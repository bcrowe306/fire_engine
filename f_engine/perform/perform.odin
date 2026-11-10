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
size. Without a transport (`ctx.transport` nil) they pass events through.
Each note they play has its own `core.Note_Id`; every note they start,
they end.
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

// [rt] The first grid step due in this call that was not handled before.
@(private)
first_step :: proc "contextless" (t: ^core.Transport, step, last: tb.Beats) -> tb.Beats {
	b := core.transport_next_multiple(t, step)
	for b <= last + step * 0.5 do b += step
	return b
}

// [rt] The frame offset of grid beat `b` in this call (`frames` or more:
// not in it).
@(private)
offset_at :: proc "contextless" (t: ^core.Transport, b: tb.Beats) -> int {
	return core.transport_offset_of(t, b)
}

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
}

// Prepares `a` with `settings`.
arp_init :: proc(a: ^Arp, settings: Arp_Settings) {
	a^ = {next_id = 1, last = -1}
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

// [rt] Arpeggiates one block: `events_in` (sorted by offset) in, notes out.
arp_process :: proc "contextless" (a: ^Arp, t: ^core.Transport, frames: int, events_in: []core.Event, out: ^core.Event_Writer) {
	if out == nil do return
	if t == nil {
		for e in events_in do core.event_writer_push(out, e)
		return
	}
	step := rate_beats(a.settings.rate)
	next_step := first_step(t, step, a.last)
	ei := 0
	for {
		off_o := offset_at(t, a.playing.off_at) if a.sounding else max(int)
		ev_o := int(events_in[ei].offset) if ei < len(events_in) else max(int)
		st_o := offset_at(t, next_step)
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
	last:     tb.Beats, // the last grid step handled
	next_id:  core.Note_Id,
}

// Prepares `r` with `settings`.
repeat_init :: proc(r: ^Repeat, settings: Repeat_Settings) {
	r^ = {next_id = 1, last = -1}
	repeat_set(r, settings)
}

// Changes `r`'s settings (between blocks).
repeat_set :: proc "contextless" (r: ^Repeat, settings: Repeat_Settings) {
	s := settings
	if s.gate <= 0 do s.gate = 0.5
	s.gate = clamp(s.gate, 0.05, 1)
	r.settings = s
}

// [rt] Repeats one block's held notes.
repeat_process :: proc "contextless" (r: ^Repeat, t: ^core.Transport, frames: int, events_in: []core.Event, out: ^core.Event_Writer) {
	if out == nil do return
	if t == nil {
		for e in events_in do core.event_writer_push(out, e)
		return
	}
	step := rate_beats(r.settings.rate)
	next_step := first_step(t, step, r.last)
	ei := 0
	for {
		// The earliest note-off due.
		off_o, off_i := max(int), -1
		for i in 0 ..< MAX_HELD do if r.sounding[i] {
			if o := offset_at(t, r.playing[i].off_at); o < off_o do off_o, off_i = o, i
		}
		ev_o := int(events_in[ei].offset) if ei < len(events_in) else max(int)
		st_o := offset_at(t, next_step)
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
					// Plays at once, until the next step.
					beat := core.transport_grid_at(t, at)
					next := tb.Beats(math.floor(f64(beat / step) + 1e-9) + 1) * step
					repeat_on(r, out, at, r.count - 1, beat + min(step * tb.Beats(r.settings.gate), next - beat))
				}
			case core.Note_Off:
				for i in 0 ..< r.count do if r.held[i].key == v.key && r.held[i].channel == v.channel {
					if r.sounding[i] do repeat_off(r, out, at, i)
					// Keep the playing slots in step with the held list.
					copy(r.playing[i:r.count - 1], r.playing[i + 1:r.count])
					copy(r.sounding[i:r.count - 1], r.sounding[i + 1:r.count])
					r.sounding[r.count - 1] = false
					break
				}
				held_remove(&r.held, &r.count, v.key, v.channel)
			case:
				core.event_writer_push(out, e)
			}
		case .Step:
			for i in 0 ..< r.count {
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
}
