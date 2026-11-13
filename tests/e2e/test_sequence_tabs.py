"""The Sequence view's two tabs: Notes (the default) and Automation, the
tab kept while moving around the app and saved with the project; the
Automation tab's Line and Curve tools, its menu (a new automation), the
notes shown under the curve or not; a drawn note's chance at 100%."""

import os


def loaded(app, fixtures):
    app.cmd(f"load 0 {os.path.join(fixtures, 'kick.wav')}")
    app.cmd(f"load 1 {os.path.join(fixtures, 'hat.wav')}")
    app.cmd("note 0 0 0.25 1")
    app.cmd("note 1 0.5 0.25 0.7")
    app.cmd("select 0")
    app.panel("Sequence")


def test_notes_is_the_default_and_the_tab_is_kept(app, fixtures, tmp_path):
    loaded(app, fixtures)
    assert app.state()["seq_mode"] == "Notes"
    app.expect_item("lane kind", window="sequence")
    app.click("sequence mode", window="sequence", at=(0.52, 0.5))  # Automation
    assert app.state()["seq_mode"] == "Automation"
    app.expect_item("auto", window="sequence")
    app.expect_item("automation", window="sequence")
    # Elsewhere and back: still Automation.
    app.panel("Mixer")
    app.panel("Sequence")
    app.cmd("slot 2")
    app.cmd("slot 1")
    assert app.state()["seq_mode"] == "Automation"
    app.expect_item("auto", window="sequence")
    # Saved with the project, and opened as it was left.
    project = str(tmp_path / "Tabs.pads")
    app.cmd(f"save_as {project}")
    app.click("sequence mode", window="sequence", at=(0.12, 0.5))  # Notes
    assert app.state()["seq_mode"] == "Notes"
    app.cmd(f"open {project}")
    app.wait(5)
    assert app.state()["seq_mode"] == "Automation"


def test_line_and_curve_tools_and_a_new_automation(app, fixtures):
    loaded(app, fixtures)
    app.click("sequence mode", window="sequence", at=(0.52, 0.5))
    assert app.state()["auto_lane"] == "A1 · Volume"
    # A new automation from the menu: the kick's sampler cutoff (a track, a
    # device, a parameter).
    app.click("automation", window="sequence")
    app.click("new automation")
    app.click("A1  kick")
    app.click("Sound")
    app.click("Cutoff")
    assert app.state()["auto_lane"] == "A1 kick · Sound: Cutoff", app.state()["auto_lane"]
    # Line: a straight line, two points.
    app.tool("Line")
    app.drag_at("auto", (0.1, 0.8), (0.9, 0.2), window="sequence", steps=20)
    s = app.state()
    assert s["points"] == 2 and s["curved"] == 0, (s["points"], s["curved"])
    # Curve: the segment dragged up bends.
    app.tool("Curve")
    app.drag_at("auto", (0.5, 0.5), (0.5, 0.2), window="sequence")
    assert app.state()["curved"] == 1
    app.screenshot("automation_tab")
    # The notes under the curve, off and on.
    app.click("show notes", window="sequence")
    app.screenshot("automation_tab_no_notes")
    app.click("show notes", window="sequence")
    # The menu lists this sequence's automation.
    app.click("automation", window="sequence")
    app.expect_item("A1 kick · Sound: Cutoff")
    app.key("esc")
    # Main's volume, from the menu too (the device page on Filter: the
    # Sample page has a Volume knob of its own).
    app.cmd("panel filter")
    app.click("automation", window="sequence")
    app.click("new automation")
    app.click("Main")
    app.click("Volume")
    assert app.state()["auto_lane"] == "Main · Volume"


def test_a_drawn_note_plays_every_time(app, fixtures):
    loaded(app, fixtures)
    app.tool("Draw")
    app.click("seq", window="sequence", at=(0.7, 0.97))
    s = app.state()
    assert s["notes"] == 3
    assert all(abs(p - 1) < 1e-6 for p in s["chances"]), s["chances"]


def test_a_cc_lane_is_drawn_for_the_selected_pad(app, fixtures):
    loaded(app, fixtures)
    app.click("lane kind", window="sequence")
    app.click("new cc")
    app.click("CC 74 · Cutoff")
    app.expect_item("cclane", window="sequence")
    app.tool("Draw")
    app.drag_at("cclane", (0.05, 0.8), (0.6, 0.2), window="sequence", steps=20)
    s = app.state()
    assert s["ccs"] >= 3, s["ccs"]
    assert s["undo"] == "Draw CC", s["undo"]
    app.key("cmd+z")
    assert app.state()["ccs"] == 0
    # Back to velocity: the notes' bars again.
    app.click("lane kind", window="sequence")
    app.click("Velocity")
    app.expect_item("lane", window="sequence")
