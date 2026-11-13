package test_warp

import "core:log"
import "core:math"
import "core:testing"
import "core:time"

import "fire:dsp"
import "fire:stretch"
import kit "fire:testkit"

SR :: 48_000.0

// Two seconds of the synthetic drums (kick, snare, hats at 120 BPM).
drums :: proc(seconds := 2.0, channels := 1) -> [][]f32 {
	return kit.stretch_case_input({signal = .Drums, sample_rate = SR, channels = i32(channels), in_frames = i32(seconds * SR)}, context.temp_allocator)
}

sine :: proc(hz: f64, seconds := 2.0) -> [][]f32 {
	x := make([]f32, int(seconds * SR), context.temp_allocator)
	kit.sine(x, SR, hz, 0.5)
	out := make([][]f32, 1, context.temp_allocator)
	out[0] = x
	return out
}

hits :: proc(x: []f32) -> []i64 {
	o, _ := dsp.detect_onsets(x, SR, {}, context.temp_allocator)
	return o
}

// Each hit of `want` (in frames) has one in `got` within `tol` frames; the
// worst miss.
worst_miss :: proc(want, got: []i64) -> (worst: i64) {
	for w in want {
		best := i64(max(i64))
		for g in got do best = min(best, abs(g - w))
		worst = max(worst, best)
	}
	return
}

// At ratio 1, Beats gives back its input exactly.
@(test)
beats_at_ratio_1_is_the_input :: proc(t: ^testing.T) {
	x := drums()
	y, err := stretch.warp(x, SR, 1, {mode = .Beats})
	defer stretch.warp_destroy(y)
	testing.expect_value(t, err, nil)
	same := len(y[0]) == len(x[0])
	if same do for v, i in x[0] do if y[0][i] != v {
		same = false
		break
	}
	testing.expect(t, same, "sample for sample")
}

// Beats: every hit lands where the tempo puts it (within a millisecond),
// longer and shorter; the length is exact.
@(test)
beats_puts_every_hit_on_time :: proc(t: ^testing.T) {
	x := drums()
	in_hits := hits(x[0])
	for ratio in ([]f64{1.25, 0.8, 1.5}) {
		y, _ := stretch.warp(x, SR, ratio, {mode = .Beats})
		defer stretch.warp_destroy(y)
		testing.expect_value(t, len(y[0]), int(math.round(f64(len(x[0])) * ratio)))
		want := make([]i64, len(in_hits), context.temp_allocator)
		for h, i in in_hits do want[i] = i64(math.round(f64(h) * ratio))
		miss := worst_miss(want, hits(y[0]))
		testing.expectf(t, miss <= 48, "×%v: every hit on time (worst %d frames)", ratio, miss)
	}
}

// Beats, longer, with gaps filled: the gaps after short pieces have sound
// (the tail looped); without, they fade to silence. No clicks either way.
@(test)
beats_fills_gaps_on_request :: proc(t: ^testing.T) {
	x := drums()
	plain, _ := stretch.warp(x, SR, 1.6, {mode = .Beats, grain = .Eighth, beat_frames = SR * 0.5})
	defer stretch.warp_destroy(plain)
	filled, _ := stretch.warp(x, SR, 1.6, {mode = .Beats, grain = .Eighth, beat_frames = SR * 0.5, fill_gaps = true})
	defer stretch.warp_destroy(filled)
	// The end of an eighth's room (0.4 s of it), past its own 0.25 s.
	lo, hi := int(0.32 * SR), int(0.39 * SR)
	q, f := kit.rms(plain[0][lo:hi]), kit.rms(filled[0][lo:hi])
	testing.expectf(t, f > 4 * q + 1e-4, "filled has sound where plain is silent (%v vs %v)", f, q)
	step_in, _ := kit.max_step(x[0])
	for y in ([][][]f32{plain, filled}) {
		s, _ := kit.max_step(y[0])
		testing.expectf(t, s <= step_in * 1.05, "no clicks beyond the drums' own (%v vs %v)", s, step_in)
	}
}

// Tones: the pitch stays, the level holds, the length is exact.
@(test)
tones_keeps_the_pitch :: proc(t: ^testing.T) {
	x := sine(440)
	for ratio in ([]f64{1.3, 0.7}) {
		y, _ := stretch.warp(x, SR, ratio, {mode = .Tones})
		defer stretch.warp_destroy(y)
		n := len(y[0])
		testing.expect_value(t, n, int(math.round(f64(len(x[0])) * ratio)))
		mid := y[0][n / 4:3 * n / 4]
		sp := kit.spectrum(mid, SR, allocator = context.temp_allocator)
		_, hz, _ := kit.spectrum_peak(sp)
		testing.expectf(t, abs(hz - 440) < 3, "×%v: still 440 Hz (%v)", ratio, hz)
		amp := kit.tone_amplitude(mid, SR, 440)
		testing.expectf(t, abs(20 * math.log10(amp / 0.5)) < 1, "×%v: the level held (%v)", ratio, amp)
	}
}

