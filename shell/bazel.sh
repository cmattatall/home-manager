bzlrun() (
    set -o pipefail
    local pattern='' targets target
    case "${1-}" in
        --) shift ;;
        ''|-*) ;;
        *) pattern=$1; shift ;;
    esac

    targets=$(bazel query "kind('.*_binary|sh_binary', //...)") || return
    if [ -n "$pattern" ]; then
        targets=$(printf '%s\n' "$targets" | grep -F -- "$pattern") || {
            printf 'bzlrun: no binary targets match "%s"\n' "$pattern" >&2
            return 1
        }
    fi

    if [ -n "$pattern" ] && [[ "$targets" != *$'\n'* ]]; then
        target=$targets
    else
        target=$(printf '%s\n' "$targets" | fzf) || return
    fi
    [ -n "$target" ] || return 1

    bazel run "$target" -- "$@"
)

bzlfind() (
    set -o pipefail
    bazel query //... | fzf
)
