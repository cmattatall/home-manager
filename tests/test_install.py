"""Tests for the installer scripts; every external command is mocked."""

import os
import shutil
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
INSTALL_NIX = REPO / "scripts" / "install-nix.sh"
INSTALL_HM = REPO / "scripts" / "install-home-manager.sh"

BASH = shutil.which("bash")
REAL_TOOLS = (
    "bash sh env cat mkdir mktemp rm ln chmod dirname basename pwd readlink "
    "grep sed tr cut head tail touch printf test cp ls"
).split()

MOCKS = {
    "id": """
        case "$1" in
          -u) echo "${MOCK_UID:-1000}" ;;
          -un) echo "$MOCK_USER" ;;
          *) exit 2 ;;
        esac
    """,
    "uname": """
        case "$1" in
          -s) echo "$MOCK_OS" ;;
          -m) echo "$MOCK_ARCH" ;;
          *) exit 2 ;;
        esac
    """,
    "sysctl": """
        log sysctl "$@"
        [ -n "${MOCK_ARM64:-}" ] || exit 1
        echo "$MOCK_ARM64"
    """,
    "systemctl": """
        log systemctl "$@"
        [ -z "${MOCK_SYSTEMCTL_FAIL:-}" ] || exit 1
        echo "$MOCK_LOADSTATE"
    """,
    "curl": """
        log curl "$@"
        [ -z "${MOCK_CURL_FAIL:-}" ] || exit 22
        out=
        while [ $# -gt 0 ]; do
          case "$1" in -o) out=$2; shift ;; esac
          shift
        done
        cat >"$out" <<'EOF'
        (IFS=$(printf '\\037'); echo "installer$IFS$*") >>"$MOCK_LOG"
        mkdir -p "$HM_INSTALL_SYSROOT/nix/var/nix/profiles/default/bin"
        cp "$MOCK_DIR/nix-impl" "$HM_INSTALL_SYSROOT/nix/var/nix/profiles/default/bin/nix"
        echo "installer stdout noise"
        EOF
    """,
}

NIX_IMPL = """
    case "$1" in
      --version)
        [ -z "${MOCK_NIX_BROKEN:-}" ] || exit 1
        echo "nix (Nix) 2.28.5"
        exit 0 ;;
    esac
    log nix "$0"
    printf '%s\\0' "$@" >"$MOCK_DIR/nix-build.args"
    {
      echo "HM_FLAKE_DIR=$HM_FLAKE_DIR"
      echo "HM_PROFILE=$HM_PROFILE"
      echo "HM_USERNAME=$HM_USERNAME"
      echo "HM_HOME=$HM_HOME"
    } >"$MOCK_DIR/nix-build.env"
    [ -z "${MOCK_BUILD_FAIL:-}" ] || exit 1
    out=
    while [ $# -gt 0 ]; do
      case "$1" in --out-link) out=$2; shift ;; esac
      shift
    done
    ln -s "$MOCK_DIR/store/$MOCK_GENERATION" "$out"
"""

ACTIVATE = """
    log activate "$HOME" "${PATH%%:*}"
    exit "${MOCK_ACTIVATE_RC:-0}"
"""


