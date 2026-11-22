use anyhow::{Context, Result, bail, ensure};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{collections::BTreeSet, fs, io::ErrorKind, path::Path, process::Stdio, time::Duration};
use tokio::{
    io::AsyncReadExt,
    process::{Child, Command},
    sync::mpsc,
};

use crate::{
    model::{
        BUILD_ID, BuildInfo, ConnectionEvent, DirectoryPage, Machine, MachineStatus,
        SshDestination, VERSION,
    },
    process, state, transport,
};

const REMOTE_COMMAND: &str = r#"exec sh -c '
if [ -n "$1" ] && [ -x "$HOME/.local/share/tether/installations/$1/bin/tether" ]; then
    exec "$HOME/.local/share/tether/installations/$1/bin/tether" machine-rpc
fi
if [ -x "$HOME/.local/share/tether/installations/current/bin/tether" ]; then
    exec "$HOME/.local/share/tether/installations/current/bin/tether" machine-rpc
fi
if command -v tether >/dev/null 2>&1; then
    exec tether machine-rpc
fi
for executable in "$HOME/.nix-profile/bin/tether" \
    "/etc/profiles/per-user/$(id -un)/bin/tether" \
    "/run/current-system/sw/bin/tether"; do
    if [ -x "$executable" ]; then
        exec "$executable" machine-rpc
    fi
done
echo "Connected over SSH. Tether setup is required on this machine." >&2
exit 78
' tether"#;

const SSH_OPTIONS: &[&str] = &[
    "-T",
    "-o",
    "BatchMode=yes",
    "-o",
    "StrictHostKeyChecking=yes",
    "-o",
    "ConnectTimeout=10",
    "-o",
    "ServerAliveInterval=5",
    "-o",
    "ServerAliveCountMax=2",
    "-o",
    "ClearAllForwardings=yes",
];

#[derive(Debug)]
struct MissingRemote;

impl std::fmt::Display for MissingRemote {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("Connected over SSH. Tether setup is required on this machine")
    }
}

impl std::error::Error for MissingRemote {}

fn remote_expression() -> Option<String> {
    std::env::var("TETHER_REMOTE_EXPRESSION").ok()
}

fn installation_key(expression: &str) -> Result<&str> {
    ensure!(
        expression.starts_with("/nix/store/"),
        "Tether bootstrap source must be in the Nix store"
    );
    Path::new(expression)
        .file_name()
        .and_then(|name| name.to_str())
        .context("Invalid Tether bootstrap source")
}

fn ssh_command(ssh: &SshDestination, script: &str) -> Command {
    let mut command = Command::new("ssh");
    command
        .args(SSH_OPTIONS)
        .arg("--")
        .arg(&ssh.destination)
        .arg(script);
    command
}

async fn report_phase(progress: Option<&mpsc::Sender<ConnectionEvent>>, message: &str) {
    if let Some(sender) = progress {
        let _ = sender
            .send(ConnectionEvent::Progress {
                message: message.into(),
            })
            .await;
    }
}

async fn diagnostics(
    reader: &mut (impl tokio::io::AsyncRead + Unpin),
    progress: Option<&mpsc::Sender<ConnectionEvent>>,
) -> Result<Vec<u8>> {
    let mut tail = Vec::new();
    let mut chunk = [0; 8192];
    loop {
        let length = reader.read(&mut chunk).await?;
        if length == 0 {
            return Ok(tail);
        }
        if let Some(sender) = progress {
            let _ = sender
                .send(ConnectionEvent::Output {
                    text: String::from_utf8_lossy(&chunk[..length]).into_owned(),
                })
                .await;
        }
        tail.extend_from_slice(&chunk[..length]);
        if tail.len() > 8192 {
            tail.drain(..tail.len() - 8192);
        }
    }
}

struct SetupProcess {
    child: Child,
    group: rustix::process::Pid,
}

impl Drop for SetupProcess {
    fn drop(&mut self) {
        let _ = rustix::process::kill_process_group(self.group, rustix::process::Signal::KILL);
    }
}

