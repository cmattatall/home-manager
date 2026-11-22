use anyhow::{Context, Result, ensure};
use chrono::Utc;
use rusqlite::{Connection, params};
use serde_json::{Value, json};
use std::path::Path;

use crate::{
    discussion,
    model::{
        Annotation, AssessedSources, Comparison, DiscussionEvent, Freshness, Selection, Source,
        SourceAssessment,
    },
    repository,
    service::{Store, selected_text},
    state,
};

fn normalized(text: &str) -> String {
    text.strip_prefix('\u{feff}')
        .unwrap_or(text)
        .replace("\r\n", "\n")
        .replace('\r', "\n")
}

fn occurrences(text: &str, excerpt: &str) -> Vec<usize> {
    text.char_indices()
        .filter_map(|(offset, _)| text[offset..].starts_with(excerpt).then_some(offset))
        .take(2)
        .collect()
}

fn position(text: &str, offset: usize) -> (u32, u32) {
    let prefix = &text[..offset];
    let line = prefix.bytes().filter(|byte| *byte == b'\n').count() as u32 + 1;
    let column = prefix.rsplit('\n').next().unwrap().encode_utf16().count() as u32 + 1;
    (line, column)
}

fn map_selection(
    before: &str,
    after: &str,
    selection: &Selection,
) -> Result<(Freshness, Option<Selection>)> {
    let before = normalized(before);
    let after = normalized(after);
    let excerpt = selected_text(&before, selection)?;
    if excerpt.is_empty() {
        return Ok((Freshness::Uncertain, None));
    }
    let candidates = occurrences(&after, excerpt);
    if candidates.len() == 1 && occurrences(&before, excerpt).len() == 1 {
        let (start_line_number, start_column) = position(&after, candidates[0]);
        let (end_line_number, end_column) = position(&after, candidates[0] + excerpt.len());
        let mapped = Selection {
            start_line_number,
            start_column,
            end_line_number,
            end_column,
        };
        if mapped == *selection {
            return Ok((Freshness::Unchanged, Some(mapped)));
        }
        let line_count = selection.end_line_number - selection.start_line_number
            + u32::from(selection.end_column > 1);
        let before_lines = before
            .split('\n')
            .skip(selection.start_line_number as usize - 1)
            .take(line_count as usize);
        let after_lines = after
            .split('\n')
            .skip(mapped.start_line_number as usize - 1)
            .take(line_count as usize);
        if before_lines.eq(after_lines) {
            return Ok((Freshness::Moved, Some(mapped)));
        }
        return Ok((Freshness::Uncertain, None));
    }
    if !candidates.is_empty() {
        return Ok((Freshness::Uncertain, None));
    }
    let start = selection.start_line_number as usize - 1;
    let end = if selection.end_column == 1 {
        selection.end_line_number as usize - 1
    } else {
        selection.end_line_number as usize
    };
    let removed = similar::TextDiff::from_lines(&before, &after)
        .ops()
        .iter()
        .any(|operation| {
            operation.tag() == similar::DiffTag::Delete
                && operation.old_range().start <= start
                && operation.old_range().end >= end
        });
    Ok((
        if removed {
            Freshness::Removed
        } else {
            Freshness::Changed
        },
        None,
    ))
}

