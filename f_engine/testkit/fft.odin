package testkit

import "core:math"
import "core:math/cmplx"

// Analysis window for `spectrum` and `window_value`.
Window :: enum {
	Rectangular, // no window
	Hann,        // good general choice, ~-31 dB sidelobes
	Blackman_Harris, // 4-term, ~-92 dB sidelobes
}

// Coefficient of window `w` at sample `i` of an `n`-sample (symmetric) window. 1 when n <= 1.
window_value :: proc(w: Window, i, n: int) -> f64 {
	if n <= 1 do return 1
	x := math.TAU * f64(i) / f64(n - 1)
	switch w {
	case .Rectangular:     return 1
	case .Hann:            return 0.5 - 0.5 * math.cos(x)
	case .Blackman_Harris: return 0.35875 - 0.48829 * math.cos(x) + 0.14128 * math.cos(2 * x) - 0.01168 * math.cos(3 * x)
	}
	return 1
}

// Smallest power of two >= n (1 for n <= 1).
next_pow2 :: proc(n: int) -> int {
	p := 1
	for p < n do p <<= 1
	return p
}

// In-place iterative radix-2 FFT. len(data) must be a power of two.
// The inverse is not normalized; divide by n yourself.
fft :: proc(data: []complex128, inverse := false) {
	n := len(data)
	assert(n > 0 && n & (n - 1) == 0, "fft length must be a power of two")

	j := 0
	for i in 1 ..< n {
		bit := n >> 1
		for j & bit != 0 {
			j ~= bit
			bit >>= 1
		}
		j |= bit
		if i < j do data[i], data[j] = data[j], data[i]
	}

	sign := inverse ? 1.0 : -1.0
	for size := 2; size <= n; size <<= 1 {
		ang := sign * math.TAU / f64(size)
		wn := complex(math.cos(ang), math.sin(ang))
		for start := 0; start < n; start += size {
			w := complex128(1)
			half := size / 2
			for k in 0 ..< half {
				a := data[start + k]
				b := data[start + k + half] * w
				data[start + k] = a + b
				data[start + k + half] = a - b
				w *= wn
			}
		}
	}
}

// Single-sided amplitude spectrum, scaled so a full-scale sine reads ~1.0 at its bin.
// The signal is zero-padded to a power of two. Bin k is at k * sample_rate / n_fft.
Spectrum :: struct {
	magnitude:   []f64, // n_fft/2 + 1 bins, linear amplitude
	n_fft:       int, // FFT length (power of two)
	sample_rate: f64, // Hz
}

// Windowed, zero-padded FFT of `x`. The magnitudes are allocated from `allocator`
// (free with `spectrum_destroy`); FFT scratch comes from context.temp_allocator.
spectrum :: proc(x: []f32, sample_rate: f64, window := Window.Hann, allocator := context.allocator) -> Spectrum {
	n := next_pow2(max(len(x), 2))
	buf := make([]complex128, n, context.temp_allocator)
	wsum := 0.0
	for v, i in x {
		w := window_value(window, i, len(x))
		wsum += w
		buf[i] = complex(f64(v) * w, 0)
	}
	fft(buf)
	mag := make([]f64, n / 2 + 1, allocator)
	for k in 0 ..= n / 2 {
		scale := (k == 0 || k == n / 2) ? 1.0 : 2.0
		mag[k] = scale * cmplx.abs(buf[k]) / max(wsum, 1e-30)
	}
	return Spectrum{mag, n, sample_rate}
}

// Frees a spectrum's magnitudes with the allocator `spectrum` used, and zeroes it.
spectrum_destroy :: proc(s: ^Spectrum, allocator := context.allocator) {
	delete(s.magnitude, allocator)
	s^ = {}
}

// Center frequency in Hz of bin `k`.
spectrum_bin_hz :: proc(s: Spectrum, k: int) -> f64 {
	return f64(k) * s.sample_rate / f64(s.n_fft)
}

// The bin with the largest magnitude, ignoring DC (bin 0), with its frequency in Hz
// and linear amplitude.
spectrum_peak :: proc(s: Spectrum) -> (bin: int, freq_hz: f64, magnitude: f64) {
	for m, k in s.magnitude {
		if k > 0 && m > magnitude {
			bin, magnitude = k, m
		}
	}
	return bin, spectrum_bin_hz(s, bin), magnitude
}
