package test_pads_model

import "core:math"
import "core:path/filepath"
import "core:testing"

import app "app:core"
import "fire:audiofile"
import fc "fire:core"
import kit "fire:testkit"
import pm "../../apps/pads/model"

// Four half-second parts, each a tone of its own (300, 600, 900, 1200 Hz)
// that starts at once and decays: a loop to slice.
four_parts :: proc(r: ^Rig, name: string) -> string {
	path, _ := filepath.join({r.dir, name}, context.temp_allocator)
	part := int(SR / 2)
	x := make([]f32, part * 4, context.temp_allocator)
	for k in 0 ..< 4 do for i in 0 ..< part {
		t := f64(i) / SR
		x[k * part + i] = f32(0.6 * math.exp(-t * 3) * math.sin(math.TAU * 300 * f64(k + 1) * t))
	}
	s := audiofile.default_writer_settings(SR, 1)
	s.encoding = .Float32
	w, _ := audiofile.writer_create(path, s)
	audiofile.writer_write(w, {x}, len(x))
	audiofile.writer_close(w)
	return path
}

// Plays slice `k` of pad `i` (as the keyboard would), renders `frames`.
play_slice :: proc(r: ^Rig, i, k: int, frames: int, velocity: f32 = 1) -> [2][]f32 {
	pm.hit(&r.m.engine, i, true, velocity, i8(k), keyboard = true)
	return render(r, frames)
}

// Loaded into a slicer, it is sliced at its four attacks; each slice plays
// its own part, on its own key from C3; Re-slice into equal parts and by
// beats; slices added, moved, taken away.
@(test)
a_slicer_slices_and_plays_each_slice :: proc(t: ^testing.T) {
	r := rig_make(t, "slicer_play")
	defer rig_destroy(r)
	m := &r.m
	testing.expect_value(t, pm.load_slicer(m, 0, four_parts(r, "four.wav")), fc.Error.None)
	render(r, 256)
	sl := m.project.pads[0].slicer
	testing.expect(t, m.project.pads[0].kind == .Slicer && sl.base == 60, "a slicer, from C3")
	testing.expectf(t, sl.count == 4, "four slices (%d)", sl.count)
	for k in 1 ..< sl.count do testing.expectf(t, abs(sl.slices[k].start - i64(k * 24_000)) < 600, "slice %d at its attack (%d)", k + 1, sl.slices[k].start)
	for k in 0 ..< 4 {
		out := play_slice(r, 0, k, 9_600)
		pm.hit(&r.m.engine, 0, false, 0, i8(k), keyboard = true)
		hz := hz_of(out[0][2000:9000])
		testing.expectf(t, abs(hz - 300 * f64(k + 1)) < 30, "slice %d plays its own part (%v Hz)", k + 1, hz)
		render(r, 24_000)
	}
	testing.expect_value(t, pm.slice_end(m, 0, 3), 96_000)
	pm.slice_pad(m, 0, .Equal) // 16 parts
	testing.expect_value(t, m.project.pads[0].slicer.count, 16)
	sl = m.project.pads[0].slicer
	sl.grain = .Quarter
	pm.set_slicer(m, 0, sl, "Grid")
	pm.slice_pad(m, 0, .Beats) // 2 s at 120 BPM: 4 beats
	testing.expect_value(t, m.project.pads[0].slicer.count, 4)
	testing.expect(t, pm.add_slice(m, 0, 30_000), "added")
	testing.expect_value(t, m.project.pads[0].slicer.slices[2].start, 30_000) // (in order)
	pm.move_slice(m, 0, 2, 40_000)
	testing.expect_value(t, m.project.pads[0].slicer.slices[2].start, 40_000)
	pm.remove_slice(m, 0, 2)
	testing.expect_value(t, m.project.pads[0].slicer.count, 4)
	testing.expect_value(t, m.project.pads[0].slicer.by, pm.Slice_By.Manual)
}

