#!/usr/bin/env bash
# Ensure a working Nix exists for the current (non-root) user and print the
# absolute path of its `nix` binary on stdout. Diagnostics go to stderr.
#
# - Reuses a working Nix on PATH or in a standard profile location.
# - Refuses to touch a broken installation or to install Nix on NixOS.
# - On macOS without Nix, runs the official multi-user installer (--daemon).
#
# HM_INSTALL_SYSROOT prefixes system paths; it exists only for tests.
set -eu

root=${HM_INSTALL_SYSROOT:-}
installer_url=https://nixos.org/nix/install

die() {
	echo "install-nix: error: $*" >&2
	exit 1
}
say() { echo "install-nix: $*" >&2; }

works() { "$1" --version >/dev/null 2>&1; }

use() {
	works "$1" || die "Nix at $1 is broken; repair it manually instead of reinstalling"
	say "using $("$1" --version) at $1"
	echo "$1"
	exit 0
}

[ "$(id -u)" != 0 ] || die "run as a normal user, not root"

if nix=$(command -v nix 2>/dev/null); then
	use "$nix"
fi

for nix in \
	"$root/nix/var/nix/profiles/default/bin/nix" \
	"$HOME/.nix-profile/bin/nix" \
	"${XDG_STATE_HOME:-$HOME/.local/state}/nix/profiles/profile/bin/nix" \
	"$root/run/current-system/sw/bin/nix"; do
	if [ -x "$nix" ]; then
		say "found Nix outside PATH"
		use "$nix"
	fi
done

if [ -e "$root/nix/store" ] || [ -e "$root/nix/var/nix" ]; then
	die "/nix exists but no working nix binary was found; installation looks broken, repair or uninstall it first"
fi

[ ! -e "$root/etc/NIXOS" ] || die "NixOS without a usable nix command; not installing Nix on NixOS"

[ "$(uname -s)" = Darwin ] ||
	die "no Nix found; automatic Nix installation is only supported on macOS"

say "Nix not found; running the official multi-user installer (sudo may prompt)"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/install-nix.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
curl --proto '=https' --tlsv1.2 -fsSL -o "$tmp/install" "$installer_url" ||
	die "failed to download $installer_url"
sh "$tmp/install" --daemon >&2 || die "official Nix installer failed"

nix="$root/nix/var/nix/profiles/default/bin/nix"
works "$nix" || die "Nix installer finished but $nix does not work"
say "installed $("$nix" --version); open a new shell to get nix on PATH"
echo "$nix"
