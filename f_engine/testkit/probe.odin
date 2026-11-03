package testkit

import "core:mem"

import "fire:core"
import tb "fire:timebase"

// A pass-through node that records what it observed on the audio thread:
// every event (with block index, offset, and absolute frame) and the transport at
// each block. Its log is preallocated in prepare, so recording never allocates.
//
// Use it to test the harness and, later, the graph and backends: anything that
// claims to deliver events sample-accurately can be checked against a Probe.

// One event as the probe received it.
Probe_Event :: struct {
	block:    int, // index of the process call
	offset:   u32, // frame offset within the block
	absolute: tb.Sample_Time, // transport.sample_pos + offset
	payload:  core.Event_Payload,
}

// One process call as the probe saw it.
Probe_Block :: struct {
	frames:    int,            // frames in this call
	transport: core.Transport, // copy of the transport at this call
}

// State of a probe node. Read the log with `probe_events` and `probe_blocks`; it
// stays valid after `render` releases the node, until the node is destroyed.
Probe :: struct {
	log_allocator:   mem.Allocator, // the log lives until destroy, so it can be read after release
	events:          []Probe_Event, // log storage; use probe_events
	event_count:     int,
	blocks:          []Probe_Block, // log storage; use probe_blocks
	block_count:     int,
	overflow:        int,           // events or blocks not recorded because the log was full
	unsorted_events: int, // events whose offset < previous offset in the same block
	out_of_range:    int, // events whose offset >= frames
	capacity:        int,           // log size, set by probe_create
}

@(private)
probe_vtable := core.Node_VTable {
	prepare = probe_prepare,
	process = probe_process,
	reset   = proc(self: rawptr) {},
	release = probe_release,
	destroy = proc(self: rawptr, allocator: mem.Allocator) {
		p := (^Probe)(self)
		delete(p.events, p.log_allocator)
		delete(p.blocks, p.log_allocator)
		free(p, allocator)
	},
}

// Creates a probe node and returns it along with its state. `capacity` is the number
// of events and of blocks the log holds (allocated in prepare with the prepare
// allocator). The node and state come from `allocator`; destroy with core.node_destroy.
probe_create :: proc(capacity := 65536, allocator := context.allocator) -> (core.Node, ^Probe) {
	p := new(Probe, allocator)
	p.capacity = capacity
	return core.node_make(&probe_vtable, p, allocator), p
}

// The events recorded so far, in arrival order. A view into the log, not a copy.
probe_events :: proc(p: ^Probe) -> []Probe_Event {
	return p.events[:p.event_count]
}

// The process calls recorded so far, in order. A view into the log, not a copy.
probe_blocks :: proc(p: ^Probe) -> []Probe_Block {
	return p.blocks[:p.block_count]
}

@(private)
probe_prepare :: proc(self: rawptr, cfg: core.Prepare_Config, allocator: mem.Allocator) -> core.Error {
	p := (^Probe)(self)
	delete(p.events, p.log_allocator) // re-prepare
	delete(p.blocks, p.log_allocator)
	p.log_allocator = allocator
	p.events = make([]Probe_Event, p.capacity, allocator)
	p.blocks = make([]Probe_Block, p.capacity, allocator)
	p.event_count, p.block_count, p.overflow = 0, 0, 0
	return .None
}

@(private)
probe_release :: proc(self: rawptr, allocator: mem.Allocator) {
	// Keep the log readable after render() releases the node; free it on destroy instead.
}

@(private)
probe_process :: proc(self: rawptr, ctx: ^core.Process_Context) {
	p := (^Probe)(self)
	block := p.block_count
	if p.block_count < len(p.blocks) {
		p.blocks[p.block_count] = {ctx.frames, ctx.transport^}
		p.block_count += 1
	} else {
		p.overflow += 1
	}

	prev: u32 = 0
	for e in ctx.events_in {
		if e.offset < prev do p.unsorted_events += 1
		if int(e.offset) >= ctx.frames do p.out_of_range += 1
		prev = e.offset
		if p.event_count < len(p.events) {
			p.events[p.event_count] = {block, e.offset, ctx.transport.sample_pos + tb.Sample_Time(e.offset), e.payload}
			p.event_count += 1
		} else {
			p.overflow += 1
		}
	}

	for c in 0 ..< len(ctx.outputs) {
		if c < len(ctx.inputs) {
			copy(ctx.outputs[c], ctx.inputs[c])
		} else {
			for &s in ctx.outputs[c] do s = 0
		}
	}
}

// Frees the probe's log and the probe itself (the same as core.node_destroy).
probe_destroy :: proc(n: ^core.Node, p: ^Probe) {
	core.node_destroy(n)
}
