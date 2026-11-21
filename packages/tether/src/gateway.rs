use anyhow::{Context, Result};
use axum::{
    Json, Router,
    body::Body,
    extract::{DefaultBodyLimit, Path, Query, Request, State},
    http::{HeaderMap, HeaderValue, StatusCode, header},
    middleware::{self, Next},
    response::{IntoResponse, Response},
    routing::{get, post},
};
use include_dir::{Dir, include_dir};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    collections::HashMap, fs, os::unix::fs::PermissionsExt, path::PathBuf, sync::Arc,
    time::Duration,
};
use tokio::{
    net::{TcpListener, UnixListener},
    process::Command,
    sync::{Mutex, mpsc, watch},
};

use crate::{
    machine,
    model::{ConnectionEvent, MAX_FRAME, Session, SshDestination, VERSION},
    state, transport,
};

static WEB: Dir = include_dir!("$CARGO_MANIFEST_DIR/frontend/dist");

struct Gateway {
    directory: PathBuf,
    origin: String,
    host: String,
    instance: String,
    directory_picker: Mutex<()>,
}

struct ApiError(StatusCode, String);
type ApiResult<T> = std::result::Result<T, ApiError>;

impl From<anyhow::Error> for ApiError {
    fn from(error: anyhow::Error) -> Self {
        Self(StatusCode::BAD_REQUEST, error.to_string())
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        (self.0, Json(json!({"error": self.1}))).into_response()
    }
}

fn cookie(headers: &HeaderMap) -> Option<&str> {
    headers
        .get(header::COOKIE)?
        .to_str()
        .ok()?
        .split(';')
        .map(str::trim)
        .find_map(|part| part.strip_prefix("tether_session="))
}

async fn boundary(State(gateway): State<Arc<Gateway>>, request: Request, next: Next) -> Response {
    let headers = request.headers();
    let host = headers
        .get(header::HOST)
        .and_then(|value| value.to_str().ok());
    let origin = headers
        .get(header::ORIGIN)
        .and_then(|value| value.to_str().ok());
    let mutation = request.method() != "GET" && request.method() != "HEAD";
    if host != Some(&gateway.host)
        || origin.is_some_and(|origin| origin != gateway.origin)
        || (mutation && origin != Some(&gateway.origin))
    {
        return ApiError(StatusCode::FORBIDDEN, "Browser origin rejected".into()).into_response();
    }
    if request.uri().path().starts_with("/api/") && request.uri().path() != "/api/login" {
        let valid = cookie(headers).map(|token| state::authenticated(&gateway.directory, token));
        match valid {
            Some(Ok(true)) => {}
            Some(Err(error)) => {
                return ApiError(StatusCode::INTERNAL_SERVER_ERROR, error.to_string())
                    .into_response();
            }
            _ => {
                return ApiError(
                    StatusCode::UNAUTHORIZED,
                    "Run tether to authorize this browser".into(),
                )
                .into_response();
            }
        }
    }
    let mut response = next.run(request).await;
    let headers = response.headers_mut();
    headers.insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
    headers.insert(
        header::REFERRER_POLICY,
        HeaderValue::from_static("no-referrer"),
    );
    headers.insert(
        header::X_CONTENT_TYPE_OPTIONS,
        HeaderValue::from_static("nosniff"),
    );
    headers.insert(header::CONTENT_SECURITY_POLICY, HeaderValue::from_static("default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; font-src 'self' data:; img-src 'self' data:; connect-src 'self'; worker-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'"));
    response
}

#[derive(Deserialize)]
struct Login {
    ticket: String,
}

async fn login(
    State(gateway): State<Arc<Gateway>>,
    Json(input): Json<Login>,
) -> ApiResult<Response> {
    let token = state::exchange_ticket(&gateway.directory, &input.ticket)?.ok_or_else(|| {
        ApiError(
            StatusCode::UNAUTHORIZED,
            "Login link expired or already used. Run tether again.".into(),
        )
    })?;
    let mut response = Json(json!({"ok": true})).into_response();
    response.headers_mut().insert(
        header::SET_COOKIE,
        HeaderValue::from_str(&format!(
            "tether_session={token}; Path=/; HttpOnly; SameSite=Strict; Max-Age=2592000"
        ))
        .unwrap(),
    );
    Ok(response)
}

async fn session(State(gateway): State<Arc<Gateway>>) -> ApiResult<Json<Session>> {
    let connection = state::gateway_database(&gateway.directory)?;
    let owner = connection
        .query_row("SELECT id FROM identity", [], |row| row.get(0))
        .map_err(anyhow::Error::from)?;
    Ok(Json(Session {
        owner,
        version: VERSION.into(),
    }))
}