async fn setup_command(
    mut command: Command,
    phase: &str,
    progress: Option<&mpsc::Sender<ConnectionEvent>>,
) -> Result<String> {
    let child = command
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .process_group(0)
        .kill_on_drop(true)
        .spawn()
        .with_context(|| format!("{phase}: could not start command"))?;
    let group = rustix::process::Pid::from_raw(child.id().unwrap() as i32).unwrap();
    let mut process = SetupProcess { child, group };
    // The remote build watches this pipe for gateway cancellation or disconnection.
    let _stdin = process.child.stdin.take().unwrap();
    let mut stdout = process.child.stdout.take().unwrap();
    let mut stderr = process.child.stderr.take().unwrap();
    tokio::time::timeout(Duration::from_secs(1800), async {
        let mut output = String::new();
        let (read, errors, status) = tokio::join!(
            stdout.read_to_string(&mut output),
            diagnostics(&mut stderr, progress),
            process.child.wait()
        );
        read?;
        let errors = errors?;
        let diagnostics = String::from_utf8_lossy(&errors);
        let message = diagnostics
            .trim()
            .lines()
            .last()
            .unwrap_or("Command exited without diagnostics");
        ensure!(status?.success(), "{phase}: {message}");
        Ok(output)
    })
    .await
    .with_context(|| format!("{phase} timed out. Retry to reuse completed Nix build work"))?
}

async fn install_remote(
    ssh: &SshDestination,
    expected_identity: Option<&str>,
    progress: Option<&mpsc::Sender<ConnectionEvent>>,
) -> Result<()> {
    let expression =
        remote_expression().context("Automatic setup requires the Nix-packaged Tether gateway")?;
    let key = installation_key(&expression)?;
    report_phase(progress, "Checking Nix on the remote machine…").await;
    let probe = r#"exec sh -c '
for executable in "$(command -v nix 2>/dev/null)" "$HOME/.nix-profile/bin/nix" /nix/var/nix/profiles/default/bin/nix /run/current-system/sw/bin/nix; do
    if [ -x "$executable" ]; then
        printf "%s\n" "$executable"
        exit 0
    fi
done
echo "Nix is required on this machine. Install Nix and retry Connect machine." >&2
exit 1
'"#;
    let nix = setup_command(ssh_command(ssh, probe), "Checking remote Nix", progress).await?;
    let nix = nix.trim();
    ensure!(
        Path::new(nix).is_absolute(),
        "Remote Nix returned an invalid executable path"
    );
    let nix_store = Path::new(nix).with_file_name("nix-store");
    let remote_program: String =
        url::form_urlencoded::byte_serialize(nix_store.to_string_lossy().as_bytes()).collect();
    let (account, host) = ssh
        .destination
        .rsplit_once('@')
        .map_or(("", ssh.destination.as_str()), |(account, host)| {
            (account, host)
        });
    let host = if host.contains(':') && !host.starts_with('[') {
        format!("[{host}]")
    } else {
        host.to_owned()
    };
    let authority = if account.is_empty() {
        host
    } else {
        format!("{account}@{host}")
    };
    report_phase(progress, "Transferring pinned Tether sources…").await;
    let mut copy = Command::new("nix");
    copy.args([
        "--extra-experimental-features",
        "nix-command",
        "--log-format",
        "raw",
        "--verbose",
        "copy",
        "--to",
    ])
    .arg(format!("ssh://{authority}?remote-program={remote_program}"))
    .arg(&expression)
    .env("NIX_SSHOPTS", SSH_OPTIONS.join(" "));
    setup_command(copy, "Transferring Tether sources", progress).await?;
    report_phase(progress, "Building and installing Tether with Nix…").await;
    let script = format!(
        r#"set -eu
umask 077
directory="$HOME/.local/share/tether/installations"
mkdir -p "$directory"
exec 3<&0
{} --extra-experimental-features nix-command --log-format raw-with-logs build --impure --file {} --out-link "$directory"/{} < /dev/null 3<&- &
build=$!
(
    read -r disconnect <&3 || :
    kill "$build" 2>/dev/null || :
) &
watcher=$!
trap 'kill "$build" "$watcher" 2>/dev/null || :' EXIT HUP INT TERM
result=0
wait "$build" || result=$?
kill "$watcher" 2>/dev/null || :
wait "$watcher" 2>/dev/null || :
trap - EXIT HUP INT TERM
exit "$result"
"#,
        shlex::try_quote(nix)?,
        shlex::try_quote(&expression)?,
        shlex::try_quote(key)?
    );
    let script = format!("exec sh -c {}", shlex::try_quote(&script)?);
    setup_command(
        ssh_command(ssh, &script),
        "Building remote Tether",
        progress,
    )
    .await?;
    report_phase(progress, "Verifying the installed Tether build…").await;
    let (machine, build) = remote_identity(ssh).await?;
    ensure!(
        expected_identity.is_none_or(|id| machine.id == id),
        "Remote machine identity changed. Reconnect this machine explicitly"
    );
    ensure!(
        build.build_id.as_deref() == Some(BUILD_ID) && build.version == VERSION,
        "Installed Tether build does not match this gateway"
    );
    let activate = format!(
        "ln -sfn {} \"$HOME/.local/share/tether/installations/current\"",
        shlex::try_quote(key)?
    );
    setup_command(
        ssh_command(ssh, &activate),
        "Activating remote Tether",
        progress,
    )
    .await?;
    Ok(())
}

