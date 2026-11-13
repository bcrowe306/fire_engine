/*
Live note effects, for playing: an arpeggiator and note repeat, both locked
to the clock's beat grid. Each is a plain struct with a `process` proc that
turns one block's incoming events into outgoing ones, so an instrument or a
router can run them inline; `arp_node_create` and `repeat_node_create`
wrap them as graph nodes (events in, events out, no audio).

	a: perform.Arp
	perform.arp_init(&a, {mode = .Up, rate = .Sixteenth, octaves = 2, gate = 0.5})
	// [rt], each block:
	perform.arp_process(&a, ctx.transport, ctx.frames, ctx.events_in, ctx.events_out)

Notes they make land on the exact frame of their grid step at any block
size. Their grid is a timeline's when one is given and playing (the
sequence's beats: the steps fall on its 1/16s, as recorded notes would), else
the transport's free-running grid (shared with every other effect, and
with Link). Without a transport
(`ctx.transport` nil) they pass events through. Each note they play has its
own `core.Note_Id`; every note they start, they end.
*/
package perform

import "core:math"

import "fire:core"
import tb "fire:timebase"

// A step length on the beat grid.
Rate :: enum u8 {
	Quarter,               // 1/4
	Eighth,                // 1/8
	Eighth_Triplet,        // 1/8T
	Sixteenth,             // 1/16
	Sixteenth_Triplet,     // 1/16T
	Thirty_Second,         // 1/32
	Thirty_Second_Triplet, // 1/32T
}

// The step in beats (quarter notes).
rate_beats :: proc "contextless" (r: Rate) -> tb.Beats {
	switch r {
	case .Quarter:               return 1
	case .Eighth:                return 0.5
	case .Eighth_Triplet:        return 1.0 / 3
	case .Sixteenth:             return 0.25
	case .Sixteenth_Triplet:     return 1.0 / 6
	case .Thirty_Second:         return 0.125
	case .Thirty_Second_Triplet: return 1.0 / 12
	}
	return 0.25
}

// Notes held at once that the effects track; more are ignored.
MAX_HELD :: 32

// A held key.
@(private)
Held :: struct {
	key:      u8,
	channel:  u8,
	velocity: f32,
	order:    u32, // when it was pressed (for `.As_Played`)
}

// A note an effect started and must end.
@(private)
Playing :: struct {
	id:      core.Note_Id,
	key:     u8,
	channel: u8,
	off_at:  tb.Beats, // grid beat of its note-off
}

// --- shared --------------------------------------------------------------------------------

// What happens next in a block: an incoming event, a note-off, or a step.
@(private)
Next :: enum u8 {Off, Event, Step, None}

// The beats an effect steps on in one call: a playing timeline's local
// beats, or the transport's grid.
@(private)
Clock :: struct {
	t:  ^core.Transport,
	tl: ^core.Timeline_State, // nil: the free grid
}

// Which beats an effect counted in last (when it changes, the beats before
// mean nothing: a start, a stop, a locate).
@(private)
Space :: enum u8 {None, Free, Timeline}

// [rt] The clock for this call, and whether its beats carry on from the
// last call's (`space` updated).
@(private)
clock_for :: proc "contextless" (t: ^core.Transport, tl: ^core.Timeline_State, space: ^Space) -> (c: Clock, same: bool) {
	want := Space.Timeline if tl != nil && tl.playing else Space.Free
	same = want == space^ || space^ == .None
	if want == .Timeline && .Jumped in tl.flags do same = false
	space^ = want
	return {t = t, tl = tl if want == .Timeline else nil}, same
}

// [rt] The clock's beat `offset` frames into the call.
@(private)
beat_at :: proc "contextless" (c: Clock, offset: int) -> tb.Beats {
	if c.tl != nil do return core.timeline_position_at(c.t, c.tl, offset)
	return core.transport_grid_at(c.t, offset)
}

