"""The slicer device, used by mouse and keys: a sample sliced onto the
next empty pad from the browser (Shift+Enter, Cmd+Shift+Enter, the
context menu, Alt-drag, an empty pad's Slicer half), an empty slicer
filled by a drop, slice markers dragged, added and taken away, a slice's
level line dragged, the slices made a sequence or a pad of their own,
and the pad a sampler again."""

import os


def open_loops(app, library):
    app.browse(library)
    app.click("Loops", window="browser")


def rect(app, label, window):
    items = [i for i in app.items(label, window) if i["label"] == label]
    assert items, f"no item {label!r} in {window}"
    return items[0]["rect"]


def drop_at(app, src, dst, fy, window="detail"):
    """Drags browser row `src` onto item `dst`, let go `fy` of the way down it."""
    a = rect(app, src, "browser")
    b = rect(app, dst, window)
    sx, sy = (a[0] + a[2]) / 2, (a[1] + a[3]) / 2
    dx, dy = (b[0] + b[2]) / 2, b[1] + (b[3] - b[1]) * fy
    app.cmd(f"drag {sx} {sy} {dx} {dy} 16")
    app.wait(3)


def slicer(app, i):
    p = app.pad(i)
    assert p["kind"] == "Slicer", p["kind"]
    return p["slicer"]


def sliced_loop(app, fixtures):
    """loop.wav (2 s, 88200 frames) in a slicer on A1, its page showing."""
    app.cmd(f"slicer 0 {os.path.join(fixtures, 'loop.wav')}")
    app.cmd("select 0")
    app.expect_item("slices", window="detail")
    return slicer(app, 0)


def test_shift_enter_slices_onto_the_next_empty_pad(app, library, fixtures):
    app.cmd(f"load 0 {os.path.join(fixtures, 'kick.wav')}")
    app.cmd("select 0")
    open_loops(app, library)
    app.click("Loop 120.wav", window="browser")
    app.key("shift+enter")
    sl = slicer(app, 1)
    assert len(sl["starts"]) > 1, sl  # sliced at its transients
    assert sl["by"] == "Transients" and sl["base"] == 60
    assert app.state()["selected"] == 1
    assert app.state()["undo"] == "Load into Slicer"
    # Cmd+Shift+Enter: onto the selected pad (the kick becomes a slicer).
    app.cmd("select 0")
    app.click("Loop 120.wav", window="browser")
    app.key("cmd+shift+enter")
    assert slicer(app, 0)["starts"] == sl["starts"]


def test_the_context_menu_slices_onto_the_next_empty_pad(app, library):
    open_loops(app, library)
    app.click("Loop 120.wav", window="browser", right=True)
    app.expect_item("Slice onto Selected Pad")
    app.click("Slice onto Next Empty Pad")
    assert len(slicer(app, 0)["starts"]) > 1


def test_alt_drag_and_the_slicer_half(app, library):
    open_loops(app, library)
    # Alt held: into a slicer, wherever it lands.
    app.cmd("hold alt")
    app.drag("Loop 120.wav", "pad A3", from_window="browser", to_window="detail")
    app.cmd("let alt")
    assert len(slicer(app, 2)["starts"]) > 1
    # An empty pad's lower half: a slicer; its upper half (and its centre): a sampler.
    drop_at(app, "Loop 120.wav", "pad A4", 0.85)
    slicer(app, 3)
    drop_at(app, "Loop 120.wav", "pad A5", 0.2)
    assert app.pad(4)["kind"] == "Sampler"
    app.drag("Loop 120.wav", "pad A6", from_window="browser", to_window="detail")
    assert app.pad(5)["kind"] == "Sampler"


def test_an_empty_slicer_takes_a_drop(app, library):
    app.click("pad A2", window="detail", right=True)
    app.click("Slicer")  # an empty pad: an empty slicer
    assert app.pad(1)["kind"] == "Slicer" and app.pad(1)["slicer"]["starts"] == []
    app.expect_item("slicer drop", window="detail")
    app.screenshot("slicer_empty")
    open_loops(app, library)
    app.drag("Loop 120.wav", "slicer drop", from_window="browser", to_window="detail")
    assert len(slicer(app, 1)["starts"]) > 1
    # A sample dropped on a slicer pad's face is sliced too.
    app.drag("Loop 120.wav", "pad A2", from_window="browser", to_window="detail")
    assert len(slicer(app, 1)["starts"]) > 1