// Mono: a slice cuts the one before off; poly: they sound together. Thru:
// a slice plays past its end into the next part. Gate: a slice stops when
// let go. A slice's level; velocity sensitivity (0: every hit as loud).
@(test)
a_slicers_play_modes_levels_and_velocity :: proc(t: ^testing.T) {
	r := rig_make(t, "slicer_modes")
	defer rig_destroy(r)
	m := &r.m
	pm.load_slicer(m, 0, four_parts(r, "four.wav"))
	render(r, 256)
	both :: proc(r: ^Rig) -> (low, high: f64) {
		pm.hit(&r.m.engine, 0, true, 1, 0, keyboard = true)
		render(r, 2400)
		pm.hit(&r.m.engine, 0, true, 1, 3, keyboard = true)
		out := render(r, 4800)
		low, high = kit.tone_amplitude(out[0][1200:], SR, 300), kit.tone_amplitude(out[0][1200:], SR, 1200)
		pm.hit(&r.m.engine, 0, false, 0, 0, keyboard = true)
		pm.hit(&r.m.engine, 0, false, 0, 3, keyboard = true)
		render(r, 48_000)
		return
	}
	lo, hi := both(r)
	testing.expectf(t, lo > 0.05 && hi > 0.05, "poly: both slices (%v %v)", lo, hi)
	sl := m.project.pads[0].slicer
	sl.mono = true
	pm.set_slicer(m, 0, sl, "Mono")
	pm.sync(&m.engine)
	lo, hi = both(r)
	testing.expectf(t, lo < 0.01 && hi > 0.05, "mono: the second cuts the first (%v %v)", lo, hi)
	// Thru: slice 1 runs on into part 2 (600 Hz) after its 0.5 s.
	sl.mono, sl.thru = false, true
	pm.set_slicer(m, 0, sl, "Thru")
	pm.sync(&m.engine)
	out := play_slice(r, 0, 0, 36_000)
	testing.expectf(t, kit.tone_amplitude(out[0][27_000:35_000], SR, 600) > 0.05, "thru: on into the next part")
	render(r, 96_000)
	// Gate: let go after 0.1 s, it stops (a release later, silence).
	sl.thru, sl.gate = false, true
	pm.set_slicer(m, 0, sl, "Gate")
	pm.sync(&m.engine)
	play_slice(r, 0, 0, 4800)
	pm.hit(&m.engine, 0, false, 0, 0, keyboard = true)
	out = render(r, 9600)
	testing.expectf(t, kit.peak(out[0][7200:]) < 0.01, "gate: stopped when let go (%v)", kit.peak(out[0][7200:]))
	// A slice 12 dB down.
	sl.gate = false
	sl.slices[1].gain_db = -12
	pm.set_slicer(m, 0, sl, "Level")
	pm.sync(&m.engine)
	full := kit.peak(play_slice(r, 0, 0, 4800)[0][:])
	render(r, 30_000)
	quiet := kit.peak(play_slice(r, 0, 1, 4800)[0][:])
	render(r, 30_000)
	testing.expectf(t, abs(20 * math.log10(quiet / full) + 12) < 1.5, "slice 2, 12 dB down (%v)", 20 * math.log10(quiet / full))
	// Velocity: sensitivity 0, a soft hit as loud as a hard one.
	pad := m.project.pads[0]
	pad.voice.velocity = 0
	pm.set_pad(m, 0, .Voice, "Velocity", pad)
	pm.sync(&m.engine)
	soft := kit.peak(play_slice(r, 0, 0, 4800, 0.2)[0][:])
	testing.expectf(t, abs(soft - full) / full < 0.05, "sensitivity 0: as loud (%v vs %v)", soft, full)
}

