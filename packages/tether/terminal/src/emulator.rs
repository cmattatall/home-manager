use std::{
    mem::size_of,
    sync::{Arc, Mutex},
};

use alacritty_terminal::{
    Term,
    event::{Event, EventListener},
    grid::{Dimensions as GridDimensions, Row},
    index::{Column, Line},
    term::{
        Config, TermMode,
        cell::{Cell, CellExtra, Flags},
    },
    vte::ansi::{self, Handler, Processor},
};
use anyhow::{Result, ensure};
use serde::{Deserialize, Serialize};
use ts_rs::TS;
use unicode_width::UnicodeWidthChar;
use uuid::Uuid;

use crate::{
    MAX_COMBINING_MARKS, MAX_HISTORY_BYTES, MAX_HISTORY_ROWS, MAX_INPUT_BYTES,
    frame::{Frame, FrameStamp},
    guard::OscGuard,
};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, TS)]
pub struct Dimensions {
    pub columns: usize,
    pub rows: usize,
}

impl Dimensions {
    pub fn validate(self) -> Result<()> {
        ensure!(
            (2..=512).contains(&self.columns),
            "Terminal columns must be between 2 and 512"
        );
        ensure!(
            (1..=200).contains(&self.rows),
            "Terminal rows must be between 1 and 200"
        );
        Ok(())
    }
}

impl GridDimensions for Dimensions {
    fn columns(&self) -> usize {
        self.columns
    }
    fn screen_lines(&self) -> usize {
        self.rows
    }
    fn total_lines(&self) -> usize {
        self.rows
    }
}

#[derive(Default)]
struct Replies {
    bytes: Vec<u8>,
    overflowed: bool,
}

#[derive(Clone, Default)]
struct ReplySink(Arc<Mutex<Replies>>);

impl EventListener for ReplySink {
    fn send_event(&self, event: Event) {
        if let Event::PtyWrite(text) = event {
            let mut replies = self.0.lock().unwrap();
            if replies.bytes.len() + text.len() <= MAX_INPUT_BYTES {
                replies.bytes.extend_from_slice(text.as_bytes());
            } else {
                replies.overflowed = true;
            }
        }
    }
}

pub struct Terminal {
    parser: Processor,
    guard: OscGuard,
    state: BoundedHandler,
    replies: ReplySink,
    stamp: FrameStamp,
}

struct BoundedHandler {
    term: Term<ReplySink>,
    largest_columns: usize,
    rejected_marks: u64,
}

impl Terminal {
    pub fn new(dimensions: Dimensions) -> Result<Self> {
        dimensions.validate()?;
        let replies = ReplySink::default();
        let mut state = BoundedHandler {
            term: Term::new(Config::default(), &dimensions, replies.clone()),
            largest_columns: dimensions.columns,
            rejected_marks: 0,
        };
        state.trim_history();
        Ok(Self {
            parser: Processor::new(),
            guard: OscGuard::default(),
            state,
            replies,
            stamp: FrameStamp {
                runtime: Uuid::new_v4(),
                revision: 0,
            },
        })
    }

    /// Consume one bounded PTY read and return replies for the PTY writer.
    pub fn advance(&mut self, bytes: &[u8]) -> Result<Vec<u8>> {
        ensure!(
            bytes.len() <= MAX_INPUT_BYTES,
            "PTY read exceeds 4096 bytes"
        );
        self.stamp.revision = self
            .stamp
            .revision
            .checked_add(1)
            .expect("terminal revision exhausted");
        for &byte in bytes {
            if let Some(byte) = self.guard.filter(byte) {
                self.parser.advance(&mut self.state, &[byte]);
            }
        }
        // Flush synchronized output at the read boundary so detached sessions progress.
        self.parser.stop_sync(&mut self.state);
        self.state.trim_history();
        let mut replies = self.replies.0.lock().unwrap();
        let overflowed = std::mem::take(&mut replies.overflowed);
        let bytes = std::mem::take(&mut replies.bytes);
        ensure!(
            !overflowed,
            "Terminal query replies exceeded 4096 bytes in one PTY read"
        );
        Ok(bytes)
    }

    pub fn resize(&mut self, dimensions: Dimensions) -> Result<()> {
        dimensions.validate()?;
        self.state.largest_columns = self.state.largest_columns.max(dimensions.columns);
        // Alacritty constructs reflow rows before eviction. Limit that expansion per step.
        while self.state.term.columns() > dimensions.columns * 4 {
            self.state.resize(Dimensions {
                columns: self.state.term.columns() / 4,
                rows: self.state.term.screen_lines(),
            });
        }
        self.state.resize(dimensions);
        self.stamp.revision = self
            .stamp
            .revision
            .checked_add(1)
            .expect("terminal revision exhausted");
        Ok(())
    }

    pub fn frame(&self) -> Result<Frame> {
        Frame::render(
            &self.state.term,
            self.stamp,
            self.state.history_bytes(),
            self.guard.rejected,
            self.state.rejected_marks,
        )
    }
}

impl BoundedHandler {
    fn resize(&mut self, dimensions: Dimensions) {
        // Reflow can move decorated screen cells into the inactive primary history.
        let row_charge = self.row_base_bytes()
            + dimensions.columns * (size_of::<CellExtra>() + 16 + MAX_COMBINING_MARKS * 4);
        self.term.set_options(Config {
            scrolling_history: (MAX_HISTORY_BYTES / row_charge).min(MAX_HISTORY_ROWS),
            ..Config::default()
        });
        self.term.resize(dimensions);
        self.trim_history();
    }

