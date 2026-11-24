use alacritty_terminal::{
    Term,
    event::VoidListener,
    grid::Dimensions as _,
    index::{Column, Line},
    term::Config,
    vte::ansi::Processor,
};
use tether_terminal::{
    Dimensions, Frame, FrameReceiver, FrameSender, MAX_FRAME_BYTES, MAX_HISTORY_BYTES,
    MAX_INPUT_BYTES, MAX_OSC_BYTES, Terminal,
};

fn terminal(columns: usize, rows: usize) -> Terminal {
    Terminal::new(Dimensions { columns, rows }).unwrap()
}

fn output(terminal: &mut Terminal, bytes: &[u8]) {
    for chunk in bytes.chunks(MAX_INPUT_BYTES) {
        terminal.advance(chunk).unwrap();
    }
}

fn display(frame: &Frame) -> Vec<String> {
    let mut view = Term::new(Config::default(), &frame.dimensions, VoidListener);
    let mut parser: Processor = Processor::new();
    parser.advance(&mut view, frame.painting.as_bytes());
    let grid = view.grid();
    (-(grid.history_size() as i32)..frame.dimensions.rows as i32)
        .map(|line| {
            let mut text = String::new();
            for column in 0..frame.dimensions.columns {
                let cell = &grid[Line(line)][Column(column)];
                text.push(cell.c);
                for mark in cell.zerowidth().unwrap_or_default() {
                    text.push(*mark);
                }
            }
            text.trim_end().to_string()
        })
        .collect()
}

#[test]
fn continuation_preserves_hidden_state_across_every_byte_boundary() {
    for (prefix, suffix, expected) in [
        (
            "HEADER\x1b[3;7H\x1b7\x1b[5;2HACTIVE",
            "\x1b8X",
            vec!["HEADER", "", "      X", "", " ACTIVE", ""],
        ),
        (
            "HEADER\x1b[6;1HFOOTER\x1b[2;5r\x1b[5;1HBOTTOM",
            "\r\nNEXT\r\nLAST",
            vec!["HEADER", "", "BOTTOM", "NEXT", "LAST", "FOOTER"],
        ),
        (
            "NORMAL café\r\n\x1b[?1049hWAIT",
            "\x1b[?1049lAPPROVED",
            vec!["NORMAL café", "APPROVED", "", "", "", ""],
        ),
        (
            "\x1b[3g\x1b[5G\x1bH\x1b[12G\x1bH\rA",
            "\tB\tC",
            vec!["A   B      C", "", "", "", "", ""],
        ),
        ("BASE\x1b[31;", "1mRED", vec!["BASERED", "", "", "", "", ""]),
        (
            "BASE\x1b]0;title",
            " continued\x07VISIBLE",
            vec!["BASEVISIBLE", "", "", "", "", ""],
        ),
    ] {
        let bytes = format!("{prefix}{suffix}").into_bytes();
        for split in 0..=bytes.len() {
            let mut state = terminal(24, 6);
            output(&mut state, &bytes[..split]);
            state.frame().unwrap();
            output(&mut state, &bytes[split..]);
            assert_eq!(
                display(&state.frame().unwrap()),
                expected,
                "split {split} of {prefix:?}"
            );
        }
    }
}

#[test]
fn utf8_queries_and_resize_continue_while_detached() {
    let mut state = terminal(24, 6);
    state.advance(&[0xe7]).unwrap();
    state.frame().unwrap();
    state
        .resize(Dimensions {
            columns: 31,
            rows: 9,
        })
        .unwrap();
    state.advance(&[0x95, 0x8c]).unwrap();
    assert!(display(&state.frame().unwrap())[0].starts_with('界'));
    assert_eq!(
        state.advance(b"\x1b[3;7H\x1b[6n\x1b[5n").unwrap(),
        b"\x1b[3;7R\x1b[0n"
    );
    let before = state.frame().unwrap();
    assert!(
        state
            .resize(Dimensions {
                columns: usize::MAX,
                rows: 9
            })
            .is_err()
    );
    assert!(state.advance(&vec![b'x'; MAX_INPUT_BYTES + 1]).is_err());
    assert_eq!(state.frame().unwrap().stamp, before.stamp);
    assert_eq!(state.frame().unwrap().painting, before.painting);
}

