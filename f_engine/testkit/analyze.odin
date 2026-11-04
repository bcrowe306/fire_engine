package testkit

import "core:math"

// --- levels ------------------------------------------------------------------

// Converts a linear amplitude to dB (20·log10|x|). Zero maps to about -600 dB instead of -Inf.
linear_to_db :: proc(x: f64) -> f64 {
	return 20 * math.log10(max(abs(x), 1e-30))
}

// Converts dB to a linear amplitude factor (10^(db/20)).
db_to_linear :: proc(db: f64) -> f64 {
	return math.pow(10, db / 20)
}

// Largest absolute sample value (linear). 0 for an empty slice.
peak :: proc(x: []f32) -> f64 {
	p: f64
	for v in x do p = max(p, abs(f64(v)))
	return p
}

// Root-mean-square level (linear). 0 for an empty slice.
rms :: proc(x: []f32) -> f64 {
	if len(x) == 0 do return 0
	sum: f64
	for v in x do sum += f64(v) * f64(v)
	return math.sqrt(sum / f64(len(x)))
}

// Mean sample value (linear). 0 for an empty slice.
dc_offset :: proc(x: []f32) -> f64 {
	if len(x) == 0 do return 0
	sum: f64
	for v in x do sum += f64(v)
	return sum / f64(len(x))
}

// --- sanity ------------------------------------------------------------------

// Counts NaN and Inf samples. `first_index` is the index of the first one, or -1 if none.
count_non_finite :: proc(x: []f32) -> (count: int, first_index: int) {
	first_index = -1
	for v, i in x {
		if math.is_nan(v) || math.is_inf(v) {
			if first_index < 0 do first_index = i
			count += 1
		}
	}
	return
}

// Counts subnormal (denormal) f32 samples. Denormals are slow on most CPUs and
// usually mean a decaying state variable was not flushed to zero.
count_denormals :: proc(x: []f32) -> int {
	n := 0
	for v in x {
		bits := transmute(u32)v
		if bits & 0x7F80_0000 == 0 && bits & 0x007F_FFFF != 0 do n += 1
	}
	return n
}

// Largest |x[n] - x[n-1]|. A hard parameter jump or a discontinuity shows up here.
max_step :: proc(x: []f32) -> (value: f64, index: int) {
	for i in 1 ..< len(x) {
		d := abs(f64(x[i]) - f64(x[i - 1]))
		if d > value do value, index = d, i
	}
	return
}

// Largest |x[n] - 2x[n-1] + x[n-2]|. A smooth signal of frequency f and amplitude A
// stays under A*(2π f/fs)^2; clicks and zipper noise spike far above that.
max_curvature :: proc(x: []f32) -> (value: f64, index: int) {
	for i in 2 ..< len(x) {
		d := abs(f64(x[i]) - 2 * f64(x[i - 1]) + f64(x[i - 2]))
		if d > value do value, index = d, i
	}
	return
}

// Bound on max_curvature for a clean sine; use as a click threshold with a margin.
sine_curvature_bound :: proc(amplitude, freq_hz, sample_rate: f64) -> f64 {
	w := math.TAU * freq_hz / sample_rate
	return amplitude * w * w
}

// --- frequency domain -------------------------------------------------------

// Amplitude of the component at `freq_hz` using a Hann-windowed single-bin DFT.
// A sine of amplitude A reads ~A when the signal spans many cycles.
tone_amplitude :: proc(x: []f32, sample_rate, freq_hz: f64) -> f64 {
	n := len(x)
	w := math.TAU * freq_hz / sample_rate
	re, im, wsum: f64
	for v, i in x {
		h := window_value(.Hann, i, n)
		wsum += h
		re += f64(v) * h * math.cos(w * f64(i))
		im -= f64(v) * h * math.sin(w * f64(i))
	}
	return 2 * math.sqrt(re * re + im * im) / max(wsum, 1e-30)
}

// Complex DFT of a (fully decayed) impulse response at one frequency.
response_at :: proc(ir: []f32, sample_rate, freq_hz: f64) -> complex128 {
	w := math.TAU * freq_hz / sample_rate
	re, im: f64
	for v, i in ir {
		re += f64(v) * math.cos(w * f64(i))
		im -= f64(v) * math.sin(w * f64(i))
	}
	return complex(re, im)
}

// Magnitude response in dB of an impulse response at `freq_hz`.
response_db :: proc(ir: []f32, sample_rate, freq_hz: f64) -> f64 {
	r := response_at(ir, sample_rate, freq_hz)
	return linear_to_db(math.sqrt(real(r) * real(r) + imag(r) * imag(r)))
}

// Phase response in radians of an impulse response at `freq_hz`.
response_phase :: proc(ir: []f32, sample_rate, freq_hz: f64) -> f64 {
	r := response_at(ir, sample_rate, freq_hz)
	return math.atan2(imag(r), real(r))
}

// THD+N in dB: residual after a least-squares fit of DC + sine at `fundamental_hz`,
// relative to the fitted sine's RMS. A clean sine gives a very negative number.
thd_n_db :: proc(x: []f32, sample_rate, fundamental_hz: f64) -> f64 {
	n := len(x)
	if n < 4 do return 0
	w := math.TAU * fundamental_hz / sample_rate
	// Normal equations for y ≈ a*sin + b*cos + c
	ss, sc, s1, cc, c1, ys, yc, y1: f64
	for v, i in x {
		s := math.sin(w * f64(i))
		c := math.cos(w * f64(i))
		y := f64(v)
		ss += s * s; sc += s * c; s1 += s
		cc += c * c; c1 += c
		ys += y * s; yc += y * c; y1 += y
	}
	m := [3][3]f64{{ss, sc, s1}, {sc, cc, c1}, {s1, c1, f64(n)}}
	r := [3]f64{ys, yc, y1}
	sol, ok := solve3(m, r)
	if !ok do return 0
	a, b, c := sol[0], sol[1], sol[2]
	resid: f64
	for v, i in x {
		fit := a * math.sin(w * f64(i)) + b * math.cos(w * f64(i)) + c
		d := f64(v) - fit
		resid += d * d
	}
	resid_rms := math.sqrt(resid / f64(n))
	sine_rms := math.sqrt((a * a + b * b) / 2)
	return linear_to_db(resid_rms / max(sine_rms, 1e-30))
}

