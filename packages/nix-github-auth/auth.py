"""Configure user-level Nix authentication from the GitHub CLI credential store."""

import argparse
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path


def write_private(path, contents):
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w") as output:
            output.write(contents)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def configure(config_home):
    if not config_home.is_absolute():
        raise ValueError("XDG_CONFIG_HOME must be an absolute path")
    directory = config_home / "nix"
    configuration = directory / "nix.conf"
    credentials = directory / "github-access-token.conf"
    include = "!include github-access-token.conf"

    if credentials.is_symlink():
        raise ValueError(f"Refusing to replace a credential symlink: {credentials}")

    contents = configuration.read_text() if configuration.exists() else ""
    includes = [line.split("#", 1)[0].strip() for line in contents.splitlines()]
    has_include = include in includes or "include github-access-token.conf" in includes
    if configuration.is_symlink() and not has_include:
        raise ValueError(
            f"Add '{include}' through the owner of {configuration}, then retry"
        )

    result = subprocess.run(
        ["gh", "auth", "token", "--hostname", "github.com"],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode:
        raise ValueError(
            "Cannot read GitHub credentials. Run gh auth login --hostname github.com first"
        )
    token = result.stdout.strip()
    if not token or any(character.isspace() or character == "#" for character in token):
        raise ValueError("GitHub CLI returned an invalid token")

    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    write_private(credentials, f"extra-access-tokens = github.com={token}\n")
    if not has_include:
        separator = "\n" if contents and not contents.endswith("\n") else ""
        write_private(configuration, f"{contents}{separator}{include}\n")

    result = subprocess.run(
        [
            "nix",
            "--extra-experimental-features",
            "nix-command",
            "config",
            "show",
            "--json",
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode:
        raise ValueError("Credential saved, but Nix could not read its configuration")
    settings = json.loads(result.stdout)
    active_token = settings["access-tokens"]["value"].get("github.com")
    if active_token != token:
        raise ValueError(
            "Credential saved, but Nix is using different authentication. "
            "Check existing github.com entries, NIX_CONFIG, and NIX_USER_CONF_FILES"
        )
    print(f"Configured Nix GitHub authentication in {credentials}")


def main():
    parser = argparse.ArgumentParser(prog="nix-github-auth", description=__doc__)
    parser.parse_args()
    config_home = Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config")
    try:
        configure(config_home)
    except (OSError, ValueError) as error:
        sys.exit(f"nix-github-auth: {error}")


if __name__ == "__main__":
    main()
