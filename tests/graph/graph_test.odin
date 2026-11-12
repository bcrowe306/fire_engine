package test_graph

import "base:intrinsics"
import "core:mem"
import "core:math"
import "core:testing"

import "fire:core"
import "fire:dsp"
import "fire:graph"
import kit "fire:testkit"
import tb "fire:timebase"

SR :: 48_000.0
MAX_BLOCK :: 256

// --- test nodes -------------------------------------------------------------------------

// out = in * gain on every channel.
Scale :: struct {
	gain:      f32,
	destroyed: ^int, // counts destroy calls, if set
}

scale_vtable := core.Node_VTable {
	prepare = proc(self: rawptr, cfg: core.Prepare_Config, a: mem.Allocator) -> core.Error { return .None },
	process = proc(self: rawptr, ctx: ^core.Process_Context) {
		k := (^Scale)(self).gain
		for out, c in ctx.outputs {
			for &s, i in out do s = ctx.inputs[c][i] * k if c < len(ctx.inputs) else 0
		}
	},
	destroy = proc(self: rawptr, a: mem.Allocator) {
		s := (^Scale)(self)
		if s.destroyed != nil do intrinsics.atomic_add(s.destroyed, 1)
		free(self, a)
	},
}

scale :: proc(gain: f32, destroyed: ^int = nil) -> core.Node {
	s := new(Scale)
	s.gain, s.destroyed = gain, destroyed
	return core.node_make(&scale_vtable, s, context.allocator)
}

// Delays every channel by `frames` and reports it as latency.
Delay :: struct {
	frames: int,
	ring:   [][]f32,
	pos:    int,
}

delay_vtable := core.Node_VTable {
	prepare = proc(self: rawptr, cfg: core.Prepare_Config, a: mem.Allocator) -> core.Error {
		d := (^Delay)(self)
		d.ring = make([][]f32, cfg.out_channels, a)
		for &r in d.ring do r = make([]f32, d.frames, a)
		return .None
	},
	process = proc(self: rawptr, ctx: ^core.Process_Context) {
		d := (^Delay)(self)
		for out, c in ctx.outputs {
			pos := d.pos
			for &s, i in out {
				x := ctx.inputs[c][i] if c < len(ctx.inputs) else 0
				s = d.ring[c][pos]
				d.ring[c][pos] = x
				pos = (pos + 1) % d.frames
			}
		}
		d.pos = (d.pos + ctx.frames) % d.frames
	},
	release = proc(self: rawptr, a: mem.Allocator) {
		d := (^Delay)(self)
		for r in d.ring do delete(r, a)
		delete(d.ring, a)
	},
	destroy = proc(self: rawptr, a: mem.Allocator) { free(self, a) },
	latency = proc(self: rawptr) -> int { return (^Delay)(self).frames },
}

delay :: proc(frames: int) -> core.Node {
	d := new(Delay)
	d.frames = frames
	return core.node_make(&delay_vtable, d, context.allocator)
}

new_graph :: proc(t: ^testing.T, channels := 2, compensation := true, workers := 0) -> ^graph.Graph {
	st := graph.default_settings(SR, MAX_BLOCK)
	st.input_channels, st.output_channels = channels, channels
	st.latency_compensation = compensation
	st.workers = workers
	st.parallel_min_us = 0 // exercise the parallel path whenever there are workers
	g, err := graph.create(st)
	testing.expect_value(t, err, core.Error.None)
	return g
}

expect_ok :: proc(t: ^testing.T, err: core.Error, loc := #caller_location) {
	testing.expect_value(t, err, core.Error.None, loc = loc)
}

noise :: proc(channels, frames: int, seed: u64) -> kit.Audio_Buffer {
	b := kit.buffer_make(channels, frames, SR, context.temp_allocator)
	for c in 0 ..< channels do kit.white_noise(b.channels[c], seed + u64(c), 0.5)
	return b
}

render :: proc(t: ^testing.T, g: ^graph.Graph, input: kit.Audio_Buffer, cfg: kit.Render_Config) -> kit.Audio_Buffer {
	n := graph.as_node(g)
	out, report := kit.render(&n, input, cfg, context.temp_allocator)
	defer kit.render_report_destroy(&report)
	kit.expect_clean_render(t, report)
	return out
}

