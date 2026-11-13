package test_effects

import "core:math"
import "core:testing"

import "fire:core"
import "fire:dsp"
import tb "fire:timebase"
import kit "fire:testkit"

// The share of a signal's energy that is not at the harmonics of `f0`
// (aliasing, folded back from above Nyquist), in dB, from a Hann-windowed
// FFT.
alias_db :: proc(x: []f32, f0: f64) -> f64 {
	n := len(x)
	f: dsp.Fft
	dsp.fft_init(&f, n, context.temp_allocator)
	buf := make([]complex64, n, context.temp_allocator)
	for v, i in x do buf[i] = complex(v * f32(0.5 - 0.5 * math.cos(math.TAU * f64(i) / f64(n))), 0)
	dsp.fft_forward(&f, buf, buf)
	harmonic, other: f64
	for k in 1 ..< n / 2 {
		e := f64(real(buf[k]) * real(buf[k]) + imag(buf[k]) * imag(buf[k]))
		hz := f64(k) * SR / f64(n)
		h := math.round(hz / f0)
		if h >= 1 && abs(hz - h * f0) < 4 * SR / f64(n) {
			harmonic += e
		} else {
			other += e
		}
	}
	return 10 * math.log10(other / harmonic)
}

// Two-point polyBLEP: about 15 dB less aliasing than a naive saw (measured
// −24 dB against −10 dB at 3.5 kHz, −35 dB against −20 dB at 440 Hz).
@(test)
polyblep_saw_aliases_far_less_than_a_naive_one :: proc(t: ^testing.T) {
	for c in ([]struct{ f0, improve, floor: f64 }{{3517, 12, -22}, {440.7, 14, -32}}) {
	f0 := c.f0
	n := 1 << 15
	blep, naive := make([]f32, n, context.temp_allocator), make([]f32, n, context.temp_allocator)
	o := dsp.Oscillator{shape = .Saw}
	dsp.osc_set_freq(&o, f0, SR)
	phase := 0.0
	for i in 0 ..< n {
		blep[i] = f32(dsp.osc_next(&o))
		naive[i] = f32(2 * phase - 1)
		phase += f0 / SR
		if phase >= 1 do phase -= 1
	}
	a_blep, a_naive := alias_db(blep, f0), alias_db(naive, f0)
	testing.expectf(t, a_blep < a_naive - c.improve && a_blep < c.floor, "%.0f Hz: aliasing polyBLEP %.1f dB, naive %.1f dB", f0, a_blep, a_naive)
	}
}

@(test)
oscillators_have_their_pitch_and_shape :: proc(t: ^testing.T) {
	crossings :: proc(shape: dsp.Osc_Shape, hz: f64) -> (n: int, mean, peak: f64) {
		o := dsp.Oscillator{shape = shape, pulse_width = 0.5}
		dsp.osc_set_freq(&o, hz, SR)
		prev := 0.0
		for i in 0 ..< 48_000 {
			v := dsp.osc_next(&o)
			if i > 0 && prev < 0 && v >= 0 do n += 1
			prev = v
			mean += v / 48_000
			if i > 4800 do peak = max(peak, abs(v))
		}
		return
	}
	for shape in dsp.Osc_Shape {
		n, mean, peak := crossings(shape, 1000)
		testing.expectf(t, abs(n - 1000) <= 1, "%v: %d cycles in a second", shape, n)
		testing.expectf(t, abs(mean) < 0.01, "%v: mean %v", shape, mean)
		testing.expectf(t, peak > 0.9 && peak < 1.15, "%v: peak %v", shape, peak)
	}
}

@(test)
adsr_keeps_its_times :: proc(t: ^testing.T) {
	a: dsp.Adsr
	dsp.adsr_set(&a, 0.01, 0.1, 0.5, 0.2, SR)
	dsp.adsr_gate(&a, true)
	for _ in 0 ..< 480 do dsp.adsr_next(&a)
	kit.expect_near(t, a.level, 1, 1e-9, "the top at the attack time")
	for _ in 0 ..< 4800 do dsp.adsr_next(&a)
	kit.expect_near(t, a.level - 0.5, 0.5 * 0.001, 1e-6, "within 60 dB of the sustain after the decay time")
	for _ in 0 ..< 20_000 do dsp.adsr_next(&a)
	testing.expect_value(t, a.stage, dsp.Adsr_Stage.Sustain)
	dsp.adsr_gate(&a, false)
	for _ in 0 ..< 9600 do dsp.adsr_next(&a)
	kit.expect_near(t, a.level, 0.5 * 0.001, 1e-6, "60 dB down after the release time")
}

