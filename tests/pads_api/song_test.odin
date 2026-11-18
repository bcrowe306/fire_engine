package test_pads_api

import "core:slice"
import "core:testing"

import pa "../../apps/pads/api"

@(test)
the_song_is_arranged :: proc(t: ^testing.T) {
	r := rig_make(t, "song")
	defer rig_destroy(r)
	api := &r.api
	pa.sequence_add_note(api, 0, {start = 0, length = 0.25, pad = 0, velocity = 1})
	pa.sequence_add_note(api, 1, {start = 0, length = 0.25, pad = 1, velocity = 1})
	a, res := pa.song_add(api, 0)
	testing.expect(t, res == .Ok && a == 0, "a clip")
	b, _ := pa.song_add(api, 1, repeats = 2)
	c, _ := pa.song_add(api, 0, lane = 1, at = 8)
	s, _ := pa.song_state(api)
	testing.expect(t, s.clips == 3 && s.lanes == 2, "three clips, two lanes")
	label, _ := pa.song_clip_label(api, b)
	testing.expect_value(t, label, "") // (no section named)
	cb, _ := pa.song_clip(api, b)
	testing.expect(t, cb.at == 4 && cb.length == 8, "after the first, twice the sequence")
	_, res = pa.song_add(api, 70)
	testing.expect_value(t, res, pa.Result.Not_Found)
	// Edited, the step named for what changed.
	cc, _ := pa.song_clip(api, c)
	cc.mute = true
	testing.expect_value(t, pa.song_set_clip(api, c, cc), pa.Result.Ok)
	n, _ := pa.history_undo_name(api)
	testing.expect_value(t, n, "Mute Clip")
	cc.slot = 1
	pa.song_set_clip(api, c, cc)
	n, _ = pa.history_undo_name(api)
	testing.expect_value(t, n, "Clip Sequence")
	cc.length = 0
	testing.expect_value(t, pa.song_set_clip(api, c, cc), pa.Result.Invalid_Argument)
	// Duplicated, moved, removed.
	added, _ := pa.song_duplicate_clips(api, {a})
	testing.expect_value(t, added, 1)
	s, _ = pa.song_state(api)
	testing.expect_value(t, s.clips, 4)
	testing.expect_value(t, pa.song_move_clips(api, {s.clips - 1}, 4, 2), pa.Result.Ok) // (to a lane of its own: on lane 2 it would cover clip c, which would make way)
	n, _ = pa.history_undo_name(api)
	testing.expect_value(t, n, "Move Clips")
	testing.expect_value(t, pa.song_remove_clips(api, {0, 1}), pa.Result.Ok)
	s, _ = pa.song_state(api)
	testing.expect_value(t, s.clips, 2)
	// Lanes.
	l, _ := pa.song_add_lane(api)
	testing.expect_value(t, pa.song_rename_lane(api, l, "Drums"), pa.Result.Ok)
	ln, _ := pa.song_lane_name(api, l)
	testing.expect_value(t, ln, "Drums")
	testing.expect_value(t, pa.song_set_lane(api, l, {mute = true}), pa.Result.Ok)
	sl, _ := pa.song_lane(api, l)
	testing.expect(t, sl.mute && !sl.solo, "muted")
	// Merged, cleared.
	testing.expect_value(t, pa.song_merge_sequence(api, 1, 0), pa.Result.Ok)
	st0, _ := pa.sequence_state(api, 0)
	testing.expect_value(t, st0.notes, 2)
	testing.expect_value(t, pa.song_merge_sequence(api, 0, 0), pa.Result.Invalid_Argument)
	testing.expect_value(t, pa.song_clear(api), pa.Result.Ok)
	s, _ = pa.song_state(api)
	testing.expect_value(t, s.clips, 0)
}

