"""Automation drawn as a person draws it: freehand with the Draw tool, a
straight line with Shift, a segment bent into a curve with Ctrl, points
swept away with Erase, all on the selected pad's lane; and the editor's
Snap toggle (off: notes and points go anywhere)."""

import os


def lane(app, fixtures):
    app.cmd(f"load 0 {os.path.join(fixtures, 'kick.wav')}")
    app.cmd("note 0 0 0.25 1")
    app.panel("Sequence")
    app.click("Automation", window="sequence")
    app.expect_item("auto", window="sequence")


def test_draw_bend_and_erase(app, fixtures):
    lane(app, fixtures)
    app.tool("Draw")
    app.drag_at("auto", (0.1, 0.8), (0.6, 0.2), window="sequence", steps=24)  # freehand
    drawn = app.state()["points"]
    assert drawn >= 4, drawn
    app.key("cmd+z")  # the stroke is one step
    assert app.state()["points"] == 0
    app.cmd("hold shift")
    app.drag_at("auto", (0.1, 0.8), (0.9, 0.2), window="sequence", steps=24)  # a straight line
    app.cmd("let shift")
    assert app.state()["points"] == 2
    assert app.state()["curved"] == 0
    app.cmd("hold ctrl")
    app.drag_at("auto", (0.5, 0.5), (0.5, 0.15), window="sequence")  # bend it
    app.cmd("let ctrl")
    assert app.state()["curved"] == 1
    app.screenshot("automation_curve")
    app.tool("Erase")
    app.drag_at("auto", (0.02, 0.5), (0.98, 0.5), window="sequence", steps=30)
    assert app.state()["points"] == 0


def snap_on(app):
    """The Snap toggle's label while on (it names the key held to place freely)."""
    return next(i["label"] for i in app.items("Snap: on", "sequence") if i["label"].startswith("Snap: on"))


def test_snap_off_places_anywhere(app, fixtures):
    lane(app, fixtures)
    assert app.state()["snap"]
    app.click(snap_on(app), window="sequence")
    assert not app.state()["snap"]
    app.expect_item("Snap: off (anywhere)", window="sequence")
    app.click("Snap: off (anywhere)", window="sequence")
    assert app.state()["snap"]
