package test_pads_model

import "core:math"
import "core:os"
import "core:path/filepath"
import "core:testing"
import "core:time"

import "fire:audiofile"
import "fire:stretch"
import pm "../../apps/pads/model"

// A click every beat at `bpm` for `beats` beats (mono, 48 kHz).
clicks :: proc(r: ^Rig, name: string, bpm: f64, beats: int) -> string {
	path, _ := filepath.join({r.dir, name}, context.temp_allocator)
	beat := int(math.round(SR * 60 / bpm))
	n := beat * beats
	x := make([]f32, n, context.temp_allocator)
	for b in 0 ..< beats do for i in 0 ..< 480 do x[b * beat + i] = f32(0.8 * math.exp(-f64(i) / 60) * math.sin(math.TAU * 2000 * f64(i) / SR))
	s := audiofile.default_writer_settings(SR, 1)
	s.encoding = .Float32
	w, _ := audiofile.writer_create(path, s)
	audiofile.writer_write(w, {x}, n)
	audiofile.writer_close(w)
	return path
}

// Waits (a few seconds at most) for pad `i`'s warp to be rendered and in
// its zone.
warp_ready :: proc(r: ^Rig, i: int) -> bool {
	for _ in 0 ..< 400 {
		pm.sync(&r.m.engine)
		if !pm.warp_rendering(&r.m.engine, i) do return true
		time.sleep(10 * time.Millisecond)
	}
	return false
}

// A loop at 100 BPM, warped (Beats), plays at the project's 120: its hits
// half a second apart; its tempo guessed from its length; off, it plays
// as it is; the rendering kept in the project's `warped` folder.
@(test)
a_warped_pad_follows_the_tempo :: proc(t: ^testing.T) {
	r := rig_make(t, "warp_pad")
	defer rig_destroy(r)
	m := &r.m
	pm.load_onto_pad(m, 0, clicks(r, "loop100.wav", 100, 4))
	render(r, 256)
	pm.set_warp(m, 0, {on = true, mode = .Beats})
	testing.expectf(t, abs(m.project.pads[0].warp.bpm - 100) < 0.01, "its tempo guessed from its length: %v", m.project.pads[0].warp.bpm)
	testing.expect(t, warp_ready(r, 0), "rendered")
	pm.hit(&m.engine, 0, true)
	out := render(r, int(SR * 2.1))
	got := onsets(out[0][:])
	testing.expectf(t, len(got) == 4, "four hits (%v)", got)
	if len(got) == 4 do for k in 1 ..< 4 {
		d := got[k] - got[k - 1]
		testing.expectf(t, abs(d - 24_000) <= 48, "half a second apart at 120 (%d)", d)
	}
	entries, _ := os.read_all_directory_by_path(pm.project_folder(m.project.dir, .Warp), context.temp_allocator)
	testing.expect(t, len(entries) == 1, "the rendering kept in the project")
	// Off: as it is (0.6 s apart).
	w := m.project.pads[0].warp
	w.on = false
	pm.set_warp(m, 0, w)
	render(r, 4800)
	pm.hit(&m.engine, 0, true)
	out = render(r, int(SR * 2))
	got = onsets(out[0][:])
	testing.expectf(t, len(got) >= 2 && abs(got[1] - got[0] - 28_800) <= 48, "warp off: 0.6 s apart (%v)", got)
	_ = stretch.Warp_Mode.Beats
}

// Transpose on a warped pad (Tones): an octave up, its length kept (the
// rendering has the pitch in it; the sampler plays it as it is). Re-pitch:
// the sampler's transpose, faster (half as long).
@(test)
transpose_keeps_a_warped_pads_timing :: proc(t: ^testing.T) {
	r := rig_make(t, "warp_transpose")
	defer rig_destroy(r)
	m := &r.m
	pm.load_onto_pad(m, 0, tone(r, "tone.wav", 440, 0.5))
	render(r, 256)
	p := m.project.pads[0]
	p.pitch = 12
	pm.set_pad(m, 0, .Pitch, "Transpose", p)
	pm.set_warp(m, 0, {on = true, mode = .Tones, bpm = 120}) // (the project's tempo: only the transpose renders)
	if !testing.expect(t, warp_ready(r, 0), "rendered") do return
	played :: proc(r: ^Rig) -> (hz: f64, seconds: f64) {
		render(r, 4800)
		pm.hit(&r.m.engine, 0, true)
		out := render(r, 48_000)
		pm.hit(&r.m.engine, 0, false)
		render(r, 4800)
		x := out[0]
		last := 0
		for v, i in x do if abs(v) > 0.01 do last = i
		return hz_of(x[2400:12_000]), f64(last) / SR
	}
	hz, secs := played(r)
	testing.expectf(t, abs(hz - 880) < 20, "an octave up (%v Hz)", hz)
	testing.expectf(t, abs(secs - 0.5) < 0.03, "as long as the sample (%v s)", secs)
	// Re-pitch: faster, so half as long.
	pm.set_warp(m, 0, {on = true, mode = .Repitch, bpm = 120})
	warp_ready(r, 0)
	hz, secs = played(r)
	testing.expectf(t, abs(hz - 880) < 20, "re-pitch: an octave up (%v Hz)", hz)
	testing.expectf(t, abs(secs - 0.25) < 0.03, "re-pitch: half as long (%v s)", secs)
}
