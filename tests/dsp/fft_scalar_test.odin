package test_dsp

import "core:math"
import "core:math/rand"
import "core:testing"

import "fire:dsp"

// The FFT as plain scalar Stockham stages: what `dsp.Fft` computed before
// its stages were vectorised. The SIMD version must match it bit for bit.
scalar_fft :: proc(x: []complex64, inverse: bool) -> []complex64 {
	size := len(x)
	radices := make([dynamic]int, context.temp_allocator)
	rest := size
	for radix in ([]int{4, 2, 3, 5}) {
		for rest % radix == 0 {
			append(&radices, radix)
			rest /= radix
		}
	}
	src := make([]complex64, size, context.temp_allocator)
	dst := make([]complex64, size, context.temp_allocator)
	copy(src, x)
	n, stride := size, 1
	for r in radices {
		m, s := n / r, stride
		for p in 0 ..< m {
			w: [5]complex64
			for k in 1 ..< r {
				angle := -math.TAU * f64(p * k) / f64(n)
				w[k] = complex(f32(math.cos(angle)), f32(math.sin(angle)))
				if inverse do w[k] = conj(w[k])
			}
			for q in 0 ..< s {
				a: [5]complex64
				for j in 0 ..< r do a[j] = src[q + s * (p + j * m)]
				y: [5]complex64
				switch r {
				case 2:
					y[0] = a[0] + a[1]
					y[1] = (a[0] - a[1]) * w[1]
				case 4:
					t0, t1 := a[0] + a[2], a[0] - a[2]
					t2, t3 := a[1] + a[3], a[1] - a[3]
					jt3 := complex(imag(t3), -real(t3)) if !inverse else complex(-imag(t3), real(t3))
					y[0] = t0 + t2
					y[1] = (t1 + jt3) * w[1]
					y[2] = (t0 - t2) * w[2]
					y[3] = (t1 - jt3) * w[3]
				case 3:
					SIN_60 :: f32(0.86602540378443864676)
					sn := -SIN_60 if !inverse else SIN_60
					sum, dif := a[1] + a[2], a[1] - a[2]
					mid := a[0] - sum * 0.5
					rot := complex(-imag(dif) * sn, real(dif) * sn)
					y[0] = a[0] + sum
					y[1] = (mid + rot) * w[1]
					y[2] = (mid - rot) * w[2]
				case 5:
					C1 :: 0.30901699437494742410
					C2 :: -0.80901699437494742410
					S1 :: 0.95105651629515357212
					S2 :: 0.58778525229247312917
					sign := f32(-1) if !inverse else 1
					b1, b4 := a[1] + a[4], a[1] - a[4]
					b2, b3 := a[2] + a[3], a[2] - a[3]
					c1 := a[0] + b1 * C1 + b2 * C2
					c2 := a[0] + b1 * C2 + b2 * C1
					d1v, d2v := b4 * S1 + b3 * S2, b4 * S2 - b3 * S1
					d1 := complex(-imag(d1v) * sign, real(d1v) * sign)
					d2 := complex(-imag(d2v) * sign, real(d2v) * sign)
					y[0] = a[0] + b1 + b2
					y[1] = (c1 + d1) * w[1]
					y[2] = (c2 + d2) * w[2]
					y[3] = (c2 - d2) * w[3]
					y[4] = (c1 - d1) * w[4]
				}
				for k in 0 ..< r do dst[q + s * (r * p + k)] = y[k]
			}
		}
		src, dst = dst, src
		n = m
		stride *= r
	}
	return src
}

// Every vector path (pairs along q, pairs along p, one at a time) and every
// radix, both directions, against the scalar stages.
@(test)
simd_fft_matches_scalar_bit_for_bit :: proc(t: ^testing.T) {
	sizes := make([dynamic]int, context.temp_allocator)
	for n in 1 ..= 400 do if smooth(n) do append(&sizes, n)
	append(&sizes, 1920, 2880, 3072, 4096, 3000)
	for size in sizes {
		f: dsp.Fft
		dsp.fft_init(&f, size)
		defer dsp.fft_destroy(&f)
		x := make([]complex64, size, context.temp_allocator)
		for &v in x do v = complex(rand.float32_range(-1, 1), rand.float32_range(-1, 1))
		got := make([]complex64, size, context.temp_allocator)
		for inverse in ([]bool{false, true}) {
			if inverse do dsp.fft_inverse(&f, x, got)
			else do dsp.fft_forward(&f, x, got)
			want := scalar_fft(x, inverse)
			diffs := 0
			for i in 0 ..< size do if got[i] != want[i] do diffs += 1
			testing.expectf(t, diffs == 0, "size %d (inverse %v): %d of %d values differ", size, inverse, diffs, size)
		}
	}
}
