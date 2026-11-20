package pads_core

import pm "../model"

// Scale mode's degrees below the selected pad's own note that bank A's
// first pad starts at: the root five octaves down (the bottom of the MIDI
// range, whatever the octave set). A slicer's keys start at its first slice.
keyboard_bottom :: proc(c: ^Core) -> int {
	if c.m.project.pads[c.selected].kind == .Slicer do return 0
	n := pm.scale_size(c.keys.scale)
	return n * (5 + c.keys.octave)
}

// What one of the note modes' keys plays: its notes (from the selected
// pad's own, low to high, as voiced and spread), and the chord it is.
Key_Notes :: struct {
	notes:  pm.Chord_Notes, // as played
	close:  pm.Chord_Notes, // a chord's, voice-led but not spread (what the next is led from)
	chord:  pm.Chord,       // Chords and Progressions: the chord (`ok` false: none)
	chords: bool,           // a chord of Chords or Progressions mode (strummed), not Scale's note
	slice:  bool,           // a slicer's slice (Scale mode on a slicer)
	index:  int,            // Progressions: its chord's index + 1 (0: not a progression's)
	voicing: pm.Chord_Voicing, // a grid cell's chord: as built, an octave up, or the bass doubled down
}

// The last chord the note modes played (from the window's pads, a
// controller's grid, the API): what a display names and lights.
Chord_Played :: struct {
	chord:   pm.Chord,       // as built (ok false: none played since the play mode changed)
	notes:   pm.Chord_Notes, // as played (voice-led, spread, voiced)
	pad:     int,
	index:   int,            // Progressions: its chord's index + 1 (0: another mode's)
	voicing: pm.Chord_Voicing,
	press:   int,            // the press that played it (`Core.presses`)
	held:    bool,           // that press still down
}

// What key `key` of the note modes plays on the selected pad: Scale's
// degree of the key (key 0 the shown bank's first pad, 16 the next
// bank's), Chords' chord (degrees across, variations up, four a bank),
// Progressions' chord `key`. Pads and Velocity: as Scale. A slicer's key
// is its slice in every mode. Chords are voice-led from the last chord the
// pad played.
keyboard_notes :: proc(c: ^Core, key: int) -> (k: Key_Notes) {
	at := c.bank * pm.PADS_PER_BANK + key
	slicer := c.m.project.pads[c.selected].kind == .Slicer
	mode := c.play_mode
	if slicer do mode = .Scale
	#partial switch mode {
	case .Chords:
		degree, v := pm.chords_pad(c.keys, at / pm.PADS_PER_BANK, at % pm.PADS_PER_BANK)
		k.chord = pm.chord_build(c.keys, degree, v)
	case .Progressions:
		if at >= c.progression.count do return // (past its chords: nothing)
		k.chord = pm.progression_chord(c.keys, &c.progression, at)
		k.index = at + 1
	case:
		degree := at - keyboard_bottom(c)
		k.notes.count = 1
		k.notes.pitches[0] = degree if slicer else pm.degree_pitch(c.keys, degree)
		k.close, k.slice = k.notes, slicer
		return
	}
	chord_voiced(c, &k)
	return
}

// Key `k`'s chord (`k.chord`, as built) voice-led from the last chord the
// selected pad played, spread, and voiced as `k.voicing` says.
@(private)
chord_voiced :: proc(c: ^Core, k: ^Key_Notes) {
	k.chords = true
	if !k.chord.ok do return
	k.close = k.chord.notes
	v := k.chord.variation
	if !c.keys.no_voice_leading && v != .First_Inversion && v != .Second_Inversion do k.close = pm.voice_lead(k.close, c.voicing[c.selected])
	k.notes = pm.voice_chord(pm.spread_chord(k.close, c.keys.spread), k.chord.notes.pitches[0], k.voicing)
}

// A key's chord played on pad `pad`: what the next chord there is led
// from, and the chord a display shows. The press's number (0: not a
// chord), for `key_released`.
key_played :: proc(c: ^Core, pad: int, k: Key_Notes) -> int {
	if !k.chords || k.notes.count == 0 || pad < 0 || pad >= pm.PADS do return 0
	c.voicing[pad] = k.close
	c.presses += 1
	c.chord_played = {chord = k.chord, notes = k.notes, pad = pad, index = k.index, voicing = k.voicing, press = c.presses, held = true}
	return c.presses
}

// Press `press` (`key_played`'s number) let go: its chord no longer held.
key_released :: proc(c: ^Core, press: int) {
	if press != 0 && c.chord_played.press == press do c.chord_played.held = false
}