#[derive(Default, Deserialize, Serialize)]
pub struct DirectoryInput {
    pub path: Option<String>,
    #[serde(default)]
    pub offset: usize,
    #[serde(default)]
    pub hidden: bool,
}

pub fn identity(directory: &Path) -> Result<Machine> {
    let id =
        state::gateway_database(directory)?
            .query_row("SELECT id FROM identity", [], |row| row.get(0))?;
    let hostname = std::process::Command::new("uname").arg("-n").output()?;
    let account = std::process::Command::new("id").arg("-un").output()?;
    ensure!(
        hostname.status.success() && account.status.success(),
        "Could not identify this machine and account"
    );
    Ok(Machine {
        id,
        host: String::from_utf8(hostname.stdout)?.trim().into(),
        account: String::from_utf8(account.stdout)?.trim().into(),
        ssh: None,
    })
}

pub fn inventory(directory: &Path) -> Result<Vec<Machine>> {
    let mut local = identity(directory)?;
    local.id = "local".into();
    let mut machines = vec![local];
    let connection = state::gateway_database(directory)?;
    let mut query = connection.prepare("SELECT configuration FROM machines ORDER BY id")?;
    for row in query.query_map([], |row| row.get::<_, String>(0))? {
        machines.push(serde_json::from_str(&row?)?);
    }
    Ok(machines)
}

pub fn configured_hosts() -> Result<Vec<String>> {
    let home = std::env::var_os("HOME").context("HOME is required to read SSH configuration")?;
    let path = Path::new(&home).join(".ssh/config");
    let configuration = match fs::read_to_string(&path) {
        Ok(configuration) => configuration,
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => return Err(error).context("Could not read ~/.ssh/config"),
    };
    let mut hosts = BTreeSet::new();
    for (index, line) in configuration.lines().enumerate() {
        let line = line.trim_start();
        let Some((keyword, arguments)) = line.split_once([' ', '\t', '=']) else {
            continue;
        };
        if !keyword.eq_ignore_ascii_case("host") {
            continue;
        }
        let arguments = arguments.trim_start_matches([' ', '\t', '=']);
        let aliases = shlex::split(arguments).with_context(|| {
            format!(
                "Invalid Host quoting in ~/.ssh/config at line {}",
                index + 1
            )
        })?;
        for alias in aliases {
            if !alias.is_empty() && !alias.contains(['*', '?', '!', '[', ']']) {
                hosts.insert(alias);
            }
        }
    }
    Ok(hosts.into_iter().collect())
}

fn find(directory: &Path, id: &str) -> Result<Machine> {
    let configuration: String = state::gateway_database(directory)?
        .query_row(
            "SELECT configuration FROM machines WHERE id=?1",
            [id],
            |row| row.get(0),
        )
        .context("Unknown machine")?;
    Ok(serde_json::from_str(&configuration)?)
}

pub async fn connect(
    directory: &Path,
    ssh: SshDestination,
    progress: Option<&mpsc::Sender<ConnectionEvent>>,
) -> Result<Machine> {
    ensure!(
        !ssh.destination.is_empty()
            && ssh.destination.len() <= 255
            && !ssh.destination.starts_with('-')
            && ssh
                .destination
                .chars()
                .all(|ch| ch.is_ascii_alphanumeric() || "@._-:[]%+".contains(ch)),
        "Enter an SSH host alias or user@host"
    );
    report_phase(progress, "Connecting over SSH…").await;
    let identity = match ssh_request(&ssh, None, "identity", json!({})).await {
        Ok(identity) => identity,
        Err(error) if error.is::<MissingRemote>() => {
            install_remote(&ssh, None, progress).await?;
            report_phase(progress, "Checking the remote Tether handshake…").await;
            ssh_request(&ssh, None, "identity", json!({})).await?
        }
        Err(error) => return Err(error),
    };
    let mut machine: Machine = serde_json::from_value(identity)?;
    ensure!(
        uuid::Uuid::parse_str(&machine.id).is_ok(),
        "Invalid remote machine identity"
    );
    report_phase(progress, "Registering the machine…").await;
    machine.ssh = Some(ssh);
    state::gateway_database(directory)?.execute(
        "INSERT INTO machines VALUES (?1, ?2) ON CONFLICT(id) DO UPDATE SET configuration=excluded.configuration",
        rusqlite::params![machine.id, serde_json::to_string(&machine)?],
    )?;
    Ok(machine)
}

