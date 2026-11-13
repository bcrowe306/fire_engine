"""Switching between the Mixer and the Sequence view: the selected pad's
strip, and its row, come back into view (scrolled to it if they were
away)."""

import os


def test_the_selected_pad_is_in_view_after_switching(app, fixtures):
    kick = os.path.join(fixtures, "kick.wav")
    for i in range(40):
        app.cmd(f"load {i} {kick}")
    app.cmd("select 0")
    # The Sequence view zoomed in: a few rows at a time.
    app.panel("Sequence")
    app.wait(2)
    app.hover("seq", window="sequence")
    app.cmd("hold cmd")
    for _ in range(8):
        app.cmd("scroll 0 2")
        app.wait(2)
    app.cmd("let cmd")
    s = app.state()
    assert s["seq_rows"] < 16 and s["seq_row0"] == 0, (s["seq_rows"], s["seq_row0"])
    # The Mixer: pad C8 (the 40th) selected, then shown: its strip in view.
    app.panel("Mixer")
    app.wait(2)
    assert not app.has("C8 fader", window="mixer"), "away to the right at first"
    app.cmd("select 39")
    app.panel("Sequence")
    app.wait(2)
    app.panel("Mixer")
    app.wait(3)
    assert app.has("C8 fader", window="mixer"), "scrolled to it"
    # The Sequence view again with A16 selected: its row in view.
    app.cmd("select 15")
    app.panel("Sequence")
    app.wait(3)
    s = app.state()
    assert s["seq_row0"] <= 15 < s["seq_row0"] + s["seq_rows"], (s["seq_row0"], s["seq_rows"])
