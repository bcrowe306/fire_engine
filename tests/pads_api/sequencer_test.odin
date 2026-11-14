package test_pads_api

import "core:testing"

import pa "../../apps/pads/api"
import "fire:sampler"

@(test)
sequences_are_named_sized_copied_and_cleared :: proc(t: ^testing.T) {
	r := rig_make(t, "sequences")
	defer rig_destroy(r)
	api := &r.api
	cur, _ := pa.sequence_current(api)
	testing.expect_value(t, cur, 0)
	s, _ := pa.sequence_state(api, 0)
	testing.expect(t, s.current && !s.used && s.bars == 1 && s.beats == 4, "an empty bar")
	name, _ := pa.sequence_name(api, 0)
	testing.expect_value(t, name, "Sequence 1")
	_, res := pa.sequence_state(api, 64)
	testing.expect_value(t, res, pa.Result.Not_Found)
	testing.expect_value(t, pa.sequence_set_name(api, 0, "Verse"), pa.Result.Ok)
	testing.expect_value(t, pa.sequence_set_bars(api, 0, 2), pa.Result.Ok)
	testing.expect_value(t, pa.sequence_set_bars(api, 0, 65), pa.Result.Invalid_Argument)
	testing.expect_value(t, pa.sequence_set_tempo(api, 0, 90), pa.Result.Ok)
	testing.expect_value(t, pa.sequence_set_tempo(api, 0, 20), pa.Result.Invalid_Argument)
	testing.expect_value(t, pa.sequence_set_color(api, 0, 0x336699), pa.Result.Ok)
	testing.expect_value(t, pa.sequence_set_swing(api, 0, 0.3, .Eighth), pa.Result.Ok)
	testing.expect_value(t, pa.sequence_set_swing(api, 0, 0.3, .Quarter), pa.Result.Invalid_Argument)
	s, _ = pa.sequence_state(api, 0)
	testing.expect(t, s.bars == 2 && s.bpm == 90 && s.color == 0x336699 && s.swing == 0.3 && s.swing_grid == .Eighth, "set")
	name, _ = pa.sequence_name(api, 0)
	testing.expect_value(t, name, "Verse")
	// Notes in it, then doubled, duplicated, copied, cleared.
	pa.sequence_add_note(api, 0, {start = 0, length = 0.5, pad = 0, velocity = 1, probability = 1})
	testing.expect_value(t, pa.sequence_double(api, 0), pa.Result.Ok)
	s, _ = pa.sequence_state(api, 0)
	testing.expect(t, s.bars == 4 && s.notes == 2, "doubled")
	to, dres := pa.sequence_duplicate(api, 0)
	testing.expect(t, dres == .Ok && to == 1, "into the next empty slot")
	dn, _ := pa.sequence_name(api, to)
	testing.expect_value(t, dn, "Verse copy")
	testing.expect_value(t, pa.sequence_copy(api, 0, 5), pa.Result.Ok)
	s5, _ := pa.sequence_state(api, 5)
	testing.expect_value(t, s5.notes, 2)
	testing.expect_value(t, pa.sequence_clear(api, 0), pa.Result.Ok)
	s, _ = pa.sequence_state(api, 0)
	testing.expect_value(t, s.notes, 0)
	testing.expect_value(t, pa.sequence_select(api, 5), pa.Result.Ok)
	render(r, 256)
	cur, _ = pa.sequence_current(api)
	testing.expect_value(t, cur, 5)
	testing.expect_value(t, pa.sequence_set_track_loop(api, 5, 0, 3), pa.Result.Ok)
	testing.expect_value(t, r.core.m.project.sequences[5].loops[0], 3)
	testing.expect_value(t, pa.sequence_set_track_loop(api, 5, 0, -1), pa.Result.Invalid_Argument)
}

@(test)
notes_are_added_edited_quantized_and_removed :: proc(t: ^testing.T) {
	r := rig_make(t, "notes")
	defer rig_destroy(r)
	api := &r.api
	i, res := pa.sequence_add_note(api, 0, {start = 1.1, length = 0.25, pad = 2, velocity = 0.8, probability = 1})
	testing.expect(t, res == .Ok && i == 0, "added")
	n, _ := pa.history_undo_name(api)
	testing.expect_value(t, n, "Add Note")
	i2, _ := pa.sequence_add_note(api, 0, {start = 0.1, length = 0.25, pad = 3, velocity = 0.8})
	testing.expect_value(t, i2, 0) // (in order: it starts first)
	note, _ := pa.sequence_note(api, 0, 0)
	testing.expect(t, note.pad == 3 && note.probability == 1, "a chance of 0 is all of it")
	_, res = pa.sequence_add_note(api, 0, {start = 0, length = 0, pad = 0, velocity = 1})
	testing.expect_value(t, res, pa.Result.Invalid_Argument)
	_, res = pa.sequence_add_note(api, 0, {start = 0, length = 1, pad = 200, velocity = 1})
	testing.expect_value(t, res, pa.Result.Not_Found)
	// Edits named for what changed.
	note.velocity = 0.3
	pa.sequence_set_note(api, 0, 0, note)
	n, _ = pa.history_undo_name(api)
	testing.expect_value(t, n, "Set Velocity")
	note.probability = 0.5
	pa.sequence_set_note(api, 0, 0, note)
	n, _ = pa.history_undo_name(api)
	testing.expect_value(t, n, "Set Chance")
	note.start = 2.5
	idx, _ := pa.sequence_set_note(api, 0, 0, note)
	testing.expect_value(t, idx, 1) // (now after the other)
	n, _ = pa.history_undo_name(api)
	testing.expect_value(t, n, "Edit Note")
	// Quantized to 1/4: onto the beat.
	testing.expect_value(t, pa.sequence_quantize(api, 0, .Quarter), pa.Result.Ok)
	q, _ := pa.sequence_note(api, 0, 0)
	testing.expect_value(t, q.start, 1)
	testing.expect_value(t, pa.sequence_quantize(api, 0, .Quarter, 2), pa.Result.Invalid_Argument)
	// Removed together: one step.
	h0, _ := pa.history_state(api)
	testing.expect_value(t, pa.sequence_remove_notes(api, 0, {0, 1}), pa.Result.Ok)
	s, _ := pa.sequence_state(api, 0)
	testing.expect_value(t, s.notes, 0)
	h1, _ := pa.history_state(api)
	testing.expect_value(t, h1.undo_steps, h0.undo_steps + 1)
	testing.expect_value(t, pa.sequence_remove_notes(api, 0, {0}), pa.Result.Not_Found)
	_, res = pa.sequence_note(api, 0, 0)
	testing.expect_value(t, res, pa.Result.Not_Found)
}

