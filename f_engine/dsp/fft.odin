package dsp

import "core:math"
import "core:mem"

import "fire:core"

// A complex FFT of a fixed size whose only prime factors are 2, 3 and 5
// (see `fft_fast_size_above`). Unnormalised both ways: the forward
// transform uses e^(−2πi·kn/N), the inverse e^(+2πi·kn/N), and an inverse
// after a forward multiplies by N. f32 data, twiddles computed in f64.
//
// A transform can run in one call or in `fft_steps` pieces (one per radix
// stage), to spread its cost over several audio blocks. Set up with
// `fft_init`; free with `fft_destroy`. One transform at a time per Fft.
// Fields are internal.
Fft :: struct {
	size:    int,
	stages:  []Fft_Stage,
	work:    []complex64,
	scratch: []complex64, // keeps the input of an in-place call
}

@(private)
Fft_Stage :: struct {
	radix:   int,
	n:       int,         // length of the sub-transforms this stage splits
	stride:  int,         // product of the radices before it
	twiddle: []complex64, // e^(−2πi·p·k/n) for p < n/radix, 1 ≤ k < radix, as [p*(radix-1) + k-1]
}

// The smallest size ≥ `size` that `Fft` handles quickly: a power of two
// times 1, 3, 5, 6 or 8 (as Signalsmith Linear chooses, so ported code gets
// the same sizes).
fft_fast_size_above :: proc "contextless" (size: int) -> int {
	pow2 := 1
	for pow2 < 16 && pow2 < size do pow2 *= 2
	for pow2 * 8 < size do pow2 *= 2
	multiple := (size + pow2 - 1) / pow2 // 1..8
	if multiple == 7 do multiple += 1
	return multiple * pow2
}

// Control thread. Prepares an FFT of `size` (≥ 1, prime factors 2, 3, 5
// only; `.Invalid_Argument` otherwise). Free with `fft_destroy`.
fft_init :: proc(f: ^Fft, size: int, allocator := context.allocator) -> core.Error {
	f^ = {size = size}
	if size < 1 do return .Invalid_Argument
	radices := make([dynamic]int, context.temp_allocator)
	rest := size
	// Radix 4 first: it is the cheapest per point.
	for radix in ([]int{4, 2, 3, 5}) {
		for rest % radix == 0 {
			append(&radices, radix)
			rest /= radix
		}
	}
	if rest != 1 do return .Invalid_Argument
	ae: mem.Allocator_Error
	f.stages, ae = make([]Fft_Stage, len(radices), allocator)
	if ae != nil do return .Out_Of_Memory
	f.work, ae = make([]complex64, size, allocator)
	if ae != nil do return fft_failed(f, allocator)
	f.scratch, ae = make([]complex64, size, allocator)
	if ae != nil do return fft_failed(f, allocator)
	n, stride := size, 1
	for r, i in radices {
		st := &f.stages[i]
		st^ = {radix = r, n = n, stride = stride}
		m := n / r
		st.twiddle, ae = make([]complex64, m * (r - 1), allocator)
		if ae != nil do return fft_failed(f, allocator)
		for p in 0 ..< m {
			for k in 1 ..< r {
				angle := -math.TAU * f64(p * k) / f64(n)
				st.twiddle[p * (r - 1) + k - 1] = complex(f32(math.cos(angle)), f32(math.sin(angle)))
			}
		}
		n = m
		stride *= r
	}
	return .None
}

// Control thread. Frees what `fft_init` allocated.
fft_destroy :: proc(f: ^Fft, allocator := context.allocator) {
	for st in f.stages do delete(st.twiddle, allocator)
	delete(f.stages, allocator)
	delete(f.work, allocator)
	delete(f.scratch, allocator)
	f^ = {}
}

// [rt] The number of steps a transform takes with `fft_forward_step` or
// `fft_inverse_step`.
fft_steps :: proc "contextless" (f: ^Fft) -> int {
	return max(len(f.stages), 1)
}

// [rt] Forward transform of `input` into `output` (both `size` long; they
// may be the same slice).
fft_forward :: proc "contextless" (f: ^Fft, input, output: []complex64) {
	for s in 0 ..< fft_steps(f) do fft_step(f, s, input, output, false)
}

// [rt] Inverse transform (unnormalised: scale by 1/size yourself).
fft_inverse :: proc "contextless" (f: ^Fft, input, output: []complex64) {
	for s in 0 ..< fft_steps(f) do fft_step(f, s, input, output, true)
}

// [rt] Step `step` (0 ..< fft_steps) of a forward transform. Run every step
// in order, with the same slices, before using `output`.
fft_forward_step :: proc "contextless" (f: ^Fft, step: int, input, output: []complex64) {
	fft_step(f, step, input, output, false)
}

