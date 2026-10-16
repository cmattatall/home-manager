#!/usr/bin/env bash
# Build and activate this flake's Home Manager configuration for the current
# user on this machine. Usage: scripts/install-home-manager.sh [profile]
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

if [ $# -gt 0 ]; then
	profile=$1
else
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

nix=$("$here/install-nix.sh") || die "Nix is not available"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/install-home-manager.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

say "building homeConfigurations.$profile for $user ($HOME)"
# shellcheck disable=SC2016 # Nix interpolation, values arrive via the environment.
HM_FLAKE_DIR=$flake_dir HM_PROFILE=$profile HM_USERNAME=$user HM_HOME=$HOME \
	"$nix" --extra-experimental-features 'nix-command flakes' \
	build --impure --out-link "$tmp/result" --expr '
let
  env = builtins.getEnv;
  flake = builtins.getFlake (env "HM_FLAKE_DIR");
  hm = flake.homeConfigurations.${env "HM_PROFILE"}.extendModules {
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
