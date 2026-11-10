package test_pads_model

import "core:log"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:testing"
import "core:time"

import app "app:core"
import pm "../../apps/pads/model"
import "fire:audiofile"
import fc "fire:core"
import "fire:stream"
import kit "fire:testkit"

SR :: 48_000.0

// A project on the fake driver, rendered offline.
Rig :: struct {
	bus:  app.Bus,
	host: app.Host,
	m:    pm.Model,
	dir:  string,
}

rig_make :: proc(t: ^testing.T, name: string, inputs := 0) -> ^Rig {
	r := new(Rig)
	app.bus_init(&r.bus)
	app.host_init(&r.host, {fake = true, sample_rate = SR, max_block = 256, inputs = inputs}, &r.bus)
	app.host_open(&r.host) // makes the graph at 48 kHz
	app.host_close(&r.host) // render offline from here
	r.dir, _ = filepath.join({kit.artifacts_root(), "pads_model", name})
	os.remove_all(r.dir)
	os.make_directory_all(r.dir)
	testing.expect_value(t, pm.model_init(&r.m, &r.host, r.dir), fc.Error.None)
	return r
}

rig_destroy :: proc(r: ^Rig) {
	pm.model_destroy(&r.m)
	app.host_destroy(&r.host)
	app.bus_destroy(&r.bus)
	delete(r.dir)
	free(r)
}

// A WAV of `seconds` of a sine (decaying if `decay`), written outside the
// project, to import.
tone :: proc(r: ^Rig, name: string, hz, seconds: f64, decay := false) -> string {
	path, _ := filepath.join({r.dir, name}, context.temp_allocator)
	n := int(SR * seconds)
	x := make([]f32, n, context.temp_allocator)
	for &v, i in x {
		env := math.exp(-f64(i) / (SR * 0.2)) if decay else 1
		v = f32(0.5 * env * math.sin(math.TAU * hz * f64(i) / SR))
	}
	s := audiofile.default_writer_settings(SR, 1)
	s.encoding = .Float32
	w, _ := audiofile.writer_create(path, s)
	audiofile.writer_write(w, {x}, n)
	audiofile.writer_close(w)
	return path
}

// Syncs the engine, waits for the pads' samples to be in memory, and
// renders `frames` frames.
render :: proc(r: ^Rig, frames: int) -> [2][]f32 {
	pm.sync(&r.m.engine)
	for _, src in r.m.engine.sources {
		for stream.source_state(src) == .Loading do time.sleep(time.Millisecond)
	}
	out := [2][]f32{make([]f32, frames, context.temp_allocator), make([]f32, frames, context.temp_allocator)}
	app.host_render(&r.host, out[:], frames)
	return out
}

@(test)
a_loaded_pad_plays_and_undo_empties_it :: proc(t: ^testing.T) {
	r := rig_make(t, "load")
	defer rig_destroy(r)
	m := &r.m
	testing.expect_value(t, pm.load_onto_pad(m, 0, tone(r, "a.wav", 440, 0.5)), fc.Error.None)
	testing.expect_value(t, app.store_len(&m.project.samples), 1)
	testing.expect_value(t, pm.pad_name(&m.project.pads[0]), "a")
	testing.expect_value(t, app.undo_name(&m.history), "Load Sample")
	copy_path := pm.pad_sample(m, 0).path
	testing.expect(t, os.exists(copy_path), "the file was copied into the project")

	silent := render(r, 4800)
	testing.expect_value(t, kit.peak(silent[0]), 0) // nothing hit yet
	pm.hit(&m.engine, 0, true)
	out := render(r, 9600)
	testing.expect(t, kit.peak(out[0]) > 0.3, "the pad plays")
	testing.expect(t, kit.peak(out[1]) > 0.3, "in both channels")

	app.undo(&m.history)
	testing.expect_value(t, m.project.pads[0].sample, 0)
	testing.expect_value(t, app.store_len(&m.project.samples), 0)
	render(r, 2400)
	testing.expect(t, !m.engine.nodes[0].live, "its nodes are gone")
	app.redo(&m.history)
	pm.sync(&m.engine)
	testing.expect(t, m.engine.nodes[0].live, "and back")
}

@(test)
pad_settings_reach_the_engine :: proc(t: ^testing.T) {
	r := rig_make(t, "settings")
	defer rig_destroy(r)
	m := &r.m
	pm.load_onto_pad(m, 0, tone(r, "a.wav", 440, 1))
	render(r, 256)
	pm.hit(&m.engine, 0, true)
	loud := render(r, 9600)
	// -12 dB: a quarter of the amplitude once the change has smoothed.
	pad := m.project.pads[0]
	pad.volume = -12
	pm.set_pad(m, 0, .Volume, "Set Volume", pad)
	render(r, 9600)
	quiet := render(r, 9600)
	ratio := kit.peak(quiet[0]) / kit.peak(loud[0][4800:])
	testing.expectf(t, abs(ratio - 0.251) < 0.02, "-12 dB: %v of the level", ratio)

	// Panned hard left: the right channel goes silent (for notes played
	// after the change; the one playing ends first).
	render(r, 48_000)
	pad.pan = -1
	pm.set_pad(m, 0, .Pan, "Set Pan", pad)
	pm.hit(&m.engine, 0, true)
	left := render(r, 9600)
	testing.expect(t, kit.peak(left[0][4800:]) > 0.05, "left plays")
	testing.expectf(t, kit.peak(left[1][4800:]) < 1e-4, "right is silent (%v)", kit.peak(left[1][4800:]))
}

