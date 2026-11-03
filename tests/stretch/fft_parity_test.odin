package test_stretch

import "core:log"
import "core:math"
import "core:testing"
import "core:time"

import "fire:dsp"
import ss "fire:sys/signalsmith"
import kit "fire:testkit"

// fire:dsp's real FFT gives the same spectrum as Signalsmith Linear's (the
// one Stretch was built on), at the sizes Stretch uses.
@(test)
real_fft_matches_linear :: proc(t: ^testing.T) {
	for size in ([]int{256, 1536, 2880 * 2, 3840, 5120, 6144, 10_240}) {
		for half_bin in ([]bool{false, true}) {
			x := make([]f32, size, context.temp_allocator)
			kit.white_noise(x, u64(size), 1)
			want := make([]complex64, size / 2, context.temp_allocator)
			ss.test_real_fft(i32(size), i32(half_bin), raw_data(x), cast([^]f32)raw_data(want))
			r: dsp.Real_Fft
			dsp.real_fft_init(&r, size, half_bin)
			got := make([]complex64, size / 2, context.temp_allocator)
			dsp.real_fft_forward(&r, x, got)
			dsp.real_fft_destroy(&r)
			worst, scale := 0.0, 0.0
			for g, i in got {
				worst = max(worst, abs(complex128(g) - complex128(want[i])))
				scale = max(scale, abs(complex128(want[i])))
			}
			db := kit.linear_to_db(worst / scale)
			testing.expectf(t, db < -120, "size %d half_bin %v: differs from Linear by %.1f dB", size, half_bin, db)
		}
	}
}

// How fast fire:dsp's FFT is next to Linear's (forward + inverse, the
// half-bin real FFT a 120 ms STFT block uses at 48 kHz). Logged, not
// asserted; the port's optimisation stage works from these numbers.
@(test)
real_fft_speed_vs_linear :: proc(t: ^testing.T) {
	for size in ([]int{6144, 3840}) {
		count := 2000
		linear := ss.test_bench_real_fft(i32(size), i32(count))
		r: dsp.Real_Fft
		dsp.real_fft_init(&r, size, true)
		defer dsp.real_fft_destroy(&r)
		x := make([]f32, size, context.temp_allocator)
		for &v in x do v = 0.25
		freq := make([]complex64, size / 2, context.temp_allocator)
		start := time.tick_now()
		for _ in 0 ..< count {
			dsp.real_fft_forward(&r, x, freq)
			dsp.real_fft_inverse(&r, freq, x)
			x[0] = 0.25
		}
		ours := time.duration_seconds(time.tick_since(start)) / f64(count)
		log.infof("size %d: fire:dsp %.1f µs, Linear %.1f µs (×%.2f)", size, ours * 1e6, linear * 1e6, ours / linear)
		testing.expect(t, !math.is_nan(ours))
	}
}
