
# Home Manager provides LLVM directly; Homebrew is only a non-Nix fallback.
if command -v llvm-config >/dev/null 2>&1; then
    return 0
fi

if [ "$(uname -s)" != "Darwin" ] || ! command -v brew >/dev/null 2>&1; then
    return 0
fi

LLVM_BREW_PREFIX=$(brew --prefix llvm 2>/dev/null) || return 0

if [ -d "$LLVM_BREW_PREFIX/bin" ]; then
    export PATH="$PATH:$LLVM_BREW_PREFIX/bin"
fi
