"""The Perform tab (play modes, repeat, arpeggiator, performance effects)
and the Song tab, by mouse."""

import os


def test_play_modes_repeat_and_arp(app, fixtures):
    app.cmd(f"load 0 {os.path.join(fixtures, 'kick.wav')}")
    app.click("Perform", window="detail")
    app.click("Keyboard", window="detail")
    assert app.state()["play_mode"] == "Keyboard"
    app.click("Pads", window="detail")
    assert app.state()["play_mode"] == "Pads"
    app.click("Repeat", window="detail")
    app.click("Arpeggiate", window="detail")
    app.click("##arp_mode", window="detail")
    app.click("Down")
    assert app.state()["undo"] != ""


def test_performance_effects_while_held(app, fixtures):
    app.cmd(f"load 0 {os.path.join(fixtures, 'loop.wav')}")
    app.click("Perform", window="detail")
    app.reveal("fx 11", "detail", over="Pads")
    app.hover("fx 11", window="detail")  # ring mod
    app.wait(2)
    app.cmd("down")
    app.wait(10)
    app.cmd("up")
    app.wait(4)
    app.click("fx 11", window="detail", right=True)  # right-click edits it
    assert app.state()["detail_tab"] == "Effects"


def test_the_song(app, fixtures):
    app.cmd(f"load 0 {os.path.join(fixtures, 'kick.wav')}")
    app.cmd("note 0 0 0.25 1")
    app.panel("Song")
    app.click("Add sequence 1", window="song")
    app.click("Add sequence 1", window="song")
    assert app.state()["song_steps"] == 2
    app.click("Song", window="song")  # the Pattern | Song switch
    assert app.state()["song_mode"]
    app.click("Loop: on (it goes round)")  # the transport's loop: the song's too
    assert not app.state()["loop"]
    app.click("Pattern", window="song")
    assert not app.state()["song_mode"]
    app.expect_item("song step 2", window="song")