// --- time domain -------------------------------------------------------------

// Delay of `output` relative to `reference`, in frames, by brute-force cross-correlation
// over lags 0..max_lag. Returns the lag with the largest |correlation|.
estimate_latency :: proc(reference, output: []f32, max_lag: int) -> int {
	best_lag := 0
	best: f64 = -1
	for lag in 0 ..= max_lag {
		sum: f64
		for i in 0 ..< len(reference) {
			j := i + lag
			if j >= len(output) do break
			sum += f64(reference[i]) * f64(output[j])
		}
		if abs(sum) > best do best, best_lag = abs(sum), lag
	}
	return best_lag
}

// Outcome of `compare_slices` / `compare_buffers`. Errors are absolute (linear)
// sample differences, `actual - expected`.
Compare_Result :: struct {
	max_abs_error:  f64,  // largest |actual - expected|
	max_error_at:   int,  // frame index of max_abs_error
	max_error_ch:   int,  // channel of max_abs_error (compare_buffers only)
	rms_error:      f64,  // RMS of the difference
	error_db:       f64,  // rms_error relative to the reference RMS, in dB
	frame_mismatch: bool, // lengths or channel counts differ; only the overlap was compared
}

// Compares two mono signals sample by sample over their common length. Sets
// `frame_mismatch` if the lengths differ. A NaN difference counts as the worst error.
compare_slices :: proc(expected, actual: []f32) -> Compare_Result {
	r: Compare_Result
	r.frame_mismatch = len(expected) != len(actual)
	n := min(len(expected), len(actual))
	sum, ref: f64
	for i in 0 ..< n {
		d := abs(f64(actual[i]) - f64(expected[i]))
		if d > r.max_abs_error || math.is_nan(d) do r.max_abs_error, r.max_error_at = d, i
		sum += d * d
		ref += f64(expected[i]) * f64(expected[i])
	}
	if n > 0 {
		r.rms_error = math.sqrt(sum / f64(n))
		r.error_db = linear_to_db(r.rms_error / max(math.sqrt(ref / f64(n)), 1e-30))
	}
	return r
}

// Compares two multichannel buffers channel by channel and returns the result of the
// channel with the largest `max_abs_error` (`max_error_ch` says which). Sets
// `frame_mismatch` if channel counts or frame counts differ.
compare_buffers :: proc(expected, actual: Audio_Buffer) -> Compare_Result {
	worst: Compare_Result
	if len(expected.channels) != len(actual.channels) || expected.frames != actual.frames {
		worst.frame_mismatch = true
	}
	for c in 0 ..< min(len(expected.channels), len(actual.channels)) {
		r := compare_slices(expected.channels[c], actual.channels[c])
		if c == 0 || r.max_abs_error > worst.max_abs_error {
			mismatch := worst.frame_mismatch
			worst = r
			worst.max_error_ch = c
			worst.frame_mismatch = mismatch || r.frame_mismatch
		}
	}
	return worst
}

@(private)
solve3 :: proc(m: [3][3]f64, r: [3]f64) -> (x: [3]f64, ok: bool) {
	a := m
	b := r
	for col in 0 ..< 3 {
		piv := col
		for row in col + 1 ..< 3 do if abs(a[row][col]) > abs(a[piv][col]) do piv = row
		if abs(a[piv][col]) < 1e-18 do return {}, false
		a[col], a[piv] = a[piv], a[col]
		b[col], b[piv] = b[piv], b[col]
		for row in 0 ..< 3 {
			if row == col do continue
			f := a[row][col] / a[col][col]
			for k in 0 ..< 3 do a[row][k] -= f * a[col][k]
			b[row] -= f * b[col]
		}
	}
	for i in 0 ..< 3 do x[i] = b[i] / a[i][i]
	return x, true
}

// How different two signals sound, ignoring phase: the mean over
// `frame`-sample frames (Hann-windowed, hopping by `frame`) of the RMS
// difference in dB between their magnitude spectra, over bins where either
// is above −100 dBFS. 0 for identical spectra. Use it where waveforms may
// legitimately diverge (a phase vocoder amplifies the last bit of rounding)
// but the sound must not. Compares the common length of `a` and `b`.
spectral_distance :: proc(a, b: []f32, sample_rate: f64, frame := 2048) -> f64 {
	n := min(len(a), len(b))
	total, frames := 0.0, 0
	for at := 0; at + frame <= n; at += frame {
		sa := spectrum(a[at:at + frame], sample_rate, allocator = context.temp_allocator)
		sb := spectrum(b[at:at + frame], sample_rate, allocator = context.temp_allocator)
		sum, count := 0.0, 0
		for k in 1 ..< len(sa.magnitude) {
			ma, mb := sa.magnitude[k], sb.magnitude[k]
			if ma < 1e-5 && mb < 1e-5 do continue
			d := linear_to_db(max(ma, 1e-9)) - linear_to_db(max(mb, 1e-9))
			sum += d * d
			count += 1
		}
		if count > 0 {
			total += math.sqrt(sum / f64(count))
			frames += 1
		}
	}
	return total / f64(max(frames, 1))
}
