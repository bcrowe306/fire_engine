package test_session

import "core:math/rand"
import "core:mem"
import "core:testing"

import "fire:core"
import "fire:dsp"
import "fire:graph"
import kit "fire:testkit"

SR :: 48_000.0
MAX_BLOCK :: 256

// --- codec ---------------------------------------------------------------------------------

@(test)
values_and_chunks_round_trip :: proc(t: ^testing.T) {
	w: core.State_Writer
	core.state_writer_init(&w)
	defer core.state_writer_destroy(&w)
	core.begin_chunk(&w, {'T', 'E', 'S', 'T'}, 3)
	core.write_u8(&w, 7)
	core.write_bool(&w, true)
	core.write_u32(&w, 0xDEADBEEF)
	core.write_i64(&w, -42)
	core.write_f64(&w, 0.1)
	core.write_f32(&w, -2.5)
	core.write_string(&w, "héllo")
	core.write_f32s(&w, {1, 2, 3})
	core.write_chunk(&w, {'U', 'N', 'K', 'N'}, 9, {1, 2, 3, 4, 5}) // a newer writer's chunk
	core.begin_chunk(&w, {'K', 'I', 'D', ' '}, 1)
	core.write_int(&w, 99)
	core.end_chunk(&w)
	core.end_chunk(&w)
	data, err := core.state_writer_bytes(&w)
	testing.expect_value(t, err, core.Error.None)

	r := core.state_reader(data)
	c, ok := core.read_chunk(&r)
	testing.expect(t, ok)
	testing.expect_value(t, c.tag, core.Tag{'T', 'E', 'S', 'T'})
	testing.expect_value(t, c.version, 3)
	testing.expect(t, core.reader_done(&r))
	cr := core.chunk_reader(c)
	testing.expect_value(t, core.read_u8(&cr), 7)
	testing.expect_value(t, core.read_bool(&cr), true)
	testing.expect_value(t, core.read_u32(&cr), 0xDEADBEEF)
	testing.expect_value(t, core.read_i64(&cr), -42)
	testing.expect_value(t, core.read_f64(&cr), 0.1)
	testing.expect_value(t, core.read_f32(&cr), -2.5)
	testing.expect_value(t, core.read_string(&cr), "héllo")
	samples := core.read_f32s(&cr, context.temp_allocator)
	testing.expect(t, len(samples) == 3 && samples[2] == 3)
	kid, found := core.find_chunk(&cr, {'K', 'I', 'D', ' '}) // skips the unknown one
	testing.expect(t, found)
	kr := core.chunk_reader(kid)
	testing.expect_value(t, core.read_int(&kr), 99)
	testing.expect_value(t, cr.err, core.Error.None)

	// An older reader reads only what it knows; what follows is skipped.
	short := core.chunk_reader(c)
	_ = core.read_u8(&short)
	testing.expect_value(t, short.err, core.Error.None)

	// A writer with a chunk left open has no result.
	w2: core.State_Writer
	core.state_writer_init(&w2)
	defer core.state_writer_destroy(&w2)
	core.begin_chunk(&w2, {'O', 'P', 'E', 'N'}, 1)
	_, err = core.state_writer_bytes(&w2)
	testing.expect_value(t, err, core.Error.Invalid_State)
}

