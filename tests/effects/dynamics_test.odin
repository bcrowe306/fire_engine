package test_effects

import "core:math"
import "core:testing"

import "fire:core"
import "fire:dsp"
import kit "fire:testkit"

@(test)
compressor_curve_is_giannoulis :: proc(t: ^testing.T) {
	testing.expect_value(t, dsp.compressor_curve(-30, -20, 4, 0), 0)
	kit.expect_near(t, dsp.compressor_curve(-10, -20, 4, 0), 7.5, 1e-12, "10 dB over at 4:1")
	kit.expect_near(t, dsp.compressor_curve(-20, -20, 4, 6), 0.75 * 6 / 8, 1e-12, "soft knee at the threshold")
	// The knee meets the straight lines at its edges.
	kit.expect_near(t, dsp.compressor_curve(-23, -20, 4, 6), 0, 1e-12, "knee start")
	kit.expect_near(t, dsp.compressor_curve(-17, -20, 4, 6), 0.75 * 3, 1e-12, "knee end")
	kit.expect_near(t, dsp.expander_curve(-50, -40, 2, 0, 96), 10, 1e-12, "1 dB down per dB under at 2:1")
	kit.expect_near(t, dsp.expander_curve(-80, -40, 100, 0, 30), 30, 1e-12, "limited by the range")
	testing.expect_value(t, dsp.expander_curve(-30, -40, 100, 0, 96), 0)
}

// A node rendered with `events`, input channels from `input`.
render_node :: proc(t: ^testing.T, n: ^core.Node, input: kit.Audio_Buffer, out_channels: int, events: []kit.Timed_Event = nil) -> kit.Audio_Buffer {
	cfg := kit.default_render_config()
	cfg.out_channels = out_channels
	cfg.events = events
	out, r := kit.render(n, input, cfg, context.temp_allocator)
	defer kit.render_report_destroy(&r)
	kit.expect_clean_render(t, r)
	return out
}

@(test)
compressor_attacks_and_releases_on_time :: proc(t: ^testing.T) {
	// A step of DC from silence to 0 dBFS, then down to −40 dB: with no knee
	// at 20:1, the target reduction is 19 dB, and the smoother covers 63% of
	// it in the attack time, then lets 63% of it go in the release time.
	n := dsp.compressor_create()
	defer core.node_destroy(&n)
	input := kit.buffer_make(1, 48_000, SR, context.temp_allocator)
	for &x, i in input.channels[0] do x = 1 if i < 24_000 else 0.01
	out := render_node(t, &n, input, 1, {
		{0, core.Param_Value{dsp.COMPRESSOR_PARAM_KNEE_DB, 0}},
		{0, core.Param_Value{dsp.COMPRESSOR_PARAM_RATIO, 20}},
		{0, core.Param_Value{dsp.COMPRESSOR_PARAM_ATTACK_MS, 10}},
		{0, core.Param_Value{dsp.COMPRESSOR_PARAM_RELEASE_MS, 50}},
	})
	y := out.channels[0]
	reduction :: proc(y: f32, x: f32) -> f64 { return -20 * math.log10(f64(y / x)) }
	kit.expect_near(t, reduction(y[480 - 1], 1), 19 * (1 - math.exp(-1.0)), 0.01, "63% after the attack")
	kit.expect_near(t, reduction(y[23_999], 1), 19, 0.01, "settled")
	kit.expect_near(t, reduction(y[24_000 + 2400 - 1], 0.01), 19 * math.exp(-1.0), 0.01, "37% left after the release")
}

@(test)
compressor_steady_state_follows_the_curve :: proc(t: ^testing.T) {
	n := dsp.compressor_create()
	defer core.node_destroy(&n)
	input := kit.buffer_make(2, 96_000, SR, context.temp_allocator)
	kit.sine(input.channels[0], SR, 1000, 0.5) // −6 dBFS peak
	kit.buffer_mono_to_all(input)
	out := render_node(t, &n, input, 2, {
		{0, core.Param_Value{dsp.COMPRESSOR_PARAM_KNEE_DB, 0}},
		{0, core.Param_Value{dsp.COMPRESSOR_PARAM_ATTACK_MS, 1}},
		{0, core.Param_Value{dsp.COMPRESSOR_PARAM_RELEASE_MS, 1000}},
		{0, core.Param_Value{dsp.COMPRESSOR_PARAM_MAKEUP_DB, 3}},
	})
	want := -6.0206 - dsp.compressor_curve(-6.0206, -20, 4, 0) + 3
	kit.expect_near(t, kit.linear_to_db(f64(kit.peak(out.channels[0][48_000:]))), want, 0.1, "−6 dBFS, 14 dB over at 4:1, +3 dB makeup")
	kit.expect_near(t, dsp.compressor_gain_reduction_db((^dsp.Compressor)(n.data)), dsp.compressor_curve(-6.0206, -20, 4, 0), 0.1, "meter")
}

@(test)
compressor_sidechain_and_mix :: proc(t: ^testing.T) {
	// Main: quiet. Sidechain (inputs 2 and 3): loud DC. Fully wet the main is
	// turned down by the sidechain's 19 dB; at 50% mix, by half the gain.
	for mix in ([]f64{100, 50}) {
		n := dsp.compressor_create()
		defer core.node_destroy(&n)
		input := kit.buffer_make(4, 24_000, SR, context.temp_allocator)
		for c in 0 ..< 2 do for &x in input.channels[c] do x = 0.01
		for c in 2 ..< 4 do for &x in input.channels[c] do x = 1
		out := render_node(t, &n, input, 2, {
			{0, core.Param_Value{dsp.COMPRESSOR_PARAM_KNEE_DB, 0}},
			{0, core.Param_Value{dsp.COMPRESSOR_PARAM_RATIO, 20}},
			{0, core.Param_Value{dsp.COMPRESSOR_PARAM_MIX, mix}},
		})
		wet := math.pow(10, -19.0 / 20)
		want := 0.01 * (mix / 100 * wet + (1 - mix / 100))
		kit.expect_near(t, f64(out.channels[1][23_999]), want, 1e-6, "compressed by the sidechain")
	}
}