async fn logout(
    State(gateway): State<Arc<Gateway>>,
    headers: HeaderMap,
    Json(input): Json<Value>,
) -> ApiResult<Response> {
    let connection = state::gateway_database(&gateway.directory)?;
    if input["all"] == true {
        connection
            .execute("DELETE FROM sessions", [])
            .map_err(anyhow::Error::from)?;
    } else if let Some(token) = cookie(&headers) {
        connection
            .execute(
                "DELETE FROM sessions WHERE hash=?1",
                [state::digest(token.as_bytes())],
            )
            .map_err(anyhow::Error::from)?;
    }
    let mut response = Json(json!({"ok": true})).into_response();
    response.headers_mut().insert(
        header::SET_COOKIE,
        HeaderValue::from_static("tether_session=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0"),
    );
    Ok(response)
}

async fn inventory(State(gateway): State<Arc<Gateway>>) -> ApiResult<Json<Value>> {
    Ok(Json(json!(state::worktrees(&gateway.directory)?)))
}

async fn machines(State(gateway): State<Arc<Gateway>>) -> ApiResult<Json<Value>> {
    Ok(Json(json!(machine::inventory(&gateway.directory)?)))
}

async fn ssh_hosts() -> ApiResult<Json<Vec<String>>> {
    Ok(Json(
        tokio::task::spawn_blocking(machine::configured_hosts)
            .await
            .map_err(anyhow::Error::from)??,
    ))
}

async fn connect_machine(
    State(gateway): State<Arc<Gateway>>,
    headers: HeaderMap,
    Json(input): Json<SshDestination>,
) -> ApiResult<Response> {
    if headers
        .get(header::ACCEPT)
        .and_then(|value| value.to_str().ok())
        != Some("application/x-ndjson")
    {
        return Ok(Json(machine::connect(&gateway.directory, input, None).await?).into_response());
    }
    let (sender, receiver) = mpsc::channel(64);
    tokio::spawn(async move {
        let result = machine::connect(&gateway.directory, input, Some(&sender)).await;
        let event = match result {
            Ok(machine) => ConnectionEvent::Connected { machine },
            Err(error) => ConnectionEvent::Error {
                message: error.to_string(),
            },
        };
        let _ = sender.send(event).await;
    });
    Ok(progress_response(receiver))
}

async fn machine_status(
    State(gateway): State<Arc<Gateway>>,
    Path(id): Path<String>,
) -> ApiResult<Json<Value>> {
    Ok(Json(json!(machine::status(&gateway.directory, &id).await?)))
}

async fn update_machine(
    State(gateway): State<Arc<Gateway>>,
    Path(id): Path<String>,
    headers: HeaderMap,
) -> ApiResult<Response> {
    if headers
        .get(header::ACCEPT)
        .and_then(|value| value.to_str().ok())
        != Some("application/x-ndjson")
    {
        return Ok(Json(machine::update(&gateway.directory, &id, None).await?).into_response());
    }
    let (sender, receiver) = mpsc::channel(64);
    tokio::spawn(async move {
        let result = machine::update(&gateway.directory, &id, Some(&sender)).await;
        let event = match result {
            Ok(machine) => ConnectionEvent::Connected { machine },
            Err(error) => ConnectionEvent::Error {
                message: error.to_string(),
            },
        };
        let _ = sender.send(event).await;
    });
    Ok(progress_response(receiver))
}

fn progress_response(receiver: mpsc::Receiver<ConnectionEvent>) -> Response {
    let stream = futures_util::stream::unfold(receiver, |mut receiver| async {
        let event = receiver.recv().await?;
        let line = serde_json::to_string(&event).map(|json| format!("{json}\n"));
        Some((line, receiver))
    });
    (
        [
            (header::CONTENT_TYPE, "application/x-ndjson"),
            (header::CACHE_CONTROL, "no-store"),
        ],
        Body::from_stream(stream),
    )
        .into_response()
}

async fn directories(
    State(gateway): State<Arc<Gateway>>,
    Path(id): Path<String>,
    Query(input): Query<machine::DirectoryInput>,
) -> ApiResult<Json<Value>> {
    Ok(Json(
        machine::request(&gateway.directory, &id, "directories", json!(input)).await?,
    ))
}

async fn machine_worktrees(
    State(gateway): State<Arc<Gateway>>,
    Path(id): Path<String>,
) -> ApiResult<Json<Value>> {
    Ok(Json(
        machine::request(&gateway.directory, &id, "worktrees", json!({})).await?,
    ))
}

async fn register_on_machine(
    State(gateway): State<Arc<Gateway>>,
    Path(id): Path<String>,
    Json(input): Json<Registration>,
) -> ApiResult<Json<Value>> {
    Ok(Json(
        machine::request(
            &gateway.directory,
            &id,
            "register",
            json!({"path": input.path}),
        )
        .await?,
    ))
}

