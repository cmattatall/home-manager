alias hm='home-manager'

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
