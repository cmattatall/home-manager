"""Source index.sh in clean Bash and Zsh subprocesses and check the result.

Run with: python3 -m unittest discover -s tests -v
"""

import json
import os
import shutil
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

REPO_DIR = Path(__file__).resolve().parent.parent / "shell"
BASH = shutil.which("bash")
ZSH = shutil.which("zsh")
GIT = shutil.which("git")
TIMEOUT_S = 20

# Runs in both shells after sourcing; "typeset -f" and "alias" are portable.
PROBE = textwrap.dedent(
    """
    for f in gs mkcd prettypath alias_expand copy nxd; do
        if typeset -f "$f" >/dev/null 2>&1; then
            echo "FUNC_OK $f"
        else
            echo "FUNC_MISSING $f"
        fi
    done
    for a in gco nxdv cb dealias reload-shell; do
        if alias "$a" >/dev/null 2>&1; then
            echo "ALIAS_OK $a"
        else
            echo "ALIAS_MISSING $a"
        fi
    done
    if typeset -f systemctl >/dev/null 2>&1; then
        echo "SYSTEMCTL_FUNCTION"
    fi
    echo "SYSTEMCTL_OUT $(systemctl is-active sshd 2>&1)"
    echo "FZF_SHELL=$FZF_SHELL"
    case ":$PATH:" in
        *":$HOME/.local/bin:"*) echo "LOCAL_BIN_OK" ;;
    esac
    """
)


def _write_stub(directory: Path, name: str, body: str) -> None:
    path = directory / name
    path.write_text("#!/bin/sh\n" + body + "\n")
    path.chmod(0o755)


class StartupTestBase(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory(prefix="shellrc test ")
        tmp = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)

        # Spaces in both the install and working directories exercise quoting.
        self.install_dir = tmp / "shell rc.d"
        shutil.copytree(
            REPO_DIR,
            self.install_dir,
            ignore=shutil.ignore_patterns(".git", "tests", "__pycache__"),
        )
        self.home = tmp / "home"
        self.home.mkdir()
        (self.home / ".local/bin").mkdir(parents=True)
        self.ordinary_dir = tmp / "ordinary dir"
        self.ordinary_dir.mkdir()
        if GIT:
            subprocess.run(
                [GIT, "-c", "init.defaultBranch=feature-x", "init", "-q"],
                cwd=self.ordinary_dir,
                check=True,
            )

        # Optional tools are stubbed so their absence does not add startup noise;
        # the systemctl stub stands in for the real Linux binary.
        self.stub_dir = tmp / "stubs"
        self.stub_dir.mkdir()
        _write_stub(self.stub_dir, "fzf", 'printf "FZF_SHELL=%s\\n" "$1"')
        _write_stub(self.stub_dir, "systemctl", 'echo "REAL_SYSTEMCTL $*"')
        _write_stub(
            self.stub_dir, "realpath", 'echo "realpath is unavailable" >&2; exit 127'
        )
        _write_stub(self.stub_dir, "nix", 'echo "Nix is unavailable" >&2; exit 127')

        self.darwin_stub_dir = tmp / "darwin stubs"
        self.darwin_stub_dir.mkdir()
        _write_stub(self.darwin_stub_dir, "uname", "echo Darwin")
        _write_stub(self.darwin_stub_dir, "brew", "echo /nonexistent/llvm")

    def run_shell(
        self,
        shell: str,
        cwd: Path,
        login_shell: str,
        probe: str,
        darwin: bool = False,
    ) -> subprocess.CompletedProcess:
        path = [str(self.stub_dir), os.environ.get("PATH", "")]
        if darwin:
            path.insert(0, str(self.darwin_stub_dir))
        env = {
            "PATH": os.pathsep.join(path),
            "HOME": str(self.home),
            "SHELL": login_shell,
            "AWS_PROFILE": "dev",
            "TERM": "dumb",
            "LANG": "C.UTF-8",
            "SHELLRC_DIR": str(self.install_dir),
            "TEST_PATH": os.pathsep.join(path),
        }
        # NixOS /etc/zshenv runs even under "zsh -f" and resets PATH.
        script = 'PATH="$TEST_PATH"\nsource "$SHELLRC_DIR/index.sh"\n' + probe
        if os.path.basename(shell) == "zsh":
            argv = [shell, "-f", "-c", script]
        else:
            argv = [shell, "--norc", "--noprofile", "-c", script]
        try:
            return subprocess.run(
                argv,
                cwd=cwd,
                env=env,
                capture_output=True,
                text=True,
                timeout=TIMEOUT_S,
            )
        except subprocess.TimeoutExpired:
            self.fail(f"{shell} startup hung in {cwd} (recursive sourcing?)")

    def assert_clean_startup(self, result: subprocess.CompletedProcess) -> list:
        self.assertEqual(result.returncode, 0, msg=result.stderr)
        self.assertEqual(result.stderr, "", msg="unexpected startup stderr")
        lines = result.stdout.splitlines()
        missing = [line for line in lines if "_MISSING" in line]
        self.assertEqual(missing, [], msg=result.stdout)
        self.assertIn("FUNC_OK gs", lines)
        self.assertIn("ALIAS_OK gco", lines)
        self.assertIn("LOCAL_BIN_OK", lines)
        return lines

    def assert_linux_systemctl_not_shadowed(self, lines: list) -> None:
        self.assertNotIn("SYSTEMCTL_FUNCTION", lines)
        self.assertIn("SYSTEMCTL_OUT REAL_SYSTEMCTL is-active sshd", lines)


