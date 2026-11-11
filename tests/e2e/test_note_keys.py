"""The sequence editor's keys on the selected notes: Backspace (the Mac's
delete) removes them, 0 mutes and unmutes them (they stay, hollow and
silent), Cmd+A selects every note, the arrows nudge them a grid step
(Shift: a bar) or a row, Cmd+C / Cmd+V / Cmd+D copy, paste and duplicate.
And the toolbar's Pattern | Song switch and launch setting."""

import os


def loaded(app, fixtures):
    app.cmd(f"load 0 {os.path.join(fixtures, 'kick.wav')}")
    app.cmd(f"load 1 {os.path.join(fixtures, 'hat.wav')}")
    for b in range(4):
        app.cmd(f"note 0 {b} 0.25 1")
    app.cmd("note 1 0.5 0.25 0.8")
    app.cmd("bars 2")
    app.panel("Sequence")


def starts(app, pad):
    return sorted(n["start"] for n in app.state()["note_list"] if n["pad"] == pad)


def test_mute_and_delete(app, fixtures):
    loaded(app, fixtures)
    app.click("seq row 0", window="sequence")  # pad 1's four notes
    assert app.state()["selected_notes"] == 4
    app.key("0")
    s = app.state()
    assert s["muted_notes"] == 4 and s["notes"] == 5 and s["undo"] == "Mute Notes", s["undo"]
    assert s["selected_notes"] == 4  # still selected, muted
    app.screenshot("notes_muted")
    app.key("0")  # all muted: unmuted
    assert app.state()["muted_notes"] == 0
    app.key("0")
    app.key("cmd+z")
    assert app.state()["muted_notes"] == 0
    app.click("seq row 0", window="sequence")
    app.key("backspace")
    s = app.state()
    assert s["notes"] == 1 and s["selected_notes"] == 0, s["notes"]


def test_select_all_nudge_copy(app, fixtures):
    loaded(app, fixtures)
    app.click("seq row 1", window="sequence")  # the hat's one note, at 0.5
    app.key("right")  # a 1/16 step
    assert starts(app, 1) == [0.75], starts(app, 1)
    app.key("shift+right")  # a bar
    assert starts(app, 1) == [4.75], starts(app, 1)
    app.key("down")  # a row down: onto pad 1's row (rows count from the bottom)
    assert starts(app, 1) == [] and 4.75 in starts(app, 0)
    app.key("down")  # off the bottom row: nothing moves
    assert 4.75 in starts(app, 0)
    app.key("up")
    assert starts(app, 1) == [4.75]
    app.key("left")
    assert starts(app, 1) == [4.5]
    app.key("cmd+a")
    assert app.state()["selected_notes"] == 5
    app.key("up")  # pad 1's notes onto pad 2's row, pad 2's onto pad 3's
    s = app.state()
    assert sorted(n["pad"] for n in s["note_list"]) == [1, 1, 1, 1, 2], s["note_list"]
    app.key("cmd+z")
    app.click("seq row 0", window="sequence")
    app.key("cmd+d")  # after themselves: the next bar
    s = app.state()
    assert s["notes"] == 9 and starts(app, 0) == [0, 1, 2, 3, 4, 5, 6, 7], starts(app, 0)


def test_the_toolbar_switches_mode_and_launch(app, fixtures):
    loaded(app, fixtures)
    app.click("Song", window="##toolbar")
    assert app.state()["song_mode"]
    app.click("Pattern", window="##toolbar")
    assert not app.state()["song_mode"]
    app.click("##launch_at", window="##toolbar")
    app.click("Next beat")
    assert app.state()["launch"] == "Beat"
    app.click("##launch_at", window="##toolbar")
    app.click("At once")
    assert app.state()["launch"] == "Now"
