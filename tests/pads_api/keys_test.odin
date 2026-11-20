package test_pads_api

import "core:testing"

import pa "../../apps/pads/api"

@(private = "file")
key_changes :: proc "c" (api: ^pa.Api, topic: pa.Topic, index: i64, user: rawptr) {
	(^int)(user)^ += 1
}

@(test)
the_project_key_and_its_chords :: proc(t: ^testing.T) {
	r := rig_make(t, "key")
	defer rig_destroy(r)
	api := &r.api
	heard := 0
	sub, res := pa.subscribe(api, .Key, -1, key_changes, &heard)
	testing.expect_value(t, res, pa.Result.Ok)
	testing.expect_value(t, pa.key_set(api, 2, .Dorian), pa.Result.Ok)
	frame(r)
	testing.expect_value(t, heard, 1) // (the Key topic heard it)
	ks, _ := pa.key_state(api)
	testing.expect(t, ks.root == 2 && ks.scale == .Dorian && ks.notes == 7 && ks.voice_leading && ks.spread == .Close && ks.strum_ms == 0, "D dorian, voice leading on")
	name, _ := pa.key_name(api)
	testing.expect_value(t, name, "D dorian")
	sn, _ := pa.key_scale_name(api, .Hirajoshi)
	testing.expect_value(t, sn, "Hirajoshi")
	_, res = pa.key_scale_name(api, pa.Scale(99))
	testing.expect_value(t, res, pa.Result.Invalid_Argument)
	testing.expect_value(t, pa.key_set(api, 12, .Major), pa.Result.Invalid_Argument)
	testing.expect_value(t, pa.key_set_octave(api, 1), pa.Result.Ok)
	testing.expect_value(t, pa.key_set_octave(api, 4), pa.Result.Invalid_Argument)
	ks, _ = pa.key_state(api)
	testing.expect_value(t, ks.octave, 1)
	pa.key_set_octave(api, 0)
	testing.expect_value(t, pa.key_set_voicing(api, false, .Drop_2, 30), pa.Result.Ok)
	ks, _ = pa.key_state(api)
	testing.expect(t, !ks.voice_leading && ks.spread == .Drop_2 && ks.strum_ms == 30, "voicing")
	testing.expect_value(t, pa.key_set_voicing(api, true, .Close, 101), pa.Result.Invalid_Argument)
	pa.key_set_voicing(api, true, .Close, 0)
	// In D dorian: B (pitch 11) is in the key, C# (1) is not.
	in_b, _ := pa.key_has(api, 11)
	in_cs, _ := pa.key_has(api, 1)
	testing.expect(t, in_b && !in_cs, "B in, C# out")
	// Its chords: ii is Em7 (E G B D).
	c, _ := pa.key_chord(api, 1, .Seventh)
	testing.expect(t, c.ok && c.root == 4 && c.count == 4, "Em7")
	cn, _ := pa.key_chord_name(api, 1, .Seventh)
	testing.expect_value(t, cn, "ii7 Em7")
	n3, _ := pa.key_chord_note(api, 1, .Seventh, 3)
	testing.expect_value(t, n3, 14) // D, an octave up
	_, res = pa.key_chord_note(api, 1, .Seventh, 4)
	testing.expect_value(t, res, pa.Result.Not_Found)
	_, res = pa.key_chord(api, -1, .Triad)
	testing.expect_value(t, res, pa.Result.Invalid_Argument)
	pa.unsubscribe(api, sub)
}

@(test)
chords_mode_plays_a_chord_a_pad :: proc(t: ^testing.T) {
	r := rig_make(t, "chords_mode")
	defer rig_destroy(r)
	api := &r.api
	pa.key_set(api, 0, .Major)
	testing.expect_value(t, pa.perform_set_play_mode(api, .Chords), pa.Result.Ok)
	s, _ := pa.perform_state(api)
	testing.expect(t, s.play_mode == .Chords && s.bank == 0 && s.chord_page == 0, "Chords: bank A, the first rows")
	// Pad 1: I; pad 5 (the row above): I7; pad 2: ii.
	k, _ := pa.perform_key(api, 0)
	testing.expect(t, k.chord && k.count == 3 && k.root && k.playable && k.pitch == 0, "pad 1: C")
	nm, _ := pa.perform_key_name(api, 0)
	testing.expect_value(t, nm, "I C")
	nm, _ = pa.perform_key_name(api, 4)
	testing.expect_value(t, nm, "Imaj7 Cmaj7")
	nm, _ = pa.perform_key_name(api, 1)
	testing.expect_value(t, nm, "ii Dm")
	// The second page: add9, 6th, the inversions.
	testing.expect_value(t, pa.perform_set_chord_page(api, 1), pa.Result.Ok)
	testing.expect_value(t, pa.perform_set_chord_page(api, 2), pa.Result.Invalid_Argument)
	nm, _ = pa.perform_key_name(api, 8)
	testing.expect_value(t, nm, "I/3 C/E")
	pa.perform_set_chord_page(api, 0)
	// Played: three notes; then F, led from it (C F A: low C stays).
	testing.expect_value(t, pa.perform_play_key(api, 0, true, 0.8), pa.Result.Ok)
	render(r, 512)
	pa.perform_play_key(api, 0, false)
	f, _ := pa.perform_key(api, 3)
	testing.expect(t, f.count == 3 && f.pitch == 0, "F after C: C F A (its lowest C)")
	_, res := pa.perform_key_name(api, 128)
	testing.expect_value(t, res, pa.Result.Invalid_Argument)
	// Scale mode names notes.
	pa.perform_set_play_mode(api, .Scale)
	k, _ = pa.perform_key(api, 0)
	testing.expect(t, !k.chord && k.count == 1, "Scale: one note")
}

