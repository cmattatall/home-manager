use std::{
    fmt::Write as _,
    io::Write,
    time::{Duration, Instant},
};

use alacritty_terminal::{
    Term,
    event::EventListener,
    grid::Dimensions as _,
    index::{Column, Line},
    term::{
        TermMode,
        cell::{Cell, Flags},
    },
    vte::ansi::{Color, CursorShape, NamedColor},
};
use anyhow::{Result, ensure};
use serde::{Deserialize, Serialize};
use ts_rs::TS;
use uuid::Uuid;

use crate::{Dimensions, MAX_FRAME_BYTES, Terminal};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, TS)]
pub struct FrameStamp {
    #[ts(type = "string")]
    pub runtime: Uuid,
    #[ts(type = "number")]
    pub revision: u64,
}

#[derive(Debug, Serialize, Deserialize, TS)]
pub struct Frame {
    pub stamp: FrameStamp,
    pub dimensions: Dimensions,
    pub painting: String,
    pub history_rows: usize,
    pub history_bytes: usize,
    #[ts(type = "number")]
    pub rejected_osc: u64,
    #[ts(type = "number")]
    pub rejected_marks: u64,
}

#[derive(Default)]
pub struct FrameSender {
    pending: Option<OutboundFrame>,
}

struct OutboundFrame {
    stamp: FrameStamp,
    bytes: Vec<u8>,
    deadline: Instant,
}

pub struct FrameReceiver {
    runtime: Uuid,
    applied: Option<u64>,
    pending: Option<PendingFrame>,
}

struct PendingFrame {
    stamp: FrameStamp,
    length: usize,
    bytes: Vec<u8>,
}

struct LimitedBytes(Vec<u8>);

