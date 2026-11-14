package test_pads_api

import "core:testing"

import pa "../../apps/pads/api"

@(test)
settings_are_set_checked_and_undoable :: proc(t: ^testing.T) {
	r := rig_make(t, "transport_settings")
	defer rig_destroy(r)
	api := &r.api
	v, _ := pa.api_version(api)
	testing.expect_value(t, v, i64(pa.VERSION))
	s, _ := pa.transport_state(api)
	testing.expect(t, !s.playing && s.bpm == 120 && s.loop && s.time_sig_num == 4 && s.time_sig_den == 4, "a new project's")
	testing.expect(t, s.bar == 1 && s.beat_in_bar == 1 && s.sixteenth == 1, "at the top")

	testing.expect_value(t, pa.transport_set_tempo(api, 20), pa.Result.Invalid_Argument)
	why, _ := pa.last_error(api)
	testing.expect_value(t, why, "the tempo is 40..300 BPM")
	testing.expect_value(t, pa.transport_set_count_in(api, 3), pa.Result.Invalid_Argument)
	testing.expect_value(t, pa.transport_set_time_signature(api, 0, 4), pa.Result.Invalid_Argument)
	testing.expect_value(t, pa.transport_set_time_signature(api, 7, 3), pa.Result.Invalid_Argument)
	testing.expect_value(t, pa.transport_set_metronome_level(api, 12), pa.Result.Invalid_Argument)
	testing.expect_value(t, pa.transport_set_metronome_sound(api, pa.Metronome_Sound(9)), pa.Result.Invalid_Argument)
	h, _ := pa.history_state(api)
	testing.expect_value(t, h.undo_steps, 0) // (nothing failed changed anything)

	testing.expect_value(t, pa.transport_set_tempo(api, 96.5), pa.Result.Ok)
	testing.expect_value(t, pa.transport_set_loop(api, false), pa.Result.Ok)
	testing.expect_value(t, pa.transport_set_count_in(api, 2), pa.Result.Ok)
	testing.expect_value(t, pa.transport_set_time_signature(api, 7, 8), pa.Result.Ok)
	testing.expect_value(t, pa.transport_set_metronome(api, true), pa.Result.Ok)
	testing.expect_value(t, pa.transport_set_metronome_level(api, -20), pa.Result.Ok)
	testing.expect_value(t, pa.transport_set_metronome_sound(api, .Wood), pa.Result.Ok)
	testing.expect_value(t, pa.transport_set_metronome_accent(api, false), pa.Result.Ok)
	testing.expect_value(t, pa.transport_set_metronome_recording_only(api, true), pa.Result.Ok)
	testing.expect_value(t, pa.transport_set_song_mode(api, true), pa.Result.Ok)
	s, _ = pa.transport_state(api)
	testing.expect_value(t, s.bpm, 96.5)
	testing.expect(t, !s.loop && s.count_in == 2 && s.time_sig_num == 7 && s.time_sig_den == 8, "loop, count-in, time signature")
	testing.expect(t, s.metronome && s.metronome_db == -20 && s.metronome_sound == .Wood && !s.metronome_accent && s.metronome_recording_only, "the metronome")
	testing.expect(t, s.song_mode, "song mode")
	// The project's settings are undo steps (the metronome's switch and song mode are not).
	h, _ = pa.history_state(api)
	testing.expect_value(t, h.undo_steps, 8)
	pa.history_go_to(api, 0)
	s, _ = pa.transport_state(api)
	testing.expect(t, s.bpm == 120 && s.loop && s.count_in == 0 && s.time_sig_num == 4 && s.metronome_accent && !s.metronome_recording_only, "all undone")
}

