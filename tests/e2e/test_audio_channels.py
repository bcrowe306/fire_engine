"""An interface's channels in Settings > Audio, by mouse and keys, on the
simulated driver's 8-in/8-out test interface (--fake-interface): the
interface chosen, channels switched on, a channel named, main and the cue
on their pairs, Apply and Keep; what opens; an audio track's inputs by
name; and the interface gone at the next start (the settings kept)."""

import os
import tempfile

from pads import Pads

IFACE = "Test Interface 8x8"


def ini(prefs):
    return open(os.path.join(prefs, "settings.ini")).read()


def test_channels_chosen_named_and_kept():
    prefs = tempfile.mkdtemp(prefix="pads_prefs_")
    app = Pads(prefs=prefs, extra=("--fake-interface",))
    try:
        app.key("cmd+,")
        app.click("Audio", window="settings")
        app.click("output interface")
        app.click(IFACE)
        app.click("input interface")
        app.click(IFACE)
        app.click("In 3")
        app.click("Out 3")
        app.click("Out 4")
        app.click("in 1 alias")
        app.type("Kick mic")
        app.key("enter")
        app.click("cue output")
        app.click("Out 3/4 · Phones L")
        app.hover("cue output")
        app.cmd("scroll 0 -20")  # (down to Apply)
        app.wait(3)
        app.click("Apply")
        app.click("Keep")
        s = app.state()
        assert s["audio_inputs"] == [1, 2, 3] and s["audio_outputs"] == [1, 2, 3, 4], (s["audio_inputs"], s["audio_outputs"])
        text = ini(prefs)
        assert "[audio.device.fake:8x8]" in text and "inputs = 1,2,3" in text and "in.1 = Kick mic" in text and "cue = 3" in text, text
        app.hover("Apply")
        app.cmd("scroll 0 20")  # (back up to the lists)
        app.wait(3)
        app.expect_item("test 3/4")  # each open pair's tone
        app.click("test 3/4")
        app.key("esc")
        # An audio track's inputs: the open ones, by name.
        app.cmd("command pad.audio pad 0")
        app.cmd("select 0")
        s = app.state()
        assert app.pad(0)["input"] == "In 1/2 · Kick mic", app.pad(0)["input"]
        app.screenshot("audio_channels")
    finally:
        app.close()
    # The next start without that interface: the system's (here, the fake
    # driver's own) device, the settings kept for when it is back.
    app = Pads(prefs=prefs)
    try:
        s = app.state()
        assert s["audio_outputs"] == [1, 2], s["audio_outputs"]
        assert "[audio.device.fake:8x8]" in ini(prefs) and "in.1 = Kick mic" in ini(prefs)
    finally:
        app.close()
