#!/usr/bin/env bash
# Build and activate this flake's Home Manager configuration for the current
# user on this machine. Usage: scripts/install-home-manager.sh [--remote] [profile]
# --remote works without a checkout: create a pinned ~/home.nix and activate it.
#
# The profile defaults to the native one (development-node, macbook or
# macbook-intel); home.username/home.homeDirectory come from `id -un`/$HOME.
# NixOS nodes whose home is owned by the fleet's home-manager-$USER.service
# are left alone. Activation is skipped when the built generation is active.
#
# HM_INSTALL_SYSROOT prefixes system paths; it exists only for tests.
set -eu

root=${HM_INSTALL_SYSROOT:-}
here=$(cd "$(dirname "$0")" && pwd -P)
flake_dir=$(dirname "$here")

die() {
	echo "install-home-manager: error: $*" >&2
	exit 1
}
say() { echo "install-home-manager: $*"; }

remote=false
profile=
for arg in "$@"; do
	case "$arg" in
	--remote) remote=true ;;
	-h|--help)
		echo "Usage: $0 [--remote] [development-node|macbook|macbook-intel]"
		echo "Default: build and activate the local checkout."
		echo "--remote: create ~/home.nix pinned to published main and activate it (requires Nix)."
		exit 0 ;;
	development-node|macbook|macbook-intel)
		[ -z "$profile" ] || die "specify only one profile"
		profile=$arg ;;
	*) die "unknown argument: $arg (use --help)" ;;
	esac
done

[ "$(id -u)" != 0 ] || die "run as a normal user, not root"
user=$(id -un)
[ -n "$user" ] || die "cannot determine the current username"
[ -n "${HOME:-}" ] || die "HOME is not set"

if [ -e "$root/etc/NIXOS" ]; then
	unit="home-manager-$user.service"
	state=$(systemctl show -p LoadState --value "$unit") ||
		die "cannot query systemd for $unit; refusing to guess whether the fleet manages this home"
	if [ "$state" = loaded ]; then
		say "$unit is loaded: this home is managed by the NixOS fleet configuration; nothing to do"
		exit 0
	fi
	[ "$state" = not-found ] || die "unexpected LoadState '$state' for $unit"
fi

if [ -z "$profile" ]; then
	case "$(uname -s)/$(uname -m)" in
	Linux/x86_64) profile=development-node ;;
	Darwin/arm64) profile=macbook ;;
	Darwin/x86_64)
		# A Rosetta shell reports x86_64 on Apple silicon.
		if [ "$(sysctl -n hw.optional.arm64 2>/dev/null || true)" = 1 ]; then
			profile=macbook
		else
			profile=macbook-intel
		fi
		;;
	*) die "unsupported platform $(uname -s)/$(uname -m)" ;;
	esac
fi

config_file=
if [ "$remote" = true ]; then
	config_file="$HOME/home.nix"
	[ ! -e "$config_file" ] && [ ! -L "$config_file" ] ||
		die "$config_file already exists; use hm_pull to update it, or hm switch -f \"$config_file\" to retry activation"
	# A downloaded copy of this script has no sibling install-nix.sh. Remote
	# NixOS machines already have Nix; never bootstrap a second installation.
	nix=$(command -v nix 2>/dev/null || true)
	if [ -z "$nix" ]; then
		for candidate in "$root/nix/var/nix/profiles/default/bin/nix" \
			"$HOME/.nix-profile/bin/nix" "$root/run/current-system/sw/bin/nix"; do
			if [ -x "$candidate" ]; then nix=$candidate; break; fi
		done
	fi
	[ -n "$nix" ] && "$nix" --version >/dev/null 2>&1 ||
		die "--remote requires a working Nix installation"
else
	[ -f "$flake_dir/flake.nix" ] && [ -x "$here/install-nix.sh" ] ||
		die "local installation requires a checkout; use --remote without a checkout"
	nix=$("$here/install-nix.sh") || die "Nix is not available"
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/install-home-manager.XXXXXX")
pending_config=
trap 'rm -rf "$tmp"; if [ -n "$pending_config" ]; then rm -f "$pending_config"; fi' EXIT