@(test)
tempo_meters_markers_loop_and_arrangements :: proc(t: ^testing.T) {
	r := rig_make(t, "song_time")
	defer rig_destroy(r)
	api := &r.api
	pa.song_add(api, 0, repeats = 8)
	testing.expect_value(t, pa.song_add_tempo_point(api, {beat = 0, bpm = 100}), pa.Result.Ok)
	testing.expect_value(t, pa.song_add_tempo_point(api, {beat = 8, bpm = 140, ramp = true}), pa.Result.Ok)
	testing.expect_value(t, pa.song_add_tempo_point(api, {beat = 8, bpm = 999}), pa.Result.Invalid_Argument)
	tp, _ := pa.song_tempo_point(api, 1)
	testing.expect(t, tp.bpm == 140 && tp.ramp, "a ramp to 140")
	testing.expect_value(t, pa.song_remove_tempo_point(api, 0), pa.Result.Busy)
	testing.expect_value(t, pa.song_remove_tempo_point(api, 1), pa.Result.Ok)
	testing.expect_value(t, pa.song_set_meter(api, 8, 3, 4), pa.Result.Ok)
	testing.expect_value(t, pa.song_set_meter(api, 8, 3, 5), pa.Result.Invalid_Argument)
	mt, _ := pa.song_meter(api, 0)
	testing.expect(t, mt.num == 3 && mt.den == 4, "3/4")
	testing.expect_value(t, pa.song_remove_meter(api, 0), pa.Result.Ok)
	k, _ := pa.song_add_marker(api, 4, "Chorus")
	mb, _ := pa.song_marker(api, k)
	testing.expect_value(t, mb, 4)
	testing.expect_value(t, pa.song_rename_marker(api, k, "Hook"), pa.Result.Ok)
	mn, _ := pa.song_marker_name(api, k)
	testing.expect_value(t, mn, "Hook")
	testing.expect_value(t, pa.song_remove_marker(api, k), pa.Result.Ok)
	testing.expect_value(t, pa.song_set_loop(api, true, 4, 12), pa.Result.Ok)
	testing.expect_value(t, pa.song_set_loop(api, true, 12, 4), pa.Result.Invalid_Argument)
	s, _ := pa.song_state(api)
	testing.expect(t, s.loop_on && s.loop_start == 4 && s.loop_end == 12, "a loop range")
	testing.expect_value(t, pa.song_jump(api, 8), pa.Result.Ok)
	s, _ = pa.song_state(api)
	testing.expect_value(t, s.cue, 8)
	// Arrangements.
	two, _ := pa.song_add_arrangement(api, copy_of = 0)
	s, _ = pa.song_state(api)
	testing.expect(t, s.arrangements == 2 && s.arrangement == two && s.clips == 1, "a copy, current")
	name, _ := pa.song_arrangement_name(api, two)
	testing.expect_value(t, name, "Song copy")
	testing.expect_value(t, pa.song_rename_arrangement(api, two, "Radio Edit"), pa.Result.Ok)
	testing.expect_value(t, pa.song_select_arrangement(api, 0), pa.Result.Ok)
	testing.expect_value(t, pa.song_delete_arrangement(api, two), pa.Result.Ok)
	testing.expect_value(t, pa.song_delete_arrangement(api, 0), pa.Result.Busy)
}

@(test)
the_launcher_launches_and_is_laid_out :: proc(t: ^testing.T) {
	r := rig_make(t, "launcher")
	defer rig_destroy(r)
	api := &r.api
	ls, _ := pa.launcher_state(api)
	testing.expect(t, ls.lanes >= 1, "lanes")
	lane, res := pa.launcher_add_lane(api)
	testing.expect(t, res == .Ok && lane == ls.lanes, "a new last lane")
	testing.expect_value(t, pa.launcher_rename_lane(api, lane, "Bass"), pa.Result.Ok)
	n, _ := pa.launcher_lane_name(api, lane)
	testing.expect_value(t, n, "Bass")
	testing.expect_value(t, pa.launcher_color_lane(api, lane, 0x00ff00), pa.Result.Ok)
	slot, _ := pa.launcher_new_sequence(api, lane)
	pl, _ := pa.launcher_place(api, slot)
	testing.expect(t, pl.lane == lane && pl.row == 0, "at the lane's top")
	at, _ := pa.launcher_slot_at(api, lane, 0)
	testing.expect_value(t, at, slot)
	testing.expect_value(t, pa.launcher_move_sequence(api, 0, lane, 1), pa.Result.Ok)
	pl, _ = pa.launcher_place(api, 0)
	testing.expect_value(t, pl.lane, lane)
	n2, _ := pa.history_undo_name(api)
	testing.expect_value(t, n2, "Move Sequence")
	// Settings.
	testing.expect_value(t, pa.launcher_set_quantize(api, .Beat), pa.Result.Ok)
	testing.expect_value(t, pa.launcher_set_hold(api, true), pa.Result.Ok)
	testing.expect_value(t, pa.launcher_set_continue(api, true), pa.Result.Ok)
	testing.expect_value(t, pa.launcher_set_recording(api, true), pa.Result.Ok)
	ls, _ = pa.launcher_state(api)
	testing.expect(t, ls.quantize == .Beat && ls.hold && ls.continue_ && ls.recording, "set")
	pa.launcher_set_recording(api, false)
	// Launched: it plays.
	pa.sequence_add_note(api, slot, {start = 0, length = 0.25, pad = 0, velocity = 1})
	testing.expect_value(t, pa.launcher_launch(api, slot), pa.Result.Ok)
	render(r, 512)
	frame(r)
	render(r, 512)
	st, _ := pa.launcher_lane(api, lane)
	testing.expect_value(t, st.playing, slot)
	testing.expect_value(t, pa.launcher_stop_lane(api, lane), pa.Result.Ok)
	testing.expect_value(t, pa.launcher_launch_row(api, 0), pa.Result.Ok)
	testing.expect_value(t, pa.launcher_launch_row(api, 999), pa.Result.Not_Found)
	testing.expect_value(t, pa.launcher_stop_all(api), pa.Result.Ok)
	testing.expect_value(t, pa.launcher_delete_lane(api, lane), pa.Result.Ok)
	_, res = pa.launcher_lane(api, lane)
	testing.expect_value(t, res, pa.Result.Not_Found)
}