// [rt] The frame offset of the clock's beat `b` in this call (`frames` or
// more: not in it; 0: already passed).
@(private)
offset_at :: proc "contextless" (c: Clock, b: tb.Beats) -> int {
	if c.tl != nil do return core.timeline_offset_of(c.t, c.tl, b)
	return core.transport_offset_of(c.t, b)
}

// [rt] The first multiple of `step` due in this call that was not handled
// before (`last`).
@(private)
first_step :: proc "contextless" (c: Clock, step, last: tb.Beats) -> tb.Beats {
	b := core.timeline_next_multiple(c.t, c.tl, step) if c.tl != nil else core.transport_next_multiple(c.t, step)
	for b <= last + step * 0.5 do b += step
	return b
}

// A beat no step comes before (nothing handled yet).
@(private)
NEVER :: tb.Beats(-1e18)

@(private)
held_add :: proc "contextless" (held: ^[MAX_HELD]Held, count: ^int, order: ^u32, on: core.Note_On) {
	for i in 0 ..< count^ do if held[i].key == on.key && held[i].channel == on.channel {
		held[i].velocity = on.velocity
		return
	}
	if count^ == MAX_HELD do return
	order^ += 1
	held[count^] = {on.key, on.channel, on.velocity, order^}
	count^ += 1
}

@(private)
held_remove :: proc "contextless" (held: ^[MAX_HELD]Held, count: ^int, key, channel: u8) -> bool {
	for i in 0 ..< count^ do if held[i].key == key && held[i].channel == channel {
		copy(held[i:count^ - 1], held[i + 1:count^])
		count^ -= 1
		return true
	}
	return false
}

@(private)
new_id :: proc "contextless" (next: ^core.Note_Id) -> core.Note_Id {
	id := next^
	next^ = next^ + 1 if next^ < max(core.Note_Id) - 1 else 1
	return id
}

// --- arpeggiator ---------------------------------------------------------------------------

// The order an arpeggio walks the held notes.
Arp_Mode :: enum u8 {
	Up,        // lowest to highest, then the next octave up
	Down,      // highest to lowest
	Up_Down,   // up then down, the ends played once
	Random,    // any held note each step
	As_Played, // in the order they were pressed
}

// Settings of an `Arp` (change them between blocks with `arp_set`).
Arp_Settings :: struct {
	mode:    Arp_Mode,
	rate:    Rate,
	octaves: int,  // 1..4: the pattern repeats this many octaves up (0 = 1)
	gate:    f32,  // 0.05..1: how much of a step each note sounds (0 = 0.5)
	latch:   bool, // keep playing after the keys are let go, until new ones are pressed
	seed:    u64,  // `.Random`: the same seed, the same choices (0 = a default)
}

// An arpeggiator: plays the held notes one after another, a step apart on
// the grid. Note-ons and note-offs it consumes; other events pass through.
// The first note plays on the first step at or after the first key.
Arp :: struct {
	settings: Arp_Settings,
	held:     [MAX_HELD]Held,
	count:    int,
	order:    u32,
	down:     int,  // keys physically held (with latch, `held` can outlast them)
	step:     int,  // position in the pattern
	last:     tb.Beats, // the last grid step handled (never handled twice)
	playing:  Playing,
	sounding: bool,
	next_id:  core.Note_Id,
	rng:      u64,
	space:    Space,    // the beats `last` and the note-off are in
}

// Prepares `a` with `settings`.
arp_init :: proc(a: ^Arp, settings: Arp_Settings) {
	a^ = {next_id = 1, last = NEVER}
	arp_set(a, settings)
	a.rng = a.settings.seed
}

// Changes `a`'s settings (between blocks; the pattern carries on).
arp_set :: proc "contextless" (a: ^Arp, settings: Arp_Settings) {
	s := settings
	if s.octaves <= 0 do s.octaves = 1
	s.octaves = min(s.octaves, 4)
	if s.gate <= 0 do s.gate = 0.5
	s.gate = clamp(s.gate, 0.05, 1)
	if s.seed == 0 do s.seed = 0x2545F4914F6CDD1D
	if !s.latch && a.settings.latch && a.down == 0 do a.count, a.step = 0, 0 // let go of the latched notes
	a.settings = s
}