@(test)
play_stop_and_toggle_move_the_playhead :: proc(t: ^testing.T) {
	r := rig_make(t, "transport_play")
	defer rig_destroy(r)
	api := &r.api
	testing.expect_value(t, pa.transport_play(api), pa.Result.Ok)
	render(r, int(SR)) // a second at 120: two beats
	s, _ := pa.transport_state(api)
	testing.expect(t, s.playing && !s.counting_in, "playing")
	testing.expectf(t, s.beat > 1.5 && s.beat < 2.5, "two beats in (%v)", s.beat)
	testing.expect_value(t, s.bar, 1)
	testing.expect_value(t, s.beat_in_bar, 3)
	// (Play and stop reach the audio thread with the next block.)
	testing.expect_value(t, pa.transport_stop(api), pa.Result.Ok)
	render(r, 256)
	s, _ = pa.transport_state(api)
	testing.expect(t, !s.playing && s.beat == 0, "stopped at the top")
	testing.expect_value(t, pa.transport_toggle(api), pa.Result.Ok)
	render(r, 256)
	s, _ = pa.transport_state(api)
	testing.expect(t, s.playing, "toggled on")
	testing.expect_value(t, pa.transport_toggle(api), pa.Result.Ok)
	render(r, 256)
	s, _ = pa.transport_state(api)
	testing.expect(t, !s.playing, "toggled off")
	// From a beat; never from before the top.
	testing.expect_value(t, pa.transport_play(api, -1), pa.Result.Invalid_Argument)
	testing.expect_value(t, pa.transport_play(api, 2), pa.Result.Ok)
	render(r, 256)
	s, _ = pa.transport_state(api)
	testing.expectf(t, s.beat >= 2 && s.beat < 2.1, "from beat 2 (%v)", s.beat)
	pa.transport_stop(api)
}

@(test)
a_count_in_plays_before_the_top :: proc(t: ^testing.T) {
	r := rig_make(t, "transport_count_in")
	defer rig_destroy(r)
	api := &r.api
	pa.transport_set_count_in(api, 1)
	pa.transport_play(api, count_in = true)
	render(r, 256)
	s, _ := pa.transport_state(api)
	testing.expect(t, s.playing && s.counting_in, "counting in")
	testing.expectf(t, s.timeline_beat < -3.9 && s.timeline_beat > -4, "a bar before the top (%v)", s.timeline_beat)
	testing.expect(t, s.bar <= 0, "bar 0 counting in")
	pa.transport_stop(api)
}

@(test)
stop_disarms_rec_and_silence_counts :: proc(t: ^testing.T) {
	r := rig_make(t, "transport_silence")
	defer rig_destroy(r)
	api := &r.api
	r.core.capture.armed = true
	s, _ := pa.transport_state(api)
	testing.expect(t, s.recording, "armed")
	pa.transport_stop(api)
	s, _ = pa.transport_state(api)
	testing.expect(t, !s.recording, "Stop disarms")
	testing.expect_value(t, pa.transport_silence(api), pa.Result.Ok)
	testing.expect_value(t, r.core.transport.silences, 1)
}

@(test)
four_taps_set_the_tempo_and_start_a_beat_later :: proc(t: ^testing.T) {
	r := rig_make(t, "transport_tap")
	defer rig_destroy(r)
	api := &r.api
	bpm, res := pa.transport_tap(api)
	testing.expect(t, res == .Ok && bpm == 0, "one tap: no tempo yet")
	for _ in 0 ..< 3 {
		frame(r, 0.5) // 120 BPM
		bpm, _ = pa.transport_tap(api)
	}
	testing.expect_value(t, bpm, 120)
	testing.expect_value(t, r.core.m.project.bpm, 120)
	s, _ := pa.transport_state(api)
	testing.expect(t, !s.playing, "not yet")
	frame(r, 0.25)
	s, _ = pa.transport_state(api)
	testing.expect(t, !s.playing, "half a beat on: not yet")
	frame(r, 0.3)
	render(r, 256)
	s, _ = pa.transport_state(api)
	testing.expect(t, s.playing, "a beat on: playing")
	// Taps a 100 BPM apart: the tempo, set to a tenth.
	pa.transport_stop(api)
	frame(r, 3) // (a pause: the taps start again)
	for _ in 0 ..< 3 {
		pa.transport_tap(api)
		frame(r, 0.6)
	}
	bpm, _ = pa.transport_tap(api)
	testing.expect_value(t, bpm, 100)
}
