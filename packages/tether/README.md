# Tether

Tether is a browser workbench for source-bound feedback on agent changes.
Register Git worktrees, inspect source, select text, and save an annotation with
the exact source you reviewed. Each worktree keeps its own notes.

This implementation supports local and SSH worktrees, diff review, Go symbol
navigation, durable annotations and delivery to existing Amp sessions. Shared
service drafts are planned.
Source editing and Git changes are performed through your existing tools.

## Install with Home Manager

The shared Home Manager configuration includes Tether. From this repository's
root, activate the local checkout:

```sh
./scripts/install-home-manager.sh
```

After activation, run `tether` from any directory. Launching inside a registered
worktree opens that worktree. Reapply the installer after updating this checkout
to install the updated executable.

## Run

From the repository root:

```sh
nix run .#tether
```

Tether starts or reuses a local gateway and opens an authenticated browser.
The home screen lists machines. Choose a machine, then choose one of its
worktrees or **Register a worktree**. The **Machines** and **Worktrees** navigation
buttons return to those lists. Switching machines opens that machine's worktree
list. Direct worktree links and launches inside a registered worktree open their
target. Launching inside an unregistered repository prefills its path when you
register a local worktree.

For the local machine, **Browse…** opens the native folder chooser in its desktop
session. **Browse folders in Tether** provides an in-app browser for headless
use. The Linux package includes Zenity for native folder selection.

For an SSH machine, **Browse…** lists that machine's directories in Tether.
Use **Home**, **Up**, directory rows, and **Hidden** to navigate. You can enter
an absolute directory and click **Go to path**. **Use this folder** fills the
registration field. **Register worktree** confirms registration on the selected
machine. Listings show 200 folders per page and support directories containing
up to 20,000 entries. Unreadable entries are counted, and permission and connection
errors offer a retry.

The CLI also supports registration and inventory:

```sh
nix run .#tether -- register /absolute/path/to/worktree
nix run .#tether -- list
```

Select a file, highlight a range, and choose **Annotate selection**. Draft text
and its captured source recover from browser storage after a reload. Choose
**Save annotation** to persist the note in its worktree. **Keep draft for later**
makes the draft available through **Resume draft** in that worktree.

After a failed save, **Retry save annotation** reuses the same operation and
content. The text stays locked while its outcome is uncertain. Saved notes
remain readable after source edits and process restarts. **Refresh** explicitly
captures the selected view again.

## Send annotations to Amp

Open Amp in the reviewed worktree with the repository's readiff Amp plugin
enabled. Its **readiff connect** command publishes the session for discovery.
For SSH worktrees, run Amp and the plugin on that execution machine.

Open **Annotations**, choose a session, select up to 20 saved annotations and
choose **Preview annotations**. The saved preview shows the recipient and exact
message, including captured source and comparison evidence. A batch supports up
to 256 KiB of message text. Choose a smaller selection if it exceeds this limit.

**Send to Amp** queues the preview as a steering message and can start agent work.
The recipient and message remain fixed for that submission. Saved annotations
remain available after sending. Agent replies are visible in Amp.

**Delivery history** retains previews and delivery outcomes through browser,
gateway and worktree-service restarts. **Confirmed** means the bridge found the
feedback in the Amp transcript. **Unconfirmed** includes queued feedback and
interrupted requests. Use **View submission**, then **Check delivery**, to check
the original submission with its original identity. An accepted submission can
be checked repeatedly.

If the original Amp plugin connection closes or restarts, Tether blocks retries
through the replacement connection. Inspect the target thread before preparing
another batch. This protects against duplicate feedback when the bridge loses
its receipt cache. Delivery history retains the exact message for that check.
Physical cleanup of retained submissions remains planned.

## Connect an SSH machine

The remote machine needs Nix and working SSH access. Confirm access in a
terminal, using your own host alias:

```sh
ssh dev-host
```

Choose **Connect machine**, type an SSH alias, hostname, IP address or `user@host`,
and choose **Connect machine** to attempt the connection. The field also offers
fuzzy suggestions from literal `Host` aliases in the gateway account's
`~/.ssh/config`. Use ↑/↓ and Enter to select a suggestion, then confirm with
**Connect machine**. **Change host** returns to the input.
Registered SSH destinations show a red validation message and block submission.
Open their existing machine entry to review worktrees. Suggestions exclude wildcard
and negated patterns. Direct entry supports destinations covered by wildcard rules
and included configuration files.

Connecting authorizes automatic setup when Tether is missing. The Nix-packaged
gateway transfers its pinned Tether and nixpkgs sources over SSH, builds Tether
for the remote platform, and installs it in the remote account's
`~/.local/share/tether/installations/` directory. Home Manager profiles stay
unchanged. A setup card in Machines shows a progress bar, the current phase,
elapsed time and live Nix transfer and build output. The card retains progress
and output while you browse other machines or worktrees. The scrollable output
panel retains the latest 32,768 characters
and follows new output while you are at the bottom. Output remains available after
a failed attempt. Initial builds can take several minutes and require access to
Nix caches and package sources. Each setup phase has a 30-minute timeout. Retry after a setup failure
to reuse completed Nix build work. If Nix is missing, install it on the remote
machine and retry.

