"""The transport toolbar, by mouse: transport, loop, count-in, the
sequence, tempo (drag, Shift, tap), the time signature, the metronome's
settings, input quantize. It shows whatever panel or tab is in front."""

import os


def loaded(app, fixtures):
    app.cmd(f"load 0 {os.path.join(fixtures, 'kick.wav')}")
    app.cmd("note 0 0 0.25 1")
    app.wait(3)


def test_it_shows_whatever_is_in_front(app):
    for panel in ("Mixer", "Song", "Sequence"):
        app.panel(panel)
        app.expect_item("Play (Space)")
        app.expect_item("tempo")
    app.panel("Perform")
    app.expect_item("Record (Cmd+R)")


def test_loop_off_plays_once_and_stops(app, fixtures):
    loaded(app, fixtures)
    app.click("Loop: on (it goes round)")
    assert not app.state()["loop"]
    app.click("Play (Space)")
    app.until(lambda s: not s["playing"], frames=240, what="the sequence to end and stop")
    app.key("cmd+z")
    assert app.state()["loop"]


def test_count_in_then_record(app, fixtures):
    loaded(app, fixtures)
    assert app.state()["count_in"] == 1  # (a new project's)
    app.click("Count-in: 1 bar (click to change)")
    assert app.state()["count_in"] == 2
    app.click("Count-in: 2 bars (click to change)")
    assert app.state()["count_in"] == 0
    app.click("Count-in: off (click to change)")
    assert app.state()["count_in"] == 1
    app.click("Record (Cmd+R)")
    s = app.state()
    assert s["recording"] and s["playing"] and s["timeline"] < 0, s["timeline"]
    assert s["position"].startswith("0.")  # the bar before the first
    app.until(lambda s: s["timeline"] >= 0, frames=240, what="the count-in to end")
    app.key("cmd+r")
    app.key("space")


def test_tempo_drags_by_one_and_shift_by_a_tenth(app):
    app.drag_by("tempo", 20, 0)  # 4 points a step: +5
    assert app.state()["bpm"] == 125
    app.cmd("hold shift")
    app.drag_by("tempo", 12, 0)  # with Shift: +0.3
    app.cmd("let shift")
    assert abs(app.state()["bpm"] - 125.3) < 1e-6, app.state()["bpm"]
    app.key("cmd+z")
    app.key("cmd+z")
    assert app.state()["bpm"] == 120


def test_tap_tempo(app):
    for _ in range(4):
        app.click("Tap")  # a click and its wait take 25 frames: 5/12 s at 60 frames a second, 144 BPM
    bpm = app.state()["bpm"]
    assert 135 <= bpm <= 155, bpm
    # The fourth tap starts playback a beat later, where a fifth would land.
    app.until(lambda s: s["playing"], frames=60, what="playback after the fourth tap")
    app.key("space")


def test_tapping_while_playing_only_changes_the_tempo(app):
    app.click("Play (Space)")
    for _ in range(4):
        app.click("Tap")
    s = app.state()
    assert s["playing"] and 135 <= s["bpm"] <= 155, s["bpm"]
    app.wait(60)
    assert app.state()["playing"]
    app.key("space")


def test_time_signature_and_the_sequence(app, fixtures):
    loaded(app, fixtures)
    app.click("##timesig")
    app.click("3/4")
    assert app.state()["time_sig"] == "3/4"
    app.key("esc")
    app.click("Next sequence")
    assert app.state()["slot"] == 2
    app.click("Previous sequence")
    assert app.state()["slot"] == 1


def test_metronome_and_quantize_settings(app):
    assert app.state()["metro_rec_only"]  # (a new project's: the click while recording)
    app.click("Metronome settings")
    app.click("Only while recording")
    assert not app.state()["metro_rec_only"]
    app.click("2 bars")
    assert app.state()["count_in"] == 2
    app.key("esc")
    app.click("Input quantize: off")
    assert app.state()["quantize"]["on"]
    app.click("Input quantize settings")
    app.drag_by("##strength", -60, 0)
    q = app.state()["quantize"]
    assert q["strength"] < 1, q
