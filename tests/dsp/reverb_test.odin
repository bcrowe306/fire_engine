package test_dsp

import "core:math"
import "core:testing"

import "fire:core"
import "fire:dsp"
import kit "fire:testkit"

reverb_ir :: proc(t: ^testing.T, seconds: f64, events: []kit.Timed_Event) -> kit.Audio_Buffer {
	n := dsp.reverb_create()
	defer core.node_destroy(&n)
	input := kit.buffer_make(2, int(seconds * SR), SR, context.temp_allocator)
	kit.impulse(input.channels[0])
	kit.impulse(input.channels[1])
	cfg := kit.default_render_config()
	cfg.events = events
	out, r := kit.render(&n, input, cfg, context.temp_allocator)
	defer kit.render_report_destroy(&r)
	kit.expect_clean_render(t, r)
	return out
}

// RT60 from a response's Schroeder energy decay curve: the slope between
// −5 and −25 dB, extended to 60 dB (T20).
rt60 :: proc(ir: []f32) -> f64 {
	edc := make([]f64, len(ir), context.temp_allocator)
	s := 0.0
	for i := len(ir) - 1; i >= 0; i -= 1 {
		s += f64(ir[i]) * f64(ir[i])
		edc[i] = s
	}
	t5, t25 := -1, -1
	for e, i in edc {
		db := 10 * math.log10(e / edc[0])
		if t5 < 0 && db <= -5 do t5 = i
		if t25 < 0 && db <= -25 {
			t25 = i
			break
		}
	}
	return f64(t25 - t5) / SR * 3
}

reverb_setup :: proc(decay, hf: f64) -> []kit.Timed_Event {
	ev := make([]kit.Timed_Event, 5, context.temp_allocator)
	ev[0] = {0, core.Param_Value{dsp.REVERB_PARAM_DECAY_S, decay}}
	ev[1] = {0, core.Param_Value{dsp.REVERB_PARAM_HF_DECAY, hf}}
	ev[2] = {0, core.Param_Value{dsp.REVERB_PARAM_MODULATION, 0}}
	ev[3] = {0, core.Param_Ramp{dsp.REVERB_PARAM_MIX, 100, 0}}
	ev[4] = {0, core.Param_Value{dsp.REVERB_PARAM_PREDELAY_MS, 0}}
	return ev
}

// Within 3% at any size and modulation: whole-frame line lengths and
// allpass interpolation keep the loop exactly as lossy as designed.
@(test)
reverb_decays_in_its_decay_time :: proc(t: ^testing.T) {
	for decay in ([]f64{1, 3}) {
		for size in ([]f64{0, 100}) {
			for modulation in ([]f64{0, 100}) {
				ev := make([]kit.Timed_Event, 7, context.temp_allocator)
				copy(ev, reverb_setup(decay, 100))
				ev[5] = {0, core.Param_Value{dsp.REVERB_PARAM_SIZE, size}}
				ev[6] = {0, core.Param_Value{dsp.REVERB_PARAM_MODULATION, modulation}}
				out := reverb_ir(t, decay * 2, ev)
				got := rt60(out.channels[0])
				testing.expectf(t, abs(got / decay - 1) < 0.03, "size %v%%, modulation %v%%: RT60 %.3f s, want %.2f s", size, modulation, got, decay)
			}
		}
	}
}

@(test)
reverb_highs_decay_faster :: proc(t: ^testing.T) {
	out := reverb_ir(t, 4, reverb_setup(2, 25))
	band :: proc(ir: []f32, mode: dsp.Filter_Mode, hz: f64) -> []f32 {
		c := dsp.svf_design(mode, hz, 0.707, 0, SR)
		s: dsp.Svf_State
		y := make([]f32, len(ir), context.temp_allocator)
		for x, i in ir do y[i] = f32(dsp.svf_tick(&c, &s, f64(x)))
		return y
	}
	low := rt60(band(out.channels[0], .Lowpass, 300))
	high := rt60(band(out.channels[0], .Highpass, 10_000))
	testing.expectf(t, low > 1.6 && low < 2.4, "low RT60 %.2f s, want about 2", low)
	testing.expectf(t, high / low < 0.45, "high RT60 %.2f s against low %.2f s: highs should go quicker", high, low)
}

