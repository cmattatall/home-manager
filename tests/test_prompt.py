"""Exercise Starship after commands in interactive Bash and Zsh."""

import os
import pty
import re
import select
import shlex
import shutil
import subprocess
import tempfile
import termios
import time
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path


SHELL_DIR = Path(__file__).resolve().parent.parent / "shell"
END = b"__PROMPT_END__"


@unittest.skipUnless(shutil.which("starship"), "starship not installed")
class PromptTest(unittest.TestCase):
    def test_username_colors(self):
        gold = "\x1b[38;5;220m"
        red = "\x1b[31m"
        host = os.uname().nodename.split(".")[0]
        usernames = (
            ("carl", "carl"),
            ("cmattatall", "cmatt"),
            ("root", f"{red}root{gold}"),
            ("rootish", "rooti"),
        )
        with tempfile.TemporaryDirectory() as home:
            for username, rendered in usernames:
                with self.subTest(username=username):
                    prompt = subprocess.run(
                        ["starship", "prompt"],
                        cwd=home,
                        env={
                            "HOME": home,
                            "USER": username,
                            "PATH": os.environ["PATH"],
                            "TERM": "xterm-256color",
                            "STARSHIP_SHELL": "sh",
                            "STARSHIP_CONFIG": str(SHELL_DIR / "starship.toml"),
                        },
                        text=True,
                        capture_output=True,
                        check=True,
                    )
                    self.assertEqual(prompt.stderr, "")
                    self.assertTrue(
                        prompt.stdout.startswith(f"{gold}[{rendered}@{host}]\x1b[0m "),
                        repr(prompt.stdout),
                    )

    def test_status_and_environment_transitions(self):
        for name in ("bash", "zsh"):
            shell = shutil.which(name)
            if not shell:
                continue
            with self.subTest(shell=name), tempfile.TemporaryDirectory() as home:
                home = str(Path(home).resolve())
                # A marker in the config survives Starship rebuilding PS1 each time.
                config = Path(home) / "prompt.toml"
                config.write_text(
                    (SHELL_DIR / "starship.toml")
                    .read_text()
                    .replace("$aws$character'", "$aws${character}__PROMPT_END__'")
                )
                master, slave = pty.openpty()
                attrs = termios.tcgetattr(slave)
                attrs[3] &= ~termios.ECHO
                termios.tcsetattr(slave, termios.TCSANOW, attrs)
                args = (
                    ["--noprofile", "--norc", "--noediting", "-i"]
                    if name == "bash"
                    else ["-d", "-f", "-i", "+Z"]
                )
                proc = subprocess.Popen(
                    [shell, *args],
                    stdin=slave,
                    stdout=slave,
                    stderr=slave,
                    cwd=home,
                    env={
                        "HOME": home,
                        "USER": "carl",
                        "PATH": os.environ["PATH"],
                        "TERM": "xterm-256color",
                        "LANG": "en_US.UTF-8",
                        "STARSHIP_CONFIG": str(config),
                        # Deliberately disagree with the running shell.
                        "SHELL": "/bin/zsh" if name == "bash" else "/bin/bash",
                    },
                )
                os.close(slave)

                def command(line):
                    os.write(master, (line + "\n").encode())
                    output = b""
                    deadline = time.monotonic() + 10
                    while END not in output:
                        remaining = deadline - time.monotonic()
                        if (
                            remaining <= 0
                            or not select.select([master], [], [], remaining)[0]
                        ):
                            self.fail(f"prompt did not appear: {output!r}")
                        output += os.read(master, 65536)
                    text = output.decode()
                    self.assertNotIn("[WARN]", text)
                    return (
                        re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", text)
                        .replace("\x01", "")
                        .replace("\x02", "")
                    )

                try:
                    source = f"source {shlex.quote(str(SHELL_DIR / 'ps1.sh'))}"
                    # Keep an existing hook, including the tmux agent hook, intact.
                    hook = (
                        "PROMPT_COMMAND='printf existing-hook\\\\n'"
                        if name == "bash"
                        else "precmd() { print -r -- existing-hook; }"
                    )
                    command(
                        f"{hook}; source {shlex.quote(str(SHELL_DIR / 'tmux.sh'))}; {source}"
                    )
                    failed = command("(exit 7)")
                    self.assertIn("[7]", failed)
                    host = os.uname().nodename.split(".")[0]
                    self.assertIn(f"[carl@{host}]", failed)
                    self.assertIn("~", failed)
                    self.assertNotIn("ssh:", failed)
                    self.assertNotIn("❄️", failed)
                    succeeded = command("true")
                    self.assertNotIn("[7]", succeeded)
                    self.assertNotIn("[0]", succeeded)

                    nix_only = command("export IN_NIX_SHELL=impure")
                    self.assertIn("❄️ $ ", nix_only)
                    command("export IN_NIX_SHELL=impure AWS_PROFILE=prod")
                    failed_in_nix = command("(exit 23)")
                    self.assertIn("[23]", failed_in_nix)
                    self.assertIn("❄️ (🚨 prod 🚨)", failed_in_nix)
                    pure = command("export IN_NIX_SHELL=pure")
                    self.assertIn("❄️ (🚨 prod 🚨)", pure)
                    left = command("unset IN_NIX_SHELL; export AWS_PROFILE=dev")
                    self.assertNotIn("❄️", left)
                    self.assertNotIn("[23]", left)
                    self.assertIn("(dev)", left)

                    expiration = datetime.now(timezone.utc) + timedelta(minutes=30)
                    expiring = command(
                        f"export AWS_SESSION_EXPIRATION={expiration.isoformat()}"
                    )
                    self.assertRegex(expiring, r"\(dev\) \[(30m0s|29m5\ds)\]")
                    expired = command(
                        "export AWS_SESSION_EXPIRATION=2000-01-01T00:00:00Z"
                    )
                    self.assertIn("(dev) [X]", expired)
                    unknown = command("unset AWS_SESSION_EXPIRATION")
                    self.assertIn("(dev) $ ", unknown)

                    self.assertNotIn("(dev)", command("unset AWS_PROFILE"))
                    self.assertNotIn("()", command("export AWS_PROFILE=''"))

                    command("export SSH_CONNECTION='192.0.2.1 1234 192.0.2.2 22' USER=cmattatall IN_NIX_SHELL=impure")
                    remote = command("(exit 19)")
                    self.assertEqual(remote.count("ssh:"), 1)
                    self.assertIn(f"ssh:[cmatt@{host}] ~ ❄️ $ ", remote)
                    self.assertNotIn("cmattatall", remote)
                    self.assertEqual(remote.count("[19]"), 1)
                    local = command(
                        "unset SSH_CONNECTION SSH_TTY IN_NIX_SHELL; export SSH_AUTH_SOCK=/tmp/agent.sock"
                    )
                    self.assertNotIn("ssh:", local)
                    self.assertIn(f"[cmatt@{host}]", local)

                    branch = command("git -c init.defaultBranch=prompt-test init -q")
                    self.assertIn("(prompt-test)", branch)
                    command(source)
                    reloaded = command("(exit 7)")
                    self.assertEqual(reloaded.count("[7]"), 1)
                    self.assertEqual(reloaded.count("existing-hook"), 1)
                    self.assertTrue(
                        reloaded.split("__PROMPT_END__")[0].rstrip().endswith("$")
                    )
                finally:
                    os.write(master, b"exit\n")
                    try:
                        proc.wait(timeout=5)
                    finally:
                        if proc.poll() is None:
                            proc.terminate()
                            proc.wait(timeout=5)
                        os.close(master)


if __name__ == "__main__":
    unittest.main()
