"""The mixer's channel strips, by mouse: faders, mute and solo, sends,
outputs, pan, inserts and the EQ display."""

import os


def mixer(app, fixtures):
    app.cmd(f"load 0 {os.path.join(fixtures, 'kick.wav')}")
    app.cmd(f"load 1 {os.path.join(fixtures, 'hat.wav')}")
    app.panel("Mixer")
    app.expect_item("A1 fader", window="mixer")


def test_a_strip_for_each_pad_with_a_sound(app, fixtures):
    mixer(app, fixtures)
    assert app.has("A2 fader", window="mixer")
    assert not app.has("A3 fader", window="mixer")
    for b in ("Bus A", "Bus B", "Bus C", "Bus D", "Main"):
        assert app.has(f"{b} fader", window="mixer"), b


def test_faders_mute_solo_and_pan(app, fixtures):
    mixer(app, fixtures)
    app.drag_by("A1 fader", 0, 40, window="mixer")
    assert app.pad(0)["volume"] < -3
    app.key("cmd+z")
    assert abs(app.pad(0)["volume"]) < 0.01
    app.click("A1 mute", window="mixer")
    assert app.pad(0)["mute"]
    app.click("A2 solo", window="mixer")
    assert app.pad(1)["solo"]
    app.drag_by("A1 pan", 0, -40, window="mixer")
    assert app.pad(0)["pan"] > 0.2
    app.drag_by("Bus A fader", 0, 30, window="mixer")
    assert app.state()["buses"][0]["volume"] < -3


def test_sends_pre_and_post(app, fixtures):
    mixer(app, fixtures)
    # The inserts and EQ hidden (the bar's toggles): the sends get the room.
    app.click("Inserts: each strip's effects (click one to edit it below, drag to reorder)", window="mixer")
    app.click("EQ: each strip's EQ curve (click it to edit below)", window="mixer")
    assert not app.state()["mixer_view"]["inserts"]
    app.drag_by("A1 send B", 150, 0, window="mixer")  # across (a bar): right, more
    assert app.pad(0)["sends"][1] > -10
    app.click("A1 send B", window="mixer", right=True)
    app.click("Pre-fader")
    assert app.state()["undo"] == "Pre-fader Send"
    app.click("A1 send C", window="mixer", double=True)  # on at 0 dB
    assert abs(app.pad(0)["sends"][2]) < 0.01


def test_outputs_and_inserts(app, fixtures):
    mixer(app, fixtures)
    app.click("A1 output", window="mixer")
    app.click("Bus C")
    assert app.pad(0)["bus"] == 3
    app.click("A1 slot 1", window="mixer")  # empty: the chain's + tab, to fill it
    app.click("add Filter", window="detail")
    assert app.pad(0)["inserts"][0] == "Filter"
    assert app.state()["detail_tab"] == "Effect"  # its device, in front
    app.click("A1 eq", window="mixer")
    assert app.state()["detail_tab"] == "EQ"


def test_the_peak_readout_resets(app, fixtures):
    mixer(app, fixtures)
    app.cmd("hit 0")
    app.wait(20)
    assert app.pad(0)["level"] > 0
    app.click("A1 peak", window="mixer")


def test_the_bar_and_main_meters(app, fixtures):
    mixer(app, fixtures)
    app.click("strip width", window="mixer", at=(0.75, 0.5))  # Narrow
    assert app.state()["mixer_view"]["narrow"]
    for k in ("eq", "sends", "io"):
        assert app.state()["mixer_view"][k]
    app.click("EQ: each strip's EQ curve (click it to edit below)", window="mixer")
    assert not app.state()["mixer_view"]["eq"]
    app.expect_item("A1 fader", window="mixer")
    app.expect_item("main integrated", window="mixer")
    app.expect_item("main correlation", window="mixer")
    app.expect_item("main stereo", window="mixer")
    app.click("main integrated", window="mixer")  # starts again
    app.screenshot("mixer_narrow")


def test_eq_switch_io_rows_and_horizontal_sends(app, fixtures):
    mixer(app, fixtures)
    # The EQ: off to start with; its switch on the strip turns it on.
    assert not app.pad(0)["eq_on"]
    app.click("A1 eq switch", window="mixer")
    assert app.pad(0)["eq_on"]
    app.key("cmd+z")
    assert not app.pad(0)["eq_on"]
    # In and out: audio and MIDI in above the pan, MIDI and audio out below.
    for part in ("audio in", "midi in", "midi out", "output"):
        app.expect_item(f"A1 {part}", window="mixer")
    app.click("A1 midi out", window="mixer")
    app.click("Default output (Settings)")
    assert app.pad(0)["midi_out"], app.pad(0)
    # A send: dragged across (right: more).
    app.click("Inserts: each strip's effects (click one to edit it below, drag to reorder)", window="mixer")
    app.click("EQ: each strip's EQ curve (click it to edit below)", window="mixer")
    before = app.pad(0)["sends"][0]
    app.drag_by("A1 send A", 40, 0, window="mixer")
    assert app.pad(0)["sends"][0] > before, (before, app.pad(0)["sends"][0])
