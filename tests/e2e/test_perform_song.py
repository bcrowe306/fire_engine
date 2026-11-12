"""The Perform panel (play modes, repeat, arpeggiator, performance effects)
and the Song tab, by mouse."""

import os


def test_play_modes_repeat_and_arp_on_the_pads_midi_page(app, fixtures):
    app.cmd(f"load 0 {os.path.join(fixtures, 'kick.wav')}")
    app.cmd("select 0")
    app.cmd("panel midi")  # the pad's MIDI page, first in its chain
    app.wait(3)
    assert app.state()["detail_tab"] == "MIDI"
    app.click("Keyboard", window="detail")
    assert app.state()["play_mode"] == "Keyboard"
    app.click("Pads", window="detail")
    assert app.state()["play_mode"] == "Pads"
    app.click("Repeat", window="detail")
    assert app.pad(0)["repeat"], app.pad(0)
    app.click("Arpeggiate", window="detail")  # (repeat off)
    p = app.pad(0)
    assert p["arp"] and not p["repeat"], p
    app.click("##arp_mode", window="detail")
    app.click("Down")
    assert app.state()["undo"] == "Arpeggiator"
    app.expect_item("steps", window="detail")  # the arpeggiator's steps
    app.screenshot("midi_page")


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
    app.click("Add Sequence 1 at the end of the first lane", window="song")
    app.click("Add Sequence 1 at the end of the first lane", window="song")
    assert app.state()["song_clips"] == 2
    app.click("Song", window="##toolbar")  # the Pattern | Song switch
    assert app.state()["song_mode"]
    app.click("Loop: on (it goes round)")  # the transport's loop: the song's too
    assert not app.state()["loop"]
    app.click("Pattern", window="##toolbar")
    assert not app.state()["song_mode"]
    app.expect_item("clip 2", window="song")