def test_markers_drag_add_and_go(app, fixtures):
    sl = sliced_loop(app, fixtures)
    n = len(sl["starts"])
    x0, y0, x1, y1 = rect(app, "slices", "detail")
    w = x1 - x0
    fx = lambda frame: x0 + w * frame / 88200
    # Slice 2's tag hangs right of its line, at the top: dragged right a little.
    s2 = sl["starts"][1]
    to = s2 + (sl["starts"][2] - s2) // 2
    app.cmd(f"drag {fx(s2) + 6} {y0 + 8} {fx(to) + 6} {y0 + 8} 12")
    app.wait(3)
    moved = slicer(app, 0)
    assert abs(moved["starts"][1] - to) < 88200 * 0.01, (moved["starts"][1], to)
    assert moved["by"] == "Manual" and app.state()["undo"] == "Move Slice"
    # A double-click between markers adds one there.
    gap = (moved["starts"][-1] + 88200) / 2
    app.click("slices", window="detail", double=True, at=(gap / 88200, 0.5))
    added = slicer(app, 0)
    assert len(added["starts"]) == n + 1, added
    assert app.state()["undo"] == "Add Slice"
    # A right-click on a marker's line takes it away.
    last = added["starts"][-1]
    app.click("slices", window="detail", right=True, at=(last / 88200, 0.5))
    assert len(slicer(app, 0)["starts"]) == n
    app.key("cmd+z")
    assert len(slicer(app, 0)["starts"]) == n + 1


def test_a_slice_level_drags(app, fixtures):
    sl = sliced_loop(app, fixtures)
    x0, y0, x1, y1 = rect(app, "slices", "detail")
    w, h = x1 - x0, y1 - y0
    # Slice 1's handle: mid-slice, 0 dB four fifths up.
    cx = x0 + w * (sl["starts"][0] + sl["starts"][1]) / 2 / 88200
    y = y0 + h * 0.2
    app.cmd(f"drag {cx} {y} {cx} {y + h * 0.2} 12")  # 6 dB down
    app.wait(3)
    g = slicer(app, 0)["gains"][0]
    assert -7 < g < -5, g
    assert app.state()["undo"] == "Slice Level"
    assert slicer(app, 0)["selected"] == 0


def test_the_overview_and_zoom(app, fixtures):
    sliced_loop(app, fixtures)
    app.expect_item("slices overview", window="detail")
    app.hover("slices", window="detail")
    app.cmd("scroll 0 3")  # the wheel: zoomed in about the mouse
    app.wait(3)
    app.screenshot("slicer_zoomed")


def test_slices_to_a_sequence_and_a_pad(app, fixtures):
    sl = sliced_loop(app, fixtures)
    n = len(sl["starts"])
    before = app.state()["slot"]
    app.click("slices to sequence", window="detail")
    s = app.state()
    assert s["slot"] != before and s["notes"] == n
    assert s["undo"] == "Slices to Sequence"
    # The piano roll shows the slices.
    app.click("pad A1", window="detail", right=True)
    app.click("Edit in the Piano Roll")
    assert app.state()["piano_roll"]
    app.screenshot("slicer_piano_roll")
    # The selected slice onto the next empty pad, a sampler of that part.
    app.click("slice to pad", window="detail")
    p = app.pad(1)
    assert p["kind"] == "Sampler"
    assert p["start"] == sl["starts"][0] and p["end"] == sl["starts"][1]


def test_keyboard_mode_plays_slices(app, fixtures):
    sliced_loop(app, fixtures)
    app.click("Thru", window="detail")  # (a slice plays on to the sample's end: long enough to see)
    assert slicer(app, 0)["thru"]
    app.cmd("mode keys")
    app.screenshot("slicer_keys")
    app.click("pad A3", window="detail")  # slice 3
    starts = slicer(app, 0)["starts"]
    p = app.until(lambda s: any(x["index"] == 0 and x["playhead"] >= 0 for x in s["pads"]), what="slice 3 playing")
    head = [x for x in p["pads"] if x["index"] == 0][0]["playhead"]
    assert starts[2] <= head < 88200, (head, starts)


def test_back_to_a_sampler_and_again(app, fixtures):
    sl = sliced_loop(app, fixtures)
    app.click("to sampler", window="detail")
    assert app.pad(0)["kind"] == "Sampler"
    app.click("pad A1", window="detail", right=True)
    app.click("Slicer")
    assert slicer(app, 0)["starts"] == sl["starts"]  # its slices kept
