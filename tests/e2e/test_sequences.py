"""Sequences by mouse and keys: renamed (double-click, its menu, F2),
duplicated, their own tempo, bars copied to another (the dialog), notes
box-selected, copied and pasted (Cmd+C, Cmd+V)."""

import os


def seqs(app):
    return {s["slot"]: s for s in app.state()["sequences"]}


def loaded(app, fixtures):
    app.cmd(f"load 0 {os.path.join(fixtures, 'kick.wav')}")
    app.cmd(f"load 1 {os.path.join(fixtures, 'hat.wav')}")
    for b in range(4):
        app.cmd(f"note 0 {b} 0.25 1")
        app.cmd(f"note 1 {b + 0.5} 0.25 0.8")
    app.panel("Sequence")


def test_rename_by_double_click_and_f2(app, fixtures):
    loaded(app, fixtures)
    app.click("sequence name", window="sequence", double=True)
    app.expect_item("sequence rename")
    app.key("cmd+a")
    app.type("Verse")
    app.key("return")
    assert seqs(app)[1]["name"] == "Verse"
    app.key("f2")
    app.type("Chorus")
    app.key("return")
    assert seqs(app)[1]["name"] == "Chorus"
    app.key("cmd+z")
    assert seqs(app)[1]["name"] == "Verse"


def test_duplicate_and_own_tempo(app, fixtures):
    loaded(app, fixtures)
    app.click("sequence name", window="sequence", right=True)
    app.click("Duplicate")
    s = app.state()
    assert s["slot"] == 2 and seqs(app)[2]["notes"] == 8, seqs(app)
    assert seqs(app)[2]["name"] == "Sequence 1 copy"
    app.click("Own tempo: off (the project's)", window="sequence")
    assert seqs(app)[2]["bpm"] == 120
    app.drag_by("seq tempo", 40, 0, window="sequence")
    assert seqs(app)[2]["bpm"] == 130, seqs(app)[2]
    app.key("cmd+d")  # and again, from the keyboard
    assert app.state()["slot"] == 3


def test_copy_bars_dialog(app, fixtures):
    loaded(app, fixtures)
    app.cmd("action copy_bars")
    app.wait(3)
    app.expect_item("Copy")
    app.click("Copy")
    s = seqs(app)
    assert s[2]["notes"] == 8, s
    assert app.state()["undo"] == "Copy Bars"


def test_mark_copy_and_paste(app, fixtures):
    loaded(app, fixtures)
    roll = [i for i in app.items("seq", "sequence") if i["label"] == "seq"][0]["rect"]
    x0, y0, x1, y1 = roll
    # Box-select across the bottom two rows (A1, A2), the second half of the bar.
    app.cmd(f"drag {x0 + (x1 - x0) * 0.58} {y1 - 3} {x0 + (x1 - x0) * 0.98} {y1 - (y1 - y0) / 16 * 1.5} 10")
    app.wait(3)
    assert app.state()["selected_notes"] == 3  # A1's at 3, A2's at 2.5 and 3.5
    app.screenshot("marked")
    app.key("cmd+c")
    app.click("Next sequence")
    app.key("cmd+v")
    s = seqs(app)
    assert s[2]["notes"] == 3, s