impl Write for LimitedBytes {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        if self.0.len() + bytes.len() > MAX_FRAME_BYTES {
            return Err(std::io::Error::other("Terminal frame exceeds 32 MiB"));
        }
        self.0.extend_from_slice(bytes);
        Ok(bytes.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

impl Frame {
    pub(crate) fn render<T: EventListener>(
        term: &Term<T>,
        stamp: FrameStamp,
        history_bytes: usize,
        rejected_osc: u64,
        rejected_marks: u64,
    ) -> Result<Self> {
        let mut painting = String::from("\x1bc\x1b[?1047l\x1b[3J\x1b[?7l");
        let grid = term.grid();
        let modes = term.mode();
        if modes.contains(TermMode::ALT_SCREEN) {
            painting.push_str("\x1b[?1047h");
        }
        let history = grid.history_size();
        let mut previous: Option<&Cell> = None;
        for row in -(history as i32)..grid.screen_lines() as i32 {
            if row != -(history as i32) {
                painting.push_str("\r\n");
            }
            for column in 0..grid.columns() {
                let cell = &grid[Line(row)][Column(column)];
                if cell.flags.contains(Flags::WIDE_CHAR_SPACER) {
                    continue;
                }
                let style_changed = previous.is_none_or(|previous| {
                    previous.fg != cell.fg
                        || previous.bg != cell.bg
                        || previous.flags != cell.flags
                        || previous.underline_color() != cell.underline_color()
                });
                if style_changed {
                    style(&mut painting, cell);
                    previous = Some(cell);
                }
                let character = if cell.c.is_control() { ' ' } else { cell.c };
                painting.push(character);
                for &mark in cell.zerowidth().unwrap_or_default() {
                    painting.push(mark);
                }
            }
            ensure!(
                painting.len() <= MAX_FRAME_BYTES,
                "Terminal painting exceeds 32 MiB"
            );
        }
        let cursor = grid.cursor.point;
        write!(
            painting,
            "\x1b[0m\x1b[{};{}H",
            cursor.line.0 + 1,
            cursor.column.0 + 1
        )?;
        let cursor_style = term.cursor_style();
        let mut cursor_shape = match cursor_style.shape {
            CursorShape::Underline => 4,
            CursorShape::Beam => 6,
            _ => 2,
        };
        if cursor_style.blinking {
            cursor_shape -= 1;
        }
        write!(painting, "\x1b[{cursor_shape} q")?;
        painting.push_str(if modes.contains(TermMode::APP_KEYPAD) {
            "\x1b="
        } else {
            "\x1b>"
        });
        if !modes.contains(TermMode::SHOW_CURSOR) {
            painting.push_str("\x1b[?25l");
        }
        for (flag, number) in [
            (TermMode::APP_CURSOR, 1),
            (TermMode::BRACKETED_PASTE, 2004),
            (TermMode::MOUSE_REPORT_CLICK, 1000),
            (TermMode::MOUSE_DRAG, 1002),
            (TermMode::MOUSE_MOTION, 1003),
            (TermMode::UTF8_MOUSE, 1005),
            (TermMode::SGR_MOUSE, 1006),
            (TermMode::ALTERNATE_SCROLL, 1007),
            (TermMode::FOCUS_IN_OUT, 1004),
        ] {
            if modes.contains(flag) {
                write!(painting, "\x1b[?{number}h")?;
            }
        }
        Ok(Self {
            stamp,
            dimensions: Dimensions {
                columns: grid.columns(),
                rows: grid.screen_lines(),
            },
            painting,
            history_rows: history,
            history_bytes,
            rejected_osc,
            rejected_marks,
        })
    }

    pub fn encode(&self) -> Result<Vec<u8>> {
        let mut bytes = LimitedBytes(Vec::new());
        serde_json::to_writer(&mut bytes, self)?;
        Ok(bytes.0)
    }
}

fn style(output: &mut String, cell: &Cell) {
    output.push_str("\x1b[0");
    for (flag, attribute) in [
        (Flags::BOLD, "1"),
        (Flags::DIM, "2"),
        (Flags::ITALIC, "3"),
        (Flags::UNDERLINE, "4"),
        (Flags::INVERSE, "7"),
        (Flags::HIDDEN, "8"),
        (Flags::STRIKEOUT, "9"),
        (Flags::DOUBLE_UNDERLINE, "4:2"),
        (Flags::UNDERCURL, "4:3"),
        (Flags::DOTTED_UNDERLINE, "4:4"),
        (Flags::DASHED_UNDERLINE, "4:5"),
    ] {
        if cell.flags.contains(flag) {
            write!(output, ";{attribute}").unwrap();
        }
    }
    color(output, cell.fg, 38);
    color(output, cell.bg, 48);
    if let Some(underline) = cell.underline_color() {
        color(output, underline, 58);
    }
    output.push('m');
}

fn color(output: &mut String, color: Color, attribute: u8) {
    match color {
        Color::Spec(rgb) => {
            write!(output, ";{attribute};2;{};{};{}", rgb.r, rgb.g, rgb.b).unwrap();
        }
        Color::Indexed(index) => {
            write!(output, ";{attribute};5;{index}").unwrap();
        }
        Color::Named(NamedColor::Foreground | NamedColor::Background) => {}
        Color::Named(name) => {
            write!(output, ";{attribute};5;{}", name as usize).unwrap();
        }
    }
}

impl FrameSender {
    /// Acknowledgement releases the sole in-flight frame before another capture.
    pub fn start(&mut self, terminal: &Terminal) -> Result<(FrameStamp, usize)> {
        ensure!(
            self.pending.is_none(),
            "A terminal frame is awaiting acknowledgement"
        );
        let frame = terminal.frame()?;
        let bytes = frame.encode()?;
        let header = (frame.stamp, bytes.len());
        self.pending = Some(OutboundFrame {
            stamp: frame.stamp,
            bytes,
            deadline: Instant::now() + Duration::from_secs(30),
        });
        Ok(header)
    }

    pub fn deadline(&self) -> Option<Instant> {
        self.pending.as_ref().map(|frame| frame.deadline)
    }

    /// The transport owner expires attachments independently of incoming requests.
    pub fn expire(&mut self, now: Instant) -> bool {
        if self.deadline().is_some_and(|deadline| now >= deadline) {
            self.pending = None;
            return true;
        }
        false
    }

    pub fn chunk(&self, offset: usize) -> Result<&[u8]> {
        let frame = self
            .pending
            .as_ref()
            .ok_or_else(|| anyhow::anyhow!("No frame in flight"))?;
        ensure!(Instant::now() < frame.deadline, "Terminal frame expired");
        let bytes = &frame.bytes;
        ensure!(offset < bytes.len(), "Invalid terminal frame offset");
        Ok(&bytes[offset..bytes.len().min(offset + 64 * 1024)])
    }

    pub fn acknowledge(&mut self, stamp: FrameStamp) -> Result<()> {
        ensure!(
            self.pending
                .as_ref()
                .is_some_and(|frame| frame.stamp == stamp && Instant::now() < frame.deadline),
            "Stale terminal acknowledgement"
        );
        self.pending = None;
        Ok(())
    }
}

impl FrameReceiver {
    pub fn new(runtime: Uuid) -> Self {
        Self {
            runtime,
            applied: None,
            pending: None,
        }
    }

    pub fn begin(&mut self, stamp: FrameStamp, length: usize) -> Result<()> {
        ensure!(stamp.runtime == self.runtime, "Terminal runtime changed");
        ensure!(
            self.applied
                .is_none_or(|revision| stamp.revision > revision),
            "Stale terminal frame"
        );
        ensure!(
            self.pending
                .as_ref()
                .is_none_or(|pending| stamp.revision > pending.stamp.revision),
            "Stale pending terminal frame"
        );
        ensure!(
            (1..=MAX_FRAME_BYTES).contains(&length),
            "Invalid terminal frame length"
        );
        self.pending = None;
        self.pending = Some(PendingFrame {
            stamp,
            length,
            bytes: Vec::with_capacity(length),
        });
        Ok(())
    }

    /// Return a display only after every byte and its identity have been validated.
    pub fn push(
        &mut self,
        stamp: FrameStamp,
        offset: usize,
        bytes: &[u8],
    ) -> Result<Option<Frame>> {
        let pending = self
            .pending
            .as_mut()
            .ok_or_else(|| anyhow::anyhow!("No pending terminal frame"))?;
        ensure!(
            stamp == pending.stamp,
            "Chunk belongs to another terminal frame"
        );
        ensure!(
            offset == pending.bytes.len(),
            "Out-of-order terminal frame chunk"
        );
        ensure!(
            bytes.len() <= pending.length - offset,
            "Terminal frame length exceeded"
        );
        pending.bytes.extend_from_slice(bytes);
        if pending.bytes.len() != pending.length {
            return Ok(None);
        }
        let pending = self.pending.take().unwrap();
        let frame: Frame = serde_json::from_slice(&pending.bytes)?;
        ensure!(frame.stamp == stamp, "Terminal frame identity mismatch");
        frame.dimensions.validate()?;
        self.applied = Some(stamp.revision);
        Ok(Some(frame))
    }

    pub fn disconnect(&mut self) {
        self.pending = None;
    }
}