@(test)
keyboard_keys_are_the_scales_notes_on_the_selected_pad :: proc(t: ^testing.T) {
	r := rig_make(t, "keys")
	defer rig_destroy(r)
	api := &r.api
	pa.perform_set_keys(api, .Major, 0, 0, .Off)
	pa.perform_set_play_mode(api, .Keyboard) // (opening on the bank of the pad's own note)
	// The key playing the pad's own note: a root; the next, a tone up.
	root := -1
	for k in 0 ..< 64 {
		x, res := pa.perform_key(api, i64(k))
		testing.expect_value(t, res, pa.Result.Ok)
		if x.root && x.pitch == 0 && x.playable do root = k
	}
	testing.expect(t, root >= 0 && root < 63, "the pad's own note among the keys shown")
	if root < 0 || root >= 63 do return
	next, _ := pa.perform_key(api, i64(root + 1))
	testing.expect(t, next.pitch == 2 && !next.root, "a major scale's second: two semitones up")
	_, res := pa.perform_key(api, 128)
	testing.expect_value(t, res, pa.Result.Invalid_Argument)
	testing.expect_value(t, pa.perform_play_key(api, i64(root), true, 0.8), pa.Result.Ok)
	testing.expect_value(t, pa.perform_play_key(api, i64(root), false), pa.Result.Ok)
	testing.expect_value(t, pa.perform_play_key(api, i64(root), true, 0), pa.Result.Invalid_Argument)
	testing.expect_value(t, pa.perform_play_key(api, -1, true), pa.Result.Invalid_Argument)
}

@(test)
play_modes_banks_and_keys :: proc(t: ^testing.T) {
	r := rig_make(t, "perform")
	defer rig_destroy(r)
	api := &r.api
	released := 0
	r.core.hooks = {user = &released, release_held = proc(user: rawptr) { (^int)(user)^ += 1 }}
	testing.expect_value(t, pa.perform_select_pad(api, 20), pa.Result.Ok)
	s, _ := pa.perform_state(api)
	testing.expect(t, s.selected == 20 && s.bank == 1, "pad 20, bank B")
	testing.expect_value(t, pa.perform_set_bank(api, 6), pa.Result.Ok)
	testing.expect_value(t, pa.perform_set_bank(api, 8), pa.Result.Invalid_Argument)
	testing.expect_value(t, pa.perform_set_play_mode(api, .Keyboard), pa.Result.Ok)
	testing.expect_value(t, released, 1)
	s, _ = pa.perform_state(api)
	testing.expect(t, s.play_mode == .Keyboard && s.bank == 3, "Keyboard: the bank of the pad's own note (C3: bank D)")
	testing.expect_value(t, pa.perform_set_play_mode(api, .Pads), pa.Result.Ok)
	s, _ = pa.perform_state(api)
	testing.expect_value(t, s.bank, 6) // (the pads' bank again)
	testing.expect_value(t, pa.perform_set_keys(api, .Dorian, 2, -1, .Triad), pa.Result.Ok)
	s, _ = pa.perform_state(api)
	testing.expect(t, s.scale == .Dorian && s.root == 2 && s.octave == -1 && s.chord == .Triad, "keys")
	testing.expect_value(t, pa.perform_set_keys(api, .Major, 12, 0, .Off), pa.Result.Invalid_Argument)
	// Accent: every pad hit at full velocity, and off again.
	testing.expect_value(t, pa.perform_set_accent(api, true), pa.Result.Ok)
	accent, _ := pa.perform_accent(api)
	testing.expect(t, accent, "accent on")
	pa.perform_set_accent(api, false)
	accent, _ = pa.perform_accent(api)
	testing.expect(t, !accent, "accent off")
	h: Heard
	sub, _ := pa.subscribe(api, .Selection, -1, proc "c" (api: ^pa.Api, topic: pa.Topic, index: i64, user: rawptr) { (^Heard)(user).transport += 1 }, &h)
	defer pa.unsubscribe(api, sub)
	pa.perform_select_pad(api, 5)
	frame(r)
	testing.expect_value(t, h.transport, 1)
}