Tether reuses the setup installation matching the gateway's sources, then the
most recent successful setup installation. It also finds existing executables
through PATH, the account's `.nix-profile`, the NixOS
per-user profile and the system profile. The remote handshake checks protocol
compatibility. Successful connections appear in Machines and persist across
gateway restarts. Closing the browser during setup leaves the operation running.
Reconnect or reload Machines to check its result.

### Check and update machines

Machine cards and the selected machine's header show **Up to date**,
**Update available**, **Updating…**, or **Unavailable**. Checks run every minute
while the view is open. Use **Check version** to check immediately. Hover over
the status to see the installed version, source-build ID and gateway build.
Older installations with an unknown build ID show an available update.

Choose **Update**, review the installed and target builds, then confirm
**Update machine**. The target is the local gateway's pinned build. Each machine
card contains its update controls, progress bar and installation output. Updates
started from the workbench header use a dialog. Failed updates offer the same action
for retry. Closing the browser leaves an accepted update running, and reopening
the machine shows its status. Each machine accepts one update at a time.

Expand **Update log** on a machine card to see the latest phase and installation
output after navigation or a browser reload. The gateway retains the latest
update's final result and up to 32 KiB of output per machine until its next update
or a gateway restart. Use the square **Cancel update** button beside refresh to
stop an active update. Its log remains available afterward. Cancellation stops
the installer and its remote build request. Completed Nix build work can be
reused on retry. If activation already completed, the installed build remains.

Updates preserve registered worktrees, source captures, saved annotations and
browser drafts. New requests use the updated worktree services immediately.
Previous services finish their requests and exit after their idle timeout.
Automatic remote updates require the Nix-packaged gateway. Update the local
gateway through its installer and restart it to use the new build.

Tether uses system SSH configuration, existing keys and known-host records.
Complete password, key-unlocking and host-key confirmation prompts in your
terminal before connecting from the browser. Browser connections require
noninteractive authentication and strict host-key verification. Ports and jump
hosts come from SSH configuration.

Browse and register a worktree on the selected machine to review its changes.
Source reads, annotations and Go analysis execute on that machine. Its state
directory retains the registered worktrees and annotations. Source caches and
recovery drafts in your browser include machine identity. The same directory
path on two machines has independent registration and review state.

When a connection fails, the selected machine remains visible with its error.
Retry after restoring SSH access. A changed remote state identity requires an
explicit connection through **Connect machine**. Each request currently opens
an SSH command, with bounded responses and a 65-second request timeout.
Discovery through SSH `Include` files, interactive authentication in the browser and
connection pooling remain planned.

## Review changes and explore Go

Worktrees open in **Explorer**, which browses files and folders even when the
worktree is clean. Expand a folder to load its immediate children. Large folders
show 200 entries at a time with **Load more entries**. Hidden and ignored files
are included. Git metadata and symbolic links are excluded. **Refresh** reloads
expanded folders and the selected source.

Choose **Changes** for diff review. **Uncommitted** compares HEAD with saved
worktree content, including eligible untracked files. **Staged** compares HEAD
with the index. **Unstaged** compares the index with saved content.
Changes refresh every five seconds. An open composer holds its captured
comparison and source. Use the arrow buttons to move between changed ranges.

Changed files appear in collapsible folders with change markers. Filter by path
in Changes to reveal matching files and their parent folders. **Files** toggles
the sidebar. Use the header
selectors to switch machines and worktrees. **Annotations** opens saved notes and
recovery drafts. Save or keep the draft for later to return to browsing.

Split diffs align corresponding lines and share scrolling, with a single vertical
scrollbar on the right. Scroll over either side to move the comparison.

Hover over a source line and click the gutter **+** to open an inline comment
directly beneath it. Drag over the line numbers to select several lines, then click **+**
beside the selection to annotate the whole range. Text selections also support
**Annotate selection** in the toolbar. The context menu offers **Annotate line or
selection**. These controls work in source review, both diff sides and Go exploration.
Blank and unchanged lines can receive annotations. Saved comments appear beneath
their captured ranges when viewing the matching source and comparison side.

Click **+**, **Annotate selection**, or **Annotate hunk** again to restart a draft
at the chosen range. An empty draft is replaced immediately. A draft containing
text opens **Discard draft?** inside the inline comment. **Keep editing** or
Escape preserves its text and captured range. **Discard draft** removes its
browser recovery copy and opens the new composer. A submitted draft stays bound
to its original source while its save is pending or awaiting retry.

Use Shift+Arrow keys to select source with the keyboard. Ctrl+Enter (Cmd+Enter on
macOS) starts an annotation for the selected lines or current line. In the
composer, the same shortcut saves the annotation. Escape or the comment's **×**
closes it and keeps its recovery draft in **Annotations**. F6 switches focus
between source and comment. The discard dialog starts
on **Keep editing**. Tab moves between its buttons and Enter activates one.