render_cfg :: proc(channels := 2) -> kit.Render_Config {
	cfg := kit.default_render_config()
	cfg.max_block = MAX_BLOCK
	cfg.out_channels = channels
	cfg.blocks = kit.Random_Blocks{seed = 7, min = 0, max = MAX_BLOCK}
	return cfg
}

// --- topology --------------------------------------------------------------------------

@(test)
passthrough :: proc(t: ^testing.T) {
	g := new_graph(t)
	defer graph.destroy(g)
	expect_ok(t, graph.connect(g, graph.INPUT, 0, graph.OUTPUT, 0))
	expect_ok(t, graph.connect(g, graph.INPUT, 1, graph.OUTPUT, 1))
	expect_ok(t, graph.commit(g))
	in_ := noise(2, 10_000, 1)
	out := render(t, g, in_, render_cfg())
	testing.expect_value(t, kit.compare_buffers(in_, out).max_abs_error, 0)
}

// in0 → ×0.5 → OUTPUT0, in0 → ×0.25 → OUTPUT0 (summed), in1 unconnected → silence.
@(test)
fan_out_and_summing :: proc(t: ^testing.T) {
	g := new_graph(t)
	defer graph.destroy(g)
	a, err := graph.add_node(g, scale(0.5), 1, 1)
	expect_ok(t, err)
	b: graph.Node_Id
	b, err = graph.add_node(g, scale(0.25), 1, 1)
	expect_ok(t, err)
	expect_ok(t, graph.connect(g, graph.INPUT, 0, a, 0))
	expect_ok(t, graph.connect(g, graph.INPUT, 0, b, 0))
	expect_ok(t, graph.connect(g, a, 0, graph.OUTPUT, 0))
	expect_ok(t, graph.connect(g, b, 0, graph.OUTPUT, 0))
	expect_ok(t, graph.commit(g))

	in_ := noise(2, 10_000, 2)
	out := render(t, g, in_, render_cfg())
	worst: f32
	for x, i in in_.channels[0] do worst = max(worst, abs(out.channels[0][i] - (x * 0.5 + x * 0.25)))
	testing.expectf(t, worst == 0, "sum off by %v", worst)
	testing.expect_value(t, kit.peak(out.channels[1]), 0)
}

@(test)
invalid_edits_are_rejected :: proc(t: ^testing.T) {
	g := new_graph(t)
	defer graph.destroy(g)
	a, _ := graph.add_node(g, scale(1), 1, 1)
	b, _ := graph.add_node(g, scale(1), 1, 1)
	expect_ok(t, graph.connect(g, a, 0, b, 0))
	testing.expect_value(t, graph.connect(g, b, 0, a, 0), core.Error.Invalid_State)        // cycle
	testing.expect_value(t, graph.connect(g, a, 0, a, 0), core.Error.Invalid_State)        // self loop
	testing.expect_value(t, graph.connect(g, a, 0, b, 0), core.Error.Invalid_State)        // duplicate
	testing.expect_value(t, graph.connect(g, a, 1, b, 0), core.Error.Invalid_Argument)     // no such channel
	testing.expect_value(t, graph.connect(g, graph.OUTPUT, 0, a, 0), core.Error.Invalid_Argument) // OUTPUT has no outputs
	testing.expect_value(t, graph.connect_events(g, a, graph.INPUT), core.Error.Invalid_Argument)
	testing.expect_value(t, graph.remove_node(g, graph.INPUT), core.Error.Invalid_Argument)
	expect_ok(t, graph.remove_node(g, a))
	testing.expect_value(t, graph.connect(g, a, 0, b, 0), core.Error.Invalid_Argument)     // stale ID
	testing.expect(t, graph.get_node(g, a) == nil)
	c, _ := graph.add_node(g, scale(1), 1, 1) // reuses a's slot with a new generation
	testing.expect(t, c.index == a.index && c.generation != a.generation)
	testing.expect_value(t, graph.connect(g, a, 0, c, 0), core.Error.Invalid_Argument)
}

// --- events and parameters ---------------------------------------------------------------

