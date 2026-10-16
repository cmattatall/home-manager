"""Check the built Linux home-path without falling back to host packages."""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path


HOME_PATH = os.environ.get("HM_TEST_HOME_PATH")


@unittest.skipUnless(HOME_PATH, "set HM_TEST_HOME_PATH to a built Linux home-path")
class PackageTest(unittest.TestCase):
    def run_tool(self, *args, input=None):
        with tempfile.TemporaryDirectory() as home:
            return subprocess.run(
                args,
                input=input,
                text=True,
                capture_output=True,
                timeout=60,
                env={"PATH": str(Path(HOME_PATH).resolve() / "bin"), "HOME": home},
            )

    def test_shell_dependencies_are_executable(self):
        commands = """
            amp bash zsh git gh gitleaks fzf bat python3 node jq aws psql
            grep sed awk find xargs sort uniq head tail wc cut tr date
            mkdir cp mv rm touch cat which dirname mktemp nproc
            curl ssh cmake make ninja clang llvm-config arm-none-eabi-gcc
            pre-commit screen vagrant cargo rustc vim nvim tmux
            lsusb ps
        """.split()
        for command in commands:
            with self.subTest(command=command):
                self.assertTrue(
                    os.access(Path(HOME_PATH) / "bin" / command, os.X_OK),
                    f"missing executable: {command}",
                )

    def test_amp_starts(self):
        result = self.run_tool("amp", "--version")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(result.stdout.strip())

    def test_gnu_grep_used_by_remote_blame(self):
        result = self.run_tool("grep", "-oP", r"#\K[0-9]+", input="change (#274)\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "274\n")

    def test_gnu_sed_used_by_pause_branch(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "paused"
            path.write_text("#old\nfeature\n")
            result = self.run_tool("sed", "-i", "1s|^#.*$|#new|", str(path))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(path.read_text(), "#new\nfeature\n")


if __name__ == "__main__":
    unittest.main()
