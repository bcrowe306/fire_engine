"""The Song tab's lanes, by mouse and keys: sequences dragged from the
list onto lanes (or double-clicked, or their +), clips moved across time
and lanes, Alt-dragged copies, their ends dragged (any length; the left
end keeps the notes where they are), painted with Draw, a lane
double-clicked, a box selecting, the clip keys (copy, paste, duplicate,
cut, remove, select all), lanes renamed, muted and soloed, the clip strip,
zoom, the ruler playing from a bar, arrangements, sequences' colours, and
the pads area folded while the Song tab shows."""

import os

ZOOM = 20  # points a beat (a bar: 80)


def two(app, fixtures):
    app.cmd(f"load 0 {os.path.join(fixtures, 'kick.wav')}")
    app.cmd("note 0 0 0.25 1")
    app.cmd("slot 2")
    app.cmd("note 0 1 0.25 1")
    app.cmd("slot 1")
    app.panel("Song")
    app.cmd(f"song zoom {ZOOM}")
    app.cmd("song scroll 0")
    app.wait(3)


def lanes(app):
    return [i for i in app.items("song lanes", "song") if i["label"] == "song lanes"][0]["rect"]


def x(app, beat):
    """Where song beat `beat` is (points)."""
    return lanes(app)[0] + beat * ZOOM


def y(app, lane):
    """The middle of lane `lane` (0-based)."""
    x0, y0, x1, y1 = lanes(app)
    n = len(app.state()["song_lanes"])
    return y0 + (lane + 0.5) * (y1 - y0) / n


def drag(app, a, b, steps=16):
    app.cmd(f"drag {a[0]} {a[1]} {b[0]} {b[1]} {steps}")
    app.wait(3)


def centre(app, label):
    r = [i for i in app.items(label, "song") if i["label"] == label][0]["rect"]
    return ((r[0] + r[2]) / 2, (r[1] + r[3]) / 2)


def clips(app):
    return [(c["slot"], c["lane"], c["at"], c["length"]) for c in app.state()["clips"]]


def test_pads_fold_while_the_song_shows(app, fixtures):
    assert not app.state()["pads_folded"]
    two(app, fixtures)
    assert app.state()["pads_folded"]
    app.panel("Sequence")
    app.wait(2)
    assert not app.state()["pads_folded"]


def test_build_from_the_list(app, fixtures):
    two(app, fixtures)
    app.click("song seq 2", window="song", double=True)
    assert clips(app) == [(2, 1, 0, 4)]
    app.click("Add Sequence 1 at the end of the first lane", window="song")
    assert clips(app) == [(2, 1, 0, 4), (1, 1, 4, 4)]
    # Dragged onto a second lane, at bar 3 (snapped to it).
    app.click("add lane", window="song")
    drag(app, centre(app, "song seq 1"), (x(app, 8.6), y(app, 1)), steps=20)
    assert clips(app)[-1] == (1, 2, 8, 4), clips(app)
    app.screenshot("song_lanes_built")
    app.click("song seq 2", window="song")  # a click edits it
    assert app.state()["slot"] == 2
    app.key("cmd+z")
    assert len(clips(app)) == 2


def test_move_copy_and_resize(app, fixtures):
    two(app, fixtures)
    app.cmd("song add 1")
    app.cmd("song add 2")  # sequence 1 at 0, sequence 2 at 4: 4 beats each
    app.cmd("song lane add")
    app.wait(2)
    # Clip 2 to the second lane, a bar later.
    drag(app, (x(app, 6), y(app, 0)), (x(app, 10), y(app, 1)))
    assert clips(app)[1] == (2, 2, 8, 4), clips(app)
    assert app.state()["undo"] == "Move Clips"
    app.key("cmd+z")
    assert clips(app)[1] == (2, 1, 4, 4)
    app.key("cmd+shift+z")
    # Alt: a copy of clip 1, two bars on; the original stays.
    app.cmd("hold alt")
    drag(app, (x(app, 2), y(app, 0)), (x(app, 10), y(app, 0)))
    app.cmd("let alt")
    assert clips(app) == [(1, 1, 0, 4), (2, 2, 8, 4), (1, 1, 8, 4)], clips(app)
    assert app.state()["undo"] == "Copy Clips"
    # Clip 1's right end, two bars on: 12 beats, going round its sequence.
    drag(app, (x(app, 4) - 2, y(app, 0)), (x(app, 12) - 2, y(app, 0)))
    c = app.state()["clips"][0]
    assert c["length"] == 12, c
    assert app.state()["undo"] == "Clip Length"
    # Its left end, with Shift a beat in: it begins a beat later, its notes
    # where they were (a beat into its sequence).
    app.cmd("hold shift")
    drag(app, (x(app, 0) + 3, y(app, 0)), (x(app, 1) + 3, y(app, 0)))
    app.cmd("let shift")
    c = app.state()["clips"][0]
    assert c["at"] == 1 and c["length"] == 11 and c["phase"] == 1, c
    app.screenshot("song_lanes_moved")


