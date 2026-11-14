package test_pads_api

import "core:testing"

import pa "../../apps/pads/api"

@(test)
each_edit_is_a_step_undone_and_redone_by_name :: proc(t: ^testing.T) {
	r := rig_make(t, "history_steps")
	defer rig_destroy(r)
	api := &r.api
	h, _ := pa.history_state(api)
	testing.expect_value(t, h.undo_steps, 0)
	testing.expect_value(t, pa.transport_set_tempo(api, 130), pa.Result.Ok)
	testing.expect_value(t, pa.transport_set_tempo(api, 140), pa.Result.Ok)
	h, _ = pa.history_state(api)
	testing.expect_value(t, h.undo_steps, 2) // (not merged: no gesture)
	testing.expect(t, h.dirty, "changed")
	name, _ := pa.history_undo_name(api)
	testing.expect_value(t, name, "Set Tempo")
	testing.expect_value(t, pa.history_undo(api), pa.Result.Ok)
	testing.expect_value(t, r.core.m.project.bpm, 130)
	name, _ = pa.history_redo_name(api)
	testing.expect_value(t, name, "Set Tempo")
	testing.expect_value(t, pa.history_redo(api), pa.Result.Ok)
	testing.expect_value(t, r.core.m.project.bpm, 140)
	// Nothing more to redo: Not_Found, and why.
	testing.expect_value(t, pa.history_redo(api), pa.Result.Not_Found)
	why, _ := pa.last_error(api)
	testing.expect_value(t, why, "nothing to redo")
	testing.expect_value(t, pa.history_undo(api), pa.Result.Ok)
	testing.expect_value(t, pa.history_undo(api), pa.Result.Ok)
	testing.expect_value(t, pa.history_undo(api), pa.Result.Not_Found)
}

@(test)
a_gesture_merges_into_one_step :: proc(t: ^testing.T) {
	r := rig_make(t, "history_gesture")
	defer rig_destroy(r)
	api := &r.api
	pa.history_gesture_begin(api)
	for bpm in ([]f64{100, 101, 102, 103}) do pa.transport_set_tempo(api, bpm)
	pa.history_gesture_end(api)
	pa.transport_set_tempo(api, 104) // (a step of its own: the gesture ended)
	h, _ := pa.history_state(api)
	testing.expect_value(t, h.undo_steps, 2)
	pa.history_undo(api)
	testing.expect_value(t, r.core.m.project.bpm, 103)
	pa.history_undo(api)
	testing.expect_value(t, r.core.m.project.bpm, 120)
}

@(test)
a_group_is_one_named_step :: proc(t: ^testing.T) {
	r := rig_make(t, "history_group")
	defer rig_destroy(r)
	api := &r.api
	testing.expect_value(t, pa.history_group_begin(api, ""), pa.Result.Invalid_Argument)
	testing.expect_value(t, pa.history_group_end(api), pa.Result.Not_Found)
	testing.expect_value(t, pa.history_group_begin(api, "Set Up the Click"), pa.Result.Ok)
	pa.transport_set_count_in(api, 1)
	pa.transport_set_metronome_level(api, -12)
	pa.transport_set_metronome_sound(api, .Cowbell)
	h, _ := pa.history_state(api)
	testing.expect(t, h.grouping, "open")
	// No undoing into the middle of a group.
	testing.expect_value(t, pa.history_undo(api), pa.Result.Busy)
	testing.expect_value(t, pa.history_redo(api), pa.Result.Busy)
	testing.expect_value(t, pa.history_go_to(api, 0), pa.Result.Busy)
	testing.expect_value(t, pa.history_group_end(api), pa.Result.Ok)
	h, _ = pa.history_state(api)
	testing.expect_value(t, h.undo_steps, 1)
	name, _ := pa.history_undo_name(api)
	testing.expect_value(t, name, "Set Up the Click")
	pa.history_undo(api)
	s, _ := pa.transport_state(api)
	testing.expect(t, s.count_in == 0 && s.metronome_db == -6 && s.metronome_sound == .Beep, "all three undone")
}

@(test)
steps_are_named_along_the_history_and_gone_to :: proc(t: ^testing.T) {
	r := rig_make(t, "history_go_to")
	defer rig_destroy(r)
	api := &r.api
	pa.transport_set_tempo(api, 90)
	pa.transport_set_loop(api, false)
	pa.transport_set_time_signature(api, 3, 4)
	names := [3]string{"Set Tempo", "Loop", "Time Signature"}
	for n, k in names {
		got, res := pa.history_step_name(api, i64(k))
		testing.expect(t, res == .Ok && got == n, n)
	}
	_, res := pa.history_step_name(api, 3)
	testing.expect_value(t, res, pa.Result.Not_Found)
	// All undone: the steps are where they were, now redoable.
	testing.expect_value(t, pa.history_go_to(api, 0), pa.Result.Ok)
	h, _ := pa.history_state(api)
	testing.expect(t, h.undo_steps == 0 && h.redo_steps == 3, "all undone")
	for n, k in names {
		got, _ := pa.history_step_name(api, i64(k))
		testing.expect_value(t, got, n)
	}
	testing.expect_value(t, pa.history_go_to(api, 2), pa.Result.Ok)
	s, _ := pa.transport_state(api)
	testing.expect(t, s.bpm == 90 && !s.loop && s.time_sig_num == 4, "two redone")
	testing.expect_value(t, pa.history_go_to(api, 4), pa.Result.Invalid_Argument)
	testing.expect_value(t, pa.history_go_to(api, -1), pa.Result.Invalid_Argument)
}
