"""Freeze, by mouse: a pad frozen from its right-click menu (rendered as
an export would be, then played instead), its device page saying so,
Unfreeze from there, undo, and Flatten to Audio."""

import os


def test_freeze_unfreeze_flatten(app, fixtures):
    app.cmd(f"load 0 {os.path.join(fixtures, 'kick.wav')}")
    app.cmd("note 0 0 0.25 1")
    app.cmd("select 0")
    app.click("pad A1", right=True)
    app.click("Freeze")
    app.until(lambda s: s["undo"] == "Freeze", frames=600, what="the freeze")
    app.expect_item("unfreeze", window="detail")
    app.click("unfreeze", window="detail")
    assert app.state()["undo"] == "Unfreeze"
    app.expect_no_item("unfreeze", window="detail")
    app.key("cmd+z")  # frozen again
    app.wait(3)
    app.expect_item("flatten", window="detail")
    app.click("flatten", window="detail")
    s = app.state()
    assert s["undo"] == "Flatten to Audio"
    assert app.pad(0)["kind"] == "Audio", app.pad(0)["kind"]
