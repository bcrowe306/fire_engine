package pads_model

import app "app:core"
import "fire:rt"

// Live recording into the current sequence: while armed and playing, the
// pads you hit become notes where you hit them (overdubbed onto what is
// there), each pass of the loop adding to the same undo step.
Capture :: struct {
	armed:         bool,
	live_quantize: bool, // notes land on the grid
	grid:          Grid,
	held:          [PADS][dynamic]Held_Hit, // per pad: hits not yet released
}

@(private)
Held_Hit :: struct {
	start:    f64, // where the note goes (on the grid, with live quantize)
	played:   f64, // where it was played (its length counts from here)
	velocity: f32,
	pitch:    i8,
}

// Arms (or disarms) recording. Disarming ends the take: its notes become one
// undo step, and pads still held end where they are.
capture_arm :: proc(m: ^Model, c: ^Capture, on: bool) {
	if c.armed == on do return
	if !on do capture_poll(m, c) // what was played before the stop
	c.armed = on
	m.engine.router.capture = on
	if !on {
		beat, _ := position(&m.engine)
		for i in 0 ..< PADS do for len(c.held[i]) > 0 do finish_hit(m, c, i, beat)
		app.seal(&m.history)
	}
}

// Frees the capture's buffers.
capture_destroy :: proc(c: ^Capture) {
	for &h in c.held do delete(h)
}

// Takes the hits the router played since the last call into the current
// sequence. Call once per frame. True if notes were added.
capture_poll :: proc(m: ^Model, c: ^Capture) -> (added: bool) {
	for t in rt.spsc_pop(&m.engine.router.taken) {
		if !c.armed || !t.playing do continue
		i := int(t.pad)
		if t.on {
			start := t.beat
			if c.live_quantize do start = quantize_beat(start, grid_beats(c.grid))
			length := seq_beats(current_sequence(m))
			if start >= length do start -= length
			append(&c.held[i], Held_Hit{start, t.beat, t.velocity, t.pitch})
		} else if len(c.held[i]) > 0 {
			finish_hit(m, c, i, t.beat)
			added = true
		}
	}
	return
}

// Pad `i`'s oldest held hit ends at `beat`: add it as a note.
@(private)
finish_hit :: proc(m: ^Model, c: ^Capture, i: int, beat: f64) {
	h := c.held[i][0]
	ordered_remove(&c.held[i], 0)
	length := seq_beats(current_sequence(m))
	d := beat - h.played
	if d <= 0 do d += length // held across the loop's end
	// A one-shot pad plays to its end however briefly it is hit: give the
	// note a grid step, so it can be seen and edited.
	if m.project.pads[i].mode == .One_Shot do d = max(d, grid_beats(c.grid))
	d = clamp(d, 1.0 / 64, length)
	s := current_sequence(m)
	notes := make([dynamic]Seq_Note, 0, len(s.notes) + 1, context.temp_allocator)
	append(&notes, ..s.notes)
	append(&notes, Seq_Note{start = h.start, length = d, pad = u8(i), pitch = h.pitch, velocity = h.velocity, probability = 1})
	s.notes = notes[:]
	set_sequence(m, m.project.slot, .Record, "Record", s)
}