class Sandbox:
    def __init__(self, root: Path):
        self.root = root
        self.mock = root / "mock"
        self.bin = root / "bin"
        self.sysroot = root / "sysroot"
        self.home = root / "Users dir" / "carl smith"
        self.tmp = root / "tmp"
        for d in (self.mock / "store", self.bin, self.sysroot, self.home, self.tmp):
            d.mkdir(parents=True)
        self.log = self.mock / "log"
        self.log.touch()
        for tool in REAL_TOOLS:
            path = shutil.which(tool)
            if path:
                (self.bin / tool).symlink_to(path)
        for name, body in MOCKS.items():
            self._script(self.bin / name, body)
        self.nix_impl = self.mock / "nix-impl"
        self._script(self.nix_impl, NIX_IMPL)
        for gen in ("gen-a", "gen-b"):
            (self.mock / "store" / gen).mkdir()
            self._script(self.mock / "store" / gen / "activate", ACTIVATE)
        self.env = {
            "PATH": str(self.bin),
            "HOME": str(self.home),
            "TMPDIR": str(self.tmp),
            "HM_INSTALL_SYSROOT": str(self.sysroot),
            "MOCK_DIR": str(self.mock),
            "MOCK_LOG": str(self.log),
            "MOCK_USER": "carl",
            "MOCK_OS": "Linux",
            "MOCK_ARCH": "x86_64",
            "MOCK_LOADSTATE": "not-found",
            "MOCK_GENERATION": "gen-a",
        }

    def _script(self, path: Path, body: str):
        prelude = (
            f"#!{BASH}\n"
            'log() { (IFS=$(printf "\\037"); echo "$*") >>"$MOCK_LOG"; }\n'
        )
        path.write_text(prelude + textwrap.dedent(body).lstrip("\n"))
        path.chmod(0o755)

    def put_nix(self, where: Path) -> Path:
        where.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(self.nix_impl, where)
        return where

    def nix_on_path(self) -> Path:
        return self.put_nix(self.bin / "nix")

    def nix_off_path(self) -> Path:
        return self.put_nix(self.sysroot / "nix/var/nix/profiles/default/bin/nix")

    def nixos(self):
        (self.sysroot / "etc").mkdir(exist_ok=True)
        (self.sysroot / "etc" / "NIXOS").touch()

    def set_active(self, gen: str, legacy: bool = False):
        if legacy:
            profiles = self.sysroot / "nix/var/nix/profiles/per-user/carl"
        else:
            profiles = self.home / ".local/state/nix/profiles"
        profiles.mkdir(parents=True)
        (profiles / "home-manager-1-link").symlink_to(self.mock / "store" / gen)
        (profiles / "home-manager").symlink_to("home-manager-1-link")

    def run(self, script: Path, *args: str, **env: str):
        return subprocess.run(
            [str(script), *args],
            env={**self.env, **env},
            capture_output=True,
            text=True,
            timeout=30,
        )

    def calls(self, name: str):
        lines = self.log.read_text().splitlines()
        return [ln.split("\x1f")[1:] for ln in lines if ln.split("\x1f")[0] == name]

    def build_args(self):
        return (self.mock / "nix-build.args").read_text().split("\0")[:-1]

    def build_env(self):
        lines = (self.mock / "nix-build.env").read_text().splitlines()
        return dict(ln.split("=", 1) for ln in lines)


class SandboxTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.sb = Sandbox(Path(self._tmp.name))

    def tearDown(self):
        self._tmp.cleanup()

    def assertOk(self, result):
        self.assertEqual(result.returncode, 0, result.stderr)

    def assertFailed(self, result, needle: str):
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertIn(needle, result.stderr.lower())


