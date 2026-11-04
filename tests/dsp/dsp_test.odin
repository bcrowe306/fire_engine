package test_dsp

import "core:math"
import "core:path/filepath"
import "core:testing"

import "fire:core"
import "fire:dsp"
import kit "fire:testkit"

SR :: 48000.0

golden_dir :: proc() -> string {
	dir, _ := filepath.join({#directory, "..", "golden"}, context.temp_allocator)
	return dir
}

gain_factory :: kit.Node_Factory{create = proc(user: rawptr) -> core.Node { return dsp.gain_create() }}
one_pole_factory :: kit.Node_Factory{create = proc(user: rawptr) -> core.Node { return dsp.one_pole_create() }}

stereo_sine :: proc(frames: int, freq, amp: f64) -> kit.Audio_Buffer {
	b := kit.buffer_make(2, frames, SR, context.temp_allocator)
	kit.sine(b.channels[0], SR, freq, amp)
	kit.buffer_mono_to_all(b)
	return b
}

// --- smoother ------------------------------------------------------------------

@(test)
smoother_linear_reaches_target_exactly :: proc(t: ^testing.T) {
	s: dsp.Smoothed_Value
	dsp.smoothed_init(&s, 0, .Linear, 10, SR) // 480 samples
	dsp.smoothed_set_target(&s, 1)
	v: f64
	for _ in 0 ..< 479 do v = dsp.smoothed_next(&s)
	testing.expect(t, v < 1 && dsp.smoothed_is_smoothing(&s))
	testing.expect_value(t, dsp.smoothed_next(&s), 1)
	testing.expect(t, !dsp.smoothed_is_smoothing(&s))
}

@(test)
smoother_one_pole_converges :: proc(t: ^testing.T) {
	s: dsp.Smoothed_Value
	dsp.smoothed_init(&s, 0, .One_Pole, 10, SR)
	dsp.smoothed_set_target(&s, 1)
	v: f64
	for _ in 0 ..< 480 do v = dsp.smoothed_next(&s)
	kit.expect_near(t, v, 1 - 1 / 2.718281828, 0.01, "one time constant")
	for _ in 0 ..< 48000 do v = dsp.smoothed_next(&s)
	testing.expect_value(t, v, 1)
}

// --- gain ----------------------------------------------------------------------

@(test)
gain_unity_is_transparent :: proc(t: ^testing.T) {
	n := dsp.gain_create()
	defer core.node_destroy(&n)
	input := stereo_sine(4800, 440, 0.5)
	out, r := kit.render(&n, input, kit.default_render_config(), context.temp_allocator)
	defer kit.render_report_destroy(&r)
	kit.expect_clean_render(t, r)
	testing.expect_value(t, kit.compare_buffers(input, out).max_abs_error, 0)
}

@(test)
gain_param_change_is_sample_accurate_and_smooth :: proc(t: ^testing.T) {
	input := stereo_sine(48000, 220, 0.5)
	cfg := kit.default_render_config()
	cfg.events = {{10_000, core.Param_Value{dsp.GAIN_PARAM_DB, -6.0206}}}

	n := dsp.gain_create()
	defer core.node_destroy(&n)
	out, r := kit.render(&n, input, cfg, context.temp_allocator)
	defer kit.render_report_destroy(&r)
	kit.expect_clean_render(t, r)

	ch := out.channels[0]
	// Untouched before the event, exactly.
	testing.expect_value(t, kit.compare_slices(input.channels[0][:10_000], ch[:10_000]).max_abs_error, 0)
	// Ramp starts at the event frame: the sample at 10_000 already moved.
	testing.expect(t, ch[10_000] != input.channels[0][10_000] || input.channels[0][10_000] == 0)
	// Settled at half amplitude after the 20 ms ramp.
	kit.expect_near(t, kit.tone_amplitude(ch[20_000:], SR, 220), 0.25, 1e-3, "settled level")
	// No click: curvature stays within a clean sine's bound (+ margin for the ramp).
	c, at := kit.max_curvature(ch)
	bound := kit.sine_curvature_bound(0.5, 220, SR)
	testing.expectf(t, c < bound * 1.5, "click at frame %d: curvature %.3g > %.3g", at, c, bound * 1.5)
}

@(test)
gain_is_block_invariant :: proc(t: ^testing.T) {
	input := stereo_sine(12_000, 330, 0.7)
	cfg := kit.default_render_config()
	cfg.events = {
		{0, core.Param_Value{dsp.GAIN_PARAM_DB, -12}},
		{3_001, core.Param_Value{dsp.GAIN_PARAM_DB, 6}},
		{3_100, core.Param_Value{dsp.GAIN_PARAM_DB, -96}}, // interrupts the previous ramp
		{9_999, core.Param_Value{dsp.GAIN_PARAM_DB, 0}},
	}
	patterns := kit.standard_block_patterns(cfg.max_block)
	kit.expect_block_invariant(t, gain_factory, input, cfg, patterns[:], 0, "gain")
}

// An automation ramp is followed exactly, without the 20 ms smoothing: the
// event's frame keeps the old gain, `frames` later the new one, linear in
// dB between. A zero-length ramp is an exact jump.
@(test)
gain_follows_ramps_exactly :: proc(t: ^testing.T) {
	input := kit.buffer_make(1, 8_000, SR, context.temp_allocator)
	for &v in input.channels[0] do v = 1
	cfg := kit.default_render_config()
	cfg.out_channels = 1
	half := 20 * math.log10(0.5)
	cfg.events = {
		{1_000, core.Param_Ramp{dsp.GAIN_PARAM_DB, half, 1_000}},
		{5_000, core.Param_Ramp{dsp.GAIN_PARAM_DB, 0, 0}},
	}
	n := dsp.gain_create()
	defer core.node_destroy(&n)
	out, r := kit.render(&n, input, cfg, context.temp_allocator)
	defer kit.render_report_destroy(&r)
	kit.expect_clean_render(t, r)
	ch := out.channels[0]
	worst: f64
	for i in 0 ..< 8_000 {
		want := 1.0
		if i >= 1_000 && i < 2_000 do want = math.pow(10, half * f64(i - 1_000) / 1_000 / 20)
		if i >= 2_000 && i < 5_000 do want = 0.5
		worst = max(worst, abs(f64(ch[i]) - want))
	}
	testing.expectf(t, worst < 1e-6, "off the ramp by %.3g", worst)
	testing.expect_value(t, ch[4_999], 0.5)
	testing.expect_value(t, ch[5_000], 1)
	patterns := kit.standard_block_patterns(cfg.max_block)
	kit.expect_block_invariant(t, gain_factory, input, cfg, patterns[:], 0, "gain ramps")
}

// A ramp interrupts smoothing in progress, and a Param_Value interrupts a
// ramp, in every smoothing mode.
@(test)
smoothed_value_ramps :: proc(t: ^testing.T) {
	for mode in core.Param_Smoothing {
		s: dsp.Smoothed_Value
		dsp.smoothed_init(&s, 0, mode, 10, SR)
		dsp.smoothed_set_target(&s, 1) // smoothing toward 1 (or there already)
		for _ in 0 ..< 5 do dsp.smoothed_next(&s)
		start := s.current
		dsp.smoothed_ramp(&s, 2, 4)
		got: [5]f64
		for &g in got do g = dsp.smoothed_next(&s)
		step := (2 - start) / 4
		for g, k in got[:4] do testing.expectf(t, abs(g - (start + f64(k) * step)) < 1e-12, "%v: frame %d of the ramp is %v", mode, k, g)
		testing.expectf(t, got[4] == 2, "%v: after the ramp %v", mode, got[4])
		dsp.smoothed_ramp(&s, 3, 100)
		dsp.smoothed_next(&s)
		dsp.smoothed_set_target(&s, -1) // back to the mode's own smoothing
		testing.expect_value(t, s.ramp_left, 0)
	}
}

// --- one-pole lowpass -------------------------------------------------------------

@(test)
one_pole_frequency_response :: proc(t: ^testing.T) {
	n := dsp.one_pole_create()
	defer core.node_destroy(&n)
	input := kit.buffer_make(1, 1 << 15, SR, context.temp_allocator)
	kit.impulse(input.channels[0])
	cfg := kit.default_render_config()
	cfg.out_channels = 1
	ir, r := kit.render(&n, input, cfg, context.temp_allocator) // cutoff defaults to 1 kHz
	defer kit.render_report_destroy(&r)
	kit.expect_clean_render(t, r)

	h := ir.channels[0]
	kit.expect_near(t, kit.response_db(h, SR, 0), 0, 1e-3, "DC gain")
	kit.expect_near(t, kit.response_db(h, SR, 1000), -3.0103, 1e-3, "-3 dB at cutoff")
	// 1st order: ~-6 dB/octave well above cutoff (bilinear warping makes it steeper near Nyquist)
	slope := kit.response_db(h, SR, 8000) - kit.response_db(h, SR, 4000)
	kit.expect_near(t, slope, -6.0, 0.6, "octave slope 4k->8k")
	testing.expect(t, kit.response_db(h, SR, 23_999) < -60, "TPT lowpass has a zero at Nyquist")
}

@(test)
one_pole_cutoff_sweep_is_block_invariant :: proc(t: ^testing.T) {
	input := kit.buffer_make(2, 24_000, SR, context.temp_allocator)
	kit.white_noise(input.channels[0], 42, 0.5)
	kit.white_noise(input.channels[1], 43, 0.5)
	cfg := kit.default_render_config()
	cfg.events = {
		{5_000, core.Param_Value{dsp.ONE_POLE_PARAM_CUTOFF_HZ, 200}},
		{12_345, core.Param_Value{dsp.ONE_POLE_PARAM_CUTOFF_HZ, 8000}},
	}
	patterns := kit.standard_block_patterns(cfg.max_block)
	kit.expect_block_invariant(t, one_pole_factory, input, cfg, patterns[:], 0, "one_pole")
}

// Golden regression: any change to the filter's output shows up here.
@(test)
one_pole_golden_pink_noise :: proc(t: ^testing.T) {
	n := dsp.one_pole_create()
	defer core.node_destroy(&n)
	input := kit.buffer_make(1, 9_600, SR, context.temp_allocator)
	kit.pink_noise(input.channels[0], 2026, 0.5)
	cfg := kit.default_render_config()
	cfg.out_channels = 1
	cfg.events = {{4_800, core.Param_Value{dsp.ONE_POLE_PARAM_CUTOFF_HZ, 300}}}
	out, r := kit.render(&n, input, cfg, context.temp_allocator)
	defer kit.render_report_destroy(&r)
	kit.expect_clean_render(t, r)
	kit.expect_golden(t, golden_dir(), "one_pole_pink_noise", out, tolerance = 1e-6)
}

@(test)
one_pole_stays_fast_with_denormal_input :: proc(t: ^testing.T) {
	n := dsp.one_pole_create()
	defer core.node_destroy(&n)
	input := kit.buffer_make(1, 48_000, SR, context.temp_allocator)
	kit.impulse(input.channels[0], 0, 1e-30) // decays straight into the denormal range
	cfg := kit.default_render_config()
	cfg.out_channels = 1
	_, r := kit.render(&n, input, cfg, context.temp_allocator)
	defer kit.render_report_destroy(&r)
	kit.expect_clean_render(t, r)
	testing.expect_value(t, r.denormals, 0)
}
