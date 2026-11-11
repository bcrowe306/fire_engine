"""Playing live from the Perform panel: launching sequences (and when
they take over), performance effects played as hard as where they are
pressed (and their own intensity), the toolbar's play modes."""

import os


def two(app, fixtures):
    app.cmd(f"load 0 {os.path.join(fixtures, 'kick.wav')}")
    app.cmd(f"load 1 {os.path.join(fixtures, 'hat.wav')}")
    app.cmd("note 0 0 0.25 1")
    app.cmd("slot 2")
    app.cmd("note 1 0 0.25 1")
    app.cmd("slot 1")
    app.panel("Perform")


def test_launch_sequences(app, fixtures):
    two(app, fixtures)
    app.expect_item("launch 1", window="perform")
    app.expect_item("new sequence", window="perform")
    app.click("launch 2", window="perform")  # stopped: it starts playing
    s = app.state()
    assert s["playing"] and s["slot"] == 2, (s["playing"], s["slot"])
    app.click("##launch_at", window="##toolbar")  # the launch setting, in the toolbar
    app.click("Sequence end")
    assert app.state()["launch"] == "End"
    app.click("launch 1", window="perform")
    assert app.state()["queued"] == 1  # it waits for the bar's end
    app.screenshot("queued")
    app.until(lambda s: s["slot"] == 1 and s["queued"] == 0, frames=240, what="the switch at the sequence's end")
    app.key("space")
    app.click("launch 2", window="perform", right=True)  # its menu
    app.click("Duplicate")
    assert app.state()["slot"] == 3


def test_effects_play_as_hard_as_pressed(app, fixtures):
    two(app, fixtures)
    app.cmd('hover_item "fx 1" in perform at 0.5 0.9')  # low on the pad: gently
    app.wait(2)
    app.cmd("down")
    app.wait(4)
    s = app.state()
    assert s["perf_on"][0] and s["perf_now"][0] < 0.2, s["perf_now"][0]
    app.cmd('hover_item "fx 1" in perform at 0.5 0.1')  # slide up: harder
    app.wait(4)
    assert app.state()["perf_now"][0] > 0.8
    app.screenshot("pressed")
    app.cmd("up")
    app.wait(3)
    assert not app.state()["perf_on"][0]
    # Its own intensity, in the Effects tab.
    app.click("fx 1", window="perform", right=True)
    app.click("Edit Effect")
    app.drag_by("Intensity", 0, 40, window="detail")
    assert app.state()["perf_intensity"][0] < 0.8
    assert app.state()["undo"] == "Effect Intensity"


def test_toolbar_play_modes(app, fixtures):
    two(app, fixtures)
    app.panel("Mixer")
    app.click("Play the pads as a keyboard of the selected pad")
    assert app.state()["play_mode"] == "Keyboard"
    app.click("Play the pads as the selected pad at 16 velocities")
    assert app.state()["play_mode"] == "Velocity"
    app.click("Play the pads as pads (each its sound)")
    assert app.state()["play_mode"] == "Pads"
