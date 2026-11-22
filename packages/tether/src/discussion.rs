use anyhow::{Context, Result, ensure};
use chrono::Utc;
use rusqlite::{Connection, OptionalExtension, Transaction, params};
use serde_json::{Value, json};
use std::{collections::BTreeMap, fs, path::Path};

use crate::{
    model::{
        AgentResponseInput, Annotation, DeliveryStatus, Discussion, DiscussionActor,
        DiscussionEvent, DiscussionStatus, Disposition, FeedbackPreview, ResolutionInput,
        ResponseEvidence, ResponseSources, Source,
    },
    repository,
    service::Store,
    state,
};

pub(crate) fn status(connection: &Connection, annotation_id: &str) -> Result<DiscussionStatus> {
    let saved: Option<(u32, String)> = connection
        .query_row(
            "SELECT revision, disposition FROM discussions WHERE annotation_id=?1",
            [annotation_id],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .optional()?;
    let (revision, disposition) = match saved {
        Some((revision, disposition)) => (revision, serde_json::from_str(&disposition)?),
        None => (0, Disposition::Open),
    };
    Ok(DiscussionStatus {
        annotation_id: annotation_id.into(),
        revision,
        disposition,
    })
}

pub(crate) fn annotation(connection: &Connection, id: &str) -> Result<Annotation> {
    let payload: String = connection
        .query_row(
            "SELECT payload FROM annotations WHERE id=?1 AND expires>?2",
            params![id, Utc::now().to_rfc3339()],
            |row| row.get(0),
        )
        .context("Annotation is unavailable in this worktree")?;
    Ok(serde_json::from_str(&payload)?)
}

fn previous_event(
    connection: &Connection,
    id: &str,
    hash: &str,
) -> Result<Option<DiscussionEvent>> {
    let saved: Option<(String, String)> = connection
        .query_row(
            "SELECT request_hash, payload FROM discussion_events WHERE id=?1",
            [id],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .optional()?;
    saved
        .map(|(previous_hash, payload)| {
            ensure!(
                previous_hash == hash,
                "Operation ID already belongs to another response or action"
            );
            Ok(serde_json::from_str(&payload)?)
        })
        .transpose()
}

fn append(transaction: &Transaction<'_>, event: &DiscussionEvent, hash: &str) -> Result<()> {
    if event.applied {
        transaction.execute(
            "INSERT INTO discussions VALUES (?1, ?2, ?3)
             ON CONFLICT(annotation_id) DO UPDATE SET revision=excluded.revision, disposition=excluded.disposition",
            params![event.annotation_id, event.based_on_revision + 1, serde_json::to_string(&event.disposition)?],
        )?;
    }
    transaction.execute(
        "INSERT INTO discussion_events(id, annotation_id, request_hash, payload) VALUES (?1, ?2, ?3, ?4)",
        params![event.id, event.annotation_id, hash, serde_json::to_string(event)?],
    )?;
    Ok(())
}

fn response_authorization(
    connection: &Connection,
    input: &AgentResponseInput,
) -> Result<(FeedbackPreview, u32)> {
    let (payload, token_hash, revisions): (String, String, String) = connection
        .query_row(
            "SELECT feedback.payload, response_authorizations.token_hash, response_authorizations.revisions
             FROM feedback JOIN response_authorizations ON feedback.id=response_authorizations.feedback_id
             WHERE feedback.id=?1",
            [&input.feedback_id],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .context("Response authorization is unavailable in this worktree")?;
    ensure!(
        state::digest(input.token.as_bytes()) == token_hash,
        "Invalid response authorization"
    );
    let preview: FeedbackPreview = serde_json::from_str(&payload)?;
    ensure!(
        preview.feedback.status != DeliveryStatus::Prepared,
        "Feedback has not been sent"
    );
    let revisions: BTreeMap<String, u32> = serde_json::from_str(&revisions)?;
    let revision = *revisions
        .get(&input.annotation_id)
        .context("Annotation is outside this submission")?;
    Ok((preview, revision))
}

impl Store {
    fn respond(&self, input: AgentResponseInput) -> Result<DiscussionEvent> {
        uuid::Uuid::parse_str(&input.id).context("Response operation ID must be a UUID")?;
        ensure!(
            !input.text.trim().is_empty() && input.text.len() <= 16_384,
            "Response must contain 1–16384 bytes of text"
        );
        ensure!(
            input.paths.len() <= 7,
            "Include at most seven additional source paths"
        );
        let hash = state::digest(&serde_json::to_vec(&input)?);
        let mut connection = state::database(&self.directory.join("review.sqlite"))?;
        response_authorization(&connection, &input)?;
        let note = annotation(&connection, &input.annotation_id)?;
        if let Some(event) = previous_event(&connection, &input.id, &hash)? {
            return Ok(event);
        }
        let mut paths = vec![note.input.path];
        for path in &input.paths {
            if !paths.contains(path) {
                paths.push(path.clone());
            }
        }
        let mut evidence = Vec::new();
        for path in paths {
            ensure!(
                !path.is_empty()
                    && path.len() <= 4096
                    && Path::new(&path).components().all(|component| {
                        matches!(component, std::path::Component::Normal(name) if name != ".git")
                    }),
                "Evidence must use a worktree-relative source path"
            );
            let text = repository::working_source(Path::new(&self.worktree.path), &path)?;
            let source_id = text
                .map(|text| self.capture(&path, text).map(|source| source.id))
                .transpose()?;
            evidence.push(ResponseEvidence { path, source_id });
        }
        let transaction =
            connection.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let (preview, revision) = response_authorization(&transaction, &input)?;
        annotation(&transaction, &input.annotation_id)?;
        if let Some(event) = previous_event(&transaction, &input.id, &hash)? {
            return Ok(event);
        }
        let current = status(&transaction, &input.annotation_id)?;
        let event = DiscussionEvent {
            id: input.id,
            annotation_id: input.annotation_id,
            actor: DiscussionActor::Agent {
                thread: preview.feedback.session.thread,
                submission: input.feedback_id,
            },
            created_at: Utc::now().to_rfc3339(),
            text: input.text,
            disposition: Disposition::Addressed,
            based_on_revision: revision,
            applied: current.revision == revision
                && matches!(
                    current.disposition,
                    Disposition::Open | Disposition::Addressed
                ),
            evidence,
        };
        append(&transaction, &event, &hash)?;
        transaction.commit()?;
        Ok(event)
    }

    fn resolve(&self, input: ResolutionInput, owner: String) -> Result<DiscussionEvent> {
        uuid::Uuid::parse_str(&input.id).context("Resolution operation ID must be a UUID")?;
        uuid::Uuid::parse_str(&owner).context("Gateway owner identity required")?;
        ensure!(
            input.disposition != Disposition::Addressed,
            "Addressed requires an agent response"
        );
        ensure!(
            input.text.len() <= 16_384,
            "Review note exceeds 16384 bytes"
        );
        let hash = state::digest(&serde_json::to_vec(
            &json!({"owner": owner, "input": input}),
        )?);
        let mut connection = state::database(&self.directory.join("review.sqlite"))?;
        let transaction =
            connection.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        annotation(&transaction, &input.annotation_id)?;
        if let Some(event) = previous_event(&transaction, &input.id, &hash)? {
            return Ok(event);
        }
        let current = status(&transaction, &input.annotation_id)?;
        ensure!(
            current.revision == input.expected_revision,
            "Discussion changed. Review its latest response before trying again"
        );
        ensure!(
            current.disposition != input.disposition,
            "Discussion already has this disposition"
        );
        let latest: Option<String> = transaction.query_row(
            "SELECT payload FROM discussion_events WHERE annotation_id=?1 AND json_extract(payload, '$.applied')=1 ORDER BY sequence DESC LIMIT 1",
            [&input.annotation_id], |row| row.get(0),
        ).optional()?;
        let evidence = latest
            .map(|payload| {
                serde_json::from_str::<DiscussionEvent>(&payload).map(|event| event.evidence)
            })
            .transpose()?
            .unwrap_or_default();
        let event = DiscussionEvent {
            id: input.id,
            annotation_id: input.annotation_id,
            actor: DiscussionActor::Human { owner },
            created_at: Utc::now().to_rfc3339(),
            text: input.text,
            disposition: input.disposition,
            based_on_revision: current.revision,
            applied: true,
            evidence,
        };
        append(&transaction, &event, &hash)?;
        transaction.commit()?;
        Ok(event)
    }

    pub(crate) fn captured_source(&self, path: &str, id: &str) -> Result<Source> {
        let text = fs::read_to_string(self.directory.join("sources").join(id))?;
        Ok(Source {
            id: id.into(),
            path: path.into(),
            highlights: Vec::new(),
            text,
        })
    }

    pub(crate) fn discussion_request(&self, method: &str, input: Value) -> Result<Value> {
        if method == "respond" {
            return Ok(json!(self.respond(serde_json::from_value(input)?)?));
        }
        if method == "resolveDiscussion" {
            let owner = input["owner"]
                .as_str()
                .context("Gateway owner identity required")?
                .to_owned();
            return Ok(json!(self.resolve(
                serde_json::from_value(input["action"].clone())?,
                owner
            )?));
        }
        let mut connection = state::database(&self.directory.join("review.sqlite"))?;
        let transaction = connection.transaction()?;
        if method == "discussions" {
            let mut statement = transaction.prepare(
                "SELECT id FROM annotations WHERE expires>?1 ORDER BY rowid DESC LIMIT 100",
            )?;
            let ids =
                statement.query_map([Utc::now().to_rfc3339()], |row| row.get::<_, String>(0))?;
            let statuses = ids
                .map(|id| status(&transaction, &id?))
                .collect::<Result<Vec<_>>>()?;
            return Ok(json!(statuses));
        }
        let id = input["id"].as_str().context("Annotation ID required")?;
        let note = annotation(&transaction, id)?;
        if method == "responseSources" {
            let event_id = input["eventId"].as_str().context("Response ID required")?;
            let path = input["path"].as_str().context("Evidence path required")?;
            let payload: String = transaction.query_row(
                "SELECT payload FROM discussion_events WHERE id=?1 AND annotation_id=?2",
                params![event_id, id],
                |row| row.get(0),
            )?;
            let event: DiscussionEvent = serde_json::from_str(&payload)?;
            let evidence = event
                .evidence
                .iter()
                .find(|evidence| evidence.path == path)
                .context("Source is outside this response")?;
            let before = if note.input.path == path {
                Some(self.captured_source(path, &note.input.source_id)?)
            } else {
                None
            };
            let after = evidence
                .source_id
                .as_deref()
                .map(|id| self.captured_source(path, id))
                .transpose()?;
            return Ok(json!(ResponseSources { before, after }));
        }
        let offset: u32 = input["offset"].as_str().unwrap_or("0").parse()?;
        let mut statement = transaction.prepare("SELECT payload FROM discussion_events WHERE annotation_id=?1 ORDER BY sequence DESC LIMIT 21 OFFSET ?2")?;
        let rows = statement.query_map(params![id, offset], |row| row.get::<_, String>(0))?;
        let mut events = Vec::new();
        let mut bytes = 0;
        let mut next_offset = None;
        for row in rows {
            let payload = row?;
            if events.len() == 20 || bytes + payload.len() > 512 * 1024 {
                next_offset = Some(offset + events.len() as u32);
                break;
            }
            bytes += payload.len();
            events.push(serde_json::from_str::<DiscussionEvent>(&payload)?);
        }
        Ok(json!(Discussion {
            status: status(&transaction, id)?,
            events,
            next_offset
        }))
    }
}
