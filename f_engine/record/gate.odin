package record

import "core:math"

import "fire:core"
import tb "fire:timebase"

// When the recorders record, shared by all of them: armed, while the
// timeline plays, inside the punch range, `latency` frames in the past. A
// gate turns each process call into clock-frame pieces to record, and
// starts and ends takes at starts, stops, punches, locates and loop wraps.
@(private)
Gate :: struct {
	timeline:    core.Timeline_Id,
	latency:     int,
	armed:       bool,
	punch:       bool,
	punch_in:    tb.Beats,
	punch_out:   tb.Beats,
	history:     [HISTORY]History,
	head, count: int, // ring of `history`, oldest at head
	own_frame:   i64, // frames seen, when there is no clock
	taking:      bool, // a take is open
	run:         i32,
	pass:        i32,
	last_pos:    tb.Beats, // position just after the last frame recorded
	ctx:         ^core.Process_Context, // the call being recorded, for handlers
}

// Calls of timeline history kept, to look `latency` frames into the past.
@(private)
HISTORY :: 1024

// The timeline during one process call.
@(private)
History :: struct {
	frame:   i64, // clock frame of the call's first frame
	frames:  int,
	playing: bool,
	pos:     tb.Beats, // at `frame`
	bpf:     f64, // beats per frame while playing
	flags:   core.Timeline_Flags,
}

// What a recorder does with the pieces a gate hands it. `begin` returns
// false when it can't start a take (no room to say so).
@(private)
Gate_Handler :: struct {
	user:  rawptr,
	begin: proc "contextless" (user: rawptr, g: ^Gate, frame: i64, pos: tb.Beats) -> bool,
	data:  proc "contextless" (user: rawptr, g: ^Gate, e: ^History, a, b: i64, at: int), // clock frames [a, b), whose input is at offset `at` of the call
	end:   proc "contextless" (user: rawptr, g: ^Gate),
}

@(private)
Gate_Command :: struct {
	kind: enum u8 {Arm, Disarm, Punch, No_Punch, Latency},
	a, b: tb.Beats,
}

// [rt]
@(private)
gate_command :: proc "contextless" (g: ^Gate, c: Gate_Command) {
	switch c.kind {
	case .Arm:      g.armed = true
	case .Disarm:   g.armed = false
	case .Punch:    g.punch, g.punch_in, g.punch_out = true, c.a, c.b
	case .No_Punch: g.punch = false
	case .Latency:  g.latency = int(c.a)
	}
}

// [rt] Records this call: hands `h` the pieces of [now - latency,
// now - latency + frames) to record, in order.
@(private)
gate_process :: proc "contextless" (g: ^Gate, ctx: ^core.Process_Context, h: Gate_Handler) {
	now := remember(g, ctx)
	if ctx.frames == 0 do return
	g.ctx = ctx
	defer g.ctx = nil
	m0 := now - i64(g.latency)
	m1 := m0 + i64(ctx.frames)
	for k in 0 ..< g.count {
		e := &g.history[(g.head + k) % HISTORY]
		a, b := max(m0, e.frame), min(m1, e.frame + i64(e.frames))
		if a >= b do continue
		if a == e.frame && .Jumped in e.flags && g.taking {
			end_take(g, h)
			if .Wrapped in e.flags && wants(g, e, a) {
				g.pass += 1
				begin_take(g, h, e, a, new_run = false)
			}
		}
		for f := a; f < b; {
			n := next_change(g, e, f, b)
			if wants(g, e, f) {
				if !g.taking do begin_take(g, h, e, f, new_run = true)
				if g.taking {
					h.data(h.user, g, e, f, n, int(f - m0))
					g.last_pos = position(g, e, n)
				}
			} else if g.taking {
				end_take(g, h)
			}
			f = n
		}
	}
	forget(g, m1)
}

