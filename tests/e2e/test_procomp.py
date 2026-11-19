"""ProComp: its panel in the window (the threshold's arrow dragged, Ratio,
the views, the mode, the sidechain row keyed from a pad) and on Push 2
(its views on the upper row, three banks of encoders), each changing the
same settings."""

import os

import pytest

from test_push2 import display_png, pads, plug, press, turn  # noqa: F401 (pads: its fixture)

THRESHOLD, RATIO, ATTACK, RELEASE, AUTO, KNEE, LOOKAHEAD, MODE = 1, 2, 3, 4, 5, 6, 7, 8
OUTPUT, MIX, EQ_ON, EQ_TYPE = 11, 12, 13, 14
SLOT = {"place": "Insert", "index": 0, "slot": 0}


def chain(app, fixtures):
    app.cmd(f"load 0 {os.path.join(fixtures, 'loop.wav')}")
    app.cmd(f"load 1 {os.path.join(fixtures, 'loop.wav')}")
    app.cmd("select 0")
    app.cmd("insert 0 0 procomp")
    app.cmd("edit_fx pad 0 0")
    app.wait(3)


def test_the_window_panel_drives_procomp(app, fixtures):
    chain(app, fixtures)
    p = lambda pid: app.api("effect_get_param", s=SLOT, id=pid)
    app.expect_item("pc display", window="detail")
    # The threshold's arrow, by the input meter (the display's left edge): dragged down.
    before = p(THRESHOLD)
    app.drag_at("pc display", (0.025, 0.5), (0.025, 0.75), window="detail")
    assert p(THRESHOLD) < before - 3, (before, p(THRESHOLD))
    app.drag_by("Ratio", 0, -40, window="detail")
    assert p(RATIO) > 4
    for view in ("Activity", "Meters", "Curve"):
        app.click(f"pc view {view}", window="detail")
        app.screenshot(f"procomp_{view.lower()}")
    app.click("pc Mode RMS", window="detail")
    assert p(MODE) == 1
    app.click("pc Lookahead", window="detail")
    app.click("pc Lookahead 10 ms")
    assert p(LOOKAHEAD) == 2
    # The sidechain row: keyed from pad A2, its EQ on.
    app.click("pc key row", window="detail")
    app.click("sidechain", window="detail")
    app.click("key pad A2")
    assert app.api("effect_key", s=SLOT)["kind"] == "Pad"
    app.click("pc Key EQ", window="detail")
    assert p(EQ_ON) == 1
    app.screenshot("procomp_sidechain")


def test_push2_drives_procomp_by_its_views_and_banks(pads, fixtures):
    plug(pads)
    pads.api("pad_load_sample", pad=0, path=os.path.join(fixtures, "loop.wav"))
    pads.cmd("midiport play push 90 24 64")  # pad A1: selected
    pads.cmd("midiport play push 80 24 00")
    pads.cmd("insert 0 0 procomp")
    pads.cmd("edit_fx pad 0 0")
    press(pads, 0x6E)  # Device
    pads.wait(8)
    st = pads.api("view_state", kind="Device", page=0)
    assert st["pages"] == 3 and st["page"] == 0, st
    p = lambda pid: pads.api("effect_get_param", s=SLOT, id=pid)
    th = p(THRESHOLD)
    turn(pads, 0, -20)
    assert p(THRESHOLD) < th
    turn(pads, 1, 20)
    assert p(RATIO) > 4
    display_png(pads, os.path.join(pads.out_dir, "push2_procomp_curve.png"))
    press(pads, 102 + 1)  # the upper row: Activity
    pads.wait(5)
    display_png(pads, os.path.join(pads.out_dir, "push2_procomp_activity.png"))
    press(pads, 45)  # ▶: Detail
    pads.wait(5)
    assert pads.api("view_state", kind="Device", page=0)["page"] == 1
    turn(pads, 0, 3)  # Mode: RMS
    assert p(MODE) == 1
    press(pads, 45)  # ▶: Sidechain
    pads.wait(5)
    turn(pads, 1, 3)  # EQ: on
    assert p(EQ_ON) == 1
    display_png(pads, os.path.join(pads.out_dir, "push2_procomp_sidechain.png"))
    assert pads.api("effect_name", s=SLOT) == "ProComp"


def test_procomps_presets_are_in_the_library(app, fixtures):
    app.cmd(f"load 0 {os.path.join(fixtures, 'loop.wav')}")
    app.cmd("select 0")
    app.wait(2)
    app.click("category Effects", window="browser")
    app.reveal("device ProComp", "browser", over="device SuperFilter", tries=60)
    app.click("device ProComp", window="browser")  # (its presets, folded under it: a click shows them)
    app.reveal("device De-ess", "browser", over="device SuperFilter", tries=40)  # (last of the effects: under the fold)
    app.click("device De-ess", window="browser", double=True)  # onto the selected pad's first empty insert
    app.wait(3)
    assert app.api("effect_name", s=SLOT) == "ProComp"
    assert app.api("effect_get_param", s=SLOT, id=EQ_ON) == 1
    app.screenshot("procomp_presets")