// Truncated or random input is reported, never read out of bounds.
@(test)
malformed_input_is_rejected :: proc(t: ^testing.T) {
	w: core.State_Writer
	core.state_writer_init(&w)
	defer core.state_writer_destroy(&w)
	core.begin_chunk(&w, {'T', 'E', 'S', 'T'}, 1)
	core.write_string(&w, "abc")
	core.write_f32s(&w, {1, 2})
	core.end_chunk(&w)
	data, _ := core.state_writer_bytes(&w)
	for n in 0 ..< len(data) {
		r := core.state_reader(data[:n])
		c, ok := core.read_chunk(&r)
		if n == 0 {
			testing.expect(t, !ok && r.err == .None) // empty: just the end
			continue
		}
		testing.expectf(t, !ok && r.err == .Invalid_Data, "prefix %d read as a chunk", n)
		_ = c
	}
	// A chunk whose values claim more than it holds.
	r := core.state_reader(data)
	c, _ := core.read_chunk(&r)
	cr := core.chunk_reader({data = c.data[:5]})
	testing.expect_value(t, core.read_string(&cr), "")
	testing.expect_value(t, cr.err, core.Error.Invalid_Data)
	testing.expect_value(t, core.read_u64(&cr), 0) // sticky

	// Random bytes, through the whole graph loader.
	reg := registry()
	defer core.registry_destroy(&reg)
	rng := rand.create(1)
	buf: [512]u8
	for _ in 0 ..< 2000 {
		n := int(rand.uint32(rand.default_random_generator(&rng)) % len(buf))
		for &b in buf[:n] do b = u8(rand.uint32(rand.default_random_generator(&rng)))
		// Half the time, a valid graph header so the fuzz reaches node parsing.
		if n > 16 && n % 2 == 0 {
			tag := graph.GRAPH_TAG
			copy(buf[:4], tag[:])
			size := u64(n - 16)
			for i in 0 ..< 8 do buf[8 + i] = u8(size >> (8 * uint(i)))
		}
		g := make_graph()
		rd := core.state_reader(buf[:n])
		if gc, ok := core.read_chunk(&rd); ok && gc.tag == graph.GRAPH_TAG {
			ctx := core.Load_Context{registry = &reg, allocator = context.allocator}
			res, _ := graph.load(g, gc, &ctx)
			graph.load_result_destroy(&res)
		}
		graph.destroy(g)
	}
}

// --- graphs --------------------------------------------------------------------------------

registry :: proc() -> core.Node_Registry {
	reg: core.Node_Registry
	core.registry_init(&reg)
	dsp.register_types(&reg)
	graph.register_types(&reg)
	return reg
}

make_graph :: proc(max_pending := 64) -> ^graph.Graph {
	st := graph.default_settings(SR, MAX_BLOCK)
	st.workers = 0 // deterministic and cheap
	st.max_pending_params = max_pending
	g, _ := graph.create(st)
	return g
}

add :: proc(t: ^testing.T, g: ^graph.Graph, n: core.Node, ins, outs: int) -> graph.Node_Id {
	id, err := graph.add_node(g, n, ins, outs)
	testing.expect_value(t, err, core.Error.None)
	return id
}

// Jumps, so the original and the loaded graph start from the same values.
jump :: proc(t: ^testing.T, g: ^graph.Graph, id: graph.Node_Id, p: core.Param_Id, v: f64) {
	testing.expect_value(t, graph.set_param_ramp(g, id, p, v, 0), core.Error.None)
}

// A graph using several node types, with summing, a nested graph, a
// constructor argument (filter mode, EQ bands, saturation oversampling),
// and a convolution's impulse response.
build_mix :: proc(t: ^testing.T, g: ^graph.Graph) {
	a := add(t, g, dsp.gain_create(), 2, 2)
	jump(t, g, a, dsp.GAIN_PARAM_DB, -6)
	hp := add(t, g, dsp.filter_create(.Highpass), 2, 2)
	jump(t, g, hp, dsp.FILTER_PARAM_CUTOFF_HZ, 800)
	eq := add(t, g, dsp.eq_create(6), 2, 2)
	jump(t, g, eq, dsp.eq_band_param(2, .Gain_Db), 9)
	sat := add(t, g, dsp.saturation_create(2), 2, 2)
	ir := [2][]f32{{1, 0.5, 0.25, 0.125}, {0.7, 0, 0.3}}
	conv := add(t, g, dsp.convolution_create(ir[:]), 2, 2)

	inner := make_graph()
	d := add(t, inner, dsp.delay_create(), 2, 2)
	for c in 0 ..< 2 {
		graph.connect(inner, graph.INPUT, c, d, c)
		graph.connect(inner, d, c, graph.OUTPUT, c)
	}
	graph.commit(inner)
	nest := add(t, g, graph.as_node(inner), 2, 2)

	for c in 0 ..< 2 {
		graph.connect(g, graph.INPUT, c, a, c)
		graph.connect(g, a, c, hp, c)
		graph.connect(g, hp, c, eq, c)
		graph.connect(g, a, c, sat, c)
		graph.connect(g, sat, c, conv, c)
		graph.connect(g, eq, c, nest, c)
		graph.connect(g, nest, c, graph.OUTPUT, c) // summed with...
		graph.connect(g, conv, c, graph.OUTPUT, c) // ...this
	}
	testing.expect_value(t, graph.commit(g), core.Error.None)
}

