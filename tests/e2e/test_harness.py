"""The harness itself: a crash is caught with its report; a missing item
is an error, not a hang."""

import pytest

from pads import Pads, PadsCrash, PadsError


@pytest.mark.parametrize("kind, cause", [("segv", "bad memory access"), ("assert", "assertion"), ("bounds", "out of range")])
def test_a_crash_is_reported_with_the_last_command(kind, cause):
    app = Pads(headless=True)
    with pytest.raises(PadsCrash) as e:
        app.cmd(f"crash {kind}")
    report = e.value.report + "\n".join(app.log)
    assert cause in report, report
    assert f"last command: crash {kind}" in report
    # Where: the back trace names it, or Odin's own message gives the line
    # (a back trace can't always be resolved: ARM Linux's addr2line).
    assert "drive_command" in report or "shell.odin(" in report or "could not resolve" in report, report


def test_a_missing_item_is_an_error(app):
    with pytest.raises(PadsError, match="no item"):
        app.click("No Such Button")
    app.cmd("wait 1")  # still alive


def test_items_and_state_describe_the_window(app):
    assert app.has("pad A1")
    assert any(i["label"] == "Sequence" for i in app.items("Sequence"))
    s = app.state()
    assert s["selected"] == 0 and s["bank"] == 0 and not s["playing"]
    assert s["browser"]["favorites"] == ["Documents", "Project"]
