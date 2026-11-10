package test_dsp

import "core:math"
import "core:testing"

import "fire:core"
import "fire:dsp"
import kit "fire:testkit"
import tb "fire:timebase"

@(private)
sine_input :: proc(hz: f64, seconds: f64, amp: f32 = 0.5, channels := 2) -> kit.Audio_Buffer {
	n := int(48_000 * seconds)
	b := kit.buffer_make(channels, n, 48_000, context.temp_allocator)
	for c in 0 ..< channels do kit.sine(b.channels[c], 48_000, hz, f64(amp))
	return b
}

@(private)
render_with :: proc(t: ^testing.T, node: ^core.Node, input: kit.Audio_Buffer, events: []kit.Timed_Event = nil, loc := #caller_location) -> kit.Audio_Buffer {
	cfg := kit.default_render_config()
	cfg.events = events
	out, r := kit.render(node, input, cfg, context.temp_allocator)
	kit.expect_clean_render(t, r, loc)
	return out
}

@(private)
value :: proc(frame: int, id: core.Param_Id, v: f64) -> kit.Timed_Event {
	return {time = tb.Sample_Time(frame), payload = core.Param_Value{param = id, value = v}}
}

@(private)
patterns := []kit.Block_Pattern{kit.Fixed_Blocks{512}, kit.Fixed_Blocks{1}, kit.Random_Blocks{seed = 11, min = 0, max = 512}}

@(test)
performance_effects_are_clean_and_block_invariant :: proc(t: ^testing.T) {
	makers := []proc(_: rawptr) -> core.Node{
		proc(_: rawptr) -> core.Node { return dsp.bitcrush_create() },
		proc(_: rawptr) -> core.Node { return dsp.ring_mod_create() },
		proc(_: rawptr) -> core.Node { return dsp.comb_create() },
		proc(_: rawptr) -> core.Node { return dsp.pitch_shift_create() },
		proc(_: rawptr) -> core.Node { return dsp.cutter_create() },
		proc(_: rawptr) -> core.Node { return dsp.stutter_create() },
		proc(_: rawptr) -> core.Node { return dsp.wet_create(dsp.reverb_create(), 0.5) },
		proc(_: rawptr) -> core.Node { n, _ := dsp.meter_create(); return n },
	}
	input := kit.buffer_make(2, 48_000, 48_000, context.temp_allocator)
	for c in 0 ..< 2 do kit.white_noise(input.channels[c], u64(c + 1), 0.4)
	cfg := kit.default_render_config()
	// The stutter switches on and off; the wet mix moves.
	cfg.events = {value(10_000, dsp.STUTTER_PARAM_ACTIVE, 1), value(30_000, dsp.STUTTER_PARAM_ACTIVE, 0), value(20_000, dsp.WET_PARAM_MIX, 1)}
	for mk, i in makers {
		testing.expectf(t, kit.expect_block_invariant(t, {create = mk}, input, cfg, patterns, name = "performance"), "effect %d", i)
	}
}

@(test)
bitcrush_quantizes_and_holds :: proc(t: ^testing.T) {
	node := dsp.bitcrush_create()
	defer core.node_destroy(&node)
	out := render_with(t, &node, sine_input(100, 0.2, 0.9), {value(0, dsp.BITCRUSH_PARAM_BITS, 2), value(0, dsp.BITCRUSH_PARAM_DOWNSAMPLE, 8)})
	x := out.channels[0][4800:]
	for v in x do testing.expectf(t, v == 0 || abs(abs(v) - 0.5) < 1e-6 || abs(abs(v) - 1) < 1e-6, "2 bits: steps of 1/2 (%v)", v)
	runs := 0
	for i in 1 ..< len(x) do if x[i] != x[i - 1] do runs += 1
	testing.expectf(t, runs < len(x) / 8 + 2, "held 8 frames at a time (%d changes)", runs)
}

@(test)
ring_mod_moves_energy_to_sidebands :: proc(t: ^testing.T) {
	node := dsp.ring_mod_create()
	defer core.node_destroy(&node)
	out := render_with(t, &node, sine_input(1000, 0.5), {value(0, dsp.RING_PARAM_HZ, 300)})
	x := out.channels[0][4800:]
	testing.expectf(t, kit.tone_amplitude(x, 48_000, 1000) < 0.02, "the input is gone")
	testing.expectf(t, kit.tone_amplitude(x, 48_000, 700) > 0.2 && kit.tone_amplitude(x, 48_000, 1300) > 0.2, "sidebands at 700 and 1300 Hz")
}

@(test)
comb_rings_at_its_pitch :: proc(t: ^testing.T) {
	node := dsp.comb_create()
	defer core.node_destroy(&node)
	in_ := kit.buffer_make(2, 24_000, 48_000, context.temp_allocator)
	in_.channels[0][4800], in_.channels[1][4800] = 1, 1 // after the parameters have glided there
	out := render_with(t, &node, in_, {value(0, dsp.COMB_PARAM_HZ, 480), value(0, dsp.COMB_PARAM_MIX, 1)})
	x := out.channels[0][4800:]
	// An impulse comes back every 100 frames (48 kHz / 480 Hz), decaying.
	testing.expectf(t, abs(x[100]) > 0.05 && abs(x[200]) > 0.05 && abs(x[200]) < abs(x[100]), "echoes at 100, 200 (%v %v)", x[100], x[200])
	testing.expectf(t, abs(x[150]) < 1e-6, "nothing between")
}