// [rt] Arpeggiates one block: `events_in` (sorted by offset) in, notes
// out; on timeline `tl`'s beats while it plays (nil: the free grid).
arp_process :: proc "contextless" (a: ^Arp, t: ^core.Transport, frames: int, events_in: []core.Event, out: ^core.Event_Writer, tl: ^core.Timeline_State = nil) {
	if out == nil do return
	if t == nil {
		for e in events_in do core.event_writer_push(out, e)
		return
	}
	c, same := clock_for(t, tl, &a.space)
	if !same {
		// A start, stop or locate: what sounds ends, the steps start again
		// on these beats.
		if a.sounding do arp_note_off(a, out, 0)
		a.last = NEVER
	}
	step := rate_beats(a.settings.rate)
	next_step := first_step(c, step, a.last)
	ei := 0
	for {
		off_o := offset_at(c, a.playing.off_at) if a.sounding else max(int)
		ev_o := int(events_in[ei].offset) if ei < len(events_in) else max(int)
		st_o := offset_at(c, next_step)
		which := Next.None
		at := frames
		if off_o < at do which, at = .Off, off_o
		if ev_o < at || (ev_o == at && which == .None) do which, at = .Event, ev_o
		if st_o < at || (st_o == at && which == .None) do which, at = .Step, st_o
		switch which {
		case .None:
			return
		case .Off:
			arp_note_off(a, out, at)
		case .Event:
			e := events_in[ei]
			ei += 1
			#partial switch v in e.payload {
			case core.Note_On:
				// With latch, the first key of a new chord replaces the old one.
				if a.settings.latch && a.down == 0 do a.count, a.step = 0, 0
				held_add(&a.held, &a.count, &a.order, v)
				a.down += 1
			case core.Note_Off:
				a.down = max(a.down - 1, 0)
				if !a.settings.latch {
					held_remove(&a.held, &a.count, v.key, v.channel)
					if a.count == 0 do a.step = 0
				}
			case:
				core.event_writer_push(out, e)
			}
		case .Step:
			arp_step(a, out, at, next_step, step)
			a.last = next_step
			next_step += step
		}
	}
}

@(private)
arp_note_off :: proc "contextless" (a: ^Arp, out: ^core.Event_Writer, at: int) {
	p := a.playing
	core.event_writer_push(out, {u32(at), core.Note_Off{id = p.id, channel = p.channel, key = p.key}})
	a.sounding = false
}

@(private)
arp_step :: proc "contextless" (a: ^Arp, out: ^core.Event_Writer, at: int, beat, step: tb.Beats) {
	if a.sounding do arp_note_off(a, out, at)
	if a.count == 0 do return
	// The held notes in pattern order.
	notes: [MAX_HELD]Held
	n := a.count
	copy(notes[:n], a.held[:n])
	if a.settings.mode != .As_Played {
		for i in 1 ..< n do for j := i; j > 0 && notes[j - 1].key > notes[j].key; j -= 1 do notes[j - 1], notes[j] = notes[j], notes[j - 1]
	} else {
		for i in 1 ..< n do for j := i; j > 0 && notes[j - 1].order > notes[j].order; j -= 1 do notes[j - 1], notes[j] = notes[j], notes[j - 1]
	}
	span := n * a.settings.octaves // notes in one pass up
	index: int
	switch a.settings.mode {
	case .Up, .As_Played:
		index = a.step % span
	case .Down:
		index = span - 1 - a.step % span
	case .Up_Down:
		cycle := max(2 * span - 2, 1)
		k := a.step % cycle
		index = k if k < span else cycle - k
	case .Random:
		x := a.rng
		x ~= x >> 12
		x ~= x << 25
		x ~= x >> 27
		a.rng = x
		index = int((x * 0x2545F4914F6CDD1D) >> 33) % span
	}
	a.step += 1
	h := notes[index % n]
	key := int(h.key) + 12 * (index / n)
	if key > 127 do return
	id := new_id(&a.next_id)
	core.event_writer_push(out, {u32(at), core.Note_On{id = id, channel = h.channel, key = u8(key), velocity = h.velocity}})
	a.playing = {id = id, key = u8(key), channel = h.channel, off_at = beat + step * tb.Beats(a.settings.gate)}
	a.sounding = true
}

