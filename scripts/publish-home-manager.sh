#!/usr/bin/env bash
# Preview or publish a scanned snapshot without private Git history.
set -euo pipefail

die() {
	printf 'publish-home-manager: %s\n' "$*" >&2
	exit 1
}

remote=https://github.com/cmattatall/home-manager.git
publish=false
while [ "$#" -gt 0 ]; do
	case "$1" in
		--remote)
			[ "$#" -ge 2 ] && [ -n "$2" ] || die '--remote requires a Git URL'
			remote=$2
			shift 2
			;;
		--remote=*)
			remote=${1#--remote=}
			[ -n "$remote" ] || die '--remote requires a Git URL'
			shift
			;;
		--publish) publish=true; shift ;;
		-h|--help)
			printf '%s\n' \
				'Usage: publish-home-manager.sh [--remote URL] [--publish]' \
				'Preview by default; --publish commits and pushes the scanned snapshot.'
			exit 0
			;;
		*) die "Unknown argument: $1" ;;
	esac
done

scanner=$(command -v gitleaks) || die 'Install Gitleaks and put it on PATH before publishing.'
source_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
revision=$(git -C "$source_dir" rev-parse HEAD)
status=$(git -C "$source_dir" status --porcelain --untracked-files=all)
[ -z "$status" ] ||
	die 'Commit or set aside all changes before exporting.'

temporary=$(mktemp -d "${TMPDIR:-/tmp}/home-manager-mirror.XXXXXX")
trap 'rm -rf -- "$temporary"' EXIT

# New top-level content needs an explicit publication decision.
git -C "$source_dir" ls-tree -z --name-only "$revision" > "$temporary/paths"
while IFS= read -r -d '' name; do
	case "$name" in
		.gitignore|README.md|development-node.nix|flake.lock|flake.nix|home.nix|macbook.nix|modules|scripts|shell|tests) ;;
		*) die "Unreviewed top-level paths: $name" ;;
	esac
done < "$temporary/paths"
entries=$(git -C "$source_dir" ls-tree -r "$revision")
if grep -q '^160000 ' <<< "$entries"; then
	die 'The export cannot include submodules; vendor them first.'
fi

marker=.home-manager-mirror
printf 'home-manager snapshot mirror v1\n' > "$temporary/expected-marker"
mirror=$temporary/mirror
mkdir "$mirror"
git -C "$mirror" init --quiet --initial-branch=main
git -C "$mirror" config core.hooksPath /dev/null
git -C "$mirror" remote add origin "$remote"
refs=$(git -C "$mirror" ls-remote --heads --tags origin)
if [ -n "$refs" ]; then
	grep -q $'\trefs/heads/main$' <<< "$refs" ||
		die 'Destination is not empty and has no main branch.'
	git -C "$mirror" fetch --quiet --no-tags origin refs/heads/main
	if ! git -C "$mirror" show "FETCH_HEAD:$marker" > "$temporary/actual-marker" 2>/dev/null ||
		! cmp -s "$temporary/expected-marker" "$temporary/actual-marker"; then
		die 'Refusing to overwrite an unmarked repository.'
	fi
	git -C "$mirror" checkout --quiet -B main FETCH_HEAD
	"$scanner" git "$mirror" '--log-opts=--all --full-history' --redact --ignore-gitleaks-allow
fi

# Only destination ancestry is retained; source objects never enter it.
shopt -s dotglob nullglob
for path in "$mirror"/*; do
	[ "$path" = "$mirror/.git" ] || rm -rf -- "$path"
done
git -C "$source_dir" archive --format=tar --output="$temporary/snapshot.tar" "$revision"
tar -xf "$temporary/snapshot.tar" -C "$mirror"
cp "$temporary/expected-marker" "$mirror/$marker"

# Scan before printing the diff, so detected secrets stay out of logs.
"$scanner" dir "$mirror" --redact --ignore-gitleaks-allow
git -C "$mirror" add --all --force
changed=$(git -C "$mirror" diff --cached --name-status)
if [ -z "$changed" ]; then
	printf 'Mirror is already up to date.\n'
	exit 0
fi
printf 'Destination: %s\nBranch: main\n%s\n' "$remote" "$changed"
git -C "$mirror" --no-pager diff --cached --no-ext-diff --no-textconv
if [ "$publish" = false ]; then
	printf 'Preview only: nothing was pushed. Manually audit before --publish.\n'
	exit 0
fi

# Ignore inherited work identities, including GIT_AUTHOR_* overrides.
GIT_AUTHOR_NAME='Carl Mattatall' \
GIT_AUTHOR_EMAIL='36604988+cmattatall@users.noreply.github.com' \
GIT_COMMITTER_NAME='Carl Mattatall' \
GIT_COMMITTER_EMAIL='36604988+cmattatall@users.noreply.github.com' \
	git -C "$mirror" -c commit.gpgsign=false commit --quiet -m 'Update Home Manager snapshot'
git -C "$mirror" push origin HEAD:refs/heads/main
printf 'Published Home Manager snapshot.\n'