// Events from the caller reach a node at exact frames, whatever the blocks.
@(test)
events_reach_nodes_sample_accurately :: proc(t: ^testing.T) {
	for pattern in kit.standard_block_patterns(MAX_BLOCK) {
		g := new_graph(t, 0) // events only
		defer graph.destroy(g)
		node, probe := kit.probe_create(1024)
		id, err := graph.add_node(g, node, 0, 0)
		expect_ok(t, err)
		expect_ok(t, graph.connect_events(g, graph.INPUT, id))
		expect_ok(t, graph.commit(g))
		cfg := render_cfg(0)
		cfg.blocks = pattern
		times := []i64{0, 1, 255, 256, 257, 1000, 4095}
		events := make([]kit.Timed_Event, len(times), context.temp_allocator)
		for at, i in times do events[i] = {tb.Sample_Time(at), core.Note_On{key = u8(i)}}
		cfg.events = events
		render(t, g, kit.buffer_length_only(5000, SR), cfg)
		got := kit.probe_events(probe)
		testing.expect_value(t, len(got), len(times))
		for e, i in got do testing.expectf(t, i64(e.absolute) == times[i], "%v: event %d at %d, want %d", pattern, i, e.absolute, times[i])
	}
}

// Parameter changes queued before playback land at their graph times exactly.
@(test)
params_are_sample_accurate :: proc(t: ^testing.T) {
	for pattern in kit.standard_block_patterns(MAX_BLOCK) {
		g := new_graph(t, 0) // events only
		defer graph.destroy(g)
		node, probe := kit.probe_create(1024)
		id, _ := graph.add_node(g, node, 0, 0)
		expect_ok(t, graph.commit(g))
		ats := []i64{0, 700, 700, 2048, 3001}
		for at, i in ats do expect_ok(t, graph.set_param(g, id, core.Param_Id(i + 1), f64(i), at))
		cfg := render_cfg(0)
		cfg.blocks = pattern
		render(t, g, kit.buffer_length_only(4000, SR), cfg)
		got := kit.probe_events(probe)
		testing.expect_value(t, len(got), len(ats))
		for e, i in got {
			pv := e.payload.(core.Param_Value)
			testing.expectf(t, i64(e.absolute) == ats[i] && pv.param == core.Param_Id(i + 1), "%v: param %d at %d, want %v at %d", pattern, pv.param, e.absolute, i + 1, ats[i])
		}
		testing.expect_value(t, graph.stats(g).params_dropped, 0)
	}
}

// Ramps arrive as Param_Ramp events at their graph times, mixed in order
// with plain values.
@(test)
param_ramps_are_sample_accurate :: proc(t: ^testing.T) {
	g := new_graph(t, 0)
	defer graph.destroy(g)
	node, probe := kit.probe_create(1024)
	id, _ := graph.add_node(g, node, 0, 0)
	expect_ok(t, graph.commit(g))
	expect_ok(t, graph.set_param_ramp(g, id, 5, 0.5, 1200, 333))
	expect_ok(t, graph.set_param(g, id, 6, 2, 900))
	testing.expect_value(t, graph.set_param_ramp(g, id, 5, 1, -1), core.Error.Invalid_Argument)
	render(t, g, kit.buffer_length_only(2000, SR), render_cfg(0))
	got := kit.probe_events(probe)
	if !testing.expect_value(t, len(got), 2) do return
	testing.expect_value(t, i64(got[0].absolute), 333)
	testing.expect_value(t, got[0].payload.(core.Param_Ramp), core.Param_Ramp{5, 0.5, 1200})
	testing.expect_value(t, i64(got[1].absolute), 900)
	testing.expect_value(t, got[1].payload.(core.Param_Value), core.Param_Value{6, 2})
}

// A real node (dsp gain) driven by a sample-accurate parameter.
@(test)
param_drives_gain_node :: proc(t: ^testing.T) {
	g := new_graph(t, 1)
	defer graph.destroy(g)
	gain, _ := graph.add_node(g, dsp.gain_create(), 1, 1)
	expect_ok(t, graph.connect(g, graph.INPUT, 0, gain, 0))
	expect_ok(t, graph.connect(g, gain, 0, graph.OUTPUT, 0))
	expect_ok(t, graph.commit(g))
	expect_ok(t, graph.set_param(g, gain, dsp.GAIN_PARAM_DB, -96, 5000)) // silence after a 20 ms ramp
	in_ := kit.buffer_make(1, 10_000, SR, context.temp_allocator)
	kit.dc(in_.channels[0], 1)
	out := render(t, g, in_, render_cfg(1))
	testing.expect_value(t, out.channels[0][4999], 1)   // untouched until the change
	testing.expect(t, out.channels[0][5001] < 1)         // ramping from frame 5000
	testing.expect_value(t, out.channels[0][9999], 0)   // ramp (960 frames) done
}

