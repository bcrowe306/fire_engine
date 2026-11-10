"""The pads and the selected pad's tabs (Sample, Pad), by mouse and keys."""

import os


def load(app, fixtures, pad, name):
    app.cmd(f"load {pad} {os.path.join(fixtures, name)}")
    app.wait(3)


def test_pads_play_and_select_by_mouse_and_keys(app, fixtures):
    load(app, fixtures, 0, "kick.wav")
    load(app, fixtures, 1, "hat.wav")
    app.click("pad A2", window="detail")
    assert app.state()["selected"] == 1
    app.key("z")  # the A1 key: the bottom row (Z X C V) is pads 1-4
    assert app.state()["selected"] == 0
    app.key("a")  # A5, the next row up
    assert app.state()["selected"] == 4
    app.key("1")  # A13, the top row
    assert app.state()["selected"] == 12


def test_banks(app):
    app.click("B", window="detail")
    assert app.state()["bank"] == 1
    app.expect_item("pad B1", window="detail")
    app.click("H", window="detail")
    assert app.state()["bank"] == 7
    app.expect_item("pad H16", window="detail")
    app.click("A", window="detail")
    assert app.state()["bank"] == 0
    app.key("cmd+8")
    assert app.state()["bank"] == 7


def test_the_pad_face_mutes_solos_and_colours(app, fixtures):
    load(app, fixtures, 0, "kick.wav")
    load(app, fixtures, 1, "hat.wav")
    app.click("pad A1 mute", window="detail")
    assert app.pad(0)["mute"] and app.state()["selected"] == 0 or app.pad(0)["mute"]
    app.click("pad A2 solo", window="detail")
    assert app.pad(1)["solo"]
    app.panel("Mixer")
    app.click("A1 mute", window="mixer")  # the same switch as the strip's
    assert not app.pad(0)["mute"]
    # A colour from the right-click menu: on the pad, its strip and its row.
    app.click("pad A2", window="detail", right=True)
    app.click("colour 1")
    app.key("esc")
    assert app.state()["undo"] == "Set Color"
    app.key("cmd+z")
    assert app.state()["undo"] != "Set Color"


def test_the_pad_tab_edits_and_undoes(app, fixtures):
    load(app, fixtures, 0, "kick.wav")
    app.click("Pad", window="detail")
    app.click("Gate", window="detail")
    assert app.pad(0)["mode"] == "Gate"
    app.click("Reverse", window="detail")
    app.drag_by("Volume", 0, 60, window="detail")  # down: quieter
    assert app.pad(0)["volume"] < -3
    app.key("cmd+z")
    assert abs(app.pad(0)["volume"]) < 0.01  # the whole drag was one step
    app.reveal("Clear Pad", "detail", over="Volume")
    app.click("Clear Pad", window="detail")
    assert app.state()["pads"] == []
    app.key("cmd+z")
    assert app.pad(0)["name"] == "kick"


def test_the_sample_tab_edits_chops_and_stretches(app, fixtures):
    load(app, fixtures, 0, "loop.wav")
    app.click("Sample", window="detail")
    app.expect_item("wave", window="detail")
    app.click("Normalize", window="detail")
    app.until(lambda s: s["undo"] == "Normalize", what="normalize")
    app.click("Reverse the audio", window="detail")
    app.until(lambda s: s["undo"] == "Reverse", what="reverse")
    app.click("Equal", window="detail")
    app.click("Chop", window="detail")
    s = app.until(lambda s: len(s["pads"]) > 1, what="the chop's pads")
    assert len(s["pads"]) >= 4
    app.key("cmd+z")
    assert len(app.state()["pads"]) == 1
    app.click("Stretch to beats", window="detail")
    app.until(lambda s: s["undo"] == "Stretch", what="the stretch")


def test_dropping_a_file_from_the_desktop(app, fixtures):
    pad = app.items("pad A3", window="detail")[0]["rect"]
    app.cmd(f"drop {(pad[0] + pad[2]) / 2} {(pad[1] + pad[3]) / 2} {os.path.join(fixtures, 'hat.wav')}")
    app.wait(3)
    assert app.pad(2)["name"] == "hat"