async fn ssh_request(
    ssh: &SshDestination,
    identity: Option<&str>,
    method: &str,
    input: Value,
) -> Result<Value> {
    ssh_reply(ssh, identity, method, input)
        .await?
        .into_result(1)
}

async fn ssh_reply(
    ssh: &SshDestination,
    identity: Option<&str>,
    method: &str,
    input: Value,
) -> Result<transport::Reply> {
    let expression = remote_expression();
    let key = expression
        .as_deref()
        .map(installation_key)
        .transpose()?
        .unwrap_or("");
    let remote_command = format!("{REMOTE_COMMAND} {}", shlex::try_quote(key)?);
    let mut child = ssh_command(ssh, &remote_command)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .context("Could not start system SSH")?;
    let mut stdin = child.stdin.take().unwrap();
    let mut stdout = child.stdout.take().unwrap();
    let mut stderr = child.stderr.take().unwrap();
    let request = transport::Request {
        jsonrpc: "2.0".into(),
        id: 1,
        version: VERSION.into(),
        method: method.into(),
        params: json!({"identity": identity, "input": input}),
    };
    let exchange_result = async {
        let exchange = async {
            transport::write(&mut stdin, &request).await?;
            drop(stdin);
            transport::read::<transport::Reply>(&mut stdout).await
        };
        let (reply, diagnostics, status) =
            tokio::join!(exchange, diagnostics(&mut stderr, None), child.wait());
        let diagnostics = diagnostics?;
        let status = status?;
        if status.code() == Some(78) {
            return Err(MissingRemote.into());
        }
        ensure!(
            status.success(),
            "SSH to {} failed. Confirm host trust, authentication and the remote Tether executable with ssh. {}",
            ssh.destination,
            String::from_utf8_lossy(&diagnostics).trim()
        );
        let reply = reply.context("Remote Tether returned an invalid response")?;
        ensure!(
            reply.jsonrpc == "2.0" && reply.id == 1,
            "Invalid remote response identity"
        );
        Ok(reply)
    };
    tokio::time::timeout(Duration::from_secs(65), exchange_result)
        .await
        .context("Remote request timed out. Check the SSH connection and retry")?
}

async fn remote_identity(ssh: &SshDestination) -> Result<(Machine, BuildInfo)> {
    let reply = ssh_reply(ssh, None, "identity", json!({})).await?;
    if let Some(error) = reply.error {
        bail!(error.message);
    }
    let value = reply.result.context("Remote identity is missing")?;
    let build = BuildInfo {
        version: reply.version,
        build_id: value["buildId"].as_str().map(str::to_owned),
    };
    Ok((serde_json::from_value(value)?, build))
}

pub async fn status(directory: &Path, id: &str) -> Result<MachineStatus> {
    let mut status = MachineStatus {
        installed: Some(BuildInfo::current()),
        expected: BuildInfo::current(),
        can_update: false,
        updating: false,
    };
    if id == "local" {
        return Ok(status);
    }
    let machine = find(directory, id)?;
    let ssh = machine
        .ssh
        .context("Saved machine has no SSH destination")?;
    status.can_update = remote_expression().is_some();
    status.updating = match state::lock(&directory.join(format!("update-{id}.lock"))) {
        Ok(_) => false,
        Err(error)
            if error
                .downcast_ref::<std::io::Error>()
                .is_some_and(|error| error.kind() == ErrorKind::WouldBlock) =>
        {
            true
        }
        Err(error) => return Err(error),
    };
    status.installed = match remote_identity(&ssh).await {
        Ok((remote, build)) => {
            ensure!(
                remote.id == machine.id,
                "Remote machine identity changed. Reconnect this machine explicitly"
            );
            Some(build)
        }
        Err(error) if error.is::<MissingRemote>() => None,
        Err(error) => return Err(error),
    };
    Ok(status)
}

pub async fn update(
    directory: &Path,
    id: &str,
    progress: Option<&mpsc::Sender<ConnectionEvent>>,
) -> Result<Machine> {
    ensure!(
        id != "local",
        "Update the local gateway through its installer"
    );
    let machine = find(directory, id)?;
    let ssh = machine
        .ssh
        .as_ref()
        .context("Saved machine has no SSH destination")?;
    let _lock = state::lock(&directory.join(format!("update-{id}.lock")))
        .context("A machine update is already running")?;
    report_phase(progress, "Checking the remote machine…").await;
    match remote_identity(ssh).await {
        Ok((remote, build)) => {
            ensure!(
                remote.id == machine.id,
                "Remote machine identity changed. Reconnect this machine explicitly"
            );
            if build.build_id.as_deref() == Some(BUILD_ID) && build.version == VERSION {
                return Ok(machine);
            }
        }
        Err(error) if error.is::<MissingRemote>() => {}
        Err(error) => return Err(error),
    }
    install_remote(ssh, Some(&machine.id), progress).await?;
    Ok(machine)
}

