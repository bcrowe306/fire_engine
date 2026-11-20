package test_pads_model

import "core:testing"

import pm "../../apps/pads/model"

// The pitches of Scale's grid row `row`, cells 0..`n`.
@(private = "file")
row_pitches :: proc(k: pm.Keys, l: pm.Grid_Layout, row, n: int) -> []int {
	out := make([]int, n, context.temp_allocator)
	for c in 0 ..< n do out[c] = pm.grid_scale_cell(k, l, c, row).pitch
	return out
}

@(private = "file")
same_ints :: proc(a, b: []int) -> bool {
	if len(a) != len(b) do return false
	for x, i in a do if b[i] != x do return false
	return true
}

@(test)
scales_layouts_on_the_grid :: proc(t: ^testing.T) {
	c_major := pm.Keys{scale = .Major}
	// Fourths: C two octaves down at the bottom left, the key's notes along
	// a row, each row a fourth (three of the key's notes) up.
	testing.expect_value(t, pm.grid_row_step(c_major, .Fourths), 3)
	testing.expect(t, same_ints(row_pitches(c_major, .Fourths, 0, 8), []int{-24, -22, -20, -19, -17, -15, -13, -12}), "C major, row 1")
	testing.expect(t, same_ints(row_pitches(c_major, .Fourths, 1, 3), []int{-19, -17, -15}), "row 2 starts on F")
	c := pm.grid_scale_cell(c_major, .Fourths, 7, 0)
	testing.expect(t, c.root && c.in_key && c.kind == .Note && c.index == -1, "C an octave up: a root")
	testing.expect(t, !pm.grid_scale_cell(c_major, .Fourths, 1, 0).root, "D: not")
	// Thirds: rows two notes apart (C, E, G...); Sequential: eight.
	testing.expect_value(t, pm.grid_scale_cell(c_major, .Thirds, 0, 1).pitch, -20)
	testing.expect_value(t, pm.grid_scale_cell(c_major, .Thirds, 0, 2).pitch, -17)
	testing.expect_value(t, pm.grid_scale_cell(c_major, .Sequential, 0, 1).pitch, -10)
	// Chromatic: every semitone, rows a fourth; the key's notes marked.
	x := pm.grid_scale_cell(c_major, .Chromatic, 1, 0)
	testing.expect(t, x.pitch == -23 && !x.in_key && !x.root, "C#: out of key")
	testing.expect(t, pm.grid_scale_cell(c_major, .Chromatic, 0, 1).pitch == -19 && pm.grid_scale_cell(c_major, .Chromatic, 0, 1).in_key, "F above C")
	testing.expect(t, pm.grid_scale_cell(c_major, .Chromatic, 2, 2).root, "C an octave up (row 3, +2): a root")
	// A minor: A at the bottom left, D above it; the octave moves it all.
	a_minor := pm.Keys{scale = .Minor, root = 9}
	testing.expect(t, same_ints(row_pitches(a_minor, .Fourths, 0, 3), []int{-15, -13, -12}), "A B C")
	testing.expect_value(t, pm.grid_scale_cell(a_minor, .Fourths, 0, 1).pitch, -10)
	a_minor.octave = 1
	testing.expect_value(t, pm.grid_scale_cell(a_minor, .Fourths, 0, 0).pitch, -3)
	// A pentatonic key: its fourth up is its fourth note (G: a fifth; minor
	// pentatonic's F a fourth); thirds a note up.
	testing.expect_value(t, pm.grid_row_step(pm.Keys{scale = .Major_Pentatonic}, .Fourths), 3)
	testing.expect_value(t, pm.grid_row_step(pm.Keys{scale = .Minor_Pentatonic}, .Fourths), 2)
	testing.expect_value(t, pm.grid_row_step(pm.Keys{scale = .Minor_Pentatonic}, .Thirds), 1)
	testing.expect_value(t, pm.grid_row_step(pm.Keys{scale = .Chromatic}, .Fourths), 5)
}

