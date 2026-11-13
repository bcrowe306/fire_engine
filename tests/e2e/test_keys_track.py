"""Keyboard mode's track arrows: beside the bank tabs, they step the
selected pad (the one the keys play) through the pads with a sound,
round from the last to the first; Pads mode doesn't show them."""

import os


def test_the_arrows_step_through_the_tracks(app, fixtures):
    kick = os.path.join(fixtures, "kick.wav")
    for i in (0, 3, 20):
        app.cmd(f"load {i} {kick}")
    app.cmd("select 0")
    app.expect_no_item("track after")
    app.cmd("mode keys")
    app.wait(3)
    app.screenshot("keys_track")
    app.click("track after")
    assert app.state()["selected"] == 3
    app.click("track after")
    assert app.state()["selected"] == 20  # (on to B5: another bank's)
    app.click("track after")
    assert app.state()["selected"] == 0  # round again
    app.click("track before")
    assert app.state()["selected"] == 20
    app.cmd("mode pads")
    app.wait(3)
    assert app.state()["bank"] == 1  # back to Pads: the track's bank