#[test]
fn control_string_and_combining_floods_leave_a_usable_terminal() {
    let mut state = terminal(24, 6);
    output(&mut state, b"e");
    output(&mut state, "\u{301}".repeat(17).as_bytes());
    let frame = state.frame().unwrap();
    assert_eq!(frame.rejected_marks, 1);
    assert_eq!(display(&frame)[0], format!("e{}", "\u{301}".repeat(16)));
    for terminator in [b"\x07".as_slice(), b"\x1b\\", b"\x18", b"\x1a"] {
        output(&mut state, b"\x1b]0;");
        output(&mut state, &vec![b'x'; MAX_OSC_BYTES * 2]);
        output(&mut state, terminator);
    }
    output(&mut state, b"\r\nRECOVERED");
    let frame = state.frame().unwrap();
    assert_eq!(frame.rejected_osc, 4);
    assert_eq!(display(&frame)[1], "RECOVERED");

    let mut boundary = terminal(24, 6);
    output(&mut boundary, b"\x1b]");
    output(&mut boundary, &vec![b'x'; MAX_OSC_BYTES]);
    output(&mut boundary, b"\x07");
    assert_eq!(boundary.frame().unwrap().rejected_osc, 0);
    output(&mut boundary, b"\x1b]");
    output(&mut boundary, &vec![b'x'; MAX_OSC_BYTES + 1]);
    output(&mut boundary, b"\x07VISIBLE");
    assert_eq!(boundary.frame().unwrap().rejected_osc, 1);
    assert_eq!(display(&boundary.frame().unwrap())[0], "VISIBLE");

    for prefix in [
        b"\x1b\0]".as_slice(),
        b"\x1b\x7f]",
        b"\x1b\xff]",
        b"\x1b\x1b]",
    ] {
        let mut escaped = terminal(24, 6);
        output(&mut escaped, prefix);
        output(&mut escaped, &vec![b'x'; MAX_OSC_BYTES + 1]);
        output(&mut escaped, b"\x1b[HOK");
        assert_eq!(escaped.frame().unwrap().rejected_osc, 1);
        assert_eq!(display(&escaped.frame().unwrap())[0], "OK");
    }
}

#[test]
fn dense_maximum_screen_remains_deliverable_after_narrow_reflow() {
    let mut state = terminal(512, 200);
    let marks = "\u{1d185}".repeat(16);
    let mut row = String::new();
    for column in 0..512 {
        let red = if column % 2 == 0 { 123 } else { 255 };
        row.push_str(&format!(
            "\x1b[1;2;3;4:3;7;9;38;2;{red};234;234;48;2;234;234;234;58;2;234;234;234mX{marks}"
        ));
    }
    for _ in 0..300 {
        output(&mut state, row.as_bytes());
        output(&mut state, b"\r\n");
    }
    let frame = state.frame().unwrap();
    let bytes = frame.encode().unwrap();
    let mut receiver = FrameReceiver::new(frame.stamp.runtime);
    receiver.begin(frame.stamp, bytes.len()).unwrap();
    let mut received = None;
    for (index, chunk) in bytes.chunks(65_536).enumerate() {
        received = receiver.push(frame.stamp, index * 65_536, chunk).unwrap();
    }
    let recovered = received.unwrap();
    assert_eq!(recovered.painting, frame.painting);
    assert!(frame.history_bytes <= MAX_HISTORY_BYTES);
    state
        .resize(Dimensions {
            columns: 2,
            rows: 200,
        })
        .unwrap();
    output(&mut state, b"\x1b[0m\x1b[HOK");
    let narrow = state.frame().unwrap();
    let rows = display(&narrow);
    assert_eq!(rows[narrow.history_rows], "OK");
    assert!(narrow.history_bytes <= MAX_HISTORY_BYTES);
}

#[test]
fn query_flood_reports_overflow_and_allows_subsequent_output() {
    let mut state = terminal(24, 6);
    assert!(state.advance(b"\x1b[6n".repeat(1024).as_slice()).is_err());
    output(&mut state, b"RECOVERED");
    assert_eq!(display(&state.frame().unwrap())[0], "RECOVERED");
    assert_eq!(state.advance(b"\x1b[6n").unwrap(), b"\x1b[1;10R");
}

#[test]
fn byte_budget_evicts_oldest_history_and_survives_alternate_resize() {
    let mut narrow = terminal(2, 1);
    output(&mut narrow, b"A\r\n");
    output(&mut narrow, &b"B\r\n".repeat(10_000));
    output(&mut narrow, b"Z");
    let narrow_frame = narrow.frame().unwrap();
    assert_eq!(narrow_frame.history_rows, 10_000);
    let narrow_rows = display(&narrow_frame);
    assert_eq!(narrow_rows.first().unwrap(), "B");
    assert_eq!(narrow_rows.last().unwrap(), "Z");

    let mut state = terminal(240, 6);
    let lines: String = (0..16_000)
        .map(|index| format!("record-{index}\r\n"))
        .collect();
    output(&mut state, lines.as_bytes());
    output(&mut state, b"CURRENT");
    let frame = state.frame().unwrap();
    // The charge reserves two 240-cell allocations and one 32-byte row header.
    assert_eq!(frame.history_rows, 726);
    assert_eq!(frame.history_bytes, 8_386_752);
    let rows = display(&frame);
    assert_eq!(rows.first().unwrap(), "record-15269");
    assert_eq!(rows.last().unwrap(), "CURRENT");
    assert!(frame.history_bytes <= MAX_HISTORY_BYTES);

    output(&mut state, b"\x1b[?1049hWAIT");
    state
        .resize(Dimensions {
            columns: 512,
            rows: 100,
        })
        .unwrap();
    output(&mut state, b"\x1b[?1049l\r\nAFTER");
    let frame = state.frame().unwrap();
    assert!(frame.history_bytes <= MAX_HISTORY_BYTES);
    assert!(display(&frame).iter().any(|row| row == "AFTER"));
}

