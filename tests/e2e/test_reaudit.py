"""What the UI re-audit fixed: Escape closes Settings (but first stops a
shortcut being recorded); choosing another pad shows its sound, not the
MIDI page the last one had in front; the slicer's toolbar, one line, its
settings behind its dropdowns; the toolbar and the mixer whole in a small
window."""

import os


def test_escape_closes_settings(app):
    app.key("cmd+,")
    assert app.state()["settings_open"]
    app.wait(3)
    app.key("esc")
    app.until(lambda s: not s["settings_open"], what="Settings closed by Escape")


def test_another_pad_shows_its_sound_not_midi(app, fixtures):
    app.cmd(f"load 0 {os.path.join(fixtures, 'kick.wav')}")
    app.cmd(f"load 1 {os.path.join(fixtures, 'hat.wav')}")
    app.cmd("select 0")
    app.cmd("panel midi")
    app.until(lambda s: s["detail_tab"] == "MIDI", what="A1's MIDI page in front")
    app.click("pad A2", window="detail")
    s = app.until(lambda s: s["detail_tab"] != "MIDI", what="A2's sound in front")
    assert s["track"] == "pad 2", s["track"]


def test_slicer_settings_behind_its_dropdowns(app, fixtures):
    app.cmd(f"slicer 0 {os.path.join(fixtures, 'loop.wav')}")
    app.cmd("select 0")
    app.cmd("panel sample")
    app.wait(3)
    app.click("slice playing", window="detail")
    app.click("Gate")
    app.key("esc")
    app.click("slice by", window="detail")
    app.expect_item("slice sensitivity")
    app.key("esc")
    app.screenshot("reaudit_slicer")


def test_a_small_window_keeps_everything(app, fixtures):
    app.cmd(f"load 0 {os.path.join(fixtures, 'kick.wav')}")
    app.cmd("size 1100 760")
    app.wait(4)
    # The toolbar's last control (the metronome's settings) still shows.
    app.expect_item("Metronome settings")
    app.cmd("panel mixer")
    app.wait(4)
    app.expect_item("A1 name")  # a strip's name plate, at its foot
    app.screenshot("reaudit_small_mixer")
