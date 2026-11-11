"""What makes it an app: the arrow keys moving between pads, Keyboard
mode's banks reaching the bottom of the MIDI range, the status bar, Edit >
History, MIDI files out and in, a new pad's own colour."""

import os


def test_arrow_keys_move_between_pads(app, fixtures):
    app.cmd(f"load 0 {os.path.join(fixtures, 'kick.wav')}")
    app.click("pad A1", window="detail")  # (the pad grid: Up and Down move up and down it)
    app.key("right")
    assert app.state()["selected"] == 1
    app.key("up")
    assert app.state()["selected"] == 5  # the pad above
    app.key("left")
    assert app.state()["selected"] == 4
    app.key("down")
    app.key("down")  # under A1: the last bank's top row (round the grid)
    assert app.state()["selected"] == (4 - 8) % 128, app.state()["selected"]
    app.cmd("select 15")
    app.key("right")  # past A16: B1, its bank shown
    s = app.state()
    assert s["selected"] == 16 and s["bank"] == 1, (s["selected"], s["bank"])


def test_keyboard_banks_reach_the_bottom(app, fixtures):
    app.cmd(f"load 0 {os.path.join(fixtures, 'kick.wav')}")
    app.cmd("select 0")
    app.cmd("mode keys")
    app.wait(3)
    s = app.state()
    assert "C3" in s["keyboard"] and s["bank"] > 0, (s["bank"], s["keyboard"])  # it opens on C3's bank
    app.click("A", window="detail")
    assert app.state()["keyboard"][0] == "C-2"  # bank A: the bottom of the MIDI range
    app.cmd("mode pads")
    assert app.state()["bank"] == 0  # the pads' own bank again


def test_the_status_bar(app, fixtures):
    app.cmd(f"load 0 {os.path.join(fixtures, 'kick.wav')}")
    app.cmd("select 0")
    for item in ("status engine", "status load", "status track"):
        app.expect_item(item, window="##statusbar")
    app.screenshot("status_bar")


def test_edit_history_jumps_back(app, fixtures):
    for k in range(3):
        app.cmd(f"load {k} {os.path.join(fixtures, 'kick.wav')}")
    assert len(app.state()["pads"]) == 3
    app.click("Edit")
    app.click("History")
    app.click("history 1")  # just after the first
    assert len(app.state()["pads"]) == 1
    app.click("Edit")
    app.click("History")
    app.click("history redo 2")  # the furthest redo: all three again
    assert len(app.state()["pads"]) == 3


def test_midi_files_out_and_in(app, fixtures, tmp_path):
    app.cmd(f"load 0 {os.path.join(fixtures, 'kick.wav')}")
    app.cmd("note 0 0 1 1")
    app.cmd("note 0 2 1 1")
    out = str(tmp_path / "seq.mid")
    app.cmd(f"export_midi 1 {out}")
    assert os.path.getsize(out) > 20
    app.cmd("slot 2")
    app.cmd(f"import_midi {out}")
    assert len(app.state()["note_list"]) == 2


def test_new_pads_get_their_own_colours(app, fixtures):
    for k in range(3):
        app.cmd(f"load {k} {os.path.join(fixtures, 'kick.wav')}")
    colours = {p["color"] for p in app.state()["pads"]}
    assert len(colours) == 3, colours


def test_metronome_sound_and_templates(app, fixtures):
    app.click("Metronome settings", window="##toolbar")
    app.click("metronome sound", at=(0.9, 0.5))  # Cowbell
    assert app.state()["metro_click"] == 3
    app.key("escape")
    # A template saved, then a new project from it: its pad with it.
    app.cmd(f"load 0 {os.path.join(fixtures, 'kick.wav')}")
    app.cmd("template save Kick Start")
    app.click("File")
    app.click("New from Template")
    app.click("Kick Start")
    assert app.pad(0)["name"] == "kick" and app.state()["metro_click"] == 3


def test_about_box_shows_the_version(app):
    app.click("Help")
    app.click("menu about")
    app.wait(3)
    app.expect_item("copy version")
    assert app.state()["version"].startswith("0.1.0-dev"), app.state()["version"]
    app.click("about close")
    app.wait(3)
    app.expect_no_item("copy version")