// [rt] Step `step` of an inverse transform (see `fft_forward_step`).
fft_inverse_step :: proc "contextless" (f: ^Fft, step: int, input, output: []complex64) {
	fft_step(f, step, input, output, true)
}

@(private)
fft_failed :: proc(f: ^Fft, allocator: mem.Allocator) -> core.Error {
	fft_destroy(f, allocator)
	return .Out_Of_Memory
}

// One Stockham (self-sorting, decimation-in-frequency) stage. Stage i reads
// what stage i−1 wrote and writes to `output` or `work`, alternating so the
// last stage lands in `output`. When input and output are the same slice,
// the input is first saved to `scratch`.
@(private)
fft_step :: proc "contextless" (f: ^Fft, step: int, input, output: []complex64, inverse: bool) {
	count := len(f.stages)
	if count == 0 { // size 1
		output[0] = input[0]
		return
	}
	src: []complex64
	if step == 0 {
		src = input
		if raw_data(input) == raw_data(output) {
			copy(f.scratch, input)
			src = f.scratch
		}
	} else {
		src = output if (count - step) % 2 == 0 else f.work
	}
	dst := output if (count - 1 - step) % 2 == 0 else f.work
	st := &f.stages[step]
	switch st.radix {
	case 2: radix2(st, src, dst, inverse)
	case 3: radix3(st, src, dst, inverse)
	case 4: radix4(st, src, dst, inverse)
	case 5: radix5(st, src, dst, inverse)
	}
}

// With m = n/r and s = stride, each stage computes, for p < m and q < s:
//   a_j = x[q + s(p + jm)],  y[q + s(rp + k)] = (Σ_j a_j·W_r^(jk)) · w_n^(pk)
// where W_r and w_n are e^(∓2πi/r) and e^(∓2πi/n).

@(private)
twiddle :: #force_inline proc "contextless" (st: ^Fft_Stage, p, k: int, inverse: bool) -> complex64 {
	w := st.twiddle[p * (st.radix - 1) + k - 1]
	return conj(w) if inverse else w
}

@(private)
radix2 :: proc "contextless" (st: ^Fft_Stage, x, y: []complex64, inverse: bool) {
	m, s := st.n / 2, st.stride
	for p in 0 ..< m {
		w := twiddle(st, p, 1, inverse)
		for q in 0 ..< s {
			a, b := x[q + s * p], x[q + s * (p + m)]
			y[q + s * (2 * p)] = a + b
			y[q + s * (2 * p + 1)] = (a - b) * w
		}
	}
}

@(private)
radix4 :: proc "contextless" (st: ^Fft_Stage, x, y: []complex64, inverse: bool) {
	m, s := st.n / 4, st.stride
	for p in 0 ..< m {
		w1, w2, w3 := twiddle(st, p, 1, inverse), twiddle(st, p, 2, inverse), twiddle(st, p, 3, inverse)
		for q in 0 ..< s {
			a0, a1 := x[q + s * p], x[q + s * (p + m)]
			a2, a3 := x[q + s * (p + 2 * m)], x[q + s * (p + 3 * m)]
			t0, t1 := a0 + a2, a0 - a2
			t2, t3 := a1 + a3, a1 - a3
			// W_4 = −i forward, +i inverse: multiplying t3 by it rotates a quarter turn.
			jt3 := complex(imag(t3), -real(t3)) if !inverse else complex(-imag(t3), real(t3))
			base := q + s * 4 * p
			y[base] = t0 + t2
			y[base + s] = (t1 + jt3) * w1
			y[base + 2 * s] = (t0 - t2) * w2
			y[base + 3 * s] = (t1 - jt3) * w3
		}
	}
}

@(private)
radix3 :: proc "contextless" (st: ^Fft_Stage, x, y: []complex64, inverse: bool) {
	m, s := st.n / 3, st.stride
	SIN_60 :: f32(0.86602540378443864676)
	sn := -SIN_60 if !inverse else SIN_60 // imag(W_3)
	for p in 0 ..< m {
		w1, w2 := twiddle(st, p, 1, inverse), twiddle(st, p, 2, inverse)
		for q in 0 ..< s {
			a0, a1, a2 := x[q + s * p], x[q + s * (p + m)], x[q + s * (p + 2 * m)]
			sum := a1 + a2
			dif := a1 - a2
			mid := a0 - sum * 0.5
			rot := complex(-imag(dif) * sn, real(dif) * sn) // i·sn·dif
			base := q + s * 3 * p
			y[base] = a0 + sum
			y[base + s] = (mid + rot) * w1
			y[base + 2 * s] = (mid - rot) * w2
		}
	}
}

