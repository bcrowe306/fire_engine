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