if [ "$remote" = true ]; then
	revision=$("$nix" --extra-experimental-features 'nix-command flakes' \
		eval --refresh --impure --raw --expr \
		'(builtins.getFlake "git+https://github.com/cmattatall/home-manager.git?ref=main").rev') ||
		die "could not resolve published main"
	[[ "$revision" =~ ^[0-9a-f]{40}$ ]] || die "main did not resolve to a valid commit SHA"
	flake_dir="git+https://github.com/cmattatall/home-manager.git?rev=$revision"
	module=$profile
	[ "$module" != macbook-intel ] || module=macbook
	pending_config=$(mktemp "$HOME/.home.nix.XXXXXX")
	HM_REVISION=$revision HM_MODULE=$module HM_USERNAME=$user HM_HOME=$HOME \
		"$nix" --extra-experimental-features 'nix-command flakes' eval --impure --raw --expr "$(cat <<'NIX'
let
  env = builtins.getEnv;
  # Quote paths/usernames as Nix strings, including literal ${...} in a path.
  quote = value: builtins.replaceStrings [ "\${" ] [ "\\\${" ] (builtins.toJSON value);
in ''
  let
    personal = builtins.getFlake (
      "git+https://github.com/cmattatall/home-manager.git"
      + "?rev=${env "HM_REVISION"}"
    );
  in
  {
    imports = [ personal.homeModules.${env "HM_MODULE"} ];
    home.username = ${quote (env "HM_USERNAME")};
    home.homeDirectory = ${quote (env "HM_HOME")};
    programs.home-manager.path = personal.inputs.home-manager.outPath;
  }
''
NIX
)" > "$pending_config" || die "could not generate home.nix"
	# An atomic, no-clobber link also protects against concurrent installers.
	ln "$pending_config" "$config_file" || die "could not create $config_file; existing files were preserved"
	rm "$pending_config"
	pending_config=
	config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/home-manager"
	mkdir -p "$config_dir"
	if [ ! -e "$config_dir/home.nix" ] && [ ! -L "$config_dir/home.nix" ]; then
		ln -s "$config_file" "$config_dir/home.nix"
	else
		say "preserved $config_dir/home.nix; use hm switch -f \"$config_file\" explicitly"
	fi
	say "created $config_file pinned to $revision"
fi

say "building homeConfigurations.$profile for $user ($HOME)"
# shellcheck disable=SC2016 # Nix interpolation, values arrive via the environment.
HM_FLAKE_DIR=$flake_dir HM_PROFILE=$profile HM_USERNAME=$user HM_HOME=$HOME HM_CONFIG_FILE=$config_file \
	"$nix" --extra-experimental-features 'nix-command flakes' \
	build --impure --out-link "$tmp/result" --expr '
let
  env = builtins.getEnv;
  flake = builtins.getFlake (env "HM_FLAKE_DIR");
  base = flake.homeConfigurations.${env "HM_PROFILE"};
  hm = if env "HM_CONFIG_FILE" != "" then
    flake.inputs.home-manager.lib.homeManagerConfiguration {
      pkgs = import flake.inputs.nixpkgs { system = base.pkgs.stdenv.hostPlatform.system; };
      modules = [ (builtins.toPath (env "HM_CONFIG_FILE")) ];
    }
  else base.extendModules {
    modules = [
      ({ lib, ... }: {
        home.username = lib.mkForce (env "HM_USERNAME");
        home.homeDirectory = lib.mkForce (env "HM_HOME");
      })
    ];
  };
in
hm.activationPackage
' || die "build failed"

# cd -P resolves symlink chains without relying on GNU readlink -f.
generation=$(cd -P "$tmp/result" && pwd -P)

for profile_link in \
	"${XDG_STATE_HOME:-$HOME/.local/state}/nix/profiles/home-manager" \
	"$root/nix/var/nix/profiles/per-user/$user/home-manager"; do
	if [ -d "$profile_link" ]; then
		if [ "$(cd -P "$profile_link" && pwd -P)" = "$generation" ]; then
			say "generation $generation is already active; nothing to do"
			exit 0
		fi
		break
	fi
done

say "activating $generation"
PATH="$(dirname "$nix"):$PATH" "$generation/activate"
say "done"
if [ "$remote" = true ]; then
	say "start a new shell; hm_pull fetches and switches to published main, hm aliases home-manager"
fi
