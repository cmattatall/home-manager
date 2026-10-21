# This file is safe to source repeatedly. Clear both possible command forms so
# stale aliases cannot shadow functions, and stale functions do not remain
# underneath aliases.
for _git_command_name in \
    _git_remote_blame_log \
    gbi \
    gcam \
    gbcp \
    gbicpo \
    gci \
    gcnv \
    git_churned_files \
    git_commit_rates \
    git_contributors \
    git_fix_upstream \
    git_how_many_lines \
    git_pause_branch \
    git_remote_blame \
    git_worktree_add \
    gl \
    gpll \
    gpo \
    gco \
    gpof \
    grbm \
    gs \
    gsh \
    gss \
    rbi
do
    builtin unalias "$_git_command_name" 2>/dev/null || :
    builtin unset -f "$_git_command_name" 2>/dev/null || :
done
builtin unset _git_command_name

# Aliases

# Checkout
alias gco="git checkout"

# Branches
alias gbcp="git branch --show-current | copy"
alias gbicpo="gbi | copy"

# Commits
alias gcam="git commit --amend --no-edit"
alias gcnv="git commit --no-verify"

# Inspection
alias gl="git log --color --graph --decorate-refs-exclude='refs/remotes/origin/gh-readonly-queue/*' --pretty=format:'%Cred%h%Creset -%C(auto)%d%Creset %s %Cgreen(%cr) %C(bold blue)<%an>%Creset' --abbrev-commit"
alias gss="git status"

# Rebase and stash
alias grbm="git rebase main"
alias gsh="git stash"

# Functions

# Short commands
gs() {
    if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
        echo "Usage: gs [checkout-arguments...]"
        echo "Run git checkout, or check out the previous branch when called without arguments."
        return 0
    fi

    if [ "$#" -eq 0 ]; then
        git checkout -
    else
        git checkout "$@"
    fi
}

gbi() {
    if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
        echo "Usage: gbi [pattern]"
        echo "Select a local or remote branch with fzf."
        return 0
    fi

    if [ "$#" -eq 0 ]; then
        git branch -a | fzf
    else
        git branch -a | fzf --query="$1" | xargs
    fi
}

gci() {
    local pattern=""
    local include_remotes=0
    local fetch_first=0
    local branch=""
    local -a git_branch_args=(--sort=-committerdate)
    local -a fzf_args=()

    while [[ $# -gt 0 ]]; do
        case $1 in
            --pattern|-p)
                pattern="$2"
                shift 2
                ;;
            --include-remotes|-r)
                include_remotes=1
                shift
                ;;
            --fetch-first|-f)
                fetch_first=1
                shift
                ;;
            --help|-h)
                echo "Usage: gci [--pattern|-p <pattern>] [--include-remotes|-r] [--fetch-first|-f] [--help|-h]"
                echo "  --pattern|-p <pattern>  Filter branches by pattern"
                echo "  --include-remotes|-r   Include remote branches"
                echo "  --fetch-first|-f       Fetch from the remote before matching branches"
                echo "  --help|-h              Show this help message"
                return 0
                ;;
            *)
                if [ -z "$pattern" ]; then
                    pattern="$1"
                    shift
                else
                    echo "Invalid option: $1" >&2
                    return 1
                fi
                ;;
        esac
    done

    if [ "$include_remotes" -eq 1 ]; then
        fetch_first=1
        git_branch_args+=(--all)
    fi

    if [ "$fetch_first" -eq 1 ]; then
        git fetch
    fi

    if [ -n "$pattern" ]; then
        fzf_args+=(--query="$pattern")
    fi

    branch=$(git branch "${git_branch_args[@]}" | fzf "${fzf_args[@]}" | xargs)

    if [ -n "$branch" ]; then
        # Remove the "remotes/origin/" prefix if it exists.
        branch=$(echo "$branch" | sed 's/^remotes\/origin\///')
        git checkout "$branch"
    fi
}

rbi() {
    if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
        echo "Usage: rbi"
        echo "Select a branch with fzf and rebase onto it."
        return 0
    fi

    git rebase "$(gbi)"
}

gpo() {
    if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
        echo "Usage: gpo [push-arguments...]"
        echo "Push the current branch to origin and set its upstream."
        return 0
    fi

    local current_branch
    current_branch=$(git branch --show-current)
    git push --set-upstream origin "$current_branch" "$@"
}

gpof() {
    if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
        echo "Usage: gpof"
        echo "Push the current branch to origin using --force-with-lease."
        return 0
    fi

    gpo --force-with-lease
}

gpll() {
    if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
        echo "Usage: gpll"
        echo "Pull changes for the current branch."
        return 0
    fi

    git pull
}

