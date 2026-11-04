package test_dsp

import "core:math"
import "core:testing"

import "fire:core"
import "fire:dsp"
import kit "fire:testkit"

@(test)
delay_line_reads_between_samples :: proc(t: ^testing.T) {
	d: dsp.Delay_Line
	dsp.delay_line_init(&d, 1000)
	defer dsp.delay_line_destroy(&d)
	for i in 0 ..< 500 do dsp.delay_line_write(&d, f32(math.sin(math.TAU * 1000 * f64(i) / SR)))
	last := 499
	for interp in ([]dsp.Interpolation{.None, .Linear, .Cubic}) {
		testing.expect_value(t, dsp.delay_line_read(&d, 37, interp), f32(math.sin(math.TAU * 1000 * f64(last - 37) / SR)))
	}
	// A 1 kHz sine read 10.37 frames back: cubic within 2e-4, linear within 1e-2.
	want := math.sin(math.TAU * 1000 * (f64(last) - 10.37) / SR)
	kit.expect_near(t, f64(dsp.delay_line_read(&d, 10.37, .Cubic)), want, 2e-4, "cubic")
	kit.expect_near(t, f64(dsp.delay_line_read(&d, 10.37, .Linear)), want, 1e-2, "linear")
}

@(test)
lfo_shapes_rates_and_sync :: proc(t: ^testing.T) {
	kit.expect_near(t, dsp.lfo_shape_at(.Sine, 0.25), 1, 1e-12, "sine peak")
	testing.expect_value(t, dsp.lfo_shape_at(.Triangle, 0), -1)
	testing.expect_value(t, dsp.lfo_shape_at(.Triangle, 0.5), 1)
	testing.expect_value(t, dsp.lfo_shape_at(.Saw_Up, 0.75), 0.5)
	testing.expect_value(t, dsp.lfo_shape_at(.Square, 0.6), -1)
	l := dsp.Lfo{shape = .Saw_Up}
	dsp.lfo_set_rate(&l, 3, SR)
	wraps, prev := 0, -2.0
	for _ in 0 ..< 48_000 {
		v := dsp.lfo_next(&l)
		if v < prev do wraps += 1
		prev = v
	}
	testing.expect_value(t, wraps, 2) // 3 Hz from phase 0: wraps at 1/3 s and 2/3 s; the third falls on the next frame
	dsp.lfo_sync(&l, 5.5, 2) // 2.75 cycles of a two-beat period
	kit.expect_near(t, l.phase, 0.75, 1e-12, "synced phase")
}

delay_impulse :: proc(t: ^testing.T, events: []kit.Timed_Event, tempo := 120.0, channels := 1, frames := 60_000) -> kit.Audio_Buffer {
	n := dsp.delay_create()
	defer core.node_destroy(&n)
	input := kit.buffer_make(channels, frames, SR, context.temp_allocator)
	kit.impulse(input.channels[0])
	cfg := kit.default_render_config()
	cfg.out_channels = channels
	cfg.tempo_bpm = tempo
	cfg.events = events
	out, r := kit.render(&n, input, cfg, context.temp_allocator)
	defer kit.render_report_destroy(&r)
	kit.expect_clean_render(t, r)
	return out
}

@(test)
delay_echoes_on_time_and_decay_by_the_feedback :: proc(t: ^testing.T) {
	out := delay_impulse(t, {
		{0, core.Param_Value{dsp.DELAY_PARAM_TIME_MS, 250}},
		{0, core.Param_Ramp{dsp.DELAY_PARAM_MIX, 100, 0}}, // exact sets, not smoothed
		{0, core.Param_Ramp{dsp.DELAY_PARAM_FEEDBACK, 50, 0}},
		{0, core.Param_Value{dsp.DELAY_PARAM_HIGH_CUT_HZ, 20_000}},
	})
	y := out.channels[0]
	T :: 12_000
	testing.expect_value(t, y[0], 0) // fully wet: no dry
	kit.expect_near(t, f64(y[T]), 1, 1e-6, "the first echo, exactly")
	// Fed back at 50%: 6 dB down where the loop filters are flat.
	kit.expect_near(t, kit.response_db(y[2 * T - 100:][:8000], SR, 1000) - kit.response_db(y[T - 100:][:8000], SR, 1000), -6.0206, 0.02, "the second echo")
	kit.expect_near(t, f64(kit.peak(y[T + 100:][:T - 200])), 0, 1e-9, "nothing between echoes")
}

