"""Exercise mirror publication against disposable local Git repositories."""

import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/publish-rediff.py"


class MirrorTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / "source"
        self.remote = self.root / "public.git"
        self.source.mkdir()
        self.env = {
            **os.environ,
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "Publisher",
            "GIT_AUTHOR_EMAIL": "publisher@example.invalid",
            "GIT_COMMITTER_NAME": "Publisher",
            "GIT_COMMITTER_EMAIL": "publisher@example.invalid",
        }
        self.git(self.source, "init", "--initial-branch=main")
        self.git(self.root, "init", "--bare", "--initial-branch=main", str(self.remote))
        (self.source / "scripts").mkdir()
        shutil.copyfile(SCRIPT, self.source / "scripts/publish-rediff.py")
        self.editor = self.source / "modules/editor/rediff"
        self.editor.mkdir(parents=True)
        (self.editor.parent / "rediff.nix").write_text("private integration\n")
        (self.source / "private.txt").write_text("private parent content\n")
        (self.editor / "editor.lua").write_text("first version\n")
        self.commit("private original history")
        (self.editor / "editor.lua").write_text("current version\n")
        (self.editor / ".gitignore").write_text("ignored.txt\n")
        (self.editor / "ignored.txt").write_text("tracked despite ignore\n")
        (self.editor / "run.sh").write_text("#!/bin/sh\nexit 0\n")
        (self.editor / "run.sh").chmod(0o755)
        (self.editor / "link").symlink_to("editor.lua")
        self.commit("private latest message")

    def git(self, directory, *args):
        return subprocess.check_output(
            ["git", "-C", str(directory), *args],
            env=self.env,
            stderr=subprocess.PIPE,
            text=True,
        ).strip()

    def commit(self, message):
        self.git(self.source, "add", "--all", "--force")
        self.git(self.source, "commit", "-m", message)

    def run_script(self, publish=False, success=True, adopt=None):
        result = subprocess.run(
            [
                sys.executable,
                str(self.source / "scripts/publish-rediff.py"),
                "--remote",
                str(self.remote),
                *(["--publish"] if publish else []),
                *(["--adopt", adopt] if adopt else []),
            ],
            env=self.env,
            text=True,
            capture_output=True,
        )
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        return result.stdout + result.stderr

    def test_preview_publish_update_and_noop_preserve_only_public_history(self):
        self.assertIn("Preview only", self.run_script())
        self.assertEqual("", self.git(self.remote, "for-each-ref"))
        self.run_script(publish=True)
        first = self.git(self.remote, "rev-parse", "main")
        self.assertEqual("1", self.git(self.remote, "rev-list", "--count", "main"))
        self.assertEqual(
            "Update Rediff snapshot",
            self.git(self.remote, "log", "--format=%s", "main"),
        )
        self.assertEqual(
            [
                ".gitignore",
                ".rediff-mirror",
                "editor.lua",
                "ignored.txt",
                "link",
                "run.sh",
            ],
            self.git(self.remote, "ls-tree", "--name-only", "main").splitlines(),
        )
        self.assertEqual(
            "current version", self.git(self.remote, "show", "main:editor.lua")
        )
        self.assertEqual(
            "tracked despite ignore", self.git(self.remote, "show", "main:ignored.txt")
        )
        self.assertTrue(
            self.git(self.remote, "ls-tree", "main", "run.sh").startswith("100755")
        )
        self.assertTrue(
            self.git(self.remote, "ls-tree", "main", "link").startswith("120000")
        )
        self.assertIn("already up to date", self.run_script(publish=True))
        self.assertEqual(first, self.git(self.remote, "rev-parse", "main"))
        (self.editor / "editor.lua").write_text("updated version\n")
        (self.editor / "ignored.txt").unlink()
        (self.editor / "new.lua").write_text("new file\n")
        self.commit("another private message")
        self.run_script()
        self.assertEqual(first, self.git(self.remote, "rev-parse", "main"))
        self.run_script(publish=True)
        self.assertEqual(first, self.git(self.remote, "rev-parse", "main^"))
        self.assertEqual(
            "updated version", self.git(self.remote, "show", "main:editor.lua")
        )
        self.assertEqual("new file", self.git(self.remote, "show", "main:new.lua"))
        self.assertNotIn(
            "ignored.txt", self.git(self.remote, "ls-tree", "--name-only", "main")
        )

    def test_dirty_editor_refused_but_parent_edits_are_not_exported(self):
        for path, staged in (
            ("editor.lua", False),
            ("new.lua", False),
            ("editor.lua", True),
        ):
            with self.subTest(path=path, staged=staged):
                target = self.editor / path
                target.write_text("uncommitted\n")
                if staged:
                    self.git(self.source, "add", "modules/editor/rediff")
                self.assertIn(
                    "Commit or set aside", self.run_script(publish=True, success=False)
                )
                self.git(self.source, "reset", "--hard", "HEAD")
                self.git(self.source, "clean", "-fd")
        (self.source / "private.txt").write_text("uncommitted private edit\n")
        self.git(self.source, "add", "private.txt")
        before = self.git(self.source, "status", "--porcelain")
        head = self.git(self.source, "rev-parse", "HEAD")
        self.run_script(publish=True)
        self.assertEqual(before, self.git(self.source, "status", "--porcelain"))
        self.assertEqual(head, self.git(self.source, "rev-parse", "HEAD"))
        self.assertNotIn(
            "private.txt", self.git(self.remote, "ls-tree", "--name-only", "main")
        )

    def test_reserved_marker_and_submodules_are_refused(self):
        (self.editor / ".rediff-mirror").write_text("collision\n")
        self.commit("reserved path")
        self.assertIn("reserved", self.run_script(publish=True, success=False))
        (self.editor / ".rediff-mirror").unlink()
        self.commit("remove reserved path")
        self.git(
            self.source,
            "update-index",
            "--add",
            "--cacheinfo",
            "160000",
            self.git(self.source, "rev-parse", "HEAD"),
            "modules/editor/rediff/nested",
        )
        self.git(self.source, "commit", "-m", "submodule fixture")
        (self.editor / "nested").mkdir()
        self.assertIn("submodules", self.run_script(publish=True, success=False))
        self.assertEqual("", self.git(self.remote, "for-each-ref"))

    def test_existing_unmarked_destination_is_not_overwritten(self):
        self.git(self.source, "push", str(self.remote), "main")
        before = self.git(self.remote, "rev-parse", "main")
        self.assertIn(
            "unmarked repository", self.run_script(publish=True, success=False)
        )
        self.assertEqual(before, self.git(self.remote, "rev-parse", "main"))

    def test_adoption_requires_exact_revision_and_preserves_public_history(self):
        self.assertIn(
            "empty destination", self.run_script(adopt="0" * 40, success=False)
        )
        public = self.root / "public"
        self.git(self.root, "clone", str(self.remote), str(public))
        (public / "old.txt").write_text("existing public content\n")
        self.git(public, "add", ".")
        self.git(public, "commit", "-m", "Existing public history")
        self.git(public, "push", "origin", "main")
        before = self.git(self.remote, "rev-parse", "main")
        self.assertIn(
            "main changed", self.run_script(publish=True, adopt="0" * 40, success=False)
        )
        self.assertIn("Preview only", self.run_script(adopt=before))
        self.assertEqual(before, self.git(self.remote, "rev-parse", "main"))
        self.run_script(publish=True, adopt=before)
        self.assertEqual(before, self.git(self.remote, "rev-parse", "main^"))
        self.assertEqual(
            "existing public content", self.git(self.remote, "show", "main^:old.txt")
        )
        self.assertNotIn(
            "old.txt", self.git(self.remote, "ls-tree", "--name-only", "main")
        )
        self.assertEqual(
            "current version", self.git(self.remote, "show", "main:editor.lua")
        )
        self.assertIn("already up to date", self.run_script(publish=True))
        private_commit = self.git(self.source, "rev-parse", "HEAD")
        result = subprocess.run(
            ["git", "-C", str(self.remote), "cat-file", "-e", private_commit],
            env=self.env,
            capture_output=True,
        )
        self.assertNotEqual(0, result.returncode)

    def test_destination_without_main_is_not_treated_as_empty(self):
        self.git(self.source, "push", str(self.remote), "main:other")
        self.assertIn("no main branch", self.run_script(publish=True, success=False))
        self.assertEqual(
            "refs/heads/other",
            self.git(self.remote, "for-each-ref", "--format=%(refname)"),
        )

    def test_rejected_push_is_reported_without_changing_remote(self):
        self.run_script(publish=True)
        previous = self.git(self.remote, "rev-parse", "main")
        # Simulate a server-side policy rejecting publication.
        hook = self.remote / "hooks/pre-receive"
        hook.write_text("#!/bin/sh\necho publication-rejected >&2\nexit 1\n")
        hook.chmod(0o755)
        (self.editor / "editor.lua").write_text("next version\n")
        self.commit("next private update")
        self.assertIn(
            "publication-rejected", self.run_script(publish=True, success=False)
        )
        self.assertEqual(previous, self.git(self.remote, "rev-parse", "main"))


if __name__ == "__main__":
    unittest.main()
