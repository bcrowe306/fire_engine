package pads_model

import "core:mem"

import fc "fire:core"

// A track's own event stream, into its device: what the router decided
// that track plays this block (its notes in its device's keys, its chokes,
// its expressions). The router fills `Router.tracks[index]`; this node,
// after it in the graph (an event connection from the router), sends them
// on to the device. So each device sees only its own notes, in its own
// keys: a sampler on its pad's key, a slicer one key a slice.
@(private)
Track_In :: struct {
	router: ^Router,
	index:  int,
}

@(private)
track_in_vtable := fc.Node_VTable {
	prepare = proc(self: rawptr, cfg: fc.Prepare_Config, a: mem.Allocator) -> fc.Error { return .None },
	process = track_in_process,
	destroy = proc(self: rawptr, a: mem.Allocator) { free((^Track_In)(self), a) },
}

// Control thread. Track `index`'s stream node.
@(private)
track_in_create :: proc(r: ^Router, index: int, allocator := context.allocator) -> fc.Node {
	t := new(Track_In, allocator)
	t.router, t.index = r, index
	return fc.node_make(&track_in_vtable, t, allocator)
}

// [rt]
@(private)
track_in_process :: proc(self: rawptr, ctx: ^fc.Process_Context) {
	t := (^Track_In)(self)
	if ctx.events_out == nil do return
	tr := &t.router.tracks[t.index]
	for e in tr.events[:tr.count] do fc.event_writer_push(ctx.events_out, e)
}
