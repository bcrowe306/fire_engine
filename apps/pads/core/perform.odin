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
	case:
		degree := at - keyboard_bottom(c)
		k.notes.count = 1
		k.notes.pitches[0] = degree if slicer else pm.degree_pitch(c.keys, degree)
		k.close, k.slice = k.notes, slicer
		return
	}
	k.chords = true
	if !k.chord.ok do return
	k.close = k.chord.notes
	v := k.chord.variation
	if !c.keys.no_voice_leading && v != .First_Inversion && v != .Second_Inversion do k.close = pm.voice_lead(k.close, c.voicing[c.selected])
	k.notes = pm.spread_chord(k.close, c.keys.spread)
	return
}

// A key's chord played on pad `pad`: what the next chord there is led from.
key_played :: proc(c: ^Core, pad: int, k: Key_Notes) {
	if k.chords && k.notes.count > 0 && pad >= 0 && pad < pm.PADS do c.voicing[pad] = k.close
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
