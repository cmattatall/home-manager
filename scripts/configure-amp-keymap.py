"""Merge Home Manager's keybindings without owning the rest of Amp's settings."""

import json
import os
import sys
import tempfile
from pathlib import Path


def configure(path, bindings):
    if path.is_symlink() or (path.exists() and not path.is_file()):
        raise ValueError(f"Refusing to replace a symlink or non-file: {path}")
    settings = json.loads(path.read_text()) if path.exists() else {}
    if not isinstance(settings, dict):
        raise ValueError("Amp settings must be a JSON object")
    keymap = settings.setdefault("amp.keymap", {})
    if not isinstance(keymap, dict):
        raise ValueError("amp.keymap must be a JSON object")
    if all(keymap.get(key) == value for key, value in bindings.items()):
        return
    keymap.update(bindings)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".amp-keymap-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as output:
            json.dump(settings, output, indent=2)
            output.write("\n")
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


if __name__ == "__main__":
    try:
        configure(Path(sys.argv[1]), json.loads(sys.argv[2]))
    except (OSError, ValueError) as error:
        sys.exit(f"Cannot configure Amp keybindings: {error}")
