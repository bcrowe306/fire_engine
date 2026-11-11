package test_sampler

import "core:testing"

import "fire:core"
import "fire:sampler"
import kit "fire:testkit"

// A sampler of `voices` voices playing the 440 Hz sine (looped), its
// parameters set at the start (`params`: id, value pairs), through
// `events`.
play_voices :: proc(t: ^testing.T, l: ^Lab, voices: int, params: [][2]f64, frames: int, events: []kit.Timed_Event) -> []f32 {
	node, s := sampler.sampler_create({voices = voices})
	defer core.node_destroy(&node)
	m, _ := sampler.sample_map_create({{source = l.sine, root_key = 69, loop = true, loop_start = 1000, loop_end = 40_000}})
	sampler.sampler_set_map(s, m)
	sampler.sample_map_release(m)
	evs := make([dynamic]kit.Timed_Event, context.temp_allocator)
	for p in params do append(&evs, kit.Timed_Event{0, core.Param_Value{core.Param_Id(p[0]), p[1]}})
	append(&evs, ..events)
	cfg := kit.default_render_config()
	cfg.events = evs[:]
	out, r := kit.render(&node, kit.buffer_length_only(frames, SR), cfg, context.temp_allocator)
	defer kit.render_report_destroy(&r)
	kit.expect_clean_render(t, r)
	return out.channels[0]
}

// The biggest step from one sample to the next in `x[a:b]`.
max_step :: proc(x: []f32, a, b: int) -> f32 {
	m: f32 = 0
	for i in a + 1 ..< b do m = max(m, abs(x[i] - x[i - 1]))
	return m
}

// One voice, a note over another: the old fades out as the new starts,
// with no jump (a sine's own steps are all there is); then one note
// alone sounds. Wherever in its cycle the old one is taken.
@(test)
a_stolen_voice_fades_out :: proc(t: ^testing.T) {
	l := lab_make()
	defer lab_destroy(l)
	// The sine at 0.5: steps of up to 0.5 × 2π × 440 / 48 000 ≈ 0.029 a sample.
	for k in 0 ..< 8 {
		at := 4_800 + k * 13
		x := play_voices(t, l, 1, nil, 14_400, {on(0, 69), on(at, 69)})
		step := max_step(x, at - 4, at + 400)
		testing.expectf(t, step < 0.07, "taken at %d: no click (biggest step %v)", at, step)
		testing.expectf(t, kit.peak(x[9_600:]) < 0.56, "then one note alone (%v)", kit.peak(x[9_600:]))
	}
	// Mono mode, any polyphony: the same.
	x := play_voices(t, l, 8, {{f64(sampler.SAMPLER_PARAM_VOICE_MODE), 1}}, 14_400, {on(0, 69), on(4_811, 64)})
	testing.expectf(t, max_step(x, 4_800, 5_300) < 0.07 && kit.peak(x[9_600:]) < 0.56, "mono: one note, no click")
	// Polyphony full: the oldest note fades for the new one.
	y := play_voices(t, l, 2, nil, 14_400, {on(0, 69), on(100, 76), on(4_807, 64)})
	testing.expectf(t, max_step(y, 4_800, 5_300) < 0.12, "two voices, a third note: no click (%v)", max_step(y, 4_800, 5_300))
}

// Legato with glide: a note played over a held one slides there (half
// way at half the glide time), starting nothing new (no step); let go,
// it slides back to the held one.
@(test)
legato_glides :: proc(t: ^testing.T) {
	l := lab_make()
	defer lab_destroy(l)
	params := [][2]f64{{f64(sampler.SAMPLER_PARAM_VOICE_MODE), 2}, {f64(sampler.SAMPLER_PARAM_GLIDE), 0.1}}
	x := play_voices(t, l, 1, params, 48_000, {on(0, 57), on(12_000, 69), off(24_000, 69)})
	c1 := cycles(x[2_400:12_000])             // 220 Hz: 44 in 0.2 s
	c2 := cycles(x[12_000 + 4_800:24_000])    // after the 0.1 s glide: 440 Hz, 66 in 0.15 s
	mid := cycles(x[12_000 + 2_400 - 240:12_000 + 2_400 + 240]) // 10 ms halfway: 311 Hz → about 3
	c3 := cycles(x[24_000 + 7_200:36_000])    // slid back: 220 Hz, 21 in 0.1 s
	testing.expectf(t, abs(c1 - 44) <= 1 && abs(c2 - 66) <= 1, "220 Hz, then 440 Hz (%d, %d)", c1, c2)
	testing.expectf(t, mid >= 2 && mid <= 4, "halfway, between (%d cycles in 10 ms)", mid)
	testing.expectf(t, abs(c3 - 22) <= 1, "let go: back to 220 Hz (%d in 0.1 s)", c3)
	testing.expectf(t, max_step(x, 11_990, 12_400) < 0.07, "the slide starts nothing (no step: %v)", max_step(x, 11_990, 12_400))
	// Without glide: straight there, still the one voice.
	y := play_voices(t, l, 1, {{f64(sampler.SAMPLER_PARAM_VOICE_MODE), 2}}, 24_000, {on(0, 57), on(12_000, 69)})
	testing.expectf(t, abs(cycles(y[12_480:24_000]) - 106) <= 1, "no glide: 440 Hz at once (%d)", cycles(y[12_480:24_000]))
}

// Mono, always glide: a note after another (not held over it) starts
// fresh but slides from the last one's pitch; not always, it doesn't.
@(test)
mono_glides_from_the_last_note :: proc(t: ^testing.T) {
	l := lab_make()
	defer lab_destroy(l)
	base := [][2]f64{{f64(sampler.SAMPLER_PARAM_VOICE_MODE), 1}, {f64(sampler.SAMPLER_PARAM_GLIDE), 0.2}}
	always := [][2]f64{base[0], base[1], {f64(sampler.SAMPLER_PARAM_GLIDE_ALWAYS), 1}}
	ev := []kit.Timed_Event{on(0, 57), off(9_600, 57), on(12_000, 69)}
	x := play_voices(t, l, 4, always, 24_000, ev)
	y := play_voices(t, l, 4, base, 24_000, ev)
	early_x := cycles(x[12_000:14_400]) // the first 50 ms
	early_y := cycles(y[12_000:14_400])
	testing.expectf(t, early_x < early_y - 3, "always: rising from 220 Hz (%d cycles against %d)", early_x, early_y)
}

// Stealing, mono and legato with glide: the same whatever the blocks.
@(test)
voices_are_block_invariant :: proc(t: ^testing.T) {
	l := lab_make()
	defer lab_destroy(l)
	for mode in 0 ..< 3 {
		cfg := kit.default_render_config()
		cfg.events = {
			{0, core.Param_Value{sampler.SAMPLER_PARAM_VOICE_MODE, f64(mode)}},
			{0, core.Param_Value{sampler.SAMPLER_PARAM_GLIDE, 0.05}},
			on(10, 69), on(3_000, 62, 0.4), on(5_500, 74), off(7_000, 74), on(9_000, 50), off(12_000, 69), on(15_000, 64),
		}
		patterns := kit.standard_block_patterns(cfg.max_block)
		args := Factory_Args{l, .Cubic}
		factory := sampler_factory
		factory.user = &args
		kit.expect_block_invariant(t, factory, kit.buffer_length_only(24_000, SR), cfg, patterns[:], 0, "sampler voices")
	}
}
