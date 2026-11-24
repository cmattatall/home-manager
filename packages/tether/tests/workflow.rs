use reqwest::{Client, StatusCode};
use serde_json::{Value, json};
use std::{
    fs,
    io::{BufRead, BufReader, Write},
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

struct Process(Child);

fn machine_rpc(
    state: &Path,
    identity: Option<&str>,
    version: &str,
    method: &str,
    input: Value,
) -> Value {
    let mut child = Command::new(env!("CARGO_BIN_EXE_tether"))
        .arg("--state-dir")
        .arg(state)
        .arg("machine-rpc")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let request = serde_json::to_vec(&json!({
        "jsonrpc": "2.0", "id": 7, "version": version, "method": method,
        "params": {"identity": identity, "input": input},
    }))
    .unwrap();
    let mut stdin = child.stdin.take().unwrap();
    stdin
        .write_all(&(request.len() as u32).to_be_bytes())
        .unwrap();
    stdin.write_all(&request).unwrap();
    drop(stdin);
    let output = child.wait_with_output().unwrap();
    assert!(output.status.success());
    let length = u32::from_be_bytes(output.stdout[..4].try_into().unwrap()) as usize;
    assert_eq!(output.stdout.len(), length + 4);
    let reply: Value = serde_json::from_slice(&output.stdout[4..]).unwrap();
    assert_eq!(reply["id"], 7);
    reply
}

impl Drop for Process {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

struct Fixture {
    _directory: tempfile::TempDir,
    state: PathBuf,
    origin: String,
    gateway: Process,
    services: Vec<Process>,
    client: Client,
}

impl Fixture {
    fn new() -> Self {
        let directory = tempfile::Builder::new()
            .prefix("tether-")
            .tempdir_in("/tmp")
            .unwrap();
        let state = directory.path().join("state");
        let (gateway, origin) = Self::gateway(&state, 0);
        let client = Client::builder()
            .no_proxy()
            .cookie_store(true)
            .pool_max_idle_per_host(0)
            .timeout(Duration::from_secs(60))
            .build()
            .unwrap();
        Self {
            _directory: directory,
            state,
            origin,
            gateway,
            services: Vec::new(),
            client,
        }
    }

    fn gateway(state: &Path, port: u16) -> (Process, String) {
        let home = state.parent().unwrap();
        let mut paths = vec![home.join("bin")];
        paths.extend(std::env::split_paths(&std::env::var_os("PATH").unwrap()));
        let mut child = Command::new(env!("CARGO_BIN_EXE_tether"))
            .env("HOME", home)
            .env("PATH", std::env::join_paths(paths).unwrap())
            .env(
                "TETHER_REMOTE_EXPRESSION",
                fs::read_to_string(home.join("bootstrap-expression")).unwrap_or_else(|_| {
                    "/nix/store/00000000000000000000000000000000-tether-remote.nix".into()
                }),
            )
            .current_dir(home)
            .arg("--state-dir")
            .arg(state)
            .arg("--port")
            .arg(port.to_string())
            .arg("gateway")
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        let mut line = String::new();
        BufReader::new(child.stdout.take().unwrap())
            .read_line(&mut line)
            .unwrap();
        let origin = line
            .trim()
            .strip_prefix("Tether gateway: ")
            .expect("gateway startup")
            .to_owned();
        (Process(child), origin)
    }

    fn ticket(&self) -> String {
        let output = Command::new(env!("CARGO_BIN_EXE_tether"))
            .arg("--state-dir")
            .arg(&self.state)
            .arg("--no-browser")
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        String::from_utf8(output.stdout)
            .unwrap()
            .trim()
            .split("#ticket=")
            .nth(1)
            .unwrap()
            .split('&')
            .next()
            .unwrap()
            .to_owned()
    }

    async fn login(&self, ticket: &str) -> reqwest::Response {
        self.client
            .post(format!("{}/api/login", self.origin))
            .header("Origin", &self.origin)
            .json(&json!({"ticket": ticket}))
            .send()
            .await
            .unwrap()
    }

    async fn get(&self, path: &str) -> reqwest::Response {
        self.client
            .get(format!("{}/api/{path}", self.origin))
            .send()
            .await
            .unwrap()
    }

    async fn read(&self, path: &str) -> Value {
        let response = self.get(path).await;
        let status = response.status();
        let result = response.json().await.unwrap();
        assert_eq!(status, StatusCode::OK, "{result}");
        result
    }

    async fn post(&self, path: &str, input: &Value) -> reqwest::Response {
        self.client
            .post(format!("{}/api/{path}", self.origin))
            .header("Origin", &self.origin)
            .json(input)
            .send()
            .await
            .unwrap()
    }

    async fn worktree(&mut self, name: &str, source: &str) -> (String, PathBuf) {
        let path = self._directory.path().join(name);
        fs::create_dir(&path).unwrap();
        assert!(
            Command::new("git")
                .args(["init", "--quiet"])
                .arg(&path)
                .status()
                .unwrap()
                .success()
        );
        fs::write(path.join("hello.go"), source).unwrap();
        let response = self.post("worktrees", &json!({"path": path})).await;
        assert_eq!(response.status(), StatusCode::OK);
        let worktree: Value = response.json().await.unwrap();
        let id = worktree["id"].as_str().unwrap().to_owned();
        self.start_service(&id).await;
        (id, path)
    }

    async fn start_service(&mut self, id: &str) {
        let mut paths = vec![self._directory.path().join("bin")];
        paths.extend(std::env::split_paths(&std::env::var_os("PATH").unwrap()));
        let child = Command::new(env!("CARGO_BIN_EXE_tether"))
            .env("HOME", self._directory.path())
            .env("PATH", std::env::join_paths(paths).unwrap())
            .arg("--state-dir")
            .arg(&self.state)
            .args(["service", "--id", id])
            .spawn()
            .unwrap();
        self.services.push(Process(child));
        let deadline = Instant::now() + Duration::from_secs(5);
        use sha2::{Digest, Sha256};
        let socket_name = format!("{:x}", Sha256::digest(id.as_bytes()));
        let socket = self.state.join("s").join(&socket_name[..32]);
        while tokio::net::UnixStream::connect(&socket).await.is_err() {
            assert!(Instant::now() < deadline, "service startup timed out");
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    }

    fn restart_gateway(&mut self) {
        self.gateway.0.kill().unwrap();
        self.gateway.0.wait().unwrap();
        let port = reqwest::Url::parse(&self.origin).unwrap().port().unwrap();
        let (gateway, origin) = Self::gateway(&self.state, port);
        assert_eq!(origin, self.origin);
        self.gateway = gateway;
    }
}

#[tokio::test]
async fn feedback_retains_evidence_and_retries_only_the_original_amp_connection() {
    use axum::{Json, Router, extract::State, http::HeaderMap, routing::get};
    use std::{
        os::unix::fs::PermissionsExt,
        sync::{
            Arc, Mutex,
            atomic::{AtomicU16, Ordering},
        },
    };

    let mut fixture = Fixture::new();
    fixture.login(&fixture.ticket()).await;
    let original = "package example\nvar Timeout = 10\n";
    let (id, root) = fixture.worktree("review", original).await;
    let (other_id, _) = fixture.worktree("other", "package other\n").await;
    let endpoint = format!("machines/local/worktrees/{id}");
    let source = fixture
        .read(&format!("{endpoint}/source?path=hello.go"))
        .await;
    let annotation_id = uuid::Uuid::new_v4().to_string();
    let input = json!({
        "id": annotation_id, "sourceId": source["id"], "path": "hello.go",
        "selection": {"startLineNumber": 2, "startColumn": 5, "endLineNumber": 2, "endColumn": 12},
        "text": "Make the timeout configurable",
    });
    assert_eq!(
        fixture
            .post(&format!("{endpoint}/annotations"), &input)
            .await
            .status(),
        StatusCode::OK
    );
    let second_id = uuid::Uuid::new_v4().to_string();
    let mut second = input.clone();
    second["id"] = json!(second_id);
    second["text"] = json!("Use milliseconds in the name");
    assert_eq!(
        fixture
            .post(&format!("{endpoint}/annotations"), &second)
            .await
            .status(),
        StatusCode::OK
    );

    let identity =
        json!({"version": 1, "root": fs::canonicalize(&root).unwrap(), "thread": "T-test-review"});
    let posts = Arc::new(Mutex::new(Vec::<Value>::new()));
    let response_status = Arc::new(AtomicU16::new(202));
    let received = Arc::new(tokio::sync::Notify::new());
    let release = Arc::new(tokio::sync::Notify::new());
    let observed = posts.clone();
    let status = response_status.clone();
    let received_by_bridge = received.clone();
    let release_bridge = release.clone();
    let app = Router::new()
        .route(
            "/feedback",
            get(
                |State(identity): State<Value>, headers: HeaderMap| async move {
                    assert_eq!(headers["authorization"], "Bearer fixture-token");
                    Json(identity)
                },
            )
            .post(move |headers: HeaderMap, Json(body): Json<Value>| {
                let observed = observed.clone();
                let status = status.clone();
                let received = received_by_bridge.clone();
                let release = release_bridge.clone();
                async move {
                    assert_eq!(headers["authorization"], "Bearer fixture-token");
                    observed.lock().unwrap().push(body);
                    let status = status.load(Ordering::SeqCst);
                    if status == 0 {
                        received.notify_one();
                        release.notified().await;
                        StatusCode::NO_CONTENT
                    } else {
                        StatusCode::from_u16(status).unwrap()
                    }
                }
            }),
        )
        .with_state(identity.clone());
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    let registry = fixture._directory.path().join(".cache/rediff/amp");
    let session_dir = registry.join("session-fixture");
    fs::create_dir_all(&session_dir).unwrap();
    for directory in [&registry, &session_dir] {
        fs::set_permissions(directory, fs::Permissions::from_mode(0o700)).unwrap();
    }
    let descriptor_path = session_dir.join("connection.json");
    let mut descriptor = identity;
    descriptor["url"] = json!(format!("http://127.0.0.1:{port}/feedback"));
    descriptor["token"] = json!("fixture-token");
    descriptor["title"] = json!("Timeout review");
    fs::write(&descriptor_path, serde_json::to_vec(&descriptor).unwrap()).unwrap();
    fs::set_permissions(&descriptor_path, fs::Permissions::from_mode(0o600)).unwrap();
    let sessions = fixture.read(&format!("{endpoint}/ampSessions")).await;
    assert_eq!(sessions.as_array().unwrap().len(), 1);
    assert!(sessions[0].get("token").is_none());
    assert_eq!(
        fixture
            .read(&format!("worktrees/{other_id}/ampSessions"))
            .await,
        json!([])
    );
    fs::set_permissions(&descriptor_path, fs::Permissions::from_mode(0o644)).unwrap();
    assert_eq!(
        fixture.read(&format!("{endpoint}/ampSessions")).await,
        json!([])
    );
    fs::set_permissions(&descriptor_path, fs::Permissions::from_mode(0o600)).unwrap();

    let batch = json!({"id": uuid::Uuid::new_v4().to_string(), "sessionId": sessions[0]["id"], "annotationIds": [annotation_id, second_id]});
    let prepared = fixture
        .post(&format!("{endpoint}/prepareFeedback"), &batch)
        .await;
    assert_eq!(prepared.status(), StatusCode::OK);
    let preview: Value = prepared.json().await.unwrap();
    assert_eq!(preview["feedback"]["status"], "prepared");
    assert!(posts.lock().unwrap().is_empty());
    let content = preview["content"].as_str().unwrap();
    let evidence: Value = serde_json::from_str(content.split("\n\n").last().unwrap()).unwrap();
    assert_eq!(evidence[0]["source"], original);
    assert_eq!(
        evidence[1]["annotation"]["input"]["text"],
        "Use milliseconds in the name"
    );
    fs::write(
        root.join("hello.go"),
        "package example\nvar Timeout = 999\n",
    )
    .unwrap();
    let mut conflicting = batch.clone();
    conflicting["annotationIds"] = json!([second_id]);
    assert_ne!(
        fixture
            .post(&format!("{endpoint}/prepareFeedback"), &conflicting)
            .await
            .status(),
        StatusCode::OK
    );
    assert_ne!(
        fixture
            .post(&format!("worktrees/{other_id}/prepareFeedback"), &batch)
            .await
            .status(),
        StatusCode::OK
    );
    let submission = json!({"id": batch["id"]});
    let pending: Value = fixture
        .post(&format!("{endpoint}/sendFeedback"), &submission)
        .await
        .json()
        .await
        .unwrap();
    assert_eq!(pending["status"], "uncertain");
    assert_eq!(posts.lock().unwrap()[0]["content"], preview["content"]);

    fixture.services[0].0.kill().unwrap();
    fixture.services[0].0.wait().unwrap();
    fixture.start_service(&id).await;
    fixture.restart_gateway();
    assert_eq!(
        fixture.read(&format!("{endpoint}/feedback")).await[0]["status"],
        "uncertain"
    );
    response_status.store(204, Ordering::SeqCst);
    let accepted: Value = fixture
        .post(&format!("{endpoint}/sendFeedback"), &submission)
        .await
        .json()
        .await
        .unwrap();
    assert_eq!(accepted["status"], "accepted");
    let sent = posts.lock().unwrap().clone();
    assert_eq!(sent.len(), 2);
    assert_eq!(sent[0], sent[1]);
    fixture
        .post(&format!("{endpoint}/sendFeedback"), &submission)
        .await;
    assert_eq!(posts.lock().unwrap().len(), 2);
    assert_eq!(
        fixture
            .read(&format!("{endpoint}/annotations"))
            .await
            .as_array()
            .unwrap()
            .len(),
        2
    );

    let mut disconnected_batch = batch.clone();
    disconnected_batch["id"] = json!(uuid::Uuid::new_v4().to_string());
    assert_eq!(
        fixture
            .post(&format!("{endpoint}/prepareFeedback"), &disconnected_batch)
            .await
            .status(),
        StatusCode::OK
    );
    response_status.store(0, Ordering::SeqCst);
    let client = fixture.client.clone();
    let origin = fixture.origin.clone();
    let url = format!("{origin}/api/{endpoint}/sendFeedback");
    let disconnected_id = disconnected_batch["id"].clone();
    let request = tokio::spawn(async move {
        client
            .post(url)
            .header("Origin", origin)
            .json(&json!({"id": disconnected_id}))
            .send()
            .await
    });
    tokio::time::timeout(Duration::from_secs(5), received.notified())
        .await
        .unwrap();
    request.abort();
    release.notify_one();
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let history = fixture.read(&format!("{endpoint}/feedback")).await;
        if history[0]["status"] == "accepted" {
            assert_eq!(history[0]["input"]["id"], disconnected_batch["id"]);
            break;
        }
        assert!(
            Instant::now() < deadline,
            "delivery did not survive browser disconnect"
        );
        tokio::time::sleep(Duration::from_millis(20)).await;
    }

    let mut uncertain_batch = batch.clone();
    uncertain_batch["id"] = json!(uuid::Uuid::new_v4().to_string());
    fixture
        .post(&format!("{endpoint}/prepareFeedback"), &uncertain_batch)
        .await;
    response_status.store(500, Ordering::SeqCst);
    let uncertain_id = json!({"id": uncertain_batch["id"]});
    let failed: Value = fixture
        .post(&format!("{endpoint}/sendFeedback"), &uncertain_id)
        .await
        .json()
        .await
        .unwrap();
    assert_eq!(failed["status"], "uncertain");
    descriptor["token"] = json!("replacement-token");
    fs::write(&descriptor_path, serde_json::to_vec(&descriptor).unwrap()).unwrap();
    let blocked: Value = fixture
        .post(&format!("{endpoint}/sendFeedback"), &uncertain_id)
        .await
        .json()
        .await
        .unwrap();
    assert_eq!(blocked["status"], "uncertain");
    assert!(
        blocked["detail"]
            .as_str()
            .unwrap()
            .contains("Original Amp connection is unavailable")
    );
    assert_eq!(posts.lock().unwrap().len(), 4);
    assert_eq!(
        fixture
            .read(&format!(
                "{endpoint}/feedbackPreview?id={}",
                batch["id"].as_str().unwrap()
            ))
            .await["content"],
        preview["content"]
    );
    descriptor["token"] = json!("fixture-token");
    fs::write(&descriptor_path, serde_json::to_vec(&descriptor).unwrap()).unwrap();
    response_status.store(204, Ordering::SeqCst);
    review_responses_survive_retries_and_require_human_resolution(
        &mut fixture,
        &id,
        &other_id,
        &root,
        &preview,
    )
    .await;
    server.abort();
}

fn submit_response(fixture: &Fixture, worktree: &str, input: &Value) -> std::process::Output {
    let mut file = tempfile::NamedTempFile::new_in(fixture._directory.path()).unwrap();
    serde_json::to_writer(&mut file, input).unwrap();
    Command::new(env!("CARGO_BIN_EXE_tether"))
        .arg("--state-dir")
        .arg(&fixture.state)
        .arg("respond")
        .arg("--worktree")
        .arg(worktree)
        .arg("--input")
        .arg(file.path())
        .output()
        .unwrap()
}

fn response_input(preview: &Value, annotation: &str) -> Value {
    let template = preview["content"]
        .as_str()
        .unwrap()
        .split("Response input:\n")
        .nth(1)
        .unwrap()
        .split("\nKeep the exact input")
        .next()
        .unwrap();
    let mut input: Value = serde_json::from_str(template).unwrap();
    input["id"] = json!(uuid::Uuid::new_v4().to_string());
    input["annotationId"] = json!(annotation);
    input["text"] =
        json!("Made the timeout configurable. Verified the supplied default and override.");
    input
}

async fn review_responses_survive_retries_and_require_human_resolution(
    fixture: &mut Fixture,
    id: &str,
    other_id: &str,
    root: &Path,
    preview: &Value,
) {
    let endpoint = format!("machines/local/worktrees/{id}");
    let annotation_id = preview["feedback"]["input"]["annotationIds"][0]
        .as_str()
        .unwrap();
    let detail_path = format!("{endpoint}/discussion?id={annotation_id}");
    assert_eq!(
        fixture.read(&detail_path).await["status"]["disposition"],
        "open"
    );
    let response = response_input(preview, annotation_id);
    let mut invalid = response.clone();
    invalid["token"] = json!("incorrect-token");
    assert!(!submit_response(fixture, id, &invalid).status.success());
    assert!(
        !submit_response(fixture, other_id, &response)
            .status
            .success()
    );
    invalid = response.clone();
    invalid["disposition"] = json!("resolved");
    assert!(!submit_response(fixture, id, &invalid).status.success());
    invalid = response.clone();
    invalid["annotationId"] = json!(uuid::Uuid::new_v4().to_string());
    assert!(!submit_response(fixture, id, &invalid).status.success());
    invalid = response.clone();
    invalid["paths"] = json!(["../missing-source"]);
    assert!(!submit_response(fixture, id, &invalid).status.success());

    let output = submit_response(fixture, id, &response);
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let addressed: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(addressed["disposition"], "addressed");
    assert_eq!(addressed["actor"]["thread"], "T-test-review");
    assert_eq!(addressed["applied"], true);
    assert_eq!(fixture.read(&detail_path).await["status"]["revision"], 1);
    let sources_path = format!(
        "{endpoint}/responseSources?id={annotation_id}&eventId={}&path=hello.go",
        response["id"].as_str().unwrap()
    );
    let sources = fixture.read(&sources_path).await;
    let assessment_path = format!(
        "{endpoint}/assessSource?id={annotation_id}&eventId={}&path=hello.go",
        response["id"].as_str().unwrap()
    );
    let response_assessment = fixture.read(&assessment_path).await;
    assert_eq!(response_assessment["freshness"], "unchanged");
    assert_eq!(response_assessment["baselineId"], sources["after"]["id"]);
    assert_eq!(
        sources["before"]["text"],
        "package example\nvar Timeout = 10\n"
    );
    assert_eq!(
        sources["after"]["text"],
        "package example\nvar Timeout = 999\n"
    );
    fs::write(
        root.join("hello.go"),
        "package example\nvar Timeout = 2000\n",
    )
    .unwrap();
    let changed = fixture
        .read(&format!("{assessment_path}&sources=true"))
        .await;
    assert_eq!(changed["assessment"]["freshness"], "changed");
    assert_eq!(changed["baseline"], sources["after"]);
    assert_eq!(
        changed["current"]["text"],
        "package example\nvar Timeout = 2000\n"
    );
    assert_eq!(
        fixture.read(&detail_path).await["status"]["disposition"],
        "addressed"
    );
    assert_eq!(
        fixture
            .get(&format!(
                "{assessment_path}&sources=true&expectedCurrentId={}",
                response_assessment["currentId"].as_str().unwrap()
            ))
            .await
            .status(),
        StatusCode::BAD_REQUEST
    );
    let retry = submit_response(fixture, id, &response);
    assert_eq!(
        serde_json::from_slice::<Value>(&retry.stdout).unwrap(),
        addressed
    );
    assert_eq!(fixture.read(&sources_path).await, sources);
    invalid = response.clone();
    invalid["text"] = json!("Changed response under the same ID");
    assert!(!submit_response(fixture, id, &invalid).status.success());

    let resolve = json!({
        "id": uuid::Uuid::new_v4().to_string(), "annotationId": annotation_id,
        "expectedRevision": 1, "disposition": "resolved", "text": "Verified the captured change",
    });
    let anonymous = Client::new()
        .post(format!(
            "{}/api/{endpoint}/resolveDiscussion",
            fixture.origin
        ))
        .header("Origin", &fixture.origin)
        .json(&resolve)
        .send()
        .await
        .unwrap();
    assert_eq!(anonymous.status(), StatusCode::UNAUTHORIZED);
    assert_eq!(
        fixture
            .post(&format!("{endpoint}/respond"), &response)
            .await
            .status(),
        StatusCode::NOT_FOUND
    );
    let resolved: Value = fixture
        .post(&format!("{endpoint}/resolveDiscussion"), &resolve)
        .await
        .json()
        .await
        .unwrap();
    assert_eq!(resolved["disposition"], "resolved");
    assert_eq!(resolved["actor"]["kind"], "human");
    assert_eq!(resolved["evidence"], addressed["evidence"]);
    assert_eq!(
        fixture
            .post(&format!("{endpoint}/resolveDiscussion"), &resolve)
            .await
            .json::<Value>()
            .await
            .unwrap(),
        resolved
    );
    let mut stale_action = resolve.clone();
    stale_action["id"] = json!(uuid::Uuid::new_v4().to_string());
    stale_action["disposition"] = json!("open");
    assert_ne!(
        fixture
            .post(&format!("{endpoint}/resolveDiscussion"), &stale_action)
            .await
            .status(),
        StatusCode::OK
    );
    let mut reopen = stale_action.clone();
    reopen["expectedRevision"] = json!(2);
    reopen["text"] = json!("Also validate negative timeouts");
    assert_eq!(
        fixture
            .post(&format!("{endpoint}/resolveDiscussion"), &reopen)
            .await
            .status(),
        StatusCode::OK
    );

    let mut late = response.clone();
    late["id"] = json!(uuid::Uuid::new_v4().to_string());
    let late_output = submit_response(fixture, id, &late);
    assert!(late_output.status.success());
    assert_eq!(
        serde_json::from_slice::<Value>(&late_output.stdout).unwrap()["applied"],
        false
    );
    let reopened = fixture.read(&detail_path).await;
    assert_eq!(reopened["status"]["disposition"], "open");
    assert_eq!(reopened["status"]["revision"], 3);
    assert_eq!(reopened["events"].as_array().unwrap().len(), 4);

    let next_batch = json!({"id": uuid::Uuid::new_v4().to_string(), "sessionId": preview["feedback"]["input"]["sessionId"], "annotationIds": [annotation_id]});
    let next_preview = fixture
        .post(&format!("{endpoint}/prepareFeedback"), &next_batch)
        .await
        .json::<Value>()
        .await
        .unwrap();
    assert!(
        next_preview["content"]
            .as_str()
            .unwrap()
            .contains("Also validate negative timeouts")
    );
    let next_response = response_input(&next_preview, annotation_id);
    assert!(
        !submit_response(fixture, id, &next_response)
            .status
            .success()
    );
    fixture
        .post(
            &format!("{endpoint}/sendFeedback"),
            &json!({"id": next_batch["id"]}),
        )
        .await;
    let next_output = submit_response(fixture, id, &next_response);
    assert!(
        next_output.status.success(),
        "{}",
        String::from_utf8_lossy(&next_output.stderr)
    );
    assert_eq!(
        serde_json::from_slice::<Value>(&next_output.stdout).unwrap()["applied"],
        true
    );
    let history = fixture.read(&detail_path).await;
    assert_eq!(history["status"]["disposition"], "addressed");
    assert_eq!(history["status"]["revision"], 4);

    let service = fixture.services.last_mut().unwrap();
    service.0.kill().unwrap();
    service.0.wait().unwrap();
    fixture.start_service(id).await;
    fixture.restart_gateway();
    assert_eq!(fixture.read(&detail_path).await, history);
    assert_eq!(fixture.read(&sources_path).await, sources);
    let restarted_retry = submit_response(fixture, id, &next_response);
    assert_eq!(
        serde_json::from_slice::<Value>(&restarted_retry.stdout).unwrap(),
        history["events"][0]
    );
    assert_eq!(fixture.read(&detail_path).await, history);
    let mut dismiss = resolve;
    dismiss["id"] = json!(uuid::Uuid::new_v4().to_string());
    dismiss["expectedRevision"] = json!(4);
    dismiss["disposition"] = json!("dismissed");
    assert_eq!(
        fixture
            .post(&format!("{endpoint}/resolveDiscussion"), &dismiss)
            .await
            .status(),
        StatusCode::OK
    );
    assert_eq!(
        fixture.read(&detail_path).await["status"]["disposition"],
        "dismissed"
    );

    fs::remove_file(root.join("hello.go")).unwrap();
    fs::write(root.join("limits.go"), "package example\nvar Minimum = 0\n").unwrap();
    let mut deleted_response = response.clone();
    deleted_response["id"] = json!(uuid::Uuid::new_v4().to_string());
    deleted_response["paths"] = json!(["limits.go"]);
    let deleted_output = submit_response(fixture, id, &deleted_response);
    assert!(deleted_output.status.success());
    let deleted: Value = serde_json::from_slice(&deleted_output.stdout).unwrap();
    assert_eq!(deleted["applied"], false);
    let deleted_sources_path = format!(
        "{endpoint}/responseSources?id={annotation_id}&eventId={}&path=hello.go",
        deleted["id"].as_str().unwrap()
    );
    let deleted_sources = fixture.read(&deleted_sources_path).await;
    assert_eq!(deleted_sources["before"], sources["before"]);
    assert!(deleted_sources["after"].is_null());
    let extra_sources_path = format!(
        "{endpoint}/responseSources?id={annotation_id}&eventId={}&path=limits.go",
        deleted["id"].as_str().unwrap()
    );
    let extra_sources = fixture.read(&extra_sources_path).await;
    assert!(extra_sources["before"].is_null());
    assert_eq!(
        extra_sources["after"]["text"],
        "package example\nvar Minimum = 0\n"
    );

    let retained = fixture.read(&detail_path).await;
    let mut expected_ids: Vec<Value> = retained["events"]
        .as_array()
        .unwrap()
        .iter()
        .map(|event| event["id"].clone())
        .collect();
    for _ in expected_ids.len()..21 {
        late["id"] = json!(uuid::Uuid::new_v4().to_string());
        assert!(submit_response(fixture, id, &late).status.success());
        expected_ids.insert(0, late["id"].clone());
    }
    let first_page = fixture.read(&detail_path).await;
    assert_eq!(first_page["nextOffset"], 20);
    let last_page = fixture.read(&format!("{detail_path}&offset=20")).await;
    assert!(last_page["nextOffset"].is_null());
    let actual_ids: Vec<Value> = first_page["events"]
        .as_array()
        .unwrap()
        .iter()
        .chain(last_page["events"].as_array().unwrap())
        .map(|event| event["id"].clone())
        .collect();
    assert_eq!(actual_ids, expected_ids);
    assert_eq!(last_page["status"], retained["status"]);
}

#[tokio::test]
async fn missing_remote_tether_is_installed_and_reused_after_setup_failures() {
    use std::os::unix::fs::{PermissionsExt, symlink};

    let mut fixture = Fixture::new();
    fixture.login(&fixture.ticket()).await;
    let home = fixture._directory.path().to_path_buf();
    let remote = home.join("remote home");
    let bin = home.join("bin");
    let remote_bin = remote.join("system-bin");
    fs::create_dir_all(&remote).unwrap();
    fs::create_dir_all(&bin).unwrap();
    fs::create_dir_all(&remote_bin).unwrap();
    for tool in ["sh", "id", "uname", "mkdir", "ln", "sleep", "cat", "rm"] {
        let executable = std::env::split_paths(&std::env::var_os("PATH").unwrap())
            .map(|directory| directory.join(tool))
            .find(|path| path.is_file())
            .unwrap();
        symlink(executable, remote_bin.join(tool)).unwrap();
    }
    let nix = bin.join("nix");
    fs::write(
        &nix,
        format!(
            r#"#!/bin/sh
set -eu
case " $* " in
    *" copy "*) exit 0 ;;
esac
if [ -e "$HOME/build-fails" ]; then
    count=0
    while [ "$count" -lt 2000 ]; do
        printf 'remote build diagnostics ✓\n' >&2
        count=$((count + 1))
    done
    echo 'Test disk full' >&2
    exit 1
fi
printf '%s' "$$" > "$HOME/build-pid"
case " $* " in
    *" --log-format raw-with-logs "*) echo 'Compiling remote Tether' >&2 ;;
esac
while [ -e "$HOME/hold-build" ]; do sleep 0.05; done
while [ "$#" -gt 0 ]; do
    if [ "$1" = --out-link ]; then
        shift
        installation=$1
    fi
    shift
done
mkdir -p "$installation/bin"
ln -s '{}' "$installation/bin/tether"
rm -f "$HOME/legacy-response"
"#,
            env!("CARGO_BIN_EXE_tether")
        ),
    )
    .unwrap();
    fs::set_permissions(&nix, fs::Permissions::from_mode(0o700)).unwrap();
    let ssh = bin.join("ssh");
    fs::write(
        &ssh,
        format!(
            r#"#!/bin/sh
set -eu
for argument do remote_command=$argument; done
export HOME='{}'
export PATH='{}'
unset XDG_STATE_HOME
case "$remote_command" in
    *'command -v nix'*)
        if [ -e "$HOME/nix-missing" ]; then
            echo 'Nix is required on this machine' >&2
            exit 1
        fi
        printf '%s\n' '{}'
        exit 0 ;;
    *'machine-rpc'*)
        if [ -e "$HOME/legacy-response" ]; then
            cat >/dev/null
            cat "$HOME/legacy-response"
            exit 0
        fi ;;
esac
exec sh -c "$remote_command"
"#,
            remote.display(),
            remote_bin.display(),
            nix.display()
        ),
    )
    .unwrap();
    fs::set_permissions(&ssh, fs::Permissions::from_mode(0o700)).unwrap();
    fixture.restart_gateway();

    fs::write(remote.join("nix-missing"), "").unwrap();
    let response = fixture
        .post("machines", &json!({"destination": "build-host"}))
        .await;
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    assert!(response.text().await.unwrap().contains("Nix is required"));
    assert_eq!(fixture.read("machines").await.as_array().unwrap().len(), 1);

    fs::remove_file(remote.join("nix-missing")).unwrap();
    fs::write(remote.join("build-fails"), "").unwrap();
    let response = fixture
        .post("machines", &json!({"destination": "build-host"}))
        .await;
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    assert!(response.text().await.unwrap().contains("Test disk full"));
    assert_eq!(fixture.read("machines").await.as_array().unwrap().len(), 1);

    fs::remove_file(remote.join("build-fails")).unwrap();
    fs::write(remote.join("hold-build"), "").unwrap();
    let mut response = fixture
        .client
        .post(format!("{}/api/machines", fixture.origin))
        .header("Origin", &fixture.origin)
        .header("Accept", "application/x-ndjson")
        .json(&json!({"destination": "build-host"}))
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let mut received = Vec::new();
    tokio::time::timeout(Duration::from_secs(5), async {
        while !String::from_utf8_lossy(&received).contains("Compiling remote Tether") {
            let chunk = response
                .chunk()
                .await
                .unwrap()
                .expect("Stream ended during build");
            received.extend_from_slice(&chunk);
        }
    })
    .await
    .expect("Build output must arrive while installation is running");
    assert!(!String::from_utf8_lossy(&received).contains("\"type\":\"connected\""));
    assert_eq!(fixture.read("machines").await.as_array().unwrap().len(), 1);
    fs::remove_file(remote.join("hold-build")).unwrap();
    received.extend_from_slice(&response.bytes().await.unwrap());
    let text = String::from_utf8(received).unwrap();
    let events: Vec<Value> = text
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    assert!(events.iter().any(|event| event["type"] == "progress"
        && event["message"] == "Building and installing Tether with Nix…"));
    assert!(events.iter().any(|event| {
        event["type"] == "output"
            && event["text"]
                .as_str()
                .unwrap()
                .contains("Compiling remote Tether")
    }));
    let completed = events.last().unwrap();
    assert_eq!(completed["type"], "connected", "{text}");
    let machine = &completed["machine"];
    assert_eq!(machine["ssh"]["destination"], "build-host");
    let machines = fixture.read("machines").await;
    assert!(machines.as_array().unwrap().contains(machine));

    fs::write(remote.join("build-fails"), "").unwrap();
    fs::write(
        home.join("bootstrap-expression"),
        "/nix/store/11111111111111111111111111111111-tether-remote.nix",
    )
    .unwrap();
    fixture.restart_gateway();
    let response = fixture
        .post("machines", &json!({"destination": "build-host"}))
        .await;
    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(response.json::<Value>().await.unwrap(), *machine);
    let id = machine["id"].as_str().unwrap();
    assert_eq!(
        fixture.read(&format!("machines/{id}/worktrees")).await,
        json!([])
    );

    let status_path = format!("machines/{id}/status");
    let update_path = format!("machines/{id}/update");
    let status = fixture.read(&status_path).await;
    assert_eq!(status["installed"], status["expected"]);
    assert_eq!(status["canUpdate"], true);
    assert_eq!(status["updating"], false);
    assert_eq!(status["expected"]["buildId"].as_str().unwrap().len(), 64);

    let write_older_identity = |identity: &str, build: Option<&str>| {
        let mut remote_identity = machine.clone();
        remote_identity["id"] = identity.into();
        if let Some(build) = build {
            remote_identity["buildId"] = build.into();
        }
        let reply = serde_json::to_vec(&json!({
            "jsonrpc": "2.0", "id": 1, "version": "0.1.0", "result": remote_identity,
        }))
        .unwrap();
        let mut frame = (reply.len() as u32).to_be_bytes().to_vec();
        frame.extend(reply);
        fs::write(remote.join("legacy-response"), frame).unwrap();
    };
    write_older_identity("replaced-machine", None);
    assert_eq!(
        fixture.get(&status_path).await.status(),
        StatusCode::BAD_REQUEST
    );
    assert!(
        fixture
            .post(&update_path, &json!({}))
            .await
            .text()
            .await
            .unwrap()
            .contains("identity changed")
    );

    write_older_identity(id, None);
    let legacy = fixture.read(&status_path).await;
    assert!(legacy["installed"]["buildId"].is_null());
    assert_eq!(legacy["installed"]["version"], "0.1.0");
    let current_link = remote.join(".local/share/tether/installations/current");
    let previous_installation = fs::read_link(&current_link).unwrap();
    let failed = fixture.post(&update_path, &json!({})).await;
    assert_eq!(failed.status(), StatusCode::BAD_REQUEST);
    assert!(failed.text().await.unwrap().contains("Test disk full"));
    assert_eq!(fs::read_link(&current_link).unwrap(), previous_installation);
    assert_eq!(fixture.read(&status_path).await["updating"], false);
    let failure_log = fixture.read(&update_path).await;
    assert_eq!(failure_log["state"], "failed");
    assert!(
        failure_log["message"]
            .as_str()
            .unwrap()
            .contains("Test disk full")
    );
    let log_tail = failure_log["output"].as_str().unwrap();
    assert!(log_tail.len() <= 32_768);
    assert!(log_tail.contains('✓'));
    assert!(log_tail.ends_with("Test disk full\n"));

    write_older_identity(id, Some("earlier-source-build"));
    assert_eq!(
        fixture.read(&status_path).await["installed"]["buildId"],
        "earlier-source-build"
    );
    fs::remove_file(remote.join("build-fails")).unwrap();
    fs::write(remote.join("hold-build"), "").unwrap();
    let mut updating = fixture
        .client
        .post(format!("{}/api/{update_path}", fixture.origin))
        .header("Origin", &fixture.origin)
        .header("Accept", "application/x-ndjson")
        .send()
        .await
        .unwrap();
    let mut output = Vec::new();
    tokio::time::timeout(Duration::from_secs(5), async {
        while !String::from_utf8_lossy(&output).contains("Compiling remote Tether") {
            output.extend_from_slice(&updating.chunk().await.unwrap().unwrap());
        }
    })
    .await
    .unwrap();
    assert_eq!(fixture.read(&status_path).await["updating"], true);
    let duplicate = fixture.post(&update_path, &json!({})).await;
    assert_eq!(duplicate.status(), StatusCode::BAD_REQUEST);
    assert!(duplicate.text().await.unwrap().contains("already running"));
    drop(updating);
    let retained = fixture.read(&update_path).await;
    assert_eq!(retained["state"], "running");
    assert!(
        retained["output"]
            .as_str()
            .unwrap()
            .contains("Compiling remote Tether")
    );
    let build_pid = fs::read_to_string(remote.join("build-pid"))
        .unwrap()
        .parse()
        .unwrap();
    let build_pid = rustix::process::Pid::from_raw(build_pid).unwrap();
    assert!(rustix::process::test_kill_process(build_pid).is_ok());
    let cancel_path = format!("{update_path}/cancel");
    assert_eq!(
        fixture.post(&cancel_path, &json!({})).await.status(),
        StatusCode::OK
    );
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            let progress = fixture.read(&update_path).await;
            let process_stopped = rustix::process::test_kill_process(build_pid).is_err();
            if progress["state"] == "cancelled" && process_stopped {
                assert_eq!(progress["message"], "Update cancelled");
                assert_eq!(progress["output"], retained["output"]);
                break;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await
    .expect("Cancellation must stop the build and retain its log");
    assert_eq!(fixture.read(&status_path).await["updating"], false);
    assert_eq!(fs::read_link(&current_link).unwrap(), previous_installation);
    assert_eq!(
        fixture.post(&cancel_path, &json!({})).await.status(),
        StatusCode::OK
    );

    fs::remove_file(remote.join("hold-build")).unwrap();
    let retried = fixture
        .client
        .post(format!("{}/api/{update_path}", fixture.origin))
        .header("Origin", &fixture.origin)
        .header("Accept", "application/x-ndjson")
        .send()
        .await
        .unwrap();
    let output = retried.bytes().await.unwrap();
    let finished: Value = serde_json::from_str(
        std::str::from_utf8(&output)
            .unwrap()
            .lines()
            .last()
            .unwrap(),
    )
    .unwrap();
    assert_eq!(finished["type"], "connected");
    assert_eq!(finished["machine"], *machine);
    let status = fixture.read(&status_path).await;
    assert_eq!(status["installed"], status["expected"]);
    assert_eq!(status["updating"], false);
    assert_ne!(fs::read_link(&current_link).unwrap(), previous_installation);
    let completed_log = fixture.read(&update_path).await;
    assert_eq!(completed_log["state"], "succeeded");
    assert_eq!(completed_log["message"], "Update complete");
    assert!(
        completed_log["output"]
            .as_str()
            .unwrap()
            .contains("Compiling remote Tether")
    );
    fs::write(remote.join("build-fails"), "").unwrap();
    assert_eq!(
        fixture.post(&update_path, &json!({})).await.status(),
        StatusCode::OK
    );
}

