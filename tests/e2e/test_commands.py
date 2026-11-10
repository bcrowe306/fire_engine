"""Commands: right-click menus made from one list (pads, notes, the
marked part, sequences, song steps, effect slots, buses, files, knobs),
the palette acting on the selection, and drive scripts running commands
by id."""

import os


def loaded(app, fixtures):
    app.cmd(f"load 0 {os.path.join(fixtures, 'kick.wav')}")
    app.cmd(f"load 1 {os.path.join(fixtures, 'hat.wav')}")
    app.cmd("note 0 0 0.25 1")
    app.cmd("note 1 0.5 0.25 0.8")


def test_a_pads_menu(app, fixtures):
    loaded(app, fixtures)
    app.click("pad A1", window="detail", right=True)
    for item in ("Play", "Mute", "Solo", "Copy Pad", "Duplicate to Next Empty Pad", "Clear Pad", "Colour"):
        app.expect_item(item)
    app.click("Duplicate to Next Empty Pad")
    assert app.pad(2)["name"] == "kick" and app.state()["selected"] == 2
    assert app.state()["undo"] == "Duplicate Pad"
    app.click("pad A2", window="detail", right=True)
    app.click("Copy Pad")
    app.click("pad A5", window="detail", right=True)
    app.click("Paste Pad")
    assert app.pad(4)["name"] == "hat"
    app.click("pad A5", window="detail", right=True)
    app.click("Mute")
    assert app.pad(4)["mute"]


def test_a_notes_menu_and_the_palette(app, fixtures):
    loaded(app, fixtures)
    app.panel("Sequence")
    app.click("seq", window="sequence", at=(0.6, 0.97))  # a note on A1
    app.click("seq", window="sequence", at=(0.6, 0.97), right=True)
    app.click("Velocity 40%")
    assert app.state()["undo"] == "Set Velocity"
    app.click("seq", window="sequence", at=(0.6, 0.97), right=True)
    app.click("Duplicate Note")
    assert app.state()["notes"] == 4
    # The palette acts on the selection: the selected pad.
    app.cmd("select 1")
    app.key("cmd+k")
    app.type("duplicate to next")
    app.key("return")
    assert app.pad(2)["name"] == "hat"


def test_steps_slots_buses_files_and_knobs(app, fixtures, library):
    loaded(app, fixtures)
    app.panel("Song")
    app.click("Add sequence 1", window="song")
    app.click("song step 1", window="song", right=True)
    app.click("Duplicate Step")
    assert app.state()["song_steps"] == 2
    app.panel("Mixer")
    app.click("A1 slot 1", window="mixer", right=True)
    app.expect_item("Paste Effect")
    app.key("esc")
    app.click("Bus A name", window="mixer", right=True)
    app.click("Mute")
    assert app.state()["buses"][0]["mute"]
    # A knob's menu: back to its default.
    app.cmd("select 0")
    app.click("Global", window="detail")
    app.drag_by("Volume", 0, 40, window="detail")
    assert app.pad(0)["volume"] < -3
    app.click("Volume", window="detail", right=True)
    app.click("Reset to Default")
    assert app.pad(0)["volume"] == 0
    # Commands by id, as a control surface would.
    app.cmd("command pad.solo pad 1")
    assert app.pad(1)["solo"]
    app.cmd("command seq.duplicate sequence 0")
    assert app.state()["slot"] == 2
    app.cmd(f"command file.load_empty file {os.path.join(library, 'Drums', 'Closed Hat.wav')}")
    assert any(p["name"] == "Closed Hat" for p in app.state()["pads"])