save_graph :: proc(t: ^testing.T, g: ^graph.Graph, allocator := context.allocator) -> []u8 {
	w: core.State_Writer
	core.state_writer_init(&w)
	defer core.state_writer_destroy(&w)
	testing.expect_value(t, graph.save(g, &w, nil), core.Error.None)
	data, err := core.state_writer_bytes(&w)
	testing.expect_value(t, err, core.Error.None)
	out := make([]u8, len(data), allocator)
	copy(out, data)
	return out
}

load_graph :: proc(t: ^testing.T, g: ^graph.Graph, data: []u8, reg: ^core.Node_Registry) -> graph.Load_Result {
	r := core.state_reader(data)
	c, ok := core.read_chunk(&r)
	testing.expect(t, ok)
	ctx := core.Load_Context{registry = reg, allocator = context.allocator}
	res, err := graph.load(g, c, &ctx)
	testing.expect_value(t, err, core.Error.None)
	return res
}

render_graph :: proc(t: ^testing.T, g: ^graph.Graph, input: kit.Audio_Buffer, seed: u64) -> kit.Audio_Buffer {
	cfg := kit.default_render_config()
	cfg.sample_rate = SR
	cfg.max_block = MAX_BLOCK
	cfg.blocks = kit.Random_Blocks{seed = seed, min = 0, max = MAX_BLOCK}
	n := graph.as_node(g)
	out, report := kit.render(&n, input, cfg, context.temp_allocator)
	defer kit.render_report_destroy(&report)
	kit.expect_clean_render(t, report)
	return out
}

noise :: proc() -> kit.Audio_Buffer {
	in_ := kit.buffer_make(2, 24_000, SR, context.temp_allocator)
	kit.white_noise(in_.channels[0], 1, 0.5)
	kit.white_noise(in_.channels[1], 2, 0.5)
	return in_
}

// A graph saved and loaded into a new graph sounds the same, sample for
// sample, at any block size.
@(test)
graph_round_trip_sounds_the_same :: proc(t: ^testing.T) {
	reg := registry()
	defer core.registry_destroy(&reg)
	input := noise()

	a := make_graph()
	build_mix(t, a)
	data := save_graph(t, a, context.temp_allocator)
	want := render_graph(t, a, input, 1)
	graph.destroy(a)

	b := make_graph()
	defer graph.destroy(b)
	res := load_graph(t, b, data, &reg)
	defer graph.load_result_destroy(&res)
	testing.expect_value(t, len(res.nodes), 6)
	testing.expect_value(t, len(res.missing), 0)
	got := render_graph(t, b, input, 2)
	cmp := kit.compare_buffers(want, got)
	testing.expectf(t, cmp.max_abs_error == 0, "loaded graph differs by up to %v at frame %d", cmp.max_abs_error, cmp.max_error_at)

	// Saving the loaded graph gives the same bytes.
	again := save_graph(t, b, context.temp_allocator)
	testing.expect(t, mem.compare(data, again) == 0)
}

// Unknown node types load as silent placeholders and save back unchanged.
@(test)
unknown_types_survive_a_round_trip :: proc(t: ^testing.T) {
	full := registry()
	defer core.registry_destroy(&full)
	a := make_graph()
	build_mix(t, a)
	data := save_graph(t, a, context.temp_allocator)
	graph.destroy(a)

	empty: core.Node_Registry
	core.registry_init(&empty)
	defer core.registry_destroy(&empty)
	b := make_graph()
	defer graph.destroy(b)
	res := load_graph(t, b, data, &empty)
	defer graph.load_result_destroy(&res)
	testing.expect_value(t, len(res.missing), 6)
	for m in res.missing {
		testing.expect_value(t, m.err, core.Error.Unsupported)
		testing.expect(t, graph.is_placeholder(b, m.id))
	}
	out := render_graph(t, b, noise(), 3)
	testing.expect_value(t, kit.peak(out.channels[0]), 0)
	again := save_graph(t, b, context.temp_allocator)
	testing.expect(t, mem.compare(data, again) == 0)

	// A loader that fails also leaves a placeholder (here: a corrupt filter mode).
	reg := registry()
	defer core.registry_destroy(&reg)
	core.register_type(&reg, {id = dsp.FILTER_TYPE_ID, load = proc(_: rawptr, r: ^core.State_Reader, v: u32, ctx: ^core.Load_Context, a: mem.Allocator) -> (core.Node, core.Error) {
		return {}, .Invalid_Data
	}})
	c := make_graph()
	defer graph.destroy(c)
	res2 := load_graph(t, c, data, &reg)
	defer graph.load_result_destroy(&res2)
	testing.expect_value(t, len(res2.missing), 1)
	if len(res2.missing) == 1 {
		testing.expect_value(t, res2.missing[0].type_id, dsp.FILTER_TYPE_ID)
		testing.expect_value(t, res2.missing[0].err, core.Error.Invalid_Data)
	}
}

