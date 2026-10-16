which fzf > /dev/null 2>&1
if [ $? -ne "0" ]; then
    echo "fzf not found. Please install it before continuing."
    return 0
fi

if [ -n "${ZSH_VERSION:-}" ]; then
    source <(fzf --zsh)
elif [ -n "${BASH_VERSION:-}" ]; then
    eval "$(fzf --bash)"
else
    echo "could not source fzf for this shell"
fi