@(test)
chords_and_progressions_on_the_grid :: proc(t: ^testing.T) {
	c_major := pm.Keys{scale = .Major}
	// Chords: eight columns (the eighth I an octave up), rows the variations.
	testing.expect_value(t, pm.grid_chord_columns(c_major), 8)
	c := pm.grid_chords_cell(c_major, 7, 0)
	testing.expect(t, c.kind == .Chord && c.degree == 7 && c.root && c.variation == .Triad, "I up an octave: the tonic's column")
	testing.expect_value(t, pm.grid_chords_cell(c_major, 2, 7).variation, pm.Variation.Second_Inversion)
	// A pentatonic key: five columns, the rest none.
	pent := pm.Keys{scale = .Major_Pentatonic}
	testing.expect_value(t, pm.grid_chord_columns(pent), 5)
	testing.expect_value(t, pm.grid_chords_cell(pent, 5, 0).kind, pm.Cell_Kind.None)
	testing.expect(t, !pm.chord_build(pent, 1, .Triad).ok && pm.chord_build(pent, 4, .Triad).ok, "no D triad, an Am")
	// Progressions: four chords a row; above them an octave up, then the bass down.
	p, _ := pm.progression_parse("I V vi IV", "test")
	g := pm.grid_progression_cell(c_major, &p, 2, 0)
	testing.expect(t, g.kind == .Chord && g.index == 2 && g.degree == 5 && g.voicing == .As_Built, "vi")
	testing.expect_value(t, pm.grid_progression_cell(c_major, &p, 2, 1).voicing, pm.Chord_Voicing.Octave_Up)
	testing.expect_value(t, pm.grid_progression_cell(c_major, &p, 2, 2).voicing, pm.Chord_Voicing.Bass_Down)
	testing.expect_value(t, pm.grid_progression_cell(c_major, &p, 2, 3).kind, pm.Cell_Kind.None)
	testing.expect_value(t, pm.grid_progression_cell(c_major, &p, 4, 0).kind, pm.Cell_Kind.None)
	// Nine chords: two rows each.
	q, _ := pm.progression_parse("I ii iii IV V vi vii I IV", "nine")
	testing.expect_value(t, pm.grid_progression_cell(c_major, &q, 0, 1).index, 8)
	testing.expect_value(t, pm.grid_progression_cell(c_major, &q, 1, 1).kind, pm.Cell_Kind.None)
	testing.expect(t, pm.grid_progression_cell(c_major, &q, 0, 2).voicing == .Octave_Up && pm.grid_progression_cell(c_major, &q, 0, 2).index == 0, "the octave up's rows")
	testing.expect_value(t, pm.grid_progression_cell(c_major, &q, 0, 6).kind, pm.Cell_Kind.None)
}

@(test)
a_chords_voicings :: proc(t: ^testing.T) {
	c := pm.Chord_Notes{pitches = {0, 4, 7, 0, 0, 0}, count = 3}
	testing.expect_value(t, pm.voice_chord(c, 0, .As_Built), c)
	up := pm.voice_chord(c, 0, .Octave_Up)
	testing.expect(t, up.count == 3 && up.pitches[0] == 12 && up.pitches[2] == 19, "an octave up")
	down := pm.voice_chord(c, 0, .Bass_Down)
	testing.expect(t, down.count == 4 && down.pitches[0] == -12 && down.pitches[1] == 0 && down.pitches[3] == 7, "C under C E G")
	// Voice-led to E G C: its bass C, an octave or more under E.
	led := pm.Chord_Notes{pitches = {4, 7, 12, 0, 0, 0}, count = 3}
	b := pm.voice_chord(led, 0, .Bass_Down)
	testing.expect(t, b.count == 4 && b.pitches[0] == -12 && b.pitches[1] == 4, "C below E G C")
	// A full chord keeps its notes.
	full := pm.Chord_Notes{pitches = {0, 1, 2, 3, 4, 5}, count = 6}
	testing.expect_value(t, pm.voice_chord(full, 0, .Bass_Down), full)
}
