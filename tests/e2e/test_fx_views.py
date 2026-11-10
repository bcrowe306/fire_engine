"""Effect devices' pictures: a filter's response to drag, a compressor's
curve with its gain reduction meter, a delay's echoes, a reverb's decay,
and a held performance filter's curve moving with the press."""

import os


def chain(app, fixtures, kind):
    app.cmd(f"load 0 {os.path.join(fixtures, 'loop.wav')}")
    app.cmd("select 0")
    app.cmd(f"insert 0 0 {kind}")
    app.cmd("edit_fx pad 0 0")
    app.wait(3)


def test_a_filter_effect_drags_by_its_response(app, fixtures):
    chain(app, fixtures, "lowpass")
    x0, y0, x1, y1 = [i for i in app.items("effect response", "detail") if i["label"] == "effect response"][0]["rect"]
    # Drag on it, left: the cutoff falls (parameter 2 of a filter).
    app.drag_by("effect response", -200, 0, window="detail")
    cut = dict((int(i), v) for i, v in app.state()["fx_params"]).get(2)
    assert cut is not None and cut < 15000, app.state()["fx_params"]
    app.screenshot("lowpass")


def test_dynamics_delay_and_reverb_pictures(app, fixtures):
    chain(app, fixtures, "compressor")
    app.expect_item("effect curve", window="detail")
    app.expect_item("gain reduction", window="detail")
    app.cmd("insert 0 0 delay")
    app.wait(2)
    app.expect_item("effect echoes", window="detail")
    app.cmd("insert 0 0 reverb")
    app.wait(2)
    app.expect_item("effect decay", window="detail")
    for kind, item in (("comb", "effect response"), ("chorus", "effect sweep"), ("cutter", "effect slices"), ("pitch", "effect pitch"), ("bitcrush", "effect curve")):
        app.cmd(f"insert 0 0 {kind}")
        app.wait(2)
        app.expect_item(item, window="detail")


def test_the_delay_syncs_to_note_values_and_shows_its_tone(app, fixtures):
    chain(app, fixtures, "delay")
    app.expect_item("Time", window="detail")
    app.expect_no_item("Note", window="detail")
    app.click("Sync", window="detail")
    app.expect_item("Note", window="detail")  # note values, not milliseconds
    app.expect_no_item("Time", window="detail")
    beats = lambda: dict((int(i), v) for i, v in app.state()["fx_params"]).get(3)
    app.drag_by("Note", 0, -30, window="detail")  # up: longer
    b = beats()
    notes = [0.0625, 1 / 12, 0.125, 1 / 6, 0.25, 1 / 3, 0.375, 0.5, 2 / 3, 0.75, 1, 4 / 3, 1.5, 2, 3, 4, 8]
    assert b is not None and any(abs(b - n) < 1e-4 for n in notes) and b > 0.75, b
    app.expect_item("delay tone", window="detail")  # its cuts, over what it puts out
    app.drag_by("Low cut", 0, -200, window="detail")  # all the way up
    low = dict((int(i), v) for i, v in app.state()["fx_params"]).get(7)
    assert low is not None and low > 2000, low  # the wider range reaches past 2 kHz
