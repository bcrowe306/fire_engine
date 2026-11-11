"""The synth device, used by mouse: a pad made a synth from its menu and
played; a source chip dragged onto a knob (a route), its ring's handle
dragged for the amount and right-clicked away; the envelope's handles
and the LFO's points drawn; a wavetable chosen; the voice modes."""


def synth_pad(app, pad="pad A1"):
    app.click(pad, window="detail", right=True)
    app.click("Synth")
    p = app.pad(0)
    assert p["kind"] == "Synth", p["kind"]
    return p


def tab(app, name):
    app.cmd(f"synth_tab {name.lower()}")
    app.wait(4)


def test_a_pad_becomes_a_synth_and_plays(app):
    synth_pad(app)
    for name in ("Osc", "Filter", "Env", "LFO", "Mod", "Effects", "Macro", "Global"):
        app.expect_item(name, window="detail")
    app.cmd("hit 0")
    p = app.until(lambda s: any(x["index"] == 0 and x["synth"]["voices"] == 1 for x in s["pads"]), what="a voice sounding")
    app.screenshot("synth_osc")
    app.cmd("release 0")
    app.until(lambda s: any(x["index"] == 0 and x["synth"]["voices"] == 0 for x in s["pads"]), frames=300, what="the voice ending")


def test_drag_a_source_onto_a_knob(app):
    synth_pad(app)
    tab(app, "Filter")
    app.drag("mod LFO 1", "Cutoff", to_window="detail")
    routes = app.pad(0)["synth"]["routes"]
    assert len(routes) == 1 and routes[0]["source"] == "LFO 1" and routes[0]["dest"] == "Filter 1 Cutoff", routes
    assert abs(routes[0]["amount"] - 0.25) < 1e-6
    assert app.state()["undo"] == "Add Modulation"
    app.screenshot("synth_ring")
    # The ring's handle: up for more.
    app.drag_by("Cutoff mod 1", 0, -20, window="detail")
    amt = app.pad(0)["synth"]["routes"][0]["amount"]
    assert amt > 0.35, amt
    # Right-click: gone.
    app.click("Cutoff mod 1", window="detail", right=True)
    assert app.pad(0)["synth"]["routes"] == []
    app.key("cmd+z")
    assert len(app.pad(0)["synth"]["routes"]) == 1


def test_the_envelope_and_lfo_editors(app):
    synth_pad(app)
    tab(app, "Env")
    # The attack's peak handle: dragged right, a longer attack.
    before = app.pad(0)["synth"]["params"].get("Env 1 Attack", 0.0005)
    x0, y0, x1, y1 = [i for i in app.items("synth envelope", "detail") if i["label"] == "synth envelope"][0]["rect"]
    ax = x0 + 10 + 2  # (a near-zero attack: its peak at the left, at the top)
    app.cmd(f"drag {ax} {y0 + 10} {ax + (x1 - x0) * 0.08} {y0 + 10} 12")
    app.wait(3)
    after = app.pad(0)["synth"]["params"].get("Env 1 Attack", 0)
    assert after > before * 10, (before, after)
    assert app.state()["undo"] == "Shape Envelope"
    tab(app, "LFO")
    n = app.pad(0)["synth"]["points"][0]
    app.click("synth lfo shape", window="detail", double=True, at=(0.25, 0.3))
    assert app.pad(0)["synth"]["points"][0] == n + 1
    app.screenshot("synth_lfo")


def test_choose_a_wavetable_and_voice_modes(app):
    synth_pad(app)
    tab(app, "Osc")
    app.click("wavetable", window="detail")
    app.click("Vowels")
    assert app.pad(0)["synth"]["tables"][0] == "Vowels"
    tab(app, "Global")
    app.click("Legato", window="detail")
    assert app.pad(0)["synth"]["params"]["Voice Mode"] == 2
    app.click("4×", window="detail")
    assert app.pad(0)["synth"]["params"]["Oversampling"] == 2
    app.screenshot("synth_global")


def test_keyboard_mode_banks_and_recording(app):
    synth_pad(app)
    app.cmd("mode keys")
    app.wait(3)
    a = app.state()["keyboard"]
    assert a[0] != "" and a[15] != "", a
    app.click("E", window="detail")  # (it opens on the bank holding C3: D, chromatic)
    b = app.state()["keyboard"]
    assert b[0] != a[0] and b[0] not in a, (a, b)  # the next 16 notes
    # A computer key plays the bank's note, and it records at that pitch.
    app.cmd("rec")
    app.cmd("play")
    app.wait(10)
    app.key("z")  # the bottom-left pad
    app.wait(20)
    app.cmd("stop")
    app.wait(5)
    notes = app.state()["note_list"]
    assert len(notes) == 1, notes
    assert notes[0]["pitch"] == 4, notes  # bank E's first pad: MIDI 64, four above C3 (chromatic: banks from C-2)
    app.cmd("mode pads")


