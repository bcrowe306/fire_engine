package graph

import "core:mem"

import "fire:core"

// Single-threaded placeholder; the multithreaded scheduler replaces this.
@(private)
Schedule :: struct {}

@(private)
Pool :: struct {}

@(private)
pool_start :: proc(g: ^Graph) -> core.Error { return .None }

@(private)
pool_stop :: proc(g: ^Graph) {}

@(private)
sched_init :: proc(g: ^Graph, p: ^Plan, a: mem.Allocator) -> core.Error { return .None }

@(private)
sched_destroy :: proc(p: ^Plan) {}

@(private)
sched_quiesce :: proc(g: ^Graph, p: ^Plan) {}

// [rt] Runs every node, in topological order.
@(private)
sched_run :: proc(g: ^Graph, p: ^Plan, frames: int, t0: i64, transport: ^core.Transport) {
	for i in 0 ..< i32(len(p.nodes)) do run_node(g, p, i, frames, t0, transport)
}
