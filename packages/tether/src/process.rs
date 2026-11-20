use anyhow::{Context, Result, ensure};
use serde_json::{Value, json};
use std::{
    fs::OpenOptions, os::unix::fs::OpenOptionsExt, path::Path, process::Stdio, time::Duration,
};
use tokio::process::{Child, Command};

use crate::{service, state, transport};

pub fn spawn(state_directory: &Path, arguments: &[&str], log_name: &str) -> Result<Child> {
    let output = OpenOptions::new()
        .create(true)
        .append(true)
        .mode(0o600)
        .open(state_directory.join(log_name))?;
    Ok(Command::new(std::env::current_exe()?)
        .arg("--state-dir")
        .arg(state_directory)
        .args(arguments)
        .stdin(Stdio::null())
        .stdout(output.try_clone()?)
        .stderr(output)
        .process_group(0)
        .spawn()?)
}

pub async fn worktree_request(
    state_directory: &Path,
    id: &str,
    method: &str,
    params: Value,
) -> Result<Value> {
    let expected = state::find_worktree(state_directory, id)?;
    let startup_path = state_directory.join(format!("startup-{}.lock", expected.id));
    let startup = tokio::time::timeout(Duration::from_secs(10), async {
        loop {
            match state::lock(&startup_path) {
                Ok(lock) => break Ok(lock),
                Err(error)
                    if error
                        .downcast_ref::<std::io::Error>()
                        .is_some_and(|error| error.kind() == std::io::ErrorKind::WouldBlock) =>
                {
                    tokio::time::sleep(Duration::from_millis(50)).await;
                }
                Err(error) => break Err(error),
            }
        }
    })
    .await
    .context("Worktree startup is busy. Retry the request")??;
    let endpoint = service::socket(state_directory, id);
    let info = match transport::call(&endpoint, "info", json!({})).await {
        Ok(info) => info,
        Err(error)
            if error.downcast_ref::<std::io::Error>().is_some_and(|error| {
                matches!(
                    error.kind(),
                    std::io::ErrorKind::NotFound | std::io::ErrorKind::ConnectionRefused
                )
            }) =>
        {
            let mut child = spawn(
                state_directory,
                &["service", "--id", id],
                &format!("service-{id}.log"),
            )?;
            for _ in 0..100 {
                if transport::call(&endpoint, "info", json!({})).await.is_ok() {
                    break;
                }
                if let Some(status) = child.try_wait()? {
                    ensure!(
                        status.success(),
                        "Worktree service failed to start. Inspect its log in {}",
                        state_directory.display()
                    );
                }
                tokio::time::sleep(Duration::from_millis(50)).await;
            }
            tokio::spawn(async move { child.wait().await });
            transport::call(&endpoint, "info", json!({}))
                .await
                .context("Worktree service unavailable")?
        }
        Err(error) => return Err(error),
    };
    ensure!(
        info["id"] == expected.id && info["path"] == expected.path,
        "Worktree service identity mismatch"
    );
    drop(startup);
    transport::call(&endpoint, method, params).await
}