class InstallNixTest(SandboxTest):
    def test_executable(self):
        self.assertTrue(os.access(INSTALL_NIX, os.X_OK))

    def test_refuses_root(self):
        self.sb.nix_on_path()
        r = self.sb.run(INSTALL_NIX, MOCK_UID="0")
        self.assertFailed(r, "root")
        self.assertEqual(r.stdout, "")

    def test_reuses_nix_on_path(self):
        nix = self.sb.nix_on_path()
        r = self.sb.run(INSTALL_NIX)
        self.assertOk(r)
        self.assertEqual(r.stdout.strip(), str(nix))
        self.assertEqual(self.sb.calls("curl"), [])

    def test_reuses_nix_on_path_on_nixos(self):
        self.sb.nixos()
        nix = self.sb.nix_on_path()
        r = self.sb.run(INSTALL_NIX)
        self.assertOk(r)
        self.assertEqual(r.stdout.strip(), str(nix))

    def test_discovers_off_path_default_profile(self):
        nix = self.sb.nix_off_path()
        r = self.sb.run(INSTALL_NIX, MOCK_OS="Darwin", MOCK_ARCH="arm64")
        self.assertOk(r)
        self.assertEqual(r.stdout.strip(), str(nix))
        self.assertEqual(self.sb.calls("curl"), [])

    def test_discovers_off_path_user_profile(self):
        nix = self.sb.put_nix(self.sb.home / ".nix-profile/bin/nix")
        r = self.sb.run(INSTALL_NIX)
        self.assertOk(r)
        self.assertEqual(r.stdout.strip(), str(nix))

    def test_discovers_xdg_state_profile(self):
        state = self.sb.home / "custom state"
        nix = self.sb.put_nix(state / "nix/profiles/profile/bin/nix")
        r = self.sb.run(INSTALL_NIX, XDG_STATE_HOME=str(state))
        self.assertOk(r)
        self.assertEqual(r.stdout.strip(), str(nix))

    def test_refuses_broken_nix_on_path(self):
        self.sb.nix_on_path()
        r = self.sb.run(INSTALL_NIX, MOCK_OS="Darwin", MOCK_NIX_BROKEN="1")
        self.assertFailed(r, "broken")
        self.assertEqual(self.sb.calls("curl"), [])

    def test_refuses_broken_off_path_nix(self):
        self.sb.nix_off_path()
        r = self.sb.run(INSTALL_NIX, MOCK_OS="Darwin", MOCK_NIX_BROKEN="1")
        self.assertFailed(r, "broken")
        self.assertEqual(self.sb.calls("curl"), [])

    def test_refuses_store_without_nix(self):
        (self.sb.sysroot / "nix" / "store").mkdir(parents=True)
        r = self.sb.run(INSTALL_NIX, MOCK_OS="Darwin")
        self.assertFailed(r, "broken")
        self.assertEqual(self.sb.calls("curl"), [])

    def test_refuses_install_on_nixos(self):
        self.sb.nixos()
        r = self.sb.run(INSTALL_NIX)
        self.assertFailed(r, "nixos")
        self.assertEqual(self.sb.calls("curl"), [])

    def test_refuses_install_on_other_linux(self):
        r = self.sb.run(INSTALL_NIX)
        self.assertFailed(r, "macos")
        self.assertEqual(self.sb.calls("curl"), [])

    def test_bootstraps_macos_with_official_daemon_installer(self):
        r = self.sb.run(INSTALL_NIX, MOCK_OS="Darwin", MOCK_ARCH="arm64")
        self.assertOk(r)
        (curl,) = self.sb.calls("curl")
        self.assertIn("https://nixos.org/nix/install", curl)
        self.assertEqual(self.sb.calls("installer"), [["--daemon"]])
        installed = self.sb.sysroot / "nix/var/nix/profiles/default/bin/nix"
        self.assertEqual(r.stdout.strip(), str(installed))
        self.assertEqual(list(self.sb.tmp.iterdir()), [])

    def test_bootstrap_download_failure_propagates(self):
        r = self.sb.run(INSTALL_NIX, MOCK_OS="Darwin", MOCK_CURL_FAIL="1")
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.sb.calls("installer"), [])
        self.assertEqual(r.stdout, "")


