"""The Settings window (File > Settings…, Cmd+,): its pages down the left,
kept in settings.ini; the theme and zoom (clicks still land where they
should, zoomed); a shortcut changed by pressing it (and a clash taken);
the audio device applied and kept; what the tempo follows and the MIDI
clock out; what a new project starts with; CLAP plug-ins found by a scan
and offered in an effect slot."""

import os
import tempfile

import pytest

from pads import ROOT, Pads


def ini(app):
    return open(os.path.join(app.tmp, "prefs", "settings.ini")).read()


def test_pages_theme_and_zoom(app):
    app.key("cmd+,")
    assert app.state()["settings_open"]
    app.click("##preset")
    app.click("Midnight###pMidnight")
    s = app.state()
    assert s["theme"] == "Midnight" and s["dark"]
    assert "theme = Midnight" in ini(app)
    app.click("125%")
    assert abs(app.state()["zoom"] - 1.25) < 1e-6
    app.wait(3)
    # Zoomed, a click still lands on what it aims at.
    app.click("Recording")
    app.expect_item("Count-in clicks with the metronome off")
    app.screenshot("settings_zoomed")
    app.click("Appearance")
    app.click("100%")
    assert "zoom = 1" in ini(app)


def test_a_shortcut_changed_by_pressing_it(app):
    app.key("cmd+,")
    app.click("Keyboard")
    app.click("##kfilter")
    app.type("Metronome")
    app.click("key metronome")  # no shortcut of its own
    app.key("cmd+shift+m")
    assert "metronome = Cmd+Shift+M" in ini(app)
    app.key("esc")  # (closes the window)
    was = app.state()["metronome"]
    app.key("cmd+shift+m")
    assert app.state()["metronome"] != was
    # Undo's shortcut given to the metronome: the clash shown, and taken.
    app.key("cmd+,")
    app.click("Keyboard")
    app.click("key metronome")  # (still searched for)
    app.key("cmd+z")
    app.expect_item("Take it")
    app.click("Take it")
    assert "undo = none" in ini(app)


def test_audio_applied_and_kept_and_sync(app):
    app.key("cmd+,")
    app.click("Audio")
    app.click("##buffer")
    app.click("128 frames (2.7 ms)")
    app.click("Apply")
    app.expect_item("Keep")
    app.click("Keep")
    assert "buffer = 128" in ini(app)
    app.click("MIDI & Sync")
    app.click("##sync")
    app.click("MIDI clock in")
    assert app.state()["sync"] == "Midi_Clock" and "sync = midi_clock" in ini(app)
    app.click("Send MIDI clock to the output")
    assert app.state()["clock_out"]
    app.click("##sync")
    app.click("Pads (its own tempo)")
    assert app.state()["sync"] == "Internal"


def test_a_new_project_starts_with_the_settings():
    prefs = tempfile.mkdtemp(prefix="pads_prefs_")
    with open(os.path.join(prefs, "settings.ini"), "w") as f:
        f.write("# by hand\n[project]\ntempo = 97\nbeats = 3\nbuses = 6\n")
    app = Pads(prefs=prefs)
    try:
        s = app.state()
        assert s["bpm"] == 97 and len(s["buses"]) == 7, (s["bpm"], len(s["buses"]))
        app.key("cmd+,")
        app.click("Projects")
        app.click("Open the last project")
        text = open(os.path.join(prefs, "settings.ini")).read()
        assert text.startswith("# by hand") and "open_last = true" in text and "tempo = 97" in text
    finally:
        app.close()


@pytest.mark.skipif(not os.path.exists(os.path.join(ROOT, ".build", "clap", "FireOdin.clap")), reason="run ./scripts/clap.sh first")
def test_plugins_found_and_offered(app):
    app.cmd(f"plugin_folder {os.path.join(ROOT, '.build', 'clap')}")
    app.cmd("scan_plugins")
    app.until(lambda s: s["plugins"] >= 1, frames=300, what="the scan")
    effects = app.state()["plugin_effects"]
    assert effects, app.state()["plugins"]
    app.key("cmd+,")
    app.click("Plug-ins")
    app.expect_item(f"plugin {effects[0]}")
    app.screenshot("plugins")


def test_settings_naming_a_device_that_is_gone_still_start():
    # (An unplugged USB interface: on the simulated device this crashed at start.)
    prefs = tempfile.mkdtemp(prefix="pads_prefs_")
    with open(os.path.join(prefs, "settings.ini"), "w") as f:
        f.write("[audio]\noutput = no-such-device:2,1\ninput = no-such-device:2,1\nsample_rate = 0\nbuffer = 0\n")
    app = Pads(prefs=prefs)
    try:
        assert app.state()["slot"] >= 1  # up and answering
        text = open(os.path.join(prefs, "settings.ini")).read()
        assert "no-such-device" in text  # (kept: it is used again when it is back)
    finally:
        app.close()


def test_the_recording_offset_is_kept(app):
    app.key("cmd+,")
    app.click("Recording")
    app.expect_item("device latency")
    app.drag_by("recording offset", 40, 0)  # right: more
    assert "offset_frames = " in ini(app)
    line = [x for x in ini(app).splitlines() if x.startswith("offset_frames")][0]
    assert int(line.split("=")[1]) > 0, line
