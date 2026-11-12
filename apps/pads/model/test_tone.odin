package pads_model

import "core:math"
import "core:mem"
import "core:time"

import app "app:core"
import fc "fire:core"
import "fire:graph"

// A test tone on an output pair, to find which speaker (or headphones) it
// is: a second of 440 Hz at -12 dB, faded in and out, straight to the
// pair's channels; the engine takes it out again after.

@(private)
Tone :: struct {
	rate:  f64,
	phase: f64,
	at:    int, // frames played
}

@(private)
tone_vtable := fc.Node_VTable {
	prepare = proc(self: rawptr, cfg: fc.Prepare_Config, allocator: mem.Allocator) -> fc.Error {
		(^Tone)(self).rate = cfg.sample_rate
		return .None
	},
	process = proc(self: rawptr, ctx: ^fc.Process_Context) {
		t := (^Tone)(self)
		total := int(t.rate) // a second
		fade := int(t.rate * 0.02)
		for i in 0 ..< ctx.frames {
			v: f32 = 0
			if t.at < total {
				env := min(f64(t.at) / f64(fade), f64(total - t.at) / f64(fade), 1)
				v = f32(math.sin(t.phase) * 0.25 * env)
				t.phase += 2 * math.PI * 440 / t.rate
				if t.phase > 2 * math.PI do t.phase -= 2 * math.PI
				t.at += 1
			}
			for o in ctx.outputs do o[i] = v
		}
	},
	reset   = proc(self: rawptr) {},
	release = proc(self: rawptr, allocator: mem.Allocator) {},
	destroy = proc(self: rawptr, allocator: mem.Allocator) { free((^Tone)(self), allocator) },
	type_id = "pads.test_tone",
}

// Plays the test tone on device output pair `first` (0-based), if open.
test_tone :: proc(e: ^Engine, first: int) -> bool {
	g := e.host.graph
	l, r, ok := out_pair(e, first)
	if !ok do return false
	tone_stop(e)
	id, err := graph.add_node(g, fc.node_make(&tone_vtable, new(Tone), context.allocator), 0, 2)
	if err != .None do return false
	graph.connect(g, id, 0, graph.OUTPUT, l)
	graph.connect(g, id, 1, graph.OUTPUT, r)
	graph.commit(g)
	e.tone_id, e.tone_until = id, time.tick_add(time.tick_now(), 1200 * time.Millisecond)
	return true
}

// [sync] The test tone out, once it has played.
@(private)
tone_frame :: proc(e: ^Engine) {
	if e.tone_id != {} && time.tick_diff(e.tone_until, time.tick_now()) > 0 do tone_stop(e)
}

@(private)
tone_stop :: proc(e: ^Engine) {
	if e.tone_id == {} do return
	graph.remove_node(e.host.graph, e.tone_id)
	graph.commit(e.host.graph)
	e.tone_id = {}
}

_ :: app.Host