@(test)
delay_syncs_to_the_tempo :: proc(t: ^testing.T) {
	out := delay_impulse(t, {
		{0, core.Param_Value{dsp.DELAY_PARAM_SYNC, 1}},
		{0, core.Param_Value{dsp.DELAY_PARAM_BEATS, 0.5}},
		{0, core.Param_Ramp{dsp.DELAY_PARAM_MIX, 100, 0}},
	}, tempo = 100)
	at := 0
	for x, i in out.channels[0] do if abs(x) > 0.5 {
		at = i
		break
	}
	testing.expect_value(t, at, 14_400) // half a beat at 100 BPM: 0.3 s
}

@(test)
delay_ping_pongs :: proc(t: ^testing.T) {
	out := delay_impulse(t, {
		{0, core.Param_Value{dsp.DELAY_PARAM_TIME_MS, 100}},
		{0, core.Param_Ramp{dsp.DELAY_PARAM_MIX, 100, 0}},
		{0, core.Param_Ramp{dsp.DELAY_PARAM_FEEDBACK, 80, 0}},
		{0, core.Param_Value{dsp.DELAY_PARAM_HIGH_CUT_HZ, 20_000}},
		{0, core.Param_Value{dsp.DELAY_PARAM_PING_PONG, 1}},
	}, channels = 2, frames = 20_000)
	T :: 4_800
	for k in 1 ..= 3 {
		side, other := (k + 1) % 2, k % 2 // left, right, left
		testing.expectf(t, abs(out.channels[side][k * T]) > 0.1 && abs(out.channels[other][k * T]) < 1e-6, "echo %d on channel %d", k, side)
	}
}

@(test)
delay_dry_is_exact_at_zero_mix :: proc(t: ^testing.T) {
	n := dsp.delay_create()
	defer core.node_destroy(&n)
	input := kit.buffer_make(2, 20_000, SR, context.temp_allocator)
	kit.white_noise(input.channels[0], 3, 0.5)
	kit.white_noise(input.channels[1], 4, 0.5)
	cfg := kit.default_render_config()
	cfg.events = {{0, core.Param_Ramp{dsp.DELAY_PARAM_MIX, 0, 0}}}
	out, r := kit.render(&n, input, cfg, context.temp_allocator)
	defer kit.render_report_destroy(&r)
	testing.expect_value(t, kit.compare_buffers(input, out).max_abs_error, 0)
}

// The flanger at rest (no depth) is a comb: half dry, half 1 ms late,
// so it cancels at 500 Hz and passes 1 kHz.
@(test)
flanger_notches_where_a_comb_does :: proc(t: ^testing.T) {
	n := dsp.flanger_create()
	defer core.node_destroy(&n)
	input := kit.buffer_make(1, 1 << 15, SR, context.temp_allocator)
	kit.impulse(input.channels[0], 9600)
	cfg := kit.default_render_config()
	cfg.out_channels = 1
	cfg.events = {{0, core.Param_Ramp{dsp.MOD_PARAM_DEPTH, 0, 0}}, {0, core.Param_Ramp{dsp.MOD_PARAM_FEEDBACK, 0, 0}}, {0, core.Param_Ramp{dsp.MOD_PARAM_DELAY_MS, 1, 0}}}
	out, r := kit.render(&n, input, cfg, context.temp_allocator)
	defer kit.render_report_destroy(&r)
	kit.expect_clean_render(t, r)
	ir := out.channels[0][9600:]
	testing.expectf(t, kit.response_db(ir, SR, 500) < -60, "notch at 500 Hz: %v dB", kit.response_db(ir, SR, 500))
	kit.expect_near(t, kit.response_db(ir, SR, 1000), 0, 0.01, "peak at 1 kHz")
}