impl Store {
    fn assess(
        &self,
        connection: &Connection,
        annotation: &Annotation,
        event: Option<&DiscussionEvent>,
        path: &str,
    ) -> Result<AssessedSources> {
        let old_side = annotation
            .input
            .review
            .as_ref()
            .is_some_and(|review| review.side == "before");
        let baseline_id = if let Some(event) = event {
            event
                .evidence
                .iter()
                .find(|evidence| evidence.path == path)
                .context("Source is outside this response")?
                .source_id
                .clone()
        } else if old_side {
            let review = annotation.input.review.as_ref().unwrap();
            let payload: String = connection.query_row(
                "SELECT payload FROM comparisons WHERE id=?1",
                [&review.comparison_id],
                |row| row.get(0),
            )?;
            let comparison: Comparison = serde_json::from_str(&payload)?;
            comparison.after.map(|source| source.id)
        } else {
            Some(annotation.input.source_id.clone())
        };
        let mut assessment = SourceAssessment {
            annotation_id: annotation.input.id.clone(),
            path: path.into(),
            observed_at: Utc::now().to_rfc3339(),
            baseline_id: baseline_id.clone(),
            current_id: None,
            freshness: Freshness::Unknown,
            file_changed: None,
            selection: None,
            detail: if event.is_some() {
                "Whole file compared with captured response evidence.".into()
            } else if old_side {
                "Whole file compared with the reviewed new-side state. The original old-side selection is retained.".into()
            } else {
                "Selected text compared with the saved worktree source.".into()
            },
        };
        let read = || -> Result<(Option<Source>, Option<Source>)> {
            let baseline = baseline_id
                .as_deref()
                .map(|id| self.captured_source(path, id))
                .transpose()?;
            let root = Path::new(&self.worktree.path);
            ensure!(root.is_dir(), "Worktree directory is unavailable");
            let current_text = repository::working_source(root, path)?;
            let current = current_text.as_ref().map(|text| Source {
                id: state::digest(text.as_bytes()),
                path: path.into(),
                text: text.clone(),
                highlights: Vec::new(),
            });
            ensure!(
                repository::working_source(root, path)? == current_text,
                "Source changed during observation. Check again"
            );
            Ok((baseline, current))
        };
        let (baseline, current) = match read() {
            Ok(sources) => sources,
            Err(error) => {
                assessment.detail = error.to_string();
                return Ok(AssessedSources {
                    assessment,
                    original: None,
                    baseline: None,
                    current: None,
                });
            }
        };
        assessment.current_id = current.as_ref().map(|source| source.id.clone());
        let file_changed = assessment.baseline_id != assessment.current_id;
        assessment.file_changed = Some(file_changed);
        if !file_changed {
            assessment.freshness = Freshness::Unchanged;
            if event.is_none() && !old_side {
                assessment.selection = Some(annotation.input.selection.clone());
            }
        } else {
            let (freshness, selection) = match (&baseline, &current) {
                (_, None) => (Freshness::Removed, None),
                (Some(before), Some(after)) if event.is_none() && !old_side => {
                    map_selection(&before.text, &after.text, &annotation.input.selection)?
                }
                _ => (Freshness::Changed, None),
            };
            assessment.freshness = freshness;
            assessment.selection = selection;
        }
        assessment.observed_at = Utc::now().to_rfc3339();
        Ok(AssessedSources {
            assessment,
            original: None,
            baseline,
            current,
        })
    }

    pub(crate) fn freshness_request(&self, method: &str, input: Value) -> Result<Value> {
        let connection = state::database(&self.directory.join("review.sqlite"))?;
        if method == "assessments" {
            let mut statement = connection.prepare(
                "SELECT payload FROM annotations WHERE expires>?1 ORDER BY rowid DESC LIMIT 100",
            )?;
            let rows =
                statement.query_map([Utc::now().to_rfc3339()], |row| row.get::<_, String>(0))?;
            let mut assessments = Vec::new();
            for row in rows {
                let annotation: Annotation = serde_json::from_str(&row?)?;
                assessments.push(
                    self.assess(&connection, &annotation, None, &annotation.input.path)?
                        .assessment,
                );
            }
            return Ok(json!(assessments));
        }
        let id = input["id"].as_str().context("Annotation ID required")?;
        let annotation = discussion::annotation(&connection, id)?;
        let event = if let Some(event_id) = input["eventId"].as_str() {
            let payload: String = connection.query_row(
                "SELECT payload FROM discussion_events WHERE id=?1 AND annotation_id=?2",
                params![event_id, id],
                |row| row.get(0),
            )?;
            Some(serde_json::from_str::<DiscussionEvent>(&payload)?)
        } else {
            None
        };
        let path = input["path"].as_str().unwrap_or(&annotation.input.path);
        ensure!(
            event.is_some() || path == annotation.input.path,
            "Source is outside this annotation"
        );
        let mut sources = self.assess(&connection, &annotation, event.as_ref(), path)?;
        if input["sources"].as_str() == Some("true") {
            if let Some(expected) = input["expectedCurrentId"].as_str() {
                ensure!(
                    sources.assessment.current_id.as_deref().unwrap_or("absent") == expected,
                    "Source advanced since assessment. Check source again"
                );
            }
            if path == annotation.input.path {
                sources.original = Some(self.captured_source(path, &annotation.input.source_id)?);
            }
            Ok(json!(sources))
        } else {
            Ok(json!(sources.assessment))
        }
    }
}