// [rt]
@(private)
begin_take :: proc "contextless" (g: ^Gate, h: Gate_Handler, e: ^History, f: i64, new_run: bool) {
	if new_run {
		g.run += 1
		g.pass = 0
	}
	pos := position(g, e, f)
	if !h.begin(h.user, g, f, pos) do return
	g.taking, g.last_pos = true, pos
}

// [rt]
@(private)
end_take :: proc "contextless" (g: ^Gate, h: Gate_Handler) {
	h.end(h.user, g)
	g.taking = false
}

// [rt] Adds this call to the history and returns its clock frame.
@(private)
remember :: proc "contextless" (g: ^Gate, ctx: ^core.Process_Context) -> i64 {
	t := ctx.transport
	now := g.own_frame if t == nil else i64(t.frame)
	g.own_frame = now + i64(ctx.frames)
	e := History{frame = now, frames = ctx.frames}
	if g.timeline == {} {
		e.playing = true
	} else if tl := core.transport_timeline(t, g.timeline); tl != nil {
		e.playing, e.pos, e.flags = tl.playing, tl.position, tl.flags
		if tl.playing && ctx.frames > 0 {
			e.bpf = f64(core.timeline_position_at(t, tl, ctx.frames) - tl.position) / f64(ctx.frames)
		}
	}
	if ctx.frames == 0 do return now
	if g.count == HISTORY { // the oldest can only be needed with an absurd latency
		g.head = (g.head + 1) % HISTORY
		g.count -= 1
	}
	g.history[(g.head + g.count) % HISTORY] = e
	g.count += 1
	return now
}

// [rt] Drops history wholly before `frame`.
@(private)
forget :: proc "contextless" (g: ^Gate, frame: i64) {
	for g.count > 1 {
		e := &g.history[g.head]
		if e.frame + i64(e.frames) > frame do break
		g.head = (g.head + 1) % HISTORY
		g.count -= 1
	}
}

// [rt] The timeline position at clock frame `f` of entry `e`.
@(private)
pos_at :: proc "contextless" (e: ^History, f: i64) -> tb.Beats {
	return e.pos + tb.Beats(f64(f - e.frame) * e.bpf)
}

// [rt] Whether frame `f` of entry `e` is at or past position `edge`. Within
// a millionth of a frame counts: positions accumulate rounding error, and a
// punch on a beat must start on the beat's frame.
@(private)
reached :: proc "contextless" (e: ^History, f: i64, edge: tb.Beats) -> bool {
	return f64(pos_at(e, f) - edge) >= -1e-6 * e.bpf
}

// [rt] The position at frame `f` of entry `e`, exactly a punch edge when
// it is within `reached`'s tolerance of one.
@(private)
position :: proc "contextless" (g: ^Gate, e: ^History, f: i64) -> tb.Beats {
	p := pos_at(e, f)
	if g.punch {
		for edge in ([2]tb.Beats{g.punch_in, g.punch_out}) do if abs(f64(p - edge)) <= 1e-6 * e.bpf do return edge
	}
	return p
}

// [rt] Whether frame `f` of entry `e` should be recorded.
@(private)
wants :: proc "contextless" (g: ^Gate, e: ^History, f: i64) -> bool {
	if !g.armed || !e.playing do return false
	if !g.punch || g.timeline == {} do return true
	return reached(e, f, g.punch_in) && !reached(e, f, g.punch_out)
}

// [rt] The first frame in (a, b) of entry `e` where `wants` changes, or b.
@(private)
next_change :: proc "contextless" (g: ^Gate, e: ^History, a, b: i64) -> i64 {
	if !g.armed || !e.playing || !g.punch || g.timeline == {} || e.bpf <= 0 do return b
	edge := g.punch_out if wants(g, e, a) else g.punch_in
	if reached(e, a, edge) do return b // already past it: no change in this entry
	f := e.frame + i64(math.ceil(f64(edge - e.pos) / e.bpf))
	for f > a + 1 && reached(e, f - 1, edge) do f -= 1 // the first frame at or past the edge
	for f < b && !reached(e, f, edge) do f += 1
	return clamp(f, a + 1, b)
}
