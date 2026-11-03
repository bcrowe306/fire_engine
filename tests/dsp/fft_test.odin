package test_dsp

import "core:math"
import "core:testing"

import "fire:core"
import "fire:dsp"
import kit "fire:testkit"

// Sizes whose only prime factors are 2, 3 and 5.
smooth :: proc(n: int) -> bool {
	m := n
	for p in ([]int{2, 3, 5}) do for m % p == 0 do m /= p
	return m == 1
}

// A direct DFT in f64: X[k] = Σ x[n]·e^(sign·2πi·kn/N), with the phase taken
// mod N so large sizes stay exact. `shift` (0 or ½) offsets k.
dft :: proc(x: []complex128, sign: f64, shift := 0.0) -> []complex128 {
	n := len(x)
	out := make([]complex128, n, context.temp_allocator)
	for k in 0 ..< n {
		sum: complex128
		for v, j in x {
			phase := sign * math.TAU * ((f64(k) + shift) * f64(j) - f64(n) * math.floor((f64(k) + shift) * f64(j) / f64(n))) / f64(n)
			sum += v * complex(math.cos(phase), math.sin(phase))
		}
		out[k] = sum
	}
	return out
}

// Largest error of `got` against `want`, relative to the input's energy.
rel_error :: proc(got: []complex64, want: []complex128, energy: f64) -> f64 {
	worst := 0.0
	for g, i in got do worst = max(worst, abs(complex128(g) - want[i]))
	return worst / math.sqrt(energy)
}

noise_complex :: proc(n: int, seed: u64) -> (x: []complex64, x64: []complex128, energy: f64) {
	re := make([]f32, n, context.temp_allocator)
	im := make([]f32, n, context.temp_allocator)
	kit.white_noise(re, seed, 1)
	kit.white_noise(im, seed + 1, 1)
	x = make([]complex64, n, context.temp_allocator)
	x64 = make([]complex128, n, context.temp_allocator)
	for i in 0 ..< n {
		x[i] = complex(re[i], im[i])
		x64[i] = complex(f64(re[i]), f64(im[i]))
		energy += f64(re[i]) * f64(re[i]) + f64(im[i]) * f64(im[i])
	}
	return
}

@(test)
fast_sizes_match_linear :: proc(t: ^testing.T) {
	// Signalsmith Linear's choices (a power of two times 1..8, never 7).
	// It starts from a power of two of at least 16 (or the size, if smaller).
	for pair in ([][2]int{{1, 1}, {5, 8}, {7, 8}, {17, 32}, {100, 128}, {1000, 1024}, {2880, 3072}, {4097, 5120}}) {
		testing.expectf(t, dsp.fft_fast_size_above(pair[0]) == pair[1], "fast size above %d: %d, want %d", pair[0], dsp.fft_fast_size_above(pair[0]), pair[1])
	}
	testing.expect_value(t, dsp.real_fft_fast_size_above(5760), 6144) // a 120 ms block at 48 kHz
	for n in 1 ..< 5000 {
		f := dsp.fft_fast_size_above(n)
		if f < n || !smooth(f) {
			testing.expectf(t, false, "fast size above %d is %d", n, f)
			break
		}
	}
}

@(test)
complex_fft_matches_the_dft :: proc(t: ^testing.T) {
	sizes := make([dynamic]int, context.temp_allocator)
	for n in 1 ..= 64 do if smooth(n) do append(&sizes, n)
	append(&sizes, 96, 120, 160, 240, 384, 640, 1000, 1536, 2880)
	for n in sizes {
		f: dsp.Fft
		testing.expect_value(t, dsp.fft_init(&f, n), core.Error.None)
		x, x64, energy := noise_complex(n, u64(n))
		out := make([]complex64, n, context.temp_allocator)
		dsp.fft_forward(&f, x, out)
		e := rel_error(out, dft(x64, -1), energy)
		testing.expectf(t, e < 2e-6, "size %d forward: relative error %v", n, e)
		dsp.fft_inverse(&f, x, out)
		e = rel_error(out, dft(x64, 1), energy)
		testing.expectf(t, e < 2e-6, "size %d inverse: relative error %v", n, e)
		dsp.fft_destroy(&f)
	}
}

@(test)
complex_round_trip_large :: proc(t: ^testing.T) {
	for n in ([]int{3072, 4096, 5120, 6144, 12_288, 30_720, 65_536}) {
		f: dsp.Fft
		dsp.fft_init(&f, n)
		x, _, energy := noise_complex(n, 7)
		y := make([]complex64, n, context.temp_allocator)
		dsp.fft_forward(&f, x, y)
		dsp.fft_inverse(&f, y, y) // in place
		worst := 0.0
		for v, i in y do worst = max(worst, abs(complex128(v) / complex128(complex(f64(n), 0)) - complex128(x[i])))
		testing.expectf(t, worst / math.sqrt(energy / f64(n)) < 1e-5, "size %d: round trip off by %v", n, worst)
		dsp.fft_destroy(&f)
	}
}

