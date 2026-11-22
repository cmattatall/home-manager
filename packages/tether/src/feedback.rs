use anyhow::{Context, Result, ensure};
use chrono::Utc;
use futures_util::{StreamExt, stream};
use reqwest::{Client, StatusCode};
use rusqlite::{OptionalExtension, params};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    collections::{BTreeMap, HashSet},
    fs,
    os::unix::fs::{MetadataExt, PermissionsExt},
    path::{Path, PathBuf},
    time::Duration,
};

use crate::{
    model::{
        AmpSession, Annotation, DeliveryStatus, Feedback, FeedbackInput, FeedbackPreview, Worktree,
    },
    state,
};

const MAX_CONTENT: usize = 256 * 1024;

#[derive(Deserialize)]
struct Descriptor {
    version: u32,
    url: String,
    token: String,
    root: String,
    thread: String,
    #[serde(default)]
    title: String,
}

struct Connection {
    session: AmpSession,
    descriptor: Descriptor,
    path: PathBuf,
}

pub(crate) struct Delivery {
    directory: PathBuf,
    worktree: Worktree,
    client: Client,
    response_command: String,
}

fn private(path: &Path, directory: bool) -> Result<()> {
    let metadata = fs::symlink_metadata(path)?;
    ensure!(
        if directory {
            metadata.is_dir()
        } else {
            metadata.is_file()
        } && metadata.uid() == rustix::process::getuid().as_raw()
            && metadata.permissions().mode() & 0o077 == 0,
        "Amp registry entries must be private and owned by this account"
    );
    Ok(())
}

fn load(path: &Path, worktree: &Worktree) -> Result<Connection> {
    private(
        path.parent().context("Amp session directory required")?,
        true,
    )?;
    private(path, false)?;
    ensure!(
        fs::metadata(path)?.len() <= 65536,
        "Amp descriptor is too large"
    );
    let bytes = fs::read(path)?;
    let descriptor: Descriptor = serde_json::from_slice(&bytes)?;
    let url = url::Url::parse(&descriptor.url)?;
    let port = url.port().context("Amp endpoint needs a port")?;
    ensure!(
        descriptor.url == format!("http://127.0.0.1:{port}/feedback")
            && descriptor.version == 1
            && descriptor.thread.starts_with("T-")
            && descriptor.thread.len() <= 256
            && descriptor.title.len() <= 1024
            && !descriptor.token.is_empty()
            && descriptor
                .token
                .bytes()
                .all(|byte| (33..=126).contains(&byte))
            && fs::canonicalize(&descriptor.root)? == fs::canonicalize(&worktree.path)?,
        "Amp connection does not match this worktree"
    );
    Ok(Connection {
        session: AmpSession {
            id: state::digest(&bytes),
            thread: descriptor.thread.clone(),
            title: descriptor.title.clone(),
        },
        descriptor,
        path: path.to_owned(),
    })
}

impl Delivery {
    pub(crate) fn new(
        directory: PathBuf,
        worktree: Worktree,
        state_directory: &Path,
    ) -> Result<Self> {
        state::database(&directory.join("review.sqlite"))?.execute_batch(
            "CREATE TABLE IF NOT EXISTS feedback (id TEXT PRIMARY KEY, payload TEXT NOT NULL);
             CREATE TABLE IF NOT EXISTS response_authorizations (feedback_id TEXT PRIMARY KEY, token_hash TEXT NOT NULL, revisions TEXT NOT NULL);",
        )?;
        // The packaged launcher supplies tools needed by a newly started service.
        let executable = std::env::current_exe()?.with_file_name("tether");
        let response_command = shlex::try_join([
            executable
                .to_str()
                .context("Executable path must be UTF-8")?,
            "--state-dir",
            state_directory
                .to_str()
                .context("State path must be UTF-8")?,
            "respond",
            "--worktree",
            &worktree.id,
            "--input",
        ])?;
        Ok(Self {
            directory,
            worktree,
            response_command,
            client: Client::builder()
                .no_proxy()
                .redirect(reqwest::redirect::Policy::none())
                .timeout(Duration::from_secs(10))
                .build()?,
        })
    }

