"""ProSaturator: its panel in the window (Drive, the type, Color and its
row, the Waveshaper's row, Quality) and on Push 2 (three banks of
encoders), each changing the same settings."""

import os

import pytest

from test_push2 import display_png, pads, plug, press, turn  # noqa: F401 (pads: its fixture)

TYPE, DRIVE, DC, COLOR, BASE = 1, 2, 3, 4, 5
WS_LIN, OUTPUT, MIX, QUALITY = 10, 16, 17, 18
SLOT = {"place": "Insert", "index": 0, "slot": 0}


def chain(app, fixtures):
    app.cmd(f"load 0 {os.path.join(fixtures, 'loop.wav')}")
    app.cmd("select 0")
    app.cmd("insert 0 0 prosaturator")
    app.cmd("edit_fx pad 0 0")
    app.wait(3)


def test_the_window_panel_drives_prosaturator(app, fixtures):
    chain(app, fixtures)
    p = lambda pid: app.api("effect_get_param", s=SLOT, id=pid)
    app.expect_item("ps display", window="detail")
    app.drag_by("Drive", 0, -40, window="detail")
    assert p(DRIVE) > 3
    app.click("ps Type", window="detail")
    app.click("ps Type Tube")
    assert p(TYPE) == 7
    # Color: its row appears.
    app.expect_no_item("Base", window="detail")
    app.click("ps Color", window="detail")
    assert p(COLOR) == 1
    app.expect_item("Base", window="detail")
    app.screenshot("prosaturator_color")
    # The Waveshaper: its row.
    app.click("ps Type", window="detail")
    app.click("ps Type Waveshaper")
    app.reveal("Lin", "detail", over="ps display")
    app.drag_by("Lin", 0, -30, window="detail")
    assert p(WS_LIN) > 0.5
    app.click("ps Quality", window="detail")
    app.click("ps Quality 4×")
    assert p(QUALITY) == 2
    app.screenshot("prosaturator_waveshaper")


def test_push2_drives_prosaturator_by_its_banks(pads, fixtures):
    plug(pads)
    pads.api("pad_load_sample", pad=0, path=os.path.join(fixtures, "loop.wav"))
    pads.cmd("midiport play push 90 24 64")  # pad A1: selected
    pads.cmd("midiport play push 80 24 00")
    pads.cmd("insert 0 0 prosaturator")
    pads.cmd("edit_fx pad 0 0")
    press(pads, 0x6E)  # Device
    pads.wait(8)
    st = pads.api("view_state", kind="Device", page=0)
    assert st["pages"] == 3 and st["page"] == 0, st
    p = lambda pid: pads.api("effect_get_param", s=SLOT, id=pid)
    turn(pads, 0, 20)
    assert p(DRIVE) > 0
    turn(pads, 1, 3)  # Type: Soft Sine
    assert p(TYPE) == 1
    turn(pads, 6, 3)  # Color: on
    assert p(COLOR) == 1
    display_png(pads, os.path.join(pads.out_dir, "push2_prosaturator_main.png"))
    press(pads, 45)  # ▶: Color
    pads.wait(5)
    assert pads.api("view_state", kind="Device", page=0)["page"] == 1
    turn(pads, 0, 20)
    assert p(BASE) > 0
    press(pads, 45)  # ▶: Waveshaper
    pads.wait(5)
    turn(pads, 1, 20)
    assert p(WS_LIN) > 0.5
    display_png(pads, os.path.join(pads.out_dir, "push2_prosaturator_ws.png"))
    assert pads.api("effect_name", s=SLOT) == "ProSaturator"


def test_prosaturators_presets_are_in_the_library(app, fixtures):
    app.cmd(f"load 0 {os.path.join(fixtures, 'loop.wav')}")
    app.cmd("select 0")
    app.wait(2)
    app.click("category Effects", window="browser")
    app.reveal("device ProSaturator", "browser", over="device SuperFilter", tries=60)
    app.click("device ProSaturator", window="browser")  # (its presets, folded under it: a click shows them)
    app.reveal("device Tube Glow", "browser", over="device SuperFilter", tries=50)  # (near the effects' end: under the fold)
    app.click("device Tube Glow", window="browser", double=True)  # onto the selected pad's first empty insert
    app.wait(3)
    assert app.api("effect_name", s=SLOT) == "ProSaturator"
    assert app.api("effect_get_param", s=SLOT, id=TYPE) == 7
    app.screenshot("prosaturator_presets")
