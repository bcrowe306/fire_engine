"""The Sequence view's vertical zoom: Cmd+wheel over the rows makes them
taller (fewer show), the wheel alone still scrolls; the row height
dragged; back to as many as fit."""

import os


def test_rows_zoom_in_and_out(app, fixtures):
    app.cmd(f"load 0 {os.path.join(fixtures, 'kick.wav')}")
    app.cmd("note 0 0 0.25 1")
    app.panel("Sequence")
    app.wait(2)
    fit = app.state()["seq_rows"]
    assert app.state()["row_h"] == 0
    app.hover("seq", window="sequence")
    app.cmd("hold cmd")
    for _ in range(4):
        app.cmd("scroll 0 2")
        app.wait(2)
    app.cmd("let cmd")
    s = app.state()
    assert s["row_h"] > 0 and s["seq_rows"] < fit, (s["row_h"], s["seq_rows"], fit)
    app.screenshot("zoomed_in")
    # Dragged down (lower): more rows again.
    before = s["seq_rows"]
    app.drag_by("row height", 0, 40, window="sequence")
    assert app.state()["seq_rows"] > before, app.state()["seq_rows"]
    # Double-click: as many as fit.
    app.click("row height", window="sequence", double=True)
    app.type("0")
    app.key("enter")
    app.until(lambda s: s["row_h"] == 0 and s["seq_rows"] == fit, what="fit again")
