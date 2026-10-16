# Re-read Home Manager session variables as well as the login shell's startup files.
alias reload-shell='unset __HM_SESS_VARS_SOURCED; exec "$SHELL" -l'

if [ "$(uname -s)" = "Darwin" ]; then
nproc(){
    sysctl -n hw.logicalcpu
}
fi


if [ "$(uname -s)" = "Darwin" ]; then
systemctl(){
    echo "command systemctl does not exist on mac. Instead use\nlaunchctl\n";
}
fi


if [ $(uname -s) = "Darwin" ]; then
lsusb(){
	echo "command does not exist on mac. Use\nioreg -p IOUSB\n"
	ioreg -p IOUSB
}
fi


ssh_restart(){
    local system_name=$(uname -s)
    if [ "$system_name" == "Darwin" ]; then
        sudo launchctl stop com.openssh.sshd
        sudo launchctl start com.openssh.sshd
    elif [ "$system_name" == "Linux" ]; then
        sudo systemctl restart sshd
    else
        echo "Unsupported system: $system_name"
        echo "Please restart sshd manually"
        return 1
    fi
}


# repeat is a zsh reserved word; key on the running shell, not the login $SHELL.
if [ -z "${ZSH_VERSION:-}" ]; then
    eval '
    repeat() {
        if [ $# -lt 2 ]; then
            echo "Usage: repeat <count> <command> [args...]"
            return 1
        fi

        local count=$1
        shift

        if ! [[ "$count" =~ ^[0-9]+$ ]] || [ "$count" -lt 1 ]; then
            echo "repeat: <count> must be a positive integer"
            return 1
        fi

        for ((i=1; i<=count; i++)); do
            "$@"
        done
    }
    '
fi



_alias_expand_segment(){
    local -n _result=$1
    local -n _segment=$2
    local _aliases="$3"

    local -a words=("${_segment[@]}")
    local -A seen=()

    while true; do
        local first_word="${words[0]}"
        if [[ -n "${seen[$first_word]+x}" ]]; then
            break
        fi

        # Use bash's own `alias` builtin so we get the canonical
        # single-quoted form (with '\'' escapes for embedded quotes),
        # then `eval` to decode those escapes correctly.
        local alias_def
        alias_def=$(alias "$first_word" 2>/dev/null)
        if [ -z "$alias_def" ]; then
            break
        fi

        local quoted="${alias_def#alias *=}"
        local expansion
        eval "expansion=$quoted"

        seen[$first_word]=1

        local -a exp_words=($expansion)
        words=("${exp_words[@]}" "${words[@]:1}")
    done

    _result+=("${words[@]}")
}

alias_expand(){
    if [[ "$1" == "--help" || "$1" == "-h" ]]; then
        cat <<EOF
Usage: alias_expand <command> [args...]
       echo '<command>' | alias_expand

Expands alias tokens in the given command using any defined alias in the current shell.
Recursively expands nested aliases (e.g., an alias whose expansion starts with another alias).
Handles chained commands separated by &&, ||, ;, |, and |&.
Prints the fully expanded command line. Circular aliases are detected and left unexpanded.

If no arguments are given and stdin is not a terminal, reads commands from stdin (one per line).

Examples:
  alias ll='ls -l'
  alias_expand ll /etc
  # Output: ls -l /etc

  alias g='git'
  alias gs='g status'
  alias_expand gs
  # Output: git status

  alias foo='foo_1'
  alias bar='bar_1'
  alias_expand foo '&&' bar
  # Output: foo_1 && bar_1

  # Read from a file:
  echo 'gs' > /tmp/cmds.txt
  alias_expand < /tmp/cmds.txt
  # Output: git status

Options:
  --help, -h     Show this help message and exit.
EOF
        return 0
    fi

    if [ $# -eq 0 ]; then
        if [[ -t 0 ]]; then
            echo "Usage: alias_expand <command> [args...]"
            return 1
        fi
        # Read from stdin, one line at a time
        local line
        while IFS= read -r line; do
            alias_expand $line
        done
        return
    fi

    local aliases
    aliases=$(alias)

    # Re-tokenize: split all arguments on whitespace so that
    # both  dealias foo '&&' bar  and  dealias "foo && bar"  work.
    local -a all_words=()
    read -r -a all_words <<< "$*"
    local -a result=()
    local -a segment=()

    for word in "${all_words[@]}"; do
        if [[ "$word" == "&&" || "$word" == "||" || "$word" == ";" || "$word" == "|" || "$word" == "|&" ]]; then
            if [ ${#segment[@]} -gt 0 ]; then
                _alias_expand_segment result segment "$aliases"
                segment=()
            fi
            result+=("$word")
        else
            segment+=("$word")
        fi
    done

    if [ ${#segment[@]} -gt 0 ]; then
        _alias_expand_segment result segment "$aliases"
    fi

    printf "%s\n" "${result[*]}"
}


alias alflat="alias_expand"
alias dealias="alias_expand"