#[tokio::test]
async fn configured_hosts_connect_using_the_remote_home_manager_installation() {
    use std::os::unix::fs::{PermissionsExt, symlink};

    let mut fixture = Fixture::new();
    assert_eq!(
        fixture.get("ssh-hosts").await.status(),
        StatusCode::UNAUTHORIZED
    );
    fixture.login(&fixture.ticket()).await;
    assert_eq!(fixture.read("ssh-hosts").await, json!([]));
    let home = fixture._directory.path();
    fs::create_dir(home.join(".ssh")).unwrap();
    fs::write(
        home.join(".ssh/config"),
        r#"
# Host commented-out
Host beta alpha !excluded *.example node? [ab]
    HostName actual-hostname
hOsT="quoted-alias" alpha # duplicate and comment
Host = gamma
Match exec "touch should-never-execute"
    User another-user
"#,
    )
    .unwrap();
    assert_eq!(
        fixture.read("ssh-hosts").await,
        json!(["alpha", "beta", "gamma", "quoted-alias"])
    );
    assert!(!home.join("should-never-execute").exists());

    let remote = home.join("remote home");
    let remote_bin = remote.join("system-bin");
    let profile = remote.join(".nix-profile/bin");
    fs::create_dir_all(&remote_bin).unwrap();
    fs::create_dir_all(&profile).unwrap();
    for tool in ["sh", "id", "uname"] {
        let executable = std::env::split_paths(&std::env::var_os("PATH").unwrap())
            .map(|directory| directory.join(tool))
            .find(|path| path.is_file())
            .unwrap();
        symlink(executable, remote_bin.join(tool)).unwrap();
    }
    symlink(env!("CARGO_BIN_EXE_tether"), profile.join("tether")).unwrap();
    fs::create_dir(home.join("bin")).unwrap();
    let ssh = home.join("bin/ssh");
    fs::write(
        &ssh,
        format!(
            r#"#!/bin/sh
for argument do remote_command=$argument; done
unset XDG_STATE_HOME
export HOME="{}"
export PATH="{}"
exec sh -c "$remote_command"
"#,
            remote.display(),
            remote_bin.display()
        ),
    )
    .unwrap();
    fs::set_permissions(&ssh, fs::Permissions::from_mode(0o700)).unwrap();
    fixture.restart_gateway();
    let response = fixture
        .post("machines", &json!({"destination": "alpha"}))
        .await;
    assert_eq!(response.status(), StatusCode::OK);
    let machine: Value = response.json().await.unwrap();
    assert_eq!(machine["ssh"], json!({"destination": "alpha"}));
    let id = machine["id"].as_str().unwrap();
    assert_eq!(
        fixture.read(&format!("machines/{id}/directories")).await["path"],
        remote.canonicalize().unwrap().to_str().unwrap()
    );
    assert_eq!(
        fixture.read(&format!("machines/{id}/worktrees")).await,
        json!([])
    );
    let machines = fixture.read("machines").await;
    assert!(machines.as_array().unwrap().contains(&machine));

    fixture.restart_gateway();
    let machines = fixture.read("machines").await;
    assert!(machines.as_array().unwrap().contains(&machine));

    assert_eq!(
        fixture
            .post(
                "machines",
                &json!({"destination": "-oProxyCommand=anything"})
            )
            .await
            .status(),
        StatusCode::BAD_REQUEST
    );

    fs::write(
        fixture._directory.path().join(".ssh/config"),
        "Host \"unfinished\n",
    )
    .unwrap();
    let response = fixture.get("ssh-hosts").await;
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    assert!(
        response
            .text()
            .await
            .unwrap()
            .contains("Invalid Host quoting")
    );
}

