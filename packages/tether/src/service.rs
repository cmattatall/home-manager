use anyhow::{Context, Result, bail, ensure};
use chrono::{Months, Utc};
use rusqlite::{OptionalExtension, params};
use serde_json::{Value, json};
use std::{fs, io::Write, os::unix::fs::PermissionsExt, path::PathBuf, time::Duration};
use tokio::net::UnixListener;

use crate::{
    model::{
        Annotation, AnnotationInput, BUILD_ID, Comparison, Hunk, Scope, Selection, Source, Worktree,
    },
    repository, state, transport,
};

pub(crate) struct Store {
    directory: PathBuf,
    worktree: Worktree,
}

impl Store {
    fn open(directory: PathBuf, worktree: Worktree) -> Result<Self> {
        state::private_directory(&directory)?;
        state::private_directory(&directory.join("sources"))?;
        let connection = state::database(&directory.join("review.sqlite"))?;
        connection.execute_batch(
            "CREATE TABLE IF NOT EXISTS sources (id TEXT NOT NULL, path TEXT NOT NULL, PRIMARY KEY(id,path));
             CREATE TABLE IF NOT EXISTS annotations (id TEXT PRIMARY KEY, payload TEXT NOT NULL, expires TEXT NOT NULL);
             CREATE TABLE IF NOT EXISTS comparisons (id TEXT PRIMARY KEY, payload TEXT NOT NULL);
             CREATE TABLE IF NOT EXISTS permissions (name TEXT PRIMARY KEY);",
        )?;
        Ok(Self {
            directory,
            worktree,
        })
    }

    fn source(&self, path: &str) -> Result<Source> {
        let text = repository::source(std::path::Path::new(&self.worktree.path), path)?;
        self.capture(path, text)
    }

    pub(crate) fn capture(&self, path: &str, text: String) -> Result<Source> {
        let id = state::digest(text.as_bytes());
        let blobs = self.directory.join("sources");
        let destination = blobs.join(&id);
        if !destination.exists() {
            let mut temporary = tempfile::NamedTempFile::new_in(&blobs)?;
            temporary.write_all(text.as_bytes())?;
            temporary.as_file().sync_all()?;
            temporary.persist(&destination)?;
            fs::File::open(&blobs)?.sync_all()?;
        }
        state::database(&self.directory.join("review.sqlite"))?.execute(
            "INSERT OR IGNORE INTO sources VALUES (?1, ?2)",
            params![id, path],
        )?;
        Ok(Source {
            id,
            path: path.to_owned(),
            highlights: crate::syntax::highlights(path, &text)?,
            text,
        })
    }

    fn comparison(&self, scope: Scope, path: &str) -> Result<Comparison> {
        let root = std::path::Path::new(&self.worktree.path);
        ensure!(
            repository::changes(root, &scope)?
                .iter()
                .any(|file| file.path == path),
            "File is outside this comparison. Refresh the change list"
        );
        let head = repository::head(root)?;
        let index = repository::git(root, &["ls-files", "--stage", "-z"])?;
        let before = match scope {
            Scope::Unstaged => repository::git_source(root, None, path)?,
            _ => match &head {
                Some(commit) => repository::git_source(root, Some(commit), path)?,
                None => None,
            },
        };
        let after = match scope {
            Scope::Staged => repository::git_source(root, None, path)?,
            _ => repository::working_source(root, path)?,
        };
        ensure!(
            repository::head(root)? == head
                && repository::git(root, &["ls-files", "--stage", "-z"])? == index,
            "Git endpoints changed during capture. Refresh the comparison"
        );
        if scope != Scope::Staged {
            ensure!(
                repository::working_source(root, path)? == after,
                "Source changed during capture. Refresh the comparison"
            );
        }
        let hunks = similar::TextDiff::from_lines(
            before.as_deref().unwrap_or(""),
            after.as_deref().unwrap_or(""),
        )
        .ops()
        .iter()
        .filter(|operation| operation.tag() != similar::DiffTag::Equal)
        .map(|operation| Hunk {
            before_start: operation.old_range().start as u32 + 1,
            before_end: operation.old_range().end as u32 + 1,
            after_start: operation.new_range().start as u32 + 1,
            after_end: operation.new_range().end as u32 + 1,
        })
        .collect();
        let before_label = match scope {
            Scope::Unstaged => format!("Index · {}", &state::digest(&index)[..8]),
            _ => head
                .as_ref()
                .map(|id| format!("HEAD · {}", &id[..8]))
                .unwrap_or("Empty baseline".into()),
        };
        let after_label = if scope == Scope::Staged {
            format!("Index · {}", &state::digest(&index)[..8])
        } else {
            "Saved worktree".into()
        };
        let mut comparison = Comparison {
            id: String::new(),
            scope,
            hunks,
            before_label,
            after_label,
            before: before.map(|text| self.capture(path, text)).transpose()?,
            after: after.map(|text| self.capture(path, text)).transpose()?,
        };
        comparison.id = state::digest(&serde_json::to_vec(&comparison)?);
        state::database(&self.directory.join("review.sqlite"))?.execute(
            "INSERT OR IGNORE INTO comparisons VALUES (?1, ?2)",
            params![comparison.id, serde_json::to_string(&comparison)?],
        )?;
        Ok(comparison)
    }