compressor_factory :: kit.Node_Factory{create = proc(user: rawptr) -> core.Node { return dsp.compressor_create() }}
gate_factory :: kit.Node_Factory{create = proc(user: rawptr) -> core.Node { return dsp.gate_create() }}
limiter_factory :: kit.Node_Factory{create = proc(user: rawptr) -> core.Node { return dsp.limiter_create() }}

// Noise in bursts at very different levels: something for every dynamics node to do.
bursts :: proc(frames: int) -> kit.Audio_Buffer {
	b := kit.buffer_make(2, frames, SR, context.temp_allocator)
	kit.white_noise(b.channels[0], 21, 1)
	kit.white_noise(b.channels[1], 22, 1)
	levels := [4]f32{0.002, 1, 0.05, 3}
	for c in 0 ..< 2 do for &x, i in b.channels[c] do x *= levels[(i / 3000) % 4]
	return b
}

@(test)
dynamics_nodes_are_block_invariant :: proc(t: ^testing.T) {
	input := bursts(30_000)
	cfg := kit.default_render_config()
	patterns := kit.standard_block_patterns(cfg.max_block)
	cfg.events = {{7_000, core.Param_Value{dsp.COMPRESSOR_PARAM_THRESHOLD_DB, -30}}, {11_111, core.Param_Ramp{dsp.COMPRESSOR_PARAM_MAKEUP_DB, 6, 3000}}, {20_000, core.Param_Value{dsp.COMPRESSOR_PARAM_DETECTOR, 1}}}
	kit.expect_block_invariant(t, compressor_factory, input, cfg, patterns[:], 0, "compressor")
	cfg.events = {{9_000, core.Param_Value{dsp.GATE_PARAM_THRESHOLD_DB, -20}}, {15_000, core.Param_Value{dsp.GATE_PARAM_RATIO, 3}}}
	kit.expect_block_invariant(t, gate_factory, input, cfg, patterns[:], 0, "gate")
	cfg.events = {{5_000, core.Param_Ramp{dsp.LIMITER_PARAM_INPUT_DB, 12, 4000}}, {18_000, core.Param_Value{dsp.LIMITER_PARAM_CEILING_DB, -6}}}
	kit.expect_block_invariant(t, limiter_factory, input, cfg, patterns[:], 0, "limiter")
}

@(test)
gate_opens_holds_and_closes :: proc(t: ^testing.T) {
	n := dsp.gate_create()
	defer core.node_destroy(&n)
	// DC: −60 dB (closed), 0 dB from 0.1 s (opens), then −42 dB from 0.3 s:
	// under the threshold (−40) but within the hysteresis (4 dB), so it stays
	// open; then −60 dB from 0.5 s, so it closes after the 20 ms hold.
	input := kit.buffer_make(1, 36_000, SR, context.temp_allocator)
	for &x, i in input.channels[0] {
		x = 0.001
		if i >= 4_800 && i < 14_400 do x = 1
		if i >= 14_400 && i < 24_000 do x = f32(math.pow(10, -42.0 / 20))
	}
	out := render_node(t, &n, input, 1)
	y := out.channels[0]
	testing.expectf(t, y[4_000] < 1e-6, "closed at first: %v", y[4_000])
	kit.expect_near(t, f64(y[14_000]), 1, 1e-4, "open")
	kit.expect_near(t, kit.linear_to_db(f64(y[23_000])), -42, 0.01, "still open within the hysteresis")
	kit.expect_near(t, f64(y[24_000 + 900]), 0.001, 1e-5, "held 20 ms after it fell")
	testing.expectf(t, y[35_000] < 1e-6, "closed: %v", y[35_000])
}

@(test)
limiter_never_exceeds_the_ceiling :: proc(t: ^testing.T) {
	n := dsp.limiter_create(5)
	defer core.node_destroy(&n)
	input := bursts(96_000)
	input.channels[0][40_000] = 40 // a lone spike, 32 dB over
	out := render_node(t, &n, input, 2, {{0, core.Param_Value{dsp.LIMITER_PARAM_INPUT_DB, 12}}, {0, core.Param_Value{dsp.LIMITER_PARAM_CEILING_DB, -1}}})
	ceiling := math.pow(10, -1.0 / 20)
	for c in 0 ..< 2 {
		p := kit.peak(out.channels[c])
		testing.expectf(t, p <= ceiling * (1 + 1e-6), "channel %d peak %v over the ceiling %v", c, p, ceiling)
	}
	testing.expect(t, dsp.limiter_gain_reduction_db((^dsp.Limiter)(n.data)) > 0)
}

@(test)
limiter_is_transparent_below_the_ceiling :: proc(t: ^testing.T) {
	n := dsp.limiter_create(5)
	defer core.node_destroy(&n)
	input := kit.buffer_make(2, 24_000, SR, context.temp_allocator)
	kit.sine(input.channels[0], SR, 440, 0.5)
	kit.buffer_mono_to_all(input)
	out := render_node(t, &n, input, 2)
	lat := core.node_latency(&n)
	testing.expect_value(t, lat, 239) // 5 ms at 48 kHz, less one (known once prepared)
	diff := kit.compare_slices(out.channels[0][lat:], input.channels[0][:24_000 - lat])
	testing.expect_value(t, diff.max_abs_error, 0) // the input, exactly, `latency` frames later
}