// [rt] Ends what `a` is playing at offset `at` and forgets the held keys
// (a stop, a bypass).
arp_reset :: proc "contextless" (a: ^Arp, out: ^core.Event_Writer, at: int = 0) {
	if a.sounding && out != nil do arp_note_off(a, out, at)
	a.count, a.down, a.step, a.sounding = 0, 0, 0, false
}

// --- note repeat ---------------------------------------------------------------------------

// Settings of a `Repeat`.
Repeat_Settings :: struct {
	rate: Rate,
	gate: f32, // 0.05..1 of a step (0 = 0.5)
}

// Note repeat: a held note plays at once, then again on every grid step
// while it is held. Note-ons and note-offs it consumes; other events pass
// through.
Repeat :: struct {
	settings: Repeat_Settings,
	held:     [MAX_HELD]Held,
	count:    int,
	order:    u32,
	playing:  [MAX_HELD]Playing,
	sounding: [MAX_HELD]bool,
	skip:     [MAX_HELD]tb.Beats, // a key pressed just before a step: that step (its note played already)
	last:     tb.Beats, // the last grid step handled
	next_id:  core.Note_Id,
	space:    Space,    // the beats `last` and the note-offs are in
}

// Prepares `r` with `settings`.
repeat_init :: proc(r: ^Repeat, settings: Repeat_Settings) {
	r^ = {next_id = 1, last = NEVER}
	for &k in r.skip do k = NEVER
	repeat_set(r, settings)
}

// Changes `r`'s settings (between blocks).
repeat_set :: proc "contextless" (r: ^Repeat, settings: Repeat_Settings) {
	s := settings
	if s.gate <= 0 do s.gate = 0.5
	s.gate = clamp(s.gate, 0.05, 1)
	r.settings = s
}

// How far before a step (of a step) a key counts as early for it: its note
// plays at once and stands for that step, which then doesn't play again
// (no second note a moment after the first). Pressed earlier than that,
// the note plays at once and the step plays too, a half step or more later.
REPEAT_EARLY :: 0.5

