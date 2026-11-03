package graph

import "core:mem/virtual"
import "core:slice"

import "fire:core"

// One compiled version of the graph. Immutable once published, except for
// the per-block counters and buffers the audio side owns.
@(private)
Plan :: struct {
	arena:      virtual.Arena,
	epoch:      u64,
	nodes:      []Plan_Node,  // in topological order
	slot_node:  []i32,        // slot index → plan node, -1 if absent
	input:      i32,
	output:     i32,
	delays:     []^Delay_Line, // used by this plan (refcounted)
	// Most processing nodes that can ever run at once (INPUT and OUTPUT are
	// not counted). At 1 the plan runs serially on the audio thread: waking
	// workers would only add latency.
	width:      int,
	// Smoothed CPU time all nodes took per block (ns), whichever threads ran
	// them; decides serial vs parallel. Audio thread.
	work_ns:    f64,
	sched:      Schedule,
}

@(private)
Plan_Node :: struct {
	slot:            ^Slot,
	channel_sources: [][]Source,    // per input channel, in connection order
	event_sources:   []Event_Source, // in connection order
	in_views:        [][]f32,
	out_views:       [][]f32,
	events:          []core.Event,  // merged input events for this block
	events_len:      int,
	consumers:       []i32,         // plan nodes that depend on this one
	num_deps:        i32,           // distinct upstream nodes
	deps:            i32,           // atomic, reset each block
}

@(private)
Source :: struct {
	buffer: []f32,       // the source's output channel (max_block long)
	delay:  ^Delay_Line, // latency compensation, or nil
}

@(private)
Event_Source :: struct {
	slot:  ^Slot,
	delay: ^Delay_Line,
}

