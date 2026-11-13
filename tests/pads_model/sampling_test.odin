package test_pads_model

import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import app "app:core"
import "fire:audiofile"
import pm "../../apps/pads/model"

// The rig's simulated interface with a cable from its outputs to its
// inputs (`rig_cabled`): pad 0 plays a hit on beat 2 of each bar (beat 1
// counted from 0), which comes back on the inputs and is recorded into pad 2.
@(private = "file")
sampling_rig :: proc(t: ^testing.T, name: string) -> ^Rig {
	r := rig_cabled(t, name)
	m := &r.m
	pm.load_onto_pad(m, 0, tone(r, "hit.wav", 440, 0.05, decay = true))
	pm.add_note(m, 0, {start = 1, length = 0.25, pad = 0, velocity = 1})
	run(r, 4096)
	return r
}

// A recorder for pad `pad` made ready (as the app does each frame for the
// selected pad) and run a while.
@(private = "file")
ready :: proc(r: ^Rig, rec: ^pm.Recording, pad: int) {
	pm.record_prepare(&r.m, rec, pad)
	run(r, 4096)
}

// Waits for pad `pad`'s recorded sample (the take finished and put on it).
@(private = "file")
take_on :: proc(r: ^Rig, rec: ^pm.Recording, pad: int) -> ^pm.Sample {
	for _ in 0 ..< 400 {
		pm.record_poll(&r.m, rec)
		if id := r.m.project.pads[pad].sample; id != 0 do return app.store_get(&r.m.project.samples, id)
		run(r, 256)
	}
	return nil
}

@(private = "file")
read_all :: proc(s: ^pm.Sample) -> []f32 {
	rd, err := audiofile.open(s.path, context.temp_allocator)
	if err != .None do return nil
	defer audiofile.close(rd)
	x := make([]f32, int(s.frames), context.temp_allocator)
	y := make([]f32, int(s.frames), context.temp_allocator)
	audiofile.read(rd, {x, y}, len(x))
	return x
}

@(test)
hold_records_while_the_pad_is_held :: proc(t: ^testing.T) {
	r := sampling_rig(t, "sample_hold")
	defer rig_destroy(r)
	rec: pm.Recording
	ready(r, &rec, 2)
	testing.expect_value(t, pm.record_start(&r.m, &rec, 2, .Hold), nil)
	run(r, 256 * 40) // held 10240 frames
	pm.record_stop(&rec)
	s := take_on(r, &rec, 2)
	if !testing.expect(t, s != nil, "a sample on pad 2") do return
	testing.expectf(t, s.frames == 10240, "exactly as long as it was held (%d)", s.frames)
	testing.expect_value(t, r.m.project.pads[2].start, i64(0))
}

@(test)
threshold_starts_the_sample_at_the_sound :: proc(t: ^testing.T) {
	r := sampling_rig(t, "sample_threshold")
	defer rig_destroy(r)
	m := &r.m
	rec: pm.Recording
	ready(r, &rec, 2)
	pm.play(&m.engine)
	testing.expect_value(t, pm.record_start(m, &rec, 2, .Threshold, threshold_db = -30), nil)
	run(r, 48_000) // past the hit on beat 2 (frame 24000 of the bar)
	pm.record_stop(&rec)
	pm.stop(&m.engine)
	s := take_on(r, &rec, 2)
	if !testing.expect(t, s != nil, "a sample on pad 2") do return
	x := read_all(s)
	start := m.project.pads[2].start
	level := f32(math.pow(10, -30.0 / 20))
	first := -1
	for v, i in x do if abs(v) >= level {
		first = i
		break
	}
	testing.expectf(t, first > 0, "the hit is in it (%d)", first)
	testing.expectf(t, start == i64(first) - i64(pm.SAMPLE_PREROLL_S * 48_000), "it starts 5 ms before the sound (start %d, sound at %d)", start, first)
	// Never loud enough: nothing kept.
	quiet: pm.Recording
	pm.record_start(m, &quiet, 3, .Threshold, threshold_db = -1)
	run(r, 4096)
	pm.record_stop(&quiet)
	run(r, 4096)
	pm.record_poll(m, &quiet)
	run(r, 4096)
	pm.record_poll(m, &quiet)
	testing.expect_value(t, m.project.pads[3].sample, app.Id(0))
}

