"""PTY integration tests for the generated tmux config, driven with raw Kitty bytes.

Run: TMUX_TEST_CONFIG=/path/to/tmux.conf [TMUX_TEST_BIN=/path/to/tmux] \
     python3 -m unittest -v tests/test_tmux.py
"""

import base64
import fcntl
import os
import pty
import shutil
import signal
import struct
import subprocess
import tempfile
import termios
import threading
import time
import unittest

CONFIG = os.environ.get("TMUX_TEST_CONFIG")
TMUX = os.environ.get("TMUX_TEST_BIN") or shutil.which("tmux")
COLS, ROWS = 100, 40
TIMEOUT = 5.0
SET_VAR = b"\x1b]1337;SetUserVar=in_tmux=MQ==\x07"
UNSET_VAR = b"\x1b]1337;SetUserVar=in_tmux\x07"
CTRL_SHIFT_ENTER = b"\x1b[13;6u"
CTRL_ALT_SHIFT_ENTER = b"\x1b[13;8u"
CTRL_SHIFT_ARROW = {"Up": b"\x1b[1;6A", "Down": b"\x1b[1;6B", "Right": b"\x1b[1;6C", "Left": b"\x1b[1;6D"}
PANE_FORMAT = "#{pane_id} #{pane_left} #{pane_top} #{pane_width} #{pane_height} #{pane_active} #{pane_current_path}"


def poll(fetch, ok, timeout=TIMEOUT):
    """Return the last fetched value once ok(value) holds or the timeout expires."""
    deadline = time.monotonic() + timeout
    while True:
        value = fetch()
        if ok(value) or time.monotonic() > deadline:
            return value
        time.sleep(0.05)


def proc_state(pid):
    try:
        with open(f"/proc/{pid}/stat") as f:
            return f.read().rsplit(")", 1)[1].split()[0]
    except (FileNotFoundError, ProcessLookupError):
        return None


class Client:
    """A tmux client attached to a real controlling PTY, with its output captured."""

    def __init__(self, pid, fd):
        self.pid, self.fd, self.status = pid, fd, None
        self.tmux_pid = None
        self._out, self._lock = bytearray(), threading.Lock()
        self._reader = threading.Thread(target=self._read, daemon=True)
        self._reader.start()

    def _read(self):
        while True:
            try:
                data = os.read(self.fd, 65536)
            except OSError:
                return
            if not data:
                return
            with self._lock:
                self._out += data

    def mark(self):
        with self._lock:
            return len(self._out)

    def output(self, start=0):
        with self._lock:
            return bytes(self._out[start:])

    def send(self, data):
        os.write(self.fd, data)

    def exited(self):
        if self.status is None:
            pid, status = os.waitpid(self.pid, os.WNOHANG)
            if pid:
                self.status = os.waitstatus_to_exitcode(status)
        return self.status is not None