// --- latency compensation -----------------------------------------------------------------

// OUTPUT0 = delay(37)(x) + (−1)·x. Compensation delays the direct path by 37,
// so they cancel exactly; without it they don't.
@(test)
latency_compensation_aligns_paths :: proc(t: ^testing.T) {
	for compensation in ([]bool{true, false}) {
		g := new_graph(t, 1, compensation)
		defer graph.destroy(g)
		d, _ := graph.add_node(g, delay(37), 1, 1)
		inv, _ := graph.add_node(g, scale(-1), 1, 1)
		expect_ok(t, graph.connect(g, graph.INPUT, 0, d, 0))
		expect_ok(t, graph.connect(g, graph.INPUT, 0, inv, 0))
		expect_ok(t, graph.connect(g, d, 0, graph.OUTPUT, 0))
		expect_ok(t, graph.connect(g, inv, 0, graph.OUTPUT, 0))
		expect_ok(t, graph.commit(g))
		testing.expect_value(t, graph.latency(g), 37)
		out := render(t, g, noise(1, 8000, 3), render_cfg(1))
		if compensation {
			testing.expectf(t, kit.peak(out.channels[0]) == 0, "paths did not cancel: peak %v", kit.peak(out.channels[0]))
		} else {
			testing.expect(t, kit.peak(out.channels[0]) > 0.1, "paths cancelled without compensation")
		}
	}
}

// Events joining a delayed audio path are delayed to match.
@(test)
events_are_latency_compensated :: proc(t: ^testing.T) {
	g := new_graph(t, 1)
	defer graph.destroy(g)
	d, _ := graph.add_node(g, delay(37), 1, 1)
	node, probe := kit.probe_create(1024)
	p, _ := graph.add_node(g, node, 1, 1)
	expect_ok(t, graph.connect(g, graph.INPUT, 0, d, 0))
	expect_ok(t, graph.connect(g, d, 0, p, 0))
	expect_ok(t, graph.connect_events(g, graph.INPUT, p))
	expect_ok(t, graph.commit(g))
	cfg := render_cfg(1)
	cfg.events = []kit.Timed_Event{{100, core.Note_On{key = 60}}, {300, core.Note_Off{key = 60}}}
	render(t, g, kit.buffer_make(1, 2000, SR, context.temp_allocator), cfg)
	got := kit.probe_events(probe)
	testing.expect_value(t, len(got), 2)
	if len(got) == 2 {
		testing.expect_value(t, got[0].absolute, 137)
		testing.expect_value(t, got[1].absolute, 337)
	}
}

// --- edits while running ------------------------------------------------------------------

Edit_State :: struct {
	g:         ^graph.Graph,
	destroyed: int,
	victim:  graph.Node_Id,
	t:       ^testing.T,
	at:      int, // block index of the edit
}

// Removing a node mid-render: the change lands at a block boundary, nothing
// is allocated on the audio side, and the node is destroyed only after the
// audio thread has dropped the plan that used it.
@(test)
edits_apply_between_blocks :: proc(t: ^testing.T) {
	g := new_graph(t, 1)
	defer graph.destroy(g)
	st := Edit_State{g = g, t = t, at = 20}
	x2, _ := graph.add_node(g, scale(2, &st.destroyed), 1, 1)
	st.victim = x2
	expect_ok(t, graph.connect(g, graph.INPUT, 0, x2, 0))
	expect_ok(t, graph.connect(g, x2, 0, graph.OUTPUT, 0))
	expect_ok(t, graph.commit(g))

	cfg := render_cfg(1)
	cfg.blocks = kit.Fixed_Blocks{100}
	cfg.user = &st
	cfg.after_block = proc(user: rawptr, block: int, ctx: ^core.Process_Context) {
		st := (^Edit_State)(user)
		if block != st.at do return
		// Control-thread work between blocks: replace ×2 with a direct wire.
		testing.expect_value(st.t, graph.remove_node(st.g, st.victim), core.Error.None)
		testing.expect_value(st.t, graph.connect(st.g, graph.INPUT, 0, graph.OUTPUT, 0), core.Error.None)
		testing.expect_value(st.t, graph.commit(st.g), core.Error.None)
		testing.expect_value(st.t, st.destroyed, 0) // still in the current plan
	}
	in_ := kit.buffer_make(1, 5000, SR, context.temp_allocator)
	kit.dc(in_.channels[0], 1)
	out := render(t, g, in_, cfg)
	testing.expect_value(t, out.channels[0][2099], 2) // block 20 still ×2
	testing.expect_value(t, out.channels[0][2100], 1) // block 21 uses the new plan
	graph.collect(g)
	testing.expect_value(t, st.destroyed, 1) // retired by the audio side, then collected
}

