# Prints one label from the targets matching query. A pattern with exactly one
# literal match selects it directly. Otherwise fzf picks from the matches.
_bzl_select_target() (
    set -o pipefail
    local command_name=$1 query=$2 target_noun=$3 pattern=$4
    local targets target

    targets=$(bazel query "$query") || return
    if [ -n "$pattern" ]; then
        targets=$(printf '%s\n' "$targets" | grep -F -- "$pattern") || {
            printf '%s: no %s match "%s"\n' "$command_name" "$target_noun" "$pattern" >&2
            return 1
        }
    fi

    if [ -n "$pattern" ] && [[ "$targets" != *$'\n'* ]]; then
        target=$targets
    else
        target=$(printf '%s\n' "$targets" | fzf) || return
    fi
    [ -n "$target" ] || return 1

    printf '%s\n' "$target"
)

bzlrun() (
    local pattern='' target
    case "${1-}" in
        --) shift ;;
        ''|-*) ;;
        *) pattern=$1; shift ;;
    esac

    target=$(_bzl_select_target bzlrun "kind('.*_binary|sh_binary', //...)" "binary targets" "$pattern") || return
    bazel run "$target" -- "$@"
)

bzlbuild() (
    local pattern='' output_directory='' target
    local build_flags=()
    case "${1-}" in
        --) shift ;;
        ''|-*) ;;
        *) pattern=$1; shift ;;
    esac

    while [ $# -gt 0 ]; do
        case "$1" in
            --outdir)
                if [ $# -lt 2 ]; then
                    printf 'bzlbuild: --outdir needs a directory\n' >&2
                    return 2
                fi
                output_directory=$2
                shift 2
                ;;
            --outdir=*)
                output_directory=${1#--outdir=}
                shift
                ;;
            *)
                build_flags+=("$1")
                shift
                ;;
        esac
    done

    target=$(_bzl_select_target bzlbuild "kind('.*_binary|.*_test', //...)" "binary or test targets" "$pattern") || return
    bazel build "${build_flags[@]}" -- "$target" || return
    [ -n "$output_directory" ] || return 0

    # cquery lists output paths relative to the execution root. It needs the
    # build flags because they can select a different output configuration.
    local execution_root output_files output_file
    execution_root=$(bazel info execution_root) || return
    output_files=$(bazel cquery "${build_flags[@]}" --output=files -- "$target") || return

    mkdir -p -- "$output_directory" || return
    while IFS= read -r output_file; do
        # Bazel outputs are read-only, so -f replaces copies from earlier builds.
        cp -f -- "$execution_root/$output_file" "$output_directory/" || return
        printf '%s\n' "$output_directory/${output_file##*/}"
    done <<< "$output_files"
)

bzlfind() (
    set -o pipefail
    bazel query //... | fzf
)
