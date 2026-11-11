"""The Song tab arranged: steps that play part of a sequence, muted,
transposed or at their own tempo, set in the step panel on the right; the
timeline above (its total time, a click on the ruler plays from there);
arrangements, each a song of its own; and sequences' colours."""

import os


def song(app, fixtures):
    app.cmd(f"load 0 {os.path.join(fixtures, 'kick.wav')}")
    app.cmd("note 0 0 0.25 1")
    app.cmd("slot 2")
    app.cmd("note 0 1 0.25 1")
    app.cmd("slot 1")
    app.panel("Song")
    app.click("song seq 1", window="song", double=True)
    app.click("song seq 2", window="song", double=True)
    assert app.state()["song"] == [1, 2]


def test_a_step_plays_its_way(app, fixtures):
    song(app, fixtures)
    assert app.state()["song_seconds"] == 4  # two bars at 120
    app.click("song step 2", window="song")
    assert app.state()["song_selected"] == 2
    app.click("Mute", window="song")
    assert app.state()["steps"][1]["mute"]
    app.drag_by("Length", 0, 40, window="song")  # shorter: part of it
    st = app.state()["steps"][1]
    assert st["length"] < 4, st
    app.drag_by("Transpose", 0, -30, window="song")
    assert app.state()["steps"][1]["transpose"] > 0
    app.click("Own tempo", window="song")
    assert app.state()["steps"][1]["bpm"] == 120
    app.click("##steplabel", window="song")
    app.type("Drop")
    app.key("enter")
    assert app.state()["steps"][1]["label"] == "Drop"
    app.screenshot("song_step")
    app.click("song step 1", window="song")
    assert app.state()["song_selected"] == 1


def test_the_timeline_plays_from_a_bar(app, fixtures):
    song(app, fixtures)
    app.click("song ruler", window="song", at=(0.6, 0.5))  # in bar 2
    s = app.state()
    assert s["playing"] and s["song_mode"]
    app.until(lambda s: s["song_step"] == 2, what="the second step playing")
    app.screenshot("song_playing")
    app.click("Stop (Space); press twice to silence every sound")
    app.click("song timeline", window="song", at=(0.1, 0.5))
    assert app.state()["song_selected"] == 1


def test_arrangements(app, fixtures):
    song(app, fixtures)
    app.click("##arrangement", window="song", right=True)
    app.click("  Duplicate")
    s = app.state()
    assert s["arrangements"] == ["Song", "Song copy"] and s["arrangement"] == 2
    app.click("song step 1", window="song", right=True)
    app.click("Remove from Song")
    assert app.state()["song"] == [2]
    app.click("##arrangement", window="song")
    app.click("Song###arr0")
    s = app.state()
    assert s["arrangement"] == 1 and s["song"] == [1, 2]  # each its own
    app.key("cmd+z")
    assert app.state()["arrangement"] == 2


def test_sequence_colours(app, fixtures):
    song(app, fixtures)
    before = app.state()["sequences"][0]["color"]
    app.click("song seq 1", window="song", right=True)
    app.hover("Colour")
    app.click("colour 1")
    after = app.state()["sequences"][0]["color"]
    assert after != before and after == 0xff5f57
    app.key("cmd+z")
    assert app.state()["sequences"][0]["color"] == before
