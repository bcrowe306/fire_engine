"""The song's time on the Song tab, by mouse and keys: a loop range dragged
along the ruler, a marker made by double-clicking the strip above it and
renamed, markers gone to with Alt+arrows, a time signature change made on
its lane, a tempo point made on the tempo lane (the project's tempo the
first), and undo."""

import os


def song_of_two(app, fixtures):
    app.cmd(f"load 0 {os.path.join(fixtures, 'kick.wav')}")
    app.cmd("note 0 0 0.25 1")
    app.cmd("song add 1 4")
    app.cmd("song add 1 4")  # 32 beats, 8 bars
    app.panel("Song")
    app.cmd("song zoom 20")  # a bar: 80 points
    app.wait(3)


def at(app, label, beat):
    """Where beat `beat` is across item `label`, as a fraction of it."""
    r = [i for i in app.items(label, "song") if i["label"] == label][0]["rect"]
    return (r[0] + beat * 20 - r[0]) / (r[2] - r[0])


def test_loop_range_markers_and_tempo(app, fixtures):
    song_of_two(app, fixtures)
    # Bars 3 to 6 dragged on the ruler.
    app.drag_at("song ruler", (at(app, "song ruler", 9), 0.5), (at(app, "song ruler", 21), 0.5), window="song")
    lo, hi = app.state()["song_loop"]
    assert lo == 8 and hi == 24, (lo, hi)
    assert app.state()["undo"] == "Loop Range"
    # A marker: double-click the strip; its name box opens.
    app.click("song markers", window="song", double=True, at=(at(app, "song markers", 17), 0.5))
    app.wait(3)
    app.expect_item("marker name")
    app.key("cmd+a")
    app.type("Chorus")
    app.key("enter")
    app.wait(3)
    s = app.state()
    assert s["markers"] == ["Chorus"], s["markers"]
    assert s["marker_beats"][0] == 16, s["marker_beats"]
    # Alt+Right goes there (stopped: where play starts); Alt+Left back.
    app.key("alt+right")
    assert app.state()["cue"] == 16
    app.key("alt+left")
    assert app.state()["cue"] == 0
    # A time signature change: double-click its lane at bar 5, pick 3/4.
    app.click("time signature lane", window="song", double=True, at=(at(app, "time signature lane", 17), 0.5))
    app.click("3/4")
    assert app.state()["meters"] == [[16, 3, 4]], app.state()["meters"]
    app.key("cmd+z")
    assert app.state()["meters"] == []
    # The tempo lane: a point (the project's tempo becomes the first).
    app.click("Tempo lane", window="song")  # it shows
    app.click("tempo lane", window="song", double=True, at=(at(app, "tempo lane", 16), 0.2))
    pts = app.state()["tempo_points"]
    assert len(pts) == 2 and pts[0][0] == 0 and pts[1][1] > pts[0][1], pts
    app.key("cmd+z")
    assert app.state()["tempo_points"] == []
    app.expect_item("tempo lane", window="song")  # (still shown: it was asked for)
    app.screenshot("song_time")
