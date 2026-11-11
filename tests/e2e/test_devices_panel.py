"""The Devices panel (a tab beside the Browser): devices dragged onto pads
(an effect into the first empty insert, an instrument made the pad's, a
synth preset loaded), double-clicked for the selected pad, found by
typing. And the Perform panel's sequence pads: launched, held (back to
the one before when let go), their banks, the pad keys playing them."""

import os


def devices(app):
    app.click("  Devices")
    app.wait(3)


def test_drag_devices_onto_pads(app, fixtures):
    app.cmd(f"load 0 {os.path.join(fixtures, 'kick.wav')}")
    devices(app)
    app.drag("device Reverb", "pad A1", to_window="detail")
    assert app.pad(0)["inserts"][0] == "Reverb", app.pad(0)["inserts"]
    assert app.state()["detail_tab"] == "Effect"  # opened in front
    app.drag("device Delay", "pad A1", to_window="detail")
    assert app.pad(0)["inserts"][1] == "Delay"
    app.drag("device Synth", "pad A2", to_window="detail")
    assert app.pad(1)["kind"] == "Synth"
    app.drag("device Wobble Bass", "pad A3", to_window="detail")
    p = app.pad(2)
    assert p["kind"] == "Synth" and p["synth"]["preset"] == "Wobble Bass", p["kind"]
    assert app.state()["undo"] == "Load Preset"
    app.key("cmd+z")  # one step: the pad empty again
    assert not any(x["index"] == 2 for x in app.state()["pads"])
    # Typed: only what matches.
    app.click("device filter")
    app.type("chor")
    app.wait(2)
    app.expect_item("device Chorus")
    app.expect_no_item("device Reverb")
    app.screenshot("devices")


def test_sequence_pads_launch_and_hold(app, fixtures):
    app.cmd(f"load 0 {os.path.join(fixtures, 'kick.wav')}")
    app.cmd("note 0 0 1 1")
    app.cmd("slot 2")
    app.cmd("note 0 0 1 1")
    app.cmd("slot 1")
    app.panel("Perform")
    app.click("launch quantize", window="perform", at=(0.9, 0.5))  # Now
    assert app.state()["launch"] == "Now"
    app.click("launch 2", window="perform")  # stopped: it plays from there
    app.until(lambda s: s["playing"] and s["slot"] == 2, what="sequence 2 playing")
    # Hold: while held only.
    app.click("launch mode", window="perform", at=(0.75, 0.5))
    assert app.state()["launch_hold"]
    app.cmd('hover_item "launch 1" in perform')
    app.cmd("down")
    app.wait(3)
    assert app.state()["slot"] == 1
    app.cmd("up")
    app.wait(3)
    assert app.state()["slot"] == 2  # back to the one before
    # The banks: B shows sequences 17 to 32.
    app.click("sequence bank", window="perform", at=(0.375, 0.5))
    assert app.state()["seq_bank"] == 1
    app.expect_item("launch 17", window="perform")
    app.screenshot("sequence_pads")
