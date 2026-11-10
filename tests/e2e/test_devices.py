"""The bottom panel as a device view: a pad's chain (its sampler with its
own tabs, its EQ, its inserts, + to add one), a bus's chain from the
mixer, a performance effect; choosing a pad shows its chain again."""

import os


def test_chains_in_the_bottom_panel(app, fixtures):
    app.cmd(f"load 0 {os.path.join(fixtures, 'kick.wav')}")
    app.cmd("select 0")
    s = app.state()
    assert s["track"] == "pad 1" and s["detail_tab"] == "Sample", (s["track"], s["detail_tab"])
    # Its EQ, then + for an insert, then another.
    app.click("EQ", window="detail")
    assert app.state()["detail_tab"] == "EQ"
    app.expect_item("Low", window="detail")
    app.panel("Mixer")
    app.click("A1 slot 1", window="mixer")
    app.click("add Delay", window="detail")
    assert app.pad(0)["inserts"][0] == "Delay"
    s = app.state()
    assert s["detail_tab"] == "Effect" and s["track"] == "pad 1"
    app.click("A1 slot 2", window="mixer")
    app.click("add Reverb", window="detail")
    assert app.pad(0)["inserts"] == ["Delay", "Reverb"]
    app.screenshot("pad_chain")
    # A bus's chain, from its slot in the mixer.
    app.click("Bus A slot 1", window="mixer")
    assert app.state()["track"] == "bus 1"
    app.click("add Compressor", window="detail")
    assert app.state()["buses"][0]["slots"][0] == "Compressor"
    app.screenshot("bus_chain")
    # Choosing a pad shows its chain again (its sampler in front).
    app.click("pad A1", window="detail")
    s = app.state()
    assert s["track"] == "pad 1", s["track"]
    # A performance effect: its device.
    app.panel("Perform")
    app.click("fx 5", window="perform", right=True)
    app.click("Edit Effect")
    s = app.state()
    assert s["track"] == "perf 5" and s["detail_tab"] == "Effect"