#[derive(Deserialize)]
struct Registration {
    path: String,
}

async fn choose_directory(State(gateway): State<Arc<Gateway>>) -> ApiResult<Json<Option<String>>> {
    let _picker = gateway.directory_picker.try_lock().map_err(|_| {
        ApiError(
            StatusCode::CONFLICT,
            "A folder chooser is already open on the Tether machine".into(),
        )
    })?;
    let mut command = if cfg!(target_os = "macos") {
        let mut command = Command::new("/usr/bin/osascript");
        command.args([
            "-e",
            r#"
try
    tell current application
        activate
        set chosenDirectory to choose folder with prompt "Select a Git worktree for Tether"
    end tell
    return POSIX path of chosenDirectory
on error number -128
    return ""
end try
"#,
        ]);
        command
    } else {
        let mut command = Command::new("zenity");
        command.args([
            "--file-selection",
            "--directory",
            "--title=Select a Git worktree for Tether",
        ]);
        command
    };
    command.kill_on_drop(true);
    let output = tokio::time::timeout(Duration::from_secs(300), command.output())
        .await
        .map_err(|_| ApiError(StatusCode::REQUEST_TIMEOUT, "Folder selection timed out. Choose Browse again.".into()))?
        .context("Could not open the native folder chooser. A desktop session is required on the Tether machine")?;
    if !cfg!(target_os = "macos") && output.status.code() == Some(1) {
        return Ok(Json(None));
    }
    if !output.status.success() {
        return Err(ApiError(
            StatusCode::BAD_REQUEST,
            format!(
                "Native folder chooser failed: {}",
                String::from_utf8_lossy(&output.stderr).trim()
            ),
        ));
    }
    let path = String::from_utf8(output.stdout).context("Selected folder path must be UTF-8")?;
    let path = path.strip_suffix('\n').unwrap_or(&path);
    Ok(Json((!path.is_empty()).then(|| path.to_owned())))
}

async fn register(
    State(gateway): State<Arc<Gateway>>,
    Json(input): Json<Registration>,
) -> ApiResult<Json<Value>> {
    let worktree = tokio::task::spawn_blocking(move || {
        state::register(&gateway.directory, std::path::Path::new(&input.path))
    })
    .await
    .map_err(anyhow::Error::from)??;
    Ok(Json(json!(worktree)))
}

#[derive(Deserialize)]
struct WorktreeRoute {
    id: String,
    machine: Option<String>,
    #[serde(default)]
    operation: String,
}

async fn worktree_request(
    gateway: &Gateway,
    route: &WorktreeRoute,
    method: &str,
    params: Value,
) -> ApiResult<Json<Value>> {
    Ok(Json(
        machine::request(
            &gateway.directory,
            route.machine.as_deref().unwrap_or("local"),
            "worktree",
            json!({
                "id": route.id, "method": method, "params": params,
            }),
        )
        .await?,
    ))
}

async fn read_worktree(
    State(gateway): State<Arc<Gateway>>,
    Path(route): Path<WorktreeRoute>,
    Query(parameters): Query<HashMap<String, String>>,
) -> ApiResult<Json<Value>> {
    if ![
        "files",
        "sourceDirectory",
        "source",
        "annotations",
        "changes",
        "comparison",
        "analysisSource",
        "inspect",
    ]
    .contains(&route.operation.as_str())
    {
        return Err(ApiError(StatusCode::NOT_FOUND, "Unknown operation".into()));
    }
    worktree_request(&gateway, &route, &route.operation, json!(parameters)).await
}

async fn save_annotation(
    State(gateway): State<Arc<Gateway>>,
    Path(route): Path<WorktreeRoute>,
    Json(input): Json<Value>,
) -> ApiResult<Json<Value>> {
    worktree_request(&gateway, &route, "saveAnnotation", input).await
}

async fn enable_analysis(
    State(gateway): State<Arc<Gateway>>,
    Path(route): Path<WorktreeRoute>,
) -> ApiResult<Json<Value>> {
    worktree_request(&gateway, &route, "enableAnalysis", json!({})).await
}

async fn annotations(
    State(gateway): State<Arc<Gateway>>,
    Path(route): Path<WorktreeRoute>,
) -> ApiResult<Json<Value>> {
    worktree_request(&gateway, &route, "annotations", json!({})).await
}

