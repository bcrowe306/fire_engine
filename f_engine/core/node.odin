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
}

Node_State :: enum u8 {
	Initialized,
	Prepared,
	Released,
}

Node :: struct {
	vtable:    ^Node_VTable,
	data:      rawptr,
	state:     Node_State,
	config:    Prepare_Config,
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

// Legal from Initialized, Released, or Prepared (re-prepare releases first).
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

// [rt]
node_process :: #force_inline proc(n: ^Node, ctx: ^Process_Context) {
	assert(n.state == .Prepared, "node_process called on a node that is not prepared")
	assert(ctx.frames >= 0 && ctx.frames <= n.config.max_block, "process frames exceed max_block")
	n.vtable.process(n.data, ctx)
}

// [rt]
node_reset :: proc(n: ^Node) {
	assert(n.state == .Prepared, "node_reset called on a node that is not prepared")
	if n.vtable.reset != nil do n.vtable.reset(n.data)
}

node_release :: proc(n: ^Node) {
	if n.state != .Prepared do return
	if n.vtable.release != nil do n.vtable.release(n.data, n.allocator)
	n.state = .Released
}

node_params :: proc(n: ^Node) -> []Param_Info {
	if n.vtable.params == nil do return nil
	return n.vtable.params(n.data)
}

find_param :: proc(params: []Param_Info, id: Param_Id) -> (Param_Info, bool) {
	for p in params {
		if p.id == id do return p, true
	}
	return {}, false
}

// Frames of latency the node reports (0 if it doesn't). Control thread.
node_latency :: proc(n: ^Node) -> int {
	if n.vtable == nil || n.vtable.latency == nil do return 0
	return max(n.vtable.latency(n.data), 0)
}