@(test)
cc_automation_input_quantize_and_midi_effects :: proc(t: ^testing.T) {
	r := rig_make(t, "seq_extras")
	defer rig_destroy(r)
	api := &r.api
	// MIDI CC.
	testing.expect_value(t, pa.sequence_add_cc(api, 0, {beat = 1, pad = 0, cc = 74, value = 100}), pa.Result.Ok)
	testing.expect_value(t, pa.sequence_add_cc(api, 0, {beat = 1, pad = 0, cc = 128, value = 0}), pa.Result.Invalid_Argument)
	c, _ := pa.sequence_cc(api, 0, 0)
	testing.expect(t, c.cc == 74 && c.value == 100 && c.beat == 1, "a CC step")
	testing.expect_value(t, pa.sequence_clear_cc(api, 0, 0, 74, 0, 4), pa.Result.Ok)
	s, _ := pa.sequence_state(api, 0)
	testing.expect_value(t, s.ccs, 0)
	// Automation: a pad's own lane, and any parameter's.
	testing.expect_value(t, pa.sequence_add_pad_point(api, 0, 1, .Volume, 0, -12), pa.Result.Ok)
	testing.expect_value(t, pa.sequence_add_pad_point(api, 0, 1, .Volume, 0, 100), pa.Result.Invalid_Argument)
	pa.pad_load_sample(api, 0, tone(r))
	frame(r)
	cutoff := pa.Param_Ref{track = .Pad, index = 0, device = .Sound, param = i64(sampler.SAMPLER_PARAM_FILTER_CUTOFF)}
	testing.expect_value(t, pa.sequence_add_point(api, 0, cutoff, 2, 800, 0.5), pa.Result.Ok)
	testing.expect_value(t, pa.sequence_add_point(api, 0, cutoff, 2, 1e9), pa.Result.Invalid_Argument)
	s, _ = pa.sequence_state(api, 0)
	testing.expect_value(t, s.points, 2)
	found_own, found_param := false, false
	for k in 0 ..< s.points {
		p, _ := pa.sequence_point(api, 0, k)
		if p.own && p.pad == 1 && p.pad_lane == .Volume && p.value == -12 do found_own = true
		if !p.own && p.param.param == cutoff.param && p.value == 800 && p.curve == 0.5 do found_param = true
	}
	testing.expect(t, found_own && found_param, "both lanes")
	testing.expect_value(t, pa.sequence_remove_point(api, 0, 0), pa.Result.Ok)
	testing.expect_value(t, pa.sequence_remove_point(api, 0, 5), pa.Result.Not_Found)
	// Input quantize.
	testing.expect_value(t, pa.sequence_set_input_quantize(api, true, .Eighth, 0.75, 0.2), pa.Result.Ok)
	q := r.core.m.project.transport.quantize
	testing.expect(t, q.on && q.grid == .Eighth && q.strength == 0.75 && q.swing == 0.2, "input quantize")
	testing.expect_value(t, pa.sequence_set_input_quantize(api, true, .Eighth, 2, 0), pa.Result.Invalid_Argument)
	// A pad's note repeat and arpeggiator.
	fx, _ := pa.sequence_midi_fx(api, 0)
	testing.expect(t, !fx.repeat && !fx.arp && fx.repeat_gate == 0.5, "off, as a pad starts")
	fx.arp, fx.arp_mode, fx.arp_octaves, fx.arp_rate = true, .Up_Down, 2, .Eighth
	testing.expect_value(t, pa.sequence_set_midi_fx(api, 0, fx), pa.Result.Ok)
	step, _ := pa.history_undo_name(api)
	testing.expect_value(t, step, "Arpeggiator") // (named for what changed)
	got, _ := pa.sequence_midi_fx(api, 0)
	testing.expect(t, got.arp && got.arp_mode == .Up_Down && got.arp_octaves == 2 && got.arp_rate == .Eighth, "the arpeggiator")
	fx.arp_octaves = 9
	testing.expect_value(t, pa.sequence_set_midi_fx(api, 0, fx), pa.Result.Invalid_Argument)
	fx.arp_octaves, fx.repeat_rate = 1, .Sixty_Fourth
	testing.expect_value(t, pa.sequence_set_midi_fx(api, 0, fx), pa.Result.Invalid_Argument)
}