@(test)
the_perform_tabs_live_state_is_shared :: proc(t: ^testing.T) {
	r := rig_make(t, "perform_live")
	defer rig_destroy(r)
	api := &r.api
	// The launcher's window: kept over the lanes there are.
	testing.expect_value(t, pa.launcher_set_view(api, 99, 0), pa.Result.Ok)
	v, _ := pa.launcher_view(api)
	ls, _ := pa.launcher_state(api)
	testing.expect_value(t, v.lane, max(ls.lanes - 4, 0))
	testing.expect_value(t, pa.launcher_set_keys(api, true), pa.Result.Ok)
	v, _ = pa.launcher_view(api)
	testing.expect(t, v.keys, "Keys on")
	// Hold: a sequence pad plays while held, its lane stops when let go.
	pa.launcher_set_hold(api, true)
	pa.sequence_add_note(api, 0, {start = 0, length = 0.25, pad = 0, velocity = 1})
	pa.transport_play(api)
	testing.expect_value(t, pa.launcher_press(api, 0, true), pa.Result.Ok)
	render(r, 512)
	frame(r)
	render(r, 512)
	lane, _ := pa.launcher_place(api, 0)
	st, _ := pa.launcher_lane(api, lane.lane)
	testing.expect_value(t, st.playing, 0)
	testing.expect_value(t, pa.launcher_press(api, 999, true), pa.Result.Not_Found)
	testing.expect_value(t, pa.launcher_press(api, 0, false), pa.Result.Ok)
	// Effects: held while held; latching, on until the next press.
	testing.expect_value(t, pa.effect_press(api, 3, true, 0.5), pa.Result.Ok)
	testing.expect_value(t, pa.effect_pressure(api, 3, 0.8), pa.Result.Ok)
	es, _ := pa.effect_state(api, {.Perf, 3, 0})
	testing.expect(t, es.on, "held: on")
	pa.effect_press(api, 3, false)
	es, _ = pa.effect_state(api, {.Perf, 3, 0})
	testing.expect(t, !es.on, "let go: off")
	testing.expect_value(t, pa.effect_set_latch(api, true), pa.Result.Ok)
	pa.effect_press(api, 3, true)
	pa.effect_press(api, 3, false)
	es, _ = pa.effect_state(api, {.Perf, 3, 0})
	testing.expect(t, es.on, "latched: on after the press")
	v, _ = pa.launcher_view(api)
	testing.expect(t, v.fx_latch && v.fx_last == 3, "latching, the last pressed")
	pa.effect_set_latch(api, false)
	es, _ = pa.effect_state(api, {.Perf, 3, 0})
	testing.expect(t, !es.on, "latch off: off")
	testing.expect_value(t, pa.effect_press(api, 16, true), pa.Result.Not_Found)
	testing.expect_value(t, pa.effect_pressure(api, 3, 2), pa.Result.Invalid_Argument)
}

