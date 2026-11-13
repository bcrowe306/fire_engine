"""Launcher lanes by mouse: a lane renamed and coloured from its header, a
lane added (the window moves to show it) and a sequence made at its end,
a sequence moved to another lane from its menu and by Option-drag, the
overview moving the window, a lane deleted, undo."""

import os


def two(app, fixtures):
    app.cmd(f"load 0 {os.path.join(fixtures, 'kick.wav')}")
    app.cmd(f"load 1 {os.path.join(fixtures, 'hat.wav')}")
    app.cmd("note 0 0 0.25 1")
    app.cmd("slot 2")
    app.cmd("note 1 0.5 0.25 1")
    app.cmd("slot 1")
    app.panel("Perform")
    app.wait(3)


def lane_of(app, seq):
    return app.state()["seq_lanes"][seq - 1] // 100


def test_rename_add_and_a_new_sequence(app, fixtures):
    two(app, fixtures)
    assert len(app.state()["lanes"]) == 8
    app.click("lane 2", window="perform")
    app.click("lane name")
    app.cmd("key cmd+a")
    app.type("Hats")
    app.key("enter")
    assert app.state()["lanes"][1] == "Hats", app.state()["lanes"]
    assert app.state()["undo"] == "Rename Lane"
    app.click("add a lane", window="perform")
    s = app.state()
    assert len(s["lanes"]) == 9 and s["window"] == [6, 1], (s["lanes"], s["window"])
    app.click("lane 9 plus", window="perform")
    assert lane_of(app, app.state()["slot"]) == 9, app.state()["seq_lanes"]
    app.screenshot("lanes_added")
    app.key("cmd+z")  # (the new sequence's move)
    app.key("cmd+z")  # the lane
    assert len(app.state()["lanes"]) == 8


def test_move_by_menu_and_by_option_drag(app, fixtures):
    two(app, fixtures)
    app.click("launch 2", window="perform", right=True)
    app.click("Move to the Lane Before")
    assert lane_of(app, 2) == 1 and app.state()["undo"] == "Move Sequence"
    # Back by Option-drag: sequence 2 onto lane 3's bottom row.
    app.key("cmd+z")
    assert lane_of(app, 2) == 2
    app.cmd("hold alt")
    app.drag("launch 2", "launch 3", from_window="perform", to_window="perform")
    app.cmd("let alt")
    assert lane_of(app, 2) == 3, app.state()["seq_lanes"]


def test_overview_and_delete(app, fixtures):
    two(app, fixtures)
    app.click("lane map", window="perform", at=(0.95, 0.9))
    assert app.state()["window"][0] == 5, app.state()["window"]
    app.click("window left", window="perform")
    app.click("window left", window="perform")
    app.click("window left", window="perform")
    app.click("window left", window="perform")
    app.click("lane 2", window="perform")
    app.click("delete lane")
    s = app.state()
    assert len(s["lanes"]) == 7 and lane_of(app, 2) == 1, s["seq_lanes"]
    assert s["undo"] == "Delete Lane"
