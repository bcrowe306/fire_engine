package test_pads_api

import "core:testing"

import pa "../../apps/pads/api"

// A controller's 8x8 grid in the note modes: Scale's layouts (the key's
// layout setting), Chords' and Progressions' cells, playing a cell, and
// the chord playing.
@(test)
the_grid_its_cells_and_the_chord_playing :: proc(t: ^testing.T) {
	r := rig_make(t, "grid")
	defer rig_destroy(r)
	api := &r.api
	pa.pad_set_kind(api, 0, .Synth)
	pa.perform_select_pad(api, 0)
	pa.key_set(api, 0, .Major)
	pa.perform_set_play_mode(api, .Scale)
	// The layout: Fourths by default, saved in the key.
	ks, _ := pa.key_state(api)
	testing.expect_value(t, ks.layout, pa.Grid_Layout.Fourths)
	ln, _ := pa.key_layout_name(api, .Chromatic)
	testing.expect_value(t, ln, "Chromatic")
	_, res := pa.key_layout_name(api, pa.Grid_Layout(9))
	testing.expect_value(t, res, pa.Result.Invalid_Argument)
	c, _ := pa.perform_cell(api, 0, 1)
	testing.expect(t, c.kind == .Note && c.pitch == -19 && c.in_key && c.playable && !c.root, "F above C")
	name, _ := pa.perform_cell_name(api, 0, 0)
	testing.expect_value(t, name, "C1")
	testing.expect_value(t, pa.key_set_layout(api, .Chromatic), pa.Result.Ok)
	testing.expect_value(t, pa.key_set_layout(api, pa.Grid_Layout(4)), pa.Result.Invalid_Argument)
	c, _ = pa.perform_cell(api, 1, 0)
	testing.expect(t, c.pitch == -23 && !c.in_key && c.playable, "C#: out of key, still played")
	_, res = pa.perform_cell(api, 8, 0)
	testing.expect_value(t, res, pa.Result.Invalid_Argument)
	_, res = pa.perform_cell_name(api, 0, -1)
	testing.expect_value(t, res, pa.Result.Invalid_Argument)
	// A note played: no chord.
	before, _ := pa.pad_struck(api, 0)
	testing.expect_value(t, pa.perform_play_cell(api, 0, 0, true, 0.7), pa.Result.Ok)
	render(r, 512)
	pa.perform_play_cell(api, 0, 0, false)
	after, _ := pa.pad_struck(api, 0)
	testing.expect(t, after > before, "the pad played")
	cp, _ := pa.perform_chord_playing(api)
	testing.expect(t, !cp.ok && cp.index == -1, "no chord yet")
	testing.expect_value(t, pa.perform_play_cell(api, 0, 0, true, 2), pa.Result.Invalid_Argument)

	// Chords: degrees across, variations up; held, then let go.
	pa.perform_set_play_mode(api, .Chords)
	name, _ = pa.perform_cell_name(api, 1, 1)
	testing.expect_value(t, name, "ii7 Dm7")
	c, _ = pa.perform_cell(api, 7, 0)
	testing.expect(t, c.kind == .Chord && c.root && c.degree == 7 && c.pitch == 12 && c.count == 3, "I an octave up")
	pa.perform_play_cell(api, 1, 1, true, 0.8)
	cp, _ = pa.perform_chord_playing(api)
	testing.expect(t, cp.ok && cp.held && cp.degree == 1 && cp.variation == .Seventh && cp.index == -1 && cp.count == 4 && cp.pad == 0, "Dm7 held")
	cn, _ := pa.perform_chord_playing_name(api)
	testing.expect_value(t, cn, "ii7 Dm7")
	low, _ := pa.perform_chord_playing_note(api, 0)
	testing.expect_value(t, low, 2)
	_, res = pa.perform_chord_playing_note(api, 4)
	testing.expect_value(t, res, pa.Result.Not_Found)
	c, _ = pa.perform_cell(api, 1, 1)
	testing.expect(t, c.playing, "its cell: playing")
	pa.perform_play_cell(api, 1, 1, false)
	cp, _ = pa.perform_chord_playing(api)
	testing.expect(t, cp.ok && !cp.held, "let go: still the last played")
	// A pentatonic key: five columns, chords it can't make not playable.
	pa.key_set(api, 0, .Major_Pentatonic)
	c, _ = pa.perform_cell(api, 5, 0)
	testing.expect_value(t, c.kind, pa.Cell_Kind.None)
	c, _ = pa.perform_cell(api, 1, 0)
	testing.expect(t, c.kind == .Chord && !c.playable, "no D triad")
	pa.key_set(api, 0, .Major)

	// Progressions: the chords, an octave up, the bass down.
	pa.perform_set_play_mode(api, .Progressions)
	cp, _ = pa.perform_chord_playing(api)
	testing.expect(t, !cp.ok, "a new mode: none playing")
	pa.perform_play_cell(api, 0, 0, true, 1)
	pa.perform_play_cell(api, 0, 0, false)
	pa.perform_play_cell(api, 0, 1, true, 1)
	cp, _ = pa.perform_chord_playing(api)
	testing.expect(t, cp.index == 0 && cp.voicing == .Octave_Up && cp.held, "I, an octave up")
	n0, _ := pa.perform_chord_playing_note(api, 0)
	testing.expect_value(t, n0, 12)
	pa.perform_play_cell(api, 0, 1, false)
	pa.perform_play_cell(api, 0, 2, true, 1)
	cp, _ = pa.perform_chord_playing(api)
	n0, _ = pa.perform_chord_playing_note(api, 0)
	testing.expect(t, cp.voicing == .Bass_Down && cp.count == 4 && n0 == -12, "I, its bass an octave down")
	c, _ = pa.perform_cell(api, 0, 2)
	testing.expect(t, c.playing && c.index == 0 && c.voicing == .Bass_Down, "playing")
	c, _ = pa.perform_cell(api, 0, 0)
	testing.expect(t, !c.playing, "the same chord, another voicing: not")
	pa.perform_play_cell(api, 0, 2, false)
	render(r, 512)
}
