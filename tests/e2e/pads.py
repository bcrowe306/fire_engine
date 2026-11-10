"""A client for driving a running Pads over its control socket (--control).

Pads takes drive-script commands one per line and answers each with a line
of JSON once it has run. This wraps that: it starts the app, sends
commands, finds items by the labels a person sees, reads the app's state,
and turns a crash into an exception carrying the app's crash report (the
signal, the last command, a back trace).

    with Pads() as app:
        app.browse("tests/app_ui/fixtures/library")
        app.click("Drums", window="browser")
        app.drag("Kick 808.wav", "pad A1", from_window="browser")
        assert app.pad(0)["name"] == "Kick 808"
"""

import json
import os
import platform
import queue
import re
import socket
import subprocess
import tempfile
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
EXE = os.path.join(ROOT, ".build", "app", "pads" + (".exe" if platform.system() == "Windows" else ""))


class PadsError(Exception):
    """A command the app ran but that failed (an expect, a missing item)."""


class PadsCrash(Exception):
    """The app died. `report` is its crash report (and the end of its log)."""

    def __init__(self, message, report):
        super().__init__(f"{message}\n{report}")
        self.report = report


def quote(label):
    """A label as one word of a command."""
    return '"' + label.replace('"', "") + '"'


class Pads:
    """A Pads process under remote control.

    headless: no window (default: E2E_HEADLESS=1, or not on macOS).
    fake: the simulated audio driver (default True: no sound card needed).
    """

    def __init__(self, headless=None, fake=True, out_dir=None, project=None, prefs=None, extra=()):
        if headless is None:
            headless = os.environ.get("E2E_HEADLESS", "1" if platform.system() != "Darwin" else "0") == "1"
        self.tmp = tempfile.mkdtemp(prefix="pads_e2e_")
        self.out_dir = out_dir or os.path.join(self.tmp, "shots")
        args = [EXE, "--control", "0", "--out", self.out_dir, "--prefs", prefs or os.path.join(self.tmp, "prefs")]
        if project:
            args += ["--project", project]
        if headless:
            args.append("--headless")
        if fake:
            args.append("--fake")
        args += list(extra)
        if not os.path.exists(EXE):
            raise FileNotFoundError(f"{EXE}: build it first (task app:pads OPT=none)")
        self.proc = subprocess.Popen(args, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, errors="replace")
        self.log = []  # every line of stderr and stdout
        self._lines = queue.Queue()
        threading.Thread(target=self._read, args=(self.proc.stdout, True), daemon=True).start()
        threading.Thread(target=self._read, args=(self.proc.stderr, False), daemon=True).start()
        port = None
        deadline = time.time() + 30
        while time.time() < deadline:
            try:
                line = self._lines.get(timeout=0.2)
            except queue.Empty:
                if self.proc.poll() is not None:
                    raise self._crash("Pads exited while starting")
                continue
            m = re.search(r"control: listening on 127\.0\.0\.1:(\d+)", line)
            if m:
                port = int(m.group(1))
                break
        if port is None:
            self.proc.kill()
            raise TimeoutError("Pads did not start listening:\n" + "\n".join(self.log[-40:]))
        self.sock = socket.create_connection(("127.0.0.1", port), timeout=120)
        self.file = self.sock.makefile("rw", encoding="utf-8", newline="\n")
        self.closed = False
        self.crashed = False
        self.wait(10)  # the docked layout settles over the first frames

    def _read(self, stream, is_stdout):
        for line in stream:
            line = line.rstrip("\n")
            self.log.append(line)
            if is_stdout:
                self._lines.put(line)

    def _crash(self, message):
        self.crashed = True
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass
        time.sleep(0.3)  # let the readers catch the report's last lines
        text = "\n".join(self.log)
        start = text.find("=== CRASH")
        report = text[start:] if start >= 0 else "\n".join(self.log[-60:])
        return PadsCrash(f"{message} (exit status {self.proc.returncode})", report)

    # --- commands --------------------------------------------------------------------------

    def cmd(self, line, check=True):
        """Runs one command; returns what it said. Raises PadsError if it
        failed (and `check`), PadsCrash if the app died."""
        if self.closed:
            raise PadsError("the app is closed")
        if os.environ.get("E2E_TRACE"):
            print("e2e>", line, flush=True)
        try:
            self.file.write(line + "\n")
            self.file.flush()
            answer = self.file.readline()
        except (OSError, ValueError):
            answer = ""
        if not answer:
            if self.proc.poll() is None:
                try:
                    self.proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    pass
            raise self._crash(f"Pads died running: {line}")
        r = json.loads(answer)
        if check and not r["ok"]:
            raise PadsError(f"{line}: {r.get('error', '')}")
        return r["output"]

    def run(self, script):
        """Runs several commands (a drive script's lines)."""
        for line in script.strip().splitlines():
            line = line.strip()
            if line and not line.startswith("#"):
                self.cmd(line)

    def _target(self, label, window):
        return quote(label) + (f" in {window}" if window else "")

    def click(self, label, window=None, right=False, double=False, at=None):
        """Clicks the item labelled `label` (in panel `window`), as a person would."""
        extra = (" right" if right else "") + (" double" if double else "")
        if at:
            extra += f" at {at[0]} {at[1]}"
        self.cmd(f"click_item {self._target(label, window)}{extra}")
        # Past ImGui's double-click time (0.3 s), so the next click is a click of its own.
        self.wait(20)

    def panel(self, name):
        """Brings panel `name` to the front by clicking its tab ("Sequence",
        "Song", "Mixer", "Perform", "Browser", "Pads"; their tabs show an icon before
        the name, so a menu of the same name isn't what is clicked)."""
        self.click("  " + name)

    def hover(self, label, window=None):
        self.cmd(f"hover_item {self._target(label, window)}")

    def drag(self, src, dst, from_window=None, to_window=None, steps=12):
        """Drags item `src` onto item `dst`."""
        self.cmd(f"drag_item {self._target(src, from_window)} to {self._target(dst, to_window)} {steps}")
        self.wait(3)

    def drag_at(self, label, frm, to, window=None, steps=12):
        """Drags inside item `label` from point `frm` to point `to`, each a
        fraction (x, y) of its size: a marker on a waveform."""
        items = [i for i in self.items(label, window) if i["label"] == label]
        if not items:
            raise PadsError(f"no item {label!r}")
        x0, y0, x1, y1 = items[0]["rect"]
        p = lambda f: (x0 + (x1 - x0) * f[0], y0 + (y1 - y0) * f[1])
        a, b = p(frm), p(to)
        self.cmd(f"drag {a[0]} {a[1]} {b[0]} {b[1]} {steps}")
        self.wait(3)

    def drag_by(self, label, dx, dy, window=None, steps=12):
        """Drags from the item's centre by (dx, dy) points: a knob, a fader."""
        self.cmd(f"drag_by {self._target(label, window)} {dx} {dy} {steps}")
        self.wait(3)

    def key(self, chord):
        """Presses a key: "space", "cmd+z", "down"."""
        self.cmd(f"key {chord}")
        self.wait(2)

    def type(self, text):
        self.cmd(f"text {text}")
        self.wait(2)

    def wait(self, frames=1):
        self.cmd(f"wait {frames}")

    def has(self, label, window=None):
        """Whether an item labelled `label` shows now."""
        return any(i["label"] == label for i in self.items(label, window))

    def expect_item(self, label, window=None):
        self.cmd(f"expect_item {self._target(label, window)}")

    def tool(self, name):
        """Picks a sequence editor tool by its button: Select, Draw, Erase, Move."""
        for it in self.items(name, "sequence"):
            if it["label"].startswith(name + " ("):
                self.click(it["label"], window="sequence")
                return
        raise PadsError(f"no tool {name}")

    def sampler_tab(self):
        """Clicks the bottom panel's first device tab, the pad's sampler
        ("A1 kick · Sampler"), whatever the pad is called."""
        for it in self.items("Sampler", "detail"):
            if it["label"].endswith("· Sampler") or it["label"].endswith("· Audio"):
                self.click(it["label"], window="detail")
                return
        raise PadsError("no sampler tab")

    def reveal(self, label, window, over, tries=12):
        """Scrolls the panel under item `over` (with the wheel, as a person
        would) until item `label` shows."""
        self.hover(over, window)
        for _ in range(tries):
            if any(i["label"] == label for i in self.items(label, window)):
                return
            self.cmd("scroll 0 -3")
            self.wait(3)
        self.expect_item(label, window)

    def expect_no_item(self, label, window=None):
        self.cmd(f"expect_no_item {self._target(label, window)}")

    def items(self, text="", window=None):
        """The items showing (whose label or window contains `text`): dicts
        with window, label and rect."""
        out = []
        for line in self.cmd("items " + quote(text) if text else "items").splitlines():
            parts = line.split("\t")
            if len(parts) == 4:
                w, label, rect, raw = parts
                if window and not w.lower().startswith(window.lower()):
                    continue
                out.append({"window": w, "label": label, "raw": raw, "rect": [float(x) for x in rect.split()]})
        return out

    def state(self):
        """The app's state: pads, sequencer, mixer, browser, preview, toasts."""
        return json.loads(self.cmd("state"))

    def pad(self, index):
        """Pad `index`'s state (it must have a sound)."""
        for p in self.state()["pads"]:
            if p["index"] == index:
                return p
        raise PadsError(f"pad {index} has no sound")

    def screenshot(self, name):
        """Saves this frame; returns the PNG's path."""
        self.cmd(f"screenshot {name}")
        self.wait(1)
        return os.path.join(self.out_dir, name + ".png")

    def browse(self, folder):
        self.cmd(f"browse {os.path.join(ROOT, folder) if not os.path.isabs(folder) else folder}")
        self.wait(2)

    def until(self, predicate, frames=180, what="a condition"):
        """Lets frames pass until predicate(state) holds (up to `frames`)."""
        for _ in range(frames // 6):
            s = self.state()
            if predicate(s):
                return s
            self.wait(6)
        raise PadsError(f"timed out waiting for {what}")

    # --- the end ---------------------------------------------------------------------------

    def close(self):
        if self.closed:
            return
        self.closed = True
        if self.proc.poll() is not None:  # already gone (a crash, reported)
            return
        try:
            self.file.write("quit\n")
            self.file.flush()
        except OSError:
            pass
        try:
            self.proc.wait(timeout=15)
        except subprocess.TimeoutExpired:
            self.proc.kill()
        try:
            self.sock.close()
        except OSError:
            pass
        if self.proc.returncode not in (0, None) and not self.crashed:
            raise self._crash("Pads crashed while quitting")

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
        return False
