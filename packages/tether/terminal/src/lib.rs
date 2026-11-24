mod emulator;
mod frame;
mod guard;

pub use emulator::{Dimensions, Terminal};
pub use frame::{Frame, FrameReceiver, FrameSender, FrameStamp};

pub const MAX_INPUT_BYTES: usize = 4096;
pub const MAX_HISTORY_BYTES: usize = 8 * 1024 * 1024;
pub const MAX_HISTORY_ROWS: usize = 10_000;
pub const MAX_FRAME_BYTES: usize = 32 * 1024 * 1024;
pub const MAX_OSC_BYTES: usize = 4096;
pub const MAX_COMBINING_MARKS: usize = 16;
