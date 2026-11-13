"""The latest tweaks by mouse: a new project's count-in (a bar) and click
(on, while recording); an audio track's Monitor from its strip (the
bottom area's and the mixer's); the toolbar's play mode; the Sample
button latched by Ctrl-click (a right-click on a Mac) or Cmd-click; an empty pad's Hold to Record; the
sequence's own arrows."""

import os


def test_new_project_defaults(app):
    s = app.state()
    assert s["count_in"] == 1, s["count_in"]
    assert s["metronome"]


def test_monitor_from_the_strips(app):
    app.click("pad A2", window="detail")
    app.click("Global", window="detail")
    app.click("Audio", window="detail")
    assert app.pad(1)["monitor"] == "Off"  # (a new pad's)
    app.click("A2 monitor", window="detail")
    app.click("monitor In")
    assert app.pad(1)["monitor"] == "In"
    app.panel("Mixer")
    app.click("A2 monitor", window="mixer")
    app.click("monitor Off")
    assert app.pad(1)["monitor"] == "Off"
    assert app.state()["undo"] == "Monitor"


def test_toolbar_play_mode_and_sequence_arrows(app, fixtures):
    app.click("toolbar play mode")
    app.click("Keyboard")
    assert app.state()["play_mode"] == "Keyboard", app.state()["play_mode"]
    app.panel("Sequence")
    app.click("sequence after", window="sequence")
    assert app.state()["slot"] == 2
    app.click("sequence before", window="sequence")
    assert app.state()["slot"] == 1


def test_sample_latch_and_hold_to_record(app):
    tip = "Sample: on, the next pad you press records while you hold it"
    app.click("Sample settings")
    app.click("Arm")
    app.key("esc")
    app.click(tip, right=True)  # (Ctrl-click on a Mac: a right-click)
    s = app.state()
    assert s["sample_latched"] and s["sample_armed"], s
    app.click(tip)  # a click: off
    s = app.state()
    assert not s["sample_latched"] and not s["sample_armed"], s
    # An empty pad's Hold to Record: recording while held.
    app.click("pad A3", window="detail")
    app.cmd('hover_item "Hold to Record" in detail')
    app.cmd("down")
    app.until(lambda s: s["sampling"] == 2, what="recording into A3")
    app.cmd("up")
    app.until(lambda s: s["sampling"] == -1, what="stopped")


def test_cmd_click_latches_too(app):
    tip = "Sample: on, the next pad you press records while you hold it"
    app.click("Sample settings")
    app.click("Arm")
    app.key("esc")
    app.cmd("hold cmd")
    app.click(tip)
    app.cmd("let cmd")
    assert app.state()["sample_latched"]
    # A take: still armed for the next pad.
    app.drag_by("pad A4", 0, 0, window="detail", steps=40)
    app.until(lambda s: any(p["index"] == 3 for p in s["pads"]), what="a sample on A4")
    assert app.state()["sample_armed"], "latched: on for the next one"


def test_every_pad_has_its_input_and_monitor(app, fixtures):
    app.cmd(f"load 0 {os.path.join(fixtures, 'kick.wav')}")
    app.click("pad A1", window="detail")  # a sampler
    app.click("A1 monitor", window="detail")
    app.click("monitor In")
    assert app.pad(0)["monitor"] == "In"
    app.click("A1 audio in", window="detail")
    app.click("In 2")
    assert app.pad(0)["input"] == "In 2", app.pad(0)["input"]
    app.panel("Mixer")
    app.expect_item("A1 monitor", window="mixer")
    app.expect_item("A1 audio in", window="mixer")


def test_no_input(app, fixtures):
    app.cmd(f"load 0 {os.path.join(fixtures, 'kick.wav')}")
    app.click("pad A1", window="detail")
    app.click("A1 audio in", window="detail")
    app.click("No input")
    assert app.pad(0)["input"] == "No input", app.pad(0)["input"]
    assert app.state()["undo"] == "Set Input"
