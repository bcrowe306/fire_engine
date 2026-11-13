"""Per-track loops by mouse: a row's menu giving the kick a loop of 3
beats (its repeats ghosted), the length dragged, off again; an audio
track's loop from the Audio tab."""

import os


def test_a_rows_loop_from_its_menu(app, fixtures):
    app.cmd(f"load 0 {os.path.join(fixtures, 'kick.wav')}")
    app.cmd("note 0 0 0.25 1")
    app.panel("Sequence")
    app.click("seq row 0", window="sequence", right=True)
    app.hover("Track Loop")
    app.click("3 beats")
    assert app.pad(0)["loop"] == 3, app.pad(0)["loop"]
    assert app.state()["undo"] == "Track Loop"
    app.screenshot("track_loop_menu")
    app.click("seq row 0", window="sequence", right=True)
    app.hover("Track Loop")
    app.click("No Track Loop")
    assert app.pad(0)["loop"] == 0
    app.key("cmd+z")
    assert app.pad(0)["loop"] == 3


def test_an_audio_tracks_loop(app, fixtures):
    app.cmd(f"take 1 {os.path.join(fixtures, 'loop.wav')}")
    app.cmd("lane audio")
    app.wait(3)
    app.click("audio loop", double=True)
    app.type("1.5")
    app.key("enter")
    app.until(lambda s: [p for p in s["pads"] if p["index"] == 1][0]["loop"] == 1.5, what="the loop typed")
