package test_testkit

import "core:math"
import "core:testing"

import kit "fire:testkit"

// Noise decaying by exactly `rt60` seconds to −60 dB.
@(private = "file")
decaying_noise :: proc(rt60: f64, seconds: f64, sr: f64, seed: u64 = 9) -> []f32 {
	n := int(seconds * sr)
	x := make([]f32, n, context.temp_allocator)
	kit.white_noise(x, seed, 1)
	for &v, i in x do v *= f32(math.pow(10, -3 * f64(i) / sr / rt60)) // (−60 dB at rt60: amplitude 10^(−3 t / rt60))
	return x
}

// The decay time of noise decaying at a known rate, broadband and in an
// octave band, within 3 %.
@(test)
decay_time_measures_a_known_decay :: proc(t: ^testing.T) {
	for rt in ([]f64{0.5, 2, 6}) {
		x := decaying_noise(rt, rt * 1.5, 48_000)
		got := kit.decay_time(x, 48_000)
		band := kit.band_decay_time(x, 48_000, 1000)
		testing.expectf(t, abs(got - rt) / rt < 0.03 && abs(band - rt) / rt < 0.05, "RT60 %v s: measured %.3f, at 1 kHz %.3f", rt, got, band)
	}
}

// Echo density: white noise is about 1; a few far-apart clicks are near 0.
// Correlation: a signal with itself is 1, with its negative −1, with other
// noise about 0. Spectral spread: a pure tone is narrow. Early peaks: a
// known pattern of clicks, found where they are.
@(test)
the_reverb_measures_know_simple_signals :: proc(t: ^testing.T) {
	SR :: 48_000.0
	// (Near-Gaussian noise, as a dense reverb's tail is: a sum of uniform draws.)
	noise := make([]f32, 48_000, context.temp_allocator)
	part := make([]f32, 48_000, context.temp_allocator)
	for k in 0 ..< 6 {
		kit.white_noise(part, u64(3 + k), 0.2)
		for v, i in part do noise[i] += v
	}
	d := kit.echo_density(noise, SR, allocator = context.temp_allocator)
	mean := 0.0
	for v in d do mean += v
	mean /= f64(len(d))
	clicks := make([]f32, 48_000, context.temp_allocator)
	for i := 0; i < len(clicks); i += 4800 do clicks[i] = 1
	sparse := kit.echo_density(clicks, SR, allocator = context.temp_allocator)
	most := 0.0
	for v in sparse do most = max(most, v)
	testing.expectf(t, abs(mean - 1) < 0.05 && most < 0.2, "noise %.3f, clicks %.3f", mean, most)
	other := make([]f32, 48_000, context.temp_allocator)
	kit.white_noise(other, 99, 0.5)
	neg := make([]f32, 48_000, context.temp_allocator)
	for v, i in noise do neg[i] = -v
	testing.expect(t, abs(kit.correlation(noise, noise) - 1) < 1e-9 && abs(kit.correlation(noise, neg) + 1) < 1e-9 && abs(kit.correlation(noise, other)) < 0.02, "correlation")
	tone := make([]f32, 32_768, context.temp_allocator)
	for &v, i in tone do v = f32(math.sin(2 * math.PI * 1000 * f64(i) / SR))
	spread := kit.spectral_spread(tone, SR, 1000)
	testing.expectf(t, spread < 20, "a pure tone's spread: %.1f Hz", spread)
	early := make([]f32, 4800, context.temp_allocator)
	at := []f64{3, 7.5, 12, 21}
	for ms, k in at do early[int(ms * 48)] = f32(1 - 0.2 * f64(k))
	p := kit.early_peaks(early, SR, 50, 4, context.temp_allocator)
	ok := len(p) == 4
	if ok do for r, k in p do if abs(r.ms - at[k]) > 0.05 do ok = false
	testing.expectf(t, ok, "the clicks found where they are: %v", p)
}