#[tokio::test]
async fn machine_browsing_preserves_host_identity_and_registration_boundaries() {
    use std::os::unix::fs::{PermissionsExt, symlink};

    let mut fixture = Fixture::new();
    assert_eq!(
        fixture.get("machines").await.status(),
        StatusCode::UNAUTHORIZED
    );
    assert_eq!(
        fixture.get("machines/local/directories").await.status(),
        StatusCode::UNAUTHORIZED
    );
    fixture.login(&fixture.ticket()).await;
    let (local_id, root) = fixture
        .worktree("same checkout ✓", "package sample\n")
        .await;
    fs::create_dir(root.join("nested ' folder")).unwrap();
    fs::create_dir(root.join(".hidden")).unwrap();
    symlink(root.join("nested ' folder"), root.join("linked")).unwrap();
    symlink(root.join("missing"), root.join("broken")).unwrap();

    let state = fixture._directory.path().join("other-machine");
    let version = env!("CARGO_PKG_VERSION");
    let remote = machine_rpc(&state, None, version, "identity", json!({}));
    let identity = remote["result"]["id"].as_str().unwrap();
    let listing = machine_rpc(
        &state,
        Some(identity),
        version,
        "directories",
        json!({"path": root}),
    );
    assert_eq!(
        listing["result"]["entries"],
        json!(["linked", "nested ' folder"])
    );
    assert_eq!(listing["result"]["skipped"], 1);
    assert_eq!(
        listing["result"]["path"],
        json!(root.canonicalize().unwrap())
    );
    let hidden = machine_rpc(
        &state,
        Some(identity),
        version,
        "directories",
        json!({"path": root, "hidden": true}),
    );
    assert!(
        hidden["result"]["entries"]
            .as_array()
            .unwrap()
            .contains(&json!(".hidden"))
    );
    assert_eq!(
        machine_rpc(&state, Some(identity), version, "worktrees", json!({}))["result"],
        json!([])
    );
    let registered = machine_rpc(
        &state,
        Some(identity),
        version,
        "register",
        json!({"path": root}),
    );
    assert_ne!(registered["result"]["id"], local_id);
    assert_eq!(
        registered["result"]["path"],
        json!(root.canonicalize().unwrap())
    );
    let local_worktrees = fixture.read("worktrees").await;
    assert_eq!(local_worktrees.as_array().unwrap().len(), 1);
    assert_eq!(local_worktrees[0]["id"], local_id);

    for (remote_identity, remote_version) in [
        (Some("other-host"), version),
        (Some(identity), "different-release"),
    ] {
        let refused = machine_rpc(
            &state,
            remote_identity,
            remote_version,
            "register",
            json!({"path": root}),
        );
        assert!(refused.get("error").is_some());
    }
    assert_eq!(
        machine_rpc(&state, Some(identity), version, "worktrees", json!({}))["result"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    let unknown = fixture.get("machines/unknown/directories").await;
    assert_eq!(unknown.status(), StatusCode::BAD_REQUEST);
    assert!(
        unknown.json::<Value>().await.unwrap()["error"]
            .as_str()
            .unwrap()
            .contains("Unknown machine")
    );

    let paged = root.join("pagination");
    fs::create_dir(&paged).unwrap();
    for index in 0..201 {
        fs::create_dir(paged.join(format!("folder-{index:03}"))).unwrap();
    }
    let first = machine_rpc(
        &state,
        Some(identity),
        version,
        "directories",
        json!({"path": paged}),
    );
    assert_eq!(first["result"]["entries"].as_array().unwrap().len(), 200);
    assert_eq!(first["result"]["entries"][0], "folder-000");
    assert_eq!(first["result"]["entries"][199], "folder-199");
    assert_eq!(first["result"]["nextOffset"], 200);
    let last = machine_rpc(
        &state,
        Some(identity),
        version,
        "directories",
        json!({"path": paged, "offset": 200}),
    );
    assert_eq!(last["result"]["entries"], json!(["folder-200"]));
    assert_eq!(last["result"]["nextOffset"], Value::Null);
    assert!(
        machine_rpc(
            &state,
            Some(identity),
            version,
            "directories",
            json!({"path": "relative"})
        )
        .get("error")
        .is_some()
    );

    let denied = root.join("denied");
    fs::create_dir(&denied).unwrap();
    fs::set_permissions(&denied, fs::Permissions::from_mode(0o000)).unwrap();
    let refused = machine_rpc(
        &state,
        Some(identity),
        version,
        "directories",
        json!({"path": denied}),
    );
    fs::set_permissions(&denied, fs::Permissions::from_mode(0o700)).unwrap();
    assert!(
        refused["error"]["message"]
            .as_str()
            .unwrap()
            .contains("Could not list directory")
    );
}

#[tokio::test]
async fn login_is_single_use_origin_bound_persistent_and_revocable() {
    let mut fixture = Fixture::new();
    assert_eq!(
        fixture.get("session").await.status(),
        StatusCode::UNAUTHORIZED
    );
    assert_eq!(
        fixture
            .post("worktree-directory", &json!({}))
            .await
            .status(),
        StatusCode::UNAUTHORIZED
    );
    let ticket = fixture.ticket();
    let hostile = fixture
        .client
        .post(format!("{}/api/login", fixture.origin))
        .header("Origin", "https://example.invalid")
        .json(&json!({"ticket": ticket}))
        .send()
        .await
        .unwrap();
    assert_eq!(hostile.status(), StatusCode::FORBIDDEN);
    let response = fixture.login(&ticket).await;
    assert_eq!(response.status(), StatusCode::OK);
    let cookie = response.headers()["set-cookie"].to_str().unwrap();
    assert!(cookie.contains("HttpOnly; SameSite=Strict; Max-Age=2592000"));
    let database = rusqlite::Connection::open(fixture.state.join("gateway.sqlite")).unwrap();
    let before_request = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64;
    database
        .execute("UPDATE sessions SET expires=?1", [before_request + 60])
        .unwrap();
    let renewed = fixture.get("session").await;
    assert_eq!(renewed.status(), StatusCode::OK);
    assert_eq!(renewed.headers()["set-cookie"].to_str().unwrap(), cookie);
    let expires: i64 = database
        .query_row("SELECT expires FROM sessions", [], |row| row.get(0))
        .unwrap();
    let after_request = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64;
    let thirty_days = 30 * 24 * 3600;
    assert!((before_request + thirty_days..=after_request + thirty_days).contains(&expires));

    database
        .execute("UPDATE sessions SET expires=0", [])
        .unwrap();
    let expired = fixture.get("session").await;
    assert_eq!(expired.status(), StatusCode::UNAUTHORIZED);
    assert!(!expired.headers().contains_key("set-cookie"));
    assert_eq!(
        fixture.login(&fixture.ticket()).await.status(),
        StatusCode::OK
    );
    drop(database);

    for origin in [None, Some("https://example.invalid")] {
        let mut request = fixture
            .client
            .post(format!("{}/api/worktree-directory", fixture.origin));
        if let Some(origin) = origin {
            request = request.header("Origin", origin);
        }
        assert_eq!(
            request.send().await.unwrap().status(),
            StatusCode::FORBIDDEN
        );
    }
    assert_eq!(
        fixture.get("worktree-directory").await.status(),
        StatusCode::METHOD_NOT_ALLOWED
    );
    assert_eq!(
        fixture.login(&ticket).await.status(),
        StatusCode::UNAUTHORIZED
    );
    let owner: Value = fixture.get("session").await.json().await.unwrap();
    fixture.restart_gateway();
    let restored: Value = fixture.get("session").await.json().await.unwrap();
    assert_eq!(owner, restored);

    let wrong_host = fixture
        .client
        .get(format!("{}/api/session", fixture.origin))
        .header("Host", "attacker.invalid")
        .send()
        .await
        .unwrap();
    assert_eq!(wrong_host.status(), StatusCode::FORBIDDEN);
    let no_origin = fixture
        .client
        .post(format!("{}/api/logout", fixture.origin))
        .json(&json!({"all": true}))
        .send()
        .await
        .unwrap();
    assert_eq!(no_origin.status(), StatusCode::FORBIDDEN);

    let second_browser = Client::builder()
        .no_proxy()
        .cookie_store(true)
        .build()
        .unwrap();
    assert_eq!(
        second_browser
            .post(format!("{}/api/login", fixture.origin))
            .header("Origin", &fixture.origin)
            .json(&json!({"ticket": fixture.ticket()}))
            .send()
            .await
            .unwrap()
            .status(),
        StatusCode::OK
    );
    let logout = fixture.post("logout", &json!({"all": true})).await;
    assert_eq!(logout.status(), StatusCode::OK);
    assert!(
        logout.headers()["set-cookie"]
            .to_str()
            .unwrap()
            .contains("Max-Age=0")
    );
    assert_eq!(
        fixture.get("session").await.status(),
        StatusCode::UNAUTHORIZED
    );
    assert_eq!(
        second_browser
            .get(format!("{}/api/session", fixture.origin))
            .send()
            .await
            .unwrap()
            .status(),
        StatusCode::UNAUTHORIZED
    );
}

#[tokio::test]
async fn annotations_retain_exact_unicode_source_across_edits_retries_and_restarts() {
    let mut fixture = Fixture::new();
    assert_eq!(
        fixture.login(&fixture.ticket()).await.status(),
        StatusCode::OK
    );
    let original = "\u{feff}package demo\r\n// A😀B and e\u{301}\rfunc hello() {}\r\n";
    let (id, directory) = fixture.worktree("alpha", original).await;
    let (other_id, _) = fixture.worktree("beta", "package other\n").await;
    let endpoint = format!("worktrees/{id}");
    let source: Value = fixture
        .get(&format!("{endpoint}/source?path=hello.go"))
        .await
        .json()
        .await
        .unwrap();
    assert_eq!(source["text"], original);
    fs::write(directory.join("hello.go"), "agent replaced this file\n").unwrap();
    let mut input = json!({
        "id": uuid::Uuid::new_v4().to_string(), "sourceId": source["id"], "path": "hello.go",
        "selection": {"startLineNumber": 2, "startColumn": 5, "endLineNumber": 2, "endColumn": 8},
        "text": "Preserve the Unicode greeting"
    });
    let saved = fixture
        .post(&format!("{endpoint}/annotations"), &input)
        .await;
    assert_eq!(saved.status(), StatusCode::OK);
    let saved: Value = saved.json().await.unwrap();
    assert_eq!(saved["excerpt"], "😀B");
    let replay: Value = fixture
        .post(&format!("{endpoint}/annotations"), &input)
        .await
        .json()
        .await
        .unwrap();
    assert_eq!(replay, saved);
    input["text"] = json!("Different content under the same operation ID");
    assert_eq!(
        fixture
            .post(&format!("{endpoint}/annotations"), &input)
            .await
            .status(),
        StatusCode::BAD_REQUEST
    );
    input["id"] = json!(uuid::Uuid::new_v4().to_string());
    assert_eq!(
        fixture
            .post(&format!("worktrees/{other_id}/annotations"), &input)
            .await
            .status(),
        StatusCode::BAD_REQUEST
    );
    input["selection"]["startColumn"] = json!(6);
    assert_eq!(
        fixture
            .post(&format!("{endpoint}/annotations"), &input)
            .await
            .status(),
        StatusCode::BAD_REQUEST
    );

    fixture.services[0].0.kill().unwrap();
    fixture.services[0].0.wait().unwrap();
    let legacy_service =
        std::os::unix::net::UnixListener::bind(fixture.state.join("s").join(&id)).unwrap();
    let legacy_lock = fs::File::create(
        fixture
            .state
            .join("worktrees")
            .join(&id)
            .join("service.lock"),
    )
    .unwrap();
    fs2::FileExt::try_lock_exclusive(&legacy_lock).unwrap();
    fixture.start_service(&id).await;
    fixture.restart_gateway();
    let notes: Value = fixture
        .get(&format!("{endpoint}/annotations"))
        .await
        .json()
        .await
        .unwrap();
    assert_eq!(notes, json!([saved]));
    drop(legacy_service);
    drop(legacy_lock);
    input["selection"] =
        json!({"startLineNumber": 1, "startColumn": 1, "endLineNumber": 3, "endColumn": 5});
    let spanning: Value = fixture
        .post(&format!("{endpoint}/annotations"), &input)
        .await
        .json()
        .await
        .unwrap();
    assert_eq!(
        spanning["excerpt"],
        "package demo\r\n// A😀B and e\u{301}\rfunc"
    );
    input["id"] = json!(uuid::Uuid::new_v4().to_string());
    input["selection"] =
        json!({"startLineNumber": 4, "startColumn": 1, "endLineNumber": 4, "endColumn": 1});
    input["text"] = json!("Add the missing example on this blank line");
    let blank = fixture
        .post(&format!("{endpoint}/annotations"), &input)
        .await;
    assert_eq!(blank.status(), StatusCode::OK);
    let blank: Value = blank.json().await.unwrap();
    assert_eq!(blank["excerpt"], "");
    assert_eq!(blank["input"], input);
    assert_eq!(
        fixture.read(&format!("{endpoint}/annotations")).await[0],
        blank
    );
    input["id"] = json!(uuid::Uuid::new_v4().to_string());
    input["selection"] =
        json!({"startLineNumber": 5, "startColumn": 1, "endLineNumber": 5, "endColumn": 1});
    assert_eq!(
        fixture
            .post(&format!("{endpoint}/annotations"), &input)
            .await
            .status(),
        StatusCode::BAD_REQUEST
    );
    let other_notes: Value = fixture
        .get(&format!("worktrees/{other_id}/annotations"))
        .await
        .json()
        .await
        .unwrap();
    assert_eq!(other_notes, json!([]));
}

#[tokio::test]
async fn explorer_browses_clean_worktrees_and_pages_immediate_children() {
    let mut fixture = Fixture::new();
    assert_eq!(
        fixture.login(&fixture.ticket()).await.status(),
        StatusCode::OK
    );
    let (id, directory) = fixture.worktree("explorer", "package main\n").await;
    git(&directory, &["add", "hello.go"]);
    git(&directory, &["commit", "--quiet", "-m", "Initial source"]);
    let endpoint = format!("machines/local/worktrees/{id}");
    assert_eq!(
        fixture
            .read(&format!("{endpoint}/changes?scope=uncommitted"))
            .await,
        json!([])
    );
    assert_eq!(
        fixture
            .read(&format!("{endpoint}/sourceDirectory?path="))
            .await,
        json!({"entries": [{"path": "hello.go", "directory": false}], "nextOffset": null})
    );

    fs::create_dir(directory.join("nested # folder")).unwrap();
    fs::create_dir(directory.join("empty")).unwrap();
    fs::write(directory.join(".hidden"), "hidden content").unwrap();
    fs::write(directory.join(".git/info/exclude"), ".hidden\n").unwrap();
    std::os::unix::fs::symlink("/tmp", directory.join("linked")).unwrap();
    for number in 0..201 {
        fs::write(
            directory.join(format!("nested # folder/file-{number:03}.txt")),
            "source",
        )
        .unwrap();
    }
    assert_eq!(
        fixture
            .read(&format!("{endpoint}/sourceDirectory?path="))
            .await,
        json!({"entries": [
            {"path": "empty", "directory": true},
            {"path": "nested # folder", "directory": true},
            {"path": ".hidden", "directory": false},
            {"path": "hello.go", "directory": false}
        ], "nextOffset": null})
    );
    assert_eq!(
        fixture
            .read(&format!("{endpoint}/sourceDirectory?path=empty"))
            .await,
        json!({"entries": [], "nextOffset": null})
    );
    let first = fixture
        .read(&format!(
            "{endpoint}/sourceDirectory?path=nested%20%23%20folder"
        ))
        .await;
    assert_eq!(first["entries"].as_array().unwrap().len(), 200);
    assert_eq!(first["entries"][0]["path"], "nested # folder/file-000.txt");
    assert_eq!(
        first["entries"][199]["path"],
        "nested # folder/file-199.txt"
    );
    assert_eq!(first["nextOffset"], 200);
    assert_eq!(
        fixture
            .read(&format!(
                "{endpoint}/sourceDirectory?path=nested%20%23%20folder&offset=200"
            ))
            .await,
        json!({"entries": [{"path": "nested # folder/file-200.txt", "directory": false}], "nextOffset": null})
    );
    let source = fixture
        .read(&format!(
            "{endpoint}/source?path=nested%20%23%20folder/file-200.txt"
        ))
        .await;
    assert_eq!(source["text"], "source");
    for path in ["..", "/tmp", ".git", "linked", "linked/nested", "hello.go"] {
        let response = fixture
            .client
            .get(format!("{}/api/{endpoint}/sourceDirectory", fixture.origin))
            .query(&[("path", path)])
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::BAD_REQUEST, "path: {path}");
    }
}

#[tokio::test]
async fn source_reads_reject_metadata_symlinks_binary_and_oversized_files() {
    let mut fixture = Fixture::new();
    assert_eq!(
        fixture.login(&fixture.ticket()).await.status(),
        StatusCode::OK
    );
    let (id, directory) = fixture.worktree("paths", "valid text").await;
    fs::write(directory.join("large"), vec![b'x'; 65_537]).unwrap();
    fs::write(directory.join("binary"), b"a\0b").unwrap();
    std::os::unix::fs::symlink(".git", directory.join("metadata")).unwrap();
    std::os::unix::fs::symlink("/etc/passwd", directory.join("outside")).unwrap();
    for path in [
        "../hello.go",
        ".git/config",
        "metadata/config",
        "outside",
        "large",
        "binary",
    ] {
        let response = fixture
            .client
            .get(format!("{}/api/worktrees/{id}/source", fixture.origin))
            .query(&[("path", path)])
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::BAD_REQUEST, "path: {path}");
    }
}

