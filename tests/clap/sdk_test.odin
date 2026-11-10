package test_clap

import "core:testing"

import "fire:clap"
import "fire:core"
import "fire:dsp"
import "fire:graph"
import kit "fire:testkit"

odin_bundle :: proc() -> string { return #directory + "/../../.build/clap/FireOdin.clap" }

// Renders `node` with `input` and `cfg`; the output.
render_with :: proc(t: ^testing.T, node: ^core.Node, input: kit.Audio_Buffer, cfg: kit.Render_Config) -> kit.Audio_Buffer {
	out, r := kit.render(node, input, cfg, context.temp_allocator)
	defer kit.render_report_destroy(&r)
	kit.expect_clean_render(t, r)
	return out
}

// A node made into a CLAP plug-in with the SDK and hosted with fire:clap
// sounds exactly like the node itself: the same code, through both ends
// of CLAP.
@(test)
sdk_plugins_sound_like_their_nodes :: proc(t: ^testing.T) {
	lib, err := clap.library_open(odin_bundle())
	if !testing.expect_value(t, err, core.Error.None) do return
	defer clap.library_close(lib)
	if !testing.expect_value(t, len(lib.plugins), 4) do return
	testing.expect(t, lib.plugins[1].name == "Fire Synth" && lib.plugins[1].features[0] == "instrument")

	noise := kit.buffer_make(2, 24_000, SR, context.temp_allocator)
	kit.white_noise(noise.channels[0], 7, 0.5)
	kit.white_noise(noise.channels[1], 8, 0.5)
	Case :: struct {
		id:     string,
		native: proc() -> core.Node,
		input:  kit.Audio_Buffer,
		events: []kit.Timed_Event,
		tempo:  f64,
	}
	cases := []Case {
		{"dev.fire-engine.odin.gain", proc() -> core.Node { return dsp.gain_create() }, noise, {{5_000, core.Param_Value{dsp.GAIN_PARAM_DB, -6}}, {15_000, core.Param_Value{dsp.GAIN_PARAM_DB, 3}}}, 120},
		{"dev.fire-engine.odin.synth", proc() -> core.Node { return dsp.synth_create(8) }, kit.buffer_length_only(24_000, SR),
			{{0, core.Note_On{id = 1, key = 57, velocity = 0.9}}, {2_000, core.Note_On{id = 2, key = 64, velocity = 0.5}},
			 {6_000, core.Note_Expression{id = 2, key = 64, kind = .Tuning, value = 2}}, {9_000, core.Note_Off{id = 1, key = 57}},
			 {12_000, core.Param_Value{dsp.SYNTH_PARAM_CUTOFF_HZ, 600}}}, 120},
		{"dev.fire-engine.odin.delay", proc() -> core.Node { return dsp.delay_create() }, noise,
			{{0, core.Param_Value{dsp.DELAY_PARAM_SYNC, 1}}, {0, core.Param_Value{dsp.DELAY_PARAM_BEATS, 0.5}}}, 100}, // the host's tempo reaches it
	}
	for x in cases {
		cfg := kit.default_render_config()
		cfg.events = x.events
		cfg.tempo_bpm = x.tempo
		node, _, perr := clap.plugin_create(lib, x.id, {})
		if !testing.expect_value(t, perr, core.Error.None) do continue
		hosted := render_with(t, &node, x.input, cfg)
		core.node_destroy(&node)
		native_node := x.native()
		native := render_with(t, &native_node, x.input, cfg)
		core.node_destroy(&native_node)
		testing.expectf(t, kit.compare_buffers(native, hosted).max_abs_error == 0, "%s: hosted differs from native by %v", x.id, kit.compare_buffers(native, hosted).max_abs_error)
		testing.expect(t, kit.peak(hosted.channels[0]) > 0.01, "and isn't silent")
	}
}

@(test)
sdk_params_latency_and_state :: proc(t: ^testing.T) {
	lib, err := clap.library_open(odin_bundle())
	if !testing.expect_value(t, err, core.Error.None) do return
	defer clap.library_close(lib)
	// The node's parameters, as the host sees them.
	node, p, _ := clap.plugin_create(lib, "dev.fire-engine.odin.gain", {})
	params := core.node_params(&node)
	if testing.expect_value(t, len(params), 1) {
		testing.expect(t, params[0].id == dsp.GAIN_PARAM_DB && params[0].name == "Gain" && params[0].min == -96 && params[0].max == 24)
	}
	testing.expect_value(t, clap.plugin_param_text(p, dsp.GAIN_PARAM_DB, -6, context.temp_allocator), "-6.00 dB")
	// State: a value set while playing comes back in a new instance.
	cfg := kit.default_render_config()
	cfg.events = {{0, core.Param_Value{dsp.GAIN_PARAM_DB, -12}}}
	render_with(t, &node, kit.buffer_make(2, 512, SR, context.temp_allocator), cfg)
	saved, serr := clap.plugin_save_state(p, context.temp_allocator)
	testing.expect_value(t, serr, core.Error.None)
	core.node_destroy(&node)
	again, q, _ := clap.plugin_create(lib, "dev.fire-engine.odin.gain", {})
	defer core.node_destroy(&again)
	testing.expect_value(t, clap.plugin_load_state(q, saved), core.Error.None)
	v, _ := clap.plugin_param_value(q, dsp.GAIN_PARAM_DB)
	testing.expect_value(t, v, -12)
	input := kit.buffer_make(2, 4_800, SR, context.temp_allocator)
	kit.sine(input.channels[0], SR, 440, 0.5)
	out := render_with(t, &again, input, kit.default_render_config())
	kit.expect_near(t, kit.linear_to_db(kit.peak(out.channels[0][2_400:])) , -6.0206 - 12, 0.01, "−12 dB, from the loaded state")
	// Latency: the limiter's lookahead.
	lim, _, _ := clap.plugin_create(lib, "dev.fire-engine.odin.limiter", {})
	defer core.node_destroy(&lim)
	render_with(t, &lim, input, kit.default_render_config())
	testing.expect_value(t, core.node_latency(&lim), 239)
}

// A hosted plug-in in a graph is saved with its library, id and state, and
// loads back through the registry sounding the same.
@(test)
hosted_plugins_save_with_the_graph :: proc(t: ^testing.T) {
	lib, err := clap.library_open(odin_bundle())
	if !testing.expect_value(t, err, core.Error.None) do return
	defer clap.library_close(lib)
	reg: core.Node_Registry
	core.registry_init(&reg)
	defer core.registry_destroy(&reg)
	clap.register_types(&reg)
	graph.register_types(&reg)

	st := graph.default_settings(SR, 512)
	st.workers = 0
	a, _ := graph.create(st)
	node, _, _ := clap.plugin_create(lib, "dev.fire-engine.odin.gain", {})
	id, _ := graph.add_node(a, node, 2, 2)
	graph.set_param_ramp(a, id, dsp.GAIN_PARAM_DB, -9, 0)
	for c in 0 ..< 2 {
		graph.connect(a, graph.INPUT, c, id, c)
		graph.connect(a, id, c, graph.OUTPUT, c)
	}
	graph.commit(a)
	input := kit.buffer_make(2, 9_600, SR, context.temp_allocator)
	kit.sine(input.channels[0], SR, 440, 0.5)
	kit.sine(input.channels[1], SR, 330, 0.5)
	an := graph.as_node(a)
	want := render_with(t, &an, input, kit.default_render_config()) // the plug-in now holds -9 dB itself
	w: core.State_Writer
	core.state_writer_init(&w, context.temp_allocator)
	testing.expect_value(t, graph.save(a, &w, nil), core.Error.None)
	data, _ := core.state_writer_bytes(&w)
	graph.destroy(a)

	b, _ := graph.create(st)
	defer graph.destroy(b)
	r := core.state_reader(data)
	c, _ := core.read_chunk(&r)
	ctx := core.Load_Context{registry = &reg, allocator = context.allocator}
	res, lerr := graph.load(b, c, &ctx)
	defer graph.load_result_destroy(&res)
	testing.expect_value(t, lerr, core.Error.None)
	testing.expect_value(t, len(res.missing), 0)
	bn := graph.as_node(b)
	got := render_with(t, &bn, input, kit.default_render_config())
	testing.expectf(t, kit.compare_buffers(want, got).max_abs_error == 0, "loaded plug-in differs by %v", kit.compare_buffers(want, got).max_abs_error)
	kit.expect_near(t, kit.linear_to_db(kit.peak(got.channels[0][4_800:])), -6.0206 - 9, 0.01, "-9 dB after loading")
}
