"""The Perform panel (play modes, repeat, arpeggiator, performance effects)
and the Song tab, by mouse."""

import os


def test_play_modes_repeat_and_arp(app, fixtures):
    app.cmd(f"load 0 {os.path.join(fixtures, 'kick.wav')}")
    app.panel("Perform")
    app.click("Keyboard", window="perform")
    assert app.state()["play_mode"] == "Keyboard"
    app.click("Pads", window="perform")
    assert app.state()["play_mode"] == "Pads"
    app.click("Repeat", window="perform")
    app.click("Arpeggiate", window="perform")
    app.click("##arp_mode", window="perform")
    app.click("Down")
    assert app.state()["undo"] != ""
    app.expect_item("steps", window="perform")  # the repeat's and the arpeggiator's steps


def test_performance_effects_while_held(app, fixtures):
    app.cmd(f"load 0 {os.path.join(fixtures, 'loop.wav')}")
    app.panel("Perform")
    app.hover("fx 11", window="perform")  # ring mod
    app.wait(2)
    app.cmd("down")
    app.wait(10)
    app.cmd("up")
    app.wait(4)
    app.click("fx 11", window="perform", right=True)  # its menu
    app.click("Edit Effect")
    assert app.state()["detail_tab"] == "Effect" and app.state()["track"] == "perf 11"


def test_the_song(app, fixtures):
    app.cmd(f"load 0 {os.path.join(fixtures, 'kick.wav')}")
    app.cmd("note 0 0 0.25 1")
    app.panel("Song")
    app.click("Add the current sequence", window="song")
    app.click("Add the current sequence", window="song")
    assert app.state()["song_steps"] == 2
    app.click("Song", window="##toolbar")  # the Pattern | Song switch
    assert app.state()["song_mode"]
    app.click("Loop: on (it goes round)")  # the transport's loop: the song's too
    assert not app.state()["loop"]
    app.click("Pattern", window="##toolbar")
    assert not app.state()["song_mode"]
    app.expect_item("song step 2", window="song")