// What it gives: the attack starting on its frame and at the top in its
// time, easing into it; from its top on, no sharp corner (the slope never turns more
// than a little a frame), and a zero release falls without a jump.
@(test)
adsr_turns_without_a_corner :: proc(t: ^testing.T) {
	a: dsp.Adsr
	dsp.adsr_set(&a, 0.003, 0.05, 0.2, 0, SR) // (3 ms up, then down to 0.2; no release at all)
	dsp.adsr_gate(&a, true)
	out := make([]f64, 9600, context.temp_allocator)
	for &v, i in out {
		if i == 4800 do dsp.adsr_gate(&a, false)
		v = dsp.adsr_next(&a)
	}
	step := 1 / (0.003 * SR)
	testing.expect(t, out[0] == 0 && out[1] > 0, "the attack starts on its frame")
	kit.expect_near(t, out[144], 1, 1e-9, "and is at the top in its time")
	worst := 0.0
	for i in 2 ..< 4800 do worst = max(worst, abs(out[i] - 2 * out[i - 1] + out[i - 2]))
	// (A straight attack's top into the decay turned by about the attack's
	// slope, 0.007 a frame; rounded, a fraction of it.)
	testing.expectf(t, worst < 0.25 * step, "no sharp corner: the slope turns at most %v a frame (the attack's slope %v)", worst, step)
	jump := 0.0
	for i in 4800 ..< len(out) do jump = max(jump, abs(out[i] - out[i - 1]))
	testing.expectf(t, jump < 0.1, "a zero release falls over a few frames, not at once (%v)", jump)
}

// A clean sine synth: one oscillator, filter wide open, full sustain.
clean_synth :: []kit.Timed_Event {
	{0, core.Param_Value{dsp.SYNTH_PARAM_OSC1_SHAPE, f64(dsp.Osc_Shape.Sine)}},
	{0, core.Param_Value{dsp.SYNTH_PARAM_OSC_MIX, 0}},
	{0, core.Param_Ramp{dsp.SYNTH_PARAM_CUTOFF_HZ, 20_000, 0}},
	{0, core.Param_Value{dsp.SYNTH_PARAM_FILTER_ENV, 0}},
	{0, core.Param_Value{dsp.SYNTH_PARAM_KEYTRACK, 0}},
	{0, core.Param_Value{dsp.SYNTH_PARAM_AMP_SUSTAIN, 100}},
	{0, core.Param_Value{dsp.SYNTH_PARAM_AMP_RELEASE, 0.05}},
	{0, core.Param_Ramp{dsp.SYNTH_PARAM_GAIN_DB, 0, 0}},
}

render_synth :: proc(t: ^testing.T, frames: int, notes: []kit.Timed_Event, voices := 16) -> kit.Audio_Buffer {
	n := dsp.synth_create(voices)
	defer core.node_destroy(&n)
	events := make([dynamic]kit.Timed_Event, context.temp_allocator)
	append(&events, ..clean_synth)
	append(&events, ..notes)
	cfg := kit.default_render_config()
	cfg.events = events[:]
	out, r := kit.render(&n, kit.buffer_length_only(frames, SR), cfg, context.temp_allocator)
	defer kit.render_report_destroy(&r)
	kit.expect_clean_render(t, r)
	return out
}

cycles :: proc(x: []f32) -> int {
	n := 0
	for i in 1 ..< len(x) do if x[i - 1] < 0 && x[i] >= 0 do n += 1
	return n
}

