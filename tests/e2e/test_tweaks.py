"""This round's tweaks, by mouse and keys: several pads selected (Shift,
Cmd) and muted, put in a choke group or cleared together; the choke
group in the Sample tab; Stop twice silences everything; the Settings
window; a sample dropped on a sequence row; the lane's height dragged;
the project renamed; buses added, renamed, routed, and several channel
strips edited at once; a pad's warp."""

import os


def loaded(app, fixtures, n=3):
    for i, name in enumerate(["kick.wav", "hat.wav", "loop.wav"][:n]):
        app.cmd(f"load {i} {os.path.join(fixtures, name)}")


def test_several_pads_at_once(app, fixtures):
    loaded(app, fixtures)
    app.click("pad A1", right=True)  # selects it (the menu shows)
    app.key("esc")
    app.cmd("hold shift")
    app.click("pad A3")
    app.cmd("let shift")
    assert app.state()["pad_sel"] == [0, 1, 2]
    app.click("pad A2", right=True)
    app.click("Mute Pads")
    assert all(p["mute"] for p in app.state()["pads"])
    app.click("pad A2", right=True)
    app.click("  Choke Group")
    app.click("choke 2")
    assert all(p["choke"] == 2 for p in app.state()["pads"])
    app.screenshot("pads_selected")
    app.key("cmd+z")
    app.click("pad A2", right=True)
    app.click("Clear Pads")
    assert app.state()["pads"] == []


def test_choke_in_the_sample_tab(app, fixtures):
    loaded(app, fixtures, 1)
    app.click("##choke")
    app.click("Choke group 3###cg3")
    app.expect_item("pad A1")
    assert app.state()["undo"] == "Set Choke Group"


def test_stop_twice_silences(app, fixtures):
    loaded(app, fixtures, 1)
    stop = "Stop (Space); press twice to silence every sound"
    app.click(stop)  # already stopped: everything silenced
    app.click(stop)
    assert app.state()["silences"] >= 2


def test_settings(app, tmp_path):
    app.key("cmd+,")
    app.click("Recording")
    app.click("Count-in clicks with the metronome off")
    prefs = os.path.join(app.tmp, "prefs", "settings.ini")
    assert "count_in_click = false" in open(prefs).read()


def test_a_sample_dropped_on_a_row(app, library):
    app.browse(library)
    app.click("Drums", window="browser")
    app.click("Kicks", window="browser")
    app.panel("Sequence")
    app.drag("Kick 808.wav", "seq row 3", from_window="browser", to_window="sequence")
    s = app.state()
    assert any(p["index"] == 3 for p in s["pads"]) and s["selected"] == 3, s["selected"]


def test_the_lane_is_taller_when_dragged(app, fixtures):
    loaded(app, fixtures, 1)
    app.cmd("note 0 0 0.25 1")
    app.panel("Sequence")
    lane = lambda: [i for i in app.items("lane", "sequence") if i["label"] == "lane"][0]["rect"]
    before = lane()[3] - lane()[1]
    app.drag_by("lane splitter", 0, -60, window="sequence")
    after = lane()[3] - lane()[1]
    assert after > before + 40, (before, after)


def test_renaming_the_project(app, tmp_path):
    app.cmd(f"save_as {tmp_path / 'Old.pads'}")
    app.click("File")
    app.click("  Rename Project…")
    app.key("cmd+a")
    app.type("My Beat")
    app.key("enter")
    assert app.state()["project"].endswith("My Beat.pads")
    assert os.path.exists(tmp_path / "My Beat.pads" / "project.fire")


def test_buses_routing_and_several_strips(app, fixtures):
    loaded(app, fixtures)
    app.panel("Mixer")
    app.cmd("mixer narrow")  # (every bus in sight in the test's window: wide ones scroll)
    app.wait(2)
    app.click("add bus", window="mixer")
    assert len(app.state()["buses"]) == 6  # A..E and main
    app.click("Bus E name", window="mixer", right=True)
    app.click("Rename…")
    app.key("cmd+a")
    app.type("Drums")
    app.key("enter")
    assert app.state()["buses"][4]["name"] == "Drums"
    # Two strips selected: one fader moves both, one route takes both.
    app.click("A1 name", window="mixer")
    app.cmd("hold shift")
    app.click("A2 name", window="mixer")
    app.cmd("let shift")
    app.drag_by("A1 fader", 0, 40, window="mixer")
    p = app.state()["pads"]
    assert p[0]["volume"] < -2 and abs(p[0]["volume"] - p[1]["volume"]) < 0.01 and p[2]["volume"] == 0, [x["volume"] for x in p]
    assert app.state()["undo"] == "Edit Channels"
    app.click("A2 output", window="mixer")
    app.click("Drums###out5")
    p = app.state()["pads"]
    assert p[0]["bus"] == 5 and p[1]["bus"] == 5 and p[2]["bus"] == 0
    # A bus into another (not round in a loop).
    app.click("Bus A output", window="mixer")
    app.click("Drums###bo5")
    assert app.state()["buses"][0]["dest"] == "Drums"
    app.screenshot("buses")


def test_warp(app, fixtures):
    loaded(app, fixtures, 3)
    app.click("pad A3")
    app.click("Warp")
    s = [p for p in app.state()["pads"] if p["index"] == 2][0]
    assert s["warp"] == "Beats" and s["warp_bpm"] > 0, s["warp"]
    app.click("Warp settings")
    app.click("##warpmode")
    app.click("Tones")
    assert [p for p in app.state()["pads"] if p["index"] == 2][0]["warp"] == "Tones"
    app.cmd("tempo 100")  # another tempo: a rendering, then it plays
    app.until(lambda st: [p for p in st["pads"] if p["index"] == 2][0]["warp_ready"], frames=600, what="the warp rendered")
    app.screenshot("warp")


def test_deleting_the_last_note_from_its_menu(app, fixtures):
    """A note's menu: Delete Note on the sequence's last note (the crash:
    the items after it read the note that was gone)."""
    loaded(app, fixtures, 1)
    for b in range(4):
        app.cmd(f"note 0 {b} 0.25 1")
    app.panel("Sequence")
    # Pad A1's row (the bottom), beat 3's note: the last in the list.
    app.click("seq", window="sequence", right=True, at=(0.80, 0.97))
    app.click("Delete Note")
    assert app.state()["notes"] == 3
    app.cmd("wait 2")  # alive
