use crate::MAX_OSC_BYTES;

#[derive(Default)]
enum State {
    #[default]
    Ground,
    Escape,
    Osc(usize),
    DiscardOsc,
}

#[derive(Default)]
pub(crate) struct OscGuard {
    state: State,
    pub rejected: u64,
}

impl OscGuard {
    // CAN cancels an oversized OSC before VTE can allocate another byte.
    pub fn filter(&mut self, byte: u8) -> Option<u8> {
        match (&self.state, byte) {
            (_, 0x1b) => self.state = State::Escape,
            (State::Escape, b']') => self.state = State::Osc(0),
            (State::Escape, 0x00..=0x17 | 0x19 | 0x1c..=0x1f | 0x7f..=0xff) => {}
            (State::Escape, _) => self.state = State::Ground,
            (State::Osc(_) | State::DiscardOsc, 0x07 | 0x18 | 0x1a) => {
                self.state = State::Ground;
            }
            (State::Osc(length), _) if *length >= MAX_OSC_BYTES => {
                self.state = State::DiscardOsc;
                self.rejected = self.rejected.saturating_add(1);
                return Some(0x18);
            }
            (State::Osc(length), _) => self.state = State::Osc(length + 1),
            (State::DiscardOsc, _) => return None,
            _ => {}
        }
        Some(byte)
    }
}