def test_the_effects_chain(app):
    synth_pad(app)
    tab(app, "Effects")
    s = app.pad(0)["synth"]
    assert s["effects"][0] == "Chorus" and s["effects"][8] == "Reverb", s["effects"]
    # The reverb's switch: on, its page shown.
    app.click("effect Reverb on", window="detail")
    assert app.pad(0)["synth"]["params"]["Reverb On"] == 1
    app.click("effect Reverb", window="detail")
    app.expect_item("synth reverb view", window="detail")
    # Dragged onto the chorus: first in the chain.
    app.drag("effect Reverb", "effect Chorus", to_window="detail")
    fx = app.pad(0)["synth"]["effects"]
    assert fx[0] == "Reverb" and fx[1] == "Chorus", fx
    assert app.state()["undo"] == "Reorder Effects"
    app.cmd("hit 0")
    app.wait(20)
    app.screenshot("synth_effects")
    app.cmd("release 0")
    app.key("cmd+z")
    assert app.pad(0)["synth"]["effects"][0] == "Chorus"


def test_a_random_modulator(app):
    synth_pad(app)
    tab(app, "LFO")
    app.cmd("synth_lfo 9")
    app.wait(3)
    app.expect_item("synth random view", window="detail")
    app.click("random style", window="detail")
    app.click("Lorenz")
    assert app.pad(0)["synth"]["params"]["Random 1 Style"] == 3
    tab(app, "Filter")
    app.drag("mod Random 1", "Cutoff", to_window="detail")
    routes = app.pad(0)["synth"]["routes"]
    assert routes[-1]["source"] == "Random 1" and routes[-1]["dest"] == "Filter 1 Cutoff", routes
    app.cmd("hit 0")
    app.wait(10)
    tab(app, "LFO")
    app.cmd("synth_lfo 9")
    app.wait(5)
    app.screenshot("synth_random")
    app.cmd("release 0")


def test_the_wavetable_editor(app):
    synth_pad(app)
    tab(app, "Osc")
    app.click("edit wavetable", window="detail")
    app.click("new table")
    w = app.state()["wavetable"]
    assert w["open"] and w["positions"] == [0, 255] and w["sources"] == ["Harmonics", "Harmonics"], w
    assert app.pad(0)["synth"]["tables"][0] == "Wavetable"
    # The second keyframe (the saw): its 2nd harmonic dragged to the top.
    app.cmd("wavetable_key 2")
    app.wait(2)
    x0, y0, x1, y1 = [i for i in app.items("harmonics") if i["label"] == "harmonics"][0]["rect"]
    bw = (x1 - x0 - 24) / 64
    hx = x0 + 12 + bw * 1.5
    app.cmd(f"drag {hx} {y0 + 60} {hx} {y0 + 14} 8")
    app.wait(3)
    lv = app.state()["wavetable"]["levels"]
    assert lv[1] > 0.9, lv[:4]
    assert app.state()["undo"] == "Harmonic Level"
    # A new keyframe between (double-click on the strip).
    app.click("keyframes", double=True, at=(0.5, 0.5))
    w = app.state()["wavetable"]
    assert len(w["positions"]) == 3 and 100 < w["positions"][2] < 156, w["positions"]
    app.screenshot("wavetable_editor")
    app.key("cmd+z")
    assert len(app.state()["wavetable"]["positions"]) == 2


def test_presets(app):
    synth_pad(app)
    assert app.pad(0)["synth"]["preset"] == ""
    app.click("preset after", window="detail")
    assert app.pad(0)["synth"]["preset"] == "Init"
    app.click("preset after", window="detail")
    assert app.pad(0)["synth"]["preset"] == "Supersaw Lead"
    assert app.pad(0)["synth"]["params"]["Osc 1 Unison"] == 7
    assert app.state()["undo"] == "Load Preset"
    # From the menu: a pad.
    app.click("preset", window="detail")
    app.click("Warm Pad")
    assert app.pad(0)["synth"]["preset"] == "Warm Pad"
    # Saved as one of yours (in the test's own settings folder), then found in the menu.
    app.click("save preset", window="detail")
    app.click("preset name")
    app.key("cmd+a")
    app.type("My Pad")
    app.click("save")
    assert app.pad(0)["synth"]["preset"] == "My Pad"
    app.click("preset before", window="detail")
    assert app.pad(0)["synth"]["preset"] == "Noise Sweep"  # (the last built-in, before yours)
    app.click("preset", window="detail")
    app.click("My Pad")
    assert app.pad(0)["synth"]["preset"] == "My Pad" and app.pad(0)["synth"]["tables"][1] == "Vowels"
    app.screenshot("synth_presets")
