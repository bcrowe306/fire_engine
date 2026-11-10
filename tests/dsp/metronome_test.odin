package test_dsp

import "core:math"
import "core:testing"

import "fire:core"
import "fire:dsp"
import kit "fire:testkit"

@(private)
make_metronome :: proc(_: rawptr) -> core.Node {
	return dsp.metronome_create({timeline = kit.RENDER_TIMELINE})
}

// Where each click starts: the first loud frame after a quiet stretch.
@(private)
click_starts :: proc(x: []f32) -> [dynamic]int {
	out := make([dynamic]int, context.temp_allocator)
	quiet := 1000
	for v, i in x {
		if abs(v) > 1e-3 {
			if quiet >= 1000 do append(&out, i)
			quiet = 0
		} else {
			quiet += 1
		}
	}
	return out
}

// Zero crossings in `x` (for the click's pitch).
@(private)
crossings :: proc(x: []f32) -> int {
	n := 0
	for i in 1 ..< len(x) do if (x[i - 1] < 0) != (x[i] < 0) do n += 1
	return n
}

@(test)
metronome_clicks_each_beat_accenting_the_bar :: proc(t: ^testing.T) {
	cfg := kit.default_render_config()
	cfg.tail_frames = 48_000 * 5 // 10 beats at 120 BPM
	cfg.out_channels = 1
	node := make_metronome(nil)
	defer core.node_destroy(&node)
	out, r := kit.render(&node, kit.buffer_make(0, 0, 48_000, context.temp_allocator), cfg, context.temp_allocator)
	kit.expect_clean_render(t, r)
	x := out.channels[0]
	starts := click_starts(x)
	testing.expectf(t, len(starts) == 10, "10 clicks in 10 beats (%v)", starts)
	for s, i in starts do testing.expectf(t, s == i * 24_000, "click %d at %d (beat at %d)", i, s, i * 24_000)
	// Bar starts (beats 0, 4, 8) are higher: 1.5 kHz against 1 kHz.
	win := 480 // 10 ms
	for s, i in starts {
		hz := f64(crossings(x[s:][:win])) / 2 / 0.01
		want := 1500.0 if i % 4 == 0 else 1000.0
		testing.expectf(t, abs(hz - want) < 120, "click %d: %.0f Hz (want %.0f)", i, hz, want)
	}
	// Silent between clicks.
	testing.expectf(t, kit.peak(x[12_000:][:6_000]) == 0, "silent between clicks")
}

@(test)
metronome_is_silent_when_stopped_or_off_and_block_invariant :: proc(t: ^testing.T) {
	cfg := kit.default_render_config()
	cfg.tail_frames = 96_000
	cfg.playing = false
	node := make_metronome(nil)
	out, _ := kit.render(&node, kit.buffer_make(0, 0, 48_000, context.temp_allocator), cfg, context.temp_allocator)
	core.node_destroy(&node)
	testing.expect_value(t, kit.peak(out.channels[0]), 0)

	cfg.playing = true
	cfg.events = {{time = 0, payload = core.Param_Value{param = dsp.METRONOME_PARAM_ON, value = 0}}}
	node = make_metronome(nil)
	out, _ = kit.render(&node, kit.buffer_make(0, 0, 48_000, context.temp_allocator), cfg, context.temp_allocator)
	core.node_destroy(&node)
	testing.expect_value(t, kit.peak(out.channels[0]), 0)

	cfg.events = nil
	kit.expect_block_invariant(t, {create = make_metronome}, kit.buffer_make(0, 0, 48_000, context.temp_allocator), cfg,
		{kit.Fixed_Blocks{512}, kit.Fixed_Blocks{1}, kit.Random_Blocks{seed = 7, min = 0, max = 512}})
	_ = math.PI
}