@(test)
reverb_is_dense_wide_and_dry_when_asked :: proc(t: ^testing.T) {
	out := reverb_ir(t, 0.5, reverb_setup(2, 50))
	quiet := 0
	for x in out.channels[0][int(0.08 * SR):int(0.2 * SR)] do if abs(x) < 1e-7 do quiet += 1
	testing.expectf(t, quiet < 50, "%d near-silent samples between 80 and 200 ms: not dense yet", quiet)
	testing.expect(t, kit.compare_slices(out.channels[0], out.channels[1]).max_abs_error > 1e-3, "stereo")

	mono := make([]kit.Timed_Event, 6, context.temp_allocator)
	copy(mono, reverb_setup(2, 50))
	mono[5] = {0, core.Param_Ramp{dsp.REVERB_PARAM_WIDTH, 0, 0}}
	m := reverb_ir(t, 0.5, mono)
	testing.expect_value(t, kit.compare_slices(m.channels[0], m.channels[1]).max_abs_error, 0)

	n := dsp.reverb_create()
	defer core.node_destroy(&n)
	input := kit.buffer_make(2, 10_000, SR, context.temp_allocator)
	kit.white_noise(input.channels[0], 1, 0.5)
	kit.white_noise(input.channels[1], 2, 0.5)
	cfg := kit.default_render_config()
	cfg.events = {{0, core.Param_Ramp{dsp.REVERB_PARAM_MIX, 0, 0}}}
	dry, r := kit.render(&n, input, cfg, context.temp_allocator)
	defer kit.render_report_destroy(&r)
	testing.expect_value(t, kit.compare_buffers(input, dry).max_abs_error, 0)
}

@(test)
reverb_stays_stable :: proc(t: ^testing.T) {
	n := dsp.reverb_create()
	defer core.node_destroy(&n)
	input := kit.buffer_make(2, 10 * 48_000, SR, context.temp_allocator)
	kit.white_noise(input.channels[0], 3, 0.5)
	kit.white_noise(input.channels[1], 4, 0.5)
	cfg := kit.default_render_config()
	cfg.events = {{0, core.Param_Value{dsp.REVERB_PARAM_DECAY_S, 30}}, {0, core.Param_Ramp{dsp.REVERB_PARAM_MIX, 100, 0}},
		{100_000, core.Param_Value{dsp.REVERB_PARAM_SIZE, 100}}, {250_000, core.Param_Value{dsp.REVERB_PARAM_SIZE, 0}}, {300_000, core.Param_Value{dsp.REVERB_PARAM_MODULATION, 100}}}
	out, r := kit.render(&n, input, cfg, context.temp_allocator)
	defer kit.render_report_destroy(&r)
	kit.expect_clean_render(t, r)
	p := kit.peak(out.channels[0])
	testing.expectf(t, p < 8, "peak %v: a 30 s tail of steady noise should level off", p)
}

reverb_factory :: kit.Node_Factory{create = proc(user: rawptr) -> core.Node { return dsp.reverb_create() }}

@(test)
reverb_is_block_invariant :: proc(t: ^testing.T) {
	input := kit.buffer_make(2, 24_000, SR, context.temp_allocator)
	kit.white_noise(input.channels[0], 51, 0.5)
	kit.white_noise(input.channels[1], 52, 0.5)
	cfg := kit.default_render_config()
	cfg.events = {{4_000, core.Param_Value{dsp.REVERB_PARAM_SIZE, 80}}, {9_000, core.Param_Value{dsp.REVERB_PARAM_DECAY_S, 5}}, {15_000, core.Param_Ramp{dsp.REVERB_PARAM_WIDTH, 20, 2000}}}
	patterns := kit.standard_block_patterns(cfg.max_block)
	kit.expect_block_invariant(t, reverb_factory, input, cfg, patterns[:], 0, "reverb")
}
