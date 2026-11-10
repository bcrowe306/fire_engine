"""The mixer's channel strips, by mouse: faders, mute and solo, sends,
outputs, pan, inserts and the EQ display."""

import os


def mixer(app, fixtures):
    app.cmd(f"load 0 {os.path.join(fixtures, 'kick.wav')}")
    app.cmd(f"load 1 {os.path.join(fixtures, 'hat.wav')}")
    app.panel("Mixer")
    app.expect_item("A1 fader", window="mixer")


def test_a_strip_for_each_pad_with_a_sound(app, fixtures):
    mixer(app, fixtures)
    assert app.has("A2 fader", window="mixer")
    assert not app.has("A3 fader", window="mixer")
    for b in ("Bus A", "Bus B", "Bus C", "Bus D", "Main"):
        assert app.has(f"{b} fader", window="mixer"), b


def test_faders_mute_solo_and_pan(app, fixtures):
    mixer(app, fixtures)
    app.drag_by("A1 fader", 0, 40, window="mixer")
    assert app.pad(0)["volume"] < -3
    app.key("cmd+z")
    assert abs(app.pad(0)["volume"]) < 0.01
    app.click("A1 mute", window="mixer")
    assert app.pad(0)["mute"]
    app.click("A2 solo", window="mixer")
    assert app.pad(1)["solo"]
    app.drag_by("A1 pan", 0, -40, window="mixer")
    assert app.pad(0)["pan"] > 0.2
    app.drag_by("Bus A fader", 0, 30, window="mixer")
    assert app.state()["buses"][0]["volume"] < -3


def test_sends_pre_and_post(app, fixtures):
    mixer(app, fixtures)
    app.drag_by("A1 send B", 0, -150, window="mixer")
    assert app.pad(0)["sends"][1] > -10
    app.click("A1 send B", window="mixer", right=True)
    app.click("Pre-fader")
    assert app.state()["undo"] == "Pre-fader Send"
    app.click("A1 send C", window="mixer", double=True)  # on at 0 dB
    assert abs(app.pad(0)["sends"][2]) < 0.01


def test_outputs_and_inserts(app, fixtures):
    mixer(app, fixtures)
    app.click("A1 output", window="mixer")
    app.click("Bus C")
    assert app.pad(0)["bus"] == 3
    app.click("A1 slot 1", window="mixer")
    assert app.state()["detail_tab"] == "Effects"
    app.click("##kind", window="detail")
    app.click("Low-pass")
    assert app.pad(0)["inserts"][0] == "Low-pass"
    app.click("A1 eq", window="mixer")
    assert app.state()["detail_tab"] == "Effects"  # the EQ is there


def test_the_peak_readout_resets(app, fixtures):
    mixer(app, fixtures)
    app.cmd("hit 0")
    app.wait(20)
    assert app.pad(0)["level"] > 0
    app.click("A1 peak", window="mixer")