@(test)
choke_groups_cut_each_other :: proc(t: ^testing.T) {
	r := rig_make(t, "choke")
	defer rig_destroy(r)
	m := &r.m
	testing.expect_value(t, pm.load_onto_pad(m, 0, tone(r, "open.wav", 600, 1)), fc.Error.None) // an "open hat", one-shot
	testing.expect_value(t, pm.load_onto_pad(m, 1, tone(r, "closed.wav", 900, 1)), fc.Error.None)
	for i in 0 ..< 2 {
		pad := m.project.pads[i]
		pad.choke = 1
		pm.set_pad(m, i, .Choke, "Set Choke", pad)
	}
	render(r, 256)
	pm.hit(&m.engine, 0, true)
	render(r, 4800)
	pm.hit(&m.engine, 1, true) // cuts pad 0
	out := render(r, 9600)
	// What is left is only the 900 Hz pad.
	tail := out[0][2400:]
	a600 := kit.tone_amplitude(tail, SR, 600)
	a900 := kit.tone_amplitude(tail, SR, 900)
	testing.expectf(t, a600 < 0.01 && a900 > 0.2, "pad 0 choked (600 Hz %v, 900 Hz %v)", a600, a900)
}

@(test)
hold_pads_stop_on_the_second_hit :: proc(t: ^testing.T) {
	r := rig_make(t, "hold")
	defer rig_destroy(r)
	m := &r.m
	pm.load_onto_pad(m, 0, tone(r, "pad.wav", 300, 0.2))
	pad := m.project.pads[0]
	pad.mode = .Hold
	pm.set_pad(m, 0, .Mode, "Set Mode", pad)
	render(r, 256)
	pm.hit(&m.engine, 0, true)
	pm.hit(&m.engine, 0, false) // released: a Hold pad keeps looping
	later := render(r, 48_000)
	testing.expect(t, kit.peak(later[0][40_000:]) > 0.3, "still looping a second later (the sample is 0.2 s)")
	pm.hit(&m.engine, 0, true) // second hit: stops
	stopped := render(r, 9600)
	testing.expectf(t, kit.peak(stopped[0][2400:]) < 1e-3, "stopped (%v)", kit.peak(stopped[0][2400:]))
}

// Decaying hits at `at` (frames), written as a file to import.
drums :: proc(r: ^Rig, name: string, frames: int, at: []int) -> string {
	path, _ := filepath.join({r.dir, name}, context.temp_allocator)
	x := make([]f32, frames, context.temp_allocator)
	noise := make([]f32, frames, context.temp_allocator)
	kit.white_noise(noise, 9, 0.8)
	for a in at do for i in a ..< frames do x[i] += noise[i] * f32(math.exp(-f64(i - a) / 2400))
	s := audiofile.default_writer_settings(SR, 1)
	s.encoding = .Float32
	w, _ := audiofile.writer_create(path, s)
	audiofile.writer_write(w, {x}, frames)
	audiofile.writer_close(w)
	return path
}

@(test)
chopping_fills_pads :: proc(t: ^testing.T) {
	r := rig_make(t, "chop")
	defer rig_destroy(r)
	m := &r.m
	at := []int{0, 12_000, 24_000, 36_000}
	pm.load_onto_pad(m, 0, drums(r, "loop.wav", 48_000, at))
	// Equal parts: 4 pads of 12,000 frames each.
	testing.expect_value(t, pm.chop_to_pads(m, 0, pm.Chop_Equal{4}), 4)
	for i in 0 ..< 4 {
		p := m.project.pads[i]
		testing.expectf(t, p.start == i64(i) * 12_000 && p.end == i64(i + 1) * 12_000, "pad %d plays %d..%d", i, p.start, p.end)
		testing.expect_value(t, p.sample, m.project.pads[0].sample) // the same file
	}
	testing.expect_value(t, app.undo_name(&m.history), "Chop to Pads")
	app.undo(&m.history) // one step
	testing.expect_value(t, m.project.pads[1].sample, 0)
	testing.expect_value(t, m.project.pads[0].end, 0)

	// At the transients: a slice per hit, each starting just before it.
	n := pm.chop_to_pads(m, 0, pm.Chop_Transients{0.5})
	testing.expect_value(t, n, len(at))
	for a, i in at do if i < n {
		start := m.project.pads[i].start
		testing.expectf(t, start <= i64(a) + 64 && start >= i64(a) - 768, "slice %d starts at %d (hit at %d)", i, start, a)
	}
}

