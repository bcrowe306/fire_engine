package test_dsp

// The resampler changes the number of frames, so it is not a core.Node and
// can't go through testkit.render. These tests drive it directly with the
// same checks: finite output, no allocation, any block split, plus accuracy.

import "core:log"
import "core:math"
import "core:testing"

import "fire:dsp"
import kit "fire:testkit"

// Resamples all of `input` at a constant speed, fed in `in_chunk`-frame
// pieces with room for `out_chunk` frames per call. Then flushes with silence
// so the output covers the whole input.
resample :: proc(q: dsp.Resampler_Quality, input: [][]f32, speed: f64, in_chunk := 512, out_chunk := 512) -> [][]f32 {
	r: dsp.Resampler
	dsp.resampler_init(&r, len(input), q, max_speed = 4, max_input = 4096)
	defer dsp.resampler_destroy(&r)
	total := int(f64(len(input[0])) / speed)
	out := make([][]f32, len(input), context.temp_allocator)
	for &c in out do c = make([]f32, total, context.temp_allocator)
	zeros := make([]f32, in_chunk, context.temp_allocator)
	ins := make([][]f32, len(input), context.temp_allocator)
	outs := make([][]f32, len(input), context.temp_allocator)
	at, produced := 0, 0
	for produced < total {
		n := min(in_chunk, len(input[0]) - at)
		for c in 0 ..< len(input) do ins[c] = input[c][at:at + n] if n > 0 else zeros
		m := min(out_chunk, total - produced)
		for c in 0 ..< len(input) do outs[c] = out[c][produced:produced + m]
		used, made := dsp.resampler_process(&r, ins, outs, speed)
		if n > 0 do at += used
		produced += made
	}
	return out
}

// RMS error, in dB relative to the amplitude, of `y` against a sine of
// `freq` (Hz at the input rate) read at times k × speed; the edges, where the
// filter sees the start or end of the signal, are skipped.
error_db :: proc(y: []f32, freq, sr, speed, amp: f64) -> f64 {
	skip := 2000
	sum: f64
	n := 0
	for k in skip ..< len(y) - skip {
		e := f64(y[k]) - amp * math.sin(math.TAU * freq * f64(k) * speed / sr)
		sum += e * e
		n += 1
	}
	return kit.linear_to_db(math.sqrt(sum / f64(n)) / amp)
}

@(test)
resampler_accuracy_at_each_quality :: proc(t: ^testing.T) {
	// 44.1 → 48 kHz (and back): tones across the passband.
	limits := [dsp.Resampler_Quality]f64{.Low = -55, .Medium = -85, .High = -110}
	for q in dsp.Resampler_Quality {
		for f in ([]f64{100, 1000, 10_000, 17_000}) {
			for speed in ([]f64{44_100.0 / 48_000, 48_000.0 / 44_100}) {
				x := make([]f32, 40_000, context.temp_allocator)
				kit.sine(x, 44_100, f, 0.5)
				flat_to := [dsp.Resampler_Quality]f64{.Low = 0.75, .Medium = 0.85, .High = 0.90}
				if f > flat_to[q] * 22_050 * min(1, 1 / speed) do continue // outside this quality's passband
				y := resample(q, {x}, speed)
				db := error_db(y[0], f, 44_100, speed, 0.5)
				log.infof("%v, %5.0f Hz, speed %.4f: error %.1f dB", q, f, speed, db)
				testing.expectf(t, db < limits[q], "%v, %v Hz, speed %v: error %.1f dB (limit %v)", q, f, speed, db, limits[q])
			}
		}
	}
}

// Tones above the output's Nyquist frequency are removed, not folded back.
@(test)
resampler_rejects_aliases :: proc(t: ^testing.T) {
	limits := [dsp.Resampler_Quality]f64{.Low = -50, .Medium = -80, .High = -110}
	for q in dsp.Resampler_Quality {
		// 48 → 32 kHz (speed 1.5): output Nyquist is 16 kHz.
		for f in ([]f64{17_500, 20_000, 23_000}) {
			x := make([]f32, 60_000, context.temp_allocator)
			kit.sine(x, 48_000, f, 1)
			y := resample(q, {x}, 1.5)
			level := kit.linear_to_db(kit.rms(y[0][2000:len(y[0]) - 2000]) * math.SQRT_TWO)
			log.infof("%v, %5.0f Hz into 32 kHz: %.1f dB", q, f, level)
			testing.expectf(t, level < limits[q], "%v: %v Hz leaks through at %.1f dB", q, f, level)
		}
	}
}

