"""Pads' note modes on the virtual Push 2 (scales-chords stage 4): Scale's
layouts on the 8x8 grid (Fourths, Thirds, Sequential, Chromatic; Shift +
Layout, Octave), the Chords grid (degrees across, variations up; what a
small key can't make dark), the Progressions grid (the chords, an octave
up, the bass down; the one playing lit), Pads' Harmony view on the
display (the key, the chord playing by name, the progression), its
encoders, and Note following the window's play mode both ways."""

import os
import shutil
import time

from test_push2 import display_png, pads, plug, press, settle, shows, turn  # noqa: F401 (pads: its fixture)

NOTE, LAYOUT, SHIFT, OCTAVE_UP, SESSION = 0x32, 0x1F, 0x31, 0x37, 0x33
UPPER_1 = 8  # View_Button.Upper_1's bit

# Where the images are copied for the report (if it exists).
SHOTS = os.environ.get("HARMONY_SHOTS", "")


def note_of(col, row):
    """The Push pad (its MIDI note) of grid cell `col`, `row` (0, 0 bottom left)."""
    return 36 + row * 8 + col


def cell(pads, col, row):
    return pads.api("perform_cell", col=col, row=row)


def hit(pads, col, row, hold=False):
    """Cell `col`, `row` pressed on the Push (and let go unless `hold`)."""
    pads.cmd(f"midiport play push 90 {note_of(col, row):02X} 64")
    pads.wait(3)
    if not hold:
        pads.cmd(f"midiport play push 80 {note_of(col, row):02X} 00")
        pads.wait(3)


def let_go(pads, col, row):
    pads.cmd(f"midiport play push 80 {note_of(col, row):02X} 00")
    pads.wait(3)


def playing_notes(pads):
    cp = pads.api("perform_chord_playing")
    return [pads.api("perform_chord_playing_note", index=i) for i in range(cp["count"])] if cp["ok"] else []


def rgb(c):
    return (c >> 16 & 255, c >> 8 & 255, c & 255)


def scaled(c, f):
    return tuple(int(min(max(x * f, 0), 255)) for x in rgb(c))


def save(pads, name):
    path = display_png(pads, os.path.join(pads.out_dir, f"harmony_{name}.png"))
    if SHOTS:
        os.makedirs(SHOTS, exist_ok=True)
        shutil.copy(path, os.path.join(SHOTS, f"push2_{name}.png"))
    return path


def shown(pads, frames=60):
    """The chord the Harmony view names, once it has drawn it."""
    for _ in range(frames):
        time.sleep(0.02)
        pads.wait(2)
        s = pads.state()["harmony_shown"]
        if s:
            return s
    return ""


def setup(pads):
    plug(pads)
    pads.cmd("synth 0")
    pads.cmd("select 0")
    pads.wait(3)


def test_scale_mode_layouts_on_the_grid(pads):
    setup(pads)
    press(pads, NOTE)
    pads.wait(5)
    assert pads.api("perform_state")["play_mode"] == "Scale"
    assert pads.api("key_state")["layout"] == "Fourths"
    # C major in fourths: C at the bottom left (two octaves down), D beside
    # it, F above it (its row F G A B).
    assert [cell(pads, 0, 0)["pitch"], cell(pads, 1, 0)["pitch"], cell(pads, 0, 1)["pitch"], cell(pads, 3, 1)["pitch"]] == [-24, -22, -19, -13]
    assert cell(pads, 0, 0)["root"] and cell(pads, 7, 0)["root"] and not cell(pads, 1, 0)["root"]
    assert pads.api("perform_cell_name", col=0, row=0) == "C1"
    settle(pads)
    colour = pads.api("pad_state", pad=0)["color"]
    assert shows(pads, note_of(0, 0)) == rgb(colour)  # a root: the pad's colour
    assert shows(pads, note_of(1, 0)) == (40, 40, 40)  # the key's others: dim white
    struck = pads.api("pad_struck", pad=0)
    hit(pads, 1, 0, hold=True)
    settle(pads)
    assert shows(pads, note_of(1, 0)) == (0, 255, 0)  # held: green
    let_go(pads, 1, 0)
    assert pads.api("pad_struck", pad=0) > struck
    save(pads, "scale_fourths")
    # Shift + Layout: Thirds (each row a third up: C, E), then Sequential.
    pads.cmd(f"midiport play push B0 {SHIFT:02X} 7F")
    press(pads, LAYOUT)
    pads.cmd(f"midiport play push B0 {SHIFT:02X} 00")
    pads.wait(5)
    assert pads.api("key_state")["layout"] == "Thirds"
    assert pads.api("perform_state")["play_mode"] == "Scale"  # (still Note: Layout alone is the drums)
    assert cell(pads, 0, 1)["pitch"] == -20
    # Encoder 4 on the Harmony view: the layout (Sequential: eight a row).
    turn(pads, 3, 3)
    assert pads.api("key_state")["layout"] == "Sequential"
    assert cell(pads, 0, 1)["pitch"] == -10  # (D: the row's ninth note)
    # Chromatic: every semitone, rows a fourth apart; out of key dimmer.
    pads.api("key_set_layout", layout="Chromatic")
    pads.wait(3)
    c1 = cell(pads, 1, 0)
    assert c1["pitch"] == -23 and not c1["in_key"] and c1["playable"]
    assert cell(pads, 0, 1)["pitch"] == -19 and cell(pads, 0, 1)["in_key"]
    settle(pads)
    assert shows(pads, note_of(1, 0)) == (16, 16, 16)  # C#: out of key, dim
    assert shows(pads, note_of(2, 0)) == (40, 40, 40)  # D: in key
    save(pads, "scale_chromatic")
    # A minor in fourths: A at the bottom left, D above it.
    pads.api("key_set", root=9, scale="Minor")
    pads.api("key_set_layout", layout="Fourths")
    pads.wait(3)
    assert [cell(pads, 0, 0)["pitch"], cell(pads, 2, 0)["pitch"], cell(pads, 0, 1)["pitch"]] == [-15, -12, -10]
    # Octave Up: the grid an octave higher.
    press(pads, OCTAVE_UP)
    pads.wait(5)
    assert pads.api("key_state")["octave"] == 1 and cell(pads, 0, 0)["pitch"] == -3
    save(pads, "scale_a_minor")
    assert 0 < pads.state()["harmony_draw_us"][0] <= pads.state()["harmony_draw_us"][1]