class InstallHomeManagerTest(SandboxTest):
    def test_executable(self):
        self.assertTrue(os.access(INSTALL_HM, os.X_OK))

    def test_refuses_root(self):
        self.sb.nix_on_path()
        r = self.sb.run(INSTALL_HM, MOCK_UID="0")
        self.assertFailed(r, "root")
        self.assertFalse((self.sb.mock / "nix-build.args").exists())

    def test_skips_fleet_managed_nixos_node(self):
        self.sb.nixos()
        self.sb.nix_on_path()
        r = self.sb.run(INSTALL_HM, MOCK_LOADSTATE="loaded")
        self.assertOk(r)
        self.assertIn("home-manager-carl.service", r.stdout + r.stderr)
        self.assertIn("managed", (r.stdout + r.stderr).lower())
        (call,) = self.sb.calls("systemctl")
        self.assertIn("home-manager-carl.service", call)
        self.assertEqual(self.sb.calls("nix"), [])
        self.assertEqual(self.sb.calls("activate"), [])

    def test_fleet_detection_failure_fails_closed(self):
        self.sb.nixos()
        self.sb.nix_on_path()
        r = self.sb.run(INSTALL_HM, MOCK_SYSTEMCTL_FAIL="1")
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.sb.calls("nix"), [])
        self.assertEqual(self.sb.calls("activate"), [])

    def test_unmanaged_nixos_node_builds_and_activates(self):
        self.sb.nixos()
        nix = self.sb.nix_on_path()
        r = self.sb.run(INSTALL_HM)
        self.assertOk(r)
        env = self.sb.build_env()
        self.assertEqual(env["HM_PROFILE"], "development-node")
        self.assertEqual(env["HM_USERNAME"], "carl")
        self.assertEqual(env["HM_HOME"], str(self.sb.home))
        self.assertEqual(env["HM_FLAKE_DIR"], str(REPO))
        args = self.sb.build_args()
        self.assertEqual(args[0], "--extra-experimental-features")
        self.assertIn("nix-command", args[1])
        self.assertIn("flakes", args[1])
        self.assertIn("build", args)
        self.assertIn("--impure", args)
        expr = args[args.index("--expr") + 1]
        for needle in ("builtins.getFlake", "extendModules", "mkForce",
                       "home.username", "home.homeDirectory", "activationPackage"):
            self.assertIn(needle, expr)
        self.assertEqual(
            self.sb.calls("activate"), [[str(self.sb.home), str(nix.parent)]]
        )
        self.assertEqual(list(self.sb.tmp.iterdir()), [])

    def test_macos_arm64_with_off_path_nix(self):
        nix = self.sb.nix_off_path()
        r = self.sb.run(INSTALL_HM, MOCK_OS="Darwin", MOCK_ARCH="arm64")
        self.assertOk(r)
        self.assertEqual(self.sb.build_env()["HM_PROFILE"], "macbook")
        self.assertEqual(self.sb.calls("nix"), [[str(nix)]])
        self.assertEqual(self.sb.calls("systemctl"), [])
        self.assertEqual(
            self.sb.calls("activate"), [[str(self.sb.home), str(nix.parent)]]
        )

    def test_macos_intel(self):
        self.sb.nix_on_path()
        r = self.sb.run(INSTALL_HM, MOCK_OS="Darwin", MOCK_ARCH="x86_64",
                        MOCK_ARM64="0")
        self.assertOk(r)
        self.assertEqual(self.sb.build_env()["HM_PROFILE"], "macbook-intel")

    def test_macos_rosetta_shell_selects_arm64_profile(self):
        self.sb.nix_on_path()
        r = self.sb.run(INSTALL_HM, MOCK_OS="Darwin", MOCK_ARCH="x86_64",
                        MOCK_ARM64="1")
        self.assertOk(r)
        self.assertEqual(self.sb.build_env()["HM_PROFILE"], "macbook")

    def test_macos_bootstraps_nix_then_activates(self):
        r = self.sb.run(INSTALL_HM, MOCK_OS="Darwin", MOCK_ARCH="arm64")
        self.assertOk(r)
        self.assertEqual(self.sb.calls("installer"), [["--daemon"]])
        self.assertEqual(len(self.sb.calls("activate")), 1)

    def test_unsupported_platform(self):
        self.sb.nix_on_path()
        r = self.sb.run(INSTALL_HM, MOCK_ARCH="aarch64")
        self.assertFailed(r, "unsupported")
        self.assertEqual(self.sb.calls("nix"), [])

    def test_repeated_install_is_noop(self):
        self.sb.nix_on_path()
        self.sb.set_active("gen-a")
        r = self.sb.run(INSTALL_HM)
        self.assertOk(r)
        self.assertIn("already active", (r.stdout + r.stderr).lower())
        self.assertEqual(self.sb.calls("activate"), [])
        self.assertEqual(list(self.sb.tmp.iterdir()), [])

    def test_repeated_install_is_noop_with_legacy_profile(self):
        self.sb.nix_on_path()
        self.sb.set_active("gen-a", legacy=True)
        r = self.sb.run(INSTALL_HM)
        self.assertOk(r)
        self.assertEqual(self.sb.calls("activate"), [])

    def test_modern_profile_takes_precedence_over_stale_legacy_profile(self):
        self.sb.nix_on_path()
        self.sb.set_active("gen-b")
        self.sb.set_active("gen-a", legacy=True)
        r = self.sb.run(INSTALL_HM)
        self.assertOk(r)
        self.assertEqual(len(self.sb.calls("activate")), 1)

    def test_changed_generation_activates(self):
        self.sb.nix_on_path()
        self.sb.set_active("gen-a")
        r = self.sb.run(INSTALL_HM, MOCK_GENERATION="gen-b")
        self.assertOk(r)
        self.assertEqual(len(self.sb.calls("activate")), 1)

    def test_build_failure_propagates(self):
        self.sb.nix_on_path()
        r = self.sb.run(INSTALL_HM, MOCK_BUILD_FAIL="1")
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.sb.calls("activate"), [])
        self.assertEqual(list(self.sb.tmp.iterdir()), [])

    def test_activation_failure_propagates(self):
        self.sb.nix_on_path()
        r = self.sb.run(INSTALL_HM, MOCK_ACTIVATE_RC="3")
        self.assertEqual(r.returncode, 3, r.stderr)

    def test_install_nix_failure_propagates(self):
        self.sb.nix_on_path()
        r = self.sb.run(INSTALL_HM, MOCK_NIX_BROKEN="1")
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.sb.calls("nix"), [])
        self.assertEqual(self.sb.calls("activate"), [])


