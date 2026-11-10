"""The sequencer by mouse and keys: transport, notes in the piano roll,
length, recording, the lanes."""

import os


def loaded(app, fixtures):
    app.cmd(f"load 0 {os.path.join(fixtures, 'kick.wav')}")
    app.cmd(f"load 1 {os.path.join(fixtures, 'hat.wav')}")
    app.wait(3)


def test_play_stop_and_the_metronome(app, fixtures):
    loaded(app, fixtures)
    app.click("Play (Space)")  # on the transport toolbar
    assert app.state()["playing"]
    app.click("Stop (Space)")
    assert not app.state()["playing"]
    app.key("space")
    assert app.state()["playing"]
    app.key("space")
    app.click("Metronome")
    assert app.state()["metronome"]


def test_notes_by_clicking_the_piano_roll(app, fixtures):
    loaded(app, fixtures)
    app.click("seq", window="sequence", at=(0.5, 0.97))  # the bottom row (A1), mid-bar
    s = app.state()
    assert s["notes"] == 1 and s["undo"] == "Add Note"
    app.click("seq", window="sequence", at=(0.75, 0.91))  # A2, the next row up
    assert app.state()["notes"] == 2
    app.key("cmd+z")
    assert app.state()["notes"] == 1
    app.key("cmd+shift+z")
    assert app.state()["notes"] == 2
    app.click("seq", window="sequence", at=(0.5, 0.97), right=True)  # right-click deletes
    assert app.state()["notes"] == 1


def test_length_double_and_clear(app, fixtures):
    loaded(app, fixtures)
    app.click("seq", window="sequence", at=(0.3, 0.97))
    app.click("×2", window="sequence")
    s = app.state()
    assert s["bars"] == 2 and s["notes"] == 2
    app.click("Clear the sequence", window="sequence")
    assert app.state()["notes"] == 0


def test_recording_by_playing_the_pads(app, fixtures):
    loaded(app, fixtures)
    app.click("Record (Cmd+R)")
    s = app.state()
    assert s["recording"] and s["playing"]
    for _ in range(3):
        app.key("z")  # A1
        app.wait(15)
    app.key("cmd+r")
    app.key("space")
    assert app.state()["notes"] >= 3


def test_the_lanes(app, fixtures):
    loaded(app, fixtures)
    app.click("seq", window="sequence", at=(0.5, 0.97))
    app.click("Chance", window="sequence")
    app.expect_item("lane", window="sequence")
    app.click("Automation", window="sequence")
    app.click("auto", window="sequence", at=(0.5, 0.5))  # a point on the selected pad's volume
    assert app.state()["points"] == 1
