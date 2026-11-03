package testkit

import "core:math"

// Deterministic generators. Each writes into `out` (one channel); use
// `buffer_mono_to_all` to copy to the other channels.

silence :: proc(out: []f32) {
	for &s in out do s = 0
}

dc :: proc(out: []f32, value: f32) {
	for &s in out do s = value
}

impulse :: proc(out: []f32, at := 0, amplitude: f32 = 1) {
	silence(out)
	if at >= 0 && at < len(out) do out[at] = amplitude
}

step :: proc(out: []f32, at := 0, amplitude: f32 = 1) {
	for &s, i in out do s = i >= at ? amplitude : 0
}

sine :: proc(out: []f32, sample_rate, freq_hz: f64, amplitude: f64 = 1, phase: f64 = 0) {
	w := math.TAU * freq_hz / sample_rate
	for &s, i in out do s = f32(amplitude * math.sin(w * f64(i) + phase))
}

// Exponential (log) sine sweep, Farina 2000. Good for frequency response and distortion.
log_sweep :: proc(out: []f32, sample_rate, f0_hz, f1_hz: f64, amplitude: f64 = 1) {
	n := len(out)
	if n == 0 do return
	duration := f64(n) / sample_rate
	k := math.ln(f1_hz / f0_hz)
	for &s, i in out {
		t := f64(i) / sample_rate
		phase := math.TAU * f0_hz * duration / k * (math.exp(t / duration * k) - 1)
		s = f32(amplitude * math.sin(phase))
	}
}

// Seedable PRNG (SplitMix64). Same seed => same signal on every platform.
Rng :: struct {
	state: u64,
}

rng_next_u64 :: proc(r: ^Rng) -> u64 {
	r.state += 0x9E3779B97F4A7C15
	z := r.state
	z = (z ~ (z >> 30)) * 0xBF58476D1CE4E5B9
	z = (z ~ (z >> 27)) * 0x94D049BB133111EB
	return z ~ (z >> 31)
}

// Uniform in [0, 1).
rng_next_f64 :: proc(r: ^Rng) -> f64 {
	return f64(rng_next_u64(r) >> 11) * (1.0 / f64(u64(1) << 53))
}

rng_range :: proc(r: ^Rng, lo, hi: int) -> int {
	if hi <= lo do return lo
	return lo + int(rng_next_u64(r) % u64(hi - lo + 1))
}

// Uniform white noise in [-amplitude, amplitude).
white_noise :: proc(out: []f32, seed: u64, amplitude: f64 = 1) {
	r := Rng{seed}
	for &s in out do s = f32(amplitude * (2 * rng_next_f64(&r) - 1))
}

// Pink noise via Paul Kellet's refined filter on white noise. Roughly -3 dB/octave.
pink_noise :: proc(out: []f32, seed: u64, amplitude: f64 = 1) {
	r := Rng{seed}
	b0, b1, b2, b3, b4, b5, b6: f64
	for &s in out {
		w := 2 * rng_next_f64(&r) - 1
		b0 = 0.99886 * b0 + w * 0.0555179
		b1 = 0.99332 * b1 + w * 0.0750759
		b2 = 0.96900 * b2 + w * 0.1538520
		b3 = 0.86650 * b3 + w * 0.3104856
		b4 = 0.55000 * b4 + w * 0.5329522
		b5 = -0.7616 * b5 - w * 0.0168980
		pink := b0 + b1 + b2 + b3 + b4 + b5 + b6 + w * 0.5362
		b6 = w * 0.115926
		s = f32(amplitude * pink * 0.11) // ~unity peak scale
	}
}