Use the hunk arrows to choose a change, then **Annotate hunk** above either diff
side to annotate that side's changed lines. A hunk annotation retains its line
range, captured comparison, base and target sources, and selected side. The action
is disabled for a side with no lines in that hunk. Each saved review note retains
its comparison and selected side. An unborn repository uses an empty baseline.
Additions and deletions show an absent-side label. Renames appear as deletion and
addition entries. Binary, symlink, submodule and conflict entries report their
text-review limitation when opened.

For a Go file, choose **Explore current version**. Enable Go analysis only for
worktrees you trust. gopls can invoke the Go toolchain and access project
dependencies. Install Go on the execution machine and make dependencies available
locally. The Nix package includes gopls. Tether disables automatic Go toolchain
and module-proxy downloads for analysis.

Hover shows signatures and documentation. F12 opens a definition, Alt+F12 peeks
inline, and Shift+F12 opens references. The editor context menu includes type
definitions and implementations. **Symbols** opens the current file's outline.
**Back** and **Forward** restore visited source positions. **Return to review**
restores the captured diff while keeping the annotation composer available.
Go source has syntax highlighting on both historical and current views.

Analysis covers Go source and module files inside the selected worktree. Changes
to these files or HEAD invalidate an earlier analysis context. **Reload current**
loads the new context. Each worktree runs its own gopls session. Go sessions
restart when their captured project context changes. This slice supports up to
16 MiB of project source and 100 locations per query. Dependency-source navigation,
workspace symbol search, call hierarchy and diagnostics are pending. Review
positions across worktree switches and automatic mapping across revisions remain
follow-up work.

## Login, state and shutdown

The default origin is `http://127.0.0.1:47831`. Use `--port PORT` when starting a
gateway on another port. A running gateway retains its existing port.
`--no-browser` prints a single-use login link valid for 60 seconds. Treat the
link as a credential. Browser authorization lasts 30 days and survives gateway
restarts.

**Sign out** offers save, export, discard and cancel for browser recovery drafts.
Export produces a JSON file containing draft text and source evidence. The
dialog can also revoke all browser sessions. Disconnected browsers can retain
their local draft data. Automatic session expiry preserves recovery drafts.

State defaults to `$XDG_STATE_HOME/tether`, or `~/.local/state/tether`. Use
`--state-dir /absolute/private/directory` for an independent instance. Existing
state directories require mode `0700`. State includes source text and review
content. Keep it private.

The current limits are UTF-8 regular files up to 64 KiB, 20,000 source paths for
Go analysis and unborn-repository comparisons, 100 returned notes per worktree,
and 1 MiB service responses. Explorer loads each folder independently. Symbolic links
and Git metadata are excluded from source reads. Saved notes leave the active
list after three calendar months. Physical expiry cleanup remains planned.

Stop the gateway explicitly:

```sh
nix run .#tether -- quit
```

Closing a browser leaves the gateway running. Worktree services exit after
five idle minutes and start again when needed. Gateway shutdown preserves
saved annotations and their captured source.

## Build and check

From the repository root:

```sh
nix build .#tether
nix develop .#tether
```

The development shell provides the Rust and Go toolchains, gopls, Node.js, Git,
pre-commit and the formatting tools. Within `packages/tether`, build the browser
assets before the Rust executable:

```sh
npm --prefix frontend ci
npm --prefix frontend run build
cargo build --locked
cargo test --locked
cargo clippy --all-targets -- -D warnings
cargo fmt --check
./target/debug/tether
```

After changing wire types, regenerate their browser declarations:

```sh
cargo run --bin tether-schema > frontend/src/protocol.ts
```

`nix build .#tether` runs the process-level integration tests and checks that
the browser declarations match the Rust schema. The package is available
without activating Home Manager. The initial executable has been validated
on Apple Silicon macOS. Linux validation remains outstanding.

### Pre-commit checks

Install the hook once per clone and run the same checks manually from the
repository root:

```sh
nix develop .#tether --command pre-commit install
nix develop .#tether --command pre-commit run --all-files
```

The Tether hook runs when its package, owning Nix module or pre-commit configuration
changes. It installs pinned frontend dependencies, checks formatting, lints,
type-checks, builds the UI, runs Rust integration tests with real gopls and checks
the generated protocol schema. Initial runs need network access to fetch tools.

| Files                       | Checks                                                  |
| --------------------------- | ------------------------------------------------------- |
| Rust                        | rustfmt, Clippy with warnings denied, integration tests |
| TypeScript, TSX, JavaScript | TypeScript, ESLint with React Hooks rules, Prettier     |
| CSS                         | Stylelint, Prettier                                     |
| HTML, JSON, Markdown, YAML  | Prettier                                                |
| TOML                        | Taplo format and validation                             |
| Nix                         | nixfmt, Statix, deadnix                                 |
| Bash                        | ShellCheck, shfmt                                       |

To apply formatting, run `cargo fmt --manifest-path packages/tether/Cargo.toml`
and `npm --prefix packages/tether/frontend run format` from the repository root.
Use `nixfmt`, `taplo fmt` and `shfmt -w` for the corresponding configuration files
inside the development shell. Generated `protocol.ts` is checked against the Rust
schema through the generation command above.