@unittest.skipUnless(TMUX, "tmux binary not found; set TMUX_TEST_BIN")
@unittest.skipUnless(CONFIG, "set TMUX_TEST_CONFIG to the generated tmux.conf path")
class TmuxPtyTest(unittest.TestCase):
    def setUp(self):
        if not os.path.isfile(CONFIG):
            self.fail(f"TMUX_TEST_CONFIG={CONFIG!r} is not a readable file")
        self.tmp = os.path.realpath(tempfile.mkdtemp(prefix="tmux-test-"))
        self.work = os.path.join(self.tmp, "work")
        self.sub = os.path.join(self.work, "sub")
        os.makedirs(self.sub)
        self.sock = os.path.join(self.tmp, "sock")
        self.env = {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "HOME": self.tmp,
            "TMUX_TMPDIR": self.tmp,
            "TERM": "xterm-256color",
            "SHELL": "/bin/sh",
            "PS1": "$ ",
            "LANG": "C.UTF-8",
        }
        for key in ("TERMINFO", "TERMINFO_DIRS", "LOCALE_ARCHIVE"):
            if key in os.environ:
                self.env[key] = os.environ[key]
        self.clients, self.server_pid = [], None
        self.addCleanup(self._cleanup)
        self.tmux("new-session", "-d", "-s", "t", "-x", str(COLS), "-y", str(ROWS), "-c", self.work, "/bin/sh")
        self.server_pid = int(self.tmux("display-message", "-p", "#{pid}"))
        self.tmux("set-option", "-g", "default-shell", "/bin/sh")
        self.tmux("set-option", "-g", "default-command", "/bin/sh")

    def _owned(self, pid):
        try:
            with open(f"/proc/{pid}/cmdline", "rb") as f:
                return self.sock.encode() in f.read()
        except OSError:
            return False

    def _cleanup(self):
        subprocess.run([TMUX, "-S", self.sock, "kill-server"], env=self.env, capture_output=True, timeout=TIMEOUT)
        for client in self.clients:
            for pid in (client.tmux_pid, self.server_pid):
                if pid and self._owned(pid):
                    os.kill(pid, signal.SIGKILL)
            if not client.exited():
                os.kill(client.pid, signal.SIGKILL)
                os.waitpid(client.pid, 0)
            os.close(client.fd)
        if self.server_pid and self._owned(self.server_pid):
            os.kill(self.server_pid, signal.SIGKILL)
        shutil.rmtree(self.tmp, ignore_errors=True)

    def tmux(self, *args, check=True):
        result = subprocess.run(
            [TMUX, "-S", self.sock, "-f", CONFIG, *args],
            env=self.env, capture_output=True, text=True, timeout=TIMEOUT,
        )
        if check and result.returncode:
            self.fail(f"tmux {' '.join(args)} failed: {result.stderr.strip()}")
        return result.stdout.strip()

    def client_info(self):
        out = self.tmux("list-clients", "-F", "#{client_pid} #{client_tty}", check=False)
        return [line.split() for line in out.splitlines()]

    def attach(self):
        """Attach like a job-control shell would: tmux in its own foreground process group."""
        pid, fd = pty.fork()
        if pid == 0:
            try:
                fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
                job = os.fork()
                if job == 0:
                    os.setpgid(0, 0)
                    signal.signal(signal.SIGTTOU, signal.SIG_IGN)
                    os.tcsetpgrp(0, os.getpid())
                    signal.signal(signal.SIGTTOU, signal.SIG_DFL)
                    os.execve(TMUX, [TMUX, "-S", self.sock, "attach-session", "-t", "t"], self.env)
                _, status = os.waitpid(job, 0)
                os._exit(os.waitstatus_to_exitcode(status) & 0xFF)
            except BaseException:
                os._exit(127)
        client = Client(pid, fd)
        self.clients.append(client)
        info = poll(self.client_info, lambda c: len(c) == 1)
        self.assertEqual(len(info), 1, f"client never attached; output={client.output()[-300:]!r}")
        client.tmux_pid, client.tty = int(info[0][0]), info[0][1]
        return client

    def expect_output(self, client, start, seq, event):
        out = poll(lambda: client.output(start), lambda o: seq in o)
        self.assertTrue(seq in out, f"{event}: outer PTY never received {seq!r}; got tail {out[-400:]!r}")

    def panes(self):
        rows = self.tmux("list-panes", "-t", "t", "-F", PANE_FORMAT).splitlines()
        keys = ("id", "left", "top", "width", "height", "active", "path")
        return [
            {k: (int(v) if k in ("left", "top", "width", "height", "active") else v)
             for k, v in zip(keys, row.split(" ", 6))}
            for row in rows
        ]

    def active_pane(self):
        return self.tmux("display-message", "-p", "-t", "t", "#{pane_id}")

    @unittest.skipUnless(shutil.which("nvim"), "nvim is needed to check terminal key decoding")
    def test_modified_keys_reach_neovim(self):
        client = self.attach()
        nvim = shutil.which("nvim")
        socket = os.path.join(self.tmp, "nvim.sock")
        self.tmux(
            "respawn-pane", "-k", "-t", "t", nvim, "-u", "NONE", "-i", "NONE",
            "--listen", socket, "-c",
            'lua for key,value in pairs({["<C-S-[>"]="previous",["<C-S-]>"]="next",'
            '["<D-w>"]="command",["<M-w>"]="alt",'
            '["<Esc>"]="escape"}) do vim.keymap.set("n",key,function() vim.g.received=value end) end',
        )
        self.assertTrue(poll(lambda: os.path.exists(socket), bool))

        def received():
            return subprocess.check_output(
                [nvim, "--server", socket, "--remote-expr", "get(g:, 'received', '')"],
                env=self.env, text=True, timeout=TIMEOUT,
            ).strip()

        for sequence, expected in (
            (b"\x1b[91;6u", "previous"),
            (b"\x1b[93;6u", "next"),
            (b"\x1b[119;9:1u", "command"),
            (b"\x1bw", "alt"),
            (b"\x1b", "escape"),
        ):
            with self.subTest(expected=expected):
                client.send(sequence)
                self.assertEqual(expected, poll(received, lambda value: value == expected))

    def test_mouse_drag_copies_only_target_pane_to_outer_clipboard(self):
        self.check_mouse_selection()

    def test_vi_mouse_drag_copies_only_target_pane_to_outer_clipboard(self):
        self.tmux("set-window-option", "-t", "t", "mode-keys", "vi")
        # Vi includes the character under the cursor; emacs excludes it.
        self.check_mouse_selection(end_column=8)

    def check_mouse_selection(self, end_column=9):
        client = self.attach()
        left = self.active_pane()
        right = self.tmux("split-window", "-h", "-P", "-F", "#{pane_id}", "/bin/sh")
        for pane, text in ((left, "LEFT ONE\\nLEFT TWO"), (right, "DO NOT COPY")):
            self.tmux(
                "send-keys", "-t", pane,
                rf"printf '\033[2J\033[H{text}\n'", "Enter",
            )
        self.assertTrue(poll(
            lambda: self.tmux("capture-pane", "-p", "-t", left),
            lambda text: text.startswith("LEFT ONE\nLEFT TWO\n"),
        ).startswith("LEFT ONE\nLEFT TWO\n"))
        mark = client.mark()
        # Kitty SGR mouse: left press at (1,1), drag to the end of row 2, release.
        client.send(b"\x1b[<0;1;1M\x1b[<32;2;1M")
        self.assertEqual("1", poll(
            lambda: self.tmux("display-message", "-p", "-t", left, "#{pane_in_mode}"),
            lambda mode: mode == "1",
        ))
        client.send(f"\x1b[<32;{end_column};2M\x1b[<0;{end_column};2m".encode())
        expected = "LEFT ONE\nLEFT TWO"
        copied = poll(lambda: self.tmux("show-buffer", check=False), lambda text: text == expected)
        self.assertEqual(expected, copied)
        self.assertEqual(left, self.active_pane(), "Dragging selects the pane under the mouse")
        # OSC 52 reaches the local terminal; no pbcopy/xclip on the remote host.
        self.expect_output(
            client, mark, b"\x1b]52;;" + base64.b64encode(expected.encode()) + b"\x07", "clipboard",
        )
        self.assertEqual("1 1", self.tmux(
            "display-message", "-p", "-t", left, "#{pane_in_mode} #{selection_present}",
        ), "Releasing the mouse must keep the selection highlighted")
        client.send(b"q")
        self.assertEqual("0", poll(
            lambda: self.tmux("display-message", "-p", "-t", left, "#{pane_in_mode}"),
            lambda mode: mode == "0",
        ), "q returns to the live shell")

    def test_diff_rgb_colors_reach_outer_terminal(self):
        client = self.attach()
        # These low-saturation rediff backgrounds otherwise map to greys in 256 colors.
        for color in ("35;75;44", "96;42;42", "53;107;62", "138;57;57"):
            with self.subTest(color=color):
                mark = client.mark()
                self.tmux(
                    "send-keys", "-t", "t",
                    rf"printf '\033[48;2;{color}mDIFF COLOR\033[0m\n'", "Enter",
                )
                self.expect_output(client, mark, f"\x1b[48;2;{color}m".encode(), "RGB background")
        features = self.tmux("list-clients", "-F", "#{client_termfeatures}")
        self.assertIn("RGB", features.split(","))

    def test_osc8_links_reach_outer_terminal(self):
        client = self.attach()
        features = self.tmux("list-clients", "-F", "#{client_termfeatures}")
        self.assertIn("hyperlinks", features.split(","))
        mark = client.mark()
        self.tmux(
            "send-keys", "-t", "t",
            r"printf '\033]8;;https://example.com/review\033\\Review link\033]8;;\033\\\n'",
            "Enter",
        )
        # Check the OSC 8 target, not a visible URL that terminals can auto-detect.
        self.expect_output(client, mark, b";https://example.com/review\x1b\\", "hyperlink")
        self.assertIn(b"\x1b]8;", client.output(mark))
        self.assertIn(b"Review link", client.output(mark))
        mark = client.mark()
        self.tmux("refresh-client", "-t", client.tty)
        self.expect_output(client, mark, b";https://example.com/review\x1b\\", "redrawn hyperlink")

    def test_ctrl_shift_enter_splits_side_by_side_in_current_path(self):
        client = self.attach()
        self.tmux("send-keys", "-t", "t", "cd sub", "Enter")
        moved = poll(self.panes, lambda p: p[0]["path"] == self.sub)
        self.assertEqual(moved[0]["path"], self.sub, "setup: pane never changed directory")
        client.send(CTRL_SHIFT_ENTER)
        panes = poll(self.panes, lambda p: len(p) == 2)
        self.assertEqual(len(panes), 2, f"ESC[13;6u did not split the window: {panes}")
        left, right = sorted(panes, key=lambda p: p["left"])
        self.assertEqual((left["top"], left["height"]), (right["top"], right["height"]), f"not side-by-side: {panes}")
        self.assertEqual(left["width"] + 1 + right["width"], COLS, f"split does not span the {COLS}-col tty: {panes}")
        self.assertEqual(right["active"], 1, "new pane should be focused")
        new = poll(self.panes, lambda p: max(p, key=lambda x: x["left"])["path"] == self.sub)
        self.assertEqual(max(new, key=lambda p: p["left"])["path"], self.sub, "new pane ignored pane_current_path")

    def test_ctrl_alt_shift_enter_splits_top_bottom(self):
        client = self.attach()
        client.send(CTRL_ALT_SHIFT_ENTER)
        panes = poll(self.panes, lambda p: len(p) == 2)
        self.assertEqual(len(panes), 2, f"ESC[13;8u did not split the window: {panes}")
        top, bottom = sorted(panes, key=lambda p: p["top"])
        self.assertEqual((top["left"], top["width"]), (bottom["left"], bottom["width"]), f"not top/bottom: {panes}")
        self.assertEqual(top["width"], COLS, f"split does not span the {COLS}-col tty: {panes}")
        self.assertGreater(bottom["top"], top["top"] + top["height"] - 1, f"panes overlap: {panes}")
        self.assertEqual(bottom["active"], 1, "new pane should be focused")

    def test_ctrl_shift_arrows_select_panes(self):
        client = self.attach()
        tl = self.active_pane()
        tr = self.tmux("split-window", "-h", "-t", tl, "-P", "-F", "#{pane_id}")
        bl = self.tmux("split-window", "-v", "-t", tl, "-P", "-F", "#{pane_id}")
        br = self.tmux("split-window", "-v", "-t", tr, "-P", "-F", "#{pane_id}")
        for start, direction, expected in ((tl, "Right", tr), (tl, "Down", bl), (br, "Left", bl), (br, "Up", tr)):
            with self.subTest(direction=direction):
                self.tmux("select-pane", "-t", start)
                self.assertEqual(self.active_pane(), start)
                client.send(CTRL_SHIFT_ARROW[direction])
                active = poll(self.active_pane, lambda a: a == expected, timeout=2.0)
                self.assertEqual(active, expected, f"{CTRL_SHIFT_ARROW[direction]!r} from {start} should select {direction}")

    def test_attach_detach_reattach_toggle_user_var(self):
        client = self.attach()
        self.expect_output(client, 0, SET_VAR, "attach")
        mark = client.mark()
        self.tmux("detach-client", "-t", client.tty)
        self.assertTrue(poll(client.exited, bool), "client did not exit on detach")
        client._reader.join(TIMEOUT)
        self.assertTrue(UNSET_VAR in client.output(mark), f"detach: no unset sequence; tail {client.output(mark)[-400:]!r}")
        again = self.attach()
        self.expect_output(again, 0, SET_VAR, "reattach")

    def test_suspend_and_resume_toggle_user_var(self):
        client = self.attach()
        mark = client.mark()
        self.tmux("suspend-client", "-t", client.tty)
        state = poll(lambda: proc_state(client.tmux_pid), lambda s: s == "T")
        self.assertEqual(state, "T", "tmux client was not actually stopped")
        self.expect_output(client, mark, UNSET_VAR, "suspend")
        mark = client.mark()
        os.kill(client.tmux_pid, signal.SIGCONT)
        state = poll(lambda: proc_state(client.tmux_pid), lambda s: s != "T")
        self.assertNotEqual(state, "T", "tmux client did not resume")
        self.expect_output(client, mark, SET_VAR, "resume")

    def test_last_pane_exit_clears_user_var(self):
        client = self.attach()
        mark = client.mark()
        self.tmux("send-keys", "-t", "t", "exit", "Enter")
        self.assertTrue(poll(client.exited, bool), "client did not exit after last pane exited")
        self.assertTrue(poll(lambda: not self._owned(self.server_pid), bool), "server outlived its last session")
        client._reader.join(TIMEOUT)
        out = client.output(mark)
        self.assertTrue(UNSET_VAR in out, f"exit: no unset sequence; tail {out[-400:]!r}")
        self.assertNotIn(SET_VAR, out[out.rfind(UNSET_VAR):], "user var re-set after final unset")


if __name__ == "__main__":
    unittest.main()
