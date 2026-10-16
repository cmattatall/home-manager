LOCAL_BIN_PATH="$HOME/.local/bin"

if [ -d "$LOCAL_BIN_PATH" ]; then
    export PATH="$PATH:$LOCAL_BIN_PATH"
fi

# Gets the directory this file is located in, compatible with bash and zsh, even when sourced

# Bash: Use ${BASH_SOURCE[0]}
if [ -n "${BASH_SOURCE[0]:-}" ]; then
    PATHS_SH_FILE="${BASH_SOURCE[0]}"
# Zsh: Use ${(%):-%N}
elif [ -n "${(%):-%N}" ]; then
    PATHS_SH_FILE="${(%):-%N}"
else
    PATHS_SH_FILE="$0"
fi

THIS_FILE_DIR="$(cd "$(dirname "$PATHS_SH_FILE")" && pwd)"

# Add our custom binaries to the PATH
export PATH="$PATH:$THIS_FILE_DIR/bin"


# ----- FUNCTIONS -----

# Prints $PATH but with newlines separating entries
prettypath(){
    echo "$PATH" | sed 's/:/\n/g'
}

mkcd(){
    if [ ! -z "$2" ]; then
        echo "Too many arguments. Usage: mkcd <directory>"
        echo "Usage: mkcd <directory>"
        echo
        echo "Creates a directory and changes into it."
        return 1
    fi
    mkdir -p "$1"
    cd "$1"
}

tmpe(){
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                echo "Usage: tmpe"
                echo
                echo "Creates a temporary directory and changes into it."
                echo
                echo "Options:"
                echo "  -h, --help   Show this help message and exit."
                return 0
                ;;
        esac
        shift
    done

    local dir="$(mktemp -d)"
    cd "$dir"
    echo "$dir"
}

# "trash" command is taken on some systems
scrap(){

    # We may not have access to /tmp/trash, so expose option to for a custom directory.
    local trash_dir="$TRASH_DIR"
    if [ -z "$trash_dir" ]; then
        trash_dir="/tmp/trash"
    fi

    if [ ! -d "$trash_dir" ]; then
        mkdir -p "$trash_dir"
    elif [ -f "$trash_dir" ]; then
        echo "$trash_dir is a file, not a directory. Please delete it and try again."
        return 1
    fi
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                echo "Usage: trash [--help] [--list] <file>"
                echo
                echo "Moves the specified file to /tmp/trash."
                echo
                echo "Options:"
                echo "  --help    Show this help message and exit."
                echo "  --list    List contents of /tmp/trash."
                return 0
                ;;
            --list|-l)
                ls -lah "$trash_dir"
                return 0
                ;;
        esac
    done

    for arg in "$@"; do
        mv "$arg" "$trash_dir"
    done
}