// The phaser at rest: two allpass stages at 1 kHz turn its phase by half a
// cycle there, so half dry and half wet cancel.
@(test)
phaser_notches_at_its_frequency :: proc(t: ^testing.T) {
	n := dsp.phaser_create()
	defer core.node_destroy(&n)
	input := kit.buffer_make(1, 1 << 15, SR, context.temp_allocator)
	kit.impulse(input.channels[0], 9600)
	cfg := kit.default_render_config()
	cfg.out_channels = 1
	cfg.events = {{0, core.Param_Ramp{dsp.MOD_PARAM_DEPTH, 0, 0}}, {0, core.Param_Value{dsp.MOD_PARAM_VOICES, 2}}, {0, core.Param_Value{dsp.MOD_PARAM_MIN_HZ, 1000}}}
	out, r := kit.render(&n, input, cfg, context.temp_allocator)
	defer kit.render_report_destroy(&r)
	kit.expect_clean_render(t, r)
	ir := out.channels[0][9600:]
	testing.expectf(t, kit.response_db(ir, SR, 1000) < -60, "notch at 1 kHz: %v dB", kit.response_db(ir, SR, 1000))
	kit.expect_near(t, kit.response_db(ir, SR, 30), 0, 0.05, "flat far below")
}

delay_factory :: kit.Node_Factory{create = proc(user: rawptr) -> core.Node { return dsp.delay_create() }}
chorus_factory :: kit.Node_Factory{create = proc(user: rawptr) -> core.Node { return dsp.chorus_create() }}
flanger_factory :: kit.Node_Factory{create = proc(user: rawptr) -> core.Node { return dsp.flanger_create() }}
phaser_factory :: kit.Node_Factory{create = proc(user: rawptr) -> core.Node { return dsp.phaser_create() }}

@(test)
delay_and_modulation_are_block_invariant :: proc(t: ^testing.T) {
	input := kit.buffer_make(2, 30_000, SR, context.temp_allocator)
	kit.white_noise(input.channels[0], 31, 0.5)
	kit.white_noise(input.channels[1], 32, 0.5)
	cfg := kit.default_render_config()
	patterns := kit.standard_block_patterns(cfg.max_block)
	cfg.events = {{0, core.Param_Value{dsp.DELAY_PARAM_TIME_MS, 50}}, {6_000, core.Param_Value{dsp.DELAY_PARAM_TIME_MS, 80}}, {14_000, core.Param_Value{dsp.DELAY_PARAM_PING_PONG, 1}}, {20_000, core.Param_Value{dsp.DELAY_PARAM_SYNC, 1}}}
	kit.expect_block_invariant(t, delay_factory, input, cfg, patterns[:], 0, "delay")
	cfg.events = {{5_000, core.Param_Value{dsp.MOD_PARAM_VOICES, 4}}, {9_999, core.Param_Ramp{dsp.MOD_PARAM_DEPTH, 8, 4000}}}
	kit.expect_block_invariant(t, chorus_factory, input, cfg, patterns[:], 0, "chorus")
	cfg.events = {{7_000, core.Param_Value{dsp.MOD_PARAM_FEEDBACK, -80}}, {12_000, core.Param_Value{dsp.MOD_PARAM_RATE_HZ, 3}}}
	kit.expect_block_invariant(t, flanger_factory, input, cfg, patterns[:], 0, "flanger")
	cfg.events = {{3_000, core.Param_Value{dsp.MOD_PARAM_VOICES, 8}}, {15_000, core.Param_Value{dsp.MOD_PARAM_FEEDBACK, 70}}}
	kit.expect_block_invariant(t, phaser_factory, input, cfg, patterns[:], 0, "phaser")
}