@(test)
synth_plays_in_tune_and_follows_tuning :: proc(t: ^testing.T) {
	out := render_synth(t, 2 * 48_000, {
		{0, core.Note_On{id = 7, key = 69, velocity = 1}},
		{48_000, core.Note_Expression{id = 7, key = 69, kind = .Tuning, value = 12}},
		{96_000 - 4800, core.Note_Off{id = 7, key = 69}},
	})
	testing.expectf(t, abs(cycles(out.channels[0][4800:48_000]) - 396) <= 1, "A4: %d cycles in 0.9 s, want 396", cycles(out.channels[0][4800:48_000]))
	testing.expectf(t, abs(cycles(out.channels[0][48_000:91_200]) - 792) <= 1, "an octave up: %d cycles in 0.9 s, want 792", cycles(out.channels[0][48_000:91_200]))
	kit.expect_near(t, kit.peak(out.channels[0][20_000:40_000]), math.SQRT_TWO / 2, 1e-3, "full level, panned centre (−3 dB)")
	testing.expect_value(t, out.channels[0][96_000 - 1], 0) // released in 50 ms: silent before the end
}

@(test)
synth_velocity_and_stealing :: proc(t: ^testing.T) {
	soft := render_synth(t, 24_000, {{0, core.Param_Value{dsp.SYNTH_PARAM_VELOCITY, 100}}, {100, core.Note_On{key = 60, velocity = 0.5}}})
	kit.expect_near(t, kit.peak(soft.channels[0][10_000:]), 0.5 * math.SQRT_TWO / 2, 1e-3, "half velocity, half level")
	// Ten notes on four voices: the newest four sound, nothing breaks.
	notes := make([]kit.Timed_Event, 10, context.temp_allocator)
	for &e, i in notes do e = {tb.Sample_Time(i * 1000), core.Note_On{id = core.Note_Id(i), key = u8(48 + i), velocity = 0.8}}
	n := dsp.synth_create(4)
	defer core.node_destroy(&n)
	events := make([dynamic]kit.Timed_Event, context.temp_allocator)
	append(&events, ..clean_synth)
	append(&events, ..notes)
	cfg := kit.default_render_config()
	cfg.events = events[:]
	out, r := kit.render(&n, kit.buffer_length_only(30_000, SR), cfg, context.temp_allocator)
	defer kit.render_report_destroy(&r)
	kit.expect_clean_render(t, r)
	keys: [dynamic]u8
	defer delete(keys)
	for v in (^dsp.Synth)(n.data).voices do if v.on do append(&keys, v.key)
	testing.expectf(t, len(keys) == 4 && slice_has_all(keys[:], {54, 55, 56, 57}), "sounding: %v, want the newest four", keys[:])
	testing.expect(t, kit.peak(out.channels[0][20_000:]) > 0.1)
}

synth_factory :: kit.Node_Factory{create = proc(user: rawptr) -> core.Node { return dsp.synth_create(8) }}

@(test)
synth_is_block_invariant :: proc(t: ^testing.T) {
	cfg := kit.default_render_config()
	cfg.events = {
		{0, core.Note_On{id = 1, key = 48, velocity = 0.9}},
		{777, core.Note_On{id = 2, key = 55, velocity = 0.6}},
		{3_000, core.Note_Expression{id = 2, key = 55, kind = .Vibrato, value = 1}},
		{5_000, core.Param_Ramp{dsp.SYNTH_PARAM_CUTOFF_HZ, 400, 6000}},
		{8_888, core.Note_Off{id = 1, key = 48}},
		{9_000, core.Note_Expression{id = 2, key = 55, kind = .Brightness, value = 0.9}},
		{12_000, core.Param_Value{dsp.SYNTH_PARAM_OSC2_SHAPE, f64(dsp.Osc_Shape.Pulse)}},
		{16_000, core.Note_Off{id = 2, key = 55}},
	}
	patterns := kit.standard_block_patterns(cfg.max_block)
	kit.expect_block_invariant(t, synth_factory, kit.buffer_length_only(24_000, SR), cfg, patterns[:], 0, "synth")
}

slice_has_all :: proc(have, want: []u8) -> bool {
	for w in want {
		found := false
		for h in have do found ||= h == w
		if !found do return false
	}
	return true
}
