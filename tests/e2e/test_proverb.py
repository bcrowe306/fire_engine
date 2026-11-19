"""ProVerb: its panel in the window (the bars, the Early and Late pages,
the damping curve's handles, the mode) and on Push 2 (the upper row's
pictures, four banks of encoders), each changing the same settings."""

import os
import time

import pytest

from test_push2 import display_png, pads, plug, press, turn  # noqa: F401 (pads: its fixture)

MIX, PREDELAY, DECAY, HIGH_CUT, DEPTH = 1, 2, 3, 4, 5
EARLY_SIZE, LATE_SIZE, BASS_MULT, BASS_XOVER, MODE = 6, 11, 15, 16, 20
SLOT = {"place": "Insert", "index": 0, "slot": 0}


def chain(app, fixtures):
    app.cmd(f"load 0 {os.path.join(fixtures, 'loop.wav')}")
    app.cmd("select 0")
    app.cmd("insert 0 0 proverb")
    app.cmd("edit_fx pad 0 0")
    app.wait(3)


def test_the_window_panel_drives_proverb(app, fixtures):
    chain(app, fixtures)
    p = lambda pid: app.api("effect_get_param", s=SLOT, id=pid)
    app.expect_item("pv damping", window="detail")
    decay = p(DECAY)
    app.drag_by("pv bar Decay", 0, -40, window="detail")
    assert p(DECAY) > decay
    app.drag_by("pv bar Mix", 0, -30, window="detail")
    assert p(MIX) > 0.35
    # The damping curve: the bass handle (B) dragged up: Bass Mult rises.
    bass = p(BASS_MULT)
    app.drag_at("pv damping", (0.6, 0.15), (0.6, 0.05), window="detail")  # (a miss: nothing)
    xover = p(BASS_XOVER)
    import math
    bx = math.log10(xover / 20) / 3  # (the handle's place across: the plot's log axis)
    app.drag_at("pv damping", (0.015 + bx * 0.97, 0.3), (0.015 + bx * 0.97, 0.1), window="detail")
    assert p(BASS_MULT) > bass or p(BASS_XOVER) != xover
    # The pages.
    app.drag_by("Size", 0, -30, window="detail")
    assert p(EARLY_SIZE) > 0.03
    app.click("pv page Late", window="detail")
    app.drag_by("Size", 0, -30, window="detail")
    assert p(LATE_SIZE) > 0.5
    app.click("pv Mode", window="detail")
    app.click("pv Mode Grand Hall")
    assert p(MODE) == 9
    # The loop playing through it, two seconds: its tail rings.
    app.cmd("set 0 mode 2")
    app.cmd("note 0 0 4 1")
    app.cmd("play")
    for _ in range(20):
        time.sleep(0.1)
        app.wait(1)
    st = app.api("effect_proverb_state", s=SLOT)
    assert st["tail"] > 0.001, st
    app.screenshot("proverb_window")


def test_push2_drives_proverb_by_its_banks(pads, fixtures):
    plug(pads)
    pads.api("pad_load_sample", pad=0, path=os.path.join(fixtures, "loop.wav"))
    pads.cmd("midiport play push 90 24 64")  # pad A1: selected (and heard)
    pads.cmd("insert 0 0 proverb")
    pads.cmd("edit_fx pad 0 0")
    press(pads, 0x6E)  # Device
    pads.wait(8)
    st = pads.api("view_state", kind="Device", page=0)
    assert st["pages"] == 4 and st["page"] == 0, st
    p = lambda pid: pads.api("effect_get_param", s=SLOT, id=pid)
    turn(pads, 2, 20)
    assert p(DECAY) > 2
    time.sleep(1)
    pads.wait(10)
    display_png(pads, os.path.join(pads.out_dir, "push2_proverb_main.png"))
    press(pads, 102 + 0)  # the upper row: Early
    pads.wait(5)
    display_png(pads, os.path.join(pads.out_dir, "push2_proverb_early.png"))
    press(pads, 102 + 1)  # Damping
    pads.wait(5)
    display_png(pads, os.path.join(pads.out_dir, "push2_proverb_damping.png"))
    press(pads, 45)  # ▶: the Early bank
    pads.wait(5)
    assert pads.api("view_state", kind="Device", page=0)["page"] == 1
    turn(pads, 0, 20)
    assert p(EARLY_SIZE) > 0.03
    press(pads, 45)  # ▶ ▶: the Decay bank
    press(pads, 45)
    pads.wait(5)
    turn(pads, 0, 20)
    assert p(BASS_MULT) > 1
    pads.cmd("midiport play push 80 24 00")
    assert pads.api("effect_name", s=SLOT) == "ProVerb"


def test_proverbs_presets_are_in_the_library(app, fixtures):
    app.cmd(f"load 0 {os.path.join(fixtures, 'loop.wav')}")
    app.cmd("select 0")
    app.wait(2)
    app.click("category Effects", window="browser")
    app.reveal("device ProVerb", "browser", over="device SuperFilter", tries=60)
    app.click("device ProVerb", window="browser")  # (its presets, folded under it: a click shows them)
    app.reveal("device Grand Hall", "browser", over="device SuperFilter", tries=60)  # (at the effects' end: under the fold)
    app.click("device Grand Hall", window="browser", double=True)  # onto the selected pad's first empty insert
    app.wait(3)
    assert app.api("effect_name", s=SLOT) == "ProVerb"
    assert app.api("effect_get_param", s=SLOT, id=MODE) == 9
    app.screenshot("proverb_presets")
