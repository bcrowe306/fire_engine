"""The Sample tab's waveform by mouse: the start and end tags drag (not
only their lines), fade handles drag in from the ends, a playhead runs
while the pad plays; and the channel strip at the bottom panel's right."""

import os


def loop_on_a1(app, fixtures):
    app.cmd(f"load 0 {os.path.join(fixtures, 'loop.wav')}")  # 2 s at 44.1 kHz: 88200 frames
    app.cmd("select 0")
    app.click("Sample", window="detail")
    app.expect_item("wave", window="detail")


def wave_rect(app):
    return [i for i in app.items("wave", "detail") if i["label"] == "wave"][0]["rect"]


def drag_points(app, a, b):
    app.cmd(f"drag {a[0]} {a[1]} {b[0]} {b[1]} 12")
    app.wait(3)


def test_the_start_and_end_tags_drag(app, fixtures):
    loop_on_a1(app, fixtures)
    x0, y0, x1, y1 = wave_rect(app)
    w = x1 - x0
    # The S tag hangs right of the start line, at the top.
    drag_points(app, (x0 + 8, y0 + 8), (x0 + 8 + w * 0.25, y0 + 8))
    p = app.pad(0)
    assert 0.2 * 88200 < p["start"] < 0.3 * 88200, p["start"]
    assert app.state()["undo"] == "Move Marker"
    # The E tag hangs left of the end line.
    drag_points(app, (x1 - 8, y0 + 8), (x1 - 8 - w * 0.25, y0 + 8))
    p = app.pad(0)
    assert 0.7 * 88200 < p["end"] < 0.8 * 88200, p["end"]


def test_fade_handles_drag_in_from_the_ends(app, fixtures):
    loop_on_a1(app, fixtures)
    x0, y0, x1, y1 = wave_rect(app)
    w = x1 - x0
    row = y0 + 24 + 5  # the fade handles' row, under the tags
    drag_points(app, (x0 + 1, row), (x0 + w * 0.1, row))
    p = app.pad(0)
    assert 0.07 * 88200 < p["fade_in"] < 0.13 * 88200, p["fade_in"]
    assert app.state()["undo"] == "Fade In"
    drag_points(app, (x1 - 1, row), (x1 - w * 0.2, row))
    p = app.pad(0)
    assert 0.17 * 88200 < p["fade_out"] < 0.23 * 88200, p["fade_out"]
    app.key("cmd+z")
    assert app.pad(0)["fade_out"] == 0


def test_a_playhead_runs_while_it_plays(app, fixtures):
    loop_on_a1(app, fixtures)
    assert app.pad(0)["playhead"] == -1
    app.cmd("hit 0")
    app.wait(20)
    first = app.pad(0)["playhead"]
    app.wait(20)
    second = app.pad(0)["playhead"]
    assert 0 < first < second, (first, second)
    app.screenshot("playhead")


def test_the_bottom_panels_strip(app, fixtures):
    loop_on_a1(app, fixtures)
    app.expect_item("A1 fader", window="detail")
    app.click("A1 mute", window="detail")
    assert app.pad(0)["mute"]
    app.drag_by("A1 fader", 0, 40, window="detail")
    assert app.pad(0)["volume"] < -3
    app.click("pad A2", window="detail")  # it follows the selection
    app.expect_item("A2 fader", window="detail")