// What cell `col`, `row` (0, 0 the bottom left) of a controller's 8×8 grid
// plays on the selected pad in the play mode now: Scale's note in the
// key's layout (a slicer's slice: one a cell, in order), Chords' chord
// (degrees across, variations up), Progressions' chord (and the rows of
// it voiced otherwise). Pads and Velocity: as Scale. Outside the grid:
// none.
grid_cell :: proc(c: ^Core, col, row: int) -> pm.Grid_Cell {
	if col < 0 || col >= pm.GRID_COLS || row < 0 || row >= pm.GRID_ROWS do return {index = -1}
	if c.m.project.pads[c.selected].kind == .Slicer do return {kind = .Slice, pitch = row * pm.GRID_COLS + col, index = -1}
	#partial switch c.play_mode {
	case .Chords:       return pm.grid_chords_cell(c.keys, col, row)
	case .Progressions: return pm.grid_progression_cell(c.keys, &c.progression, col, row)
	}
	return pm.grid_scale_cell(c.keys, c.keys.layout, col, row)
}

// What grid cell `g` plays (as `keyboard_notes` says for the window's
// keys): its note, its slice, or its chord voice-led, spread and voiced.
grid_notes :: proc(c: ^Core, g: pm.Grid_Cell) -> (k: Key_Notes) {
	switch g.kind {
	case .None:
	case .Note, .Slice:
		k.notes.count = 1
		k.notes.pitches[0] = g.pitch
		k.close, k.slice = k.notes, g.kind == .Slice
	case .Chord:
		k.chord = pm.chord_build(c.keys, g.degree, g.variation)
		k.index = g.index + 1 if g.index >= 0 else 0
		k.voicing = g.voicing
		chord_voiced(c, &k)
	}
	return
}

// Whether grid cell `g`'s chord is the one playing now (held): the same
// chord of Chords, the same chord and voicing of Progressions.
grid_playing :: proc(c: ^Core, g: pm.Grid_Cell) -> bool {
	p := &c.chord_played
	if g.kind != .Chord || !p.held || !p.chord.ok do return false
	if g.index >= 0 do return p.index == g.index + 1 && p.voicing == g.voicing
	return p.index == 0 && p.chord.degree == g.degree && p.chord.variation == g.variation
}

// What a note mode's key shows: a note's name (or a slicer's slice), or a
// chord's ("ii7 Dm7"; "–" if the key can't make it). Temporary allocator.
key_label :: proc(c: ^Core, k: Key_Notes, note_name: proc(midi: int) -> string) -> string {
	if k.chords do return pm.chord_name(c.keys, k.chord)
	if k.notes.count == 0 do return ""
	return note_name(60 + k.notes.pitches[0])
}

// Whether a note mode's key `key` is the key's root (a slicer's: its first
// slice; a chord: built on the root).
keyboard_root :: proc(c: ^Core, key: int) -> bool {
	k := keyboard_notes(c, key)
	if k.chords do return k.chord.ok && ((k.chord.root - c.keys.root) % 12 + 12) % 12 == 0
	at := c.bank * pm.PADS_PER_BANK + key
	degree := at - keyboard_bottom(c)
	if k.slice do return degree == 0
	n := pm.scale_size(c.keys.scale)
	return n > 0 && ((degree % n) + n) % n == 0
}

// Whether every pitch can be played (the pad's own note is key 60 of the
// MIDI range).
keyboard_in_range :: proc(ps: []int) -> bool {
	for p in ps do if p < -60 || p > 67 do return false
	return len(ps) > 0
}

// The bank Scale mode opens on: the one holding the pad's own note.
keyboard_home_bank :: proc(c: ^Core) -> int {
	return clamp(keyboard_bottom(c) / pm.PADS_PER_BANK, 0, pm.PADS / pm.PADS_PER_BANK - 1)
}

// Plays pitches `ps` (from pad `pad`'s own note, low to high) on it, or
// ends them: a chord strummed `strum_ms` apart, low note first (its
// note-offs too, so each note sounds as long). The router times them.
play_pitches :: proc(c: ^Core, pad: int, ps: []i8, on: bool, velocity: f32, strum_ms: f32 = 0) {
	for p, i in ps do pm.hit(&c.m.engine, pad, on, velocity if on else 0, p, keyboard = true, delay_ms = f32(i) * strum_ms)
}

// How the pads play: each its sound, the selected one's key (Scale), its
// chords (Chords, Progressions), or it at 16 velocities. The pads held let
// go first (the app's `release_held`). Scale opens on the bank holding the
// pad's own note, Chords and Progressions on bank A; leaving them, the
// pads' bank again. Progressions with none in use: the bank's first.
set_play_mode :: proc(c: ^Core, mode: pm.Play_Mode) {
	if c.play_mode == mode do return
	if c.hooks.release_held != nil do c.hooks.release_held(c.hooks.user)
	was := pm.note_mode(c.play_mode)
	if !was do c.pads_bank = c.bank
	c.play_mode = mode
	c.voicing = {}
	c.chord_played = {}
	#partial switch mode {
	case .Scale:
		c.bank = keyboard_home_bank(c)
	case .Chords, .Progressions:
		c.bank = 0
		if mode == .Progressions && c.progression.count == 0 do c.progression = pm.progression_builtin(0)
	case:
		if was do c.bank = c.pads_bank
	}
}
