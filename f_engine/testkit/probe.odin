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

Probe_Event :: struct {
	block:    int,
	offset:   u32,
	absolute: tb.Sample_Time, // transport.sample_pos + offset
	payload:  core.Event_Payload,
}

Probe_Block :: struct {
	frames:    int,
	transport: core.Transport,
}

Probe :: struct {
	log_allocator:   mem.Allocator, // the log lives until destroy, so it can be read after release
	events:          []Probe_Event,
	event_count:     int,
	blocks:          []Probe_Block,
	block_count:     int,
	overflow:        int,
	unsorted_events: int, // events whose offset < previous offset in the same block
	out_of_range:    int, // events whose offset >= frames
	capacity:        int,
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

probe_create :: proc(capacity := 65536, allocator := context.allocator) -> (core.Node, ^Probe) {
	p := new(Probe, allocator)
	p.capacity = capacity
	return core.node_make(&probe_vtable, p, allocator), p
}

probe_events :: proc(p: ^Probe) -> []Probe_Event {
	return p.events[:p.event_count]
}

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
