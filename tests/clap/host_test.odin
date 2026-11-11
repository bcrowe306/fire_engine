package test_clap

import "core:dynlib"
import "core:math"
import "core:testing"
import "core:thread"

import "fire:clap"
import "fire:core"
import kit "fire:testkit"

SR :: 48_000.0
GAIN :: core.Param_Id(7)
PLUGIN_ID :: "dev.fire-engine.test.gain"

bundle :: proc() -> string { return #directory + "/../../.build/clap/FireTest.clap" }

open_test_plugin :: proc(t: ^testing.T) -> (node: core.Node, p: ^clap.Plugin, lib: ^clap.Library, ok: bool) {
	err: core.Error
	lib, err = clap.library_open(bundle())
	if !testing.expect_value(t, err, core.Error.None) do return
	node, p, err = clap.plugin_create(lib, PLUGIN_ID, {})
	if !testing.expect_value(t, err, core.Error.None) {
		clap.library_close(lib)
		return
	}
	return node, p, lib, true
}

// The test plug-in's count of calls on the wrong thread.
wrong_thread_calls :: proc() -> int {
	lib, ok := dynlib.load_library(plugin_binary()) // already loaded: the same instance
	if !ok do return -1
	defer dynlib.unload_library(lib)
	f := cast(proc "c" () -> i32)dynlib.symbol_address(lib, "fire_test_wrong_thread_calls")
	return int(f()) if f != nil else -1
}

@(test)
lists_and_describes_the_plugin :: proc(t: ^testing.T) {
	node, p, lib, ok := open_test_plugin(t)
	if !ok do return
	defer clap.library_close(lib)
	defer core.node_destroy(&node)
	if !testing.expect_value(t, len(lib.plugins), 2) do return
	d := lib.plugins[0]
	testing.expect_value(t, d.id, PLUGIN_ID)
	testing.expect_value(t, d.name, "Fire Test Gain")
	testing.expect(t, len(d.features) == 2 && d.features[0] == "audio-effect")
	ins, outs := clap.plugin_channels(p)
	testing.expect(t, ins == 2 && outs == 2)
	params := core.node_params(&node)
	if testing.expect_value(t, len(params), 1) {
		testing.expect(t, params[0].id == GAIN && params[0].name == "Gain" && params[0].min == -60 && params[0].max == 12 && .Automatable in params[0].flags)
	}
	testing.expect_value(t, clap.plugin_param_text(p, GAIN, -3, context.temp_allocator), "-3.0 dB")
	testing.expect(t, !clap.plugin_gui_supported(p, .Cocoa))
	_, _, gerr := clap.plugin_gui_open(p, {api = .Cocoa})
	testing.expect_value(t, gerr, core.Error.Unsupported)
	_, open_err := clap.library_open("no/such.clap")
	testing.expect(t, open_err != .None)
}

// The library's second plug-in: an instrument (a sine at the held note).
@(test)
an_instrument_plays_its_notes :: proc(t: ^testing.T) {
	lib, err := clap.library_open(bundle())
	if !testing.expect_value(t, err, core.Error.None) do return
	defer clap.library_close(lib)
	d := lib.plugins[1]
	testing.expect_value(t, d.id, "dev.fire-engine.test.sine")
	testing.expect(t, len(d.features) > 0 && d.features[0] == "instrument")
	node, p, cerr := clap.plugin_create(lib, d.id, {})
	if !testing.expect_value(t, cerr, core.Error.None) do return
	defer core.node_destroy(&node)
	ins, outs := clap.plugin_channels(p)
	testing.expect(t, ins == 0 && outs == 2)
	cfg := kit.default_render_config()
	cfg.events = {{1_000, core.Note_On{id = 1, key = 69, velocity = 1}}, {25_000, core.Note_Off{id = 1, key = 69}}}
	out, r := kit.render(&node, kit.buffer_make(2, 30_000, SR, context.temp_allocator), cfg, context.temp_allocator)
	defer kit.render_report_destroy(&r)
	testing.expect(t, r.non_finite == 0 && r.rt_allocations == 0)
	x := out.channels[0]
	// Silent before the note, a 440 Hz sine at -6 dB while held, silent after.
	pre, held, post: f32
	for v in x[:1_000] do pre = max(pre, abs(v))
	for v in x[2_000:24_000] do held = max(held, abs(v))
	for v in x[25_100:] do post = max(post, abs(v))
	testing.expect(t, pre == 0 && post == 0)
	testing.expect(t, abs(held - 0.501) < 0.01)
	crossings := 0
	for i in 2_001 ..< 24_000 do if (x[i - 1] < 0) != (x[i] < 0) do crossings += 1
	hz := f64(crossings) / 2 / (22_000 / SR)
	testing.expect(t, abs(hz - 440) < 3)
	// Its editor embeds in whatever window it is given.
	testing.expect(t, clap.plugin_gui_supported(p, .Cocoa) && clap.plugin_gui_supported(p, .X11))
	w, h, gerr := clap.plugin_gui_open(p, {api = .Cocoa, handle = 0x1234})
	testing.expect(t, gerr == .None && w == 360 && h == 240)
	lib2, _ := dynlib.load_library(plugin_binary())
	defer dynlib.unload_library(lib2)
	parent := cast(proc "c" () -> uintptr)dynlib.symbol_address(lib2, "fire_test_gui_parent")
	testing.expect(t, parent != nil && parent() == 0x1234)
	clap.plugin_gui_close(p)
	testing.expect(t, parent() == 0)
}

@(test)
audio_params_and_latency :: proc(t: ^testing.T) {
	node, _, lib, ok := open_test_plugin(t)
	if !ok do return
	defer clap.library_close(lib)
	defer core.node_destroy(&node)
	input := kit.buffer_make(2, 30_000, SR, context.temp_allocator)
	kit.white_noise(input.channels[0], 1, 0.5)
	kit.white_noise(input.channels[1], 2, 0.5)
	cfg := kit.default_render_config()
	cfg.events = {
		{10_000, core.Param_Value{GAIN, -6}},
		{20_000, core.Param_Ramp{GAIN, -12, 4800}},
	}
	out, r := kit.render(&node, input, cfg, context.temp_allocator)
	defer kit.render_report_destroy(&r)
	kit.expect_clean_render(t, r)
	testing.expect_value(t, core.node_latency(&node), 32)
	for i in 32 ..< 10_000 do if out.channels[0][i] != input.channels[0][i - 32] {
		testing.expectf(t, false, "frame %d: not the input 32 frames late", i)
		break
	}
	g := f32(math.pow(10, -6.0 / 20))
	kit.expect_near(t, f64(out.channels[1][15_000]), f64(input.channels[1][15_000 - 32] * g), 1e-6, "−6 dB, from frame 10000 exactly")
	testing.expect(t, abs(out.channels[0][9_999] - input.channels[0][9_999 - 32]) < 1e-7, "still 0 dB the frame before")
	end := f32(math.pow(10, -12.0 / 20))
	kit.expect_near(t, f64(out.channels[0][26_000]), f64(input.channels[0][26_000 - 32] * end), 1e-6, "the ramp reached −12 dB")
	mid := out.channels[0][22_400] / input.channels[0][22_400 - 32]
	testing.expectf(t, mid < g && mid > end, "half way down the ramp: %v", mid)
}

@(test)
notes_go_in_and_come_out :: proc(t: ^testing.T) {
	node, _, lib, ok := open_test_plugin(t)
	if !ok do return
	defer clap.library_close(lib)
	defer core.node_destroy(&node)
	cfg := kit.default_render_config()
	cfg.events = {{100, core.Note_On{id = 5, key = 60, velocity = 0.8}}, {3_000, core.Note_Off{id = 5, key = 60}}}
	_, r := kit.render(&node, kit.buffer_make(2, 4_000, SR, context.temp_allocator), cfg, context.temp_allocator)
	defer kit.render_report_destroy(&r)
	if !testing.expect_value(t, len(r.events_out), 2) do return
	on := r.events_out[0].payload.(core.Note_On)
	testing.expect(t, r.events_out[0].time == 100 && on.key == 72 && on.id == 5 && abs(on.velocity - 0.8) < 1e-6)
	testing.expect(t, r.events_out[1].time == 3_000 && r.events_out[1].payload.(core.Note_Off).key == 72)
}

@(test)
state_round_trips :: proc(t: ^testing.T) {
	node, p, lib, ok := open_test_plugin(t)
	if !ok do return
	defer clap.library_close(lib)
	defer core.node_destroy(&node)
	saved, err := clap.plugin_save_state(p, context.temp_allocator)
	if !testing.expect_value(t, err, core.Error.None) do return
	testing.expect_value(t, len(saved), 8) // the gain, a double
	cfg := kit.default_render_config()
	cfg.events = {{0, core.Param_Value{GAIN, -9}}}
	_, r := kit.render(&node, kit.buffer_make(2, 512, SR, context.temp_allocator), cfg, context.temp_allocator)
	kit.render_report_destroy(&r)
	v, _ := clap.plugin_param_value(p, GAIN)
	testing.expect_value(t, v, -9)
	testing.expect_value(t, clap.plugin_load_state(p, saved), core.Error.None)
	v, _ = clap.plugin_param_value(p, GAIN)
	testing.expect_value(t, v, 0)
}

clap_factory :: kit.Node_Factory{create = proc(user: rawptr) -> core.Node {
	node, _, _ := clap.plugin_create((^clap.Library)(user), PLUGIN_ID, {})
	return node
}}

@(test)
hosted_plugin_is_block_invariant :: proc(t: ^testing.T) {
	lib, err := clap.library_open(bundle())
	if !testing.expect_value(t, err, core.Error.None) do return
	defer clap.library_close(lib)
	input := kit.buffer_make(2, 20_000, SR, context.temp_allocator)
	kit.white_noise(input.channels[0], 3, 0.5)
	kit.white_noise(input.channels[1], 4, 0.5)
	cfg := kit.default_render_config()
	cfg.events = {{3_333, core.Param_Value{GAIN, -3}}, {7_000, core.Param_Ramp{GAIN, -20, 5000}}, {15_000, core.Param_Value{GAIN, 4}}}
	factory := clap_factory
	factory.user = lib
	patterns := kit.standard_block_patterns(cfg.max_block)
	kit.expect_block_invariant(t, factory, input, cfg, patterns[:], 0, "clap")
}

// CLAP's thread rules, as the plug-in checks them: main-thread calls from
// the creating thread, processing from the audio thread, after
// start_processing.
@(test)
threads_are_where_clap_wants_them :: proc(t: ^testing.T) {
	node, p, lib, ok := open_test_plugin(t)
	if !ok do return
	defer clap.library_close(lib)
	before := wrong_thread_calls()
	core.node_prepare(&node, {sample_rate = SR, max_block = 256, in_channels = 2, out_channels = 2})
	Run :: struct { node: ^core.Node }
	run := Run{&node}
	audio := thread.create_and_start_with_data(&run, proc(data: rawptr) {
		n := (^Run)(data).node
		l, r := make([]f32, 256), make([]f32, 256)
		defer delete(l)
		defer delete(r)
		for _ in 0 ..< 50 {
			ctx := core.Process_Context{inputs = {l, r}, outputs = {l, r}, frames = 256}
			core.node_process(n, &ctx)
		}
	})
	thread.join(audio)
	thread.destroy(audio)
	clap.plugin_save_state(p, context.temp_allocator)
	clap.plugin_param_value(p, GAIN)
	core.node_destroy(&node) // release and destroy, back on this thread
	testing.expect_value(t, wrong_thread_calls() - before, 0)
}