    pub(crate) fn analysis_allowed(&self) -> Result<bool> {
        Ok(
            state::database(&self.directory.join("review.sqlite"))?.query_row(
                "SELECT EXISTS(SELECT 1 FROM permissions WHERE name='go-analysis')",
                [],
                |row| row.get(0),
            )?,
        )
    }

    fn save(&self, input: AnnotationInput) -> Result<Annotation> {
        uuid::Uuid::parse_str(&input.id).context("Annotation operation ID must be a UUID")?;
        ensure!(
            !input.text.trim().is_empty() && input.text.len() <= 16_384,
            "Annotation must contain 1–16384 bytes of text"
        );
        let mut connection = state::database(&self.directory.join("review.sqlite"))?;
        let transaction =
            connection.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        if let Some(review) = &input.review {
            let payload: String = transaction
                .query_row(
                    "SELECT payload FROM comparisons WHERE id=?1",
                    [&review.comparison_id],
                    |row| row.get(0),
                )
                .context("Comparison was not captured by this worktree")?;
            let comparison: Comparison = serde_json::from_str(&payload)?;
            let source = match review.side.as_str() {
                "before" => comparison.before,
                "after" => comparison.after,
                _ => bail!("Invalid comparison side"),
            }
            .context("Selected comparison side is absent")?;
            ensure!(
                source.id == input.source_id && source.path == input.path,
                "Annotation source does not match its comparison side"
            );
        }
        let previous: Option<String> = transaction
            .query_row(
                "SELECT payload FROM annotations WHERE id=?1",
                [&input.id],
                |row| row.get(0),
            )
            .optional()?;
        if let Some(previous) = previous {
            let annotation: Annotation = serde_json::from_str(&previous)?;
            ensure!(
                annotation.input == input,
                "Operation ID already belongs to different annotation content"
            );
            ensure!(
                annotation.expires_at > Utc::now().to_rfc3339(),
                "Annotation has expired"
            );
            return Ok(annotation);
        }
        let captured: bool = transaction.query_row(
            "SELECT EXISTS(SELECT 1 FROM sources WHERE id=?1 AND path=?2)",
            params![input.source_id, input.path],
            |row| row.get(0),
        )?;
        ensure!(
            captured,
            "Source snapshot was not captured by this worktree service"
        );
        let source = fs::read_to_string(self.directory.join("sources").join(&input.source_id))?;
        let excerpt = selected_text(&source, &input.selection)?.to_owned();
        let created = Utc::now();
        let annotation = Annotation {
            input,
            excerpt,
            created_at: created.to_rfc3339(),
            expires_at: created
                .checked_add_months(Months::new(3))
                .context("Invalid expiry")?
                .to_rfc3339(),
        };
        transaction.execute(
            "INSERT INTO annotations VALUES (?1, ?2, ?3)",
            params![
                annotation.input.id,
                serde_json::to_string(&annotation)?,
                annotation.expires_at
            ],
        )?;
        transaction.commit()?;
        Ok(annotation)
    }

    fn execute(&self, request: transport::Request) -> Result<Value> {
        request.validate()?;
        match request.method.as_str() {
            "info" => Ok(json!(self.worktree)),
            "files" => Ok(json!(repository::files(std::path::Path::new(
                &self.worktree.path
            ))?)),
            "sourceDirectory" => Ok(json!(repository::source_directory(
                std::path::Path::new(&self.worktree.path),
                request.params["path"]
                    .as_str()
                    .context("Directory path required")?,
                request.params["offset"].as_str().unwrap_or("0").parse()?,
            )?)),
            "source" => Ok(json!(
                self.source(
                    request.params["path"]
                        .as_str()
                        .context("Source path required")?
                )?
            )),
            "changes" => Ok(json!(repository::changes(
                std::path::Path::new(&self.worktree.path),
                &serde_json::from_value(request.params["scope"].clone())?
            )?)),
            "comparison" => Ok(json!(
                self.comparison(
                    serde_json::from_value(request.params["scope"].clone())?,
                    request.params["path"]
                        .as_str()
                        .context("Comparison path required")?,
                )?
            )),
            "enableAnalysis" => {
                state::database(&self.directory.join("review.sqlite"))?.execute(
                    "INSERT OR IGNORE INTO permissions VALUES ('go-analysis')",
                    [],
                )?;
                Ok(json!({"enabled": true}))
            }
            "saveAnnotation" => Ok(json!(self.save(serde_json::from_value(request.params)?)?)),
            "annotations" => {
                let connection = state::database(&self.directory.join("review.sqlite"))?;
                let mut statement = connection.prepare("SELECT payload FROM annotations WHERE expires>?1 ORDER BY rowid DESC LIMIT 100")?;
                let rows = statement
                    .query_map([Utc::now().to_rfc3339()], |row| row.get::<_, String>(0))?;
                let annotations = rows
                    .map(|row| Ok(serde_json::from_str::<Annotation>(&row?)?))
                    .collect::<Result<Vec<_>>>()?;
                Ok(json!(annotations))
            }
            _ => bail!("Unknown worktree operation"),
        }
    }
}

