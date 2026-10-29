# Use shell builtins so startup does not require Nix or GNU realpath.
if [ -n "${ZSH_VERSION:-}" ]; then
    THIS_FILE_PATH="${(%):-%x}"
elif [ -n "${BASH_VERSION:-}" ]; then
    THIS_FILE_PATH="${BASH_SOURCE[0]}"
else
    echo "shell/index.sh requires Bash or Zsh" >&2
    return 1
fi
THIS_DIR="$(CDPATH= cd -- "$(dirname "$THIS_FILE_PATH")" && pwd -P)"
THIS_FILE_PATH="$THIS_DIR/index.sh"
export THIS_FILE_PATH

# Resolve against this directory only, so same-named files in $PWD are never sourced.
source_one(){
    local file="${THIS_DIR}/$1"
    source "$file" || echo "Failed to source $file"
}

source_one jsonfmt.sh
source_one textmanip.sh
source_one paths.sh
source_one cmake.sh
source_one bazel.sh
source_one arm-none-eabi.sh
source_one llvm.sh
source_one psql.sh
source_one rust.sh
source_one tf_scripts.sh
source_one misc.sh

source_one nix.sh
source_one aws.sh

# Home Manager loads the prompt separately with its configured options.
if [ "${SHELLRC_SKIP_PROMPT:-0}" != 1 ]; then
    source_one ps1.sh
fi


source_one git.sh

# Code composer studio
source_one ccs.sh
source_one fzf.sh

source_one tmux.sh
