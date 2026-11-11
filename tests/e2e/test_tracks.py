"""Tracks' ins and arming, by mouse: the selected track armed (the one
before going back, unless armed by hand; Cmd-click arms more); the setting
off; a track's MIDI input chosen on its strip, and an armed track played by
its own port (its notes counted, its light lit); input meters in Settings
> Audio."""

import os


def loaded(app, fixtures):
    for i, name in enumerate(["kick.wav", "hat.wav", "loop.wav"]):
        app.cmd(f"load {i} {os.path.join(fixtures, name)}")


def armed(app):
    return [p["index"] for p in app.state()["pads"] if p["armed"]]


def test_arming_follows_the_selection(app, fixtures):
    loaded(app, fixtures)
    app.click("pad A1")
    assert armed(app) == [0]
    app.click("pad A2")
    assert armed(app) == [1]
    app.panel("Mixer")
    app.cmd("hold cmd")
    app.click("A1 arm", window="mixer")  # one more, by hand
    app.cmd("let cmd")
    assert armed(app) == [0, 1]
    app.click("pad A3")
    assert armed(app) == [0, 2]  # A1 stays (armed by hand); A2 goes back
    app.screenshot("armed")
    # The setting off: selecting doesn't arm.
    app.key("cmd+,")
    app.click("Recording")
    app.click("Arm the selected track")
    app.key("esc")
    app.click("pad A2")
    assert 1 not in armed(app)


def test_a_tracks_midi_input(app, fixtures):
    loaded(app, fixtures)
    app.panel("Mixer")
    app.click("A2 input", window="mixer")
    app.click("No MIDI")
    assert app.pad(1)["midi_in"] == "No MIDI"
    assert app.state()["undo"] == "MIDI In"
    # Its own port (input 3, in this script's terms), armed: port 3's notes play it.
    app.cmd("midi_in 1 3")
    app.cmd("arm 1 on")
    app.cmd("midi 64 100 3")
    app.wait(3)
    app.cmd("midi 64 0 3")
    app.until(lambda s: [p for p in s["pads"] if p["index"] == 1][0]["midi_in_notes"] == 1, frames=60, what="the note on pad 2")
    app.screenshot("midi_light")
    # Unarmed, nothing.
    app.cmd("arm 1 off")
    app.cmd("midi 64 100 3")
    app.wait(3)
    assert app.pad(1)["midi_in_notes"] == 1


def test_input_meters(app):
    app.key("cmd+,")
    app.click("Audio")
    app.expect_item("input meter 1")
    app.expect_item("input meter 2")