fn git(directory: &Path, arguments: &[&str]) {
    let output = Command::new("git")
        .args([
            "-c",
            "user.name=Tether Test",
            "-c",
            "user.email=tether@example.invalid",
            "-c",
            "commit.gpgSign=false",
        ])
        .args(arguments)
        .current_dir(directory)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
}

#[tokio::test]
async fn source_freshness_tracks_selections_and_preserves_review_evidence() {
    let mut fixture = Fixture::new();
    fixture.login(&fixture.ticket()).await;
    let original = "package example\nvar Timeout = 10\n";
    let (id, root) = fixture.worktree("freshness", original).await;
    let endpoint = format!("machines/local/worktrees/{id}");
    let source = fixture
        .read(&format!("{endpoint}/source?path=hello.go"))
        .await;
    let annotation_id = uuid::Uuid::new_v4().to_string();
    let selection =
        json!({"startLineNumber": 2, "startColumn": 5, "endLineNumber": 2, "endColumn": 17});
    let input = json!({
        "id": annotation_id, "sourceId": source["id"], "path": "hello.go",
        "selection": selection, "text": "Check this timeout",
    });
    let saved: Value = fixture
        .post(&format!("{endpoint}/annotations"), &input)
        .await
        .json()
        .await
        .unwrap();
    assert_eq!(saved["excerpt"], "Timeout = 10");
    let assess_path = format!("{endpoint}/assessSource?id={annotation_id}");
    let initial = fixture.read(&assess_path).await;
    assert_eq!(initial["freshness"], "unchanged");
    assert_eq!(initial["fileChanged"], false);
    assert_eq!(initial["selection"], selection);
    for (text, expected, line) in [
        (
            "package example\nvar Timeout = 10 // seconds\n",
            "unchanged",
            Some(2),
        ),
        (
            "// header\npackage example\nvar Timeout = 10\n",
            "moved",
            Some(3),
        ),
        ("package example\nvar Timeout = 99\n", "changed", None),
        (
            "package example\nvar Timeout = 10\n// Timeout = 10\n",
            "uncertain",
            None,
        ),
        (
            "package example\n// header\n// Timeout = 10\n",
            "uncertain",
            None,
        ),
        ("package example\n", "removed", None),
    ] {
        fs::write(root.join("hello.go"), text).unwrap();
        let observed = fixture.read(&assess_path).await;
        assert_eq!(observed["freshness"], expected, "{text}");
        assert_eq!(observed["fileChanged"], true);
        assert_eq!(observed["baselineId"], source["id"]);
        match line {
            Some(line) => assert_eq!(observed["selection"]["startLineNumber"], line),
            None => assert!(observed["selection"].is_null()),
        }
        assert_eq!(
            fixture
                .read(&format!("{endpoint}/discussion?id={annotation_id}"))
                .await["status"]["disposition"],
            "open"
        );
    }
    fs::remove_file(root.join("hello.go")).unwrap();
    let removed = fixture.read(&format!("{assess_path}&sources=true")).await;
    assert_eq!(removed["assessment"]["freshness"], "removed");
    assert!(removed["current"].is_null());
    assert_eq!(removed["original"]["text"], original);
    std::os::unix::fs::symlink("/etc/hosts", root.join("hello.go")).unwrap();
    let unknown = fixture.read(&assess_path).await;
    assert_eq!(unknown["freshness"], "unknown");
    assert!(unknown["fileChanged"].is_null());
    fs::remove_file(root.join("hello.go")).unwrap();
    fs::write(root.join("hello.go"), original).unwrap();
    fixture.restart_gateway();
    let reverted = fixture.read(&assess_path).await;
    assert_eq!(reverted["freshness"], "unchanged");
    assert_eq!(reverted["fileChanged"], false);
    assert_eq!(
        fixture.read(&format!("{endpoint}/annotations")).await,
        json!([saved])
    );
    for (revision, disposition) in [(0, "resolved"), (1, "dismissed"), (2, "open")] {
        let action = json!({"id": uuid::Uuid::new_v4().to_string(), "annotationId": annotation_id,
            "expectedRevision": revision, "disposition": disposition, "text": "Reviewed"});
        assert_eq!(
            fixture
                .post(&format!("{endpoint}/resolveDiscussion"), &action)
                .await
                .status(),
            StatusCode::OK
        );
        fs::write(root.join("hello.go"), "package example\nvar Timeout = 20\n").unwrap();
        assert_eq!(
            fixture.read(&format!("{endpoint}/assessments")).await[0]["freshness"],
            "changed"
        );
        assert_eq!(
            fixture
                .read(&format!("{endpoint}/discussion?id={annotation_id}"))
                .await["status"]["disposition"],
            disposition
        );
    }

    fs::write(root.join("hello.go"), original).unwrap();
    git(&root, &["add", "."]);
    git(&root, &["commit", "-qm", "baseline"]);
    fs::remove_file(root.join("hello.go")).unwrap();
    let comparison = fixture
        .read(&format!(
            "{endpoint}/comparison?scope=uncommitted&path=hello.go"
        ))
        .await;
    let deleted_id = uuid::Uuid::new_v4().to_string();
    let mut deletion = input.clone();
    deletion["id"] = json!(deleted_id);
    deletion["review"] = json!({"comparisonId": comparison["id"], "side": "before"});
    assert_eq!(
        fixture
            .post(&format!("{endpoint}/annotations"), &deletion)
            .await
            .status(),
        StatusCode::OK
    );
    let deleted_path = format!("{endpoint}/assessSource?id={deleted_id}&sources=true");
    let unchanged_deletion = fixture.read(&deleted_path).await;
    assert_eq!(unchanged_deletion["assessment"]["freshness"], "unchanged");
    assert!(unchanged_deletion["baseline"].is_null());
    assert_eq!(unchanged_deletion["original"]["text"], original);
    fs::write(root.join("hello.go"), original).unwrap();
    assert_eq!(
        fixture.read(&deleted_path).await["assessment"]["freshness"],
        "changed"
    );

    let unicode = "\u{feff}heading\r\nα😀 target\r\nend\r\n";
    fs::write(root.join("unicode.txt"), unicode).unwrap();
    let unicode_source = fixture
        .read(&format!("{endpoint}/source?path=unicode.txt"))
        .await;
    let unicode_id = uuid::Uuid::new_v4().to_string();
    let unicode_input = json!({
        "id": unicode_id, "sourceId": unicode_source["id"], "path": "unicode.txt",
        "selection": {"startLineNumber": 2, "startColumn": 2, "endLineNumber": 2, "endColumn": 11},
        "text": "Preserve Unicode coordinates",
    });
    assert_eq!(
        fixture
            .post(&format!("{endpoint}/annotations"), &unicode_input)
            .await
            .status(),
        StatusCode::OK
    );
    fs::write(
        root.join("unicode.txt"),
        "header\nheading\nα😀 target\nend\n",
    )
    .unwrap();
    let moved = fixture
        .read(&format!("{endpoint}/assessSource?id={unicode_id}"))
        .await;
    assert_eq!(moved["freshness"], "moved");
    assert_eq!(
        moved["selection"],
        json!({"startLineNumber": 3, "startColumn": 2, "endLineNumber": 3, "endColumn": 11})
    );
    assert_eq!(
        fixture
            .get(&format!("{assess_path}&path=unicode.txt"))
            .await
            .status(),
        StatusCode::BAD_REQUEST
    );
}

