# Reattachment updates tmux's session environment, not existing pane shells.
_tmux_refresh_ssh_agent() {
    local previous_exit_status=$? agent
    if [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ]; then
        if agent=$(command tmux show-environment -t "$TMUX_PANE" SSH_AUTH_SOCK 2>/dev/null); then
            case "$agent" in
                SSH_AUTH_SOCK=*)
                    agent=${agent#SSH_AUTH_SOCK=}
                    if [ -S "$agent" ]; then
                        export SSH_AUTH_SOCK="$agent"
                    fi
                    ;;
            esac
        fi
    fi
    # Zsh preserves prompt status itself; a nonzero hook would skip later hooks.
    if [ -n "${ZSH_VERSION:-}" ]; then
        return 0
    fi
    return "$previous_exit_status"
}

if [[ $- == *i* ]]; then
    if [ -n "${ZSH_VERSION:-}" ]; then
        autoload -Uz add-zsh-hook
        add-zsh-hook precmd _tmux_refresh_ssh_agent
    elif [ -n "${BASH_VERSION:-}" ]; then
        if [[ "$(declare -p PROMPT_COMMAND 2>/dev/null)" == "declare -a"* ]]; then
            if [[ " ${PROMPT_COMMAND[*]:-} " != *" _tmux_refresh_ssh_agent "* ]]; then
                PROMPT_COMMAND=(_tmux_refresh_ssh_agent "${PROMPT_COMMAND[@]}")
            fi
        elif [[ ";${PROMPT_COMMAND:-};" != *";_tmux_refresh_ssh_agent;"* ]]; then
            PROMPT_COMMAND="_tmux_refresh_ssh_agent${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
        fi
    fi
fi

tmux_setup(){
    local session bottom pane
    if ! session=$(tmux display-message -p '#{session_id}' 2>/dev/null); then
        session=$(tmux new-session -d -x - -y - -c "$PWD" -P -F '#{session_id}') || return
        bottom=$(tmux split-window -d -v -l 25% -c "$PWD" -t "$session:" -P -F '#{pane_id}') || return
        tmux split-window -d -h -l 50% -c "$PWD" -t "$session:" || return
        tmux split-window -d -h -l 50% -c "$PWD" -t "$bottom" || return

        for pane in $(tmux list-panes -t "$session:" -F '#{pane_id}'); do
            tmux send-keys -t "$pane" 'if command -v nix >/dev/null 2>&1; then nix develop; fi' Enter || return
        done
    fi

    if [ -n "${TMUX:-}" ]; then
        tmux switch-client -t "$session"
    else
        tmux attach-session -t "$session"
    fi
}