@unittest.skipUnless(BASH, "bash not installed")
class BashStartupTest(StartupTestBase):
    def check(self, cwd: Path, login_shell: str) -> None:
        result = self.run_shell(BASH, cwd, login_shell, PROBE)
        lines = self.assert_clean_startup(result)
        self.assert_linux_systemctl_not_shadowed(lines)

        self.assertIn("FZF_SHELL=--bash", lines)

    def test_from_ordinary_directory(self) -> None:
        self.check(self.ordinary_dir, BASH)

    def test_from_shell_repo_directory(self) -> None:
        self.check(self.install_dir, BASH)

    def test_detects_bash_when_login_shell_is_zsh(self) -> None:
        self.check(self.ordinary_dir, ZSH or "/bin/zsh")

    def test_darwin_systemctl_hint(self) -> None:
        result = self.run_shell(BASH, self.ordinary_dir, BASH, PROBE, darwin=True)
        lines = self.assert_clean_startup(result)
        self.assertIn("SYSTEMCTL_FUNCTION", lines)
        self.assertIn("launchctl", result.stdout)

    def test_managed_llvm_does_not_call_brew(self) -> None:
        _write_stub(self.stub_dir, "llvm-config", "echo /managed/llvm")
        _write_stub(self.darwin_stub_dir, "brew", "echo unexpected-brew >&2; exit 1")
        result = self.run_shell(BASH, self.ordinary_dir, BASH, PROBE, darwin=True)
        self.assert_clean_startup(result)

    def test_llvm_source_preserves_errexit_without_homebrew(self) -> None:
        (self.darwin_stub_dir / "brew").unlink()
        result = subprocess.run(
            [
                BASH,
                "--norc",
                "--noprofile",
                "-c",
                'set -e; source "$1"; case $- in *e*) ;; *) exit 7;; esac',
                "bash",
                str(self.install_dir / "llvm.sh"),
            ],
            capture_output=True,
            text=True,
            env={"PATH": str(self.darwin_stub_dir)},
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout + result.stderr, "")

    def test_running_helper_is_executable(self) -> None:
        self.assertTrue(os.access(self.install_dir / "bin/running", os.X_OK))


@unittest.skipUnless(ZSH, "zsh not installed")
class ZshStartupTest(StartupTestBase):
    def check(self, cwd: Path, login_shell: str) -> None:
        result = self.run_shell(ZSH, cwd, login_shell, PROBE)
        lines = self.assert_clean_startup(result)
        self.assert_linux_systemctl_not_shadowed(lines)

        self.assertIn("FZF_SHELL=--zsh", lines)

    def test_from_ordinary_directory(self) -> None:
        self.check(self.ordinary_dir, ZSH)

    def test_from_shell_repo_directory(self) -> None:
        self.check(self.install_dir, ZSH)

    def test_detects_zsh_when_login_shell_is_bash(self) -> None:
        self.check(self.ordinary_dir, BASH or "/bin/bash")

    def test_darwin_systemctl_hint(self) -> None:
        result = self.run_shell(ZSH, self.ordinary_dir, ZSH, PROBE, darwin=True)
        lines = self.assert_clean_startup(result)
        self.assertIn("SYSTEMCTL_FUNCTION", lines)
        self.assertIn("launchctl", result.stdout)


