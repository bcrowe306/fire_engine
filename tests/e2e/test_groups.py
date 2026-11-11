"""Track groups, by mouse and keys: pads selected and grouped (Cmd+G; its
name typed), the group's tab folding its pads away and back, ungrouping
from its menu, and undo."""

import os


def test_group_fold_and_ungroup(app, fixtures):
    for i, name in enumerate(("kick.wav", "hat.wav", "loop.wav")):
        app.cmd(f"load {i} {os.path.join(fixtures, name)}")
    app.panel("Mixer")
    app.wait(3)
    app.click("A1 name", window="mixer")
    app.cmd("hold shift")
    app.click("A2 name", window="mixer")
    app.cmd("let shift")
    assert app.state()["pad_sel"] == [0, 1]
    app.key("cmd+g")
    app.wait(3)
    app.key("cmd+a")
    app.type("Drums")
    app.key("enter")
    app.wait(3)
    s = app.state()
    assert s["undo"] in ("Rename Bus", "Group Pads"), s["undo"]
    app.expect_item("group Drums", window="mixer")
    app.expect_item("A1 name", window="mixer")
    app.click("group Drums", window="mixer")  # folded
    app.expect_no_item("A1 name", window="mixer")
    app.expect_item("A3 name", window="mixer")
    app.click("group Drums", window="mixer")  # open again
    app.expect_item("A2 name", window="mixer")
    app.screenshot("groups")
    app.click("group Drums", window="mixer", right=True)
    app.click("Ungroup")
    app.wait(3)
    app.expect_no_item("group Drums", window="mixer")
    app.key("cmd+z")
    app.wait(3)
    app.expect_item("group Drums", window="mixer")
