

copy(){
    if hash pbcopy 2>/dev/null; then
        pbcopy
    elif hash xclip 2>/dev/null; then
       xclip -selection clipboard
    elif hash putclip 2>/dev/null; then
        putclip
    else
        rm -f /tmp/clipboard 2> /dev/null
        if [ $# -eq 0 ]; then
            cat > /tmp/clipboard
        else
            cat "$1" > /tmp/clipboard
        fi
    fi
}

pasta(){
    if hash pbpaste 2>/dev/null; then
        pbpaste
    elif hash xclip 2>/dev/null; then
        xclip -selection clipboard -o
    elif [[ -e /tmp/clipboard ]]; then
        cat /tmp/clipboard
    else
        echo ''
    fi
}

alias cb="copy"
alias pst="pasta"

cpwd(){
    pwd | copy
}



lines() {
    if [ ! -z $2 ]; then
        echo "Too many arguments."
        echo "Usage: lines <line count>"
        return 1
    fi
    head -n "$1" | tail -n 1
}

uppered() {
    tr '[:lower:]' '[:upper:]'
}

lowered() {
    tr '[:upper:]' '[:lower:]'
}


# Prints current date in ISO format
hoy(){
    echo -n "$(date '+%Y-%m-%d')"
}