@(test)
real_fft_matches_the_dft :: proc(t: ^testing.T) {
	for n in ([]int{2, 4, 6, 10, 12, 30, 48, 120, 384, 1000, 2880, 6144}) {
		for half_bin in ([]bool{false, true}) {
			r: dsp.Real_Fft
			testing.expect_value(t, dsp.real_fft_init(&r, n, half_bin), core.Error.None)
			x := make([]f32, n, context.temp_allocator)
			kit.white_noise(x, u64(n), 1)
			x64 := make([]complex128, n, context.temp_allocator)
			energy: f64
			for v, i in x {
				x64[i] = complex(f64(v), 0)
				energy += f64(v) * f64(v)
			}
			freq := make([]complex64, n / 2, context.temp_allocator)
			dsp.real_fft_forward(&r, x, freq)
			want := dft(x64, -1, 0.5 if half_bin else 0)
			expect := make([]complex128, n / 2, context.temp_allocator)
			copy(expect, want[:n / 2])
			if !half_bin do expect[0] = complex(real(want[0]), real(want[n / 2])) // DC and Nyquist packed
			e := rel_error(freq, expect, energy)
			testing.expectf(t, e < 2e-6, "size %d half_bin %v: relative error %v", n, half_bin, e)

			back := make([]f32, n, context.temp_allocator)
			dsp.real_fft_inverse(&r, freq, back)
			worst := 0.0
			for v, i in back do worst = max(worst, abs(f64(v) / f64(n) - f64(x[i])))
			testing.expectf(t, worst < 1e-5, "size %d half_bin %v: round trip off by %v", n, half_bin, worst)
			dsp.real_fft_destroy(&r)
		}
	}
}

// Running a transform step by step (as split computation does) gives
// exactly the same result as running it at once.
@(test)
steps_match_one_shot :: proc(t: ^testing.T) {
	n := 6144
	x := make([]f32, n, context.temp_allocator)
	kit.white_noise(x, 3, 1)
	for half_bin in ([]bool{false, true}) {
		for split in ([]bool{false, true}) {
			r: dsp.Real_Fft
			dsp.real_fft_init(&r, n, half_bin, split)
			a := make([]complex64, n / 2, context.temp_allocator)
			b := make([]complex64, n / 2, context.temp_allocator)
			dsp.real_fft_forward(&r, x, a)
			for s in 0 ..< dsp.real_fft_steps(&r) do dsp.real_fft_forward_step(&r, s, x, b)
			same := true
			for v, i in a do if v != b[i] do same = false
			testing.expectf(t, same, "half_bin %v split %v: forward steps differ", half_bin, split)
			ta := make([]f32, n, context.temp_allocator)
			tb := make([]f32, n, context.temp_allocator)
			dsp.real_fft_inverse(&r, a, ta)
			for s in 0 ..< dsp.real_fft_steps(&r) do dsp.real_fft_inverse_step(&r, s, a, tb)
			testing.expectf(t, kit.compare_slices(ta, tb).max_abs_error == 0, "half_bin %v split %v: inverse steps differ", half_bin, split)
			testing.expect_value(t, dsp.real_fft_steps(&r), dsp.fft_steps(&r.complex) + (3 if split else 2))
			dsp.real_fft_destroy(&r)
		}
	}
}

@(test)
fft_never_allocates :: proc(t: ^testing.T) {
	r: dsp.Real_Fft
	dsp.real_fft_init(&r, 6144, true, true)
	defer dsp.real_fft_destroy(&r)
	x := make([]f32, 6144, context.temp_allocator)
	kit.white_noise(x, 4, 1)
	freq := make([]complex64, 3072, context.temp_allocator)
	trap: kit.Trap_Allocator
	{
		context.allocator = kit.trap_allocator(&trap)
		context.temp_allocator = context.allocator
		for _ in 0 ..< 10 {
			dsp.real_fft_forward(&r, x, freq)
			dsp.real_fft_inverse(&r, freq, x)
		}
	}
	testing.expect_value(t, trap.violations, 0)
	n, _ := kit.count_non_finite(x)
	testing.expect_value(t, n, 0)
}

@(test)
fft_rejects_other_sizes :: proc(t: ^testing.T) {
	f: dsp.Fft
	testing.expect_value(t, dsp.fft_init(&f, 7), core.Error.Invalid_Argument)
	testing.expect_value(t, dsp.fft_init(&f, 0), core.Error.Invalid_Argument)
	r: dsp.Real_Fft
	testing.expect_value(t, dsp.real_fft_init(&r, 15), core.Error.Invalid_Argument)
	testing.expect_value(t, dsp.real_fft_init(&r, 14), core.Error.Invalid_Argument) // 7
}
