package test_dsp

import "core:math"
import "core:testing"

import "fire:core"
import "fire:dsp"
import kit "fire:testkit"

FREQS := [?]f64{20, 50, 100, 300, 700, 1000, 1500, 3000, 6000, 10_000, 16_000, 20_000}

Design :: struct {
	mode:         dsp.Filter_Mode,
	fc, q, gain:  f64,
}

DESIGNS := [?]Design {
	{.Lowpass, 1000, 0.7071, 0}, {.Lowpass, 200, 5, 0},
	{.Highpass, 1000, 0.7071, 0}, {.Highpass, 5000, 2, 0},
	{.Bandpass, 1000, 2, 0}, {.Notch, 1000, 1, 0}, {.Peak, 800, 3, 0},
	{.Allpass, 1000, 0.7071, 0}, {.Bell, 1000, 1, 9}, {.Bell, 3000, 4, -12},
	{.Low_Shelf, 1000, 0.7071, 6}, {.Low_Shelf, 300, 0.7071, -10},
	{.High_Shelf, 1000, 0.7071, 6}, {.High_Shelf, 6000, 0.7071, -8},
}

db :: proc(gain: f64) -> f64 { return 20 * math.log10(max(gain, 1e-12)) }

// The impulse response of an SVF design, run sample by sample.
svf_ir :: proc(c: dsp.Svf_Coeffs, n := 1 << 15) -> []f32 {
	c := c
	s: dsp.Svf_State
	ir := make([]f32, n, context.temp_allocator)
	for &x, i in ir do x = f32(dsp.svf_tick(&c, &s, 1 if i == 0 else 0))
	return ir
}

@(test)
svf_runs_as_its_response_says :: proc(t: ^testing.T) {
	for d in DESIGNS {
		c := dsp.svf_design(d.mode, d.fc, d.q, d.gain, SR)
		ir := svf_ir(c)
		for f in FREQS {
			want, _ := dsp.svf_response(&c, f, SR)
			if db(want) < -60 do continue // the measurement's own noise floor
			kit.expect_near(t, kit.response_db(ir, SR, f), db(want), 0.01, "measured vs svf_response")
		}
	}
}

@(test)
svf_modes_meet_their_definitions :: proc(t: ^testing.T) {
	at :: proc(mode: dsp.Filter_Mode, fc, q, gain, f: f64) -> f64 {
		c := dsp.svf_design(mode, fc, q, gain, SR)
		g, _ := dsp.svf_response(&c, f, SR)
		return db(g)
	}
	kit.expect_near(t, at(.Lowpass, 1000, math.SQRT_TWO / 2, 0, 1000), -3.0103, 1e-3, "lowpass −3 dB at cutoff")
	kit.expect_near(t, at(.Lowpass, 1000, math.SQRT_TWO / 2, 0, 20), 0, 1e-3, "lowpass passes lows")
	kit.expect_near(t, at(.Highpass, 1000, math.SQRT_TWO / 2, 0, 1000), -3.0103, 1e-3, "highpass −3 dB at cutoff")
	kit.expect_near(t, at(.Bandpass, 1000, 3, 0, 1000), 0, 1e-9, "bandpass 0 dB at centre")
	testing.expect(t, at(.Notch, 1000, 1, 0, 1000) < -100, "notch at centre")
	for f in FREQS do kit.expect_near(t, at(.Allpass, 1000, 1, 0, f), 0, 1e-9, "allpass is flat")
	kit.expect_near(t, at(.Bell, 2000, 2, 7.5, 2000), 7.5, 1e-9, "bell gain at centre")
	kit.expect_near(t, at(.Bell, 2000, 2, -7.5, 2000), -7.5, 1e-9, "bell cut at centre")
	kit.expect_near(t, at(.Low_Shelf, 1000, 0.7071, 6, 1000), 3, 1e-6, "low shelf half gain at cutoff")
	kit.expect_near(t, at(.Low_Shelf, 1000, 0.7071, 6, 20), 6, 0.01, "low shelf gain below")
	kit.expect_near(t, at(.High_Shelf, 1000, 0.7071, -6, 1000), -3, 1e-6, "high shelf half gain at cutoff")
	kit.expect_near(t, at(.High_Shelf, 1000, 0.7071, -6, 20_000), -6, 0.05, "high shelf gain above")
}

