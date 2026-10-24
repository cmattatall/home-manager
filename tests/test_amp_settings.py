"""Check Home Manager's Amp plugins and settings using disposable configurations."""

import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parent.parent
SCRIPT = REPO / "scripts/configure-amp-keymap.py"
BINDINGS = {"thread.interrupt": ["ctrl+l", "esc esc"]}


@unittest.skipUnless(shutil.which("nix"), "Nix is required")
class AmpPluginsTest(unittest.TestCase):
    def test_profiles_install_both_plugins_with_or_without_editor(self):
        result = subprocess.run(
            ["nix", "--extra-experimental-features", "nix-command flakes",
             "eval", "--impure", "--json", "--expr", '''
                let
                  flake = builtins.getFlake ("path:" + toString ./.);
                  plugins = home: builtins.map (name:
                    let file = home.config.home.file.".config/amp/plugins/${name}.ts";
                    in {
                      inherit name;
                      inherit (file) enable force target;
                      contents = builtins.readFile file.source;
                    }
                  ) [ "readiff" "desloppify" ];
                in builtins.mapAttrs (_: home: {
                  default = plugins home;
                  withoutEditor = plugins (home.extendModules {
                    modules = [ { programs.rediff.enable = false; } ];
                  });
                }) flake.homeConfigurations
             '''],
            cwd=REPO, text=True, capture_output=True, check=False, timeout=180,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        profiles = json.loads(result.stdout)
        self.assertEqual(set(profiles), {"macbook", "macbook-intel", "development-node"})
        for profile, variants in profiles.items():
            for variant, plugins in variants.items():
                for plugin in plugins:
                    with self.subTest(profile=profile, variant=variant, plugin=plugin["name"]):
                        name = plugin["name"]
                        self.assertTrue(plugin["enable"])
                        self.assertTrue(plugin["force"])
                        self.assertEqual(plugin["target"], f".config/amp/plugins/{name}.ts")
                        source = REPO / f"modules/editor/rediff/plugins/amp/{name}.ts"
                        self.assertEqual(plugin["contents"], source.read_text())


class AmpSettingsTest(unittest.TestCase):
    def merge(self, path):
        return subprocess.run(
            [sys.executable, str(SCRIPT), str(path), json.dumps(BINDINGS)],
            text=True, capture_output=True, check=False,
        )

    def test_create_migrate_preserve_and_reapply(self):
        with tempfile.TemporaryDirectory() as home:
            path = Path(home) / ".config/amp/settings.json"
            self.assertEqual(0, self.merge(path).returncode)
            self.assertEqual({"amp.keymap": BINDINGS}, json.loads(path.read_text()))
            self.assertEqual(0o600, path.stat().st_mode & 0o777)
            settings = {
                "amp.gauge": "cost",
                "amp.keymap": {"thread.interrupt": "ctrl+l", "thread.copyURL": "ctrl+y"},
            }
            path.write_text(json.dumps(settings))
            self.assertEqual(0, self.merge(path).returncode)
            settings["amp.keymap"]["thread.interrupt"] = ["ctrl+l", "esc esc"]
            self.assertEqual(settings, json.loads(path.read_text()))
            before = path.stat().st_mtime_ns
            self.assertEqual(0, self.merge(path).returncode)
            self.assertEqual(before, path.stat().st_mtime_ns)

    def test_refuse_invalid_settings_and_symlinks_without_changing_them(self):
        with tempfile.TemporaryDirectory() as home:
            path = Path(home) / "settings.json"
            for contents in ("{broken", "[]", '{"amp.keymap": []}'):
                with self.subTest(contents=contents):
                    path.write_text(contents)
                    self.assertNotEqual(0, self.merge(path).returncode)
                    self.assertEqual(contents, path.read_text())
            path.unlink()
            target = Path(home) / "managed.json"
            target.write_text("{}")
            path.symlink_to(target)
            self.assertNotEqual(0, self.merge(path).returncode)
            self.assertTrue(path.is_symlink())
            self.assertEqual("{}", target.read_text())


if __name__ == "__main__":
    unittest.main()
