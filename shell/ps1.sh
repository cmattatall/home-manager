# Home Manager uses programs.starship; this entry point is for portable use.
if [[ $- != *i* ]] || ! command -v starship >/dev/null 2>&1; then
    return 0
fi

# Respect an explicit config and the user's standard Starship config.
if [ -z "${STARSHIP_CONFIG:-}" ] && [ ! -f "${XDG_CONFIG_HOME:-$HOME/.config}/starship.toml" ]; then
    if [ -n "${ZSH_VERSION:-}" ]; then
        export STARSHIP_CONFIG="${${(%):-%x}:A:h}/starship.toml"
    elif [ -n "${BASH_VERSION:-}" ]; then
        export STARSHIP_CONFIG="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/starship.toml"
    fi
fi

if [ -n "${ZSH_VERSION:-}" ]; then
    eval "$(starship init zsh)"
elif [ -n "${BASH_VERSION:-}" ]; then
    eval "$(starship init bash)"
fi