@(test)
progressions_bank_editing_and_yours :: proc(t: ^testing.T) {
	r := rig_make(t, "progressions")
	defer rig_destroy(r)
	api := &r.api
	pa.key_set(api, 0, .Major)
	// Progressions mode with none in use takes the bank's first.
	pa.perform_set_play_mode(api, .Progressions)
	ps, _ := pa.progression_state(api)
	testing.expect(t, ps.count == 4 && ps.max == 16, "the bank's first: four chords")
	n, _ := pa.progression_bank_count(api)
	testing.expect(t, n >= 40, "about 40 built in")
	for k in 0 ..< n {
		bn, _ := pa.progression_bank_name(api, k)
		st, _ := pa.progression_bank_style(api, k)
		nums, _ := pa.progression_bank_numerals(api, k)
		testing.expectf(t, bn != "" && st != "" && nums != "", "bank %d", k)
	}
	_, res := pa.progression_bank_name(api, n)
	testing.expect_value(t, res, pa.Result.Not_Found)
	testing.expect_value(t, pa.progression_use_bank(api, 0), pa.Result.Ok)
	nums, _ := pa.progression_numerals(api)
	want, _ := pa.progression_bank_numerals(api, 0)
	testing.expect_value(t, nums, want)
	// Pad n plays chord n.
	c0, _ := pa.progression_chord_name(api, 0)
	k0, _ := pa.perform_key_name(api, 0)
	testing.expect_value(t, k0, c0)
	k, _ := pa.perform_key(api, 15)
	testing.expect(t, !k.playable && !k.chord && k.count == 0, "past its chords: none")
	// Editing: a chord added, changed, moved, taken out; the name.
	testing.expect_value(t, pa.progression_insert(api, 4, 1, .Seventh), pa.Result.Ok)
	testing.expect_value(t, pa.progression_insert(api, 6, 1, .Seventh), pa.Result.Invalid_Argument)
	c, _ := pa.progression_chord(api, 4)
	testing.expect(t, c.degree == 1 && c.variation == .Seventh, "ii7 at the end")
	cn, _ := pa.progression_chord_name(api, 4)
	testing.expect_value(t, cn, "ii7 Dm7")
	testing.expect_value(t, pa.progression_set_chord(api, 4, 4, .Sus4), pa.Result.Ok)
	testing.expect_value(t, pa.progression_move(api, 4, 0), pa.Result.Ok)
	nums, _ = pa.progression_numerals(api)
	testing.expect_value(t, nums[:5], "Vsus4")
	testing.expect_value(t, pa.progression_remove(api, 0), pa.Result.Ok)
	testing.expect_value(t, pa.progression_remove(api, 9), pa.Result.Not_Found)
	nums, _ = pa.progression_numerals(api)
	testing.expect_value(t, nums, want)
	testing.expect_value(t, pa.progression_set_name(api, "  Mine  "), pa.Result.Ok)
	nm, _ := pa.progression_name(api)
	testing.expect_value(t, nm, "Mine")
	for _ in 0 ..< 12 do pa.progression_insert(api, 0, 0, .Triad)
	testing.expect_value(t, pa.progression_insert(api, 0, 0, .Triad), pa.Result.Unsupported) // (16 at most)
	for _ in 0 ..< 12 do pa.progression_remove(api, 0)
	// Saved as yours (in the settings folder), listed, used again.
	path, sres := pa.progression_save(api, "Late Night")
	testing.expect(t, sres == .Ok && path != "", "saved")
	_, sres = pa.progression_save(api, " ")
	testing.expect_value(t, sres, pa.Result.Invalid_Argument)
	mc, _ := pa.progression_mine_count(api)
	testing.expect_value(t, mc, 1)
	mn, _ := pa.progression_mine_name(api, 0)
	testing.expect_value(t, mn, "Late Night")
	_, res = pa.progression_mine_name(api, 1)
	testing.expect_value(t, res, pa.Result.Not_Found)
	pa.progression_use_bank(api, 5)
	testing.expect_value(t, pa.progression_use_mine(api, "Late Night"), pa.Result.Ok)
	nums, _ = pa.progression_numerals(api)
	testing.expect_value(t, nums, want)
	testing.expect_value(t, pa.progression_use_mine(api, "Nope"), pa.Result.Not_Found)
}