@unittest.skipUnless(GIT, "git not installed")
class GitWorktreeAddTest(StartupTestBase):
    def test_copies_only_ignored_envrc_files_below_current_directory(self) -> None:
        root = self.ordinary_dir
        ignored = {
            ".envrc": 'touch "$HOME/should-not-run"\n',
            "ignored tree/line\nbreak/.envrc": "export NESTED=1\n",
            "service/.envrc": "export SERVICE=1\n",
            "service/nested dir/.envrc": "export CHILD=2\n",
        }
        files = {
            **ignored,
            "public/.envrc": "export NOT_IGNORED=1\n",
            "tracked/.envrc": "export TRACKED=original\n",
            "nix/config/user-aliases": "local aliases\n",
            "tmp/pain.sh": "local pain\n",
            "tmp/spells.sh": "local spells\n",
        }
        for relative, text in files.items():
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        (root / ".gitignore").write_text(
            "/.envrc\n/ignored tree/\n/service/**/.envrc\n/tracked/.envrc\n"
        )
        subprocess.run([GIT, "add", "-f", ".gitignore", "tracked/.envrc"], cwd=root, check=True)
        subprocess.run(
            [GIT, "-c", "user.name=Test", "-c", "user.email=test@example.com",
             "-c", "commit.gpgsign=false", "commit", "-qm", "Initial"],
            cwd=root, check=True,
        )
        (root / "tracked/.envrc").write_text("export TRACKED=modified\n")
        for shell in filter(None, [BASH, ZSH]):
            for directory in (".", "service", "public"):
                with self.subTest(shell=shell, directory=directory):
                    cwd = root / directory
                    destination = self.home / (Path(shell).name + "-" + ("root" if directory == "." else directory))
                    relative_destination = os.path.relpath(destination, cwd)
                    result = self.run_shell(
                        shell, cwd, shell, f'git_worktree_add "{relative_destination}"\n'
                    )
                    self.assertEqual(result.returncode, 0, result.stderr)
                    for relative, text in ignored.items():
                        copied = destination / relative
                        if directory == "." or relative.startswith(directory + "/"):
                            self.assertEqual(copied.read_text(), text)
                        else:
                            self.assertFalse(copied.exists(), relative)
                    self.assertFalse((destination / "public/.envrc").exists())
                    self.assertEqual((destination / "tracked/.envrc").read_text(), files["tracked/.envrc"])
                    if directory == ".":
                        for relative in ("nix/config/user-aliases", "tmp/pain.sh", "tmp/spells.sh"):
                            self.assertEqual((destination / relative).read_text(), files[relative])
                    self.assertFalse((self.home / "should-not-run").exists())


class HomeManagerAliasTest(StartupTestBase):
    def test_hm_pull_updates_only_the_pin_and_preserves_failed_switch_for_retry(self) -> None:
        old, new = "a" * 40, "b" * 40
        original = f'let\n  unrelated = "{old}";\n  source = "git+https://example.test"\n    + "?rev={old}"\n; in {{}}\n'
        _write_stub(self.stub_dir, "git", f'printf "{new}\\trefs/heads/main\\n"')
        _write_stub(self.stub_dir, "home-manager", 'printf "<%s>\\n" "$@"; exit 7')
        config = self.home / "home.nix"
        for shell in filter(None, [BASH, ZSH]):
            with self.subTest(shell=shell):
                config.write_text(original)
                result = self.run_shell(shell, self.ordinary_dir, shell, "hm_pull\n")
                self.assertEqual(result.returncode, 7, result.stderr)
                self.assertEqual(config.read_text(), original.replace(f"?rev={old}", f"?rev={new}"))
                self.assertEqual(result.stdout.splitlines(), [
                    "<switch>", "<-b>", "<backup>", "<-f>", f"<{config}>",
                ])

    def test_hm_pull_rejects_invalid_revisions_and_ambiguous_pins(self) -> None:
        _write_stub(self.stub_dir, "home-manager", 'echo unexpected-activation; exit 0')
        config = self.home / "home.nix"
        pin = '  + "?rev=' + "a" * 40 + '"\n'
        for shell in filter(None, [BASH, ZSH]):
            for revision, original in (("bad-revision", pin), ("b" * 40, pin * 2)):
                with self.subTest(shell=shell, revision=revision, original=original):
                    config.write_text(original)
                    _write_stub(self.stub_dir, "git", f'printf "{revision}\\trefs/heads/main\\n"')
                    result = self.run_shell(shell, self.ordinary_dir, shell, "hm_pull\n")
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("hm_pull:", result.stderr)
                    self.assertEqual(result.stdout, "")
                    self.assertEqual(config.read_text(), original)

    def test_hm_forwards_arguments_and_exit_status(self) -> None:
        _write_stub(self.stub_dir, "home-manager", 'printf "<%s>\\n" "$@"; exit 7')
        for shell in filter(None, [BASH, ZSH]):
            with self.subTest(shell=shell):
                result = self.run_shell(
                    shell, self.ordinary_dir, shell,
                    'if [ -n "${BASH_VERSION:-}" ]; then shopt -s expand_aliases; fi\n'
                    'eval \'hm switch -f "config with spaces.nix"\'\n',
                )
                self.assertEqual(result.returncode, 7, result.stderr)
                self.assertEqual(result.stdout.splitlines(), [
                    "<switch>", "<-f>", "<config with spaces.nix>",
                ])