pub(crate) fn selected_text<'a>(source: &'a str, selection: &Selection) -> Result<&'a str> {
    fn offset(source: &str, line: u32, column: u32) -> Result<usize> {
        ensure!(line > 0 && column > 0, "Source coordinates are one-based");
        let mut line_start = if source.starts_with('\u{feff}') {
            '\u{feff}'.len_utf8()
        } else {
            0
        };
        for _ in 1..line {
            let newline = source[line_start..]
                .find(['\r', '\n'])
                .context("Source line is out of range")?;
            line_start += newline;
            line_start += if source[line_start..].starts_with("\r\n") {
                2
            } else {
                1
            };
        }
        let remaining = &source[line_start..];
        let text = remaining.split(['\r', '\n']).next().unwrap();
        let target = (column - 1) as usize;
        let mut units = 0;
        for (byte, character) in text.char_indices() {
            if units == target {
                return Ok(line_start + byte);
            }
            units += character.len_utf16();
        }
        ensure!(
            units == target,
            "Source column is out of range or splits a Unicode character"
        );
        Ok(line_start + text.len())
    }
    let start = offset(source, selection.start_line_number, selection.start_column)?;
    let end = offset(source, selection.end_line_number, selection.end_column)?;
    ensure!(start <= end, "Source selection is reversed");
    Ok(&source[start..end])
}

pub fn socket(state: &std::path::Path, id: &str) -> PathBuf {
    let identity = state::digest(format!("{id}:{BUILD_ID}").as_bytes());
    state.join("s").join(&identity[..32])
}

pub async fn run(state_directory: PathBuf, id: String) -> Result<()> {
    let worktree = state::find_worktree(&state_directory, &id)?;
    let directory = state::worktree_state(&state_directory, &id);
    state::private_directory(&directory)?;
    let _lock = state::lock(&directory.join(format!("service-{BUILD_ID}.lock")))?;
    state::private_directory(&state_directory.join("s"))?;
    let endpoint = socket(&state_directory, &id);
    if endpoint.exists() {
        fs::remove_file(&endpoint)?;
    }
    let listener = UnixListener::bind(&endpoint)?;
    fs::set_permissions(&endpoint, fs::Permissions::from_mode(0o600))?;
    let analysis = std::sync::Arc::new(crate::analysis::Analysis::new(
        PathBuf::from(&worktree.path),
        state_directory.clone(),
    ));
    let delivery = std::sync::Arc::new(crate::feedback::Delivery::new(
        directory.clone(),
        worktree.clone(),
    )?);
    let store = std::sync::Arc::new(Store::open(directory, worktree)?);
    let mut requests = tokio::task::JoinSet::new();
    loop {
        let accepted = tokio::select! {
            accepted = listener.accept() => accepted,
            _ = requests.join_next(), if !requests.is_empty() => continue,
            _ = tokio::time::sleep(Duration::from_secs(300)), if requests.is_empty() => break,
        };
        let (mut stream, _) = accepted?;
        let store = store.clone();
        let analysis = analysis.clone();
        let delivery = delivery.clone();
        requests.spawn(async move {
            let result = async {
                let request: transport::Request = transport::read(&mut stream).await?;
                let id = request.id;
                request.validate()?;
                let feedback_operation = matches!(
                    request.method.as_str(),
                    "ampSessions" | "prepareFeedback" | "sendFeedback" | "feedback" | "feedbackPreview"
                );
                let outcome = if feedback_operation {
                    delivery.execute(&request.method, request.params).await
                } else if matches!(request.method.as_str(), "analysisSource" | "inspect") {
                    use tokio::io::AsyncReadExt;
                    let mut disconnect = [0];
                    tokio::select! {
                        result = tokio::time::timeout(Duration::from_secs(45), analysis.execute(store, &request.method, request.params)) => {
                            result.unwrap_or_else(|_| Err(anyhow::anyhow!("Go analysis timed out. Retry to restart gopls")))
                        }
                        _ = stream.read(&mut disconnect) => return Ok(()),
                    }
                } else {
                    tokio::task::spawn_blocking(move || store.execute(request)).await?
                };
                transport::respond(&mut stream, id, outcome).await
            };
            if let Ok(Err(error)) = tokio::time::timeout(Duration::from_secs(55), result).await {
                eprintln!("Worktree request failed: {error}");
            }
        });
    }
    fs::remove_file(endpoint)?;
    Ok(())
}