def test_the_chords_grid_and_a_pentatonic_keys_dark_cells(pads):
    setup(pads)
    press(pads, NOTE)
    press(pads, NOTE)  # (again: Chords)
    pads.wait(5)
    assert pads.api("perform_state")["play_mode"] == "Chords"
    # C major: eight columns (the eighth I an octave up), rows the variations.
    assert pads.api("perform_cell_name", col=1, row=0) == "ii Dm"
    assert pads.api("perform_cell_name", col=4, row=1) == "V7 G7"
    assert pads.api("perform_cell_name", col=7, row=0) == "I C" and cell(pads, 7, 0)["pitch"] == 12
    assert pads.api("perform_cell_name", col=1, row=4) == "iiadd9 Dmadd9"
    hit(pads, 1, 1, hold=True)  # ii7: Dm7
    assert pads.api("perform_chord_playing")["held"]
    assert sorted(n % 12 for n in playing_notes(pads)) == [0, 2, 5, 9]
    assert shown(pads) == "ii7 Dm7"
    settle(pads)
    assert cell(pads, 1, 1)["playing"]
    save(pads, "chords_c_major")
    let_go(pads, 1, 1)
    assert not pads.api("perform_chord_playing")["held"]
    # C major pentatonic: five columns; its triads only on I and vi, its
    # sus2s on the others it has.
    pads.api("key_set", root=0, scale="Major_Pentatonic")
    pads.wait(3)
    assert [cell(pads, c, 0)["kind"] for c in range(8)] == ["Chord"] * 5 + ["None"] * 3
    triads = [cell(pads, c, 0)["playable"] for c in range(5)]
    assert triads == [True, False, False, False, True], triads
    assert cell(pads, 1, 3)["playable"]  # Dsus2: D E A
    assert pads.api("perform_cell_name", col=1, row=0) == "–"
    settle(pads)
    colour = pads.api("pad_state", pad=0)["color"]
    assert shows(pads, note_of(0, 0)) == scaled(colour, 0.45)  # the tonic's column: the pad's colour
    assert shows(pads, note_of(1, 0)) is None  # none: dark
    assert shows(pads, note_of(5, 0)) is None  # past the key's degrees: dark
    assert shows(pads, note_of(4, 0)) not in (None, scaled(colour, 0.45))  # vi: its degree's colour
    hit(pads, 4, 0, hold=True)
    assert shown(pads, 90) == "vi Am"
    save(pads, "chords_pentatonic")
    let_go(pads, 4, 0)