@(test)
a_controller_edits_the_song_at_its_cursor :: proc(t: ^testing.T) {
	r := rig_make(t, "song_edit")
	defer rig_destroy(r)
	api := &r.api
	pa.sequence_add_note(api, 0, {start = 0, length = 0.25, pad = 0, velocity = 1})
	pa.sequence_add_note(api, 1, {start = 0, length = 0.25, pad = 1, velocity = 1})
	e, _ := pa.song_edit_state(api)
	testing.expect(t, e.cursor == 0 && e.clip == -1 && e.lane == 0, "the cursor at the start, no clip")
	// The current sequence at the cursor, twice: the second follows the first.
	pa.sequence_select(api, 0)
	a, res := pa.song_add_at_cursor(api, 1)
	testing.expect(t, res == .Ok && a == 0, "a clip")
	b, _ := pa.song_add_at_cursor(api, 1, slot = 1)
	cb, _ := pa.song_clip(api, b)
	testing.expect(t, cb.lane == 1 && cb.at == 4 && cb.slot == 1, "after the first, on its lane")
	e, _ = pa.song_edit_state(api)
	testing.expect(t, e.cursor == 8 && e.clip == b && e.lane == 1, "the cursor at its end, it selected")
	// A length of its own, the cursor anywhere.
	testing.expect_value(t, pa.song_set_add_length(api, 2), pa.Result.Ok)
	testing.expect_value(t, pa.song_set_cursor(api, 2), pa.Result.Ok)
	c, _ := pa.song_add_at_cursor(api, 0)
	cc, _ := pa.song_clip(api, c)
	testing.expect(t, cc.at == 2 && cc.length == 2, "two beats from beat 2")
	testing.expect_value(t, pa.song_set_cursor(api, -1), pa.Result.Invalid_Argument)
	testing.expect_value(t, pa.song_set_add_length(api, -1), pa.Result.Invalid_Argument)
	// The clip at a place on a lane, selected.
	at, _ := pa.song_clip_at(api, 1, 5)
	testing.expect_value(t, at, b)
	none, _ := pa.song_clip_at(api, 2, 5)
	testing.expect_value(t, none, -1)
	testing.expect_value(t, pa.song_select_clip(api, a), pa.Result.Ok)
	testing.expect_value(t, pa.song_select_clip(api, 99), pa.Result.Not_Found)
	pa.song_select_clip(api, -1)
	e, _ = pa.song_edit_state(api)
	testing.expect_value(t, e.clip, -1)
	// Lanes: selected, the eight shown follow.
	pa.song_select_lane(api, 9)
	e, _ = pa.song_edit_state(api)
	testing.expect(t, e.lane == 9 && e.first_lane == 8, "lane 10, the second eight")
	testing.expect_value(t, pa.song_show_lanes(api, 0), pa.Result.Ok)
	testing.expect_value(t, pa.song_show_lanes(api, 3), pa.Result.Invalid_Argument)
	testing.expect_value(t, pa.song_select_lane(api, 16), pa.Result.Not_Found)
	// A section's name.
	testing.expect_value(t, pa.song_set_clip_label(api, a, "Verse"), pa.Result.Ok)
	label, _ := pa.song_clip_label(api, a)
	testing.expect_value(t, label, "Verse")
	testing.expect_value(t, pa.song_set_clip_label(api, a, "a name far too long"), pa.Result.Invalid_Argument)
	// A sequence taken out of the song: its clips, one step.
	n, _ := pa.song_remove_sequence(api, 0)
	testing.expect_value(t, n, 2)
	s, _ := pa.song_state(api)
	testing.expect_value(t, s.clips, 1)
	left, _ := pa.song_clip(api, 0)
	testing.expect_value(t, left.at, 0) // (its lane's gap closed)
	name, _ := pa.history_undo_name(api)
	testing.expect_value(t, name, "Remove from Song")
}

