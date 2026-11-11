package test_synth

import "core:math"
import "core:testing"

import "fire:dsp"
import "fire:synth"

// The level of harmonic `h` in a wave buffer's cycle (as `wave_build`
// lays it out), by correlation.
harmonic :: proc(buf: []f32, h: int) -> f64 {
	s, c: f64
	for i in 0 ..< synth.WAVE_SIZE {
		p := math.TAU * f64(h) * f64(i) / synth.WAVE_SIZE
		s += f64(buf[i + 1]) * math.sin(p)
		c += f64(buf[i + 1]) * math.cos(p)
	}
	return math.sqrt(s * s + c * c) * 2 / synth.WAVE_SIZE
}

// A frame kept whole comes back as it went in; band-limited, the
// harmonics above the limit are gone and those below untouched.
@(test)
a_wave_buffer_keeps_the_harmonics_asked_for :: proc(t: ^testing.T) {
	tab, err := synth.builtin_table(.Saw)
	testing.expect_value(t, err, nil)
	defer synth.wavetable_destroy(tab)
	fft: dsp.Real_Fft
	dsp.real_fft_init(&fft, synth.WAVE_SIZE)
	defer dsp.real_fft_destroy(&fft)
	spec := make([]complex64, synth.WAVE_BINS)
	defer delete(spec)
	buf := make([]f32, synth.WAVE_SIZE + synth.WAVE_PAD)
	defer delete(buf)

	synth.wave_build(&fft, tab, 0, synth.WAVE_BINS - 1, spec, buf)
	worst: f32 = 0
	for i in 0 ..< synth.WAVE_SIZE do worst = max(worst, abs(buf[i + 1] - tab.waves[0][i]))
	testing.expectf(t, worst < 0.02, "whole, it is the frame again (off by %v; Nyquist only is dropped)", worst)
	testing.expect(t, buf[0] == buf[synth.WAVE_SIZE] && buf[synth.WAVE_SIZE + 1] == buf[1], "its ends wrap")

	synth.wave_build(&fft, tab, 0, 10, spec, buf)
	h1, h10, h11, h40 := harmonic(buf, 1), harmonic(buf, 10), harmonic(buf, 11), harmonic(buf, 40)
	testing.expectf(t, abs(h10 / h1 - 0.1) < 0.005, "harmonic 10 at 1/10 of the first (%v)", h10 / h1)
	testing.expectf(t, h11 < 1e-4 && h40 < 1e-4, "nothing above 10 (%v, %v)", h11, h40)
}

// How many harmonics a pitch keeps: none reach Nyquist; above 88.2 kHz no
// more than at 44.1 kHz.
@(test)
harmonics_stop_short_of_nyquist :: proc(t: ^testing.T) {
	for hz in ([]f64{27.5, 110, 440, 1760, 7040, 20_000}) {
		for sr in ([]f64{44_100, 48_000, 96_000}) {
			n := synth.wave_harmonics(hz / sr, sr)
			testing.expectf(t, f64(n) * hz < 0.5 * sr || n == 0, "%v Hz at %v: %d harmonics reach Nyquist", hz, sr, n)
			testing.expectf(t, f64(n + 1) * hz >= 0.5 * min(sr, 48_000) - hz || n == synth.WAVE_BINS - 1, "%v Hz at %v: %d keeps too few", hz, sr, n)
		}
	}
	testing.expect_value(t, synth.wave_harmonics(440.0 / 96_000, 96_000), synth.wave_harmonics(440.0 / 48_000, 48_000))
}

// Keyframes spread over the table: the first and last frames are the
// keyframes, the middle a crossfade; positions pick frames in order.
@(test)
keyframes_are_spread_and_crossfaded :: proc(t: ^testing.T) {
	a := make([]f32, synth.WAVE_SIZE)
	b := make([]f32, synth.WAVE_SIZE)
	defer delete(a)
	defer delete(b)
	for i in 0 ..< synth.WAVE_SIZE {
		a[i] = f32(math.sin(math.TAU * f64(i) / synth.WAVE_SIZE))
		b[i] = f32(math.sin(math.TAU * 3 * f64(i) / synth.WAVE_SIZE))
	}
	tab, _ := synth.wavetable_make("ab", {a, b})
	defer synth.wavetable_destroy(tab)
	testing.expect_value(t, tab.frames, synth.WAVE_FRAMES)
	testing.expect_value(t, tab.waves[0][100], a[100])
	testing.expect_value(t, tab.waves[synth.WAVE_FRAMES - 1][100], b[100])
	mid := tab.waves[synth.WAVE_FRAMES / 2][:]
	testing.expectf(t, abs(mid[300] - (a[300] + b[300]) / 2) < 0.01, "the middle is half of each (%v)", mid[300])
	testing.expect_value(t, synth.wave_frame_at(tab, 0), 0)
	testing.expect_value(t, synth.wave_frame_at(tab, 1), synth.WAVE_FRAMES - 1)
	testing.expect(t, synth.wave_frame_at(tab, 0.3) < synth.wave_frame_at(tab, 0.6), "positions in order")
}

// Every built-in table: finite, peak near 1, no DC.
@(test)
the_builtin_tables_are_sound :: proc(t: ^testing.T) {
	for which in synth.Builtin_Table {
		tab, err := synth.builtin_table(which)
		testing.expectf(t, err == nil && tab != nil, "%v made", which)
		if tab == nil do continue
		peak: f32 = 0
		for f in 0 ..< tab.frames {
			mean: f64 = 0
			for v in tab.waves[f] {
				testing.expectf(t, !math.is_nan(v) && !math.is_inf(v), "%v finite", which)
				peak = max(peak, abs(v))
				mean += f64(v)
			}
			mean /= synth.WAVE_SIZE
			if abs(mean) > 1e-3 do testing.expectf(t, false, "%v frame %d has DC %v", which, f, mean)
		}
		testing.expectf(t, peak > 0.8 && peak <= 1.01, "%v peaks near 1 (%v)", which, peak)
		synth.wavetable_destroy(tab)
	}
}
