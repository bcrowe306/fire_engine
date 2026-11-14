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