// More starting values than fit in one block's parameter events all arrive
// (over the first blocks).
@(test)
many_parameters_reach_a_loaded_node :: proc(t: ^testing.T) {
	reg := registry()
	defer core.registry_destroy(&reg)
	a := make_graph(max_pending = 256)
	eq := add(t, a, dsp.eq_create(dsp.EQ_MAX_BANDS), 2, 2)
	for i in 0 ..< dsp.EQ_MAX_BANDS {
		jump(t, a, eq, dsp.eq_band_param(i, .Gain_Db), f64(i % 5) - 2)
		jump(t, a, eq, dsp.eq_band_param(i, .Q), 2)
	}
	for c in 0 ..< 2 {
		graph.connect(a, graph.INPUT, c, eq, c)
		graph.connect(a, eq, c, graph.OUTPUT, c)
	}
	graph.commit(a)
	data := save_graph(t, a, context.temp_allocator)
	input := noise()
	want := render_graph(t, a, input, 4)
	graph.destroy(a)

	b := make_graph(max_pending = 8) // 2 × bands values: several blocks' worth
	defer graph.destroy(b)
	res := load_graph(t, b, data, &reg)
	defer graph.load_result_destroy(&res)
	got := render_graph(t, b, input, 5)
	// Once every value has arrived (blocks may be 0 frames, so allow plenty),
	// the filters have the same coefficients; their state needs a little
	// longer to agree.
	from := 12_000
	cmp := kit.compare_slices(want.channels[0][from:], got.channels[0][from:])
	testing.expectf(t, cmp.max_abs_error < 1e-4, "differs by %v after all values arrived", cmp.max_abs_error)
}

// A graph can be replaced by a loaded one while it runs: one commit, no
// allocation on the audio thread.
@(test)
load_into_a_running_graph :: proc(t: ^testing.T) {
	reg := registry()
	defer core.registry_destroy(&reg)
	a := make_graph()
	build_mix(t, a)
	data := save_graph(t, a, context.temp_allocator)
	graph.destroy(a)

	g := make_graph()
	defer graph.destroy(g)
	gain := add(t, g, dsp.gain_create(), 2, 2)
	for c in 0 ..< 2 {
		graph.connect(g, graph.INPUT, c, gain, c)
		graph.connect(g, gain, c, graph.OUTPUT, c)
	}
	graph.commit(g)

	State :: struct {
		t:    ^testing.T,
		g:    ^graph.Graph,
		data: []u8,
		reg:  ^core.Node_Registry,
		res:  graph.Load_Result,
	}
	st := State{t, g, data, &reg, {}}
	cfg := kit.default_render_config()
	cfg.sample_rate = SR
	cfg.max_block = MAX_BLOCK
	cfg.blocks = kit.Random_Blocks{seed = 6, min = 0, max = MAX_BLOCK}
	cfg.user = &st
	cfg.after_block = proc(user: rawptr, block: int, ctx: ^core.Process_Context) {
		st := (^State)(user)
		if block != 20 do return
		for id in graph.nodes(st.g, context.temp_allocator) do graph.remove_node(st.g, id)
		st.res = load_graph(st.t, st.g, st.data, st.reg)
	}
	n := graph.as_node(g)
	out, report := kit.render(&n, noise(), cfg, context.temp_allocator)
	defer kit.render_report_destroy(&report)
	defer graph.load_result_destroy(&st.res)
	kit.expect_clean_render(t, report)
	testing.expect_value(t, len(st.res.nodes), 6)
	testing.expect_value(t, len(graph.nodes(g, context.temp_allocator)), 6)
	_ = out
}
