"""Publish snapshots to disposable local remotes, never GitHub."""

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/publish-home-manager.sh"


class HomeMirrorTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / "source"
        self.source.mkdir()
        self.remote = self.root / "public.git"
        tools = self.root / "bin"
        tools.mkdir()
        scanner = tools / "gitleaks"
        scanner.write_text("#!/bin/sh\nexit \"${SCAN_EXIT:-0}\"\n")
        scanner.chmod(0o755)
        self.env = {
            **os.environ,
            "PATH": f"{tools}{os.pathsep}{os.environ['PATH']}",
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "Private Author",
            "GIT_AUTHOR_EMAIL": "private@example.invalid",
            "GIT_COMMITTER_NAME": "Private Author",
            "GIT_COMMITTER_EMAIL": "private@example.invalid",
        }
        self.git(self.source, "init", "--initial-branch=main")
        self.git(self.root, "init", "--bare", "--initial-branch=main", str(self.remote))
        (self.source / "scripts").mkdir()
        shutil.copy2(SCRIPT, self.source / "scripts/publish-home-manager.sh")
        (self.source / "home.nix").write_text("old private content\n")
        self.commit("Private original history")
        self.private_commit = self.git(self.source, "rev-parse", "HEAD")
        (self.source / "home.nix").write_text("public configuration\n")
        (self.source / ".gitignore").write_text(".env\n")
        self.commit("Private latest message")
        (self.source / ".env").write_text("ignored private content\n")

    def git(self, directory, *args):
        return subprocess.check_output(
            ["git", "-C", str(directory), *args], env=self.env,
            stderr=subprocess.PIPE, text=True,
        ).strip()

    def commit(self, message):
        self.git(self.source, "add", "--all")
        self.git(self.source, "commit", "-m", message)

    def run_script(self, publish=False, success=True):
        result = subprocess.run(
            [str(self.source / "scripts/publish-home-manager.sh"),
             "--remote", str(self.remote), *(["--publish"] if publish else [])],
            env=self.env, text=True, capture_output=True,
        )
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        return result.stdout + result.stderr

    def test_preview_public_history_identity_updates_and_noop(self):
        head = self.git(self.source, "rev-parse", "HEAD")
        self.assertIn("Preview only", self.run_script())
        self.assertEqual("", self.git(self.remote, "for-each-ref"))
        self.run_script(publish=True)
        first = self.git(self.remote, "rev-parse", "main")
        self.assertEqual("1", self.git(self.remote, "rev-list", "--count", "main"))
        self.assertEqual(
            "public configuration", self.git(self.remote, "show", "main:home.nix"),
        )
        self.assertNotIn(".env", self.git(self.remote, "ls-tree", "--name-only", "main"))
        self.assertEqual(
            "36604988+cmattatall@users.noreply.github.com\n"
            "36604988+cmattatall@users.noreply.github.com\nUpdate Home Manager snapshot",
            self.git(self.remote, "log", "--format=%ae%n%ce%n%s", "main"),
        )
        for revision in [head, self.private_commit]:
            self.assertNotEqual(0, subprocess.run(
                ["git", "-C", str(self.remote), "cat-file", "-e", revision],
                env=self.env, capture_output=True,
            ).returncode)
        self.assertIn("already up to date", self.run_script(publish=True))
        self.assertEqual(first, self.git(self.remote, "rev-parse", "main"))
        self.assertEqual(head, self.git(self.source, "rev-parse", "HEAD"))
        self.assertEqual("", self.git(self.source, "status", "--porcelain"))
        (self.source / "home.nix").unlink()
        (self.source / "macbook.nix").write_text("replacement\n")
        self.commit("Another private update")
        self.run_script(publish=True)
        self.assertEqual(first, self.git(self.remote, "rev-parse", "main^"))
        self.assertNotIn("home.nix", self.git(self.remote, "ls-tree", "--name-only", "main"))
        self.assertEqual("replacement", self.git(self.remote, "show", "main:macbook.nix"))

    def test_dirty_and_unreviewed_source_refused(self):
        (self.source / "private.txt").write_text("must not publish\n")
        self.assertIn("Commit or set aside", self.run_script(publish=True, success=False))
        self.commit("Unreviewed addition")
        self.assertIn("Unreviewed top-level", self.run_script(publish=True, success=False))
        self.assertEqual("", self.git(self.remote, "for-each-ref"))

    def test_scan_failure_blocks_preview_diff_and_push(self):
        for exit_code in ["1", "2"]:
            with self.subTest(exit_code=exit_code):
                self.env["SCAN_EXIT"] = exit_code
                for publish in [False, True]:
                    output = self.run_script(publish=publish, success=False)
                    self.assertNotIn("public configuration", output)
                    self.assertEqual("", self.git(self.remote, "for-each-ref"))

    def test_unmarked_destination_and_missing_main_refused(self):
        self.git(self.source, "push", str(self.remote), "main:other")
        self.assertIn("no main branch", self.run_script(publish=True, success=False))
        self.git(self.source, "push", str(self.remote), "main")
        before = self.git(self.remote, "rev-parse", "main")
        self.assertIn("unmarked repository", self.run_script(publish=True, success=False))
        self.assertEqual(before, self.git(self.remote, "rev-parse", "main"))

    def test_submodules_refused(self):
        (self.source / "modules").mkdir()
        self.git(
            self.source, "update-index", "--add", "--cacheinfo", "160000",
            self.private_commit, "modules/nested",
        )
        self.git(self.source, "commit", "-m", "Submodule fixture")
        (self.source / "modules/nested").mkdir()
        self.assertIn("submodules", self.run_script(publish=True, success=False))
        self.assertEqual("", self.git(self.remote, "for-each-ref"))

    def test_rejected_push_preserves_destination(self):
        self.run_script(publish=True)
        before = self.git(self.remote, "rev-parse", "main")
        hook = self.remote / "hooks/pre-receive"
        hook.write_text("#!/bin/sh\necho publication-rejected >&2\nexit 1\n")
        hook.chmod(0o755)
        (self.source / "home.nix").write_text("next version\n")
        self.commit("Private next version")
        self.assertIn("publication-rejected", self.run_script(publish=True, success=False))
        self.assertEqual(before, self.git(self.remote, "rev-parse", "main"))


if __name__ == "__main__":
    unittest.main()
