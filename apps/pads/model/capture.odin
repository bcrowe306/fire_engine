package pads_model

import app "app:core"
import "fire:clip"
import tb "fire:timebase"
import "fire:transport"
import "fire:rt"

// Live recording into the current sequence: while armed and playing, the
// pads you hit become notes where you hit them (overdubbed onto what is
// there), each pass of the loop adding to the same undo step.
Capture :: struct {
	armed:         bool, // (input quantize is the transport's: Transport.quantize)
	held:          [PADS][dynamic]Held_Hit, // per pad: hits not yet released
	midi_key:      int, // the last MIDI note that came in (-1: none yet), for MIDI learn
	midi_count:    int, // MIDI notes that came in (to notice a new one)
	preroll:       f64, // beats: a hit this much before a sequence's downbeat (or the end of the count-in) goes on the downbeat (0: none)
	// The MIDI notes on pads that came in since the last poll (for the app:
	// an armed Sample control starts on one), a hit each: on or off.
	midi_presses:  [dynamic]Taken,
	midi_offset:   f64, // seconds: notes from MIDI are recorded this much earlier (a controller's delay)
}

@(private)
Held_Hit :: struct {
	start:    f64, // where the note goes (on the grid, with live quantize)
	played:   f64, // the timeline beat it was played at (its length counts from here)
	velocity: f32,
	pitch:    i8,
	slot:     int, // the sequence it was played into
	exact:    bool, // a MIDI effect's note: its length as played (no one-shot minimum)
}

// Arms (or disarms) recording. Disarming ends the take: its notes become one
// undo step, and pads still held end where they are.
capture_arm :: proc(m: ^Model, c: ^Capture, on: bool) {
	if c.armed == on do return
	if !on do capture_poll(m, c) // what was played before the stop
	c.armed = on
	m.engine.router.capture = on
	m.engine.recording = on
	if !on {
		pos, _, _ := transport.timeline_status(m.engine.host.clock, m.engine.timeline)
		for i in 0 ..< PADS do for len(c.held[i]) > 0 do finish_hit(m, c, i, f64(pos))
		app.seal(&m.history)
	}
}

// Where a note played at beat `beat` goes with input quantize `q`: toward
// the nearest grid step (swung, if `q.swing`), as far as `q.strength`.
input_quantize :: proc(q: Input_Quantize, beat: f64) -> f64 {
	if !q.on || q.strength <= 0 do return beat
	g := grid_beats(q.grid)
	target := f64(clip.swing(tb.Beats(quantize_beat(beat, g)), tb.Beats(g), f64(q.swing)))
	return beat + (target - beat) * f64(clamp(q.strength, 0, 1))
}

// Frees the capture's buffers.
capture_destroy :: proc(c: ^Capture) {
	for &h in c.held do delete(h)
	delete(c.midi_presses)
}

// Takes the hits the router played since the last call into the current
// sequence. Call once per frame. True if notes were added.
capture_poll :: proc(m: ^Model, c: ^Capture) -> (added: bool) {
	clear(&c.midi_presses)
	for t in rt.spsc_pop(&m.engine.router.taken) {
		if t.midi_key >= 0 && !t.no_pad && !t.fx do append(&c.midi_presses, t)
		if t.midi_key >= 0 && t.on {
			c.midi_key = int(t.midi_key)
			c.midi_count += 1
		}
		// A key its pad's MIDI effect plays: the effect's notes are recorded
		// instead (they come as `fx`).
		if t.no_pad || t.effected || !c.armed || !t.playing do continue
		i := int(t.pad)
		t := t
		if t.midi_key >= 0 && c.midi_offset != 0 do t.beat -= c.midi_offset * m.engine.bpm / 60 // (MIDI: the controller's delay)
		// Played to what was heard, which came out the device's output
		// latency after the engine made it: that much earlier. (Not a MIDI
		// effect's notes: they are the engine's, on its grid.)
		if !t.fx {
			if ol, rate := output_latency(&m.engine), m.engine.host.format.sample_rate; ol > 0 && rate > 0 do t.beat -= f64(ol) / rate * m.engine.bpm / 60
		}
		if t.on {
			// Just before a sequence's downbeat (its part's start, each pass;
			// the top after a count-in): on the downbeat, so a hit a little
			// early isn't lost at the end of the loop or before the top.
			if slot, start, early := downbeat_ahead(m, c.preroll, t.beat); early && !t.fx {
				append(&c.held[i], Held_Hit{start, t.beat, t.velocity, t.pitch, slot, false})
				continue
			}
			_, slot, rel, ok := plan_locate(m.engine.plan, t.beat, editing_slot(m))
			if !ok do continue
			start := input_quantize(m.project.transport.quantize, rel)
			// A MIDI effect's notes: on its own grid (note repeat's rate,
			// the arpeggiator's), never moved; the first, played at the
			// press, onto that grid when input quantize is on (not a
			// coarser one, where repeats would merge).
			if t.fx do if step := fx_step(&m.engine, i); step > 0 {
				q := m.project.transport.quantize
				on_grid := abs(rel - quantize_beat(rel, step)) < 1e-4
				start = rel
				if !on_grid && q.on && q.strength > 0 do start = rel + (quantize_beat(rel, step) - rel) * f64(clamp(q.strength, 0, 1))
			}
			length := seq_beats(&m.project, m.project.sequences[slot])
			if start >= length do start -= length
			append(&c.held[i], Held_Hit{start, t.beat, t.velocity, t.pitch, slot, t.fx})
		} else if len(c.held[i]) > 0 {
			k := 0 // the held hit of the same pitch (a chord's notes end one by one)
			for h, j in c.held[i] do if h.pitch == t.pitch {
				k = j
				break
			}
			finish_hit(m, c, i, t.beat, k)
			added = true
		}
	}
	if audio_poll(m) do added = true
	return
}

// Whether a sequence's downbeat (the start of a pass of its part) comes
// within `preroll` beats after timeline beat `beat`: its sequence and where
// in it the downbeat is.
@(private)
downbeat_ahead :: proc(m: ^Model, preroll, beat: f64) -> (slot: int, start: f64, ok: bool) {
	if preroll <= 0 do return
	pl := m.engine.plan
	seg, s, rel, found := plan_locate(pl, beat + preroll, editing_slot(m))
	if !found do return
	into := rel - pl.segs[seg].offset // how far past its downbeat beat + preroll is
	if into >= preroll - 1e-9 do return
	return s, pl.segs[seg].offset, true
}

// Pad `i`'s held hit `k` (the oldest by default) ends at `beat`: add it as
// a note.
@(private)
finish_hit :: proc(m: ^Model, c: ^Capture, i: int, beat: f64, k := 0) {
	h := c.held[i][k]
	ordered_remove(&c.held[i], k)
	length := seq_beats(&m.project, m.project.sequences[h.slot])
	d := beat - h.played
	// A one-shot pad plays to its end however briefly it is hit: give the
	// note a grid step, so it can be seen and edited.
	if m.project.pads[i].mode == .One_Shot && !h.exact do d = max(d, grid_beats(m.project.transport.quantize.grid))
	d = clamp(d, 1.0 / 64, length)
	s := m.project.sequences[h.slot]
	notes := make([dynamic]Seq_Note, 0, len(s.notes) + 1, context.temp_allocator)
	append(&notes, ..s.notes)
	append(&notes, Seq_Note{start = h.start, length = d, pad = u8(i), pitch = h.pitch, velocity = h.velocity, probability = 1})
	s.notes = notes[:]
	set_sequence(m, h.slot, .Record, "Record", s)
}