@(test)
biquad_matches_svf :: proc(t: ^testing.T) {
	for d in DESIGNS {
		s := dsp.svf_design(d.mode, d.fc, d.q, d.gain, SR)
		b := dsp.biquad_design(d.mode, d.fc, d.q, d.gain, SR)
		for f in FREQS {
			gs, _ := dsp.svf_response(&s, f, SR)
			gb, _ := dsp.biquad_response(&b, f, SR)
			if db(gs) < -80 do continue
			testing.expectf(t, abs(db(gs) - db(gb)) < 1e-6, "%v at %.0f Hz: svf %.6f dB, biquad %.6f dB", d, f, db(gs), db(gb))
		}
		// And running it gives that response.
		ir := make([]f32, 1 << 15, context.temp_allocator)
		st: dsp.Biquad_State
		for &x, i in ir do x = f32(dsp.biquad_tick(&b, &st, 1 if i == 0 else 0))
		for f in FREQS {
			want, _ := dsp.biquad_response(&b, f, SR)
			if db(want) > -60 do kit.expect_near(t, kit.response_db(ir, SR, f), db(want), 0.01, "biquad measured")
		}
	}
}

// Cutoff jumping across the spectrum every 37 samples at Q 20: the TPT
// structure keeps it bounded where a biquad would ring or blow up.
@(test)
svf_survives_wild_modulation :: proc(t: ^testing.T) {
	s: dsp.Svf_State
	seed := u64(5)
	peak := 0.0
	for i in 0 ..< 200_000 {
		fc := 20.0 if (i / 37) % 2 == 0 else 19_000
		c := dsp.svf_design(.Lowpass, fc * (1 + 0.1 * math.sin(f64(i) * 0.01)), 20, 0, SR)
		seed = seed * 6364136223846793005 + 1442695040888963407
		x := f64(i64(seed >> 11)) / f64(1 << 52) - 1
		y := dsp.svf_tick(&c, &s, x)
		peak = max(peak, abs(y))
	}
	testing.expect(t, !math.is_nan(peak) && !math.is_inf(peak))
	testing.expectf(t, peak < 100, "peak %v", peak) // resonance at Q 20 is at most 20× a full-scale input, plus transients
}

filter_factory :: kit.Node_Factory{create = proc(user: rawptr) -> core.Node { return dsp.filter_create() }}

@(test)
filter_node_is_clean_and_block_invariant :: proc(t: ^testing.T) {
	input := kit.buffer_make(2, 30_000, SR, context.temp_allocator)
	kit.white_noise(input.channels[0], 7, 0.5)
	kit.white_noise(input.channels[1], 8, 0.5)
	cfg := kit.default_render_config()
	cfg.events = {
		{3_000, core.Param_Value{dsp.FILTER_PARAM_CUTOFF_HZ, 300}},
		{7_777, core.Param_Ramp{dsp.FILTER_PARAM_CUTOFF_HZ, 9000, 5000}},
		{9_000, core.Param_Value{dsp.FILTER_PARAM_Q, 8}},
		{15_000, core.Param_Value{dsp.FILTER_PARAM_MODE, f64(dsp.Filter_Mode.Bell)}},
		{15_000, core.Param_Value{dsp.FILTER_PARAM_GAIN_DB, 9}},
		{22_222, core.Param_Value{dsp.FILTER_PARAM_MODE, f64(dsp.Filter_Mode.Highpass)}},
	}
	patterns := kit.standard_block_patterns(cfg.max_block)
	kit.expect_block_invariant(t, filter_factory, input, cfg, patterns[:], 0, "filter")
}

@(test)
filter_node_has_the_designed_response :: proc(t: ^testing.T) {
	n := dsp.filter_create(.Bell)
	defer core.node_destroy(&n)
	input := kit.buffer_make(1, 1 << 15, SR, context.temp_allocator)
	kit.impulse(input.channels[0], 4800) // after the parameter has settled
	cfg := kit.default_render_config()
	cfg.out_channels = 1
	cfg.events = {{0, core.Param_Value{dsp.FILTER_PARAM_GAIN_DB, -9}}, {0, core.Param_Value{dsp.FILTER_PARAM_CUTOFF_HZ, 2500}}}
	out, r := kit.render(&n, input, cfg, context.temp_allocator)
	defer kit.render_report_destroy(&r)
	kit.expect_clean_render(t, r)
	c := dsp.svf_design(.Bell, 2500, 0.707, -9, SR)
	for f in FREQS {
		want, _ := dsp.svf_response(&c, f, SR)
		kit.expect_near(t, kit.response_db(out.channels[0][4800:], SR, f), db(want), 0.01, "bell node")
	}
}

eq_factory :: kit.Node_Factory{create = proc(user: rawptr) -> core.Node { return dsp.eq_create(6) }}