#[test]
fn slow_clients_hold_one_frame_and_reconnect_to_current_state() {
    let mut state = terminal(80, 24);
    output(&mut state, b"OLD");
    let mut sender = FrameSender::default();
    let (old, length) = sender.start(&state).unwrap();
    let mut receiver = FrameReceiver::new(old.runtime);
    receiver.begin(old, length).unwrap();
    assert!(
        receiver
            .push(old, 0, &sender.chunk(0).unwrap()[..17])
            .unwrap()
            .is_none()
    );
    for _ in 0..100 {
        output(&mut state, b"\rNEW");
    }
    state
        .resize(Dimensions {
            columns: 93,
            rows: 27,
        })
        .unwrap();
    assert!(sender.start(&state).is_err());
    receiver.disconnect();
    drop(sender);

    let mut sender = FrameSender::default();
    let (current, length) = sender.start(&state).unwrap();
    receiver.begin(current, length).unwrap();
    assert!(receiver.push(old, 17, b"late").is_err());
    assert!(receiver.push(current, 1, b"unordered").is_err());
    let mut offset = 0;
    let mut frame = None;
    while offset < length {
        let chunk = sender.chunk(offset).unwrap();
        frame = receiver.push(current, offset, chunk).unwrap();
        offset += chunk.len();
    }
    let frame = frame.unwrap();
    assert_eq!(display(&frame)[0], "NEW");
    assert_eq!(
        frame.dimensions,
        Dimensions {
            columns: 93,
            rows: 27
        }
    );
    assert!(sender.acknowledge(old).is_err());
    sender.acknowledge(current).unwrap();
    assert!(receiver.begin(old, length).is_err());
    assert!(receiver.begin(current, length).is_err());
    let other = terminal(80, 24).frame().unwrap();
    assert!(receiver.begin(other.stamp, length).is_err());
    output(&mut state, b"NOW");
    let (next, _) = sender.start(&state).unwrap();
    assert!(receiver.begin(next, MAX_FRAME_BYTES + 1).is_err());
}

#[test]
fn malformed_complete_frames_preserve_the_last_applied_revision() {
    let mut state = terminal(24, 6);
    let frame = state.frame().unwrap();
    let mut receiver = FrameReceiver::new(frame.stamp.runtime);
    receiver.begin(frame.stamp, 1).unwrap();
    assert!(receiver.push(frame.stamp, 0, b"{").is_err());
    let bytes = frame.encode().unwrap();
    receiver.begin(frame.stamp, bytes.len()).unwrap();
    assert!(receiver.push(frame.stamp, 0, &bytes).unwrap().is_some());
    output(&mut state, b"NEXT");
    let next = state.frame().unwrap();
    receiver.begin(next.stamp, bytes.len()).unwrap();
    assert!(receiver.push(next.stamp, 0, &bytes).is_err());
    receiver
        .begin(next.stamp, next.encode().unwrap().len())
        .unwrap();
}

#[test]
fn delivery_deadlines_release_unacknowledged_frames_and_allow_held_receipts() {
    use std::time::Duration;

    let mut state = terminal(80, 24);
    output(&mut state, b"BEFORE");
    let mut sender = FrameSender::default();
    let (old, _) = sender.start(&state).unwrap();
    let deadline = sender.deadline().unwrap();
    assert!(!sender.expire(deadline - Duration::from_nanos(1)));
    assert!(sender.chunk(0).is_ok());
    assert!(sender.expire(deadline));
    assert!(sender.chunk(0).is_err());
    assert!(sender.acknowledge(old).is_err());

    output(&mut state, b"\rAFTER ");
    let (fresh, _) = sender.start(&state).unwrap();
    assert!(fresh.revision > old.revision);
    sender.acknowledge(fresh).unwrap();
    assert!(!sender.expire(deadline + Duration::from_secs(300)));
    assert!(sender.deadline().is_none());
    assert!(sender.start(&state).is_ok());
}
