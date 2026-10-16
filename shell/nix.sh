alias hm='home-manager'

hm_pull() {
    local config_file="$HOME/home.nix"
    local repository_url="https://github.com/cmattatall/home-manager.git"
    local remote_reference latest_revision
    local revision_pin_pattern matching_pin_count updated_config

    if [ ! -f "$config_file" ] || [ -L "$config_file" ]; then
        printf 'hm_pull: expected a regular, unmanaged %s; use the local installer for a checkout\n' "$config_file" >&2
        return 1
    fi
    if ! remote_reference=$(git ls-remote --exit-code "$repository_url" refs/heads/main); then
        printf 'hm_pull: could not read main from %s\n' "$repository_url" >&2
        return 1
    fi
    latest_revision=$(printf '%s\n' "$remote_reference" | cut -f1)
    if ! [[ "$latest_revision" =~ ^[0-9a-f]{40}$ ]]; then
        printf 'hm_pull: main did not resolve to a valid commit SHA\n' >&2
        return 1
    fi

    revision_pin_pattern='^[[:space:]]*\+ "\?rev=[0-9a-f]{40}"$'
    matching_pin_count=$(grep -Ec "$revision_pin_pattern" "$config_file")
    if [ "$matching_pin_count" != 1 ]; then
        printf 'hm_pull: expected exactly one revision pin in %s\n' "$config_file" >&2
        return 1
    fi
    if ! updated_config=$(mktemp "$config_file.XXXXXX"); then
        printf 'hm_pull: could not create a temporary configuration\n' >&2
        return 1
    fi
    if ! sed -E "/$revision_pin_pattern/s/[0-9a-f]{40}/$latest_revision/" \
        "$config_file" > "$updated_config"; then
        rm -f "$updated_config"
        return 1
    fi
    if ! mv "$updated_config" "$config_file"; then
        rm -f "$updated_config"
        return 1
    fi
    # Keep the new pin after an activation failure so the switch can be retried.
    home-manager switch -b backup -f "$config_file"
}

unalias nxd 2>/dev/null || true

nxd() {
    local arg
    for arg in "$@"; do
        case "$arg" in
            -c|--command)
                nix develop "$@"
                return
                ;;
        esac
    done

    # Keep Zsh for Zsh callers; Bash must use Nix's rcfile to retain shellHook state.
    if [ -n "${ZSH_VERSION:-}" ]; then
        nix develop "$@" --command zsh -i
    else
        nix develop "$@"
    fi
}

alias nxdv="nxd --print-build-logs"

nd() {
    local repo_root flake arg
    repo_root="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || pwd)"
    if [ -f "$repo_root/nix/flake.nix" ]; then
        flake="path:$repo_root/nix"
        if [ -n "${ZSH_VERSION:-}" ]; then
            for arg in "$@"; do
                case "$arg" in
                    -c|--command) nix develop "$flake" "$@"; return ;;
                esac
            done
            flake="$flake#zsh"
        fi
        nix develop "$flake" "$@"
    else
        nxd "$@"
    fi
}
