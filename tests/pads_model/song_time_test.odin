package test_pads_model

import "core:math"
import "core:testing"

import app "app:core"
import fc "fire:core"
import "fire:transport"
import pm "../../apps/pads/model"

// A song of `beats` beats (sequence 1, a bar, round and round), in song
// mode with the transport's loop `loop`.
@(private)
song_rig :: proc(t: ^testing.T, name: string, beats: int, loop: bool) -> ^Rig {
	r := blips(t, name)
	m := &r.m
	pm.song_add(m, 0, repeats = beats / 4)
	m.project.song_mode = true
	m.project.transport.loop = loop
	m.engine.seq_dirty = true
	return r
}

// The timeline's position after `seconds` of playing from the top.
@(private)
beat_after :: proc(r: ^Rig, seconds: f64) -> f64 {
	pm.play(&r.m.engine)
	render_synced(r, int(seconds * 48_000), 480)
	pos, _, _ := transport.timeline_status(r.m.engine.host.clock, r.m.engine.timeline)
	return f64(pos)
}

@(test)
the_tempo_lane_steps_and_ramps :: proc(t: ^testing.T) {
	pts := []pm.Tempo_Point{{0, 120, false}, {8, 60, true}, {16, 120, false}}
	testing.expect_value(t, pm.tempo_in(pts, 4), 120)
	testing.expect_value(t, pm.tempo_in(pts, 12), 90) // halfway up the ramp
	testing.expect_value(t, pm.tempo_in(pts, 20), 120)
	// Played: 8 beats at 120 (4 s), then 60: 2 s on is 2 beats further.
	r := song_rig(t, "tempo_step", 32, false)
	defer rig_destroy(r)
	m := &r.m
	pm.tempo_point_add(m, {0, 120, false})
	pm.tempo_point_add(m, {8, 60, false})
	testing.expect_value(t, m.project.song.tempo_count, 2)
	b := beat_after(r, 6)
	testing.expectf(t, abs(b - 10) < 0.02, "8 beats at 120, 2 at 60 (%v)", b)
	pm.stop(&m.engine)
	// A ramp from 120 to 240 over 8 beats takes 4·ln 2 s.
	pm.tempo_point_set(m, 0, {0, 120, true})
	pm.tempo_point_set(m, 1, {8, 240, false})
	app.seal(&m.history)
	b = beat_after(r, 4 * math.LN2)
	testing.expectf(t, abs(b - 8) < 0.02, "the ramp's 8 beats in 4 ln 2 s (%v)", b)
}

@(test)
the_tempo_follows_the_loop_round :: proc(t: ^testing.T) {
	// 120 up to beat 6, 60 from there; looping beats 4..8. The first pass
	// (0..8) takes 3 + 2 s; each pass after (4..8) 1 + 2 s.
	r := song_rig(t, "tempo_loop", 16, true)
	defer rig_destroy(r)
	m := &r.m
	pm.tempo_point_add(m, {0, 120, false})
	pm.tempo_point_add(m, {6, 60, false})
	pm.set_song_loop(m, true, 4, 8)
	b := beat_after(r, 6)
	testing.expectf(t, abs(b - 10) < 0.02, "the second pass at 120 again (%v)", b)
	render_synced(r, 2 * 48_000, 480)
	pos, _, _ := transport.timeline_status(m.engine.host.clock, m.engine.timeline)
	testing.expectf(t, abs(f64(pos) - 12) < 0.02, "then 60 (%v)", pos)
	// Past a few passes the map is laid out further.
	render_synced(r, 30 * 48_000, 2400)
	pos, _, _ = transport.timeline_status(m.engine.host.clock, m.engine.timeline)
	testing.expectf(t, abs(f64(pos) - (12 + 40)) < 0.05, "ten passes more (%v)", pos)
	// No lane: the steps' tempos.
	pm.stop(&m.engine)
	for m.project.song.tempo_count > 1 do pm.tempo_point_remove(m, m.project.song.tempo_count - 1)
	pm.tempo_point_remove(m, 0)
	testing.expect_value(t, m.project.song.tempo_count, 0)
	testing.expect_value(t, pm.song_tempo_at(&m.project, 5), m.project.bpm)
}

@(test)
steps_have_time_signatures :: proc(t: ^testing.T) {
	r := song_rig(t, "song_meters", 8, false)
	defer rig_destroy(r)
	m := &r.m
	pm.song_add(m, 0, repeats = 3) // beats 8..20
	pm.set_step_meter(m, 1, {3, 4})
	testing.expect_value(t, pm.song_meter_at(&m.project, 9), pm.Time_Sig{3, 4})
	testing.expect_value(t, pm.song_meter_at(&m.project, 2), m.project.transport.time_sig)
	mp := pm.song_tempo_map(&m.project, pm.plan_song(&m.project, 0), 1)
	testing.expect(t, len(mp.meters) == 2 && mp.meters[1].bar == 2 && mp.meters[1].meter.numerator == 3, "3/4 from bar 3")
	// The clock's bars follow it: beat 11 is bar 3 + 1 bar of 3/4.
	pm.play(&m.engine)
	render_synced(r, int(5.5 * 48_000), 480) // beat 11
	st := transport.status(m.engine.host.clock)
	testing.expectf(t, st.meter.numerator == 3, "3/4 while it plays (%v)", st.meter)
}

@(test)
markers_and_the_loop_range_are_kept :: proc(t: ^testing.T) {
	r := song_rig(t, "song_markers", 16, true)
	defer rig_destroy(r)
	m := &r.m
	testing.expect_value(t, pm.marker_add(m, 8, "Chorus"), 0)
	testing.expect_value(t, pm.marker_add(m, 0, "Intro"), 0) // in order
	pm.marker_add(m, 12, "Outro")
	testing.expect_value(t, pm.marker_name(&m.project.song.markers[1]), "Chorus")
	testing.expect_value(t, pm.marker_next(&m.project, 0), 1)
	testing.expect_value(t, pm.marker_next(&m.project, 9, back = true), 1)
	testing.expect_value(t, pm.marker_next(&m.project, 12), -1)
	pm.marker_move(m, 2, 4) // Outro before Chorus now
	app.seal(&m.history)
	testing.expect_value(t, pm.marker_name(&m.project.song.markers[1]), "Outro")
	pm.marker_rename(m, 1, "Bridge")
	pm.set_song_loop(m, true, 12, 4) // (either way round)
	testing.expect(t, m.project.song.loop_start == 4 && m.project.song.loop_end == 12)
	pm.tempo_point_add(m, {0, 100, true})
	pm.tempo_point_add(m, {8, 140, false})
	pm.set_step_meter(m, 0, {7, 8})
	testing.expect_value(t, pm.model_save(m), fc.Error.None)
	r2 := rig_make(t, "song_markers_load")
	defer rig_destroy(r2)
	testing.expect_value(t, pm.model_load(&r2.m, m.project.dir), fc.Error.None)
	s := r2.m.project.song
	testing.expect_value(t, s.marker_count, 3)
	testing.expect_value(t, pm.marker_name(&s.markers[1]), "Bridge")
	testing.expect(t, s.loop_on && s.loop_start == 4 && s.loop_end == 12)
	testing.expect(t, s.tempo_count == 2 && s.tempo[0].ramp && s.tempo[1].bpm == 140)
	testing.expect_value(t, s.steps[0].meter, pm.Time_Sig{7, 8})
	// Undone: the loop range goes.
	app.undo(&m.history)
	app.undo(&m.history)
	app.undo(&m.history)
	app.undo(&m.history)
	testing.expect(t, !m.project.song.loop_on)
}