class ReloadShellTest(StartupTestBase):
    def test_reload_replaces_shell_and_refreshes_session_variables(self) -> None:
        _write_stub(
            self.home,
            "replacement shell",
            'test "$$" = "$RELOAD_PID" || exit 11\n'
            'test "${__HM_SESS_VARS_SOURCED+x}" != x || exit 12\n'
            'printf "RELOADED %s %s %s\\n" "$#" "$1" "$RELOAD_VALUE"',
        )
        for shell in filter(None, [BASH, ZSH]):
            with self.subTest(shell=shell):
                result = self.run_shell(
                    shell,
                    self.ordinary_dir,
                    "/nonexistent/login-shell",
                    'if [ -n "${BASH_VERSION:-}" ]; then shopt -s expand_aliases; fi\n'
                    'export __HM_SESS_VARS_SOURCED=1 RELOAD_PID=$$ RELOAD_VALUE=retained\n'
                    'SHELL="$HOME/replacement shell"\n'
                    'eval reload-shell\n'
                    'echo NOT_REPLACED\n',
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("RELOADED 1 -l retained", result.stdout.splitlines())
                self.assertNotIn("NOT_REPLACED", result.stdout)


class PsqlHelpersTest(StartupTestBase):
    def test_local_helpers_use_external_authentication(self) -> None:
        _write_stub(
            self.stub_dir,
            "psql",
            'printf "%s\\n" "${PGPASSWORD-<unset>}" "$@"; exit 7',
        )
        for shell in filter(None, [BASH, ZSH]):
            for password in [None, "externally-supplied-test-value"]:
                for command, args in [
                    ("psql_local", ["resources"]),
                    ('psql_local "db with spaces"', ["db with spaces"]),
                    ('psql_local_exec "select 1;"', ["resources", "-c", "select 1;"]),
                ]:
                    with self.subTest(shell=shell, password=password, command=command):
                        auth = (
                            "unset PGPASSWORD\n" if password is None
                            else f"export PGPASSWORD={password}\n"
                        )
                        result = self.run_shell(
                            shell, self.ordinary_dir, shell, auth + command,
                        )
                        self.assertEqual(result.returncode, 7, result.stderr)
                        self.assertEqual(result.stderr, "")
                        self.assertEqual(
                            result.stdout.splitlines(),
                            [
                                password or "<unset>", "-h", "localhost", "-p", "5432",
                                "-U", "postgres", "-d", *args,
                            ],
                        )


@unittest.skipUnless(BASH and shutil.which("nix-instantiate"), "bash and Nix required")
class SshBannerTest(unittest.TestCase):
    def test_warns_for_other_users_or_source_ips(self) -> None:
        evaluated = subprocess.run(
            [
                "nix-instantiate", "--eval", "--strict", "--json", "--expr",
                "(import ./development-node.nix { lib = {}; pkgs = {}; "
                "nixpkgs-unstable = {}; }).programs.bash.initExtra",
            ],
            cwd=REPO_DIR.parent, capture_output=True, text=True,
            check=True, timeout=TIMEOUT_S,
        )
        init = json.loads(evaluated.stdout)
        current_user = subprocess.check_output(["id", "-un"], text=True).strip()
        for current_ip, other_ip in [
            ("192.0.2.10", "192.0.2.11"),
            ("2001:db8::1", "2001:db8::10"),
        ]:
            for different_source, different_user in [(False, False), (True, False), (False, True), (True, True)]:
                for login, ssh in [(True, True), (False, True), (True, False)]:
                    with self.subTest(
                        ip=current_ip, different=different_source,
                        different_user=different_user, login=login, ssh=ssh,
                    ):
                        peer_user = current_user + "_other" if different_user else current_user
                        peer_ip = other_ip if different_source else current_ip
                        sessions = (
                            "NAME LINE TIME IDLE PID COMMENT\n"
                            f"{current_user} pts/0 Oct 15 00:01 100 ({current_ip})\n"
                            f"{current_user} pts/1 Oct 15 10:56 101 ({current_ip})\n"
                            "localuser tty1 Oct 15 old 102\n"
                            f"{peer_user} pts/2 Oct 15 00:42 103 ({peer_ip})\n"
                        )
                        env = {
                            **os.environ,
                            "SSH_CONNECTION": f"{current_ip} 54321 10.0.0.1 22" if ssh else "",
                            "SSH_TTY": "/dev/pts/0",
                            "TEST_SESSIONS": sessions,
                        }
                        env.pop("BASH_ENV", None)
                        result = subprocess.run(
                            [BASH, "--noprofile", "--norc", *(["--login"] if login else []),
                             "-c", 'who() { printf "%s" "$TEST_SESSIONS"; };\n' + init],
                            env=env, capture_output=True, text=True, timeout=TIMEOUT_S,
                        )
                        self.assertEqual(result.returncode, 0, result.stderr)
                        self.assertEqual(result.stderr, "")
                        if (different_source or different_user) and login and ssh:
                            self.assertIn("WARNING: SHARED LAB STATION", result.stdout)
                            rows = [line.split() for line in result.stdout.splitlines() if line.endswith(f"({peer_ip})")]
                            self.assertEqual(rows, [[peer_user, "Oct", "15", "00:42", f"({peer_ip})"]])
                            for excluded in ["00:01", "10:56", "localuser"]:
                                self.assertNotIn(excluded, result.stdout)
                        else:
                            self.assertEqual(result.stdout, "")


class NixHelpersTest(unittest.TestCase):
    def test_nxd_preserves_shell_or_explicit_command(self) -> None:
        for shell in filter(None, [BASH, ZSH]):
            shell_name = Path(shell).name
            for args in [
                [],
                ["--print-build-logs", "path:/flake with spaces"],
                ["path:/flake -c with spaces"],
                ["--command", "echo", "two words"],
                ["-c", "echo", "two words"],
            ]:
                with self.subTest(shell=shell, args=args):
                    result = subprocess.run(
                        [
                            shell,
                            "-c",
                            'alias nxd="nix develop"; source "$1"; shift; '
                            'nix() { printf "%s\\n" "$@"; return 7; }; nxd "$@"',
                            "test",
                            str(REPO_DIR / "nix.sh"),
                            *args,
                        ],
                        capture_output=True,
                        text=True,
                    )
                    self.assertEqual(result.returncode, 7, result.stderr)
                    expected = ["develop", *args]
                    if shell_name == "zsh" and not any(
                        arg in ("--command", "-c") for arg in args
                    ):
                        expected += ["--command", shell_name, "-i"]
                    self.assertEqual(result.stdout.splitlines(), expected)

    def test_nd_selects_repo_flake_or_default(self) -> None:
        with tempfile.TemporaryDirectory(prefix="nix helper ") as directory:
            root = Path(directory).resolve()
            (root / "nix").mkdir()
            for has_flake in [False, True]:
                if has_flake:
                    (root / "nix/flake.nix").touch()
                for shell in filter(None, [BASH, ZSH]):
                    for args in [
                        [],
                        ["--print-build-logs"],
                        ["--command", "echo", "two words"],
                        ["-c", "echo", "two words"],
                    ]:
                        with self.subTest(shell=shell, has_flake=has_flake, args=args):
                            result = subprocess.run(
                                [
                                    shell,
                                    "-c",
                                    'source "$1"; shift; git() { printf "%s\\n" "$PWD"; }; '
                                    'nix() { printf "%s\\n" "$@"; return 7; }; nd "$@"',
                                    "test",
                                    str(REPO_DIR / "nix.sh"),
                                    *args,
                                ],
                                cwd=root,
                                capture_output=True,
                                text=True,
                            )
                            self.assertEqual(result.returncode, 7, result.stderr)
                            zsh = Path(shell).name == "zsh"
                            explicit = any(arg in ("--command", "-c") for arg in args)
                            expected = ["develop"]
                            if has_flake:
                                suffix = "#zsh" if zsh and not explicit else ""
                                expected.append(f"path:{root}/nix{suffix}")
                            expected += args
                            if zsh and not has_flake and not explicit:
                                expected += ["--command", "zsh", "-i"]
                            self.assertEqual(result.stdout.splitlines(), expected)


if __name__ == "__main__":
    unittest.main()