pub async fn request(
    directory: &Path,
    machine_id: &str,
    method: &str,
    input: Value,
) -> Result<Value> {
    if machine_id == "local" {
        return execute(directory, method, input).await;
    }
    let machine = find(directory, machine_id)?;
    let ssh = machine
        .ssh
        .context("Saved machine has no SSH destination")?;
    ssh_request(&ssh, Some(&machine.id), method, input).await
}

async fn execute(directory: &Path, method: &str, input: Value) -> Result<Value> {
    match method {
        "identity" => {
            let mut identity = json!(identity(directory)?);
            identity["buildId"] = BUILD_ID.into();
            Ok(identity)
        }
        "directories" => {
            let input = serde_json::from_value(input)?;
            Ok(json!(
                tokio::task::spawn_blocking(move || list_directories(input)).await??
            ))
        }
        "worktrees" => Ok(json!(state::worktrees(directory)?)),
        "register" => {
            let path = input["path"]
                .as_str()
                .context("Worktree path required")?
                .to_owned();
            ensure!(
                Path::new(&path).is_absolute(),
                "An absolute worktree path is required"
            );
            let directory = directory.to_owned();
            Ok(json!(
                tokio::task::spawn_blocking(move || state::register(&directory, Path::new(&path)))
                    .await??
            ))
        }
        "worktree" => {
            process::worktree_request(
                directory,
                input["id"].as_str().context("Worktree ID required")?,
                input["method"]
                    .as_str()
                    .context("Worktree operation required")?,
                input["params"].clone(),
            )
            .await
        }
        _ => bail!("Unknown machine operation"),
    }
}

pub async fn serve(directory: &Path) -> Result<()> {
    let request: transport::Request = tokio::time::timeout(
        Duration::from_secs(15),
        transport::read(&mut tokio::io::stdin()),
    )
    .await??;
    let outcome = async {
        if request.method == "identity" {
            ensure!(request.jsonrpc == "2.0", "JSON-RPC 2.0 required");
        } else {
            request.validate()?;
        }
        if request.method != "identity" {
            ensure!(
                request.params["identity"].as_str() == Some(&identity(directory)?.id),
                "Remote machine identity changed. Reconnect this machine explicitly"
            );
        }
        execute(directory, &request.method, request.params["input"].clone()).await
    }
    .await;
    transport::respond(&mut tokio::io::stdout(), request.id, outcome).await
}

fn list_directories(input: DirectoryInput) -> Result<DirectoryPage> {
    let requested = input
        .path
        .filter(|path| !path.is_empty())
        .or_else(|| std::env::var("HOME").ok())
        .context("Home directory unavailable. Enter an absolute path")?;
    ensure!(
        Path::new(&requested).is_absolute(),
        "An absolute directory path is required"
    );
    let path = fs::canonicalize(&requested)
        .with_context(|| format!("Could not open directory {requested}"))?;
    let contents =
        fs::read_dir(&path).with_context(|| format!("Could not list directory {requested}"))?;
    let mut entries = Vec::new();
    let mut skipped = 0;
    for (index, entry) in contents.enumerate() {
        ensure!(
            index < 20_000,
            "Directory exceeds 20,000 entries. Enter a more specific path"
        );
        let entry = entry?;
        let Ok(name) = entry.file_name().into_string() else {
            skipped += 1;
            continue;
        };
        if !input.hidden && name.starts_with('.') {
            continue;
        }
        match fs::metadata(entry.path()) {
            Ok(metadata) if metadata.is_dir() => entries.push(name),
            Ok(_) => {}
            Err(_) => skipped += 1,
        }
    }
    entries.sort();
    let end = input.offset.saturating_add(200).min(entries.len());
    let next_offset = (end < entries.len()).then_some(end);
    let entries = entries.into_iter().skip(input.offset).take(200).collect();
    Ok(DirectoryPage {
        path: path
            .to_str()
            .context("Directory path must be UTF-8")?
            .into(),
        parent: path
            .parent()
            .map(|parent| parent.to_string_lossy().into_owned()),
        entries,
        next_offset,
        skipped,
    })
}