def test_the_progressions_grid_its_voicings_and_the_bank_on_the_encoders(pads):
    setup(pads)
    pads.api("perform_set_play_mode", mode="Progressions")  # (the window: the Push follows)
    for _ in range(10):
        time.sleep(0.05)
        pads.wait(2)
    assert pads.api("progression_numerals") == "I V vi IV"
    # One row of chords, the row above an octave up, the next the bass down.
    assert [pads.api("perform_cell_name", col=c, row=0) for c in range(5)] == ["I C", "V G", "vi Am", "IV F", ""]
    assert cell(pads, 2, 1)["voicing"] == "Octave_Up" and cell(pads, 2, 2)["voicing"] == "Bass_Down"
    assert cell(pads, 0, 3)["kind"] == "None"
    hit(pads, 0, 0)
    base = playing_notes(pads)
    assert base == [0, 4, 7]
    hit(pads, 0, 1)  # I an octave up
    assert playing_notes(pads) == [n + 12 for n in base]
    hit(pads, 0, 2)  # I with its bass an octave down
    assert playing_notes(pads) == [-12] + base
    cp = pads.api("perform_chord_playing")
    assert cp["index"] == 0 and cp["voicing"] == "Bass_Down" and not cp["held"]
    # Played elsewhere (the API, as another surface or the window would):
    # the chord playing lit bright on the Push.
    pads.api("perform_play_cell", col=2, row=0, on=True, velocity=0.8)
    settle(pads)
    assert cell(pads, 2, 0)["playing"] and not cell(pads, 0, 0)["playing"]
    colour = pads.api("pad_state", pad=0)["color"]
    vi = shows(pads, note_of(2, 0))
    assert vi is not None and max(vi) == 255  # playing: its colour bright
    assert shows(pads, note_of(0, 0)) == scaled(colour, 0.45)
    assert shown(pads) == "vi Am"
    save(pads, "progressions")
    pads.api("perform_play_cell", col=2, row=0, on=False)
    # The bank on encoders 5 (the progression) and 4 (the style).
    name = pads.api("progression_name")
    turn(pads, 4, 3)
    assert pads.api("progression_name") == pads.api("progression_bank_name", index=1) != name
    style = pads.api("progression_bank_style", index=1)
    turn(pads, 3, 3)
    assert pads.api("progression_bank_style", index=next(i for i in range(pads.api("progression_bank_count")) if pads.api("progression_bank_name", index=i) == pads.api("progression_name"))) != style
    hit(pads, 1, 0, hold=True)
    shown(pads)
    save(pads, "progressions_next_style")
    let_go(pads, 1, 0)


def test_note_follows_the_play_mode_both_ways(pads):
    setup(pads)
    # The Push: Note, again and again: Scale, Chords, Progressions, Scale.
    modes = []
    for _ in range(4):
        press(pads, NOTE)
        pads.wait(4)
        modes.append(pads.api("perform_state")["play_mode"])
    assert modes == ["Scale", "Chords", "Progressions", "Scale"], modes
    assert pads.state()["play_mode"] == "Scale"  # (the window's)
    # The display: Pads' Harmony view, the mode lit on its upper row.
    for _ in range(10):
        time.sleep(0.05)
        pads.wait(2)
    assert pads.api("view_state", kind="Harmony", page=0)["lit"] & (1 << UPPER_1)
    # The view's upper row: Chords.
    pads.cmd("midiport play push B0 67 7F")  # (Upper 2: CC 103)
    pads.cmd("midiport play push B0 67 00")
    for _ in range(10):
        time.sleep(0.05)
        pads.wait(2)
    assert pads.api("perform_state")["play_mode"] == "Chords"
    # Session: Pads mode again (the window too).
    press(pads, SESSION)
    pads.wait(5)
    assert pads.api("perform_state")["play_mode"] == "Pads"
    # The window: Chords; the Push's grid plays its chords.
    pads.api("perform_set_play_mode", mode="Chords")
    for _ in range(10):
        time.sleep(0.05)
        pads.wait(2)
    hit(pads, 4, 0)
    cp = pads.api("perform_chord_playing")
    assert cp["ok"] and cp["degree"] == 4 and cp["variation"] == "Triad"
    # The window: Pads; the Push's grid its pads again (a press selects).
    pads.api("perform_set_play_mode", mode="Pads")
    for _ in range(10):
        time.sleep(0.05)
        pads.wait(2)
    hit(pads, 3, 0)
    assert pads.api("perform_state")["selected"] == 3


def test_the_windows_toolbar_and_long_chord_names(pads):
    pads.cmd("synth 0")
    pads.cmd("select 0")
    pads.api("perform_set_play_mode", mode="Progressions")
    pads.wait(4)
    pads.screenshot("harmony_toolbar_progressions")
    pads.api("perform_set_play_mode", mode="Chords")
    pads.api("perform_set_chord_page", page=1)
    pads.wait(4)
    pads.screenshot("harmony_chords_add9")
    assert pads.state()["keyboard"][1] == "iiadd9 Dmadd9"
    if SHOTS:
        os.makedirs(SHOTS, exist_ok=True)
        for n in ("harmony_toolbar_progressions", "harmony_chords_add9"):
            src = os.path.join(pads.out_dir, n + ".png")
            if os.path.exists(src):
                shutil.copy(src, os.path.join(SHOTS, f"window_{n[8:]}.png"))