// A lane plays one clip at a time: inserting at the cursor moves the
// lane's later clips on, removing closes the gap, duplicating pushes on;
// a clip put over others makes them make way.
@(test)
a_lane_ripples_and_never_overlaps :: proc(t: ^testing.T) {
	r := rig_make(t, "song_ripple")
	defer rig_destroy(r)
	api := &r.api
	for k in 0 ..< 3 do pa.sequence_add_note(api, i64(k), {start = 0, length = 0.25, pad = 0, velocity = 1})
	starts :: proc(api: ^pa.Api, lane: i64) -> [dynamic]f64 {
		out := make([dynamic]f64, context.temp_allocator)
		s, _ := pa.song_state(api)
		for i in 0 ..< s.clips {
			c, _ := pa.song_clip(api, i)
			if c.lane == lane do append(&out, c.at)
		}
		slice.sort(out[:])
		return out
	}
	// Three in a row on the first lane: 0, 4, 8 (four beats each).
	for k in 0 ..< 3 do pa.song_add_at_cursor(api, 0, i64(k))
	// The cursor inside the second: the new one goes after it, the third on.
	pa.song_set_cursor(api, 5)
	pa.song_add_at_cursor(api, 0, 0)
	x := starts(api, 0)
	testing.expect(t, len(x) == 4 && x[2] == 8 && x[3] == 12, "inserted after the clip the cursor was in, the rest moved on")
	// At a clip's start: before it.
	pa.song_set_cursor(api, 0)
	pa.song_add_at_cursor(api, 0, 1)
	x = starts(api, 0)
	testing.expect(t, len(x) == 5 && x[4] == 16, "inserted at the front, everything moved on")
	// Removed: the gap closes, the cursor back to where it began.
	at, _ := pa.song_clip_at(api, 0, 9)
	pa.song_set_cursor(api, 10)
	testing.expect_value(t, pa.song_ripple_remove(api, {at}), pa.Result.Ok)
	x = starts(api, 0)
	testing.expect(t, len(x) == 4 && x[3] == 12, "the later ones closed the gap")
	e, _ := pa.song_edit_state(api)
	testing.expect_value(t, e.cursor, 8)
	name, _ := pa.history_undo_name(api)
	testing.expect_value(t, name, "Remove from Song")
	testing.expect_value(t, pa.song_ripple_remove(api, {99}), pa.Result.Not_Found)
	// Duplicated: right after itself, the later ones on; it selected.
	first, _ := pa.song_clip_at(api, 0, 0)
	d, res := pa.song_ripple_duplicate(api, first)
	testing.expect_value(t, res, pa.Result.Ok)
	cd, _ := pa.song_clip(api, d)
	testing.expect_value(t, cd.at, 4)
	x = starts(api, 0)
	testing.expect(t, len(x) == 5 && x[4] == 16, "the duplicate pushed the rest on")
	e, _ = pa.song_edit_state(api)
	testing.expect(t, e.clip == d && e.cursor == 8, "the copy selected, the cursor at its end")
	// Resized: twice as long, the later ones moving on.
	testing.expect_value(t, pa.song_ripple_resize(api, first, 8), pa.Result.Ok)
	x = starts(api, 0)
	testing.expect(t, len(x) == 5 && x[1] == 8 && x[4] == 20, "the later ones moved on with its end")
	testing.expect_value(t, pa.song_ripple_resize(api, first, 0), pa.Result.Invalid_Argument)
	pa.song_ripple_resize(api, first, 4)
	// Put over others (song_add at a place): they make way: one under it
	// trimmed, one inside it taken out.
	pa.song_add(api, 2, lane = 1, at = 0, length = 8)
	pa.song_add(api, 2, lane = 1, at = 8, length = 2)
	pa.song_add(api, 1, lane = 1, at = 6, length = 6)
	x = starts(api, 1)
	testing.expect(t, len(x) == 2 && x[0] == 0 && x[1] == 6, "the clip inside taken out")
	a0, _ := pa.song_clip_at(api, 1, 0)
	c0, _ := pa.song_clip(api, a0)
	testing.expect_value(t, c0.length, 6)
	// Moved over another: that one's start trimmed, its notes kept in place.
	pa.song_add(api, 2, lane = 2, at = 0, length = 4)
	pa.song_add(api, 2, lane = 2, at = 4, length = 4)
	mv, _ := pa.song_clip_at(api, 2, 0)
	pa.song_move_clips(api, {mv}, 2, 0)
	b, _ := pa.song_clip_at(api, 2, 7)
	cb, _ := pa.song_clip(api, b)
	testing.expect(t, cb.at == 6 && cb.length == 2 && cb.phase == 2, "trimmed from the left, its notes where they were")
	// One set over the middle of another: that one cut in two.
	pa.song_add(api, 0, lane = 3, at = 0, length = 8)
	sm, _ := pa.song_add(api, 1, lane = 3, at = 10, length = 2)
	c, _ := pa.song_clip(api, sm)
	c.at = 3
	pa.song_set_clip(api, sm, c)
	x = starts(api, 3)
	testing.expect(t, len(x) == 3 && x[0] == 0 && x[1] == 3 && x[2] == 5, "cut in two around it")
}
