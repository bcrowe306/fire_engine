"""Audio pads by mouse: a pad made an audio track, its input, arm and
monitor; a take recorded into the current sequence (from the fake
device's silent input) and shown in the Sample tab; the strip's arm
button; undo and Clear Take."""


def audio_pad(app, index=1):
    app.click(f"pad A{index + 1}", window="detail")
    app.click("Global", window="detail")
    app.click("Audio", window="detail")
    p = app.pad(index)
    assert p["kind"] == "Audio" and p["take"] == 0, p
    return p


def test_a_pad_becomes_an_audio_track(app):
    audio_pad(app)
    assert app.state()["undo"] == "Audio Track"
    assert app.pad(1)["monitor"] == "Auto"  # its input heard while armed
    app.click("Off", window="detail")
    assert app.pad(1)["monitor"] == "Off"
    app.click("##audioin", window="detail")
    app.click("In 2")
    assert app.pad(1)["input"] == "In 2"
    app.click("Sampler", window="detail")
    assert app.state()["undo"] == "Sampler Pad"
    app.key("cmd+z")
    assert app.pad(1)["kind"] == "Audio"


def test_arm_and_record_a_take(app):
    audio_pad(app)
    assert app.pad(1)["armed"]  # selected: armed
    app.expect_item("A2 arm", window="detail")  # the strip's arm button, lit
    app.click("Record (Cmd+R)")
    app.until(lambda s: s["timeline"] > 1.0, frames=240, what="a beat or so recorded")
    app.click("Stop (Space); press twice to silence every sound")
    app.until(lambda s: any(p["index"] == 1 and p["take"] > 0 for p in s["pads"]), frames=240, what="the take")
    assert app.state()["undo"] == "Record Audio"
    take = app.pad(1)["take"]
    # One sequence long: a bar at 120 BPM, 2 s, at the device's rate.
    assert take in (88200, 96000), take
    app.click("Sample", window="detail")
    app.expect_item("wave", window="detail")
    app.screenshot("take")
    app.click("Clear Take", window="detail")
    assert app.pad(1)["take"] == 0
    app.key("cmd+z")
    assert app.pad(1)["take"] == take


def test_the_strips_arm_button(app):
    audio_pad(app)
    assert app.pad(1)["armed"]  # selected: armed
    app.click("A2 arm", window="detail")
    assert not app.pad(1)["armed"]
    app.panel("Mixer")
    app.click("A2 arm", window="mixer")
    assert app.pad(1)["armed"]
