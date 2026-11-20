use anyhow::{Context, Result};
use tree_sitter_highlight::{HighlightConfiguration, HighlightEvent, Highlighter};

use crate::model::TOKEN_TYPES;

pub fn highlights(path: &str, text: &str) -> Result<Vec<u32>> {
    if !path.ends_with(".go") {
        return Ok(Vec::new());
    }
    let mut configuration = HighlightConfiguration::new(
        tree_sitter_go::LANGUAGE.into(),
        "go",
        tree_sitter_go::HIGHLIGHTS_QUERY,
        "",
        "",
    )?;
    configuration.configure(&TOKEN_TYPES);
    let mut highlighter = Highlighter::new();
    let events = highlighter.highlight(&configuration, text.as_bytes(), None, |_| None)?;
    let mut stack = Vec::new();
    let mut tokens = Vec::new();
    let mut line = 0;
    let mut column = 0;
    let mut previous_line = 0;
    let mut previous_column = 0;
    let mut previous_cr = false;
    let mut emit = |line: u32, column: u32, length: u32, kind: Option<&u32>| {
        let Some(kind) = kind else { return };
        if length == 0 {
            return;
        }
        let delta_column = if line == previous_line {
            column - previous_column
        } else {
            column
        };
        tokens.extend([line - previous_line, delta_column, length, *kind, 0]);
        previous_line = line;
        previous_column = column;
    };
    for event in events {
        match event? {
            HighlightEvent::HighlightStart(kind) => stack.push(kind.0 as u32),
            HighlightEvent::HighlightEnd => {
                stack.pop();
            }
            HighlightEvent::Source { start, end } => {
                let content = text
                    .get(start..end)
                    .context("Invalid Go syntax source range")?;
                let mut run_start = column;
                let mut run_length = 0;
                for character in content.chars() {
                    if character == '\r' || character == '\n' {
                        emit(line, run_start, run_length, stack.last());
                        if character == '\r' || !previous_cr {
                            line += 1;
                        }
                        previous_cr = character == '\r';
                        column = 0;
                        run_start = 0;
                        run_length = 0;
                    } else {
                        previous_cr = false;
                        if start == 0 && column == 0 && character == '\u{feff}' {
                            continue;
                        }
                        let units = character.len_utf16() as u32;
                        column += units;
                        run_length += units;
                    }
                }
                emit(line, run_start, run_length, stack.last());
            }
        }
    }
    Ok(tokens)
}
