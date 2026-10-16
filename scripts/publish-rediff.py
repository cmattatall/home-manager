#!/usr/bin/env python3
"""Preview or publish modules/editor/rediff/ to a separate, one-way mirror."""

import argparse
import shutil
import subprocess
import tempfile
from pathlib import Path

MARKER = ".rediff-mirror"
MARKER_TEXT = "rediff snapshot mirror v1\n"
SOURCE = Path(__file__).resolve().parent.parent
SUBTREE = "modules/editor/rediff"


def git(directory, *args):
    return subprocess.check_output(
        ["git", "-C", str(directory), *args], text=True
    ).strip()


def publish(remote, push, adopt=None):
    # Pin HEAD once so a concurrent local commit cannot change the export.
    revision = git(SOURCE, "rev-parse", "HEAD")
    if git(SOURCE, "status", "--porcelain", "--untracked-files=all", "--", SUBTREE):
        raise RuntimeError(f"Commit or set aside {SUBTREE}/ changes before exporting.")
    tree = f"{revision}:{SUBTREE}"
    names = git(SOURCE, "ls-tree", "--name-only", tree).splitlines()
    if MARKER in names:
        raise RuntimeError(f"{SUBTREE}/{MARKER} is reserved for the mirror.")
    if any(
        line.startswith("160000 ")
        for line in git(SOURCE, "ls-tree", "-r", tree).splitlines()
    ):
        raise RuntimeError("The export cannot include submodules; vendor them first.")

    with tempfile.TemporaryDirectory(prefix="rediff-mirror-") as temporary:
        temporary = Path(temporary)
        mirror = temporary / "mirror"
        mirror.mkdir()
        git(mirror, "init", "--quiet", "--initial-branch=main")
        git(mirror, "config", "core.hooksPath", "/dev/null")
        git(mirror, "remote", "add", "origin", remote)
        refs = git(mirror, "ls-remote", "--heads", "--tags", "origin")
        if refs:
            if not any(
                line.endswith("\trefs/heads/main") for line in refs.splitlines()
            ):
                raise RuntimeError("Destination is not empty and has no main branch.")
            git(mirror, "fetch", "--quiet", "--no-tags", "origin", "refs/heads/main")
            if adopt and git(mirror, "rev-parse", "FETCH_HEAD") != adopt:
                raise RuntimeError(
                    "Destination main changed or --adopt is not its full commit ID. Preview again."
                )
            marker = subprocess.run(
                ["git", "-C", str(mirror), "show", f"FETCH_HEAD:{MARKER}"],
                capture_output=True,
                text=True,
            )
            if (marker.returncode or marker.stdout != MARKER_TEXT) and not adopt:
                raise RuntimeError(
                    "Refusing to overwrite an unmarked repository. Use an empty destination or --adopt FULL_COMMIT_ID."
                )
            git(mirror, "checkout", "--quiet", "-B", "main", "FETCH_HEAD")
        elif adopt:
            raise RuntimeError("Cannot adopt an empty destination.")
        # Replace the snapshot, including deletions; keep only mirror history.
        for path in mirror.iterdir():
            if path.name == ".git":
                continue
            if path.is_dir() and not path.is_symlink():
                shutil.rmtree(path)
            else:
                path.unlink()
        archive = temporary / "rediff.tar"
        git(SOURCE, "archive", "--format=tar", f"--output={archive}", tree)
        subprocess.run(["tar", "-xf", str(archive), "-C", str(mirror)], check=True)
        (mirror / MARKER).write_text(MARKER_TEXT)
        # Force-add exported files even when the editor's .gitignore matches them.
        git(mirror, "add", "--all", "--force")
        changed = git(mirror, "diff", "--cached", "--name-status")
        if not changed:
            print("Mirror is already up to date.")
            return
        print(f"Destination: {remote}\nBranch: main\n{changed}", flush=True)
        subprocess.run(
            [
                "git",
                "-C",
                str(mirror),
                "--no-pager",
                "diff",
                "--cached",
                "--no-ext-diff",
                "--no-textconv",
            ],
            check=True,
        )
        if not push:
            print(
                "Preview only: nothing was pushed. Audit the export before using --publish."
            )
            return
        # No private commit messages, authors, ancestry, or parent files are copied.
        # The publisher's normal Git identity is used for this new public commit.
        git(mirror, "commit", "--quiet", "-m", "Update Rediff snapshot")
        git(mirror, "push", "origin", "HEAD:refs/heads/main")
        print("Published Rediff snapshot.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--remote", required=True, help="Mirror Git URL")
    parser.add_argument(
        "--adopt",
        metavar="FULL_COMMIT_ID",
        help="Explicitly adopt an existing repository at this main commit, preserving its history",
    )
    parser.add_argument(
        "--publish",
        action="store_true",
        help="Commit and push; default is a read-only remote preview",
    )
    args = parser.parse_args()
    try:
        publish(args.remote, args.publish, args.adopt)
    except (RuntimeError, subprocess.CalledProcessError, OSError) as error:
        parser.exit(1, f"publish-rediff: {error}\n")


if __name__ == "__main__":
    main()