    fn connections(&self) -> Result<Vec<Connection>> {
        let registry = PathBuf::from(std::env::var_os("HOME").context("HOME is required")?)
            .join(".cache/rediff/amp");
        if !registry.exists() {
            return Ok(Vec::new());
        }
        private(&registry, true)?;
        let mut connections = Vec::new();
        for entry in fs::read_dir(registry)?.take(256) {
            let entry = entry?;
            if !entry.file_name().to_string_lossy().starts_with("session-") {
                continue;
            }
            if let Ok(connection) = load(&entry.path().join("connection.json"), &self.worktree) {
                connections.push(connection);
            }
        }
        Ok(connections)
    }

    async fn verify(&self, connection: &Connection) -> Result<()> {
        let descriptor = &connection.descriptor;
        let mut response = self
            .client
            .get(&descriptor.url)
            .bearer_auth(&descriptor.token)
            .send()
            .await?;
        ensure!(
            response.status() == StatusCode::OK,
            "Amp identity check failed"
        );
        let mut bytes = Vec::new();
        while let Some(chunk) = response.chunk().await? {
            ensure!(
                bytes.len() + chunk.len() <= 65536,
                "Amp identity response is too large"
            );
            bytes.extend_from_slice(&chunk);
        }
        let identity: Value = serde_json::from_slice(&bytes)?;
        ensure!(
            identity["version"] == descriptor.version
                && identity["root"] == descriptor.root
                && identity["thread"] == descriptor.thread,
            "Amp session identity changed"
        );
        let current = load(&connection.path, &self.worktree)?;
        ensure!(
            current.session.id == connection.session.id,
            "Amp connection changed"
        );
        Ok(())
    }

    async fn sessions(&self) -> Result<Vec<AmpSession>> {
        let mut sessions = Vec::new();
        let mut checks = stream::iter(self.connections()?)
            .map(|connection| async move {
                let verified =
                    tokio::time::timeout(Duration::from_secs(1), self.verify(&connection)).await;
                if matches!(verified, Ok(Ok(()))) {
                    Some(connection.session)
                } else {
                    None
                }
            })
            .buffer_unordered(16);
        while let Some(result) = checks.next().await {
            if let Some(session) = result {
                sessions.push(session);
            }
        }
        sessions.sort_by(|left, right| left.id.cmp(&right.id));
        Ok(sessions)
    }

    fn get(&self, id: &str) -> Result<Option<FeedbackPreview>> {
        let payload: Option<String> = state::database(&self.directory.join("review.sqlite"))?
            .query_row("SELECT payload FROM feedback WHERE id=?1", [id], |row| {
                row.get(0)
            })
            .optional()?;
        payload
            .map(|payload| Ok(serde_json::from_str(&payload)?))
            .transpose()
    }

    fn update(&self, preview: &FeedbackPreview) -> Result<()> {
        state::database(&self.directory.join("review.sqlite"))?.execute(
            "UPDATE feedback SET payload=?2 WHERE id=?1",
            params![preview.feedback.input.id, serde_json::to_string(preview)?],
        )?;
        Ok(())
    }

