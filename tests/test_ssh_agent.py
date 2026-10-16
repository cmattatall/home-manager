"""Refresh existing interactive shells using private tmux sessions and sockets."""

import os
import pty
import select
import shlex
import shutil
import socket
import subprocess
import tempfile
import termios
import time
import unittest
from pathlib import Path


SHELL_DIR = Path(__file__).resolve().parent.parent / "shell"
TMUX = shutil.which("tmux")
END = b"__AGENT_PROMPT_END__"


@unittest.skipUnless(TMUX and shutil.which("starship"), "tmux and starship are required")
class SSHAgentTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="agent-test-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        config = self.root / "starship.toml"
        config.write_text(
            (SHELL_DIR / "starship.toml").read_text().replace(
                "$aws$character'", "$aws${character}__AGENT_PROMPT_END__'"
            )
        )
        self.env = {
            "HOME": str(self.root),
            "PATH": os.environ["PATH"],
            "TERM": "xterm-256color",
            "LANG": "C.UTF-8",
            "STARSHIP_CONFIG": str(config),
        }
        self.sock = str(self.root / "tmux.sock")
        self.addCleanup(self.stop_tmux)
        self.pane = self.tmux("new-session", "-d", "-s", "target", "-P", "-F", "#{pane_id}", "/bin/sh")
        self.server_pid = self.tmux("display-message", "-p", "-t", self.pane, "#{pid}")
        # Neither the newest session nor the global environment is the target.
        self.tmux("new-session", "-d", "-s", "decoy", "/bin/sh")
        self.old = self.make_socket("old agent.sock")
        self.new = self.make_socket("new agent.sock")
        self.decoy = self.make_socket("decoy.sock")
        self.tmux("set-environment", "-g", "SSH_AUTH_SOCK", self.decoy)
        self.tmux("set-environment", "-t", "decoy", "SSH_AUTH_SOCK", self.decoy)
        self.tmux("set-environment", "-t", self.pane, "SSH_AUTH_SOCK", self.old)

    def tmux(self, *args):
        return subprocess.run(
            [TMUX, "-S", self.sock, "-f", "/dev/null", *args],
            env=self.env, capture_output=True, text=True, check=True, timeout=5,
        ).stdout.strip()

    def stop_tmux(self):
        subprocess.run(
            [TMUX, "-S", self.sock, "kill-server"],
            env=self.env, capture_output=True, timeout=5,
        )

    def make_socket(self, name):
        sock = socket.socket(socket.AF_UNIX)
        self.addCleanup(sock.close)
        path = str(self.root / name)
        sock.bind(path)
        return path

    def start_shell(self, name, hooks):
        shell = shutil.which(name)
        if not shell:
            self.skipTest(f"{name} is not installed")
        master, slave = pty.openpty()
        attrs = termios.tcgetattr(slave)
        attrs[3] &= ~termios.ECHO
        termios.tcsetattr(slave, termios.TCSANOW, attrs)
        args = ["--noprofile", "--norc", "--noediting", "-i"] if name == "bash" else ["-d", "-f", "-i", "+Z"]
        proc = subprocess.Popen(
            [shell, *args], stdin=slave, stdout=slave, stderr=slave,
            cwd=self.root,
            env={**self.env, "TMUX": f"{self.sock},{self.server_pid},0", "TMUX_PANE": self.pane,
                 "SSH_AUTH_SOCK": self.decoy, "SSH_TTY": "/dev/pts/test"},
        )
        os.close(slave)

        def cleanup():
            if proc.poll() is None:
                os.write(master, b"exit\n")
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.terminate()
                    proc.wait(timeout=5)
            os.close(master)

        self.addCleanup(cleanup)
        self.master = master
        source = f"source {shlex.quote(str(SHELL_DIR / 'tmux.sh'))}"
        startup = self.root / f"startup-{name}.sh"
        startup.write_text(
            # NixOS /etc/zshenv resets PATH even with zsh -f.
            f"export PATH={shlex.quote(self.env['PATH'])}; "
            # Each existing hook records its incoming status and passes it on.
            "first() { local code=$?; printf 'FIRST=%s\\n' \"$code\"; return \"$code\"; }; "
            "last() { local code=$?; printf 'LAST=%s\\n' \"$code\"; return \"$code\"; }; "
            + hooks + "; " + source + "; "
            + ("add-zsh-hook precmd last; " if name == "zsh" else "")
            + source + "; "
            + f"source {shlex.quote(str(SHELL_DIR / 'ps1.sh'))}"
        )
        self.command(f"source {shlex.quote(str(startup))}")
        return source

    def command(self, command):
        os.write(self.master, (command + "\n").encode())
        result = b""
        deadline = time.monotonic() + 10
        while END not in result:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([self.master], [], [], remaining)[0]:
                self.fail(f"No prompt: {result!r}")
            result += os.read(self.master, 65536)
        return result.replace(b"\x01", b"").replace(b"\x02", b"")

    def agent(self):
        # A child process proves the replacement was exported, not merely assigned.
        output = self.command("/bin/sh -c 'printf \"AGENT=%s\\n\" \"$SSH_AUTH_SOCK\"'")
        return next(line[6:].decode() for line in output.splitlines() if line.startswith(b"AGENT="))

    def exercise(self, name, hooks):
        source = self.start_shell(name, hooks)
        self.assertEqual(self.old, self.agent())
        self.tmux("set-environment", "-t", self.pane, "SSH_AUTH_SOCK", self.new)
        output = self.command("(exit 19)")
        self.assertIn(b"\x1b[31m[19]", output, "Recovery must preserve the failed-command prompt")
        self.assertEqual(self.new, self.agent())
        self.assertEqual(output.count(b"FIRST="), 1)
        self.assertEqual(output.count(b"LAST="), 1, "A nonzero recovery hook must not skip later hooks")
        if name == "zsh":
            # Without a primary precmd function, recovery receives the failure
            # directly. It must not stop Zsh from running subsequent hooks.
            self.command("unfunction precmd 2>/dev/null; add-zsh-hook -d precmd first")
            output = self.command("(exit 27)")
            self.assertIn(b"\x1b[31m[27]", output)
            self.assertIn(b"LAST=27", output, "Zsh restores the original status for each hook")

        ordinary = self.root / "not a socket"
        ordinary.touch()
        for invalid in ("", str(ordinary), str(self.root), str(self.root / "expired.sock"), "$(touch injected)"):
            self.tmux("set-environment", "-t", self.pane, "SSH_AUTH_SOCK", invalid)
            self.command("true")
            self.assertEqual(self.new, self.agent())
        self.assertFalse((self.root / "injected").exists(), "Never evaluate tmux's output as shell code")
        for flag in ("-u", "-r"):
            self.tmux("set-environment", flag, "-t", self.pane, "SSH_AUTH_SOCK")
            self.command("true")
            self.assertEqual(self.new, self.agent(), "Do not fall back to the global socket")
        self.tmux("set-environment", "-t", self.pane, "SSH_AUTH_SOCK", self.old)
        self.command("export TMUX_PANE=%999999")
        self.assertEqual(self.new, self.agent())
        self.command("unset TMUX_PANE")
        self.assertEqual(self.new, self.agent())
        self.command(f"export TMUX_PANE={shlex.quote(self.pane)}; unset TMUX")
        self.assertEqual(self.new, self.agent())
        self.command(source)
        self.assertEqual(self.new, self.agent())
        succeeded = self.command("true")
        self.assertNotIn(b"[19]", succeeded)

    def test_bash_scalar_hooks(self):
        self.exercise("bash", "PROMPT_COMMAND='first;last'")

    def test_bash_array_hooks(self):
        self.exercise("bash", "PROMPT_COMMAND=(first last)")

    def test_zsh_hooks(self):
        # Register a hook both before and after recovery, then source again.
        self.exercise("zsh", "precmd_functions=(first)")

    @unittest.skipUnless(shutil.which("direnv"), "direnv is not installed")
    def test_direnv_hooks_still_load_environment_and_preserve_status(self):
        (self.root / ".envrc").write_text("export AGENT_TEST_DIRENV=loaded\n")
        for name, hooks in (("bash", "PROMPT_COMMAND=(first last)"), ("zsh", "precmd_functions=(first)")):
            with self.subTest(shell=name):
                self.tmux("set-environment", "-t", self.pane, "SSH_AUTH_SOCK", self.old)
                source = self.start_shell(name, hooks)
                self.command(f'eval "$(direnv hook {name})"; direnv allow; {source}; {source}')
                self.tmux("set-environment", "-t", self.pane, "SSH_AUTH_SOCK", self.new)
                output = self.command('(exit 23)')
                self.assertIn(b"\x1b[31m[23]", output)
                self.assertEqual(output.count(b"FIRST="), 1)
                self.assertEqual(output.count(b"LAST="), 1)
                self.assertIn(b"DIRENV=loaded", self.command('printf "DIRENV=%s\\n" "$AGENT_TEST_DIRENV"'))
                self.assertEqual(self.new, self.agent())
                if name == "bash":
                    output = self.command('printf "HOOKS=%s\\n" "${PROMPT_COMMAND[*]}"')
                else:
                    output = self.command('print -r -- "HOOKS=$precmd_functions"')
                self.assertEqual(output.count(b"_tmux_refresh_ssh_agent"), 1)
                self.assertEqual(output.count(b"_direnv_hook"), 1)


if __name__ == "__main__":
    unittest.main()
