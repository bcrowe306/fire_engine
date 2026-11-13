"""Resampling and bouncing by mouse: an audio track's input set to main,
to another track and to a bus from its input menu; a pad bounced onto the
next empty pad, then two selected together; a bus bounced from its strip's
menu; a pad bounced in place (an audio track of its sound, the pad
muted), and undo."""

import os


def kick_with_notes(app, fixtures, index=0):
    app.cmd(f"load {index} {os.path.join(fixtures, 'kick.wav')}")
    app.cmd(f"note {index} 0 0.25 1")
    app.cmd(f"note {index} 2 0.25 1")


def test_an_audio_tracks_input_from_inside_the_mix(app, fixtures):
    kick_with_notes(app, fixtures)
    app.click("pad A2", window="detail")
    app.click("Global", window="detail")
    app.click("Audio", window="detail")
    app.click("##audioin", window="detail")
    app.click("Main (resample)")
    assert app.pad(1)["input"] == "Main mix", app.pad(1)["input"]
    assert app.state()["undo"] == "Set Input"
    app.click("##audioin", window="detail")
    app.hover("From a track")
    app.click("A1 · kick")
    assert app.pad(1)["input"] == "From A1 · kick", app.pad(1)["input"]
    app.click("##audioin", window="detail")
    app.hover("From a bus")
    app.click("Bus A")
    assert app.pad(1)["input"] == "From Bus A", app.pad(1)["input"]
    app.screenshot("resample_input")
    app.key("cmd+z")
    assert app.pad(1)["input"] == "From A1 · kick"


def test_bounce_pads_and_a_bus_to_a_pad(app, fixtures):
    kick_with_notes(app, fixtures)
    app.cmd(f"load 1 {os.path.join(fixtures, 'hat.wav')}")
    app.cmd("note 1 1 0.25 1")
    app.click("pad A1", right=True)
    app.click("Bounce to Pad")
    app.until(lambda s: s["undo"] == "Bounce to Pad", frames=600, what="the bounce")
    p = app.pad(2)
    assert p["name"] == "Bounce A1", p["name"]
    # Two together: A1, then Cmd-click A2.
    app.click("pad A1")
    app.cmd("hold cmd")
    app.click("pad A2")
    app.cmd("let cmd")
    app.click("pad A2", right=True)
    app.click("Bounce to Pad")
    app.until(lambda s: any(p["index"] == 3 for p in s["pads"]), frames=600, what="the second bounce")
    assert app.pad(3)["name"] == "Bounce 2 pads", app.pad(3)["name"]
    # A bus, from its strip's menu.
    app.cmd("route 0 1")  # (A1 onto Bus A)
    app.panel("Mixer")
    app.click("Bus A name", window="mixer", right=True)
    app.click("Bounce to Pad")
    app.until(lambda s: any(p["index"] == 4 for p in s["pads"]), frames=600, what="the bus's bounce")
    assert app.pad(4)["name"] == "Bounce Bus A", app.pad(4)["name"]


def test_bounce_in_place(app, fixtures):
    kick_with_notes(app, fixtures)
    app.click("pad A1", right=True)
    app.click("Bounce in Place")
    app.until(lambda s: s["undo"] == "Bounce in Place", frames=600, what="the bounce in place")
    assert app.pad(0)["mute"]
    t = app.pad(1)
    assert t["kind"] == "Audio" and t["take"] in (96000, 88200), t
    assert t["name"] == "kick (bounced)", t["name"]
    app.screenshot("bounce_in_place")
    app.key("cmd+z")
    assert not app.pad(0)["mute"]