@(private)
radix5 :: proc "contextless" (st: ^Fft_Stage, x, y: []complex64, inverse: bool) {
	m, s := st.n / 5, st.stride
	C1 :: 0.30901699437494742410  // cos(2π/5)
	C2 :: -0.80901699437494742410 // cos(4π/5)
	S1 :: 0.95105651629515357212  // sin(2π/5)
	S2 :: 0.58778525229247312917  // sin(4π/5)
	sign := f32(-1) if !inverse else 1 // sign of the imaginary part of W_5
	for p in 0 ..< m {
		w1, w2 := twiddle(st, p, 1, inverse), twiddle(st, p, 2, inverse)
		w3, w4 := twiddle(st, p, 3, inverse), twiddle(st, p, 4, inverse)
		for q in 0 ..< s {
			a0 := x[q + s * p]
			a1, a2 := x[q + s * (p + m)], x[q + s * (p + 2 * m)]
			a3, a4 := x[q + s * (p + 3 * m)], x[q + s * (p + 4 * m)]
			b1, b4 := a1 + a4, a1 - a4
			b2, b3 := a2 + a3, a2 - a3
			c1 := a0 + b1 * C1 + b2 * C2
			c2 := a0 + b1 * C2 + b2 * C1
			// sign·i·(S1·b4 + S2·b3) and sign·i·(S2·b4 − S1·b3)
			d1v := b4 * S1 + b3 * S2
			d2v := b4 * S2 - b3 * S1
			d1 := complex(-imag(d1v) * sign, real(d1v) * sign)
			d2 := complex(-imag(d2v) * sign, real(d2v) * sign)
			base := q + s * 5 * p
			y[base] = a0 + b1 + b2
			y[base + s] = (c1 + d1) * w1
			y[base + 2 * s] = (c2 + d2) * w2
			y[base + 3 * s] = (c2 - d2) * w3
			y[base + 4 * s] = (c1 - d1) * w4
		}
	}
}

// --- real FFT ----------------------------------------------------------------------------------

// An FFT of `size` real samples (even; size/2 a fast size), giving size/2
// complex bins. Same conventions as `Fft` (unnormalised; inverse after
// forward multiplies by `size`). Two spectrum layouts:
//
// - Normal: bin k is X[k] for 1 ≤ k < size/2, and bin 0 packs DC (real
//   part) with Nyquist (imaginary part).
// - Half-bin (`half_bin`): bin k is the spectrum at k + ½, for 0 ≤ k <
//   size/2: X[k+½] = Σ x[n]·e^(−2πi·(k+½)n/size). No packing; the bins sit
//   symmetrically around the frequencies that matter (used by STFTs).
//
// With `split`, the final (forward) or first (inverse) twiddle pass is done
// in two halves, for one more step and smaller pieces. Laid out as
// Signalsmith Linear's RealFFT, so ported code steps through it the same
// way. Set up with `real_fft_init`; free with `real_fft_destroy`. Fields are
// internal.
Real_Fft :: struct {
	size:     int,
	half_bin: bool,
	split:    bool,
	complex:  Fft,
	twiddles: []complex64,
	twists:   []complex64, // half-bin: e^(−2πi·n/size), applied to the input pairs
	time:     []complex64,
	freq:     []complex64,
}

// The smallest even size ≥ `size` that `Real_Fft` handles quickly.
real_fft_fast_size_above :: proc "contextless" (size: int) -> int {
	return fft_fast_size_above((size + 1) / 2) * 2
}

// Control thread. Prepares a real FFT of `size` (even, size/2 with prime
// factors 2, 3 and 5 only). Free with `real_fft_destroy`.
real_fft_init :: proc(r: ^Real_Fft, size: int, half_bin := false, split := false, allocator := context.allocator) -> core.Error {
	r^ = {size = size, half_bin = half_bin, split = split}
	if size < 2 || size % 2 != 0 do return .Invalid_Argument
	h := size / 2
	fft_init(&r.complex, h, allocator) or_return
	ae: mem.Allocator_Error
	r.twiddles, ae = make([]complex64, h / 2 + 1, allocator)
	if ae != nil do return real_fft_failed(r, allocator)
	r.time, ae = make([]complex64, h, allocator)
	if ae != nil do return real_fft_failed(r, allocator)
	r.freq, ae = make([]complex64, h, allocator)
	if ae != nil do return real_fft_failed(r, allocator)
	offset := 0.5 if half_bin else 0
	for &t, i in r.twiddles {
		// The rotation by −i is baked in.
		phase := (f64(i) + offset) * (-math.TAU / f64(size)) - math.PI / 2
		t = complex(f32(math.cos(phase)), f32(math.sin(phase)))
	}
	if half_bin {
		r.twists, ae = make([]complex64, h, allocator)
		if ae != nil do return real_fft_failed(r, allocator)
		for &t, i in r.twists {
			phase := -math.TAU * f64(i) / f64(size)
			t = complex(f32(math.cos(phase)), f32(math.sin(phase)))
		}
	}
	return .None
}

