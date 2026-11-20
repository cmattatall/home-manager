use reqwest::{Client, StatusCode};
use serde_json::{Value, json};
use std::{
    fs,
    io::{BufRead, BufReader, Write},
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    time::{Duration, Instant},
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
        let child = Command::new(env!("CARGO_BIN_EXE_tether"))
            .arg("--state-dir")
            .arg(&self.state)
            .args(["service", "--id", id])
            .spawn()
            .unwrap();
        self.services.push(Process(child));
        let deadline = Instant::now() + Duration::from_secs(5);
        while tokio::net::UnixStream::connect(self.state.join("s").join(id))
            .await
            .is_err()
        {
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
    assert_eq!(
        fixture.post("logout", &json!({"all": true})).await.status(),
        StatusCode::OK
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
    fixture.start_service(&id).await;
    fixture.restart_gateway();
    let notes: Value = fixture
        .get(&format!("{endpoint}/annotations"))
        .await
        .json()
        .await
        .unwrap();
    assert_eq!(notes, json!([saved]));
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
    let other_notes: Value = fixture
        .get(&format!("worktrees/{other_id}/annotations"))
        .await
        .json()
        .await
        .unwrap();
    assert_eq!(other_notes, json!([]));
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