#[tokio::test]
async fn comparisons_separate_index_and_worktree_and_retain_both_annotation_sides() {
    let mut fixture = Fixture::new();
    assert_eq!(
        fixture.login(&fixture.ticket()).await.status(),
        StatusCode::OK
    );
    let (id, directory) = fixture
        .worktree("diff", "package demo\nconst Timeout = 10\n")
        .await;
    let endpoint = format!("worktrees/{id}");
    let unborn = fixture
        .read(&format!(
            "{endpoint}/comparison?scope=uncommitted&path=hello.go"
        ))
        .await;
    assert!(unborn["before"].is_null());
    assert_eq!(
        unborn["after"]["text"],
        "package demo\nconst Timeout = 10\n"
    );
    git(&directory, &["add", "."]);
    let staged_add = fixture
        .read(&format!("{endpoint}/comparison?scope=staged&path=hello.go"))
        .await;
    assert!(staged_add["before"].is_null());
    assert_eq!(
        staged_add["after"]["text"],
        "package demo\nconst Timeout = 10\n"
    );
    fs::remove_file(directory.join("hello.go")).unwrap();
    assert_eq!(
        fixture
            .read(&format!("{endpoint}/changes?scope=uncommitted"))
            .await,
        json!([])
    );
    fs::write(
        directory.join("hello.go"),
        "package demo\nconst Timeout = 10\n",
    )
    .unwrap();
    git(&directory, &["commit", "-qm", "baseline"]);
    fs::write(
        directory.join("hello.go"),
        "package demo\nconst Timeout = 20\n",
    )
    .unwrap();
    git(&directory, &["add", "."]);
    fs::write(
        directory.join("hello.go"),
        "package demo\nconst Timeout = 10\n",
    )
    .unwrap();
    assert_eq!(
        fixture
            .read(&format!("{endpoint}/changes?scope=uncommitted"))
            .await,
        json!([])
    );
    let staged = fixture
        .read(&format!("{endpoint}/comparison?scope=staged&path=hello.go"))
        .await;
    let unstaged = fixture
        .read(&format!(
            "{endpoint}/comparison?scope=unstaged&path=hello.go"
        ))
        .await;
    assert_eq!(
        staged["before"]["text"],
        "package demo\nconst Timeout = 10\n"
    );
    assert_eq!(
        staged["after"]["text"],
        "package demo\nconst Timeout = 20\n"
    );
    assert_eq!(unstaged["before"]["text"], staged["after"]["text"]);
    assert_eq!(unstaged["after"]["text"], staged["before"]["text"]);
    assert_eq!(
        staged["hunks"],
        json!([{"beforeStart": 2, "beforeEnd": 3, "afterStart": 2, "afterEnd": 3}])
    );

    fs::remove_file(directory.join("hello.go")).unwrap();
    let deleted = fixture
        .read(&format!(
            "{endpoint}/comparison?scope=uncommitted&path=hello.go"
        ))
        .await;
    assert!(deleted["after"].is_null());
    for (side, expected) in [("before", "10"), ("after", "20")] {
        let mut input = json!({
            "id": uuid::Uuid::new_v4().to_string(), "sourceId": staged[side]["id"], "path": "hello.go",
            "selection": {"startLineNumber": 2, "startColumn": 17, "endLineNumber": 2, "endColumn": 19},
            "text": "Explain the timeout", "review": {"comparisonId": staged["id"], "side": side}
        });
        let saved: Value = fixture
            .post(&format!("{endpoint}/annotations"), &input)
            .await
            .json()
            .await
            .unwrap();
        assert_eq!(saved["excerpt"], expected, "{saved}");
        input["id"] = json!(uuid::Uuid::new_v4().to_string());
        input["review"]["side"] = json!(if side == "before" { "after" } else { "before" });
        assert_eq!(
            fixture
                .post(&format!("{endpoint}/annotations"), &input)
                .await
                .status(),
            StatusCode::BAD_REQUEST
        );
    }
    fs::write(directory.join(".gitignore"), "ignored.go\n").unwrap();
    fs::write(directory.join("ignored.go"), "ignored").unwrap();
    fs::write(directory.join("empty.go"), "").unwrap();
    let changes = fixture
        .read(&format!("{endpoint}/changes?scope=uncommitted"))
        .await;
    assert!(
        changes
            .as_array()
            .unwrap()
            .iter()
            .any(|entry| entry["path"] == "empty.go")
    );
    assert!(
        !changes
            .as_array()
            .unwrap()
            .iter()
            .any(|entry| entry["path"] == "ignored.go")
    );
    let empty = fixture
        .read(&format!(
            "{endpoint}/comparison?scope=uncommitted&path=empty.go"
        ))
        .await;
    assert!(empty["before"].is_null());
    assert_eq!(empty["after"]["text"], "");
}

