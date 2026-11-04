package test_dsp

import "core:testing"

import "fire:core"
import "fire:dsp"
import kit "fire:testkit"

// The direct convolution, in f64.
direct_convolution :: proc(x, h: []f32) -> []f64 {
	y := make([]f64, len(x), context.temp_allocator)
	for n in 0 ..< len(x) {
		s := 0.0
		for k in 0 ..< min(len(h), n + 1) do s += f64(h[k]) * f64(x[n - k])
		y[n] = s
	}
	return y
}

@(test)
convolver_matches_direct_convolution :: proc(t: ^testing.T) {
	x := make([]f32, 12_000, context.temp_allocator)
	kit.white_noise(x, 77, 0.5)
	for length in ([]int{1, 63, 64, 65, 2047, 2048, 2049, 5000}) {
		h := make([]f32, length, context.temp_allocator)
		kit.white_noise(h, u64(length), 1)
		for i in 0 ..< length do h[i] *= f32(1 - f64(i) / f64(length)) // a decay, like a room
		want := direct_convolution(x, h)
		peak := 0.0
		for v in want do peak = max(peak, abs(v))
		for chunks in ([][]int{{12_000}, {1}, {7, 300, 64, 1}}) {
			c: dsp.Convolver
			if !testing.expect_value(t, dsp.convolver_init(&c, h), core.Error.None) do continue
			y := make([]f32, len(x), context.temp_allocator)
			for at, k := 0, 0; at < len(x); k += 1 {
				n := min(chunks[k % len(chunks)], len(x) - at)
				dsp.convolver_process(&c, x[at:][:n], y[at:][:n])
				at += n
			}
			dsp.convolver_destroy(&c)
			worst, worst_at := 0.0, 0
			for v, i in y do if e := abs(f64(v) - want[i]); e > worst do worst, worst_at = e, i
			testing.expectf(t, worst <= 2e-6 * peak, "%d taps, chunks %v: error %v at %d (peak %v)", length, chunks, worst, worst_at, peak)
		}
	}
}

@(test)
convolver_has_no_latency_and_is_chunk_invariant :: proc(t: ^testing.T) {
	h := make([]f32, 30_000, context.temp_allocator)
	kit.white_noise(h, 5, 0.3)
	h[0] = 1
	x := make([]f32, 40_000, context.temp_allocator)
	kit.white_noise(x, 6, 0.5)
	outs: [2][]f32
	for chunks, i in ([2][]int{{40_000}, {1, 2, 3, 511, 64}}) {
		c: dsp.Convolver
		dsp.convolver_init(&c, h)
		defer dsp.convolver_destroy(&c)
		outs[i] = make([]f32, len(x), context.temp_allocator)
		for at, k := 0, 0; at < len(x); k += 1 {
			n := min(chunks[k % len(chunks)], len(x) - at)
			dsp.convolver_process(&c, x[at:][:n], outs[i][at:][:n])
			at += n
		}
	}
	testing.expect_value(t, outs[0][0], x[0]) // h[0] = 1: the first input comes straight out
	testing.expect_value(t, kit.compare_slices(outs[0], outs[1]).max_abs_error, 0)
}

convolution_factory :: kit.Node_Factory{create = proc(user: rawptr) -> core.Node {
	ir := make([]f32, 9000, context.temp_allocator)
	kit.white_noise(ir, 9, 0.2)
	return dsp.convolution_create({ir})
}}

@(test)
convolution_node_is_clean_and_block_invariant :: proc(t: ^testing.T) {
	input := kit.buffer_make(2, 24_000, SR, context.temp_allocator)
	kit.white_noise(input.channels[0], 41, 0.5)
	kit.white_noise(input.channels[1], 42, 0.5)
	cfg := kit.default_render_config()
	cfg.events = {{8_000, core.Param_Value{dsp.CONVOLUTION_PARAM_MIX, 40}}, {16_000, core.Param_Ramp{dsp.CONVOLUTION_PARAM_WET_DB, -6, 3000}}}
	patterns := kit.standard_block_patterns(cfg.max_block)
	kit.expect_block_invariant(t, convolution_factory, input, cfg, patterns[:], 0, "convolution")
}