// Transposed: Tones and Complex move the pitch (an octave up: 880 Hz;
// seven semitones down: 293.66 Hz), the length exact, at any ratio.
@(test)
tones_and_complex_transpose_keeping_the_timing :: proc(t: ^testing.T) {
	x := sine(440)
	for mode in ([]stretch.Warp_Mode{.Tones, .Complex}) do for c in ([]struct{ratio, semis, hz: f64}{{1.3, 12, 880}, {0.8, -7, 293.66}, {1, 12, 880}}) {
		y, _ := stretch.warp(x, SR, c.ratio, {mode = mode, transpose = c.semis})
		defer stretch.warp_destroy(y)
		n := len(y[0])
		testing.expect_value(t, n, int(math.round(f64(len(x[0])) * c.ratio)))
		sp := kit.spectrum(y[0][n / 4:3 * n / 4], SR, allocator = context.temp_allocator)
		_, hz, _ := kit.spectrum_peak(sp)
		testing.expectf(t, abs(hz - c.hz) < c.hz * 0.01, "%v ×%v %+v st: %v Hz (%v)", mode, c.ratio, c.semis, c.hz, hz)
	}
}

// Beats, transposed: every hit still on time (each piece re-pitched where
// it falls), the length exact, the pitch moved (a sine piece up an octave).
@(test)
beats_transposes_each_piece_on_time :: proc(t: ^testing.T) {
	x := drums()
	in_hits := hits(x[0])
	for c in ([]struct{ratio, semis: f64}{{1.25, 5}, {0.8, -5}, {1, 12}}) {
		y, _ := stretch.warp(x, SR, c.ratio, {mode = .Beats, transpose = c.semis})
		defer stretch.warp_destroy(y)
		testing.expect_value(t, len(y[0]), int(math.round(f64(len(x[0])) * c.ratio)))
		want := make([]i64, len(in_hits), context.temp_allocator)
		for h, i in in_hits do want[i] = i64(math.round(f64(h) * c.ratio))
		// (Each piece starts on its exact frame; a re-pitched attack has
		// another shape, so the onset detector reads it a little off: 1.5 ms.)
		miss := worst_miss(want, hits(y[0]))
		testing.expectf(t, miss <= 72, "×%v %+v st: every hit on time (worst %d frames)", c.ratio, c.semis, miss)
	}
	// One piece of sine (a grid of a whole second): an octave up.
	y, _ := stretch.warp(sine(440), SR, 1, {mode = .Beats, grain = .Quarter, beat_frames = SR, transpose = 12})
	defer stretch.warp_destroy(y)
	sp := kit.spectrum(y[0][int(0.1 * SR):int(0.4 * SR)], SR, allocator = context.temp_allocator)
	_, hz, _ := kit.spectrum_peak(sp)
	testing.expectf(t, abs(hz - 880) < 9, "880 Hz (%v)", hz)
}

// Re-pitch: twice as long is an octave down.
@(test)
repitch_moves_the_pitch :: proc(t: ^testing.T) {
	y, _ := stretch.warp(sine(440), SR, 2, {mode = .Repitch})
	defer stretch.warp_destroy(y)
	n := len(y[0])
	sp := kit.spectrum(y[0][n / 4:3 * n / 4], SR, allocator = context.temp_allocator)
	_, hz, _ := kit.spectrum_peak(sp)
	testing.expectf(t, abs(hz - 220) < 2, "220 Hz (%v)", hz)
}

// Complex keeps the hits on time (within 3 ms) and sharper than one
// continuous stretch (Tones) does: its attacks rise as fast as the input's.
@(test)
complex_keeps_hits_crisp_and_on_time :: proc(t: ^testing.T) {
	x := drums()
	ratio := 1.25
	in_hits := hits(x[0])
	want := make([]i64, len(in_hits), context.temp_allocator)
	for h, i in in_hits do want[i] = i64(math.round(f64(h) * ratio))
	cx, _ := stretch.warp(x, SR, ratio, {mode = .Complex})
	defer stretch.warp_destroy(cx)
	tn, _ := stretch.warp(x, SR, ratio, {mode = .Tones})
	defer stretch.warp_destroy(tn)
	miss := worst_miss(want, hits(cx[0]))
	testing.expectf(t, miss <= 144, "on time (worst %d frames)", miss)
	// Attack: the loudest of the 4 ms after each hit against the 4 ms before.
	attack :: proc(y: []f32, at: []i64) -> f64 {
		w := int(SR * 0.004)
		sum := 0.0
		for a in at {
			i := int(a)
			if i - w < 0 || i + w >= len(y) do continue
			sum += kit.peak(y[i:i + w]) / max(kit.peak(y[i - w:i]), 1e-4)
		}
		return sum / f64(len(at))
	}
	ac, at := attack(cx[0], want), attack(tn[0], want)
	log.infof("attack (peak after / before a hit): complex %.1f, tones %.1f, input %.1f", ac, at, attack(x[0], in_hits))
	testing.expectf(t, ac > at, "complex's attacks sharper than tones' (%v vs %v)", ac, at)
}

// How long each mode takes on 8 s of stereo drums (×1.25): offline, but
// it should be quick (optimized: under 4 s; it takes well under one).
@(test)
warp_speed :: proc(t: ^testing.T) {
	x := drums(8, 2)
	for mode in stretch.Warp_Mode {
		t0 := time.tick_now()
		y, _ := stretch.warp(x, SR, 1.25, {mode = mode})
		ms := time.duration_milliseconds(time.tick_since(t0))
		stretch.warp_destroy(y)
		log.infof("warp %v: 8 s stereo in %.1f ms", mode, ms)
		// (Timed only when optimized: a debug build is many times slower.)
		when ODIN_OPTIMIZATION_MODE != .None do testing.expectf(t, ms < 4000, "%v under 4 s (%.0f ms)", mode, ms)
	}
}