    fn row_base_bytes(&self) -> usize {
        // Vec growth and reflow can retain capacity after a width reduction.
        2 * self.largest_columns * size_of::<Cell>() + size_of::<Row<Cell>>()
    }

    fn row_bytes(&self, line: Line) -> usize {
        let mut bytes = self.row_base_bytes();
        for cell in &self.term.grid()[line][..] {
            if let Some(extra) = &cell.extra {
                let marks = cell.zerowidth().unwrap_or_default().len();
                let capacity = if marks == 0 {
                    0
                } else {
                    marks.next_power_of_two().max(4)
                };
                bytes += size_of_val(extra.as_ref()) + 16 + capacity * size_of::<char>();
            }
        }
        bytes
    }

    fn history_bytes(&self) -> usize {
        (1..=self.term.grid().history_size())
            .map(|row| self.row_bytes(Line(-(row as i32))))
            .sum()
    }

    fn trim_history(&mut self) {
        if self.term.mode().contains(TermMode::ALT_SCREEN) {
            self.term.grid_mut().truncate();
            return;
        }
        let mut bytes = 0;
        let mut retained = 0;
        for row in 1..=self.term.grid().history_size().min(MAX_HISTORY_ROWS) {
            let charge = self.row_bytes(Line(-(row as i32)));
            if bytes + charge > MAX_HISTORY_BYTES {
                break;
            }
            bytes += charge;
            retained = row;
        }
        let capacity = (MAX_HISTORY_BYTES / self.row_base_bytes()).min(MAX_HISTORY_ROWS);
        let grid = self.term.grid_mut();
        grid.update_history(retained);
        grid.truncate();
        self.term.set_options(Config {
            scrolling_history: capacity,
            ..Config::default()
        });
    }
}

macro_rules! forward {
    ($(fn $name:ident($($argument:ident: $kind:ty),*);)*) => {
        $(fn $name(&mut self, $($argument: $kind),*) {
            self.term.$name($($argument),*);
        })*
    };
}

impl Handler for BoundedHandler {
    fn input(&mut self, character: char) {
        if character.width() == Some(0) {
            let grid = self.term.grid();
            let mut point = grid.cursor.point;
            if !grid.cursor.input_needs_wrap {
                point.column.0 = point.column.0.saturating_sub(1);
            }
            if grid[point].flags.contains(Flags::WIDE_CHAR_SPACER) {
                point.column = Column(point.column.0.saturating_sub(1));
            }
            if grid[point].zerowidth().unwrap_or_default().len() >= MAX_COMBINING_MARKS {
                self.rejected_marks = self.rejected_marks.saturating_add(1);
                return;
            }
        }
        self.term.input(character);
    }

    fn set_private_mode(&mut self, mode: ansi::PrivateMode) {
        self.trim_history();
        self.term.set_private_mode(mode);
    }

    fn unset_private_mode(&mut self, mode: ansi::PrivateMode) {
        self.term.unset_private_mode(mode);
        self.trim_history();
    }

    // Host effects and hyperlink/title storage stay disabled at this boundary.
    forward! {
        fn set_cursor_style(style: Option<ansi::CursorStyle>);
        fn set_cursor_shape(shape: ansi::CursorShape);
        fn goto(line: i32, column: usize);
        fn goto_line(line: i32);
        fn goto_col(column: usize);
        fn insert_blank(count: usize);
        fn move_up(count: usize);
        fn move_down(count: usize);
        fn identify_terminal(intermediate: Option<char>);
        fn device_status(status: usize);
        fn move_forward(count: usize);
        fn move_backward(count: usize);
        fn move_down_and_cr(count: usize);
        fn move_up_and_cr(count: usize);
        fn put_tab(count: u16);
        fn backspace();
        fn carriage_return();
        fn linefeed();
        fn substitute();
        fn newline();
        fn set_horizontal_tabstop();
        fn scroll_up(count: usize);
        fn scroll_down(count: usize);
        fn insert_blank_lines(count: usize);
        fn delete_lines(count: usize);
        fn erase_chars(count: usize);
        fn delete_chars(count: usize);
        fn move_backward_tabs(count: u16);
        fn move_forward_tabs(count: u16);
        fn save_cursor_position();
        fn restore_cursor_position();
        fn clear_line(mode: ansi::LineClearMode);
        fn clear_screen(mode: ansi::ClearMode);
        fn clear_tabs(mode: ansi::TabulationClearMode);
        fn set_tabs(interval: u16);
        fn reset_state();
        fn reverse_index();
        fn terminal_attribute(attribute: ansi::Attr);
        fn set_mode(mode: ansi::Mode);
        fn unset_mode(mode: ansi::Mode);
        fn report_mode(mode: ansi::Mode);
        fn report_private_mode(mode: ansi::PrivateMode);
        fn set_scrolling_region(top: usize, bottom: Option<usize>);
        fn set_keypad_application_mode();
        fn unset_keypad_application_mode();
        fn set_active_charset(index: ansi::CharsetIndex);
        fn configure_charset(index: ansi::CharsetIndex, charset: ansi::StandardCharset);
        fn decaln();
    }
}
