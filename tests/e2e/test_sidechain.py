"""Sidechain, by mouse: a loop's compressor keyed from the kick (picked
from the Sidechain list, which offers only sources that can't loop),
Listen, and undo."""

import os


def test_compressor_keyed_from_the_kick(app, fixtures):
    app.cmd(f"load 0 {os.path.join(fixtures, 'kick.wav')}")
    app.cmd(f"load 2 {os.path.join(fixtures, 'loop.wav')}")
    app.cmd("insert 2 0 compressor")
    app.cmd("edit_fx pad 2 0")
    app.wait(3)
    app.click("sidechain", window="detail")
    app.wait(2)
    app.expect_no_item("key pad A3")  # (its own output: a loop)
    app.click("key pad A1")
    app.wait(3)
    assert app.state()["undo"] == "Sidechain"
    app.expect_item("Listen", window="detail")
    app.click("Listen", window="detail")
    assert app.state()["undo"] == "Listen to Key"
    app.screenshot("sidechain")
    app.key("cmd+z")
    app.key("cmd+z")
    app.wait(3)
    app.expect_no_item("Listen", window="detail")  # (no key: no Listen)