@(private)
plan_compile :: proc(g: ^Graph) -> (p: ^Plan, err: core.Error) {
	p = new(Plan, g.allocator)
	if p == nil do return nil, .Out_Of_Memory
	if virtual.arena_init_growing(&p.arena) != nil {
		free(p, g.allocator)
		return nil, .Out_Of_Memory
	}
	defer if err != .None {
		virtual.arena_destroy(&p.arena)
		free(p, g.allocator)
		p = nil
	}
	a := virtual.arena_allocator(&p.arena)
	g.epoch += 1
	p.epoch = g.epoch

	// Topological order (Kahn), deterministic: ready nodes in slot order.
	n_slots := len(g.slots)
	alive := make([]bool, n_slots, context.temp_allocator)
	indegree := make([]int, n_slots, context.temp_allocator)
	for s, i in g.slots do alive[i] = s.kind != .Free && !s.removed
	for c in g.conns do indegree[c.dst] += 1
	order := make([dynamic]u32, 0, n_slots, context.temp_allocator)
	for i in 0 ..< n_slots do if alive[i] && indegree[i] == 0 do append(&order, u32(i))
	for head := 0; head < len(order); head += 1 {
		n := order[head]
		for c in g.conns do if c.src == n {
			indegree[c.dst] -= 1
			if indegree[c.dst] == 0 do append(&order, c.dst)
		}
	}
	live := 0
	for b in alive do if b do live += 1
	if len(order) != live do return p, .Invalid_State // a cycle: connect prevents this

	// Latency: when each node's input arrives (max over sources).
	own := make([]int, n_slots, context.temp_allocator)
	arrival := make([]int, n_slots, context.temp_allocator)
	for s, i in g.slots do if alive[i] && s.kind == .Node do own[i] = core.node_latency(&s.node)
	for n in order {
		for c in g.conns do if c.dst == n do arrival[n] = max(arrival[n], arrival[c.src] + own[c.src])
	}
	g.latency = arrival[OUTPUT.index]

	p.slot_node = make([]i32, n_slots, a)
	slice.fill(p.slot_node, -1)
	for n, i in order do p.slot_node[n] = i32(i)
	p.nodes = make([]Plan_Node, len(order), a)
	p.input, p.output = p.slot_node[INPUT.index], p.slot_node[OUTPUT.index]

	delays := make([dynamic]^Delay_Line, a)
	for n, i in order {
		s := g.slots[n]
		pn := &p.nodes[i]
		pn.slot = s
		s.plan_refs += 1
		pn.channel_sources = make([][]Source, s.in_channels, a)
		pn.in_views = make([][]f32, s.in_channels, a)
		pn.out_views = make([][]f32, s.out_channels, a)
		ev_sources := make([dynamic]Event_Source, a)
		upstream := make([dynamic]i32, context.temp_allocator)
		for &list, ch in pn.channel_sources {
			srcs := make([dynamic]Source, a)
			for c in g.conns do if c.dst == n && c.dst_ch == ch {
				d := delay_for(g, c, compensation(g, arrival, own, c), &delays) or_return
				append(&srcs, Source{g.slots[c.src].outputs[c.src_ch], d})
			}
			list = srcs[:]
		}
		for c in g.conns do if c.dst == n && c.dst_ch < 0 {
			d := delay_for(g, c, compensation(g, arrival, own, c), &delays) or_return
			append(&ev_sources, Event_Source{g.slots[c.src], d})
		}
		pn.event_sources = ev_sources[:]
		for c in g.conns do if c.dst == n && !slice.contains(upstream[:], p.slot_node[c.src]) do append(&upstream, p.slot_node[c.src])
		pn.num_deps = i32(len(upstream))
		// Room for every source's events, plus parameter changes (and the
		// caller's events for OUTPUT's sources, already counted).
		pn.events = make([]core.Event, g.settings.max_events * max(1, len(pn.event_sources)) + g.settings.max_pending_params, a)
	}
	for n, i in order {
		consumers := make([dynamic]i32, a)
		for c in g.conns do if c.src == n && !slice.contains(consumers[:], p.slot_node[c.dst]) do append(&consumers, p.slot_node[c.dst])
		p.nodes[i].consumers = consumers[:]
	}
	p.delays = delays[:]

	// Width: processing nodes per dependency level (a node's level is one
	// more than its deepest source's).
	level := make([]int, len(order), context.temp_allocator)
	per_level := make([]int, len(order) + 1, context.temp_allocator)
	for n, i in order {
		for c in g.conns do if c.dst == n do level[i] = max(level[i], level[p.slot_node[c.src]] + 1)
		if g.slots[n].kind == .Node {
			per_level[level[i]] += 1
			p.width = max(p.width, per_level[level[i]])
		}
	}
	sched_init(g, p, a) or_return
	return p, .None
}

// Frames by which connection `c` must be delayed so its source arrives with
// the latest source of the same input (0 with compensation off).
@(private)
compensation :: proc(g: ^Graph, arrival, own: []int, c: Connection) -> int {
	if !g.settings.latency_compensation do return 0
	return arrival[c.dst] - (arrival[c.src] + own[c.src])
}

// Decrements the counts this plan holds; recycles removed nodes and unused
// delay lines; frees the plan. Control thread, once the audio side is done
// with it.
@(private)
plan_release :: proc(g: ^Graph, p: ^Plan) {
	sched_quiesce(g, p)
	for pn in p.nodes {
		s := pn.slot
		s.plan_refs -= 1
		if s.removed && s.plan_refs == 0 do slot_recycle(g, s)
	}
	for d in p.delays {
		d.refs -= 1
		if d.refs == 0 {
			for e, i in g.delays do if e == d {
				unordered_remove(&g.delays, i)
				break
			}
			delay_free(g, d)
		}
	}
	for e, i in g.live do if e == p {
		ordered_remove(&g.live, i)
		break
	}
	plan_free(g, p)
}

@(private)
plan_free :: proc(g: ^Graph, p: ^Plan) {
	sched_destroy(p)
	virtual.arena_destroy(&p.arena)
	free(p, g.allocator)
}
