package test_pads_api

import "core:testing"

import pa "../../apps/pads/api"

@(test)
an_audio_tracks_part_is_edited :: proc(t: ^testing.T) {
	r := rig_make(t, "audio")
	defer rig_destroy(r)
	api := &r.api
	path := tone(r) // (a second: two beats at 120)
	testing.expect_value(t, pa.audio_add_take(api, 0, 1, path), pa.Result.Unsupported) // (not an audio track)
	pa.pad_set_kind(api, 1, .Audio)
	testing.expect_value(t, pa.audio_add_take(api, 0, 1, "/no/such.wav"), pa.Result.Io_Error)
	testing.expect_value(t, pa.audio_add_take(api, 0, 1, path), pa.Result.Ok)
	p, _ := pa.audio_part(api, 0, 1)
	testing.expect(t, p.regions == 1 && p.takes == 1, "a take, a region")
	g, _ := pa.audio_region(api, 0, 1, 0)
	testing.expect(t, g.at == 0 && g.end > g.start, "at the top")
	// Split, a region's settings, deleted, undone.
	testing.expect_value(t, pa.audio_split(api, 0, 1, 1), pa.Result.Ok)
	testing.expect_value(t, pa.audio_split(api, 0, 1, 3.5), pa.Result.Not_Found) // (no region there)
	p, _ = pa.audio_part(api, 0, 1)
	testing.expect_value(t, p.regions, 2)
	g, _ = pa.audio_region(api, 0, 1, 1)
	g.gain_db, g.pan, g.fade_in, g.mute = -6, 0.5, 0.01, true
	testing.expect_value(t, pa.audio_set_region(api, 0, 1, 1, g), pa.Result.Ok)
	got, _ := pa.audio_region(api, 0, 1, 1)
	testing.expect(t, got.gain_db == -6 && got.pan == 0.5 && got.mute, "set")
	g.pan = 3
	testing.expect_value(t, pa.audio_set_region(api, 0, 1, 1, g), pa.Result.Invalid_Argument)
	testing.expect_value(t, pa.audio_normalize_region(api, 0, 1, 0), pa.Result.Ok)
	testing.expect_value(t, pa.audio_move_region(api, 0, 1, 1, 1.5), pa.Result.Ok)
	testing.expect_value(t, pa.audio_trim_region(api, 0, 1, 0, 0.5, true), pa.Result.Ok)
	testing.expect_value(t, pa.audio_delete_region(api, 0, 1, 1), pa.Result.Ok)
	testing.expect_value(t, pa.audio_delete_region(api, 0, 1, 5), pa.Result.Not_Found)
	p, _ = pa.audio_part(api, 0, 1)
	testing.expect_value(t, p.regions, 1)
	pa.history_undo(api)
	p, _ = pa.audio_part(api, 0, 1)
	testing.expect_value(t, p.regions, 2)
	// A range deleted, then cropped.
	testing.expect_value(t, pa.audio_delete_range(api, 0, 1, 0.25, 0.5), pa.Result.Ok)
	testing.expect_value(t, pa.audio_delete_range(api, 0, 1, 1, 0.5), pa.Result.Invalid_Argument)
	testing.expect_value(t, pa.audio_crop(api, 0, 1, 0, 1.5), pa.Result.Ok)
	// Takes: a second, used for a range (comping).
	pa.audio_add_take(api, 0, 1, tone(r, "b.wav"), 0)
	p, _ = pa.audio_part(api, 0, 1)
	testing.expect_value(t, p.takes, 2)
	testing.expect_value(t, pa.audio_use_take(api, 0, 1, 0, 0, 1), pa.Result.Ok)
	testing.expect_value(t, pa.audio_use_take(api, 0, 1, 5, 0, 1), pa.Result.Not_Found)
	// Warp, consolidated, cleared.
	testing.expect_value(t, pa.audio_set_warp(api, 0, 1, .Stretch, 3), pa.Result.Ok)
	p, _ = pa.audio_part(api, 0, 1)
	testing.expect(t, p.warp == .Stretch && p.transpose == 3, "stretched, up 3")
	testing.expect_value(t, pa.audio_set_warp(api, 0, 1, .Stretch, 30), pa.Result.Invalid_Argument)
	res := pa.audio_consolidate(api, 0, 1)
	testing.expect(t, res == .Ok || res == .Busy, "consolidated, or not yet")
	testing.expect_value(t, pa.audio_clear(api, 1), pa.Result.Ok)
	p, _ = pa.audio_part(api, 0, 1)
	testing.expect_value(t, p.regions, 0)
}

@(test)
rec_and_sampling :: proc(t: ^testing.T) {
	r := rig_make(t, "recording")
	defer rig_destroy(r)
	api := &r.api
	s, _ := pa.recording_state(api)
	testing.expect(t, !s.armed && !s.recording && !s.sampling && s.sample_pad == -1, "idle")
	// Rec from a stop: it plays (after a count-in, if any).
	pa.transport_set_count_in(api, 1)
	testing.expect_value(t, pa.recording_record(api, true), pa.Result.Ok)
	render(r, 256)
	s, _ = pa.recording_state(api)
	testing.expect(t, s.armed && s.recording, "recording")
	ts, _ := pa.transport_state(api)
	testing.expect(t, ts.counting_in, "counting in first")
	testing.expect_value(t, pa.recording_record(api, false), pa.Result.Ok)
	s, _ = pa.recording_state(api)
	testing.expect(t, !s.armed, "disarmed")
	pa.transport_stop(api)
	// Sampling: this rig has no audio input.
	testing.expect_value(t, pa.recording_sample_start(api, 0, .Hold), pa.Result.Unsupported)
	testing.expect_value(t, pa.recording_sample_start(api, 0, .Bars, -40, 20), pa.Result.Invalid_Argument)
	testing.expect_value(t, pa.recording_sample_stop(api), pa.Result.Not_Found)
}
