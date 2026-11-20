"""The project key and the note modes, by mouse: the Play mode menu's five
modes, Chords mode's pads (a chord a pad, named; their rows paged), the Key
dialog (key, scale, octave, voicing), the status bar's key, Progressions
mode with its dialog (the bank by style, the editor, saved as yours), the
piano roll's key shading and Fold to key, and the arpeggiator's In key."""

import os


def synth(app):
    app.cmd("synth 0")
    app.cmd("select 0")
    app.wait(3)


def test_the_play_mode_menu_and_chords_mode(app):
    synth(app)
    app.click("toolbar play mode")
    for name in ("Pads", "Scale", "Chords", "Progressions", "Velocity"):
        app.expect_item(name)
    app.click("Chords")
    s = app.state()
    assert s["play_mode"] == "Chords" and s["bank"] == 0, s["play_mode"]
    # C major: degrees across, the triads on the bottom row, 7ths above.
    assert s["keyboard"][0:4] == ["I C", "ii Dm", "iii Em", "IV F"], s["keyboard"]
    assert s["keyboard"][4] == "Imaj7 Cmaj7" and s["keyboard"][12] == "Isus2 Csus2", s["keyboard"]
    app.screenshot("chords_mode")
    # A pad: its chord's three notes.
    app.click("pad A1")
    app.wait(4)
    app.cmd("expect struck 0 3")
    # Bank B: the next four degrees.
    app.click("B")
    assert app.state()["keyboard"][0:4] == ["V G", "vi Am", "vii° Bdim", "I C"], app.state()["keyboard"]
    app.click("A")
    # The rows' second page: add9, 6th, the inversions.
    app.click("add9 6 inv")
    s = app.state()
    assert s["chord_page"] == 1 and s["keyboard"][8] == "I/3 C/E", s["keyboard"]
    app.screenshot("chords_page2")
    app.click("Triad 7 sus")
    assert app.state()["chord_page"] == 0


def test_the_key_dialog_and_the_status_bar(app):
    synth(app)
    app.cmd("mode chords")
    app.wait(2)
    assert app.state()["key"] == "C major"
    app.click("status key")  # the status bar's key opens the Key dialog
    app.wait(2)
    assert app.api("ui_dialog_title") == "Key"
    app.click("key scale")
    app.click("Dorian")
    app.click("key root")
    app.click("F#")  # (not D: the bank tabs have one)
    app.wait(2)
    s = app.state()
    assert s["key"] == "F# dorian" and s["keyboard"][0] == "i F#m", (s["key"], s["keyboard"][0])
    # The voicing: voice leading off, open, a strum.
    app.click("voice leading")
    app.click("key spread")
    app.click("Open")
    ks = app.api("key_state")
    assert not ks["voice_leading"] and ks["spread"] == "Open", ks
    app.screenshot("key_dialog")
    app.click("Close")
    app.wait(2)
    assert app.items("status key")


def test_progressions_the_bank_the_editor_and_yours(app):
    synth(app)
    app.click("Play the pads as a progression's chords, on the selected pad (Progressions)")
    app.wait(2)
    s = app.state()
    assert s["play_mode"] == "Progressions" and s["progression"] == "I V vi IV", s["progression"]  # (in C major)
    assert s["keyboard"][0:4] == ["I C", "V G", "vi Am", "IV F"], s["keyboard"]
    assert s["keyboard"][4] == "", s["keyboard"]  # (four chords: the rest empty)
    app.click("progression")  # its dialog
    app.wait(2)
    assert app.api("ui_dialog_title") == "Progressions"
    # The bank by style: Jazz's first.
    app.click("progression style")
    app.click("Jazz")
    app.click("bank Turnaround")
    app.wait(2)
    assert app.state()["progression"] == "I7 vi7 ii7 V7"
    app.screenshot("progressions_dialog")
    # The editor: add a chord (a copy of the last), change it, move it up,
    # take one out, rename, save as yours.
    app.click("add chord")
    assert app.state()["progression"] == "I7 vi7 ii7 V7 V7"
    app.click("chord 5 variation")
    app.click("sus4")
    assert app.state()["progression"] == "I7 vi7 ii7 V7 Vsus4"
    app.click("chord 5 up")
    assert app.state()["progression"] == "I7 vi7 ii7 Vsus4 V7"
    app.click("chord 1 remove")
    assert app.state()["progression"] == "vi7 ii7 Vsus4 V7"
    app.click("progression name")
    app.key("cmd+a")
    app.type("My Turn")
    app.key("return")
    app.click("save progression")
    app.wait(2)
    assert app.api("progression_mine_count") == 1
    app.click("progression style")
    app.click("Yours")
    app.expect_item("mine My Turn")
    app.screenshot("progressions_editor")
    app.click("Close")
    app.wait(2)
    s = app.state()
    assert s["progression_name"] == "My Turn" and s["keyboard"][0] == "vi7 Am7", (s["progression_name"], s["keyboard"][0])


def test_the_piano_roll_shades_and_folds_to_the_key(app):
    synth(app)
    for p in (0, 1, 2):  # C, C#, D on pad A1
        app.api("sequence_add_note", slot=0, n={"start": p, "length": 0.5, "pad": 0, "pitch": p, "velocity": 0.8, "probability": 1})
    app.panel("Sequence")
    app.click("seq row 0", window="sequence", double=True)  # A1's piano roll
    assert app.state()["piano_roll"]
    app.wait(2)
    rows = app.state()["seq_row_count"]
    assert rows == 97, rows  # four octaves each way
    app.click("fold to key", window="sequence")
    app.wait(2)
    s = app.state()
    # C major's notes over the 8 octaves, and C# (it has a note).
    assert s["key_fold"] and s["seq_row_count"] == 57 + 1, s["seq_row_count"]
    app.screenshot("piano_roll_key")
    app.click("fold to key", window="sequence")


def test_the_arpeggiators_in_key(app):
    synth(app)
    app.cmd("panel midi")
    app.wait(3)
    app.click("arp in key", window="detail")
    fx = app.api("sequence_midi_fx", pad=0)
    assert fx["arp_in_key"], fx
    assert app.state()["undo"] == "Arpeggiator"
