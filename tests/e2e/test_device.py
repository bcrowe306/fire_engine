"""The sampler's device tabs by mouse: the amp envelope's handles, the
filter's type, slope and response handle (and its curve following what
plays), the pitch envelope, an LFO routed to the cutoff, Global."""

import os

# The state gives enums as numbers.
LOWPASS, SQUARE, TRIGGER, CUTOFF = 1, 4, 1, 4


def loaded(app, fixtures):
    app.cmd(f"load 0 {os.path.join(fixtures, 'loop.wav')}")
    app.cmd("select 0")


def rect(app, label):
    return [i for i in app.items(label, "detail") if i["label"] == label][0]["rect"]


def drag(app, a, b):
    app.cmd(f"drag {a[0]} {a[1]} {b[0]} {b[1]} 12")
    app.wait(3)


def test_the_amp_envelope_drags(app, fixtures):
    loaded(app, fixtures)
    app.click("Env", window="detail")
    x0, y0, x1, y1 = rect(app, "amp envelope")
    p = app.pad(0)
    assert p["voice"]["sustain"] == 1
    # The attack's peak (top left, a millisecond in): right.
    w = x1 - x0
    drag(app, (x0 + 10 + 1, y0 + 10), (x0 + 10 + (w - 20) * 0.25, y0 + 10))
    assert app.pad(0)["attack"] > 0.05, app.pad(0)["attack"]
    assert app.state()["undo"] == "Shape Envelope"
    app.key("cmd+z")
    assert app.pad(0)["attack"] < 0.01


def test_the_filter_type_slope_and_response(app, fixtures):
    loaded(app, fixtures)
    app.click("Filter", window="detail")
    app.click("Low-pass", window="detail")
    v = app.pad(0)["voice"]
    assert v["filter"] == LOWPASS, v["filter"]
    app.click("24 dB", window="detail")
    assert app.pad(0)["voice"]["steep"]
    # The handle sits at the cutoff (20 kHz: the right edge): drag it left
    # and up, to about 1 kHz with resonance.
    x0, y0, x1, y1 = rect(app, "filter response")
    h = (x1 - 8, y1 - 8 - (y1 - y0 - 16) * 36 / 60)
    drag(app, h, (x0 + 8 + (x1 - x0 - 16) * 0.57, h[1] - 40))
    v = app.pad(0)["voice"]
    assert 500 < v["cutoff"] < 2000 and v["resonance"] > 0.2, (v["cutoff"], v["resonance"])
    assert app.state()["undo"] == "Set Cutoff"
    # Its envelope opens it while a note plays: the cutoff now is above the setting.
    app.drag_by("Env", 0, -40, window="detail")
    app.cmd("hit 0")
    app.wait(3)
    p = app.pad(0)
    assert p["cutoff_now"] > p["voice"]["cutoff"] * 1.5, (p["cutoff_now"], p["voice"]["cutoff"])
    app.cmd("release 0")
    app.screenshot("filter")


def test_pitch_and_an_lfo_on_the_cutoff(app, fixtures):
    loaded(app, fixtures)
    app.click("Pitch", window="detail")
    app.drag_by("Amount", 0, -30, window="detail")
    assert app.pad(0)["voice"]["pitch_env"] > 5
    app.expect_item("pitch now", window="detail")
    app.click("LFO", window="detail")
    app.click("LFO 1 Square", window="detail")
    app.click("Trigger", window="detail")
    app.click("LFO 1 route 1", window="detail")
    app.click("Cutoff")
    v = app.pad(0)["voice"]
    assert v["lfos"][0]["shape"] == SQUARE and v["lfos"][0]["mode"] == TRIGGER, v["lfos"][0]
    assert v["routes"][0]["dest"] == CUTOFF and v["routes"][0]["amount"] > 0, v["routes"][0]
    app.expect_item("lfo 1 trace", window="detail")


def test_global_and_an_audio_pads_tabs(app, fixtures):
    loaded(app, fixtures)
    app.click("Global", window="detail")
    app.drag_by("Fine", 0, -20, window="detail")
    assert app.pad(0)["voice"]["fine"] > 5
    app.click("##voices", window="detail")
    app.click("Audio", window="detail")
    app.expect_no_item("Filter", window="detail")  # an audio pad has no voice
    app.expect_item("EQ", window="detail")
    app.key("cmd+z")
    app.expect_item("Filter", window="detail")


def test_transpose_moves_in_whole_semitones(app, fixtures):
    # On a sampler and on a slicer: a drag lands on whole semitones (small
    # moves add up underneath), a wheel notch is one semitone.
    loaded(app, fixtures)
    app.cmd(f"slicer 1 {os.path.join(fixtures, 'loop.wav')}")
    for pad in (0, 1):
        app.cmd(f"select {pad}")
        app.click("Global", window="detail")
        app.drag_by("Transpose", 0, -9, window="detail", steps=18)  # half a pixel a frame
        p = app.pad(pad)["pitch"]
        assert p >= 1 and p == int(p), p
        app.hover("Transpose", window="detail")
        app.cmd("scroll 0 1")
        app.wait(3)
        assert app.pad(pad)["pitch"] == p + 1
        app.cmd("scroll 0 -2")
        app.wait(3)
        assert app.pad(pad)["pitch"] == p - 1


def test_mono_legato_and_glide(app, fixtures):
    loaded(app, fixtures)
    app.click("Global", window="detail")
    app.expect_no_item("Glide", window="detail")  # (poly: no glide)
    app.click("voice mode", window="detail", at=(0.83, 0.5))  # the third: Legato
    v = app.pad(0)["voice"]
    assert v["mode"] == 2, v["mode"]  # Legato
    assert app.state()["undo"] == "Voice Mode"
    app.expect_item("Glide", window="detail")
    app.drag_by("Glide", 0, -40, window="detail")
    assert app.pad(0)["voice"]["glide"] > 0.1, app.pad(0)["voice"]["glide"]
    app.click("Always", window="detail")
    assert app.pad(0)["voice"]["glide_always"]
    app.screenshot("voice_glide")
    app.key("cmd+z")
    assert not app.pad(0)["voice"]["glide_always"]