@(test)
bars_record_whole_bars_from_the_next :: proc(t: ^testing.T) {
	// Playing, half a bar in: one bar, from the next bar's start. The hit
	// on its beat 2 lands on that beat's frame of the sample (24000, and
	// the 6 frames its sine takes to pass the level).
	r := sampling_rig(t, "sample_bars")
	defer rig_destroy(r)
	m := &r.m
	pm.play(&m.engine)
	run(r, 48_000)
	rec: pm.Recording
	ready(r, &rec, 2)
	testing.expect_value(t, pm.record_start(m, &rec, 2, .Bars, bars = 1), nil)
	testing.expectf(t, abs(rec.from - 4) < 1e-9 && abs(rec.to - 8) < 1e-9, "the next bar (%v..%v)", rec.from, rec.to)
	run(r, 3 * 96_000 / 2) // past its end: it stops itself
	s := take_on(r, &rec, 2)
	pm.stop(&m.engine)
	if !testing.expect(t, s != nil, "a sample on pad 2") do return
	testing.expect_value(t, s.frames, i64(96_000))
	testing.expect(t, !rec.active, "stopped by itself")
	x := read_all(s)
	first := -1
	for v, i in x do if abs(v) > 0.02 {
		first = i
		break
	}
	testing.expectf(t, first == 24_006, "the hit on beat 2 of the bar (%d)", first)
}

@(test)
a_new_project_records_into_a_pad :: proc(t: ^testing.T) {
	// A project with nothing loaded has no samples folder yet: the take
	// still lands (its file made), on the pad, with what came in. After Save
	// As, the next one goes into the new project's folder.
	r := rig_cabled(t, "sample_fresh")
	defer rig_destroy(r)
	m := &r.m
	samples, _ := filepath.join({m.project.dir, pm.SAMPLES_FOLDER}, context.temp_allocator)
	os.remove_all(samples)
	testing.expect(t, !os.exists(samples), "no samples folder to start with")
	rec: pm.Recording
	defer pm.record_forget(&rec)
	ready(r, &rec, 2)
	testing.expect_value(t, pm.record_start(m, &rec, 2, .Hold), nil)
	run(r, 256 * 20)
	pm.record_stop(&rec)
	s := take_on(r, &rec, 2)
	if !testing.expect(t, s != nil, "a sample on pad 2") do return
	testing.expect(t, os.exists(s.path), "its file written")
	testing.expect(t, !rec.last_failed, "not a failed take")
	testing.expect_value(t, filepath.dir(s.path), pm.project_folder(m.project.dir, .Recorded))
	// The recorder made again (as when the input changes, or the project
	// opens again) counts from 1 again: the next take still has a name of
	// its own, and pad 2's sample is as it was.
	first := strings.clone(s.path, context.temp_allocator)
	first_frames := s.frames
	pm.record_forget(&rec)
	ready(r, &rec, 4)
	testing.expect_value(t, pm.record_start(m, &rec, 4, .Hold), nil)
	run(r, 256 * 30)
	pm.record_stop(&rec)
	s4 := take_on(r, &rec, 4)
	if !testing.expect(t, s4 != nil, "a sample on pad 4") do return
	testing.expect(t, s4.path != first, "a file of its own")
	if rd, err := audiofile.open(first, context.temp_allocator); testing.expect_value(t, err, audiofile.Error.None) {
		testing.expect_value(t, audiofile.info(rd).frames, first_frames) // not written over
		audiofile.close(rd)
	}
	// Saved elsewhere: the next take there.
	to, _ := filepath.join({r.dir, "moved"}, context.temp_allocator)
	testing.expect_value(t, pm.model_save_as(m, to), nil)
	ready(r, &rec, 3)
	testing.expect_value(t, pm.record_start(m, &rec, 3, .Hold), nil)
	run(r, 256 * 20)
	pm.record_stop(&rec)
	s3 := take_on(r, &rec, 3)
	if !testing.expect(t, s3 != nil, "a sample on pad 3") do return
	testing.expectf(t, strings.has_prefix(s3.path, m.project.dir), "in the project's folder now (%s, %s)", s3.path, m.project.dir)
	testing.expect(t, os.exists(s3.path), "its file written")
}
