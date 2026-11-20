# Tether

Tether is a browser workbench for source-bound feedback on agent changes.
Register Git worktrees, inspect source, select text, and save an annotation with
the exact source you reviewed. Each worktree keeps its own notes.

This implementation supports local and SSH worktrees, diff review, Go symbol
navigation and durable annotations. Shared service drafts and Amp delivery are planned.
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

## Connect an SSH machine

Install this checkout's Tether build on the remote machine. You can use its Home
Manager installer from a copy of this checkout on that host. Confirm SSH access
and the executable in a terminal, using your own host alias:

```sh
ssh dev-host tether --version
```

Choose **Connect machine** and select a host from the gateway account's
`~/.ssh/config`. The picker lists unique, literal `Host` aliases from that file.
Wildcard and negated patterns are excluded. Use **Enter another destination…**
for a host supplied through an included configuration file or a `user@host` address.
Tether locates its remote executable through PATH, the account's `.nix-profile`,
the NixOS per-user profile or the system profile.
Successful connections appear in the machine selector and persist across
gateway restarts. Adding a machine requires an installed matching release.

Tether uses system SSH configuration, existing keys and known-host records.
Complete password, key-unlocking and host-key confirmation prompts in your
terminal before connecting from the browser. Browser connections require
noninteractive authentication and strict host-key verification. Ports and jump
hosts come from SSH configuration. Tether leaves remote installation to you.

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

The initial **Uncommitted** view compares HEAD with saved worktree content,
including eligible untracked files. **Staged** compares HEAD with the index.
**Unstaged** compares the index with saved content. **All source** browses the
worktree. Changes refresh every five seconds. An open composer holds its captured
comparison and source. Use the arrow buttons to move between changed ranges.

Select text on either side to annotate it. Each saved review note retains its
comparison and selected side. An unborn repository uses an empty baseline.
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

The current limits are UTF-8 regular files up to 64 KiB, 20,000 source paths,
100 returned notes per worktree, and 1 MiB service responses. Symbolic links
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
