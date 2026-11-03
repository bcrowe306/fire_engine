package graph

import "fire:core"

// A compensating delay on one connection: a ring buffer for an audio channel,
// or a time-ordered queue for events. Owned by the graph and shared by
// successive plans while the connection and delay stay the same, so edits
// elsewhere don't reset it.
@(private)
Delay_Line :: struct {
	conn:       Connection,
	src_gen:    u32,
	dst_gen:    u32,
	frames:     int,
	refs:       int, // plans using it
	// Audio.
	ring:       []f32,
	mask:       int,
	pos:        int,
	out:        []f32, // this block's delayed output (max_block)
	// Events.
	events:     []Timed_Event,
	events_len: int,
}

@(private)
Timed_Event :: struct {
	at:      i64, // graph time
	payload: core.Event_Payload,
}

// Finds the graph's delay line for this connection and length, or makes one,
// and records it in the plan being compiled.
@(private)
delay_for :: proc(g: ^Graph, c: Connection, frames: int, used: ^[dynamic]^Delay_Line) -> (^Delay_Line, core.Error) {
	if frames <= 0 do return nil, .None
	src_gen, dst_gen := g.slots[c.src].generation, g.slots[c.dst].generation
	for d in g.delays {
		if d.conn == c && d.src_gen == src_gen && d.dst_gen == dst_gen && d.frames == frames {
			d.refs += 1
			append(used, d)
			return d, .None
		}
	}
	d := new(Delay_Line, g.allocator)
	if d == nil do return nil, .Out_Of_Memory
	d^ = {conn = c, src_gen = src_gen, dst_gen = dst_gen, frames = frames, refs = 1}
	if c.src_ch >= 0 {
		size := 1
		for size < frames + g.settings.max_block do size <<= 1
		d.ring = make([]f32, size, g.allocator)
		d.out = make([]f32, g.settings.max_block, g.allocator)
		d.mask = size - 1
		if d.ring == nil || d.out == nil {
			delay_free(g, d)
			return nil, .Out_Of_Memory
		}
	} else {
		// Enough for the events of every block in flight, plus margin.
		blocks := frames / g.settings.max_block + 2
		d.events = make([]Timed_Event, g.settings.max_events * blocks, g.allocator)
		if d.events == nil {
			delay_free(g, d)
			return nil, .Out_Of_Memory
		}
	}
	append(&g.delays, d)
	append(used, d)
	return d, .None
}

@(private)
delay_free :: proc(g: ^Graph, d: ^Delay_Line) {
	delete(d.ring, g.allocator)
	delete(d.out, g.allocator)
	delete(d.events, g.allocator)
	free(d, g.allocator)
}

// [rt] Pushes one block of audio through the delay; returns the delayed block.
@(private)
delay_audio :: proc "contextless" (d: ^Delay_Line, input: []f32) -> []f32 {
	out := d.out[:len(input)]
	for x, i in input {
		d.ring[(d.pos + i) & d.mask] = x
		out[i] = d.ring[(d.pos + i - d.frames) & d.mask]
	}
	d.pos = (d.pos + len(input)) & d.mask
	return out
}

// [rt] Queues this block's events `frames` later and appends those now due to
// `out` (at offsets within the block). Returns the new length of `out`, and
// how many events were dropped because the queue was full.
@(private)
delay_events :: proc "contextless" (d: ^Delay_Line, input: []core.Event, t0: i64, frames: int, out: []core.Event, n: int) -> (int, int) {
	n, dropped := n, 0
	for e in input {
		if d.events_len == len(d.events) {
			dropped += 1
			continue
		}
		d.events[d.events_len] = {t0 + i64(e.offset) + i64(d.frames), e.payload}
		d.events_len += 1
	}
	due := 0
	for due < d.events_len && d.events[due].at < t0 + i64(frames) {
		if n < len(out) {
			out[n] = {u32(max(d.events[due].at - t0, 0)), d.events[due].payload}
			n += 1
		} else {
			dropped += 1
		}
		due += 1
	}
	if due > 0 {
		copy(d.events[:], d.events[due:d.events_len])
		d.events_len -= due
	}
	return n, dropped
}
