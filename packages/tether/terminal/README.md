# Tether terminal recovery

This library owns terminal state for Tether's execution-machine managed sessions.
The worktree service drains PTY output and provides bounded browser recovery frames.

From the repository root, run its checks with:

```sh
nix develop .#tether --command cargo test --locked --manifest-path packages/tether/Cargo.toml -p tether-terminal
```

## Feed output and recover a display

Create a `Terminal` with `Dimensions`. Serialize PTY reads and resizes through that
owner. `advance` accepts up to 4 KiB per call and returns terminal-query replies
for the PTY writer. Drain output while viewers are disconnected. `resize` accepts
2–512 columns and 1–200 rows. Invalid dimensions and oversized reads fail before
changing terminal state.

`frame` captures the current display and retained history. It carries a random
runtime identity and a revision shared by output and resize operations. Its
`painting` string is generated terminal rendering data. Set the display's size to
the frame's dimensions and apply a complete painting to xterm.js. Feed subsequent
PTY output to `Terminal::advance`. Each later painting replaces the display.

The supported display includes normal and alternate screens, cursor visibility,
ANSI/RGB cell styles, combining characters, wide characters and selected input
modes. The service retains parsing state between frames, including incomplete
UTF-8 and escape sequences, saved cursors and scrolling margins. Clipboard,
hyperlink, title, dynamic-palette and extended-keyboard handlers are disabled in
this qualification boundary. Qualify each harness against this supported subset.

## Preserve browser selection

`../frontend/src/TerminalDisplay.ts` exports `TerminalDisplay` for xterm.js 6. Import xterm's
CSS, open a terminal with `allowProposedApi: true` and `scrollback: 10000`, then
construct `TerminalDisplay(terminal, runtimeIdentity, changed)`. The adapter
activates Unicode 11 widths, which align the exercised `🔒` emoji with the Rust
emulator. Broader Unicode and grapheme compatibility requires further checks.

Pass complete, size-validated `Frame` objects to `apply`. Treat each accepted frame
as immutable. Runtime identity, increasing safe-integer revision and dimensions
are checked before acceptance. A concurrent call during painting fails.

- `apply` resolves to `"displayed"` after xterm's write callback, or `"held"` when
  selection, a selection gesture or a scrolled-back viewport pins the display.
  A newer held frame replaces the previous held frame. Selection retains its
  original text, viewport and dimensions while PTY output and service-side history
  eviction continue.
- Acknowledge the exact frame stamp after either result. This receipt releases
  the sender's frame. `displayedStamp` separately identifies the completed paint.
  Stop requesting captures while `paused` or `rendering` is true. Once both are
  false, request current state again. A held receipt therefore permits a person
  to read past the transport deadline without retaining a server-side frame.
- Use the `changed` callback to refresh the visible pause status and set
  `terminal.options.disableStdin` whenever the display is paused, painting,
  disconnected, awaiting a fresh recovery frame or lacking input control. This
  prevents xterm from clearing selection as a side effect of user input. Check
  the control grant independently when forwarding input and resize requests.
- Provide a **Resume live output** action that calls `terminal.clearSelection()`
  and `terminal.scrollToBottom()`. Releasing the last pin paints the held frame.
  Input remains disabled until the current-state refresh completes.
- With harness mouse reporting enabled, normal clicks reach the harness.
  Forced selection follows xterm's platform convention: Shift-drag on Linux,
  or Option-drag on macOS with `macOptionClickForcesSelection: true`.
- Retain the adapter across connection loss to the same runtime. Feed only fully
  assembled recovery frames to it. Dispose the adapter and its xterm together
  when changing runtime or removing the view. Disposal releases the held frame
  and rejects an outstanding `apply`.

The adapter owns display updates. Route terminal writes and screen resizes through
`apply` so that layout changes preserve pinned content. Browser pane resizing can
clip or pan the existing screen until a frame is displayed.

From the repository root, install and run the browser checks:

```sh
npm --prefix packages/tether/terminal/browser ci --ignore-scripts
npm --prefix packages/tether/terminal/browser run check
npm --prefix packages/tether/terminal/browser test
```

The tests use Playwright's installed Chromium. Set `CHROME_BIN` to an existing
Chrome executable to use that browser. To install Chromium, run
`npm exec --prefix packages/tether/terminal/browser -- playwright install chromium`.
Regenerate browser protocol types after changing the Rust frame types:

```sh
nix develop .#tether --command cargo run --quiet --locked --manifest-path packages/tether/Cargo.toml -p tether-terminal --example browser_schema > packages/tether/terminal/browser/src/protocol.ts
```

## Bound input and delivery

- History retains up to 10,000 rows within an 8 MiB conservative allocation charge.
  Oldest rows are evicted first. Resizing can evict more history. Screen storage,
  emulator caches, parsing and frame buffers have separate allocation costs.
  The history charge describes retained history. Total process memory includes
  those additional allocations.
- A cell retains up to 16 combining marks. Excess marks are dropped and counted
  in `Frame::rejected_marks`.
- OSC input is limited to 4 KiB. Excess payload is discarded until its terminator
  or a new escape sequence. `Frame::rejected_osc` reports these events.
- Query replies are limited to 4 KiB per input call. Reply overflow returns an
  error after consuming that input. Surface the fault and continue draining the
  PTY. Subsequent calls can still produce replies and display updates.
- Encoded frames are limited to 32 MiB. `FrameSender` retains one frame per
  attachment until its exact stamp is acknowledged or its 30-second deadline
  expires. Retrieve chunks of up to 64 KiB with `chunk`. The next `start` captures
  current terminal state. Call `expire` from the transport owner's independent
  timer and release the attachment when it returns true. Chunk requests and
  acknowledgements also enforce this deadline.
- `FrameReceiver` accepts a length and stamp with `begin`, followed by contiguous
  byte offsets through `push`. It returns a frame after the complete JSON payload,
  dimensions and identity validate. Superseded, reordered and foreign-runtime
  chunks fail. A newer `begin` replaces an unfinished frame. `disconnect` drops
  unfinished bytes and preserves the last received revision.

Drop an attachment's sender when its transport closes or times out. Recreate it
when reconnecting, retaining the execution-machine `Terminal`. Keep the visible
display until a complete replacement arrives. Authenticate the attachment and
its runtime identity before accepting frames. Tether's managed-session interface
enforces attachment leases, control generations and fresh display receipts.