# Long-form helpers
git_how_many_lines() {
    if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
        echo "Usage: git_how_many_lines [author]"
        echo "Summarize changed files, insertions, and deletions on main for an author."
        echo "Defaults to the email in git config user.email."
        return 0
    fi

    local user="${1:-}"
    if [ -z "$user" ]; then
        user=$(git config user.email)
    fi

    git log \
        --author="$user" \
        --shortstat \
        --no-merges main \
        | grep "files\? changed" \
        | awk '{files+=$1; inserted+=$4; deleted+=$6} END {print "Total: ", files, "files changed,", inserted, "insertions(+),", deleted, "deletions(-)"}'
}

git_fix_upstream() {
    if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
        echo "Usage: git_fix_upstream"
        echo "Set the current branch's upstream to the branch of the same name on origin."
        return 0
    fi

    local current_branch
    current_branch=$(git branch --show-current)
    git branch --set-upstream-to="origin/$current_branch" "$current_branch"
}

_git_remote_blame_log() {
    if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
        echo "Usage: _git_remote_blame_log <0|1> <message...>"
        echo "Write an internal git_remote_blame log message when enabled."
        return 0
    fi

    local verbose="$1"
    shift

    if [ "$verbose" -eq 1 ]; then
        echo "[git_remote_blame] $*" >&2
    fi
}

git_remote_blame() {
    local text=""
    local json=0
    local show_approvers=0
    local verbose=0

    while [[ $# -gt 0 ]]; do
        case $1 in
            --json)
                json=1
                shift
                ;;
            --approvers)
                show_approvers=1
                shift
                ;;
            --verbose|-v)
                verbose=1
                shift
                ;;
            --help|-h)
                echo "Usage: git_remote_blame <text> [--json] [--approvers] [--verbose|-v]"
                echo "  <text>       String to search for using git log -S"
                echo "  --json       Output as JSON"
                echo "  --approvers  Show who approved the PR (requires gh CLI)"
                echo "  --verbose|-v Print progress to stderr"
                echo "  -h|--help    Show this help message"
                return 0
                ;;
            *)
                if [ -z "$text" ]; then
                    text="$1"
                else
                    echo "Unknown option: $1" >&2
                    return 1
                fi
                shift
                ;;
        esac
    done

    if [ -z "$text" ]; then
        echo "Usage: git_remote_blame <text> [--json] [--approvers] [--verbose|-v]" >&2
        return 1
    fi

    _git_remote_blame_log "$verbose" "Resolving remote URL..."
    local remote_url
    remote_url=$(git remote get-url origin 2>/dev/null)
    local base_url
    base_url=$(echo "$remote_url" | sed -E 's|git@([^:]+):|https://\1/|;s|\.git$||')
    _git_remote_blame_log "$verbose" "Base URL: $base_url"

    _git_remote_blame_log "$verbose" "Running git log -S \"$text\" --no-merges ..."
    local format="%H%x09%an%x09%aI%x09%s"
    local lines
    lines=$(git log -S "$text" --pretty=format:"$format" --no-merges)

    if [ -z "$lines" ]; then
        echo "No commits found for: $text" >&2
        return 1
    fi

    local count
    count=$(echo "$lines" | wc -l)
    _git_remote_blame_log "$verbose" "Found $count commit(s)"

    if [ $json -eq 1 ]; then
        echo "["
        local first=1
        while IFS=$'\t' read -r sha author date subject; do
            local pr_num
            pr_num=$(echo "$subject" | grep -oP '#\K[0-9]+' | head -1)
            local pr_url=""
            if [ -n "$pr_num" ]; then
                pr_url="${base_url}/pull/${pr_num}"
            fi
            _git_remote_blame_log "$verbose" "Processing ${sha:0:12} (PR #${pr_num:-none})"
            local approvers="[]"
            if [ $show_approvers -eq 1 ] && [ -n "$pr_num" ]; then
                _git_remote_blame_log "$verbose" "  Fetching approvers for PR #$pr_num ..."
                approvers=$(gh pr view "$pr_num" --json reviews --jq '[.reviews[] | select(.state == "APPROVED") | .author.login] | unique' 2>/dev/null || echo "[]")
                _git_remote_blame_log "$verbose" "  Approvers: $approvers"
            fi
            if [ $first -eq 0 ]; then echo ","; fi
            first=0
            if [ $show_approvers -eq 1 ]; then
                printf '  {"sha": "%s", "author": "%s", "date": "%s", "pr_url": "%s", "approvers": %s, "subject": "%s"}' \
                    "$sha" "$author" "${date%T*}" "${pr_url:-N/A}" "$approvers" "$subject"
            else
                printf '  {"sha": "%s", "author": "%s", "date": "%s", "pr_url": "%s", "subject": "%s"}' \
                    "$sha" "$author" "${date%T*}" "${pr_url:-N/A}" "$subject"
            fi
        done <<< "$lines"
        echo ""
        echo "]"
    else
        while IFS=$'\t' read -r sha author date subject; do
            local pr_num
            pr_num=$(echo "$subject" | grep -oP '#\K[0-9]+' | head -1)
            local pr_url=""
            if [ -n "$pr_num" ]; then
                pr_url="${base_url}/pull/${pr_num}"
            fi
            _git_remote_blame_log "$verbose" "Processing ${sha:0:12} (PR #${pr_num:-none})"
            local approvers_str=""
            if [ $show_approvers -eq 1 ] && [ -n "$pr_num" ]; then
                _git_remote_blame_log "$verbose" "  Fetching approvers for PR #$pr_num ..."
                approvers_str=$(gh pr view "$pr_num" --json reviews --jq '[.reviews[] | select(.state == "APPROVED") | .author.login] | unique | join(", ")' 2>/dev/null)
                _git_remote_blame_log "$verbose" "  Approvers: ${approvers_str:-none}"
            fi
            local out="${sha:0:12}  ${date%T*}  $(printf '%-20s' "$author")  ${pr_url:-N/A}"
            if [ $show_approvers -eq 1 ]; then
                out+="  approved-by: ${approvers_str:-N/A}"
            fi
            echo "$out"
        done <<< "$lines"
    fi
    _git_remote_blame_log "$verbose" "Done"
}

