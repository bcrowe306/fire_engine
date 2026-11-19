"""The test kit for the devices' panels on Push 2 (docs/design/push2-devices.md):
a device put where it can be (an effect slot, the synth's Effects tab, a
Perform effect), shown on the Push's display, its banks stepped, its knobs
turned and checked, the display saved, the panel's drawing time read.

    from push2_fx import *  # noqa: F401,F403 (pads: its fixture)

    def test_push2_compressor(pads):
        d = in_slot(pads, "compressor")
        assert banks(pads) == ["Main", "Detector"]
        moves(pads, d, 0, THRESHOLD, -10)   # encoder 1 lowers Threshold
        save(pads, "compressor_main")
        bank(pads, 1)
        ...
"""

import os

from test_push2 import display_png, pads, plug, press, settle, turn  # noqa: F401 (pads: its fixture)

DEVICE = 0x6E  # Push 2's Device button
RIGHT, LEFT = 45, 44  # ◀ ▶: the banks


class Device:
    """Where a device under test is, and how to read its parameters."""

    def __init__(self, pads, where, slot=None, pad=0):
        self.pads, self.where, self.slot, self.pad = pads, where, slot, pad

    def get(self, pid):
        """Parameter `pid`'s plain value."""
        if self.where == "synth":
            return self.pads.api("param_get", ref={"track": "Pad", "index": self.pad, "device": "Sound", "param": pid})
        return self.pads.api("effect_get_param", s=self.slot, id=pid)

    def set(self, pid, value):
        if self.where == "synth":
            self.pads.cmd(f"synth_param {self.pad} {pid} {value}")
        else:
            self.pads.api("effect_set_param", s=self.slot, id=pid, value=value)
        self.pads.wait(3)


def _show(pads):
    press(pads, DEVICE)
    pads.wait(8)


def _select_pad(pads, pad=0):
    note = 0x24 + pad  # (Pads mode: A1 is the bottom left)
    pads.cmd(f"midiport play push 90 {note:02X} 64")
    pads.cmd(f"midiport play push 80 {note:02X} 00")
    pads.wait(3)


def in_slot(pads, kind, pad=0, slot=0, sample=None):
    """Effect `kind` (the shell's name: compressor, delay...) in pad `pad`'s
    insert `slot`, shown on the Push (Device). Give it a `sample` (the
    fixtures' loop.wav): an empty pad's Device shows what to put on it."""
    plug(pads)
    if sample:
        pads.api("pad_load_sample", pad=pad, path=sample)
    _select_pad(pads, pad)
    pads.cmd(f"insert {pad} {slot} {kind}")
    pads.cmd(f"edit_fx pad {pad} {slot}")
    _show(pads)
    return Device(pads, "slot", {"place": "Insert", "index": pad, "slot": slot}, pad)


def in_perform(pads, kind, n=0):
    """Effect `kind` as Perform's effect `n`, shown on the Push (Device)."""
    plug(pads)
    pads.cmd(f"perf_fx {n} {kind}")
    pads.cmd(f"edit_fx perf {n}")
    _show(pads)
    return Device(pads, "perf", {"place": "Perf", "index": n, "slot": 0})


def on_synth(pads, effect, pad=0):
    """The synth's effect `effect` (chorus, compressor, delay, distortion, eq,
    filter, flanger, phaser, reverb) on pad `pad`'s synth, its Effects tab
    shown on the Push."""
    plug(pads)
    pads.cmd(f"synth {pad}")
    _select_pad(pads, pad)
    pads.cmd("synth_tab effects")
    pads.cmd(f"synth_fx {effect}")
    _show(pads)
    return Device(pads, "synth", pad=pad)


def view(pads):
    return pads.api("view_state", kind="Device", page=0)


def banks(pads):
    """How many banks the panel shows (◀ ▶ page them)."""
    return view(pads)["pages"]


def bank(pads, n):
    """Bank `n` shown (◀ ▶ pressed until it is)."""
    for _ in range(16):
        now = view(pads)["page"]
        if now == n:
            return
        press(pads, RIGHT if now < n else LEFT)
        pads.wait(4)
    assert view(pads)["page"] == n, view(pads)


def moves(pads, d, encoder, pid, steps, check=None):
    """Encoder `encoder` (0..7) turned `steps` moves parameter `pid` (the way
    `check(before, after)` says; by default, up for + steps, down for -)."""
    before = d.get(pid)
    turn(pads, encoder, steps)
    after = d.get(pid)
    if check is None:
        assert (after > before) if steps > 0 else (after < before), (encoder, pid, before, after)
    else:
        assert check(before, after), (encoder, pid, before, after)
    return after


def save(pads, name):
    """The display as `<out_dir>/push2_<name>.png` (look at it)."""
    settle(pads)
    return display_png(pads, os.path.join(pads.out_dir, f"push2_{name}.png"))


def draw_us(pads):
    """The family panel's drawing time on this machine: (last, most) µs."""
    last, most = pads.state()["fx_draw_us"]
    return last, most