    async fn prepare(&self, input: FeedbackInput) -> Result<FeedbackPreview> {
        uuid::Uuid::parse_str(&input.id).context("Feedback ID must be a UUID")?;
        if let Some(previous) = self.get(&input.id)? {
            ensure!(
                previous.feedback.input == input,
                "Feedback ID already belongs to another batch"
            );
            return Ok(previous);
        }
        ensure!(
            !input.annotation_ids.is_empty() && input.annotation_ids.len() <= 20,
            "Select between 1 and 20 annotations"
        );
        let unique: HashSet<_> = input.annotation_ids.iter().collect();
        ensure!(
            unique.len() == input.annotation_ids.len(),
            "Select each annotation once"
        );
        let connection = self
            .connections()?
            .into_iter()
            .find(|connection| connection.session.id == input.session_id)
            .context("Selected Amp session is unavailable. Refresh sessions")?;
        self.verify(&connection).await?;
        let mut database = state::database(&self.directory.join("review.sqlite"))?;
        let transaction =
            database.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let mut evidence = Vec::new();
        let mut revisions = BTreeMap::new();
        for id in &input.annotation_ids {
            let payload: String = transaction
                .query_row(
                    "SELECT payload FROM annotations WHERE id=?1 AND expires>?2",
                    params![id, Utc::now().to_rfc3339()],
                    |row| row.get(0),
                )
                .context("Selected annotation is unavailable in this worktree")?;
            let annotation: Annotation = serde_json::from_str(&payload)?;
            let discussion = crate::discussion::status(&transaction, id)?;
            let mut history_query = transaction.prepare(
                "SELECT payload FROM discussion_events WHERE annotation_id=?1 ORDER BY sequence DESC LIMIT 10",
            )?;
            let rows = history_query.query_map([id], |row| row.get::<_, String>(0))?;
            let recent_activity = rows
                .map(|row| Ok(serde_json::from_str::<Value>(&row?)?))
                .collect::<Result<Vec<_>>>()?;
            revisions.insert(id.clone(), discussion.revision);
            let source = fs::read_to_string(
                self.directory
                    .join("sources")
                    .join(&annotation.input.source_id),
            )?;
            let comparison = if let Some(review) = &annotation.input.review {
                let payload: String = transaction.query_row(
                    "SELECT payload FROM comparisons WHERE id=?1",
                    [&review.comparison_id],
                    |row| row.get(0),
                )?;
                serde_json::from_str::<Value>(&payload)?
            } else {
                Value::Null
            };
            evidence.push(
                json!({"annotation": annotation, "discussion": discussion, "recentActivity": recent_activity, "source": source, "comparison": comparison}),
            );
        }
        let response_token = state::secret();
        let response_template = json!({
            "id": "Generate a UUID for this response and keep it for retries",
            "feedbackId": input.id,
            "annotationId": "Copy the annotation input.id being answered",
            "token": response_token,
            "text": "Explain the fix or answer and the verification performed",
            "paths": [],
        });
        let content = format!(
            concat!(
                "Tether review feedback {}\nWorktree: {}\n\n",
                "Apply the selected review feedback. Check current source before editing. ",
                "Each annotation includes its latest ten review events, newest first. Address follow-up notes in that history. ",
                "For each annotation you address, write a private JSON response file using the template below ",
                "and run the response command on this execution machine. ",
                "Include up to seven additional worktree-relative source paths that explain the change. ",
                "Tether captures the annotated file automatically and retains the source observed when you respond. ",
                "Questions may be addressed with an explanation alone. Human review completes resolution.\n\n",
                "Response command: {} /absolute/path/to/response.json\nResponse input:\n{}\n",
                "Keep the exact input and operation ID when retrying an interrupted response. ",
                "An applied:false result records a reply to an earlier review revision. ",
                "Preserve it and wait for the current request. Remove the private response file after a confirmed result.\n\n{}"
            ),
            input.id,
            self.worktree.path,
            self.response_command,
            serde_json::to_string_pretty(&response_template)?,
            serde_json::to_string_pretty(&evidence)?
        );
        ensure!(
            content.len() <= MAX_CONTENT,
            "Feedback exceeds 256 KiB. Select a smaller batch"
        );
        let preview = FeedbackPreview {
            feedback: Feedback {
                input,
                session: connection.session,
                created_at: Utc::now().to_rfc3339(),
                status: DeliveryStatus::Prepared,
                detail: "Preview saved. Awaiting Send to Amp".into(),
            },
            content,
        };
        transaction.execute(
            "INSERT OR IGNORE INTO feedback VALUES (?1, ?2)",
            params![preview.feedback.input.id, serde_json::to_string(&preview)?],
        )?;
        transaction.execute(
            "INSERT OR IGNORE INTO response_authorizations VALUES (?1, ?2, ?3)",
            params![
                preview.feedback.input.id,
                state::digest(response_token.as_bytes()),
                serde_json::to_string(&revisions)?
            ],
        )?;
        transaction.commit()?;
        let saved = self
            .get(&preview.feedback.input.id)?
            .context("Feedback preview missing")?;
        ensure!(
            saved.feedback.input == preview.feedback.input,
            "Feedback ID already belongs to another batch"
        );
        Ok(saved)
    }

