package test_pads_model

import "core:testing"

import app "app:core"
import fc "fire:core"
import pm "../../apps/pads/model"

@(test)
a_track_loops_its_own_part_and_drifts :: proc(t: ^testing.T) {
	// A 4/4 bar; pad 0 loops 3 beats (its note at the top), pad 1 plays the
	// bar as written (beat 0). Pad 0 is heard at 0 and 3, then from the
	// sequence's top again (4, 7): the loop starts again at each pass.
	r := blips(t, "loop_drift")
	defer rig_destroy(r)
	m := &r.m
	pm.add_note(m, 0, {start = 0, length = 0.25, pad = 0, velocity = 1})
	pm.add_note(m, 0, {start = 3.5, length = 0.25, pad = 0, velocity = 1}) // (past its loop: not heard)
	pm.set_track_loop(m, 0, 0, 3)
	testing.expect_value(t, app.undo_name(&m.history), "Track Loop")
	testing.expect_value(t, pm.track_beats(&m.project, m.project.sequences[0], 0), 3)
	testing.expect_value(t, pm.track_beats(&m.project, m.project.sequences[0], 1), 4)
	render(r, 256)
	pm.play(&m.engine)
	out := render_synced(r, 2 * 96_000, 480)
	pm.stop(&m.engine)
	got := onsets(out[0][:])
	want := []int{0, 72_000, 96_000, 168_000}
	testing.expectf(t, len(got) == len(want), "a hit at 0 and 3 each bar (%v)", got)
	for w, i in want do if i < len(got) do testing.expectf(t, abs(got[i] - got[0] - w) <= 2, "hit %d at %d (%v)", i, w, got)
	// Off: as written again (0 and 3.5).
	pm.set_track_loop(m, 0, 0, 0)
	testing.expect_value(t, pm.track_beats(&m.project, m.project.sequences[0], 0), 4)
	notes := pm.played_notes(&m.project, m.project.sequences[0])
	testing.expect_value(t, len(notes), 2)
	// Saved and opened: the loop with it.
	pm.set_track_loop(m, 0, 0, 3)
	testing.expect_value(t, pm.model_save(m), fc.Error.None)
	r2 := rig_make(t, "loop_drift_load")
	defer rig_destroy(r2)
	testing.expect_value(t, pm.model_load(&r2.m, m.project.dir), fc.Error.None)
	testing.expect_value(t, r2.m.project.sequences[0].loops[0], f32(3))
}

@(test)
recording_into_a_looped_track_goes_round_its_loop :: proc(t: ^testing.T) {
	// Pad 0 loops 3 beats; a hit at beat 3.5 (the loop's second time round)
	// is recorded at 0.5 of it.
	r := blips(t, "loop_record")
	defer rig_destroy(r)
	m := &r.m
	m.project.transport.quantize.on = false
	pm.set_track_loop(m, 0, 0, 3)
	c: pm.Capture
	defer pm.capture_destroy(&c)
	pm.capture_arm(m, &c, true)
	pm.play(&m.engine)
	render(r, int(3.5 * 24_000))
	pm.hit(&m.engine, 0, true, 0.8)
	render(r, 6000)
	pm.hit(&m.engine, 0, false)
	render(r, 2400)
	pm.capture_poll(m, &c)
	pm.capture_arm(m, &c, false)
	pm.stop(&m.engine)
	notes := m.project.sequences[0].notes
	testing.expectf(t, len(notes) == 1 && abs(notes[0].start - 0.5) < 0.01, "at 0.5 of its loop (%v)", notes)
}

@(test)
an_audio_track_loops_exactly :: proc(t: ^testing.T) {
	// The ramp on pad 1, looped every beat (24 000 frames): each beat plays
	// the first again, from its very frame.
	r := rig_make(t, "loop_audio")
	defer rig_destroy(r)
	m := &r.m
	ramp_clip(r, 1)
	pm.set_track_loop(m, 0, 1, 1)
	mix := mix_of(t, m, 1)
	if mix == nil do return
	for k in 1 ..< 4 do for f in ([]int{0, 100, 23_999}) {
		testing.expectf(t, mix[k * 24_000 + f] == mix[f], "beat %d frame %d: as beat 1's (%v vs %v)", k + 1, f, mix[k * 24_000 + f], mix[f])
	}
	// A loop of 1/3 beat (8000 frames): no drift, each pass on its frame.
	pm.set_track_loop(m, 0, 1, 1.0 / 3)
	mix = mix_of(t, m, 1)
	if mix != nil do testing.expectf(t, mix[11 * 8000] == mix[0] && mix[11 * 8000 + 5] == mix[5], "the 12th pass on frame 88 000")
}