// --- the graph as a node ----------------------------------------------------------------

graph_factory :: kit.Node_Factory {
	create = proc(user: rawptr) -> core.Node {
		st := graph.default_settings(SR, MAX_BLOCK)
		st.workers = 0
		g, _ := graph.create(st)
		d, _ := graph.add_node(g, delay(13), 2, 2)
		gain, _ := graph.add_node(g, dsp.gain_create(), 2, 2)
		for c in 0 ..< 2 {
			graph.connect(g, graph.INPUT, c, d, c)
			graph.connect(g, d, c, gain, c)
			graph.connect(g, graph.INPUT, c, graph.OUTPUT, c)
			graph.connect(g, gain, c, graph.OUTPUT, c)
		}
		graph.connect_events(g, graph.INPUT, gain)
		graph.commit(g)
		return graph.as_node(g)
	},
}

// The same output for every block pattern, with events routed to a gain node.
@(test)
graph_is_block_size_invariant :: proc(t: ^testing.T) {
	cfg := render_cfg()
	cfg.events = []kit.Timed_Event{{1000, core.Param_Value{dsp.GAIN_PARAM_DB, -12}}, {3333, core.Param_Value{dsp.GAIN_PARAM_DB, 6}}}
	patterns := kit.standard_block_patterns(MAX_BLOCK)
	kit.expect_block_invariant(t, graph_factory, noise(2, 6000, 4), cfg, patterns[:], 0, "graph")
}

// A parameter set on a node just added (before the commit that adds it to
// the audio thread's plan) is where it starts, though the audio thread
// runs a block in between: on a device the audio thread may take the
// change before it has the new plan. (It was dropped: a pad's fader at
// 0 dB after a project opened.) It starts there at once, without a glide.
@(test)
a_parameter_set_before_its_node_is_committed_is_kept :: proc(t: ^testing.T) {
	g := new_graph(t, 1)
	defer graph.destroy(g)
	expect_ok(t, graph.connect(g, graph.INPUT, 0, graph.OUTPUT, 0))
	expect_ok(t, graph.commit(g))
	in_ := kit.buffer_make(1, 2_000, SR, context.temp_allocator)
	kit.dc(in_.channels[0], 1)
	render(t, g, in_, render_cfg(1))
	// The new node, its value, and a block of the old plan before the commit.
	gain, _ := graph.add_node(g, dsp.gain_create(), 1, 1)
	expect_ok(t, graph.set_param(g, gain, dsp.GAIN_PARAM_DB, -12))
	render(t, g, in_, render_cfg(1))
	expect_ok(t, graph.disconnect(g, graph.INPUT, 0, graph.OUTPUT, 0))
	expect_ok(t, graph.connect(g, graph.INPUT, 0, gain, 0))
	expect_ok(t, graph.connect(g, gain, 0, graph.OUTPUT, 0))
	expect_ok(t, graph.commit(g))
	out := render(t, g, in_, render_cfg(1))
	want := f32(math.pow(10, -12.0 / 20))
	testing.expectf(t, abs(out.channels[0][0] - want) < 1e-4, "from its first frame (%v)", out.channels[0][0])
	testing.expectf(t, abs(out.channels[0][1999] - want) < 1e-4, "and on (%v)", out.channels[0][1999])
	testing.expect_value(t, graph.stats(g).params_dropped, 0)
}
