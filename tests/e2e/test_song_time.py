"""The song's time on the Song tab, by mouse and keys: a loop range dragged
along the ruler, a marker made by double-clicking the strip above it and
renamed, markers gone to with Alt+arrows, a tempo point made on the tempo
lane (the steps' tempos becoming points), and undo."""

import os


def song_of_two(app, fixtures):
    app.cmd(f"load 0 {os.path.join(fixtures, 'kick.wav')}")
    app.cmd("note 0 0 0.25 1")
    app.cmd("song add 1 4")
    app.cmd("song add 1 4")  # 32 beats, 8 bars
    app.panel("Song")
    app.wait(3)


def test_loop_range_markers_and_tempo(app, fixtures):
    song_of_two(app, fixtures)
    # Bars 3 to 6 dragged on the ruler (its width: 8 bars, and the
    # length's text at the right).
    app.drag_at("song ruler", (0.30, 0.5), (0.62, 0.5), window="song")
    lo, hi = app.state()["song_loop"]
    assert lo == 8 and hi == 24, (lo, hi)
    assert app.state()["undo"] == "Loop Range"
    # A marker: double-click the strip; its name box opens.
    app.click("song markers", window="song", double=True, at=(0.55, 0.5))
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
    # The tempo lane: a point (the steps' tempo becomes the first).
    app.click("Tempo lane", window="song")  # it shows
    app.click("tempo lane", window="song", double=True, at=(0.5, 0.2))
    pts = app.state()["tempo_points"]
    assert len(pts) == 2 and pts[0][0] == 0 and pts[1][1] > pts[0][1], pts
    app.key("cmd+z")
    assert app.state()["tempo_points"] == []
    app.expect_item("tempo lane", window="song")  # (still shown: it was asked for)
    app.screenshot("song_time")
