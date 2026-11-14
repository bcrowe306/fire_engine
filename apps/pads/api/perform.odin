package pads_api

import pc "../core"
import pm "../model"

// How the pads play.
Play_Mode :: enum i32 {
	Pads,     // each pad its own sound
	Keyboard, // the pads are a scale's notes, played on the selected pad
	Velocity, // the pads play the selected pad, softest to loudest
}

// Keyboard mode's scales.
Scale :: enum i32 {
	Chromatic,
	Major,
	Minor,
	Dorian,
	Mixolydian,
	Harmonic_Minor,
	Major_Pentatonic,
	Minor_Pentatonic,
	Blues,
}

// Keyboard mode's chords (one pad, several notes).
Chord :: enum i32 {
	Off,   // one note
	Triad,
	Seventh,
	Power,
}

// How the pads play now.
Perform_State :: struct {
	play_mode: Play_Mode,
	bank:      i64, // 0..7 (A..H; Keyboard mode: a range of notes)
	selected:  i64, // the selected pad: what Keyboard and Velocity play, the keys play, the editors show
	scale:     Scale,
	root:      i64, // 0..11, semitones above C
	octave:    i64, // -3..3
	chord:     Chord,
}

// How the pads play now.
perform_state :: proc(api: ^Api) -> (Perform_State, Result) {
	c := api.core
	return {play_mode = Play_Mode(c.play_mode), bank = i64(c.bank), selected = i64(c.selected), scale = Scale(c.keys.scale), root = i64(c.keys.root), octave = i64(c.keys.octave), chord = Chord(c.keys.chord)}, .Ok
}

// Plays the pads as `mode` (the pads held let go first; Keyboard opens on
// the bank holding the pad's own note).
perform_set_play_mode :: proc(api: ^Api, mode: Play_Mode) -> Result {
	if mode < min(Play_Mode) || mode > max(Play_Mode) do return fail(api, .Invalid_Argument, "no such play mode")
	pc.set_play_mode(api.core, pm.Play_Mode(mode))
	return .Ok
}

// Shows bank `bank` (0..7) of the pads.
perform_set_bank :: proc(api: ^Api, bank: i64) -> Result {
	if bank < 0 || bank >= pm.BANKS do return fail(api, .Invalid_Argument, "a bank is 0..7")
	api.core.bank = int(bank)
	return .Ok
}

// Selects pad `pad` (in Pads mode, its bank shown).
perform_select_pad :: proc(api: ^Api, pad: i64) -> Result {
	if _, r := pad_of(api, pad); r != .Ok do return r
	c := api.core
	c.selected = int(pad)
	if c.play_mode != .Keyboard do c.bank = int(pad) / pm.PADS_PER_BANK
	return .Ok
}

// Keyboard mode's scale, root (0..11), octave (-3..3) and chord. Saved with
// the project (not an edit).
perform_set_keys :: proc(api: ^Api, scale: Scale, root: i64, octave: i64, chord: Chord) -> Result {
	if scale < min(Scale) || scale > max(Scale) || chord < min(Chord) || chord > max(Chord) do return fail(api, .Invalid_Argument, "no such scale or chord")
	if root < 0 || root > 11 || octave < -3 || octave > 3 do return fail(api, .Invalid_Argument, "the root is 0..11, the octave -3..3")
	api.core.keys = {scale = pm.Scale(scale), root = int(root), octave = int(octave), chord = pm.Chord(chord)}
	return .Ok
}
