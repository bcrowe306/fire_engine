package perform

import "core:mem"

import "fire:core"
import "fire:rt"

// A graph node running an `Arp` on the events it receives (no audio).
// Change its settings from the control thread with `arp_node_set`.
Arp_Node :: struct {
	arp:     Arp,
	pending: rt.Spsc_Queue(Arp_Settings),
}

// A graph node running a `Repeat` on the events it receives (no audio).
Repeat_Node :: struct {
	repeat:  Repeat,
	pending: rt.Spsc_Queue(Repeat_Settings),
}

@(private)
arp_node_vtable := core.Node_VTable {
	prepare = proc(self: rawptr, cfg: core.Prepare_Config, a: mem.Allocator) -> core.Error { return .None },
	process = proc(self: rawptr, ctx: ^core.Process_Context) {
		n := (^Arp_Node)(self)
		for s in rt.spsc_pop(&n.pending) do arp_set(&n.arp, s)
		arp_process(&n.arp, ctx.transport, ctx.frames, ctx.events_in, ctx.events_out)
	},
	reset = proc(self: rawptr) { arp_reset(&(^Arp_Node)(self).arp, nil) },
	destroy = proc(self: rawptr, a: mem.Allocator) {
		n := (^Arp_Node)(self)
		rt.spsc_destroy(&n.pending, a)
		free(n, a)
	},
}

// Control thread. An arpeggiator node and its handle (valid until the
// graph destroys the node).
arp_node_create :: proc(settings: Arp_Settings, allocator := context.allocator) -> (core.Node, ^Arp_Node) {
	n := new(Arp_Node, allocator)
	arp_init(&n.arp, settings)
	rt.spsc_init(&n.pending, 16, allocator)
	return core.node_make(&arp_node_vtable, n, allocator), n
}

// Control thread. New settings for the node, from its next block. False if
// too many are waiting (try again next frame).
arp_node_set :: proc(n: ^Arp_Node, settings: Arp_Settings) -> bool {
	return rt.spsc_push(&n.pending, settings)
}

@(private)
repeat_node_vtable := core.Node_VTable {
	prepare = proc(self: rawptr, cfg: core.Prepare_Config, a: mem.Allocator) -> core.Error { return .None },
	process = proc(self: rawptr, ctx: ^core.Process_Context) {
		n := (^Repeat_Node)(self)
		for s in rt.spsc_pop(&n.pending) do repeat_set(&n.repeat, s)
		repeat_process(&n.repeat, ctx.transport, ctx.frames, ctx.events_in, ctx.events_out)
	},
	reset = proc(self: rawptr) { repeat_reset(&(^Repeat_Node)(self).repeat, nil) },
	destroy = proc(self: rawptr, a: mem.Allocator) {
		n := (^Repeat_Node)(self)
		rt.spsc_destroy(&n.pending, a)
		free(n, a)
	},
}

// Control thread. A note repeat node and its handle.
repeat_node_create :: proc(settings: Repeat_Settings, allocator := context.allocator) -> (core.Node, ^Repeat_Node) {
	n := new(Repeat_Node, allocator)
	repeat_init(&n.repeat, settings)
	rt.spsc_init(&n.pending, 16, allocator)
	return core.node_make(&repeat_node_vtable, n, allocator), n
}

// Control thread. New settings for the node, from its next block.
repeat_node_set :: proc(n: ^Repeat_Node, settings: Repeat_Settings) -> bool {
	return rt.spsc_push(&n.pending, settings)
}
