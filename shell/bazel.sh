bzlrun() (
    set -o pipefail
    local target
    target=$(bazel query "kind('.*_binary|sh_binary', //...)" | fzf) || return
    [ -n "$target" ] || return 1

    bazel run "$target" -- "$@"
)

bzlfind() (
    set -o pipefail
    bazel query //... | fzf
)