@(test)
resampler_passband_is_flat :: proc(t: ^testing.T) {
	edges := [dsp.Resampler_Quality]f64{.Low = 0.75, .Medium = 0.85, .High = 0.90}
	for q in dsp.Resampler_Quality {
		edge := edges[q]
		for frac in ([]f64{0.05, 0.3, 0.6, edge}) {
			f := frac * 16_000
			x := make([]f32, 48_000, context.temp_allocator)
			kit.sine(x, 48_000, f, 0.5)
			y := resample(q, {x}, 1.5)
			gain := kit.linear_to_db(kit.tone_amplitude(y[0][2000:30_000], 32_000, f) / 0.5)
			testing.expectf(t, abs(gain) < 0.05, "%v: %v Hz gain %.3f dB", q, f, gain)
		}
	}
}

// Speed changing on every call (varispeed): the output follows a sine whose
// phase advances by each frame's speed, with no clicks where speed changes.
@(test)
resampler_varispeed_is_continuous :: proc(t: ^testing.T) {
	x := make([]f32, 200_000, context.temp_allocator)
	kit.sine(x, 48_000, 300, 0.5)
	r: dsp.Resampler
	dsp.resampler_init(&r, 1, .High, max_speed = 4)
	defer dsp.resampler_destroy(&r)
	out := make([]f32, 64, context.temp_allocator)
	pos, at := 0.0, 0
	worst := 0.0
	for block in 0 ..< 1500 {
		speed := 1 + 0.9 * math.sin(f64(block) * 0.05) // 0.1 .. 1.9
		need := dsp.resampler_input_needed(&r, len(out), speed)
		used, made := dsp.resampler_process(&r, {x[at:at + need]}, {out}, speed)
		testing.expect_value(t, used, need)
		testing.expect_value(t, made, len(out))
		at += used
		for k in 0 ..< made {
			if block > 10 { // past the start-up silence
				want := 0.5 * math.sin(math.TAU * 300 * pos / 48_000)
				worst = max(worst, abs(f64(out[k]) - want))
			}
			pos += speed
		}
	}
	testing.expectf(t, worst < 1e-4, "varispeed off by %v", worst)
}

// The same input gives bit-identical output however it is split.
@(test)
resampler_block_size_invariance :: proc(t: ^testing.T) {
	x := [2][]f32{make([]f32, 30_000, context.temp_allocator), make([]f32, 30_000, context.temp_allocator)}
	kit.white_noise(x[0], 1, 0.5)
	kit.white_noise(x[1], 2, 0.5)
	a := resample(.High, x[:], 0.83, 512, 512)
	for split in ([][2]int{{1, 7}, {4096, 1}, {333, 1000}, {17, 4096}}) {
		b := resample(.High, x[:], 0.83, split[0], split[1])
		for c in 0 ..< 2 {
			cmp := kit.compare_slices(a[c], b[c])
			testing.expectf(t, cmp.max_abs_error == 0, "split %v: differs by %v at %d", split, cmp.max_abs_error, cmp.max_error_at)
		}
	}
}

@(test)
resampler_never_allocates_and_stays_finite :: proc(t: ^testing.T) {
	r: dsp.Resampler
	dsp.resampler_init(&r, 2, .High, max_speed = 4)
	defer dsp.resampler_destroy(&r)
	x := make([]f32, 4096, context.temp_allocator)
	kit.white_noise(x, 9, 1)
	out := [2][]f32{make([]f32, 4096, context.temp_allocator), make([]f32, 4096, context.temp_allocator)}
	trap: kit.Trap_Allocator
	{
		context.allocator = kit.trap_allocator(&trap)
		context.temp_allocator = context.allocator
		for i in 0 ..< 200 {
			speed := 0.25 + f64(i % 15) * 0.25
			dsp.resampler_process(&r, {x, x}, {out[0][:1 + i * 13 % 4000], out[1][:1 + i * 13 % 4000]}, speed)
			if i == 100 do dsp.resampler_reset(&r)
		}
	}
	testing.expect_value(t, trap.violations, 0)
	n, _ := kit.count_non_finite(out[0])
	testing.expect_value(t, n, 0)
}
