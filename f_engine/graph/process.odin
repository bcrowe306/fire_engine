package graph

import "base:intrinsics"

import "fire:core"
import "fire:rt"

// [rt] Processes one block: `ctx.inputs` feed INPUT, OUTPUT's inputs are
// written to `ctx.outputs`, `ctx.events_in` feed INPUT's events and OUTPUT's
// events go to `ctx.events_out` (if set). `ctx.frames` may be anything from 0
// to `max_block`. Call from the audio thread only; never allocates.
//
// Wire it into a device callback:
//
//	process :: proc(user: rawptr, b: ^backend.Io_Block) {
//		ctx := core.Process_Context{inputs = b.inputs, outputs = b.outputs, frames = b.frames}
//		graph.process((^graph.Graph)(user), &ctx)
//	}
process :: proc(g: ^Graph, ctx: ^core.Process_Context) {
	adopt(g)
	p := g.current
	frames := min(ctx.frames, g.settings.max_block)
	if p == nil || frames <= 0 {
		for out in ctx.outputs do for &s in out[:max(frames, 0)] do s = 0
		return
	}
	t0 := intrinsics.atomic_load_explicit(&g.sample_time, .Relaxed)
	take_params(g, p)

	// INPUT: the caller's audio and events.
	in_slot := p.nodes[p.input].slot
	for &ch, c in in_slot.outputs {
		if c < len(ctx.inputs) && len(ctx.inputs[c]) >= frames {
			copy(ch[:frames], ctx.inputs[c][:frames])
		} else {
			for &s in ch[:frames] do s = 0
		}
	}
	core.event_writer_clear(&in_slot.events_out)
	for e in ctx.events_in do if int(e.offset) < frames do core.event_writer_push(&in_slot.events_out, e)

	sched_run(g, p, frames, t0, ctx.transport)

	// OUTPUT: gathered like any node's inputs.
	out := &p.nodes[p.output]
	for dst, c in ctx.outputs {
		n := min(frames, len(dst))
		if c < len(out.in_views) {
			copy(dst[:n], out.in_views[c][:n])
		} else {
			for &s in dst[:n] do s = 0
		}
	}
	if ctx.events_out != nil {
		for e in out.events[:out.events_len] do core.event_writer_push(ctx.events_out, e)
	}
	intrinsics.atomic_store_explicit(&g.sample_time, t0 + i64(frames), .Relaxed)
	intrinsics.atomic_add_explicit(&g.blocks, 1, .Relaxed)
}

// [rt] Switches to a newly committed plan, handing the old one back to the
// control thread. Skipped (keeping the old plan) if the hand-back queue is
// full, so a plan is never dropped.
@(private)
adopt :: proc "contextless" (g: ^Graph) {
	if intrinsics.atomic_load_explicit(&g.pending, .Acquire) == nil do return
	if g.current != nil && rt.spsc_len(&g.retired) >= rt.spsc_capacity(&g.retired) do return
	p := intrinsics.atomic_exchange_explicit(&g.pending, nil, .Acq_Rel)
	if p == nil do return
	if g.current != nil do rt.spsc_push(&g.retired, g.current)
	g.current = p
}

// [rt] Moves queued parameter changes into their nodes' pending lists,
// sorted by time.
@(private)
take_params :: proc "contextless" (g: ^Graph, p: ^Plan) {
	for c in rt.spsc_pop(&g.params) {
		if int(c.slot) >= len(p.slot_node) || p.slot_node[c.slot] < 0 {
			intrinsics.atomic_add_explicit(&g.params_dropped, 1, .Relaxed)
			continue
		}
		s := p.nodes[p.slot_node[c.slot]].slot
		if s.generation != c.generation || s.pending_len == len(s.pending) {
			intrinsics.atomic_add_explicit(&g.params_dropped, 1, .Relaxed)
			continue
		}
		i := s.pending_len
		for i > 0 && s.pending[i - 1].at > c.at {
			s.pending[i] = s.pending[i - 1]
			i -= 1
		}
		s.pending[i] = c
		s.pending_len += 1
	}
}

// [rt] Gathers one node's inputs and runs it. Touches only this node's state
// and its sources' (finished) outputs, so nodes run concurrently once their
// sources are done.
@(private)
run_node :: proc(g: ^Graph, p: ^Plan, i: i32, frames: int, t0: i64, transport: ^core.Transport) {
	pn := &p.nodes[i]
	s := pn.slot

	for &view, c in pn.in_views {
		sources := pn.channel_sources[c]
		switch len(sources) {
		case 0:
			view = g.silence[:frames]
		case 1:
			src := sources[0]
			view = delay_audio(src.delay, src.buffer[:frames]) if src.delay != nil else src.buffer[:frames]
		case:
			// Summed in connection order: the same result on any thread.
			acc := s.scratch[c][:frames]
			for src, k in sources {
				x := delay_audio(src.delay, src.buffer[:frames]) if src.delay != nil else src.buffer[:frames]
				if k == 0 {
					copy(acc, x)
				} else {
					for &a, j in acc do a += x[j]
				}
			}
			view = acc
		}
	}

	// Events: due parameter changes first, then each event source in
	// connection order; then a stable sort by offset.
	n := 0
	due := 0
	for due < s.pending_len && s.pending[due].at < t0 + i64(frames) {
		c := s.pending[due]
		pn.events[n] = {u32(max(c.at - t0, 0)), core.Param_Value{c.param, c.value}}
		n += 1
		due += 1
	}
	if due > 0 {
		copy(s.pending[:], s.pending[due:s.pending_len])
		s.pending_len -= due
	}
	dropped := 0
	for src in pn.event_sources {
		events := core.event_writer_events(&src.slot.events_out)
		if src.delay != nil {
			k: int
			n, k = delay_events(src.delay, events, t0, frames, pn.events, n)
			dropped += k
			continue
		}
		for e in events {
			if n == len(pn.events) {
				dropped += 1
				continue
			}
			pn.events[n] = e
			n += 1
		}
	}
	sort_events(pn.events[:n])
	pn.events_len = n // OUTPUT's are read by `process` after the block

	if s.kind == .Node {
		for &view, c in pn.out_views do view = s.outputs[c][:frames]
		core.event_writer_clear(&s.events_out)
		ctx := core.Process_Context {
			inputs     = pn.in_views,
			outputs    = pn.out_views,
			frames     = frames,
			events_in  = pn.events[:n],
			events_out = &s.events_out,
			transport  = transport,
		}
		core.node_process(&s.node, &ctx)
		dropped += s.events_out.dropped
	}
	if dropped > 0 do intrinsics.atomic_add_explicit(&g.events_dropped, u64(dropped), .Relaxed)
}

// [rt] Stable insertion sort by offset (inputs are short and nearly sorted).
@(private)
sort_events :: proc "contextless" (events: []core.Event) {
	for i in 1 ..< len(events) {
		e := events[i]
		j := i
		for j > 0 && events[j - 1].offset > e.offset {
			events[j] = events[j - 1]
			j -= 1
		}
		events[j] = e
	}
}