// Slices to a sequence (each where it falls, its pitch its slice); a slice
// onto its own pad; sampler and back; saved and loaded.
@(test)
a_slicers_slices_go_to_sequences_pads_and_files :: proc(t: ^testing.T) {
	r := rig_make(t, "slicer_ops")
	defer rig_destroy(r)
	m := &r.m
	pm.load_slicer(m, 0, four_parts(r, "four.wav"))
	render(r, 256)
	slot := pm.slices_to_sequence(m, 0)
	testing.expect(t, slot >= 0 && m.project.slot == slot, "a new sequence, current")
	notes := m.project.sequences[slot].notes
	testing.expectf(t, len(notes) == 4, "a note a slice (%v)", notes)
	for n, k in notes do testing.expectf(t, int(n.pitch) == k && abs(n.start - f64(k)) < 0.02, "slice %d on beat %d (%v)", k + 1, k + 1, n)
	// It plays them: the sequence's first beat is slice 1 (300 Hz).
	pm.play(&m.engine)
	out := render(r, 12_000)
	testing.expectf(t, abs(hz_of(out[0][2000:11000]) - 300) < 30, "the sequence plays slice 1 first")
	pm.stop(&m.engine)
	// Slice 3 onto the next empty pad: a sampler of that part.
	to := pm.slice_to_pad(m, 0, 2)
	testing.expect_value(t, to, 1)
	p1 := m.project.pads[1]
	testing.expect(t, p1.kind == .Sampler && p1.start == m.project.pads[0].slicer.slices[2].start && p1.end == pm.slice_end(m, 0, 2), "its part alone")
	pm.hit(&m.engine, 1, true)
	out = render(r, 9600)
	testing.expectf(t, abs(hz_of(out[0][2000:9000]) - 900) < 40, "plays part 3 (%v)", hz_of(out[0][2000:9000]))
	// Sampler and back: the slices kept.
	pm.make_sampler(m, 0)
	testing.expect(t, m.project.pads[0].kind == .Sampler && m.project.pads[0].slicer.count == 4, "a sampler; slices kept")
	pm.make_slicer(m, 0)
	testing.expect_value(t, m.project.pads[0].slicer.count, 4)
	// Saved and loaded.
	sl := m.project.pads[0].slicer
	sl.mono, sl.fade_out_ms = true, 12
	sl.slices[2].pitch, sl.slices[2].reverse = -5, true
	pm.set_slicer(m, 0, sl, "Edit")
	testing.expect_value(t, pm.model_save(m), fc.Error.None)
	r2 := rig_make(t, "slicer_ops2")
	defer rig_destroy(r2)
	testing.expect_value(t, pm.model_load(&r2.m, m.project.dir), fc.Error.None)
	testing.expect(t, r2.m.project.pads[0].slicer == m.project.pads[0].slicer && r2.m.project.pads[0].kind == .Slicer, "the slicer back")
	app.undo(&m.history)
	_ = app.Id(0)
}

// An empty slicer: a pad in use (its strip shows), silent until a sample
// is put in it.
@(test)
an_empty_slicer :: proc(t: ^testing.T) {
	r := rig_make(t, "slicer_empty")
	defer rig_destroy(r)
	m := &r.m
	pm.empty_slicer(m, 5)
	testing.expect(t, pm.pad_used(&m.project, 5) && m.project.pads[5].kind == .Slicer, "in use, a slicer")
	pm.load_slicer(m, 5, four_parts(r, "four.wav"))
	testing.expect_value(t, m.project.pads[5].slicer.count, 4)
}

// Warped (its own tempo half the project's: twice as fast, its pitch
// kept), a slicer plays each slice from the rendering where it falls; its
// playhead is in the sample's frames (over the waveform and its slices);
// its fades are as long as set, not stretched with it.
@(test)
a_warped_slicer_plays_its_slices_in_time :: proc(t: ^testing.T) {
	r := rig_make(t, "slicer_warp")
	defer rig_destroy(r)
	m := &r.m
	testing.expect_value(t, pm.load_slicer(m, 0, four_parts(r, "four.wav")), fc.Error.None)
	render(r, 256)
	pm.set_warp(m, 0, {on = true, mode = .Tones, bpm = 60})
	testing.expect(t, warp_ready(r, 0), "rendered")
	start := m.project.pads[0].slicer.slices[2].start
	out := play_slice(r, 0, 2, 4800)
	head, playing := pm.pad_playhead(&m.engine, 0)
	testing.expect(t, playing, "playing")
	// 4800 frames out at twice the speed: 9600 of the sample's (a block either way).
	testing.expectf(t, abs(head - (start + 9600)) <= 2 * 256 * 2, "the playhead over the sample (%d, want %d)", head, start + 9600)
	hz := hz_of(out[0][1000:4800])
	testing.expectf(t, abs(hz - 900) < 40, "slice 3 plays its own part, its pitch kept (%v Hz)", hz)
	pm.hit(&r.m.engine, 0, false, 0, 2, keyboard = true)
	// Fades: 10 ms is 480 frames, warped or not.
	pad := m.project.pads[0]
	pad.slicer.fade_in_ms, pad.slicer.fade_out_ms = 10, 10
	pad.end = 96_000
	zones := pm.slicer_zones(pad, nil, 0.5)
	testing.expect_value(t, zones[0].fade_in, i64(480))
	testing.expect_value(t, zones[0].fade_out, i64(480))
	testing.expect_value(t, zones[2].start, i64(math.round(f64(start) * 0.5)))
}
