use anyhow::{Context, Result, bail, ensure};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{collections::BTreeSet, fs, io::ErrorKind, path::Path, process::Stdio, time::Duration};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    process::Command,
};

use crate::{
    model::{DirectoryPage, Machine, SshDestination, VERSION},
    process, state, transport,
};

const REMOTE_COMMAND: &str = r#"exec sh -c '
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
echo "Tether is missing on this host. Install this checkout with scripts/install-home-manager.sh on the remote host, then retry." >&2
exit 127
'"#;

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

pub async fn connect(directory: &Path, ssh: SshDestination) -> Result<Machine> {
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
    let mut machine: Machine =
        serde_json::from_value(ssh_request(&ssh, None, "identity", json!({})).await?)?;
    ensure!(
        uuid::Uuid::parse_str(&machine.id).is_ok(),
        "Invalid remote machine identity"
    );
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
    let mut child = Command::new("ssh")
        .args([
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
            "--",
        ])
        .arg(&ssh.destination)
        .arg(REMOTE_COMMAND)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .context("Could not start system SSH")?;
    let mut stdin = child.stdin.take().unwrap();
    let mut stdout = child.stdout.take().unwrap();
    let mut stderr = child.stderr.take().unwrap().take(8192);
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
            stdin.shutdown().await?;
            transport::read::<transport::Reply>(&mut stdout).await
        };
        let mut diagnostics = Vec::new();
        let (reply, diagnostics_read, status) =
            tokio::join!(exchange, stderr.read_to_end(&mut diagnostics), child.wait());
        diagnostics_read?;
        ensure!(
            status?.success(),
            "SSH to {} failed. Confirm host trust, authentication and the remote Tether executable with ssh. {}",
            ssh.destination,
            String::from_utf8_lossy(&diagnostics).trim()
        );
        reply
            .context("Remote Tether returned an invalid response")?
            .into_result(1)
    };
    tokio::time::timeout(Duration::from_secs(65), exchange_result)
        .await
        .context("Remote request timed out. Check the SSH connection and retry")?
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
        "identity" => Ok(json!(identity(directory)?)),
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
        request.validate()?;
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
