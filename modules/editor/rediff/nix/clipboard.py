"""Copy stdin through the enclosing Neovim terminal, not the remote desktop."""

import argparse
import base64
import sys


def main():
    tool = sys.argv[1]
    parser = argparse.ArgumentParser(prog=tool)
    if tool == "xclip":
        parser.add_argument("-selection", choices=["clipboard", "primary"], default="clipboard")
        parser.add_argument("-i", "-in", action="store_true")
    elif tool == "wl-copy":
        parser.add_argument("-t", "--type", choices=["text/plain", "text/plain;charset=utf-8"])
        parser.add_argument("-n", "--trim-newline", action="store_true")
    elif tool == "pbcopy":
        parser.add_argument("-pboard", choices=["general"], default="general")
    else:
        parser.error("unsupported clipboard command")
    args = parser.parse_args(sys.argv[2:])
    data = sys.stdin.buffer.read()
    if getattr(args, "trim_newline", False) and data.endswith(b"\n"):
        data = data[:-1]
    selection = b"p" if getattr(args, "selection", None) == "primary" else b"c"
    # Amp captures subprocess stdout. The controlling PTY, not stdout, is the
    # Neovim terminal that handles OSC 52 using its configured clipboard provider.
    with open("/dev/tty", "wb") as terminal:
        terminal.write(b"\x1b]52;" + selection + b";" + base64.b64encode(data) + b"\x07")


if __name__ == "__main__":
    main()
