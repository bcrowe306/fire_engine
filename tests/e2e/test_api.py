"""The Pads API from another process: JSON lines over the control socket
(see docs/guides/api.md). What it does shows in the app (its state, the
toolbar), and what the app does shows through it."""


def test_transport_and_history_through_the_api(app):
    s = app.api("transport_state")
    assert not s["playing"] and s["bpm"] == 120
    app.api("transport_set_tempo", bpm=97.5)
    app.api("transport_set_time_signature", num=3, den=4)
    app.api("transport_set_metronome_sound", sound="Stick")
    st = app.state()
    assert st["bpm"] == 97.5 and st["time_sig"] == "3/4"
    assert app.api("history_undo_name") == "Metronome Sound"
    # The app's own undo (the key) is the API's history.
    app.key("cmd+z")
    assert app.api("history_undo_name") == "Time Signature"
    assert app.api("history_state")["redo_steps"] == 1
    app.api("history_redo")
    assert app.api("transport_state")["metronome_sound"] == "Stick"


def test_play_and_stop_through_the_api(app):
    app.api("transport_play")
    app.until(lambda s: s["playing"], what="playing")
    app.wait(30)
    assert app.api("transport_state")["beat"] > 0
    # The toolbar's Stop (the mouse) and the API agree.
    app.click("Stop (Space); press twice to silence every sound")
    app.wait(2)
    assert not app.api("transport_state")["playing"]


def test_failures_say_why(app):
    r = app.api("transport_set_tempo", check=False, bpm=5)
    assert r["result"] == "Invalid_Argument" and "40..300" in r["error"]
    r = app.api("no_such_method", check=False)
    assert r["result"] == "Not_Found"
    # (A drive command still works between API calls.)
    app.cmd("tempo 111")
    assert app.api("transport_state")["bpm"] == 111


def test_project_through_the_api(app, tmp_path):
    assert app.api("project_state")["untitled"]
    app.api("transport_set_tempo", bpm=101)
    # Changes not saved: another project only if they may go.
    r = app.api("project_new", check=False, discard_changes=False)
    assert r["result"] == "Busy"
    app.api("project_save_as", path=str(tmp_path / "Through"))
    assert app.api("project_name") == "Through"
    assert app.state()["untitled"] is False
    app.api("project_rename", name="Renamed")
    assert app.api("project_dir").endswith("Renamed.pads")
    app.api("project_new", discard_changes=False)
    assert app.state()["bpm"] == 120
    app.api("project_open", dir=str(tmp_path / "Renamed.pads"), discard_changes=False)
    assert app.state()["bpm"] == 101


def test_settings_through_the_api(app):
    n = app.api("settings_count")
    names = [app.api("settings_name", index=k) for k in range(n)]
    assert "project.tempo" in names and "midi.sync" in names
    info = app.api("settings_info", name="project.tempo")
    assert info["kind"] == "Number" and info["min"] == 40
    app.api("settings_set_number", name="mixer.narrow", value=1)
    assert app.state()["mixer_view"]["narrow"] is True
    app.cmd("setting mixer.narrow false")
    assert app.api("settings_get_text", name="mixer.narrow") == "false"
    r = app.api("settings_set_text", check=False, name="midi.sync", value="Tape")
    assert r["result"] == "Invalid_Argument" and "Internal" in r["error"]


def test_pads_and_params_through_the_api(app, fixtures):
    import os
    app.api("pad_load_sample", pad=2, path=os.path.join(fixtures, "kick.wav"))
    app.api("pad_set_name", pad=2, name="Big Kick")
    app.api("pad_set_volume", pad=2, db=-8)
    assert app.api("pad_name", pad=2) == "Big Kick"
    s = app.api("pad_state", pad=2)
    assert s["used"] and s["volume"] == -8 and s["kind"] == "Sampler"
    assert app.pad(2)["volume"] == -8  # (the app's own state says so)
    # Any parameter, by reference: its fader, as the Mixer's.
    ref = {"track": "Pad", "index": 2, "device": "Volume"}
    app.api("param_set", ref=ref, value=-3)
    assert app.api("param_get", ref=ref) == -3
    assert app.api("param_text", ref=ref) == "-3.0 dB"
    app.wait(2)
    sound = {"track": "Pad", "index": 2, "device": "Sound"}
    n = app.api("param_count", ref=sound)
    names = [app.api("param_name", ref=app.api("param_at", ref=sound, index=k)) for k in range(n)]
    assert "Cutoff" in names
    r = app.api("pad_set_volume", check=False, pad=2, db=40)
    assert r["result"] == "Invalid_Argument"


def test_effects_through_the_api(app, fixtures):
    import os
    app.api("pad_load_sample", pad=0, path=os.path.join(fixtures, "kick.wav"))
    kinds = [app.api("effect_kind_name", kind=k) for k in range(app.api("effect_kind_count"))]
    slot = {"place": "Insert", "index": 0, "slot": 0}
    app.api("effect_set", s=slot, kind=kinds.index("Reverb"))
    assert app.api("effect_name", s=slot) == "Reverb"
    assert app.pad(0)["inserts"][0] == "Reverb"
    app.api("effect_set_on", s=slot, on=False)
    assert app.api("effect_state", s=slot)["on"] is False
    app.key("cmd+z")
    assert app.api("effect_state", s=slot)["on"] is True


def test_the_mixer_through_the_api(app):
    b = app.api("mixer_add_bus")
    app.api("mixer_rename_bus", bus=b, name="Drums")
    app.api("mixer_set_pad_output", pad=0, output={"kind": "Bus", "index": b})
    assert app.api("mixer_pad_output", pad=0) == {"kind": "Bus", "index": b}
    app.api("mixer_set_bus_volume", bus=b, db=-4)
    st = app.state()
    assert any(x["name"] == "Drums" and x["volume"] == -4 for x in st["buses"])
    g = app.api("mixer_group_pads", pads=[2, 3], name="Toms")
    assert app.api("mixer_bus_name", bus=g) == "Toms"
    r = app.api("mixer_set_bus_output", check=False, bus=b, output={"kind": "Bus", "index": b})
    assert r["result"] == "Invalid_Argument"
