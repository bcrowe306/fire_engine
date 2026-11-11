"""The Song tab's overview, by mouse and keys: Shift-click selects a range
of steps and Cmd-click one more; a block's right handle drags the length of
its part and its left handle where it starts (by bars, Shift: beats); its
middle drags the selection elsewhere; Cmd+C / Cmd+V paste after the last
selected, Cmd+D duplicates, Cmd+X cuts, Backspace removes, Cmd+A selects
all."""

import os


def song(app, fixtures):
    """Steps playing sequences 1 (two bars), 2 (one) and 1 again: 20 beats."""
    app.cmd(f"load 0 {os.path.join(fixtures, 'kick.wav')}")
    app.cmd("note 0 0 0.25 1")
    app.cmd("bars 2")
    app.cmd("slot 2")
    app.cmd("note 0 1 0.25 1")
    app.cmd("slot 1")
    app.panel("Song")
    for k in (1, 2, 1):
        app.click(f"song seq {k}", window="song", double=True)
    assert app.state()["song"] == [1, 2, 1]


def lane(app):
    return [i for i in app.items("song timeline", "song") if i["label"] == "song timeline"][0]["rect"]


def x_of(app, beat, total=20):
    """Where beat `beat` of the song is on the timeline (points)."""
    x0, _, x1, _ = lane(app)
    a, b = x0 + 6, x1 - 70
    return a + (b - a) * beat / total


def y_mid(app):
    _, y0, _, y1 = lane(app)
    return (y0 + y1) / 2


def click_at(app, beat, total=20):
    x0, _, x1, _ = lane(app)
    app.click("song timeline", window="song", at=((x_of(app, beat, total) - x0) / (x1 - x0), 0.5))


def drag(app, x_from, x_to, steps=16):
    y = y_mid(app)
    app.cmd(f"drag {x_from} {y} {x_to} {y} {steps}")
    app.wait(3)


def test_select_and_drag_edges(app, fixtures):
    song(app, fixtures)
    click_at(app, 2)  # step 1
    app.cmd("hold shift")
    click_at(app, 15)  # step 3: a range
    app.cmd("let shift")
    s = app.state()
    assert s["song_sel"] == [1, 2, 3] and s["song_selected"] == 3, s["song_sel"]
    click_at(app, 10)  # step 2 alone
    app.cmd("hold cmd")
    click_at(app, 2)  # and step 1
    app.cmd("let cmd")
    assert app.state()["song_sel"] == [1, 2]
    # Step 1's right handle, a bar to the left: it plays one bar of two.
    drag(app, x_of(app, 8) - 2, x_of(app, 4) - 2)
    st = app.state()
    assert st["steps"][0]["length"] == 4 and st["song_seconds"] == 8, st["steps"][0]
    assert st["undo"] == "Step Length"
    app.screenshot("song_overview_trimmed")
    # Step 3 (now at beat 8): its left handle, with Shift a beat to the right.
    app.cmd("hold shift")
    drag(app, x_of(app, 8, 16) + 3, x_of(app, 9, 16) + 3)
    app.cmd("let shift")
    st = app.state()["steps"][2]
    assert st["start"] == 1 and st["length"] == 7, st


def test_move_copy_paste_cut(app, fixtures):
    song(app, fixtures)
    click_at(app, 10)  # step 2 (sequence 2)
    drag(app, x_of(app, 10), x_of(app, 1))  # its middle, to before step 1
    s = app.state()
    assert s["song"] == [2, 1, 1] and s["song_sel"] == [1], s["song"]
    app.key("cmd+c")
    click_at(app, 8)  # step 2
    app.key("cmd+v")  # after it
    s = app.state()
    assert s["song"] == [2, 1, 2, 1] and s["song_sel"] == [3], (s["song"], s["song_sel"])
    app.key("cmd+d")
    assert app.state()["song"] == [2, 1, 2, 2, 1]
    app.key("backspace")
    assert app.state()["song"] == [2, 1, 2, 1]
    app.key("cmd+a")
    assert app.state()["song_sel"] == [1, 2, 3, 4]
    app.key("cmd+x")
    assert app.state()["song"] == []
    app.key("cmd+z")
    assert app.state()["song"] == [2, 1, 2, 1]