git_pause_branch() {
    if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
        echo "Usage: git_pause_branch"
        echo "Record the current branch and today's date in tmp/paused-branches.sh."
        return 0
    fi

    local branch_actual
    local paused_file="tmp/paused-branches.sh"
    local branch_line
    local prev_line

    mkdir -p tmp
    if [ ! -f "$paused_file" ]; then
        touch "$paused_file"
    fi

    branch_actual=$(git branch --show-current)

    if grep -Fxq "$branch_actual" "$paused_file"; then
        branch_line=$(grep -nxF "$branch_actual" "$paused_file" | cut -d: -f1 | head -n1)
        if [ -n "$branch_line" ]; then
            prev_line=$((branch_line - 1))
            if [ "$prev_line" -ge 1 ]; then
                sed -i "${prev_line}s|^#.*$|#$(hoy)|" "$paused_file"
            fi
        fi
    else
        printf '#%s\n%s\n\n' "$(hoy)" "$branch_actual" >> "$paused_file"
    fi
}

git_contributors() {
    if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
        echo "Usage: git_contributors"
        echo "List committers by commit count, excluding merge commits."
        return 0
    fi

    # Show committers.
    git shortlog -sn --no-merges
}

git_worktree_add() {
    if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
        echo "Usage: git_worktree_add <path>"
        echo "Add a worktree and copy supported local files, including ignored .envrc files below the current directory."
        return 0
    fi

    local worktree_path="${1:-}"
    if [ -z "$worktree_path" ]; then
        echo "Usage: git_worktree_add <path>" >&2
        return 1
    fi

    git worktree add "$worktree_path" || return

    local prefix envrc
    prefix=$(git rev-parse --show-prefix) || return
    while IFS= read -r -d '' envrc; do
        mkdir -p "$(dirname "$worktree_path/$prefix$envrc")" || return
        cp "$envrc" "$worktree_path/$prefix$envrc" || return
    done < <(git ls-files --others --ignored --exclude-standard -z -- '.envrc' ':(glob)**/.envrc')

    # Copy repository-local configuration and scratch files when present.
    if [ -d nix/config ]; then
        mkdir -p "$worktree_path/nix/config"
        if [ -f nix/config/user-aliases ]; then
            cp nix/config/user-aliases "$worktree_path/nix/config/user-aliases"
        fi
    fi

    if [ -d tmp ]; then
        mkdir -p "$worktree_path/tmp"

        if [ -f tmp/pain.sh ]; then
            cp tmp/pain.sh "$worktree_path/tmp/pain.sh"
        fi

        if [ -f tmp/spells.sh ]; then
            cp tmp/spells.sh "$worktree_path/tmp/spells.sh"
        fi
    fi
}

git_churned_files() {
    if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
        echo "Usage: git_churned_files"
        echo "List the 20 files with the most commits in the last year."
        return 0
    fi

    # Show files with the most commits in the last year.
    git log --format=format: --name-only --since="1 year ago" | sort | uniq -c | sort -nr | head -20
}

git_commit_rates() {
    if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
        echo "Usage: git_commit_rates"
        echo "Show commit counts grouped by month."
        return 0
    fi

    # Show commit counts by month.
    git log --format='%ad' --date=format:'%Y-%m' | sort | uniq -c
}
