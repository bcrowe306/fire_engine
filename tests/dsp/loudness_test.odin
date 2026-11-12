package test_dsp

import "core:math"
import "core:testing"

import "fire:core"
import "fire:dsp"
import kit "fire:testkit"

// A stereo sine at `dbfs` (its peak) for `seconds`, both channels alike
// (or the second inverted, or the second at a phase).
@(private = "file")
stereo_sine :: proc(hz, dbfs, seconds: f64, invert := false, phase := 0.0) -> kit.Audio_Buffer {
	n := int(48_000 * seconds)
	b := kit.buffer_make(2, n, 48_000, context.temp_allocator)
	amp := math.pow(10, dbfs / 20)
	for i in 0 ..< n {
		x := amp * math.sin(2 * math.PI * hz * f64(i) / 48_000 + phase)
		b.channels[0][i] = f32(x)
		b.channels[1][i] = f32(-x if invert else x)
	}
	return b
}

@(test)
loudness_and_stereo_are_clean_and_block_invariant :: proc(t: ^testing.T) {
	makers := []proc(_: rawptr) -> core.Node{
		proc(_: rawptr) -> core.Node { n, _ := dsp.loudness_create(); return n },
		proc(_: rawptr) -> core.Node { n, _ := dsp.stereo_create(); return n },
	}
	input := kit.buffer_make(2, 48_000, 48_000, context.temp_allocator)
	for c in 0 ..< 2 do kit.white_noise(input.channels[c], u64(c + 3), 0.4)
	cfg := kit.default_render_config()
	for mk, i in makers {
		testing.expectf(t, kit.expect_block_invariant(t, {create = mk}, input, cfg, patterns, name = "meters"), "meter %d", i)
	}
	// The measurements too, block by block or all at once.
	read :: proc(input: kit.Audio_Buffer, blocks: kit.Block_Pattern) -> (m, s, i, tp: f32) {
		node, lm := dsp.loudness_create()
		defer core.node_destroy(&node)
		cfg := kit.default_render_config()
		cfg.blocks = blocks
		out, r := kit.render(&node, input, cfg, context.temp_allocator)
		_, _ = out, r
		return dsp.loudness_read(lm)
	}
	a0, a1, a2, a3 := read(input, kit.Fixed_Blocks{512})
	b0, b1, b2, b3 := read(input, kit.Random_Blocks{seed = 5, min = 0, max = 512})
	testing.expect(t, a0 == b0 && a1 == b1 && a2 == b2 && a3 == b3, "the same, whatever the blocks")
}

@(test)
a_reference_sine_reads_its_loudness :: proc(t: ^testing.T) {
	// EBU Tech 3341's first case: a stereo 1 kHz sine at -23 dBFS reads -23
	// LUFS (momentary, short-term and integrated), within 0.1 LU.
	node, m := dsp.loudness_create()
	defer core.node_destroy(&node)
	out := render_with(t, &node, stereo_sine(1000, -23, 5))
	testing.expect_value(t, out.channels[0][1000], stereo_sine(1000, -23, 5).channels[0][1000]) // passes through
	mom, short, integ, tp := dsp.loudness_read(m)
	testing.expectf(t, abs(mom + 23) < 0.1, "momentary %v", mom)
	testing.expectf(t, abs(short + 23) < 0.1, "short-term %v", short)
	testing.expectf(t, abs(integ + 23) < 0.1, "integrated %v", integ)
	testing.expectf(t, abs(20 * math.log10(f64(tp)) + 23) < 0.1, "true peak %v dBTP", 20 * math.log10(f64(tp)))
}

@(test)
silence_is_gated_out_of_the_integrated_loudness :: proc(t: ^testing.T) {
	node, m := dsp.loudness_create()
	defer core.node_destroy(&node)
	tone := stereo_sine(1000, -23, 4)
	input := kit.buffer_make(2, tone.frames * 2, 48_000, context.temp_allocator)
	for c in 0 ..< 2 do copy(input.channels[c], tone.channels[c]) // then 4 s of silence
	render_with(t, &node, input)
	mom, short, integ, _ := dsp.loudness_read(m)
	testing.expectf(t, mom == dsp.LOUDNESS_SILENT, "momentary: silent at the end (%v)", mom)
	testing.expectf(t, short < -60, "short-term: the 3 s window all silence (%v)", short)
	// (The 400 ms blocks across the tone's end, part tone and part silence,
	// pass both gates, as BS.1770 has it: a little under -23.)
	testing.expectf(t, abs(integ + 23) < 0.25, "integrated: the tone, not the silence (%v)", integ)
	// Reset: nothing integrated until a 400 ms block has played.
	dsp.loudness_reset(m)
	render_with(t, &node, stereo_sine(1000, -13, 0.2))
	_, _, integ, _ = dsp.loudness_read(m)
	testing.expectf(t, integ == dsp.LOUDNESS_SILENT, "started again (%v)", integ)
	render_with(t, &node, stereo_sine(1000, -13, 2))
	_, _, integ, _ = dsp.loudness_read(m)
	testing.expectf(t, abs(integ + 13) < 0.2, "the new level (%v)", integ)
}

@(test)
true_peak_sees_between_the_samples :: proc(t: ^testing.T) {
	// A full-scale sine at a quarter of the rate, 45° off: its samples peak
	// at 0.707, the signal at 1.
	node, m := dsp.loudness_create()
	defer core.node_destroy(&node)
	input := stereo_sine(12_000, 0, 1, phase = math.PI / 4)
	testing.expectf(t, kit.peak(input.channels[0]) < 0.72, "sample peak %v", kit.peak(input.channels[0]))
	render_with(t, &node, input)
	_, _, _, tp := dsp.loudness_read(m)
	db := 20 * math.log10(f64(tp))
	testing.expectf(t, db > -0.5 && db < 0.5, "true peak near 0 dBTP (%v)", db)
}

@(test)
stereo_correlation_and_points :: proc(t: ^testing.T) {
	corr :: proc(t: ^testing.T, input: kit.Audio_Buffer) -> (f32, [16][2]f32) {
		node, s := dsp.stereo_create()
		defer core.node_destroy(&node)
		render_with(t, &node, input)
		pts: [16][2]f32
		dsp.stereo_points(s, pts[:])
		return dsp.stereo_correlation(s), pts
	}
	same, pts := corr(t, stereo_sine(440, -6, 1))
	testing.expectf(t, same > 0.99, "the same in both: +1 (%v)", same)
	for p in pts do testing.expectf(t, p[0] == p[1], "a mono signal's points on the middle line (%v)", p)
	inv, _ := corr(t, stereo_sine(440, -6, 1, invert = true))
	testing.expectf(t, inv < -0.99, "one inverted: -1 (%v)", inv)
	noise := kit.buffer_make(2, 48_000, 48_000, context.temp_allocator)
	for c in 0 ..< 2 do kit.white_noise(noise.channels[c], u64(c + 7), 0.4)
	un, _ := corr(t, noise)
	testing.expectf(t, abs(un) < 0.15, "unrelated: about 0 (%v)", un)
	quiet, _ := corr(t, kit.buffer_make(2, 4800, 48_000, context.temp_allocator))
	testing.expect_value(t, quiet, 0)
}
