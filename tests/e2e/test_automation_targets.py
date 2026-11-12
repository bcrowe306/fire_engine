"""Automation of any parameter, as a person adds it: right-clicking a
mixer fader for Automate, touching a knob while learning, and recording
knob moves (only with the Automation arm on) into the sequence."""

import os


def loaded(app, fixtures):
    app.cmd(f"load 0 {os.path.join(fixtures, 'kick.wav')}")
    app.cmd("note 0 0 0.25 1")
    app.cmd("select 0")


def test_right_click_a_fader_to_automate_it(app, fixtures):
    loaded(app, fixtures)
    app.panel("Mixer")
    app.click("A1 fader", window="mixer", right=True)
    app.click("Automate")
    s = app.state()
    assert s["seq_mode"] == "Automation" and s["auto_lane"] == "A1 kick · Volume", (s["seq_mode"], s["auto_lane"])
    app.expect_item("auto", window="sequence")
    # A point drawn there is that automation's.
    app.click("auto", window="sequence", at=(0.5, 0.5))
    assert app.state()["points"] == 1
    # The fader's menu now offers to show it.
    app.panel("Mixer")
    app.click("A1 fader", window="mixer", right=True)
    app.expect_item("Automate")  # (named the same: Show Automation)
    app.key("esc")


def test_touch_a_control_learns_it(app, fixtures):
    loaded(app, fixtures)
    app.panel("Sequence")
    app.click("sequence mode", window="sequence", at=(0.75, 0.5))
    app.click("automation", window="sequence")
    app.click("touch a control")
    app.cmd("panel filter")
    app.wait(3)
    app.drag_by("Cutoff", 0, -20, window="detail")
    s = app.state()
    assert s["auto_lane"] == "A1 kick · Sound: Cutoff", s["auto_lane"]
    assert s["seq_mode"] == "Automation"


def test_knob_moves_are_recorded_only_when_armed(app, fixtures):
    loaded(app, fixtures)
    app.cmd("panel filter")
    app.wait(3)
    # Recording without the arm: the knob only changes the sound.
    app.key("cmd+r")
    app.until(lambda s: s["playing"], frames=600, what="recording starts")
    app.drag_by("Cutoff", 0, -30, window="detail", steps=30)
    app.key("space")
    assert app.state()["points"] == 0
    # Armed: the move is written into the sequence.
    app.click("Record automation: off (knobs only change the sound)", window="##toolbar")
    app.key("cmd+r")
    app.until(lambda s: s["playing"], frames=600, what="recording starts")
    app.drag_by("Cutoff", 0, 40, window="detail", steps=40)
    app.key("space")
    s = app.state()
    assert s["points"] >= 2, s["points"]
    assert s["undo"] == "Draw Automation", s["undo"]
