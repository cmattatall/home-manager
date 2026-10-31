"""Exercise the command with disposable credentials and Nix configuration."""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("auth.py")


@unittest.skipUnless(shutil.which("nix"), "Nix is required to check effective settings")
class AuthenticationTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.home = Path(self.temporary.name)
        self.config_home = self.home / "config with spaces"
        self.directory = self.config_home / "nix"
        self.directory.mkdir(parents=True)
        self.configuration = self.directory / "nix.conf"
        self.credentials = self.directory / "github-access-token.conf"
        self.bin = self.home / "bin"
        self.bin.mkdir()
        gh = self.bin / "gh"
        gh.write_text(
            f"#!{sys.executable}\n"
            "import os, sys\n"
            "print(os.environ['TEST_TOKEN'])\n"
            "sys.exit(int(os.environ.get('TEST_GH_EXIT', '0')))\n"
        )
        gh.chmod(0o755)
        self.environment = {
            **os.environ,
            "HOME": str(self.home),
            "XDG_CONFIG_HOME": str(self.config_home),
            "PATH": f"{self.bin}{os.pathsep}{os.environ.get('PATH', '')}",
            "TEST_TOKEN": "test_first_credential",
            "NIX_CONF_DIR": str(self.home / "system"),
            "NIX_USER_CONF_FILES": str(self.configuration),
            "NIX_CONFIG": "",
        }

    def run_auth(self, **environment):
        result = subprocess.run(
            [sys.executable, str(SCRIPT)],
            env={**self.environment, **environment},
            capture_output=True,
            text=True,
        )
        self.assertNotIn(
            environment.get("TEST_TOKEN", self.environment["TEST_TOKEN"]),
            result.stdout + result.stderr,
        )
        return result

    def test_preserve_settings_and_rotate_private_credential(self):
        original = (
            "# Existing settings\n"
            "substituters = https://cache.example.test\n"
            "access-tokens = gitlab.com=other"
        )
        self.configuration.write_text(original)
        result = self.run_auth()
        self.assertEqual(result.returncode, 0, result.stderr)
        expected = f"{original}\n!include github-access-token.conf\n"
        self.assertEqual(self.configuration.read_text(), expected)
        self.assertEqual(
            self.credentials.read_text(),
            "extra-access-tokens = github.com=test_first_credential\n",
        )
        self.assertEqual(self.credentials.stat().st_mode & 0o777, 0o600)
        self.credentials.chmod(0o644)
        result = self.run_auth(TEST_TOKEN="test_rotated_credential")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.configuration.read_text(), expected)
        self.assertEqual(
            self.credentials.read_text(),
            "extra-access-tokens = github.com=test_rotated_credential\n",
        )
        self.assertEqual(self.credentials.stat().st_mode & 0o777, 0o600)

    def test_failed_authentication_leaves_existing_files_unchanged(self):
        self.configuration.write_text("max-jobs = 3\n")
        self.credentials.write_text("existing credential\n")
        for environment in (
            {"TEST_GH_EXIT": "1"},
            {"TEST_TOKEN": "invalid\ninjection"},
        ):
            with self.subTest(environment=environment):
                self.assertNotEqual(self.run_auth(**environment).returncode, 0)
                self.assertEqual(self.configuration.read_text(), "max-jobs = 3\n")
                self.assertEqual(self.credentials.read_text(), "existing credential\n")

    def test_managed_config_requires_include_and_credential_symlinks_are_refused(self):
        managed = self.home / "managed.conf"
        managed.write_text("max-jobs = 3\n")
        self.configuration.symlink_to(managed)
        self.assertNotEqual(self.run_auth().returncode, 0)
        self.assertTrue(self.configuration.is_symlink())
        self.assertEqual(managed.read_text(), "max-jobs = 3\n")
        self.assertFalse(self.credentials.exists())
        managed.write_text("max-jobs = 3\n!include github-access-token.conf\n")
        result = self.run_auth()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.configuration.is_symlink())
        self.credentials.unlink()
        self.credentials.symlink_to(managed)
        self.assertNotEqual(self.run_auth().returncode, 0)
        self.assertEqual(
            managed.read_text(), "max-jobs = 3\n!include github-access-token.conf\n"
        )

    def test_nix_reads_new_user_config_and_preserves_system_authentication(self):
        self.directory.rmdir()
        system = self.home / "system"
        system.mkdir()
        (system / "nix.conf").write_text(
            "experimental-features = nix-command\n"
            "access-tokens = gitlab.com=system_credential\n"
        )
        for user_config in (None, "access-tokens = gitlab.com=user_credential\n"):
            with self.subTest(user_config=user_config):
                if user_config is not None:
                    self.configuration.write_text(user_config)
                result = self.run_auth()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.directory.stat().st_mode & 0o777, 0o700)
                result = subprocess.run(
                    ["nix", "config", "show", "--json"],
                    env=self.environment,
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                tokens = json.loads(result.stdout)["access-tokens"]["value"]
                expected_gitlab = (
                    "user_credential" if user_config else "system_credential"
                )
                self.assertEqual(
                    tokens,
                    {
                        "gitlab.com": expected_gitlab,
                        "github.com": "test_first_credential",
                    },
                )

    def test_reports_when_existing_authentication_takes_precedence(self):
        self.configuration.write_text(
            "access-tokens = github.com=existing_credential\n"
        )
        result = self.run_auth()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Nix is using different authentication", result.stderr)
        self.assertNotIn("existing_credential", result.stdout + result.stderr)

        self.configuration.unlink()
        result = self.run_auth(
            NIX_CONFIG="access-tokens = github.com=environment_credential"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Nix is using different authentication", result.stderr)
        self.assertNotIn("environment_credential", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
