"""Exercise the settings merge used by Home Manager, never real user settings."""

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parent.parent / "scripts/configure-amp-keymap.py"
BINDINGS = {"thread.interrupt": ["ctrl+l", "esc esc"]}


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