// The dominant frequency of `x`, by zero crossings.
@(private)
crossing_hz :: proc(x: []f32) -> f64 {
	n := 0
	for i in 1 ..< len(x) do if (x[i - 1] < 0) != (x[i] < 0) do n += 1
	return f64(n) / 2 / (f64(len(x)) / 48_000)
}

@(test)
pitch_shift_moves_an_octave :: proc(t: ^testing.T) {
	// (Its two read heads make a grain texture, so the pitch is measured by
	// zero crossings, and the level by RMS.)
	node := dsp.pitch_shift_create()
	defer core.node_destroy(&node)
	out := render_with(t, &node, sine_input(230, 1))
	x := out.channels[0][9600:]
	testing.expectf(t, abs(crossing_hz(x) / 460 - 1) < 0.1, "+12: 460 Hz (%v)", crossing_hz(x))
	testing.expectf(t, kit.rms(x) > 0.2, "about the input's level (%v)", kit.rms(x))
	node2 := dsp.pitch_shift_create()
	defer core.node_destroy(&node2)
	out2 := render_with(t, &node2, sine_input(460, 1), {value(0, dsp.PITCH_PARAM_SEMITONES, -12)})
	y := out2.channels[0][9600:]
	testing.expectf(t, abs(crossing_hz(y) / 230 - 1) < 0.1, "-12: 230 Hz (%v)", crossing_hz(y))
}

@(test)
cutter_gates_on_the_grid :: proc(t: ^testing.T) {
	node := dsp.cutter_create()
	defer core.node_destroy(&node)
	in_ := kit.buffer_make(2, 48_000, 48_000, context.temp_allocator)
	for c in 0 ..< 2 do for &v in in_.channels[c] do v = 1
	out := render_with(t, &node, in_) // 1/16 at 120 BPM: 6000 frames, open for the first 3000
	x := out.channels[0]
	for cycle in 0 ..< 7 {
		base := cycle * 6000
		testing.expectf(t, x[base + 1500] > 0.99, "open early in cycle %d (%v)", cycle, x[base + 1500])
		testing.expectf(t, x[base + 4500] < 0.01, "shut late in cycle %d (%v)", cycle, x[base + 4500])
	}
	// The edges take a couple of milliseconds: no jumps.
	for i in 1 ..< len(x) do if abs(x[i] - x[i - 1]) > 0.02 {
		testing.expectf(t, false, "a jump at %d", i)
		break
	}
}

@(test)
stutter_repeats_the_slice_before_it :: proc(t: ^testing.T) {
	node := dsp.stutter_create()
	defer core.node_destroy(&node)
	in_ := kit.buffer_make(2, 48_000, 48_000, context.temp_allocator)
	for c in 0 ..< 2 do kit.white_noise(in_.channels[c], 5, 0.5)
	at := 24_000
	out := render_with(t, &node, in_, {value(at, dsp.STUTTER_PARAM_ACTIVE, 1)}) // 1/16: 6000 frames
	x, src := out.channels[0], in_.channels[0]
	testing.expect_value(t, x[1000], src[1000]) // before: the input
	// After the crossfade, the slice before `at` plays, again and again.
	for k in ([]int{500, 3000, 5500}) {
		for rep in 0 ..< 3 {
			i := at + rep * 6000 + k
			testing.expectf(t, abs(x[i] - src[at - 6000 + k]) < 1e-6, "repeat %d, frame %d", rep, k)
		}
	}
}

@(test)
wet_dry_mixes_without_steps :: proc(t: ^testing.T) {
	// Dry: exactly the input; wet: the effect's output.
	in_ := sine_input(500, 0.5)
	dry := dsp.wet_create(dsp.ring_mod_create(), 0)
	defer core.node_destroy(&dry)
	out := render_with(t, &dry, in_)
	for v, i in out.channels[0] do if v != in_.channels[0][i] {
		testing.expectf(t, false, "dry differs at %d", i)
		break
	}
	// Switched in at 12000: a 15 ms fade, no jump bigger than the sine moves.
	sw := dsp.wet_create(dsp.ring_mod_create(), 0)
	defer core.node_destroy(&sw)
	out2 := render_with(t, &sw, in_, {value(12_000, dsp.WET_PARAM_MIX, 1)})
	x := out2.channels[0]
	maxd: f32 = 0
	for i in 1 ..< len(x) do maxd = max(maxd, abs(x[i] - x[i - 1]))
	testing.expectf(t, maxd < 0.1, "smooth (biggest step %v)", maxd)
	testing.expectf(t, kit.tone_amplitude(x[18_000:], 48_000, 500) < 0.02, "fully wet later")
	// Its parameters: the effect's, and the mix.
	params := core.node_params(&sw)
	testing.expect_value(t, len(params), len(dsp.ring_params) + 1)
}

@(test)
meter_measures_peak_and_rms :: proc(t: ^testing.T) {
	node, m := dsp.meter_create()
	defer core.node_destroy(&node)
	out := render_with(t, &node, sine_input(1000, 0.5, 0.5))
	testing.expect_value(t, out.channels[0][100], sine_input(1000, 0.5, 0.5).channels[0][100]) // passes through
	peak, rms := dsp.meter_read(m)
	testing.expectf(t, abs(peak[0] - 0.5) < 1e-3, "peak %v", peak[0])
	testing.expectf(t, abs(rms[1] - 0.3536) < 2e-3, "rms %v", rms[1])
	peak, rms = dsp.meter_read(m)
	testing.expect(t, peak[0] == 0 && rms[0] == 0, "reading starts again")
	_ = math.PI
}
