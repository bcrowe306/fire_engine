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


# The synth's effects' parameter ids (synth.effect_param): 700 + 32 x the effect + the field.
FILTER_CUTOFF = 700 + 32 * 5 + 3
DELAY_SYNC, DELAY_HZ, DELAY_TEMPO = 700 + 32 * 2 + 2, 700 + 32 * 2 + 3, 700 + 32 * 2 + 4


def fx_param(app, pid):
    return dict((int(i), v) for i, v in app.state()["fx_params"]).get(pid)


def test_a_filter_effect_drags_by_its_response(app, fixtures):
    chain(app, fixtures, "lowpass")  # (the synth's filter, as a low-pass)
    before = fx_param(app, FILTER_CUTOFF)
    # Its handle, dragged left: the cutoff falls.
    x0, y0, x1, y1 = [i for i in app.items("synth fx filter response", "detail") if i["label"] == "synth fx filter response"][0]["rect"]
    app.drag_by("synth fx filter response", -150, 0, window="detail")
    cut = fx_param(app, FILTER_CUTOFF)
    assert cut is not None and before is not None and cut < before, (before, cut)
    app.screenshot("lowpass")


def test_dynamics_delay_and_reverb_pictures(app, fixtures):
    chain(app, fixtures, "compressor")
    app.expect_item("synth compressor view", window="detail")
    for kind, item in (("delay", "synth delay view"), ("reverb", "synth reverb view"), ("chorus", "synth sweep view"),
                       ("bitcrush", "synth distortion view"), ("comb", "effect response"), ("cutter", "effect slices"), ("pitch", "effect pitch")):
        app.cmd(f"insert 0 0 {kind}")
        app.wait(2)
        app.expect_item(item, window="detail")


def test_the_delay_syncs_to_note_values(app, fixtures):
    chain(app, fixtures, "delay")
    assert fx_param(app, DELAY_SYNC) == 1  # to the tempo, to start
    app.expect_item("Time", window="detail")
    app.click("##dsync", window="detail")
    app.click("Hz")
    assert fx_param(app, DELAY_SYNC) == 0
    before = fx_param(app, DELAY_HZ)
    app.drag_by("Time", 0, -30, window="detail")
    assert fx_param(app, DELAY_HZ) > before
    app.expect_item("synth delay view", window="detail")