async fn asset(request: Request) -> Response {
    let path = request.uri().path().trim_start_matches('/');
    let path = if path.is_empty() || path.starts_with("worktrees/") || path.starts_with("machines/")
    {
        "index.html"
    } else {
        path
    };
    match WEB.get_file(path) {
        Some(file) => Response::builder()
            .header(
                header::CONTENT_TYPE,
                mime_guess::from_path(path).first_or_octet_stream().as_ref(),
            )
            .body(Body::from(file.contents()))
            .unwrap(),
        None => StatusCode::NOT_FOUND.into_response(),
    }
}

async fn serve_control(
    control: UnixListener,
    gateway: Arc<Gateway>,
    shutdown: watch::Sender<bool>,
) -> Result<()> {
    loop {
        let (mut stream, _) = control.accept().await?;
        let gateway = gateway.clone();
        let shutdown = shutdown.clone();
        tokio::spawn(async move {
            let handle = async {
                let request: transport::Request = transport::read(&mut stream).await?;
                let outcome = request.validate().and_then(|()| match request.method.as_str() {
                    "status" => Ok(json!({"origin": gateway.origin, "instance": gateway.instance})),
                    "login" => Ok(json!({"origin": gateway.origin, "instance": gateway.instance, "ticket": state::mint_ticket(&gateway.directory)?})),
                    "stop" => Ok(json!({"stopping": true})),
                    _ => anyhow::bail!("Unknown gateway control operation"),
                });
                let stop = request.method == "stop" && outcome.is_ok();
                transport::respond(&mut stream, request.id, outcome).await?;
                if stop {
                    shutdown.send(true)?;
                }
                Ok::<(), anyhow::Error>(())
            };
            let _ = tokio::time::timeout(std::time::Duration::from_secs(5), handle).await;
        });
    }
}

pub async fn run(directory: PathBuf, port: u16) -> Result<()> {
    let _lock = state::lock(&directory.join("gateway.lock"))?;
    state::gateway_database(&directory)?;
    let listener = TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, port))
        .await
        .context(
            "Gateway port unavailable. Choose an explicit --port or stop the conflicting listener",
        )?;
    let port = listener.local_addr()?.port();
    let gateway = Arc::new(Gateway {
        directory: directory.clone(),
        host: format!("127.0.0.1:{port}"),
        origin: format!("http://127.0.0.1:{port}"),
        instance: state::secret(),
        directory_picker: Mutex::new(()),
    });
    let control_path = directory.join("gateway.sock");
    if control_path.exists() {
        fs::remove_file(&control_path)?;
    }
    let control = UnixListener::bind(&control_path)?;
    fs::set_permissions(&control_path, fs::Permissions::from_mode(0o600))?;
    let (shutdown, mut receiver) = watch::channel(false);
    let control_task = tokio::spawn(serve_control(control, gateway.clone(), shutdown));
    let identity = gateway.clone();
    let app = Router::new()
        .route(
            "/identity",
            get(move || {
                let identity = identity.clone();
                async move { Json(json!({"instance": identity.instance, "version": VERSION})) }
            }),
        )
        .route("/api/login", post(login))
        .route("/api/session", get(session))
        .route("/api/logout", post(logout))
        .route("/api/ssh-hosts", get(ssh_hosts))
        .route("/api/machines", get(machines).post(connect_machine))
        .route("/api/machines/{id}/status", get(machine_status))
        .route("/api/machines/{id}/update", post(update_machine))
        .route("/api/machines/{id}/directories", get(directories))
        .route(
            "/api/machines/{id}/worktrees",
            get(machine_worktrees).post(register_on_machine),
        )
        .route(
            "/api/machines/{machine}/worktrees/{id}/annotations",
            get(annotations).post(save_annotation),
        )
        .route(
            "/api/machines/{machine}/worktrees/{id}/enableAnalysis",
            post(enable_analysis),
        )
        .route(
            "/api/machines/{machine}/worktrees/{id}/{operation}",
            get(read_worktree),
        )
        .route("/api/worktrees", get(inventory).post(register))
        .route("/api/worktree-directory", post(choose_directory))
        .route(
            "/api/worktrees/{id}/annotations",
            get(annotations).post(save_annotation),
        )
        .route("/api/worktrees/{id}/enableAnalysis", post(enable_analysis))
        .route("/api/worktrees/{id}/{operation}", get(read_worktree))
        .fallback(asset)
        .layer(DefaultBodyLimit::max(MAX_FRAME))
        .layer(middleware::from_fn_with_state(gateway.clone(), boundary))
        .with_state(gateway.clone());
    println!("Tether gateway: {}", gateway.origin);
    axum::serve(listener, app)
        .with_graceful_shutdown(async move {
            tokio::select! { _ = receiver.changed() => {}, _ = tokio::signal::ctrl_c() => {} }
        })
        .await?;
    control_task.abort();
    fs::remove_file(control_path)?;
    Ok(())
}