#[tokio::test]
async fn go_navigation_uses_current_project_context_and_isolates_linked_worktrees() {
    let mut fixture = Fixture::new();
    assert_eq!(
        fixture.login(&fixture.ticket()).await.status(),
        StatusCode::OK
    );
    let caller = "package demo\nfunc Use() int { _ = \"😀\"; return Limit() }\n";
    let (id, directory) = fixture.worktree("go-main", caller).await;
    fs::write(
        directory.join("go.mod"),
        "module example.com/demo\n\ngo 1.24\n",
    )
    .unwrap();
    fs::write(
        directory.join("limit.go"),
        "package demo\n// Limit bounds retries.\nfunc Limit() int { return 3 }\n",
    )
    .unwrap();
    git(&directory, &["add", "."]);
    git(&directory, &["commit", "-qm", "Go baseline"]);
    let other = fixture._directory.path().join("go-linked");
    git(
        &directory,
        &["worktree", "add", "--detach", other.to_str().unwrap()],
    );
    fs::remove_file(other.join("limit.go")).unwrap();
    fs::write(
        other.join("different.go"),
        "package demo\n// Limit uses another policy.\nfunc Limit() int { return 19 }\n",
    )
    .unwrap();
    let registered: Value = fixture
        .post("worktrees", &json!({"path": other}))
        .await
        .json()
        .await
        .unwrap();
    let other_id = registered["id"].as_str().unwrap();
    fixture.start_service(other_id).await;
    let endpoint = format!("worktrees/{id}");
    let rejected = fixture
        .get(&format!("{endpoint}/analysisSource?path=hello.go"))
        .await;
    assert_eq!(rejected.status(), StatusCode::BAD_REQUEST);
    assert!(
        rejected
            .text()
            .await
            .unwrap()
            .contains("Enable Go analysis")
    );
    assert_eq!(
        fixture
            .post(&format!("{endpoint}/enableAnalysis"), &json!({}))
            .await
            .status(),
        StatusCode::OK
    );
    let current = fixture
        .read(&format!("{endpoint}/analysisSource?path=hello.go"))
        .await;
    let query = format!(
        "{endpoint}/inspect?path=hello.go&context={}&sourceId={}&line=2&column=38",
        current["context"].as_str().unwrap(),
        current["source"]["id"].as_str().unwrap()
    );
    let definition = fixture.read(&format!("{query}&kind=definition")).await;
    assert_eq!(definition["locations"][0]["source"]["path"], "limit.go");
    assert_eq!(
        definition["locations"][0]["selection"],
        json!({"startLineNumber": 3, "startColumn": 6, "endLineNumber": 3, "endColumn": 11})
    );
    let hover = fixture.read(&format!("{query}&kind=hover")).await;
    assert!(hover["hover"].to_string().contains("Limit bounds retries"));
    let references = fixture
        .read(&format!("{query}&kind=references&includeDeclaration=false"))
        .await;
    assert_eq!(references["locations"].as_array().unwrap().len(), 1);
    assert_eq!(references["locations"][0]["source"]["path"], "hello.go");
    let symbols = fixture.read(&format!("{query}&kind=symbols")).await;
    assert_eq!(symbols["symbols"][0]["name"], "Use");

    let other_endpoint = format!("worktrees/{other_id}");
    assert_eq!(
        fixture
            .get(&format!("{other_endpoint}/analysisSource?path=hello.go"))
            .await
            .status(),
        StatusCode::BAD_REQUEST
    );
    fixture
        .post(&format!("{other_endpoint}/enableAnalysis"), &json!({}))
        .await
        .error_for_status()
        .unwrap();
    let linked = fixture
        .read(&format!("{other_endpoint}/analysisSource?path=hello.go"))
        .await;
    let linked_query = format!(
        "{other_endpoint}/inspect?path=hello.go&context={}&sourceId={}&line=2&column=38&kind=definition",
        linked["context"].as_str().unwrap(),
        linked["source"]["id"].as_str().unwrap()
    );
    assert_eq!(
        fixture.read(&linked_query).await["locations"][0]["source"]["path"],
        "different.go"
    );
    assert_eq!(
        fixture.read(&format!("{query}&kind=definition")).await["locations"][0]["source"]["path"],
        "limit.go"
    );

    fs::write(
        directory.join("limit.go"),
        "package demo\nfunc Limit() string { return \"new\" }\n",
    )
    .unwrap();
    let stale = fixture.get(&format!("{query}&kind=hover")).await;
    assert_eq!(stale.status(), StatusCode::BAD_REQUEST);
    assert!(
        stale
            .text()
            .await
            .unwrap()
            .contains("Analysis context changed")
    );
    let refreshed = fixture
        .read(&format!("{endpoint}/analysisSource?path=hello.go"))
        .await;
    assert_eq!(refreshed["source"]["id"], current["source"]["id"]);
    assert_ne!(refreshed["context"], current["context"]);
    let changed_query = format!(
        "{endpoint}/inspect?path=hello.go&context={}&sourceId={}&line=2&column=38&kind=hover",
        refreshed["context"].as_str().unwrap(),
        refreshed["source"]["id"].as_str().unwrap()
    );
    assert!(
        fixture.read(&changed_query).await["hover"]
            .to_string()
            .contains("string")
    );
}

