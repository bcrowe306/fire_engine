"""ProEq: its panel in the window (a band's handle dragged on the display,
the type menus and a cut's slopes, the on switches, the mode and the set
edited) and on Push 2 (the bands on the upper row, three banks of
encoders), each changing the same settings."""

import math
import os

import pytest

from test_push2 import display_png, pads, plug, press, turn  # noqa: F401 (pads: its fixture)

MODE, SCALE, GAIN = 1, 3, 4
ON, TYPE, SLOPE, FREQ, BGAIN, Q = range(6)
BELL, NOTCH = 2, 3


def band(set_, b, field):
    """fx.pro_eq_band_param."""
    return 6 + 48 * set_ + 6 * b + field


def chain(app, fixtures):
    app.cmd(f"load 0 {os.path.join(fixtures, 'loop.wav')}")
    app.cmd("select 0")
    app.cmd("insert 0 0 proeq")
    app.cmd("edit_fx pad 0 0")
    app.wait(3)


SLOT = {"place": "Insert", "index": 0, "slot": 0}


def test_the_window_panel_drives_proeq(app, fixtures):
    chain(app, fixtures)
    p = lambda pid: app.api("effect_get_param", s=SLOT, id=pid)
    app.expect_item("pe display", window="detail")
    # Band 3 at the display's middle (632 Hz, 0 dB): dragged right and up, its Freq and Gain rise.
    mid = math.sqrt(20 * 20_000)
    app.api("effect_set_param", s=SLOT, id=band(0, 2, FREQ), value=mid)
    app.wait(2)
    app.drag_by("pe display", 60, -30, window="detail")
    assert p(band(0, 2, FREQ)) > mid * 1.2, p(band(0, 2, FREQ))
    assert p(band(0, 2, BGAIN)) > 1, p(band(0, 2, BGAIN))
    assert app.api("history_undo_name") == "Set Effect"
    # A type from its cell's menu; a cut's slope; a band turned on.
    app.click("pe type 4", window="detail")
    app.click("pe type 4 Notch")
    assert p(band(0, 3, TYPE)) == NOTCH
    app.click("pe band 1", window="detail")
    assert p(band(0, 0, ON)) == 1
    app.click("pe type 1", window="detail")
    app.click("pe slope 1 48 dB")
    assert p(band(0, 0, SLOPE)) == 3
    app.screenshot("proeq_window")
    # M/S: B starts as A; editing B leaves A.
    app.click("pe Mode", window="detail")
    app.click("pe Mode M/S")
    assert p(MODE) == 2
    a_gain = p(band(0, 2, BGAIN))
    assert p(band(1, 2, BGAIN)) == pytest.approx(a_gain)
    app.click("pe Edit 1", window="detail")
    app.api("effect_set_param", s=SLOT, id=band(1, 2, FREQ), value=mid)
    app.api("effect_set_param", s=SLOT, id=band(1, 2, BGAIN), value=0)
    app.wait(2)
    app.drag_by("pe display", 0, 30, window="detail")
    assert p(band(1, 2, BGAIN)) < -1
    assert p(band(0, 2, BGAIN)) == pytest.approx(a_gain)
    app.screenshot("proeq_window_side")


def test_push2_drives_proeq_by_its_bands_and_banks(pads, fixtures):
    plug(pads)
    pads.api("pad_load_sample", pad=0, path=os.path.join(fixtures, "loop.wav"))
    pads.cmd("midiport play push 90 24 64")  # pad A1: selected
    pads.cmd("midiport play push 80 24 00")
    pads.cmd("insert 0 0 proeq")
    pads.cmd("edit_fx pad 0 0")
    press(pads, 0x6E)  # Device: the slot, as the window shows it
    pads.wait(8)
    st = pads.api("view_state", kind="Device", page=0)
    assert st["pages"] == 3 and st["page"] == 0, st
    p = lambda pid: pads.api("effect_get_param", s=SLOT, id=pid)
    # The upper row picks a band: the fifth; its Freq and Gain on the first encoders.
    press(pads, 102 + 4)
    pads.wait(4)
    freq = p(band(0, 4, FREQ))
    turn(pads, 0, 20)
    assert p(band(0, 4, FREQ)) > freq
    turn(pads, 1, 20)
    assert p(band(0, 4, BGAIN)) > 0
    turn(pads, 3, 3)  # Type: one on (Bell → Notch)
    assert p(band(0, 4, TYPE)) == NOTCH
    display_png(pads, os.path.join(pads.out_dir, "push2_proeq_band.png"))
    # Bands: every band's frequency.
    press(pads, 45)  # ▶: the next page
    pads.wait(5)
    assert pads.api("view_state", kind="Device", page=0)["page"] == 1
    f2 = p(band(0, 1, FREQ))
    turn(pads, 1, -20)
    assert p(band(0, 1, FREQ)) < f2
    display_png(pads, os.path.join(pads.out_dir, "push2_proeq_bands.png"))
    # Global: the mode (L/R), Scale.
    press(pads, 45)
    pads.wait(5)
    turn(pads, 0, 3)
    assert p(MODE) == 1
    turn(pads, 6, -20)
    assert p(SCALE) < 1
    display_png(pads, os.path.join(pads.out_dir, "push2_proeq_global.png"))
    assert pads.api("effect_name", s=SLOT) == "ProEq"


def test_proeqs_presets_are_in_the_library(app, fixtures):
    app.cmd(f"load 0 {os.path.join(fixtures, 'loop.wav')}")
    app.cmd("select 0")
    app.wait(2)
    app.click("category Effects", window="browser")
    app.reveal("device ProEq", "browser", over="device SuperFilter", tries=60)
    app.click("device ProEq", window="browser")  # (its presets, folded under it: a click shows them)
    app.reveal("device Kick Punch", "browser", over="device SuperFilter", tries=30)  # (last of the effects: under the fold)
    app.expect_item("device ProEq", window="browser")
    app.click("device Kick Punch", window="browser", double=True)  # onto the selected pad's first empty insert
    app.wait(3)
    assert app.api("effect_name", s=SLOT) == "ProEq"
    assert app.api("effect_get_param", s=SLOT, id=band(0, 2, BGAIN)) == pytest.approx(-4)
    app.screenshot("proeq_presets")
