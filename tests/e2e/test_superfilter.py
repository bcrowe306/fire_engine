"""SuperFilter: its panel in the window (the display's handle, the type and
circuit, the sidechain row and the LFO's extras folded away, its knobs) and
on Push 2 (the same display, four banks of encoders), each changing the
same settings."""

import os

import pytest

from test_push2 import display_png, pads, plug, press, turn  # noqa: F401 (pads: its fixture)

# SuperFilter's parameter ids (fx.SF_PARAM_*).
TYPE, CIRCUIT, FREQ, RES, LFO_AMOUNT, ENV_ATTACK, LFO_STEREO, MIX = 1, 2, 3, 4, 8, 22, 15, 30


def fx_param(app, pid):
    return dict((int(i), v) for i, v in app.state()["fx_params"]).get(pid)


def chain(app, fixtures):
    app.cmd(f"load 0 {os.path.join(fixtures, 'loop.wav')}")
    app.cmd("select 0")
    app.cmd("insert 0 0 superfilter")
    app.cmd("edit_fx pad 0 0")
    app.wait(3)


def test_the_window_panel_drives_superfilter(app, fixtures):
    chain(app, fixtures)
    app.expect_item("superfilter display", window="detail")
    # The display's handle, dragged left: Freq falls; up: Res rises.
    before, res = fx_param(app, FREQ), fx_param(app, RES)
    app.drag_by("superfilter display", -120, -20, window="detail")
    assert fx_param(app, FREQ) < before, (before, fx_param(app, FREQ))
    assert fx_param(app, RES) > res
    # The type, from its dropdown.
    app.click("sf Type", window="detail")
    app.click("sf Type Band-pass")
    assert fx_param(app, TYPE) == 2
    # The LFO's knob, turned up.
    app.drag_by("LFO", 0, -40, window="detail")
    assert fx_param(app, LFO_AMOUNT) > 0
    # The sidechain's row, folded away until asked for; the LFO's extras too.
    app.expect_no_item("sidechain", window="detail")
    app.click("sf key row", window="detail")
    app.expect_item("sidechain", window="detail")
    app.expect_no_item("Retrigger", window="detail")
    app.click("sf lfo extras", window="detail")
    app.reveal("sf LFO Stereo", "detail", over="Release")  # (under the fold with the sidechain's row open: scrolled to)
    app.expect_item("Retrigger", window="detail")
    app.click("sf LFO Stereo", window="detail")
    app.click("sf LFO Stereo Spin")
    assert fx_param(app, LFO_STEREO) == 1
    app.expect_item("Spin", window="detail")
    app.screenshot("superfilter_window")


def test_push2_drives_superfilter_by_its_banks(pads, fixtures):
    plug(pads)
    pads.api("pad_load_sample", pad=0, path=os.path.join(fixtures, "loop.wav"))
    pads.cmd("midiport play push 90 24 64")  # pad A1: selected
    pads.cmd("midiport play push 80 24 00")
    pads.cmd("insert 0 0 superfilter")
    pads.cmd("edit_fx pad 0 0")
    press(pads, 0x6E)  # Device: the slot, as the window shows it
    pads.wait(8)
    st = pads.api("view_state", kind="Device", page=0)
    assert st["pages"] == 4 and st["page"] == 0, st
    slot = {"place": "Insert", "index": 0, "slot": 0}
    p = lambda pid: pads.api("effect_get_param", s=slot, id=pid)
    # Filter: Freq down, the type (a dropdown) to the next, Dry/Wet down.
    freq = p(FREQ)
    turn(pads, 0, -20)
    assert p(FREQ) < freq
    turn(pads, 3, 3)  # three detents: High-pass
    assert p(TYPE) == 1
    turn(pads, 7, -20)
    assert p(MIX) < 1
    display_png(pads, os.path.join(pads.out_dir, "push2_superfilter_filter.png"))
    # Its pages (Filter, Circuit, Envelope, LFO): ◀ ▶, the lower row free of them.
    assert st["pages"] == 4 and (st["buttons"] >> 16) & 3 == 3, st
    press(pads, 45)  # ▶: Circuit
    pads.wait(5)
    assert pads.api("view_state", kind="Device", page=0)["page"] == 1
    turn(pads, 1, 6)  # Circuit: two on (Analog → Ladder)
    assert p(CIRCUIT) == 3
    display_png(pads, os.path.join(pads.out_dir, "push2_superfilter_circuit.png"))
    press(pads, 45)  # ▶: Envelope
    pads.wait(5)
    attack = p(ENV_ATTACK)
    turn(pads, 0, 20)
    assert p(ENV_ATTACK) > attack
    display_png(pads, os.path.join(pads.out_dir, "push2_superfilter_envelope.png"))
    press(pads, 45)  # ▶: LFO
    pads.wait(5)
    turn(pads, 0, 3)  # Stereo: Spin
    assert p(LFO_STEREO) == 1
    display_png(pads, os.path.join(pads.out_dir, "push2_superfilter_lfo.png"))
    # The window follows: its slot is what the Push changed.
    assert pads.api("effect_name", s=slot) == "SuperFilter"


def test_superfilters_presets_are_in_the_library(app, fixtures):
    app.cmd(f"load 0 {os.path.join(fixtures, 'loop.wav')}")
    app.cmd("select 0")
    app.wait(2)
    app.click("category Effects", window="browser")
    app.reveal("device SuperFilter", "browser", over="device SuperFilter", tries=60)
    app.click("device SuperFilter", window="browser")  # (its presets, folded under it: a click shows them)
    app.reveal("device Wobble 1/8", "browser", over="device SuperFilter")
    app.click("device Wobble 1/8", window="browser", double=True)  # onto the selected pad's first empty insert
    app.wait(3)
    slot = {"place": "Insert", "index": 0, "slot": 0}
    assert app.api("effect_name", s=slot) == "SuperFilter"
    assert app.api("effect_get_param", s=slot, id=LFO_AMOUNT) == pytest.approx(0.45)
    assert app.api("history_undo_name") in ("Load Preset", "Add Effect")
    app.screenshot("superfilter_presets")
