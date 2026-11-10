package test_dsp

import "core:testing"

import "fire:core"
import "fire:dsp"
import kit "fire:testkit"

@(test)
a_tap_keeps_the_last_frames_it_heard :: proc(t: ^testing.T) {
	node, tap := dsp.tap_create()
	defer core.node_destroy(&node)
	in_ := kit.buffer_make(2, 10_000, 48_000, context.temp_allocator)
	for i in 0 ..< 10_000 {
		in_.channels[0][i] = f32(i)
		in_.channels[1][i] = f32(i) + 2 // the channels averaged: i + 1
	}
	cfg := kit.default_render_config()
	cfg.out_channels = 0
	_, r := kit.render(&node, in_, cfg, context.temp_allocator)
	defer kit.render_report_destroy(&r)
	kit.expect_clean_render(t, r)
	got: [8]f32
	heard := dsp.tap_read(tap, got[:])
	testing.expect_value(t, heard, 10_000)
	for v, k in got do testing.expect_value(t, v, f32(10_000 - 8 + k) + 1)
	// More than it keeps: TAP_FRAMES at most, oldest first.
	all := make([]f32, dsp.TAP_FRAMES + 10, context.temp_allocator)
	dsp.tap_read(tap, all)
	testing.expect_value(t, all[0], f32(10_000 - dsp.TAP_FRAMES) + 1)
	// Nothing heard yet: silence.
	node2, fresh := dsp.tap_create()
	defer core.node_destroy(&node2)
	dsp.tap_read(fresh, got[:])
	testing.expect_value(t, got[7], 0)
}
