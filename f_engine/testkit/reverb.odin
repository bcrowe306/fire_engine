package testkit

import "core:math"
import "core:slice"

// Measures of a reverb's output, the same for any reverb (ours or a
// reference measured at its output): how long it lasts in a band, how
// dense it becomes, how wide it is, how much it smears a pure tone, where
// its first reflections fall.

// The energy decay curve of `x` (Schroeder's backward integration), in dB
// against its total energy (0 dB at the start, falling). Allocates.
energy_decay_db :: proc(x: []f32, allocator := context.allocator) -> []f64 {
	out := make([]f64, len(x), allocator)
	sum := 0.0
	for i := len(x) - 1; i >= 0; i -= 1 {
		sum += f64(x[i]) * f64(x[i])
		out[i] = sum
	}
	total := max(out[0] if len(out) > 0 else 0, 1e-30)
	for &e in out do e = 10 * math.log10(max(e / total, 1e-30))
	return out
}

// The time `x` takes to fall 60 dB (seconds), from the straight line
// through its energy decay curve between `from_db` and `to_db` (−5 to −35:
// a T30); 0 if it never reaches `to_db`.
decay_time :: proc(x: []f32, sample_rate: f64, from_db := -5.0, to_db := -35.0) -> f64 {
	edc := energy_decay_db(x, context.temp_allocator)
	// Least squares over the frames between the two levels.
	n, sx, sy, sxx, sxy: f64
	reached := false
	for e, i in edc {
		if e > from_db do continue
		if e < to_db {
			reached = true
			break
		}
		t := f64(i) / sample_rate
		n += 1
		sx += t
		sy += e
		sxx += t * t
		sxy += t * e
	}
	if !reached || n < 2 do return 0
	slope := (n * sxy - sx * sy) / (n * sxx - sx * sx) // dB a second
	return -60 / slope if slope < 0 else 0
}

// `x` through an octave band-pass at `center_hz` (two second-order
// band-passes in a row). Allocates.
octave_band :: proc(x: []f32, sample_rate, center_hz: f64, allocator := context.allocator) -> []f32 {
	out := slice.clone(x, allocator)
	w := 2 * math.PI * center_hz / sample_rate
	q := math.SQRT_TWO // (an octave wide)
	alpha := math.sin(w) / (2 * q)
	a0 := 1 + alpha
	b0, b2 := alpha / a0, -alpha / a0
	a1, a2 := -2 * math.cos(w) / a0, (1 - alpha) / a0
	for _ in 0 ..< 2 {
		z1, z2: f64
		for &v in out {
			x := f64(v)
			y := b0 * x + z1
			z1 = -a1 * y + z2
			z2 = b2 * x - a2 * y
			v = f32(y)
		}
	}
	return out
}

// `x`'s decay time in the octave band at `center_hz` (as `decay_time`).
band_decay_time :: proc(x: []f32, sample_rate, center_hz: f64) -> f64 {
	return decay_time(octave_band(x, sample_rate, center_hz, context.temp_allocator), sample_rate)
}

// `x`'s normalised echo density over time (Abel and Huang): in each
// window of `window_ms`, every `step_ms`, the share of frames further from
// zero than the window's standard deviation, over a Gaussian's share
// (0.3173). About 1 once the reverb is smooth noise; near 0 while it is
// a few separate echoes. Allocates.
echo_density :: proc(x: []f32, sample_rate: f64, window_ms := 20.0, step_ms := 5.0, allocator := context.allocator) -> []f64 {
	w := max(int(window_ms * sample_rate / 1000), 8)
	step := max(int(step_ms * sample_rate / 1000), 1)
	out := make([dynamic]f64, allocator)
	for at := 0; at + w <= len(x); at += step {
		s2 := 0.0
		for v in x[at:at + w] do s2 += f64(v) * f64(v)
		sd := math.sqrt(s2 / f64(w))
		if sd == 0 {
			append(&out, 0)
			continue
		}
		over := 0
		for v in x[at:at + w] do if abs(f64(v)) > sd do over += 1
		append(&out, f64(over) / f64(w) / 0.3173105)
	}
	return out[:]
}

// The correlation of `a` and `b` (−1..1; 0 when either is silent).
correlation :: proc(a, b: []f32) -> f64 {
	n := min(len(a), len(b))
	sab, saa, sbb: f64
	for i in 0 ..< n {
		sab += f64(a[i]) * f64(b[i])
		saa += f64(a[i]) * f64(a[i])
		sbb += f64(b[i]) * f64(b[i])
	}
	if saa == 0 || sbb == 0 do return 0
	return sab / math.sqrt(saa * sbb)
}

// How far `x`'s spectrum spreads about `hz` (Hz): the width of the band
// around its peak near `hz` within 20 dB of it. A pure tone through a
// reverb that modulates comes out wider.
spectral_spread :: proc(x: []f32, sample_rate, hz: f64) -> f64 {
	s := spectrum(x, sample_rate, allocator = context.temp_allocator)
	if len(s.magnitude) < 4 do return 0
	k := clamp(int(hz / spectrum_bin_hz(s, 1)), 1, len(s.magnitude) - 2)
	for j in max(k - 4, 1) ..= min(k + 4, len(s.magnitude) - 2) do if s.magnitude[j] > s.magnitude[k] do k = j
	floor := s.magnitude[k] * 0.1
	lo, hi := k, k
	for lo > 1 && s.magnitude[lo - 1] >= floor do lo -= 1
	for hi < len(s.magnitude) - 2 && s.magnitude[hi + 1] >= floor do hi += 1
	return spectrum_bin_hz(s, hi) - spectrum_bin_hz(s, lo) + spectrum_bin_hz(s, 1)
}

// One reflection: when (ms from the start) and how loud (linear).
Reflection :: struct {
	ms:    f64,
	level: f64,
}

// The `count` loudest peaks of `x` in its first `ms` milliseconds (at
// least half a millisecond apart), in time order. Allocates.
early_peaks :: proc(x: []f32, sample_rate, ms: f64, count: int, allocator := context.allocator) -> []Reflection {
	n := min(len(x), int(ms * sample_rate / 1000))
	gap := max(int(0.0005 * sample_rate), 1)
	peaks := make([dynamic]Reflection, context.temp_allocator)
	for i in 1 ..< n - 1 {
		a := abs(f64(x[i]))
		if a > abs(f64(x[i - 1])) && a >= abs(f64(x[i + 1])) && a > 1e-5 do append(&peaks, Reflection{f64(i) * 1000 / sample_rate, a})
	}
	slice.sort_by(peaks[:], proc(a, b: Reflection) -> bool { return a.level > b.level })
	out := make([dynamic]Reflection, allocator)
	for p in peaks {
		if len(out) >= count do break
		near := false
		for q in out do if abs(q.ms - p.ms) * sample_rate / 1000 < f64(gap) do near = true
		if !near do append(&out, p)
	}
	slice.sort_by(out[:], proc(a, b: Reflection) -> bool { return a.ms < b.ms })
	return out[:]
}