@(test)
eq_is_the_product_of_its_bands :: proc(t: ^testing.T) {
	n := dsp.eq_create(4)
	defer core.node_destroy(&n)
	input := kit.buffer_make(2, 1 << 15, SR, context.temp_allocator)
	kit.impulse(input.channels[0], 4800)
	kit.impulse(input.channels[1], 4800)
	cfg := kit.default_render_config()
	b := dsp.eq_band_param
	cfg.events = {
		{0, core.Param_Value{b(0, .Gain_Db), 6}},
		{0, core.Param_Value{b(1, .Gain_Db), -9}}, {0, core.Param_Value{b(1, .Q), 3}},
		{0, core.Param_Value{b(2, .Mode), f64(dsp.Filter_Mode.Notch)}}, {0, core.Param_Value{b(2, .Freq_Hz), 5000}},
		{0, core.Param_Value{b(3, .On), 0}},
		{0, core.Param_Value{dsp.EQ_PARAM_OUTPUT_DB, -2}},
	}
	out, r := kit.render(&n, input, cfg, context.temp_allocator)
	defer kit.render_report_destroy(&r)
	kit.expect_clean_render(t, r)
	bands := [3]dsp.Svf_Coeffs{
		dsp.svf_design(.Low_Shelf, 100, 0.707, 6, SR),
		dsp.svf_design(.Bell, 100 * math.pow(80, 1.0 / 3), 3, -9, SR),
		dsp.svf_design(.Notch, 5000, 0.707, 0, SR),
	}
	for f in FREQS {
		want := -2.0
		for &c in bands {
			g, _ := dsp.svf_response(&c, f, SR)
			want += db(g)
		}
		if want < -60 do continue
		kit.expect_near(t, kit.response_db(out.channels[0][4800:], SR, f), want, 0.01, "eq")
		kit.expect_near(t, db(dsp.eq_response((^dsp.Eq)(n.data), f)), want, 1e-9, "eq_response")
	}
}

@(test)
eq_is_clean_and_block_invariant :: proc(t: ^testing.T) {
	input := kit.buffer_make(2, 24_000, SR, context.temp_allocator)
	kit.white_noise(input.channels[0], 11, 0.5)
	kit.white_noise(input.channels[1], 12, 0.5)
	cfg := kit.default_render_config()
	b := dsp.eq_band_param
	cfg.events = {
		{1_000, core.Param_Value{b(0, .Gain_Db), 8}},
		{4_321, core.Param_Ramp{b(2, .Freq_Hz), 12_000, 9000}},
		{6_000, core.Param_Value{b(4, .On), 0}},
		{18_000, core.Param_Value{b(4, .On), 1}},
		{20_000, core.Param_Value{dsp.EQ_PARAM_OUTPUT_DB, -6}},
	}
	patterns := kit.standard_block_patterns(cfg.max_block)
	kit.expect_block_invariant(t, eq_factory, input, cfg, patterns[:], 0, "eq")
}

// After a ramp, a filter runs at the ramp's target exactly (its last step
// must not be left as the coefficient).
@(test)
ramps_end_on_their_target :: proc(t: ^testing.T) {
	cases := []struct { make: proc() -> core.Node, param: core.Param_Id, setup: core.Param_Id, value: f64 } {
		{proc() -> core.Node { return dsp.one_pole_create() }, dsp.ONE_POLE_PARAM_CUTOFF_HZ, dsp.ONE_POLE_PARAM_CUTOFF_HZ, 1000},
		{proc() -> core.Node { return dsp.filter_create() }, dsp.FILTER_PARAM_CUTOFF_HZ, dsp.FILTER_PARAM_Q, 4},
		{proc() -> core.Node { return dsp.eq_create(1) }, dsp.eq_band_param(0, .Freq_Hz), dsp.eq_band_param(0, .Gain_Db), 12},
	}
	for c in cases {
		ramped, direct := c.make(), c.make()
		defer core.node_destroy(&ramped)
		defer core.node_destroy(&direct)
		input := kit.buffer_make(1, 20_000, SR, context.temp_allocator)
		kit.impulse(input.channels[0], 12_000)
		cfg := kit.default_render_config()
		cfg.out_channels = 1
		cfg.events = {{0, core.Param_Value{c.setup, c.value}}, {100, core.Param_Ramp{c.param, 3000, 2000}}}
		a, r1 := kit.render(&ramped, input, cfg, context.temp_allocator)
		defer kit.render_report_destroy(&r1)
		cfg.events = {{0, core.Param_Value{c.setup, c.value}}, {100, core.Param_Ramp{c.param, 3000, 0}}} // an exact set
		b, r2 := kit.render(&direct, input, cfg, context.temp_allocator)
		defer kit.render_report_destroy(&r2)
		testing.expect_value(t, kit.compare_slices(a.channels[0][12_000:], b.channels[0][12_000:]).max_abs_error, 0)
		testing.expect(t, abs(kit.response_db(a.channels[0][12_000:], SR, 3000)) > 1, "the parameter has an effect") // not a vacuous match
	}
}