    async fn send(&self, id: &str) -> Result<Feedback> {
        uuid::Uuid::parse_str(id).context("Feedback ID must be a UUID")?;
        let _lock = state::lock(&self.directory.join(format!("feedback-{id}.lock")))
            .context("This feedback is already being checked. Refresh its delivery status")?;
        let mut preview = self
            .get(id)?
            .context("Feedback preview required before sending")?;
        if preview.feedback.status == DeliveryStatus::Accepted {
            return Ok(preview.feedback);
        }
        let connection = self
            .connections()?
            .into_iter()
            .find(|connection| connection.session.id == preview.feedback.input.session_id);
        let Some(connection) = connection else {
            preview.feedback.detail = "Original Amp connection is unavailable. Inspect the target thread before preparing another batch. This attempt sent nothing".into();
            self.update(&preview)?;
            return Ok(preview.feedback);
        };
        self.verify(&connection).await?;
        preview.feedback.status = DeliveryStatus::Uncertain;
        preview.feedback.detail =
            "Delivery outcome is uncertain. Check the original submission".into();
        self.update(&preview)?;
        let response = self
            .client
            .post(&connection.descriptor.url)
            .bearer_auth(&connection.descriptor.token)
            .json(&json!({"id": id, "content": preview.content}))
            .send()
            .await;
        match response {
            Ok(response) if response.status() == StatusCode::NO_CONTENT => {
                preview.feedback.status = DeliveryStatus::Accepted;
                preview.feedback.detail = "Confirmed in the Amp transcript".into();
            }
            Ok(response) if response.status() == StatusCode::ACCEPTED => {
                preview.feedback.detail =
                    "Queued in Amp. Check delivery to confirm transcript visibility".into();
            }
            Ok(response) => {
                preview.feedback.detail = format!(
                    "Amp returned HTTP {}. Check the original submission",
                    response.status()
                );
            }
            Err(_) => {}
        }
        self.update(&preview)?;
        Ok(preview.feedback)
    }

    pub(crate) async fn execute(&self, method: &str, input: Value) -> Result<Value> {
        match method {
            "ampSessions" => Ok(json!(self.sessions().await?)),
            "prepareFeedback" => Ok(json!(self.prepare(serde_json::from_value(input)?).await?)),
            "sendFeedback" => Ok(json!(
                self.send(input["id"].as_str().context("Feedback ID required")?)
                    .await?
            )),
            "feedbackPreview" => Ok(json!(
                self.get(input["id"].as_str().context("Feedback ID required")?)?
                    .context("Feedback preview unavailable")?
            )),
            "feedback" => {
                let connection = state::database(&self.directory.join("review.sqlite"))?;
                let mut statement = connection
                    .prepare("SELECT json_extract(payload, '$.feedback') FROM feedback ORDER BY rowid DESC LIMIT 100")?;
                let rows = statement.query_map([], |row| row.get::<_, String>(0))?;
                let feedback = rows
                    .map(|row| Ok(serde_json::from_str::<Feedback>(&row?)?))
                    .collect::<Result<Vec<_>>>()?;
                Ok(json!(feedback))
            }
            _ => anyhow::bail!("Unknown feedback operation"),
        }
    }
}
