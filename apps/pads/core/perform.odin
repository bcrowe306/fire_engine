package pads_core

import pm "../model"

// Keyboard mode's degrees below the selected pad's own note that bank A's
// first pad starts at: the root five octaves down (the bottom of the MIDI
// range, whatever the octave set). A slicer's keys start at its first slice.
keyboard_bottom :: proc(c: ^Core) -> int {
	if c.m.project.pads[c.selected].kind == .Slicer do return 0
	n := pm.scale_size(c.keys.scale)
	return n * (5 + c.keys.octave)
}

// The pitches (from the selected pad's own note) Keyboard mode's key `key`
// plays: the scale's degrees from the shown bank's start (key 0 its first
// pad, 16 the next bank's), a chord's several; a slicer's key its slice.
keyboard_notes :: proc(c: ^Core, key: int, out: ^[4]int) -> []int {
	degree := c.bank * pm.PADS_PER_BANK + key - keyboard_bottom(c)
	if c.m.project.pads[c.selected].kind == .Slicer {
		out[0] = degree
		return out[:1]
	}
	return pm.keyboard_pitches(c.keys, degree, out)
}

// Whether Keyboard mode's key `key` is the scale's root (a slicer's: its
// first slice).
keyboard_root :: proc(c: ^Core, key: int) -> bool {
	degree := c.bank * pm.PADS_PER_BANK + key - keyboard_bottom(c)
	if c.m.project.pads[c.selected].kind == .Slicer do return degree == 0
	n := pm.scale_size(c.keys.scale)
	return n > 0 && ((degree % n) + n) % n == 0
}

// Whether every pitch can be played (the pad's own note is key 60 of the
// MIDI range).
keyboard_in_range :: proc(ps: []int) -> bool {
	for p in ps do if p < -60 || p > 67 do return false
	return len(ps) > 0
}

// The bank Keyboard mode opens on: the one holding the pad's own note.
keyboard_home_bank :: proc(c: ^Core) -> int {
	return clamp(keyboard_bottom(c) / pm.PADS_PER_BANK, 0, pm.PADS / pm.PADS_PER_BANK - 1)
}

// How the pads play: each its sound, a keyboard of the selected one, or it
// at 16 velocities. The pads held let go first (the app's `release_held`).
// Keyboard mode opens on the bank holding the pad's own note; leaving it,
// the pads' bank again.
set_play_mode :: proc(c: ^Core, mode: pm.Play_Mode) {
	if c.play_mode == mode do return
	if c.hooks.release_held != nil do c.hooks.release_held(c.hooks.user)
	if mode == .Keyboard {
		c.pads_bank = c.bank
		c.play_mode = mode
		c.bank = keyboard_home_bank(c)
		return
	}
	if c.play_mode == .Keyboard do c.bank = c.pads_bank
	c.play_mode = mode
}
