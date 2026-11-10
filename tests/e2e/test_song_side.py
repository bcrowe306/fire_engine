"""The Song tab's sidebar: the sequences in use, added to the song by
double-click or +, dragged onto a step (before it) or the end, edited by
a click, their commands by right-click."""

import os


def two(app, fixtures):
    app.cmd(f"load 0 {os.path.join(fixtures, 'kick.wav')}")
    app.cmd("note 0 0 0.25 1")
    app.cmd("slot 2")
    app.cmd("note 0 1 0.25 1")
    app.cmd("slot 1")
    app.panel("Song")


def test_build_a_song_from_the_sidebar(app, fixtures):
    two(app, fixtures)
    app.expect_item("song seq 1", window="song")
    app.click("song seq 2", window="song", double=True)
    assert app.state()["song"] == [2]
    app.click("Add Sequence 1 to the song's end", window="song")
    assert app.state()["song"] == [2, 1]
    app.drag("song seq 1", "song step 1", from_window="song", to_window="song")  # before the first
    assert app.state()["song"] == [1, 2, 1]
    app.drag("song seq 2", "song end", from_window="song", to_window="song")
    assert app.state()["song"] == [1, 2, 1, 2]
    app.screenshot("song")
    app.click("song seq 2", window="song")  # a click edits it
    assert app.state()["slot"] == 2
    app.click("song seq 2", window="song", right=True)
    app.click("Rename…")
    app.expect_item("sequence rename")
    app.key("esc")
    app.key("cmd+z")
    assert app.state()["song"] == [1, 2, 1]
