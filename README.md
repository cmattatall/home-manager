# Personal environment

This repository contains Carl's Home Manager environment and personal tools.
It supports Linux and macOS, with portable shell helpers and the readiff editor.

## Repository layout and development

| Path | Purpose |
| --- | --- |
| `flake.nix`, `flake.lock` | Inputs and dependency pins for the whole repository |
| `modules/` | Dendritic configuration features and package integration |
| `modules/profiles/` | MacBook and development-node profiles |
| `packages/<name>/` | Self-contained programs, with their source, tests, documentation, and build files |
| `shell/` | Portable Bash/Zsh helpers and Starship settings |
| `scripts/` | Installation and publishing commands |
| `tests/` | Environment and repository workflow tests |

Configuration follows the [dendritic pattern](https://github.com/mightyiam/dendritic):
each Nix file under `modules/` is a flake-parts module for one feature. All are
loaded automatically through import-tree. A feature can contribute packages,
checks, development shells, and Home Manager settings in the same file.
Program source and package recipes belong under `packages/`.

Reusable Home Manager modules are available as `modules.homeManager.<name>`
and `homeModules.<name>`. The names are `default`, `macbook`, `development-node`,
`prompt`, `rediff`, and `zellij`. `default` combines the personal environment.
The profiles include it and add their platform settings. Use these exported
modules when composing another configuration.

Enter the repository development shell with `nix develop`. It provides Python,
Bash, Zsh, Git, and nixfmt for the environment tests and Nix formatting:

```sh
nix develop
python3 -m unittest discover -s tests -v
nix fmt -- flake.nix modules
```

### Add a program

Create `packages/my-tool/` with its source, native build files, tests, and a
`package.nix` recipe that accepts dependencies through `pkgs.callPackage`.
Keep its README focused on building and using the program. A standalone flake
is useful for an independently published project, as in `packages/readiff/`.
Smaller tools can use the root flake directly.

Expose the recipe in `modules/my-tool.nix`:

```nix
{
  perSystem = { pkgs, ... }: {
    packages.my-tool = pkgs.callPackage ../packages/my-tool/package.nix { };
  };
}
```

Add new files to Git so Nix includes them, then build with `nix build .#my-tool`.
For an executable package, set `meta.mainProgram` in its recipe and run it with
`nix run .#my-tool`. Add `perSystem.devShells.my-tool` for its development tools
and `perSystem.checks.my-tool` for its test derivation. Those are used by
`nix develop .#my-tool` and `nix flake check`.

To install that tool in the personal environment, the same module can also define:

```nix
{ withSystem, ... }:
{
  flake.modules.homeManager.default = { pkgs, ... }: {
    home.packages = [
      (withSystem pkgs.stdenv.hostPlatform.system ({ config, ... }: config.packages.my-tool))
    ];
  };
}
```

Package availability must cover the profiles that install it. The root package
outputs target `aarch64-darwin`, `aarch64-linux`, and `x86_64-linux`.
The Intel Mac Home Manager profile builds readiff with its own stable package set.

## Install Nix and Home Manager

On your MacBook (or another machine with a local checkout):

```sh
git clone https://github.com/cmattatall/home-manager.git ~/home-manager
cd ~/home-manager
./scripts/install-home-manager.sh
```

Run as yourself, not with `sudo`. Git is required for cloning.
Review the personal defaults before installing them on your own machine;
in particular, override `programs.git.settings.user` with your own identity.

The installer detects x86-64 Linux, Apple Silicon macOS (including a Rosetta
shell), or Intel macOS. It uses your actual username and `$HOME`, so it works
for `cmattatall` on a development node and `carl` on a Mac without editing Nix.

- A working Nix installation is reused, including one not yet on `PATH`.
- If Nix is absent on macOS, it runs the official multi-user installer from
  `https://nixos.org/nix/install`. That installer may ask for sudo and creates
  system services/volumes. A broken installation is never silently replaced.
- NixOS already supplies Nix; the script never installs a second copy there.
- A development node still running the system-managed Home Manager service
  for your account is left unchanged, with an explanatory message.
- An unmanaged account builds and activates this configuration. If the same
  Home Manager generation is already active, activation is skipped.
- The `readiff` and `desloppify` Amp plugins are replaced with repository versions.
  Other conflicting unmanaged dotfiles require review and backup before retrying,
  especially existing `.zshrc` and `kitty.conf`.

### Nix only

From this checkout, install or check Nix with:

```sh
./scripts/install-nix.sh
```

It prints the usable Nix executable path. Neither script rewrites global Nix
settings, changes your login shell, installs nix-darwin, or enables automatic
updates. Flake support is enabled for the invoked commands only.

The script installs Nix on macOS and reuses it on NixOS. For other Linux
distributions, follow the [Nix installation guide](https://nixos.org/download/).

For direct `nix build`, `nix run`, and `nix develop` commands, enable flakes in
`~/.config/nix/nix.conf`:

```conf
experimental-features = nix-command flakes
```

On NixOS, you can manage this through your system configuration instead:

```nix
nix.settings.experimental-features = [ "nix-command" "flakes" ];
```

Apply that setting through your usual NixOS deployment workflow.

### Apply a profile

The native profiles are `development-node`, `macbook`, and `macbook-intel`.
An explicit profile can be passed to `install-home-manager.sh`. Prefer this
script over a bare `home-manager switch`: it applies the local account identity
and checks for competing NixOS ownership.

To update that local installation, pull this checkout and rerun the same script:

```sh
git pull --ff-only
./scripts/install-home-manager.sh
```

### Install on a remote NixOS node without cloning

After SSHing into a development node, download and review the installer, then
run it with `--remote` as your normal user:

```sh
curl -fsSL https://raw.githubusercontent.com/cmattatall/home-manager/main/scripts/install-home-manager.sh \
  -o /tmp/install-home-manager.sh
less /tmp/install-home-manager.sh
bash /tmp/install-home-manager.sh --remote
```

`--remote` requires working Nix, but neither a repository checkout nor an existing
Home Manager CLI. It resolves published `main` over HTTPS, creates a revision-pinned
`~/home.nix` using your actual username and home directory, and builds and activates
that configuration. It uses the same platform detection and NixOS fleet-ownership
check as local installation; it does nothing while the fleet owns your home.
An explicit profile can follow `--remote` if needed.

The installer refuses to overwrite an existing `~/home.nix`. It creates the
standard Home Manager config symlink when absent, respecting `XDG_CONFIG_HOME`.
Existing config links/files are preserved; use `hm switch -f "$HOME/home.nix"`
explicitly if the standard path points elsewhere.

The generated configuration pins `programs.home-manager.path` to the same Home
Manager input as this repository. The first activation uses the flake's pinned
inputs without requiring channels. After activation, start a new shell:

```sh
hm_pull       # Update the revision in ~/home.nix to published main and switch
hm switch     # Reapply the current pin; hm is an alias for home-manager
```

Subsequent standalone Home Manager CLI commands need a compatible `nixpkgs`
entry in `NIX_PATH` (normally supplied by NixOS), but not a `home-manager` entry.
`hm_pull` preserves your other configuration edits and keeps the new revision
if activation fails, so you can retry `hm switch -f "$HOME/home.nix"`.
The separate `install-nix-home.sh` setup step is no longer needed. Existing
files generated by that script remain valid and are not automatically replaced.

## Project environments

The Mac and personal `development-node` profiles enable Zsh and direnv with
nix-direnv and Bash/Zsh integration. On Linux this is a per-user Home Manager setting,
not a system-wide NixOS default; only the account activating the profile opts in.
For a project with `nix/flake.nix`, create `.envrc` containing
`use flake path:./nix`, then run `direnv allow`.
Entering the checkout loads its pinned toolchain into your current shell;
leaving restores the previous environment. No Bash subshell is needed.

Starship renders the Bash/Zsh prompt. It shows `[user@hostname]` in gold, with
the username limited to its first five characters and no OS label by default.
The username `root` appears in red.
An `ssh:` indicator appears in pink before the brackets for remote sessions.
The directory is magenta, the Git branch green, and the Nix shell indicator a
cyan snowflake.
The AWS profile is yellow (`prod` retains the `🚨 prod 🚨` warning).
When Starship finds an AWS expiration, the profile is followed by the remaining
time, such as `(dev) [29m59s]`, or `[X]` after expiration.
Failed commands add a red `[exit-code]` prefix.
The next successful command clears it.
The SSH indicator detects `SSH_CONNECTION`, not `SSH_TTY` alone.
The shared defaults live in `shell/starship.toml`; `shell/ps1.sh` only initializes
Starship for portable use. Home Manager installs and initializes Starship itself.

### Opt into just the prompt

`homeModules.prompt` is a standalone **Home Manager module** for macOS or Linux,
including Home Manager used inside NixOS. It does not import the editor, tmux,
personal package collection, or shell helpers. Add this repository as a flake
input:

```nix
inputs.personal.url = "github:cmattatall/home-manager";
```

Then, in your Home Manager configuration:

```nix
imports = [ inputs.personal.homeModules.prompt ];

programs.zsh.enable = true; # Or programs.bash.enable; both are supported.
programs.personalPrompt = {
  enable = true;
  aws.enable = false;
  host.showOS = false;
};
```

The module defaults to disabled. Once enabled, all segments except the OS label default to enabled:

| Option under `programs.personalPrompt` | Controls |
| --- | --- |
| `host.enable` | Entire username/hostname/OS/SSH prefix |
| `host.showOS` | OS label inside the brackets (off by default) |
| `host.showSSH` | SSH indicator before the brackets |
| `directory.enable` | Current directory |
| `git.enable` | Git branch; also adds Git to home packages |
| `nixShell.enable` | Nix shell indicator when `IN_NIX_SHELL` is set |
| `aws.enable` | Starship AWS profile, including the production warning |
| `exitStatus.enable` | Nonzero command exit code |

Enable Bash and/or Zsh separately; the module does not enable a shell or change
your login shell. It uses Home Manager's Starship integration, preserving existing
prompt hooks. The existing personal profiles enable this module
by default; set `programs.personalPrompt.enable = false` to opt out completely.
Customize Starship directly through `programs.starship.settings`; those values
override the personal defaults. For example:

```nix
programs.starship.settings.directory.truncation_length = 3;
```

For non-Nix use, install `starship` separately. The loader respects
`STARSHIP_CONFIG` or an existing `~/.config/starship.toml` (including
`XDG_CONFIG_HOME`); otherwise it uses the bundled defaults. Customize that TOML
instead of the former `SHELLRC_PS1_*` flags, which are no longer used.
Set `SHELLRC_SKIP_PROMPT=1` when sourcing `shell/index.sh` to load the other helpers
without changing your prompt. Without Starship installed, the loader leaves your
existing prompt alone. Noninteractive shells do not initialize Starship.

### Opt into just readiff

`homeModules.rediff` builds the editor against the consumer's package set:

```nix
imports = [ inputs.personal.homeModules.rediff ];
programs.rediff = {
  enable = true;
  nvimAlias = true;
  vimAlias = true;
  harness = "amp";
  ampPlugin.enable = false; # Keep an already-installed plugin user-managed.
};
```

Importing enables nothing. The module does not bring in the personal shell,
prompt, tmux, or agent CLIs. The `rediff` command is always installed when enabled;
`nvimAlias` and `vimAlias` independently opt into those command names. Avoid
installing competing packages that provide the aliases you enable.

`manageSettings` defaults to true and writes `rediff/settings.json` from
`harness`, `feedbackCommand`, and `reviewRefreshInterval`. Set it to false to
preserve a user-managed settings file. `ampPlugin.enable` and `ompPlugin.enable`
independently manage their plugin files; by default they follow the selected
harness. See [the editor module documentation](packages/readiff/README.md#use-your-own-home-manager-configuration).

The personal profiles enable readiff and both aliases by default. Set
`programs.rediff.enable = false` to omit the editor. See [Amp plugins](#amp-plugins)
for their separate installation settings.

### Shell helpers

The portable shell configuration provides `nd` for explicitly entering a nested
Nix shell. Keep employer-specific build, deployment, and database helpers in
machine-local shell configuration outside this repository.

With Bazel and fzf available, `bzlfind` selects and prints a target from `//...`.
`bzlrun [arguments...]` selects a binary target and runs it, passing arguments
after Bazel's `--`. Cancelling the picker leaves without running a target.

In Bash, `nxd` runs plain `nix develop`, preserving the project's shell-hook
functions, aliases, and completions. Nix loads `~/.bashrc`, and Starship renders
the personal prompt. In Zsh, `nxd` keeps Zsh with `--command zsh -i`: exported
environment variables survive, but Bash-specific project functions, aliases,
and completions do not. Use the project's native Zsh devshell through `nd`
when available; the helper does not translate Bash hooks into Zsh.

`nd` selects the repository's `nix/flake.nix` when present; `nxd` accepts normal
`nix develop` arguments. For interactive Zsh, `nd` selects that flake's `#zsh`
devshell directly, allowing its native Zsh hooks to load project aliases,
functions, and completions alongside the personal Starship prompt. This requires
the project to export `devShells.<system>.zsh`; generic flakes without that output
can still use `nxd`. Explicit `-c`/`--command` commands use the default devshell
and are passed through unchanged. With direnv already loaded, neither helper
is needed to use the project tools.

On Macs migrating existing Zsh configuration, keep machine-local additions
in `~/.zshrc.local`, `~/.zshenv.local`, and `~/.zprofile.local`. The managed startup files source
these without putting personal machine settings or credentials in this repo.
Do not source the old shell-config checkout from `.zshrc.local`; Home Manager
already loads the authoritative `shell/` directory.

Run `reload-shell` to replace the current shell with a fresh login shell in the
same terminal or tmux pane. It also clears Home Manager's session-variable guard
so updated session variables load. Exported variables carry over; unexported
variables and temporary functions do not. This does not rebuild Home Manager.

## Use the shell configuration without Nix

Clone the repository and add **one** line to your existing `~/.bashrc` or
`~/.zshrc`:

```sh
source "$HOME/home-manager/shell/index.sh"
```

Use the same command to load it in your current shell. Source only `index.sh`,
not every file individually. The loader supports Bash and Zsh and does not
require Nix or GNU `realpath`. Shell functions that invoke other tools still
need those tools installed separately: for example Git, fzf, CMake, AWS CLI,
and Python 3 for `shell/bin/each`. Nix-related aliases do not install Nix.
Some development helpers use Bash-specific features; use a modern Bash when
calling those helpers rather than macOS's old Bash 3.2.

Home Manager sources the same files through `~/.config/shellrc.d`; it does
not replace the old editable checkout at `~/.local/shellrc.d`. Shell aliases
and functions from `shell/` take precedence over development-node defaults.
For example `gs` means checkout, and `gss` means status.

## Programs and external prerequisites

Home Manager installs these dependencies instead of relying on tools that
happen to be present on a development node:

| Purpose | Managed programs |
| --- | --- |
| Coding agents | Amp CLI (`amp`); oh-my-pi (`omp`) on Apple Silicon Macs |
| Shell and Git helpers | Modern Bash, Zsh, Git, GitHub CLI, fzf, bat, GNU coreutils/grep/sed/awk/findutils, which |
| JSON, scripts, remote access | Node.js, jq, Python 3, curl, OpenSSH (Linux; macOS uses Apple's SSH) |
| Cloud and database helpers | AWS CLI v2, PostgreSQL (`psql`; no database service is started) |
| Builds | CMake, Make, Ninja, Clang/LLVM, Arm bare-metal GCC, Cargo/rustc, pre-commit |
| Editor and panes | readiff as `rediff`, `nvim`, and `vim`; tmux; Kitty |
| Development-node helpers | Screen, Vagrant with libvirt support, usbutils, procps |

macOS keeps `/usr/bin/ssh` for `UseKeychain` and Apple Keychain support. Installing
Nix OpenSSH ahead of it would break existing SSH configurations using those options.

The GNU tools are intentional: helpers use `grep -P` and GNU `sed -i`, which
macOS's system tools do not provide. On a non-Nix Mac, install their Homebrew
equivalents and put their `gnubin` directories before `/usr/bin` in `PATH`.
Install the other commands with your native package manager as needed; sourcing
the shell configuration does not install software or contact cloud services.
LLVM already on `PATH` takes precedence; Homebrew LLVM is an optional fallback.
Intel macOS uses Nix's source-built Arm cross-compiler because the pinned Arm
binary distribution no longer supports that host; the first build may be slow.

Amp is the Nixpkgs `amp-cli` package, not a plugin or installation hook from
readiff. Nixpkgs disables Amp's background updater; update the flake lockfile
and activate to change its version. Run `amp login` on a new machine. Existing
Amp binaries, settings, and credentials are not deleted; use `type -a amp` to
check for a standalone installation ahead of `~/.nix-profile/bin` on `PATH`.
Only Amp and Vagrant are allowed as unfree packages, not every unfree package.

### Amp plugins

Home Manager installs and updates both `readiff` and `desloppify` Amp plugins
through the normal `./scripts/install-home-manager.sh` or `hm switch` workflow.
Each switch replaces `~/.config/amp/plugins/readiff.ts` and `desloppify.ts` with
the repository versions, including on the first installation. Make plugin changes
here and switch to apply them. Restart Amp to load updates.

Both plugins are installed even when `programs.rediff.enable = false`.
Desloppify supplies coding guidance on every turn, including the first. Use
`code: desloppify` for a behavior-preserving cleanup of the active thread's work.
To opt out of either plugin, set its file's `enable` option, for example:

```nix
home.file.".config/amp/plugins/desloppify.ts".enable = false;
```

The shared Home Manager profile merges `amp.keymap.thread.interrupt =
["ctrl+l", "esc esc"]` into `~/.config/amp/settings.json` at activation on both
macOS and Linux. Other settings and keybindings stay machine-local and writable;
credentials are never copied into the Nix store. Invalid settings or symlinks are
refused rather than overwritten. Restart Amp after activation: Ctrl+L interrupts
standalone Amp; in the readiff pane, Ctrl+L dismisses/backtracks and **Ctrl+L twice**
interrupts. Pull and activate this configuration on each remote machine too
(`hm_pull` for revision-pinned installations); a local activation does not update
remote hosts. No plugin installation or reload is needed for this setting.

### External prerequisites

These prerequisites remain outside Home Manager:

- GitHub/AWS/Amp credentials and access to the target services.
- `psql_local` and `psql_local_exec` use libpq's normal authentication: a password
  prompt, a private `~/.pgpass` file (mode `0600`), or externally supplied
  `PGPASSWORD`. No database password is configured here. Remote database helpers
  belong in your machine-local configuration.
- TI Code Composer Studio and TI ARM LLVM are proprietary SDK installations.
  The shell retains the optional `/Applications/ti/ccs2011/ccs` paths, but does
  not download or license those SDKs. Project-specific toolchain versions belong
  in the project's development environment rather than this common profile.
- `vssh`/`vreload` still require `/var/lib/ubuntu-vm`, its Vagrant configuration,
  a host virtualization service, and sudo access. No VM is created or restarted.
- `ssh_restart` requires the OS SSH service and sudo. NixOS provides systemd;
  macOS provides launchctl, sysctl, ioreg, ps, pbcopy, and pbpaste.
- Clipboard helpers use macOS's clipboard, an existing X11 `xclip`, or a local
  `/tmp/clipboard` file on headless nodes. X11 and its clipboard service are not
  installed on development nodes; Windows's optional `putclip` is out of scope.

## Development-node ownership

On centrally managed NixOS hosts, arrange a per-user Home Manager handoff in
the system's deployment configuration before activating this repository.
Keep that handoff in the deployment source so a later deployment cannot restore
a competing Home Manager owner. The installer refuses to activate over an
existing system-managed Home Manager service. No login-time auto-update is enabled.

## Kitty and tmux

### Multi-machine Zellij dashboard

The personal environment includes Zellij's `config.kdl`, `layouts/machines.kdl`,
and the `cluster-dash` launcher. To use just this setup in another Home Manager
configuration (including on NixOS), import `inputs.personal.homeModules.zellij`.

Edit the `targets` block at the top of `modules/zellij.nix` before launching:
replace the example addresses with `user@hostname`, or use SSH aliases such as
`web-server`. Aliases use your existing `~/.ssh/config` for `HostName`, `User`,
`Port`, `IdentityFile`, and `ProxyJump`. Keep credentials out of Nix files/the
world-readable Nix store. SSH retains normal host-key checking; verify new host
fingerprints rather than disabling it. macOS uses Apple's SSH for Keychain support.

Apply with `./scripts/install-home-manager.sh`, then run `cluster-dash` from a
plain local terminal, outside any existing multiplexer.
This explicitly runs `zellij --layout machines`; ordinary shells do not autostart
Zellij. All three remote tabs connect immediately, even before you select them.
The Dashboard opens a local shell beside an interactive machine menu; click the
sidebar and enter 1–3 to select a remote tab. This menu selects tabs, not live
host-health checks.

The hub starts **locked** so remote applications receive their keys. Alt+G
unlocks/locks the hub; while unlocked, Ctrl+T enters tab mode (arrows select a tab,
Enter returns to normal), and Ctrl+P enters pane mode. Lock again with Alt+G
before working remotely. On macOS, configure your terminal's Option key to send
Alt/Esc if needed. The Alt+G override belongs only to `machines.kdl`, so remote
sessions retain standard Ctrl+G even when they share this Home Manager module.
The layout disables Zellij 0.45+'s nested-session prompt/automatic focus handling
in favor of this explicit lock/unlock workflow, keeping the machine tabs visible.

Each remote pane executes `ssh -t user@hostname 'zellij attach --create work'`.
Install Zellij on each remote host (`programs.zellij.enable = true;` in its Home
Manager configuration) and make it available on the noninteractive SSH shell's
PATH. Each host owns its persistent `work` session; the local hub does not run
those workloads. With the hub locked, use the remote Zellij controls normally:
Ctrl+G unlocks a locked remote, then Ctrl+O, D detaches without killing its running
session. Disconnected/exited SSH panes stay visible; Enter reruns the connection.
There is no automatic reconnect loop. The dashboard has no tmux dependency;
the separate existing tmux configuration remains available.

Home Manager installs Kitty on macOS and Linux and owns
`~/.config/kitty/kitty.conf`. After activation, run `kitty` from a graphical
desktop. On macOS, you can also launch it from your Home Manager applications
directory (normally `~/Applications/Home Manager Apps`). Reload an already-running
Kitty with `Ctrl+Shift+F5`, or `Cmd+Ctrl+,` on macOS.

On macOS, `paste_actions no-op` disables Kitty's paste filtering and confirmation
warnings. The following extra shortcuts are configured on macOS:

| Shortcut | In tmux | Outside tmux in Kitty |
| --- | --- | --- |
| Ctrl+Shift+Enter | Side-by-side split | Native automatic split |
| Ctrl+Shift+Option+Enter | Top/bottom split | Top/bottom split |
| Ctrl+Shift+arrow | Focus pane in that direction | Focus Kitty window in that direction |
| Cmd+click a web link | Open in the Mac's default browser | Open in the Mac's default browser |

tmux preserves OSC 8 hyperlinks, including labelled links in Amp. Kitty handles
Cmd+click even when the application captures mouse input. Links from remote SSH
sessions open on the Mac, not on the remote host.
tmux also enables RGB for Kitty's configured `xterm-256color` terminal so rediff's
red/green hunk backgrounds are not reduced to grey 256-color approximations.

In readiff, **Cmd+W, then an arrow** moves between Neovim panels, including out
of the embedded harness. Kitty emits an explicit Command key press and tmux
forwards it unchanged instead of converting it to Alt+W. Activate Home Manager
on the Mac and reload Kitty for this mapping; activating only the SSH host does
not update the Mac's keyboard configuration.

In ordinary shell panes, drag with the left mouse button to select text within
that pane. tmux holds the view still while selecting. Releasing the button copies
the text through OSC 52 to Kitty's system clipboard and returns to the live shell,
ready for typing or pasting. Paste with Cmd+V on macOS or Ctrl+Shift+V on Linux.

Outside tmux, Kitty also copies mouse selections to the clipboard automatically.
Applications that capture the mouse retain their own behavior. Shift+drag uses
Kitty's native selection and automatic copying instead, but can span adjacent
tmux panes.

New panes inherit the current pane's directory. tmux's prefix remains Ctrl+B.
Kitty forwards the keys only while its `in_tmux` user variable is present.
tmux sets/clears it on terminal entry/exit, covering attach, detach, suspend,
resume, and normal session exit. The local Mac Zsh prompt also clears stale
state after SSH ends. A broken connection cannot deliver remote cleanup;
if you are not returning to that Zsh prompt, clear it manually:

```sh
printf '\033]1337;SetUserVar=in_tmux\007'
```

tmux config changes need a reload in an existing server:

```sh
tmux source-file ~/.config/tmux/tmux.conf
```

Terminal capability changes take effect on reattachment. Detach and reattach
the client; do not kill existing sessions.

Bash and Zsh refresh `SSH_AUTH_SOCK` before each prompt from the current pane's
tmux session, so forwarded agents recover after SSH reconnects and reattachment.
The helper uses `TMUX_PANE`, not tmux's global environment or a socket-directory
scan. Missing or invalid session sockets leave the shell's current agent alone;
outside tmux nothing changes. Existing prompt hooks and direnv remain intact.
After activating this update, start a new shell or load the helper once in each
existing pane with `source ~/.config/shellrc.d/tmux.sh`. Subsequent commands use
the refreshed agent. Already-running child processes retain their old environment
and must be restarted to pick up a changed socket.

## Neovim / readiff

The complete editor source, tests, harness plugins, documentation, and MIT
license live in [`packages/readiff/`](packages/readiff/README.md). They were imported from
[`cmattatall/readiff` at `6de0dc3`](https://github.com/cmattatall/readiff/commit/6de0dc3dd3a5f4efe2ab5647eac6b2c56d386b17).
Make future editor changes here; no checkout or fetch of that repository is needed.

Root editor builds use this repository's Nixpkgs and Home Manager pins. Local
editor edits are included on rebuild. The standalone flake uses its own pins
when invoked directly from `packages/readiff/`.

This repository installs `rediff` and makes `nvim` and `vim` invoke it. The
editor is configured through `modules/readiff.nix`, with editor settings
and OMP plugins user-managed. The packaged editor uses its isolated
`rediff` profile and does not overwrite `~/.config/nvim`. Plugins are built by
Nix, not downloaded at editor startup. Intel macOS still builds the package through
`homeConfigurations.macbook-intel`.

From this repository root, `nix run .#rediff` launches just the editor and
`nix build .#rediff` builds it without activation. To install the complete personal
environment, use `./scripts/install-home-manager.sh`, **not** `packages/readiff/install.sh`;
the latter is the retained optional minimal bootstrap for otherwise unmanaged homes.

### Publish an editor-only mirror

Keep developing here. `scripts/publish-rediff.py` exports the committed `packages/readiff/`
snapshot to the root of a separate Git repository. It creates fresh public commits
without copying this repository's history, commit messages, or files outside
`packages/readiff/` (including the personal integration in `modules/`).
It requires Python 3, Git, tar, and authentication to the destination.

The public destination is [cmattatall/readiff](https://github.com/cmattatall/readiff).
Preview the export, then publish it:

```sh
python3 scripts/publish-rediff.py --remote https://github.com/cmattatall/readiff.git
# After reviewing the export, publish it:
GIT_AUTHOR_NAME='Carl Mattatall' GIT_COMMITTER_NAME='Carl Mattatall' \
GIT_AUTHOR_EMAIL='36604988+cmattatall@users.noreply.github.com' \
GIT_COMMITTER_EMAIL='36604988+cmattatall@users.noreply.github.com' \
python3 scripts/publish-rediff.py --remote https://github.com/cmattatall/readiff.git --publish
```

Repeat after committing editor changes. Uncommitted editor changes are refused;
unchanged snapshots produce no commit. The script updates `main` with ordinary
fast-forward pushes, never force-pushes, and refuses nonempty destinations lacking
its `.rediff-mirror` marker unless explicitly adopted. To adopt an existing repo,
pass `--adopt FULL_COMMIT_ID` with the reviewed current `main` commit to both preview
and publish. Adoption preserves existing public history and refuses a changed tip.
New destinations must be empty (no generated README/license).
Preview mode reads the remote but never writes it.
Only disposable temporary checkouts are changed; your local branch/index stay put.
Configure a public-safe Git name/email (such as GitHub's noreply address) for the
publisher; absent the environment overrides above, the temporary checkout uses
your global Git identity, not repo-local settings.

This is a **one-way mirror**: edits made directly in the mirror are replaced by the
next snapshot. Bring contributions back into `packages/readiff/` here before publishing.
The script does not run on a timer, install a Git hook, or create GitHub repositories.

**Audit exported changes for sensitive content before each public push.**
This script is not a secret scanner or sanitizer. Subsequent deletions do not remove
files from earlier public mirror commits.

## Public source repository

[`cmattatall/home-manager`](https://github.com/cmattatall/home-manager) is the
authoritative source, not a snapshot mirror. Develop here and push reviewed
commits directly. Its history starts from a clean snapshot; do not merge or push
the former private repository's history into it. The editor-only `readiff` mirror
described above remains separate.

Existing clones of the former mirror or private repository have unrelated
history. Clone this repository afresh rather than pulling with
`--allow-unrelated-histories`. Existing standalone `~/home.nix` configurations
must update both repository URLs to the public HTTPS URL and replace their old
revision pin with a commit from this repository's `main`. Do not rerun the setup
script over an existing configuration or discard local customizations.

The personal Home Manager profiles install Gitleaks. Without Home Manager,
install it with `brew install gitleaks` or run it through
`nix shell nixpkgs#gitleaks`. Scan and manually review changes before pushing;
there is no longer a snapshot publisher that performs the scan for you.

## Keep credentials and private configuration outside Git

Never put passwords, API keys, private keys, or private infrastructure details in
Nix files: the Nix store is normally world-readable. Keep credentials in the
service's own credential store or private files outside this checkout. The local
Zsh startup files described above are sourced at runtime, not copied into the store.
Use SSH aliases backed by your private `~/.ssh/config` rather than committing
private host addresses. The development-node profile uses a GitHub noreply email;
configure work identities outside this repository.

`.gitignore` excludes common credential files and `*.local` files, but ignores are
not a security boundary and do not affect already tracked files. Before publishing,
review the staged diff and scan **all history**, not just the current checkout:

```sh
gitleaks git . --log-opts='--all --full-history' --redact
```

Automated scanners can miss simple passwords and
private project names; manually review those, commit author emails/messages, and
GitHub pull requests, issues, and attachments as well. If a real credential was
committed, revoke or rotate it. A cleanup commit does not erase earlier versions,
and a force-push alone does not purge GitHub's pull-request refs or cached commits.

## Update, rollback, and verify

Never edit generated symlinks in the home directory.

```sh
git pull --ff-only
./scripts/install-home-manager.sh
```

Use `nix flake update` to deliberately update pinned dependencies, review the
lockfile changes, then rerun the installer. Keep `home.stateVersion` unchanged
unless deliberately migrating compatibility defaults.

For rollback, run `home-manager generations` and execute the previous
generation's `activate` script. Reverting the fleet handoff is a separate
NixOS deployment; do not restore two competing Home Manager owners.

```sh
nix build .#homeConfigurations.development-node.activationPackage
HM_TEST_HOME_PATH="$PWD/result/home-path" \
  TMUX_TEST_BIN="$PWD/result/home-path/bin/tmux" \
  TMUX_TEST_CONFIG="$PWD/result/home-files/.config/tmux/tmux.conf" \
  python3 -m unittest discover -s tests -v

# Without a built profile, package tests are skipped:
python3 -m unittest discover -s tests -v
TMUX_TEST_CONFIG="$HOME/.config/tmux/tmux.conf" \
  python3 -m unittest discover -s tests -p test_tmux.py -v

# Editor integration, UI, harness and Amp tests with this home's dependency pins:
nix flake check
# Complete standalone editor checks, including OMP and optional bootstrap:
nix flake check ./packages/readiff
```

Installer tests mock installation and activation. Shell tests run Bash and
Zsh. tmux tests use private sockets and PTYs on Linux; they never touch the
running user session. A real macOS installation still requires Mac-side
verification.