def test_draw_double_click_and_box(app, fixtures):
    two(app, fixtures)
    app.cmd("song tool draw")
    drag(app, (x(app, 0.2), y(app, 0)), (x(app, 7.9), y(app, 0)))  # two bars painted
    assert clips(app) == [(1, 1, 0, 8)], clips(app)
    assert app.state()["undo"] == "Draw Clip"
    app.key("v")  # Select
    assert app.state()["song_tool"] == "Select"
    lx0 = lanes(app)[0]
    app.click("song lanes", window="song", double=True, at=((x(app, 12.5) - lx0) / (lanes(app)[2] - lx0), 0.5))
    assert clips(app)[-1] == (1, 1, 12, 4), clips(app)
    # A box from past them both, back over them.
    app.click("song lanes", window="song", at=(0.95, 0.5))  # nothing: none selected
    assert app.state()["song_sel"] == []
    drag(app, (x(app, 20), y(app, 0) - 10), (x(app, 2), y(app, 0) + 10))
    assert app.state()["song_sel"] == [1, 2], app.state()["song_sel"]


def test_clip_keys(app, fixtures):
    two(app, fixtures)
    app.cmd("song add 1")
    app.cmd("song add 2")
    app.wait(2)
    app.click("clip 2", window="song")
    assert app.state()["song_selected"] == 2
    app.key("cmd+c")
    app.key("cmd+v")  # after it: at 8
    assert clips(app)[-1] == (2, 1, 8, 4), clips(app)
    app.key("cmd+d")  # after itself: at 12
    assert clips(app)[-1] == (2, 1, 12, 4)
    app.key("backspace")
    assert len(clips(app)) == 3
    app.key("cmd+a")
    assert app.state()["song_sel"] == [1, 2, 3]
    app.key("cmd+x")
    assert clips(app) == []
    app.key("cmd+z")
    assert len(clips(app)) == 3
    app.cmd("hold cmd")
    app.click("clip 1", window="song")
    app.cmd("let cmd")
    app.click("clip 1", window="song", right=True)
    app.click("Remove from Song")
    assert len(clips(app)) == 2


def test_lanes_and_the_clip_strip(app, fixtures):
    two(app, fixtures)
    app.cmd("song add 1")
    app.cmd("song add 2 lane 2 at 0")
    app.wait(2)
    app.click("Mute Lane 1", window="song")
    assert app.state()["song_lanes"][0]["mute"]
    app.click("Solo Lane 2", window="song")
    assert app.state()["song_lanes"][1]["solo"]
    app.click("lane 2", window="song", double=True)
    app.expect_item("lane name")
    app.key("cmd+a")
    app.type("Fills")
    app.key("enter")
    app.wait(2)
    assert app.state()["song_lanes"][1]["name"] == "Fills"
    # The strip: the selected clip's section, length, transpose, mute.
    app.click("clip 2", window="song")
    app.click("clip section", window="song")
    app.type("Drop")
    app.key("enter")
    assert app.state()["clips"][1]["label"] == "Drop"
    app.drag_by("clip transpose", 0, -30, window="song")
    assert app.state()["clips"][1]["transpose"] > 0
    app.click("clip mute", window="song")
    assert app.state()["clips"][1]["mute"]
    app.screenshot("song_strip")


def test_zoom_and_the_ruler(app, fixtures):
    two(app, fixtures)
    app.cmd("song add 1")
    app.cmd("song add 2")
    app.wait(2)
    app.hover("song lanes", window="song")
    app.cmd("hold cmd")
    app.cmd("scroll 0 2")
    app.wait(2)
    app.cmd("let cmd")
    assert app.state()["song_zoom"] > ZOOM
    app.click("Fit the song in (Cmd+0); Cmd+scroll zooms, scrolling sideways moves along", window="song")
    app.wait(2)
    z = app.state()["song_zoom"]
    assert z < ZOOM, z  # (two bars, and the room after them)
    app.cmd(f"song zoom {ZOOM}")
    app.wait(2)
    r = [i for i in app.items("song ruler", "song") if i["label"] == "song ruler"][0]["rect"]
    app.click("song ruler", window="song", at=((x(app, 5) - r[0]) / (r[2] - r[0]), 0.5))  # bar 2
    s = app.state()
    assert s["playing"] and s["song_mode"]
    app.until(lambda s: s["song_clip"] == 2, what="the second clip playing")


def test_arrangements_and_colours(app, fixtures):
    two(app, fixtures)
    app.cmd("song add 1")
    app.cmd("song add 2")
    app.wait(2)
    app.click("##arrangement", window="song", right=True)
    app.click("  Duplicate")
    s = app.state()
    assert s["arrangements"] == ["Song", "Song copy"] and s["arrangement"] == 2
    app.click("clip 1", window="song", right=True)
    app.click("Remove from Song")
    assert app.state()["song"] == [2]
    app.click("##arrangement", window="song")
    app.click("Song###arr0")
    s = app.state()
    assert s["arrangement"] == 1 and s["song"] == [1, 2]  # each its own
    before = app.state()["sequences"][0]["color"]
    app.click("song seq 1", window="song", right=True)
    app.hover("Colour")
    app.click("colour 1")
    after = app.state()["sequences"][0]["color"]
    assert after != before and after == 0xff5f57