// Control thread. Frees what `real_fft_init` allocated.
real_fft_destroy :: proc(r: ^Real_Fft, allocator := context.allocator) {
	fft_destroy(&r.complex, allocator)
	delete(r.twiddles, allocator)
	delete(r.twists, allocator)
	delete(r.time, allocator)
	delete(r.freq, allocator)
	r^ = {}
}

// [rt] Steps per transform (forward or inverse).
real_fft_steps :: proc "contextless" (r: ^Real_Fft) -> int {
	return fft_steps(&r.complex) + (3 if r.split else 2)
}

// [rt] Forward transform: `size` samples to `size`/2 bins.
real_fft_forward :: proc "contextless" (r: ^Real_Fft, time: []f32, freq: []complex64) {
	for s in 0 ..< real_fft_steps(r) do real_fft_forward_step(r, s, time, freq)
}

// [rt] Inverse transform: `size`/2 bins to `size` samples (unnormalised).
real_fft_inverse :: proc "contextless" (r: ^Real_Fft, freq: []complex64, time: []f32) {
	for s in 0 ..< real_fft_steps(r) do real_fft_inverse_step(r, s, freq, time)
}

// [rt] Step `step` of a forward transform (0 ..< real_fft_steps). Run every
// step in order, with the same slices.
real_fft_forward_step :: proc "contextless" (r: ^Real_Fft, step: int, time: []f32, freq: []complex64) {
	h := r.size / 2
	complex_steps := fft_steps(&r.complex)
	switch {
	case step == 0: // pair up samples as complex values
		for i in 0 ..< h {
			t := complex(time[2 * i], time[2 * i + 1])
			r.time[i] = t * r.twists[i] if r.half_bin else t
		}
	case step - 1 < complex_steps:
		fft_forward_step(&r.complex, step - 1, r.time, r.freq)
	case: // untangle the half-size spectrum into the real one
		if !r.half_bin {
			b := r.freq[0]
			freq[0] = complex(real(b) + imag(b), real(b) - imag(b)) // DC, Nyquist
		}
		first, end := split_range(r, step - 1 - complex_steps)
		for i in first ..< end {
			ci := conj_index(r, i)
			tw := r.twiddles[i]
			odd := (r.freq[i] + conj(r.freq[ci])) * 0.5
			even := (r.freq[i] - conj(r.freq[ci])) * 0.5
			rot := even * tw
			freq[i] = odd + rot
			freq[ci] = complex(real(odd) - real(rot), imag(rot) - imag(odd))
		}
	}
}

// [rt] Step `step` of an inverse transform (see `real_fft_forward_step`).
real_fft_inverse_step :: proc "contextless" (r: ^Real_Fft, step: int, freq: []complex64, time: []f32) {
	h := r.size / 2
	complex_steps := fft_steps(&r.complex)
	twiddle_steps := 2 if r.split else 1
	switch {
	case step < twiddle_steps: // re-tangle into a half-size spectrum
		if !r.half_bin {
			b := freq[0]
			r.freq[0] = complex(real(b) + imag(b), real(b) - imag(b))
		}
		first, end := split_range(r, step)
		for i in first ..< end {
			ci := conj_index(r, i)
			tw := r.twiddles[i]
			odd := freq[i] + conj(freq[ci])
			even := (freq[i] - conj(freq[ci])) * conj(tw)
			r.freq[i] = odd + even
			r.freq[ci] = complex(real(odd) - real(even), imag(even) - imag(odd))
		}
	case step - twiddle_steps < complex_steps:
		fft_inverse_step(&r.complex, step - twiddle_steps, r.freq, r.time)
	case: // complex values back to sample pairs
		for i in 0 ..< h {
			t := r.time[i] * conj(r.twists[i]) if r.half_bin else r.time[i]
			time[2 * i], time[2 * i + 1] = real(t), imag(t)
		}
	}
}

// The bins a twiddle pass covers: all of them, or (split) half for `part`
// 0 and the rest for part 1.
@(private)
split_range :: #force_inline proc "contextless" (r: ^Real_Fft, part: int) -> (first, end: int) {
	first = 0 if r.half_bin else 1
	end = r.size / 4 + 1
	if r.split {
		mid := (first + end) / 2
		if part == 0 {
			end = mid
		} else {
			first = mid
		}
	}
	return
}

@(private)
conj_index :: #force_inline proc "contextless" (r: ^Real_Fft, i: int) -> int {
	h := r.size / 2
	return h - 1 - i if r.half_bin else h - i
}

@(private)
real_fft_failed :: proc(r: ^Real_Fft, allocator: mem.Allocator) -> core.Error {
	real_fft_destroy(r, allocator)
	return .Out_Of_Memory
}