// [rt] Repeats one block's held notes: each plays when its key is pressed,
// then on every step of the grid while it is held (timeline `tl`'s beats
// while it plays; nil, or stopped: the transport's grid).
repeat_process :: proc "contextless" (r: ^Repeat, t: ^core.Transport, frames: int, events_in: []core.Event, out: ^core.Event_Writer, tl: ^core.Timeline_State = nil) {
	if out == nil do return
	if t == nil {
		for e in events_in do core.event_writer_push(out, e)
		return
	}
	c, same := clock_for(t, tl, &r.space)
	if !same {
		// A start, stop or locate: what sounds ends (its note-off was in the
		// old beats), the held keys play again on the new beats' steps.
		for i in 0 ..< MAX_HELD do if r.sounding[i] do repeat_off(r, out, 0, i)
		r.last = NEVER
		for &k in r.skip do k = NEVER
	}
	step := rate_beats(r.settings.rate)
	next_step := first_step(c, step, r.last)
	ei := 0
	for {
		// The earliest note-off due.
		off_o, off_i := max(int), -1
		for i in 0 ..< MAX_HELD do if r.sounding[i] {
			if o := offset_at(c, r.playing[i].off_at); o < off_o do off_o, off_i = o, i
		}
		ev_o := int(events_in[ei].offset) if ei < len(events_in) else max(int)
		st_o := offset_at(c, next_step)
		// At one frame: note-offs, then the step, then new keys (a key
		// pressed on a step plays once, not twice).
		which := Next.None
		at := frames
		if off_o < at do which, at = .Off, off_o
		if st_o < at || (st_o == at && which == .None) do which, at = .Step, st_o
		if ev_o < at || (ev_o == at && which == .None) do which, at = .Event, ev_o
		switch which {
		case .None:
			return
		case .Off:
			repeat_off(r, out, at, off_i)
		case .Event:
			e := events_in[ei]
			ei += 1
			#partial switch v in e.payload {
			case core.Note_On:
				before := r.count
				held_add(&r.held, &r.count, &r.order, v)
				if r.count > before {
					// Plays at once. Just before a step (REPEAT_EARLY), it is
					// that step's note: the step passes it by, and it lasts a
					// gate from it. Otherwise it lasts a gate, at most to the
					// next step.
					i := r.count - 1
					beat := beat_at(c, at)
					gate := step * tb.Beats(r.settings.gate)
					next := tb.Beats(math.floor(f64(beat / step) + 1e-9) + 1) * step
					on_step := beat - (next - step) < step * 1e-6 // (on a step: that step's note, the step not played again)
					r.skip[i] = NEVER
					if next - beat <= step * REPEAT_EARLY && !on_step && next > r.last {
						r.skip[i] = next
						repeat_on(r, out, at, i, next + gate)
					} else {
						if on_step do r.skip[i] = next - step
						repeat_on(r, out, at, i, beat + min(gate, next - beat))
					}
				}
			case core.Note_Off:
				for i in 0 ..< r.count do if r.held[i].key == v.key && r.held[i].channel == v.channel {
					if r.sounding[i] do repeat_off(r, out, at, i)
					// Keep the playing slots in step with the held list.
					copy(r.playing[i:r.count - 1], r.playing[i + 1:r.count])
					copy(r.sounding[i:r.count - 1], r.sounding[i + 1:r.count])
					copy(r.skip[i:r.count - 1], r.skip[i + 1:r.count])
					r.sounding[r.count - 1] = false
					r.skip[r.count - 1] = NEVER
					break
				}
				held_remove(&r.held, &r.count, v.key, v.channel)
			case:
				core.event_writer_push(out, e)
			}
		case .Step:
			for i in 0 ..< r.count {
				if abs(r.skip[i] - next_step) < step * 0.25 do continue // its key's note is this step's
				if r.sounding[i] do repeat_off(r, out, at, i)
				repeat_on(r, out, at, i, next_step + step * tb.Beats(r.settings.gate))
			}
			r.last = next_step
			next_step += step
		}
	}
}

@(private)
repeat_on :: proc "contextless" (r: ^Repeat, out: ^core.Event_Writer, at: int, i: int, off_at: tb.Beats) {
	h := r.held[i]
	id := new_id(&r.next_id)
	core.event_writer_push(out, {u32(at), core.Note_On{id = id, channel = h.channel, key = h.key, velocity = h.velocity}})
	r.playing[i] = {id = id, key = h.key, channel = h.channel, off_at = off_at}
	r.sounding[i] = true
}

@(private)
repeat_off :: proc "contextless" (r: ^Repeat, out: ^core.Event_Writer, at: int, i: int) {
	p := r.playing[i]
	core.event_writer_push(out, {u32(at), core.Note_Off{id = p.id, channel = p.channel, key = p.key}})
	r.sounding[i] = false
}

// [rt] Ends every note `r` is playing and forgets the held keys.
repeat_reset :: proc "contextless" (r: ^Repeat, out: ^core.Event_Writer, at: int = 0) {
	for i in 0 ..< MAX_HELD do if r.sounding[i] && out != nil do repeat_off(r, out, at, i)
	r.count = 0
	for &k in r.skip do k = NEVER
}
