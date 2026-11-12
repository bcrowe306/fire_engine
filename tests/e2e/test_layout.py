"""The window as it is by default (layout D, at the Comfortable size, not
the Compact one the other tests use): the Library beside everything, the
pads area folding to a bar of pads and back, the Library's Browser and
Devices tabs, the toolbar's labelled
buttons, the control size in Settings."""

import os

from pads import Pads


def test_the_pads_area_folds_and_the_library_finds(fixtures):
    app = Pads(size=None)
    try:
        s = app.state()
        assert s["control_h"] == 34 and not s["folded"] and s["library"], (s["control_h"], s["folded"], s["library"])
        app.cmd(f"browse {fixtures}")
        app.cmd(f"load 0 {os.path.join(fixtures, 'kick.wav')}")
        app.expect_item("Record (Cmd+R)", window="##toolbar")
        app.expect_item("Loop: on (it goes round)", window="##toolbar")
        # Folded: a bar of 16 pads; one clicked is selected and unfolds.
        app.key("cmd+j")
        app.wait(3)
        assert app.state()["folded"]
        app.expect_item("bar pad A16", window="detail")
        app.screenshot("folded")
        app.click("bar pad A2", window="detail")
        s = app.state()
        assert not s["folded"] and s["selected"] == 1, (s["folded"], s["selected"])
        app.expect_item("pad A2", window="detail")
        # The fold button in the area's header does the same.
        app.click("Fold the pads and the sound to a bar (Cmd+J)", window="detail")
        assert app.state()["folded"]
        app.click("Unfold the pads and the sound (Cmd+J)", window="detail")
        assert not app.state()["folded"]
        # The Library's two tabs, each searched in its own way.
        app.library_find("kick")
        app.expect_item("kick.wav", window="browser")
        app.library_find("reverb", tab="Devices")
        app.expect_item("device Reverb", window="browser")
        app.expect_no_item("kick.wav", window="browser")
        # Cmd+L hides the Library and shows it again.
        app.key("esc")  # (out of the search box)
        app.wait(2)
        app.key("cmd+l")
        assert not app.state()["library"]
        app.key("cmd+l")
        assert app.state()["library"]
        app.screenshot("layout")
    finally:
        app.close()


def test_the_control_size_setting():
    app = Pads(size=None)
    try:
        app.key("cmd+,")
        app.click("control size", at=(0.875, 0.5))  # Touch
        assert app.state()["control_h"] == 44
        app.screenshot("touch")
        app.click("control size", at=(0.375, 0.5))  # Compact
        assert app.state()["control_h"] == 28
        app.click("control size", at=(0.125, 0.5))  # Auto: Comfortable here
        assert app.state()["control_h"] == 34
    finally:
        app.close()
