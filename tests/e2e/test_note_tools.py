"""The sequence editor's tools: a row's name selects its pad and its notes
(heard, with the headphones on); Draw paints, Erase sweeps, Move drags the
selection (Alt copies); V B E M switch tools; a row's menu renames its
pad; a pad's piano roll, folded to the rows with notes."""

import os


def loaded(app, fixtures):
    app.cmd(f"load 0 {os.path.join(fixtures, 'kick.wav')}")
    app.cmd(f"load 1 {os.path.join(fixtures, 'hat.wav')}")
    for b in range(4):
        app.cmd(f"note 0 {b} 0.25 1")
    app.cmd("note 1 0.5 0.25 0.8")
    app.panel("Sequence")


def grid(app):
    return [i for i in app.items("seq", "sequence") if i["label"] == "seq"][0]["rect"]


def row_y(rect, row, rows=16):
    x0, y0, x1, y1 = rect
    return y1 - (y1 - y0) / rows * (row + 0.5)


def test_a_rows_name_selects_its_pad_and_notes(app, fixtures):
    loaded(app, fixtures)
    app.click("seq row 0", window="sequence")
    s = app.state()
    assert s["selected"] == 0 and s["selected_notes"] == 4, (s["selected"], s["selected_notes"])
    app.click("seq row 1", window="sequence")
    s = app.state()
    assert s["selected"] == 1 and s["selected_notes"] == 1
    # The headphones: off, a row is only selected.
    app.click("Hear a row's pad when you click its name: on", window="sequence")
    app.click("seq row 0", window="sequence")
    assert app.state()["selected"] == 0
    # Delete with notes selected deletes them, not the pad.
    app.key("delete")
    s = app.state()
    assert s["notes"] == 1 and any(p["index"] == 0 for p in s["pads"]), s["notes"]


def test_draw_paints_and_erase_sweeps(app, fixtures):
    loaded(app, fixtures)
    app.click("Clear the sequence", window="sequence")
    x0, y0, x1, y1 = grid(app)
    app.tool("Draw")
    y = row_y((x0, y0, x1, y1), 3)
    app.cmd(f"drag {x0 + 2} {y} {x0 + (x1 - x0) * 0.49} {y} 16")  # half a bar of 1/16s: 8 notes
    app.wait(3)
    assert app.state()["notes"] == 8, app.state()["notes"]
    app.key("cmd+z")
    assert app.state()["notes"] == 0  # the paint was one step
    app.key("cmd+shift+z")
    app.tool("Erase")
    app.cmd(f"drag {x0 + 2} {y} {x0 + (x1 - x0) * 0.3} {y} 20")
    app.wait(3)
    assert app.state()["notes"] < 8 and app.state()["undo"] == "Erase Notes"


def test_move_and_copy_the_selection(app, fixtures):
    loaded(app, fixtures)
    app.click("seq row 1", window="sequence")  # A2's note at 0.5
    x0, y0, x1, y1 = grid(app)
    app.tool("Move")
    beat = (x1 - x0) / 4
    y = row_y((x0, y0, x1, y1), 1)
    app.cmd(f"drag {x0 + beat * 0.55} {y} {x0 + beat * 1.55} {y} 10")  # a beat later
    app.wait(3)
    assert app.state()["undo"] == "Move Notes" and app.state()["notes"] == 5
    app.cmd("hold alt")
    app.cmd(f"drag {x0 + beat * 1.55} {y} {x0 + beat * 2.55} {y} 10")
    app.wait(3)
    app.cmd("let alt")
    assert app.state()["undo"] == "Copy Notes" and app.state()["notes"] == 6


def test_tool_keys_rename_and_the_piano_roll(app, fixtures):
    loaded(app, fixtures)
    app.click("seq row 0", window="sequence")  # the editor has the keyboard
    for key, tool in (("b", "Draw"), ("e", "Erase"), ("m", "Move"), ("v", "Select")):
        app.key(key)
        assert app.state()["tool"] == tool
    # A row's menu: rename its pad.
    app.click("seq row 1", window="sequence", right=True)
    app.click("Rename…")
    app.key("cmd+a")
    app.type("Shaker")
    app.key("return")
    assert app.pad(1)["name"] == "Shaker"
    # Double-click a row's name: its pad's piano roll; fold to the rows used.
    app.click("seq row 0", window="sequence", double=True)
    assert app.state()["piano_roll"]
    app.click("Fold: only the rows that have notes", window="sequence")
    app.expect_item("seq row 0", window="sequence")
    app.expect_no_item("seq row 1", window="sequence")  # one pitch used: one row
    app.tool("Draw")
    app.click("Fold: on (only the rows that have notes)", window="sequence")
    app.screenshot("piano")
