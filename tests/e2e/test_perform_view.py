"""The Perform tab: the whole height (the pads area folded while it shows,
and from Song to Perform it stays so), the launcher's lanes playing
together (a scene launched at once, a lane stopped, all stopped), Record
to Song writing what was launched into the Song's lanes, and the main
level."""

import os


def three(app, fixtures):
    app.cmd(f"load 0 {os.path.join(fixtures, 'kick.wav')}")
    app.cmd(f"load 1 {os.path.join(fixtures, 'hat.wav')}")
    app.cmd("note 0 0 0.25 1")
    app.cmd("slot 2")
    app.cmd("note 1 0.5 0.25 1")
    app.cmd("slot 3")
    app.cmd("note 1 0 0.25 1")
    app.cmd("slot 1")
    app.panel("Perform")
    app.wait(3)


def test_the_pads_area_folds(app, fixtures):
    three(app, fixtures)
    assert app.state()["pads_folded"]
    app.panel("Song")
    app.wait(2)
    assert app.state()["pads_folded"]  # (Song wants the height too)
    app.panel("Mixer")
    app.wait(2)
    assert not app.state()["pads_folded"]


def test_columns_rows_and_stops(app, fixtures):
    three(app, fixtures)
    app.click("launch quantize", window="perform", at=(0.9, 0.5))  # Now
    app.click("scene 1", window="perform")
    app.until(lambda s: s["playing"], what="playing")
    assert app.state()["columns"][:4] == [1, 2, 3, 0], app.state()["columns"]
    app.click("stop lane 2", window="perform")
    assert app.state()["columns"][:4] == [1, 0, 3, 0]
    app.click("launch 2", window="perform")  # back in its column, the others play on
    assert app.state()["columns"][:4] == [1, 2, 3, 0]
    app.screenshot("perform_columns")
    app.click("stop all", window="perform")
    assert app.state()["columns"][:4] == [0, 0, 0, 0]


def test_shift_launches_alone_and_continue(app, fixtures):
    three(app, fixtures)
    app.click("launch quantize", window="perform", at=(0.9, 0.5))  # Now
    app.click("scene 1", window="perform")
    app.until(lambda s: s["playing"], what="playing")
    app.cmd("hold shift")
    app.click("launch 2", window="perform")  # alone: the others stop
    app.cmd("let shift")
    assert app.state()["columns"][:4] == [0, 2, 0, 0], app.state()["columns"]
    app.click("launch continue", window="perform")
    assert app.state()["launch_continue"]
    app.cmd("hold alt")
    app.click("launch 3", window="perform")  # Option: playing, it isn't launched
    app.cmd("let alt")
    assert app.state()["columns"][:4] == [0, 2, 0, 0]


def test_record_to_song(app, fixtures):
    three(app, fixtures)
    app.click("launch quantize", window="perform", at=(0.9, 0.5))  # Now
    app.click("record to song", window="perform")
    assert app.state()["launch_record"]
    app.click("launch 1", window="perform")  # stopped: it starts
    app.until(lambda s: s["playing"], what="playing")
    app.wait(20)
    app.click("launch 2", window="perform")  # its own column
    app.wait(20)
    app.key("space")  # stop: the take goes into the Song
    app.wait(3)
    s = app.state()
    lanes = sorted((c["slot"], c["lane"]) for c in s["clips"])
    assert lanes == [(1, 1), (2, 2)], s["clips"]
    assert s["undo"] == "Record to Song"


def test_main_level(app, fixtures):
    three(app, fixtures)
    app.drag_by("Main fader", 0, 60, window="perform")  # down: quieter
    assert app.state()["main_volume"] < -3