async fn terminal_call(fixture: &Fixture, endpoint: &str, method: &str, input: Value) -> Value {
    let response = fixture.post(&format!("{endpoint}/{method}"), &input).await;
    let status = response.status();
    let result = response.json().await.unwrap();
    assert_eq!(status, StatusCode::OK, "{method}: {result}");
    result
}

async fn receive_terminal_frame(fixture: &Fixture, endpoint: &str, identity: &Value) -> Value {
    let header = terminal_call(fixture, endpoint, "terminalFrame", identity.clone()).await;
    let mut bytes = Vec::new();
    while bytes.len() < header["length"].as_u64().unwrap() as usize {
        let mut input = identity.clone();
        input["offset"] = json!(bytes.len());
        let chunk = terminal_call(fixture, endpoint, "terminalChunk", input).await;
        bytes.extend(serde_json::from_value::<Vec<u8>>(chunk["bytes"].clone()).unwrap());
    }
    let frame: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(frame["stamp"], header["stamp"]);
    frame
}

async fn terminal_frame(
    fixture: &Fixture,
    endpoint: &str,
    identity: &Value,
    displayed: bool,
) -> Value {
    let frame = receive_terminal_frame(fixture, endpoint, identity).await;
    let mut receipt = identity.clone();
    receipt["stamp"] = frame["stamp"].clone();
    receipt["displayed"] = json!(displayed);
    terminal_call(fixture, endpoint, "terminalAck", receipt).await;
    frame
}

