package core

import "core:mem"

// A node is a vtable + opaque state, so statically linked nodes and nodes loaded
// from the device SDK look the same to the graph.
Node_VTable :: struct {
	// Control thread. Allocate and size everything `process` will need.
	prepare: proc(self: rawptr, cfg: Prepare_Config, allocator: mem.Allocator) -> Error,
	// [rt] Must not allocate, lock, or fail.
	process: proc(self: rawptr, ctx: ^Process_Context),
	// [rt] Clear state without allocating.
	reset:   proc(self: rawptr),
	// Control thread. Free what `prepare` allocated.
	release: proc(self: rawptr, allocator: mem.Allocator),
	// Static parameter table (may be nil for nodes without parameters).
	params:  proc(self: rawptr) -> []Param_Info,
	// Control thread. Free the node's own state (the inverse of its `*_create`).
	destroy: proc(self: rawptr, allocator: mem.Allocator),
	// Control thread, after prepare. Frames by which the output lags the
	// input (lookahead, linear-phase filters, plugin latency). May be nil: 0.
	// The graph delays parallel paths to compensate.
	latency: proc(self: rawptr) -> int,
	// The ID this node type is registered under for loading saved state
	// (see `Node_Registry`), such as "fire.gain". "" = cannot be saved.
	type_id: string,
	// Version of what `save` writes; the loader receives it.
	state_version: u32,
	// Control thread. Writes what the type's `Node_Loader` needs to make the
	// node again: construction settings and any state its parameters do not
	// hold (the graph saves parameter values itself). May be nil: nothing.
	save: proc(self: rawptr, w: ^State_Writer, ctx: ^Save_Context) -> Error,
}

// Lifecycle state of a `Node`, tracked by `node_prepare` and `node_release`.
Node_State :: enum u8 {
	Initialized, // created, not yet prepared
	Prepared,    // ready for process and reset
	Released,    // prepare's allocations freed; may be prepared again
}

// Handle to a node: its vtable, its opaque state and lifecycle bookkeeping.
// Create with a node type's `*_create` proc and free with `node_destroy`.
Node :: struct {
	vtable:    ^Node_VTable,
	data:      rawptr,         // the node type's own state
	state:     Node_State,
	config:    Prepare_Config, // the config of the last successful prepare
	allocator: mem.Allocator, // the allocator `prepare` used, reused by `release`
	create_allocator: mem.Allocator, // the allocator that owns `data`
}

// Called by each node type's `*_create` proc after allocating its state.
node_make :: proc "contextless" (vtable: ^Node_VTable, data: rawptr, allocator: mem.Allocator) -> Node {
	return Node{vtable = vtable, data = data, state = .Initialized, create_allocator = allocator}
}

// Releases (if prepared) and frees the node's state.
node_destroy :: proc(n: ^Node) {
	node_release(n)
	if n.vtable != nil && n.vtable.destroy != nil do n.vtable.destroy(n.data, n.create_allocator)
	n^ = {}
}

// Control thread. Allocates and sizes everything `process` needs for `cfg`.
// Legal from Initialized, Released, or Prepared (re-prepare releases first).
// Returns `.Invalid_Argument` for a bad config, or the node's own error.
// `allocator` is kept and reused by `node_release`.
node_prepare :: proc(n: ^Node, cfg: Prepare_Config, allocator := context.allocator) -> Error {
	if cfg.sample_rate <= 0 || cfg.max_block < 0 || cfg.in_channels > MAX_CHANNELS || cfg.out_channels > MAX_CHANNELS {
		return .Invalid_Argument
	}
	if n.state == .Prepared {
		node_release(n)
	}
	err := n.vtable.prepare(n.data, cfg, allocator)
	if err != .None do return err
	n.state = .Prepared
	n.config = cfg
	n.allocator = allocator
	return .None
}

// [rt] Processes one block. The node must be prepared and `ctx.frames` must
// not exceed the prepared `max_block` (both asserted).
node_process :: #force_inline proc(n: ^Node, ctx: ^Process_Context) {
	assert(n.state == .Prepared, "node_process called on a node that is not prepared")
	assert(ctx.frames >= 0 && ctx.frames <= n.config.max_block, "process frames exceed max_block")
	n.vtable.process(n.data, ctx)
}

// [rt] Clears the node's state (delay lines, envelopes, voices) without
// allocating. The node must be prepared.
node_reset :: proc(n: ^Node) {
	assert(n.state == .Prepared, "node_reset called on a node that is not prepared")
	if n.vtable.reset != nil do n.vtable.reset(n.data)
}

// Control thread. Frees what `node_prepare` allocated; the node can be
// prepared again. Does nothing unless the node is prepared.
node_release :: proc(n: ^Node) {
	if n.state != .Prepared do return
	if n.vtable.release != nil do n.vtable.release(n.data, n.allocator)
	n.state = .Released
}

// The node's static parameter table, or nil if it has none. The slice is owned
// by the node type; do not free it.
node_params :: proc(n: ^Node) -> []Param_Info {
	if n.vtable.params == nil do return nil
	return n.vtable.params(n.data)
}

// Looks up the parameter with `id` in `params`. Returns false if absent.
find_param :: proc(params: []Param_Info, id: Param_Id) -> (Param_Info, bool) {
	for p in params {
		if p.id == id do return p, true
	}
	return {}, false
}

// Control thread. Writes the node's own state (see `Node_VTable.save`) as
// the payload of the current chunk. `.Unsupported` if the type cannot be
// saved.
node_save :: proc(n: ^Node, w: ^State_Writer, ctx: ^Save_Context) -> Error {
	if n.vtable == nil || n.vtable.type_id == "" do return .Unsupported
	if n.vtable.save == nil do return .None
	return n.vtable.save(n.data, w, ctx)
}

// Frames of latency the node reports (0 if it doesn't). Control thread.
node_latency :: proc(n: ^Node) -> int {
	if n.vtable == nil || n.vtable.latency == nil do return 0
	return max(n.vtable.latency(n.data), 0)
}