@unittest.skipUnless(BASH, "bash is not installed")
class SetupHomeManagerTest(unittest.TestCase):
    def test_configuration_link_and_existing_files_are_preserved(self):
        for custom_xdg in (False, True):
            for existing in (None, "file", "dangling-link"):
                with self.subTest(xdg=custom_xdg, existing=existing), tempfile.TemporaryDirectory() as directory:
                    home = Path(directory)
                    env = {**os.environ, "HOME": str(home)}
                    env.pop("XDG_CONFIG_HOME", None)
                    config_root = home / ".config"
                    if custom_xdg:
                        config_root = home / "custom config"
                        env["XDG_CONFIG_HOME"] = str(config_root)
                    config = config_root / "home-manager/home.nix"
                    config.parent.mkdir(parents=True)
                    if existing == "file":
                        config.write_text("existing config\n")
                    elif existing == "dangling-link":
                        config.symlink_to(home / "missing.nix")

                    def run():
                        return subprocess.run(
                            [BASH, str(REPO / "scripts/install-nix-home.sh")],
                            env=env, capture_output=True, text=True, timeout=10,
                        )

                    result = run()
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertTrue((home / "home.nix").is_file())
                    generated = (home / "home.nix").read_text()
                    self.assertIn(
                        '"git+https://github.com/cmattatall/home-manager.git"', generated,
                    )
                    self.assertIn(
                        'repository_url="https://github.com/cmattatall/home-manager.git"',
                        generated,
                    )
                    self.assertRegex(generated, r'\?rev=[0-9a-f]{40}"')
                    if existing == "file":
                        self.assertEqual(config.read_text(), "existing config\n")
                    elif existing == "dangling-link":
                        self.assertEqual(config.readlink(), home / "missing.nix")
                    else:
                        self.assertEqual(config.resolve(), (home / "home.nix").resolve())

                    (home / "home.nix").write_text("personal edits\n")
                    result = run()
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual((home / "home.nix").read_text(), "personal edits\n")


if __name__ == "__main__":
    unittest.main()
