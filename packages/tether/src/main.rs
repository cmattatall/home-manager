mod analysis;
mod discussion;
mod feedback;
mod gateway;
mod machine;
mod model;
mod process;
mod repository;
mod service;
mod state;
mod syntax;
mod transport;

use anyhow::{Context, Result, ensure};
use clap::{Parser, Subcommand};
use serde_json::json;
use std::{path::PathBuf, process::Command, time::Duration};

#[derive(Parser)]
#[command(version, about)]
struct Arguments {
    #[arg(long, global = true)]
    state_dir: Option<PathBuf>,
    #[arg(long, global = true, default_value_t = 47831)]
    port: u16,
    #[arg(long)]
    no_browser: bool,
    #[command(subcommand)]
    command: Option<Action>,
}

#[derive(Subcommand)]
enum Action {
    /// Register a local Git worktree for source review.
    Register { path: PathBuf },
    /// Stop the local gateway. Worktree services retain their independent lifetime.
    Quit,
    /// List registered local worktrees as JSON.
    List,
    /// Submit an agent's addressed response using a feedback authorization.
    Respond {
        #[arg(long)]
        worktree: String,
        #[arg(long)]
        input: PathBuf,
    },
    /// Emit the browser's TypeScript wire types.
    Schema,
    /// Run the gateway in the foreground.
    Gateway,
    #[command(hide = true)]
    MachineRpc,
    #[command(hide = true)]
    Service {
        #[arg(long)]
        id: String,
    },
}

#[tokio::main]
async fn main() -> Result<()> {
    let arguments = Arguments::parse();
    if matches!(arguments.command, Some(Action::Schema)) {
        print!("{}", model::typescript());
        return Ok(());
    }
    let directory = match arguments.state_dir {
        Some(directory) => directory,
        None => {
            let home = std::env::var_os("XDG_STATE_HOME")
                .map(PathBuf::from)
                .or_else(|| {
                    std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".local/state"))
                })
                .context("Set HOME, XDG_STATE_HOME or --state-dir")?;
            home.join("tether")
        }
    };
    state::private_directory(&directory)?;
    let directory = directory.canonicalize()?;
    match arguments.command {
        Some(Action::Gateway) => gateway::run(directory, arguments.port).await,
        Some(Action::MachineRpc) => machine::serve(&directory).await,
        Some(Action::Service { id }) => service::run(directory, id).await,
        Some(Action::Register { path }) => {
            println!(
                "{}",
                serde_json::to_string_pretty(&state::register(&directory, &path)?)?
            );
            Ok(())
        }
        Some(Action::List) => {
            println!(
                "{}",
                serde_json::to_string_pretty(&state::worktrees(&directory)?)?
            );
            Ok(())
        }
        Some(Action::Respond { worktree, input }) => {
            use std::io::Read;
            let mut bytes = Vec::new();
            std::fs::File::open(input)?
                .take(65_537)
                .read_to_end(&mut bytes)?;
            ensure!(bytes.len() <= 65_536, "Response input exceeds 64 KiB");
            let response: model::AgentResponseInput = serde_json::from_slice(&bytes)?;
            let result = process::worktree_request(
                &directory,
                &worktree,
                "respond",
                serde_json::to_value(response)?,
            )
            .await?;
            println!("{}", serde_json::to_string_pretty(&result)?);
            Ok(())
        }
        Some(Action::Quit) => {
            transport::call(&directory.join("gateway.sock"), "stop", json!({})).await?;
            Ok(())
        }
        Some(Action::Schema) => unreachable!(),
        None => {
            let endpoint = directory.join("gateway.sock");
            if tokio::net::UnixStream::connect(&endpoint).await.is_err() {
                let mut child = process::spawn(
                    &directory,
                    &["--port", &arguments.port.to_string(), "gateway"],
                    "gateway.log",
                )?;
                for _ in 0..100 {
                    if tokio::net::UnixStream::connect(&endpoint).await.is_ok() {
                        break;
                    }
                    if let Some(status) = child.try_wait()? {
                        ensure!(
                            status.success(),
                            "Gateway startup failed. Inspect {}",
                            directory.join("gateway.log").display()
                        );
                    }
                    tokio::time::sleep(Duration::from_millis(50)).await;
                }
            }
            let login = transport::call(&endpoint, "login", json!({})).await?;
            let origin = login["origin"].as_str().context("Gateway origin missing")?;
            let ticket = login["ticket"].as_str().context("Login ticket missing")?;
            let client = reqwest::Client::builder()
                .no_proxy()
                .redirect(reqwest::redirect::Policy::none())
                .timeout(Duration::from_secs(5))
                .build()?;
            let identity: serde_json::Value = client
                .get(format!("{origin}/identity"))
                .send()
                .await?
                .error_for_status()?
                .json()
                .await?;
            ensure!(
                identity["instance"] == login["instance"] && identity["version"] == model::VERSION,
                "Gateway HTTP identity mismatch"
            );
            let registered = state::worktrees(&directory)?;
            let current_root = repository::root(&std::env::current_dir()?).ok();
            let target = current_root.as_ref().and_then(|root| {
                registered
                    .iter()
                    .find(|worktree| std::path::Path::new(&worktree.path) == root)
            });
            let path =
                target.map_or_else(String::new, |worktree| format!("worktrees/{}", worktree.id));
            let mut url = reqwest::Url::parse(&format!("{origin}/{path}"))?;
            url.query_pairs_mut().append_pair("ticket", ticket);
            if target.is_none()
                && let Some(root) = current_root
            {
                url.query_pairs_mut().append_pair(
                    "register",
                    root.to_str().context("Worktree path must be UTF-8")?,
                );
            }
            let fragment = url.query().unwrap().to_owned();
            url.set_query(None);
            url.set_fragment(Some(&fragment));
            if arguments.no_browser {
                println!("{url}");
            } else {
                let opener = if cfg!(target_os = "macos") {
                    "open"
                } else {
                    "xdg-open"
                };
                ensure!(
                    Command::new(opener).arg(url.as_str()).status()?.success(),
                    "Browser launch failed. Use --no-browser to print a login link"
                );
                println!("Tether: {origin}");
            }
            Ok(())
        }
    }
}