#[tokio::test]
async fn managed_terminal_recovers_partial_frames_lost_receipts_and_paused_readers() {
    use std::os::unix::fs::PermissionsExt;

    let mut fixture = Fixture::new();
    assert_eq!(
        fixture.login(&fixture.ticket()).await.status(),
        StatusCode::OK
    );
    let binary = fixture._directory.path().join("bin");
    fs::create_dir(&binary).unwrap();
    fs::write(
        binary.join("amp"),
        r#"#!/bin/sh
row=0
while [ "$row" -lt 1000 ]; do
    printf 'history %s\n' "$row"
    row=$((row + 1))
done
printf 'READY café\n'
while IFS= read -r line; do
    printf 'RECEIVED:%s\n' "$line"
done
"#,
    )
    .unwrap();
    fs::set_permissions(binary.join("amp"), fs::Permissions::from_mode(0o700)).unwrap();
    let (id, _) = fixture.worktree("managed", "package demo\n").await;
    let endpoint = format!("worktrees/{id}");
    let launch =
        json!({"id": uuid::Uuid::new_v4().to_string(), "dimensions": {"columns": 80, "rows": 24}});
    let session = terminal_call(&fixture, &endpoint, "launchSession", launch.clone()).await;
    assert_eq!(session["status"], "running");
    assert_eq!(
        session,
        terminal_call(&fixture, &endpoint, "launchSession", launch.clone()).await
    );
    let attach = json!({"session": launch["id"]});
    let first = terminal_call(&fixture, &endpoint, "attachTerminal", attach.clone()).await;
    let first = json!({"session": launch["id"], "attachment": first["attachment"], "generation": first["generation"]});
    let mut input = first.clone();
    input["text"] = json!("too-early\n");
    assert_eq!(
        fixture
            .post(&format!("{endpoint}/terminalInput"), &input)
            .await
            .status(),
        StatusCode::BAD_REQUEST
    );
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let frame = terminal_frame(&fixture, &endpoint, &first, true).await;
        if frame["painting"].as_str().unwrap().contains("READY café") {
            break;
        }
        assert!(Instant::now() < deadline, "{frame}");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let header = terminal_call(&fixture, &endpoint, "terminalFrame", first.clone()).await;
    assert!(header["length"].as_u64().unwrap() > 65_536);
    let mut chunk = first.clone();
    chunk["offset"] = json!(0);
    terminal_call(&fixture, &endpoint, "terminalChunk", chunk).await;
    terminal_call(&fixture, &endpoint, "detachTerminal", first.clone()).await;
    fixture.restart_gateway();

    let second = terminal_call(&fixture, &endpoint, "attachTerminal", attach.clone()).await;
    assert_eq!(second["runtime"], session["runtime"]);
    let second = json!({"session": launch["id"], "attachment": second["attachment"], "generation": second["generation"]});
    let recovered = terminal_frame(&fixture, &endpoint, &second, true).await;
    assert!(
        recovered["painting"]
            .as_str()
            .unwrap()
            .contains("READY café"),
        "{recovered}"
    );
    let mut input = second.clone();
    input["text"] = json!("after-reconnect\n");
    terminal_call(&fixture, &endpoint, "terminalInput", input).await;
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let frame = terminal_frame(&fixture, &endpoint, &second, true).await;
        if frame["painting"]
            .as_str()
            .unwrap()
            .contains("RECEIVED:after-reconnect")
        {
            break;
        }
        assert!(Instant::now() < deadline);
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let lost = receive_terminal_frame(&fixture, &endpoint, &second).await;
    let paused = terminal_call(&fixture, &endpoint, "attachTerminal", attach.clone()).await;
    let mut paused = json!({"session": launch["id"], "attachment": paused["attachment"], "generation": paused["generation"], "paused": true});
    terminal_frame(&fixture, &endpoint, &paused, false).await;
    let elapsed = Instant::now();
    while elapsed.elapsed() < Duration::from_secs(32) {
        terminal_call(&fixture, &endpoint, "terminalHeartbeat", paused.clone()).await;
        tokio::time::sleep(Duration::from_secs(1)).await;
    }
    let mut late = second.clone();
    late["stamp"] = lost["stamp"].clone();
    late["displayed"] = json!(true);
    assert_eq!(
        fixture
            .post(&format!("{endpoint}/terminalAck"), &late)
            .await
            .status(),
        StatusCode::BAD_REQUEST
    );
    let mut stale = first.clone();
    stale["stamp"] = header["stamp"].clone();
    stale["displayed"] = json!(true);
    assert_eq!(
        fixture
            .post(&format!("{endpoint}/terminalAck"), &stale)
            .await
            .status(),
        StatusCode::BAD_REQUEST
    );
    let control = terminal_call(&fixture, &endpoint, "claimTerminal", paused.clone()).await;
    paused["generation"] = control["generation"].clone();
    paused["text"] = json!("still-paused\n");
    assert_eq!(
        fixture
            .post(&format!("{endpoint}/terminalInput"), &paused)
            .await
            .status(),
        StatusCode::BAD_REQUEST
    );
    paused["paused"] = json!(false);
    terminal_frame(&fixture, &endpoint, &paused, true).await;
    let viewer = terminal_call(&fixture, &endpoint, "attachTerminal", attach.clone()).await;
    assert_eq!(viewer["control"], false);
    let mut viewer = json!({"session": launch["id"], "attachment": viewer["attachment"], "generation": viewer["generation"]});
    terminal_frame(&fixture, &endpoint, &viewer, true).await;
    let control = terminal_call(&fixture, &endpoint, "claimTerminal", viewer.clone()).await;
    viewer["generation"] = control["generation"].clone();
    assert_eq!(
        fixture
            .post(&format!("{endpoint}/terminalInput"), &paused)
            .await
            .status(),
        StatusCode::BAD_REQUEST
    );
    viewer["text"] = json!("takeover-before-refresh\n");
    assert_eq!(
        fixture
            .post(&format!("{endpoint}/terminalInput"), &viewer)
            .await
            .status(),
        StatusCode::BAD_REQUEST
    );
    let frame = receive_terminal_frame(&fixture, &endpoint, &viewer).await;
    let mut receipt = viewer.clone();
    receipt["stamp"] = frame["stamp"].clone();
    assert_eq!(
        fixture
            .post(&format!("{endpoint}/terminalAck"), &receipt)
            .await
            .status(),
        StatusCode::BAD_REQUEST
    );
    receipt["displayed"] = json!(true);
    terminal_call(&fixture, &endpoint, "terminalAck", receipt).await;
    viewer["dimensions"] = json!({"columns": 73, "rows": 19});
    terminal_call(&fixture, &endpoint, "resizeTerminal", viewer.clone()).await;
    assert_eq!(
        fixture
            .post(&format!("{endpoint}/terminalInput"), &viewer)
            .await
            .status(),
        StatusCode::BAD_REQUEST
    );
    let frame = terminal_frame(&fixture, &endpoint, &viewer, true).await;
    assert_eq!(frame["dimensions"], json!({"columns": 73, "rows": 19}));
    terminal_call(&fixture, &endpoint, "stopSession", viewer).await;
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let sessions = fixture.read(&format!("{endpoint}/managedSessions")).await;
        if sessions[0]["status"] == "exited" {
            break;
        }
        assert!(Instant::now() < deadline);
        tokio::time::sleep(Duration::from_millis(20)).await;
    }

    let mut surviving_launch = launch.clone();
    surviving_launch["id"] = json!(uuid::Uuid::new_v4().to_string());
    let surviving = terminal_call(
        &fixture,
        &endpoint,
        "launchSession",
        surviving_launch.clone(),
    )
    .await;
    let database = rusqlite::Connection::open(
        fixture
            .state
            .join("worktrees")
            .join(&id)
            .join("sessions.sqlite"),
    )
    .unwrap();
    for _ in 0..100 {
        let mut failed_launch = launch.clone();
        failed_launch["id"] = json!(uuid::Uuid::new_v4().to_string());
        let failed = json!({"launch": failed_launch, "runtime": null, "status": "failed", "detail": "Amp executable unavailable"});
        database
            .execute(
                "INSERT INTO sessions(id,payload) VALUES (?1,?2)",
                rusqlite::params![failed_launch["id"].as_str().unwrap(), failed.to_string()],
            )
            .unwrap();
    }
    let sessions = fixture.read(&format!("{endpoint}/managedSessions")).await;
    assert_eq!(sessions[0], surviving);
    drop(fixture.services.pop().unwrap());
    fixture.start_service(&id).await;
    let reconciled = terminal_call(&fixture, &endpoint, "launchSession", surviving_launch).await;
    assert_eq!(reconciled["status"], "lost");
    assert_eq!(reconciled["runtime"], surviving["runtime"]);
}