@(test)
audio_edits_write_new_samples_and_undo :: proc(t: ^testing.T) {
	r := rig_make(t, "edits")
	defer rig_destroy(r)
	m := &r.m
	pm.load_onto_pad(m, 0, tone(r, "t.wav", 440, 1))
	first := m.project.pads[0].sample
	testing.expect_value(t, pm.edit_audio(m, 0, .Crop, {12_000, 24_000}), fc.Error.None)
	testing.expect(t, m.project.pads[0].sample != first, "a new sample")
	testing.expect_value(t, pm.pad_sample(m, 0).frames, 12_000)
	app.undo(&m.history)
	testing.expect_value(t, m.project.pads[0].sample, first)

	// Normalize: peak 0.5 → 1.
	testing.expect_value(t, pm.edit_audio(m, 0, .Normalize), fc.Error.None)
	a, _ := pm.pad_audio(m, 0)
	testing.expectf(t, abs(kit.peak(a.channels[0]) - 1) < 1e-3, "normalized (%v)", kit.peak(a.channels[0]))
	// Reverse: the audio itself backwards.
	before, _ := pm.pad_audio(m, 0)
	pm.edit_audio(m, 0, .Reverse)
	after, _ := pm.pad_audio(m, 0)
	n := len(before.channels[0])
	testing.expect(t, after.channels[0][0] == before.channels[0][n - 1] && after.channels[0][n - 1] == before.channels[0][0], "reversed")
	// Trim: silence off both ends.
	pad := m.project.pads[0]
	pm.edit_audio(m, 0, .Silence, {0, 10_000})
	pm.edit_audio(m, 0, .Trim)
	testing.expectf(t, abs(pm.pad_sample(m, 0).frames - i64(n - 10_000)) < 50, "trimmed to %d", pm.pad_sample(m, 0).frames)
	_ = pad
}

@(test)
stretching_and_bouncing :: proc(t: ^testing.T) {
	r := rig_make(t, "stretch")
	defer rig_destroy(r)
	m := &r.m
	pm.load_onto_pad(m, 0, tone(r, "t.wav", 440, 1)) // 1 s
	// 4 beats at 120 BPM: 2 s.
	testing.expect_value(t, pm.stretch_to_beats(m, 0, 4), fc.Error.None)
	testing.expect_value(t, pm.pad_sample(m, 0).frames, 96_000)
	a, _ := pm.pad_audio(m, 0)
	testing.expectf(t, abs(kit.tone_amplitude(a.channels[0][24_000:72_000], SR, 440) - 0.5) < 0.1, "the same pitch, the same level")
	// Bounce a region to the next empty pad.
	b := pm.bounce_to_pad(m, 0, {10_000, 20_000})
	testing.expect_value(t, b, 1)
	testing.expect(t, m.project.pads[1].start == 10_000 && m.project.pads[1].end == 20_000, "plays that region")
}

@(test)
recording_puts_a_take_on_a_pad :: proc(t: ^testing.T) {
	r := rig_make(t, "record", inputs = 2)
	defer rig_destroy(r)
	m := &r.m
	rec: pm.Recording
	testing.expect_value(t, pm.record_start(m, &rec, 5), fc.Error.None)
	render(r, 24_000) // half a second (of silence: offline, there is no input)
	pm.record_stop(&rec)
	render(r, 2400)
	for i := 0; i < 100 && !pm.record_poll(m, &rec); i += 1 do render(r, 256)
	testing.expect(t, m.project.pads[5].sample != 0, "the take is on pad 5")
	if s := pm.pad_sample(m, 5); s != nil {
		testing.expectf(t, s.frames >= 20_000, "about half a second (%d frames)", s.frames)
	}
	testing.expect_value(t, app.undo_name(&m.history), "Record")
}

// What the tools cost on a 30-second loop (logged; the bounds
// only catch something gone badly wrong). These run on the UI thread.
@(test)
tool_timings :: proc(t: ^testing.T) {
	r := rig_make(t, "timings")
	defer rig_destroy(r)
	m := &r.m
	hits := make([dynamic]int, context.temp_allocator)
	for k := 0; k < 30 * 48_000 - 12_000; k += 12_000 do append(&hits, k)
	path := drums(r, "long.wav", 30 * 48_000, hits[:])
	ms :: proc(t0: time.Tick) -> f64 { return time.duration_milliseconds(time.tick_since(t0)) }
	t0 := time.tick_now()
	pm.load_onto_pad(m, 0, path)
	load := ms(t0)
	t0 = time.tick_now()
	n := pm.chop_to_pads(m, 0, pm.Chop_Transients{0.5})
	chop := ms(t0)
	t0 = time.tick_now()
	pm.edit_audio(m, 0, .Normalize)
	norm := ms(t0)
	t0 = time.tick_now()
	pm.stretch_to_beats(m, 0, 32)
	stretch := ms(t0)
	log.infof("30 s: import %.1f ms, chop %.1f ms (%d slices), normalize %.1f ms, stretch %.1f ms", load, chop, n, norm, stretch)
	testing.expect(t, n > 0, "slices")
	when ODIN_OPTIMIZATION_MODE != .None { // a debug build is tens of times slower
		testing.expectf(t, chop < 2000 && norm < 2000 && stretch < 10_000, "too slow: chop %.0f, normalize %.0f, stretch %.0f ms", chop, norm, stretch)
	}
}
