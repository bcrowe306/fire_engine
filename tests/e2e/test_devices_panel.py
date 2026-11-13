"""The Library's devices (its Instruments, Effects and Plug-ins sections): devices dragged onto pads
(an effect into the first empty insert, an instrument made the pad's, a
synth preset loaded), double-clicked for the selected pad, found by
typing. And the Perform panel's sequence pads: launched, held (back to
the one before when let go), their banks, the pad keys playing them
(Keys on)."""

import os


def devices(app):
    app.cmd("panel library")  # (the Library is always beside the panels; this shows it if hidden)
    app.wait(3)


def test_drag_devices_onto_pads(app, fixtures):
    app.cmd(f"load 0 {os.path.join(fixtures, 'kick.wav')}")
    devices(app)
    app.library_find("reverb", tab="Devices")
    app.drag("device Reverb", "pad A1", to_window="detail")
    assert app.pad(0)["inserts"][0] == "Reverb", app.pad(0)["inserts"]
    assert app.state()["detail_tab"] == "Effect"  # opened in front
    app.library_find("delay", tab="Devices")
    app.drag("device Delay", "pad A1", to_window="detail")
    assert app.pad(0)["inserts"][1] == "Delay"
    app.library_find("synth", tab="Devices")
    app.drag("device Synth", "pad A2", to_window="detail")
    assert app.pad(1)["kind"] == "Synth"
    app.library_find("wobble", tab="Devices")
    app.drag("device Wobble Bass", "pad A3", to_window="detail")
    p = app.pad(2)
    assert p["kind"] == "Synth" and p["synth"]["preset"] == "Wobble Bass", p["kind"]
    assert app.state()["undo"] == "Load Preset"
    app.key("cmd+z")  # one step: the pad empty again
    assert not any(x["index"] == 2 for x in app.state()["pads"])
    # Typed: only what matches.
    app.library_find("chor", tab="Devices")
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
    # Hold: while held only (sequence 1 in its own column, beside 2).
    app.click("launch mode", window="perform", at=(0.75, 0.5))
    assert app.state()["launch_hold"]
    app.cmd('hover_item "launch 1" in perform')
    app.cmd("down")
    app.wait(3)
    s = app.state()
    assert s["slot"] == 1 and s["columns"][:2] == [1, 2], s["columns"]
    app.cmd("up")
    app.wait(3)
    assert app.state()["columns"][:2] == [0, 2]  # its column back to what it had: nothing
    # The window over the lanes: lanes 5-8 show sequences 5 to 8 at the bottom.
    for _ in range(4):
        app.click("window right", window="perform")
    assert app.state()["window"] == [5, 1], app.state()["window"]
    app.expect_item("launch 5", window="perform")
    app.screenshot("sequence_pads")
    # Keys on: the pad keys play the window's cells (lanes 1-4: z is 1, x is 2).
    for _ in range(4):
        app.click("window left", window="perform")
    app.click("launch mode", window="perform", at=(0.25, 0.5))  # Launch again
    app.click("sequence keys", window="perform")
    app.key("z")
    assert app.state()["slot"] == 1
    app.key("x")
    assert app.state()["slot"] == 2


def test_the_synths_presets_are_folded_under_it(app):
    # One Synth branch: a plain synth, its preset kinds folded under it
    # (opened one at a time), not a branch of the panel each.
    app.cmd("panel devices")
    app.wait(3)
    app.expect_item("devices Synth")
    app.expect_item("device Synth")
    app.expect_item("devices Synth Bass")
    app.expect_no_item("device Wobble Bass")
    app.screenshot("devices_folded")
    app.click("devices Synth Bass")
    app.expect_item("device Wobble Bass")
