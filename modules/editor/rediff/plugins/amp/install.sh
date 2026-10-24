#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
    --help|-h)
        echo "Usage: $0"
        echo "Installs readiff and desloppify for this user. Backs up the old rediff plugin. Does not reload Amp."
        echo "Sets amp.keymap thread.interrupt to ctrl+l and esc esc, preserving other settings. Requires Python 3."
        exit 0 ;;
esac
if [ "$#" -ne 0 ]; then echo "Unexpected argument: $1" >&2; exit 2; fi

source_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
destination_dir="${HOME:?HOME must be set}/.config/amp/plugins"
legacy="$destination_dir/rediff.ts"
settings="$HOME/.config/amp/settings.json"

for path in "$destination_dir/readiff.ts" "$destination_dir/desloppify.ts" "$legacy" "$settings"; do
    if [ -L "$path" ] || { [ -e "$path" ] && [ ! -f "$path" ]; }; then
        echo "Refusing to replace a symlink or non-file: $path (use Home Manager if it owns this file)." >&2
        exit 1
    fi
done

mkdir -p "$destination_dir"
temporary=$(mktemp -d "$destination_dir/.amp-install.XXXXXX")
trap 'rm -rf "$temporary"' EXIT
for name in readiff desloppify; do
    cp "$source_dir/$name.ts" "$temporary/$name.ts"
    chmod 644 "$temporary/$name.ts"
done

# Validate settings first so a failed merge leaves the installed plugins intact.
python3 - "$settings" <<'PY'
import json
import os
import sys
import tempfile
from pathlib import Path

path = Path(sys.argv[1])
try:
    settings = json.loads(path.read_text()) if path.exists() else {}
    if not isinstance(settings, dict):
        raise ValueError("settings must be a JSON object")
    keymap = settings.setdefault("amp.keymap", {})
    if not isinstance(keymap, dict):
        raise ValueError("amp.keymap must be a JSON object")
    # Neovim sends Escape for Ctrl-L so Amp's dialogs handle it as well.
    # Keep Ctrl-L for standalone Amp and older editor versions.
    interrupt = ["ctrl+l", "esc esc"]
    if keymap.get("thread.interrupt") != interrupt:
        keymap["thread.interrupt"] = interrupt
        fd, temporary = tempfile.mkstemp(prefix=".readiff-keymap-", dir=path.parent)
        try:
            with os.fdopen(fd, "w") as output:
                json.dump(settings, output, indent=2)
                output.write("\n")
            os.replace(temporary, path)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
except (OSError, ValueError) as error:
    sys.exit(f"Cannot configure Amp interrupt key in {path}: {error}")
PY
if [ -f "$legacy" ]; then
    backup_dir="$HOME/.config/amp/plugin-backups"
    mkdir -p "$backup_dir"
    backup=$(mktemp -d "$backup_dir/readiff-migration.XXXXXX")
    mv "$legacy" "$backup/rediff.ts"
    printf 'Backed up old plugin to %s\n' "$backup/rediff.ts"
fi
for name in readiff desloppify; do
    mv -f "$temporary/$name.ts" "$destination_dir/$name.ts"
    printf 'Installed %s\n' "$destination_dir/$name.ts"
done
printf 'Configured Ctrl+L and Esc Esc to interrupt Amp; other settings and keybindings preserved.\n'
printf 'In the Amp pane, Ctrl+L sends Escape: once to dismiss/back, twice to interrupt.\n'
printf 'Restart Amp or reload its plugins, then run :harness connect amp in rediff.\n'
printf 'Desloppify supplies coding guidance on every turn and adds code: desloppify to the Amp command palette.\n'
printf 'No other plugins were changed. No reload was performed.\n'
