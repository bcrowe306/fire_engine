package test_pads_model

import "core:testing"

import app "app:core"
import pm "../../apps/pads/model"
import kit "fire:testkit"

// Frames where a sound starts in `x`: the first loud frame after 2000 quiet ones.
@(private)
onsets :: proc(x: []f32, threshold: f32 = 0.05) -> [dynamic]int {
	out := make([dynamic]int, context.temp_allocator)
	quiet := 2000
	for v, i in x {
		if abs(v) > threshold {
			if quiet >= 2000 do append(&out, i)
			quiet = 0
		} else {
			quiet += 1
		}
	}
	return out
}

// A rig with a short blip on pad 0 (and pad 1, an octave up).
@(private)
blips :: proc(t: ^testing.T, name: string) -> ^Rig {
	r := rig_make(t, name)
	pm.load_onto_pad(&r.m, 0, tone(r, "blip.wav", 440, 0.08, decay = true))
	pm.load_onto_pad(&r.m, 1, tone(r, "blip2.wav", 880, 0.08, decay = true))
	render(r, 256)
	return r
}

@(test)
a_sequence_plays_its_notes_in_time_and_loops :: proc(t: ^testing.T) {
	r := blips(t, "seq_play")
	defer rig_destroy(r)
	m := &r.m
	pm.add_note(m, 0, {start = 0, length = 0.25, pad = 0, velocity = 1})
	pm.add_note(m, 0, {start = 1, length = 0.25, pad = 1, velocity = 1})
	pm.add_note(m, 0, {start = 2.5, length = 0.25, pad = 0, velocity = 1})
	testing.expect_value(t, len(m.project.sequences[0].notes), 3)
	testing.expect_value(t, app.undo_name(&m.history), "Add Note")
	pm.play(&m.engine)
	out := render(r, 48_000 * 4) // 8 beats at 120: two passes of the 1-bar loop
	got := onsets(out[0][:])
	want := []int{0, 24_000, 60_000, 96_000, 120_000, 156_000}
	testing.expectf(t, len(got) == len(want), "onsets %v (want %v)", got, want)
	for w, i in want do if i < len(got) {
		testing.expectf(t, abs(got[i] - (w + 256)) <= 256, "note %d at %d (want about %d)", i, got[i], w + 256)
	}
	pm.stop(&m.engine)
	render(r, 9600)
	quiet := render(r, 48_000)
	testing.expectf(t, kit.peak(quiet[0][:]) == 0, "stopped: silent")
}

@(test)
sequence_edits_undo_and_merge :: proc(t: ^testing.T) {
	r := rig_make(t, "seq_edit")
	defer rig_destroy(r)
	m := &r.m
	pm.add_note(m, 0, {start = 0.1, length = 0.25, pad = 3, velocity = 0.8})
	pm.add_note(m, 0, {start = 1.9, length = 0.25, pad = 3, velocity = 0.8})
	// A drag: many moves, one undo step.
	for k in 1 ..= 5 {
		n := m.project.sequences[0].notes[0]
		n.start = 0.1 + f64(k) * 0.1
		pm.set_note(m, 0, 0, n, .Note_Drag, "Move Note")
	}
	app.seal(&m.history)
	testing.expect_value(t, app.undo_name(&m.history), "Move Note")
	app.undo(&m.history)
	testing.expect_value(t, m.project.sequences[0].notes[0].start, 0.1)
	// Quantize to 1/4: 0.1 → 0, 1.9 → 2.
	pm.quantize_sequence(m, 0, .Quarter)
	notes := m.project.sequences[0].notes
	testing.expect(t, notes[0].start == 0 && notes[1].start == 2, "quantized")
	// Double: two bars, the notes repeated.
	pm.double_sequence(m, 0)
	s := m.project.sequences[0]
	testing.expect_value(t, s.bars, 2)
	testing.expect_value(t, len(s.notes), 4)
	testing.expect_value(t, s.notes[2].start, 4)
	app.undo(&m.history)
	app.undo(&m.history)
	testing.expect_value(t, m.project.sequences[0].notes[1].start, 1.9)
	// Slots are separate; copying one onto another is one step.
	pm.copy_sequence(m, 0, 5)
	testing.expect_value(t, len(m.project.sequences[5].notes), 2)
	pm.clear_sequence(m, 0)
	testing.expect(t, !pm.slot_used(m, 0) && pm.slot_used(m, 5), "cleared one slot only")
}

@(test)
notes_with_no_chance_are_silent_and_swing_moves_offbeats :: proc(t: ^testing.T) {
	r := blips(t, "seq_chance")
	defer rig_destroy(r)
	m := &r.m
	pm.add_note(m, 0, {start = 0, length = 0.1, pad = 0, velocity = 1, probability = 1})
	pm.add_note(m, 0, {start = 1, length = 0.1, pad = 0, velocity = 1})
	n := m.project.sequences[0].notes[1]
	n.probability = 0.001 // as good as never
	pm.set_note(m, 0, 1, n, .Probability, "Set Chance")
	pm.add_note(m, 0, {start = 2.5, length = 0.1, pad = 1, velocity = 1})
	pm.set_swing(m, 0, 1, .Eighth) // an 1/8 off-beat at 2.5 moves to 2.75
	pm.play(&m.engine)
	out := render(r, 96_000)
	got := onsets(out[0][:])
	testing.expectf(t, len(got) == 2, "two notes play (%v)", got)
	if len(got) == 2 do testing.expectf(t, abs(got[1] - (66_000 + 256)) <= 256, "the swung note at %d (want about %d)", got[1], 66_256)
}

@(test)
recording_puts_hits_where_they_were_played :: proc(t: ^testing.T) {
	r := blips(t, "seq_record")
	defer rig_destroy(r)
	m := &r.m
	c: pm.Capture
	defer pm.capture_destroy(&c)
	m.project.transport.quantize = {on = true, grid = .Sixteenth, strength = 1}
	pm.capture_arm(m, &c, true)
	pm.play(&m.engine)
	render(r, 24_000 + 1200) // about beat 1.05
	pm.hit(&m.engine, 1, true, 0.7)
	render(r, 6000)
	pm.hit(&m.engine, 1, false)
	render(r, 512)
	testing.expect(t, pm.capture_poll(m, &c), "a note")
	pm.hit(&m.engine, 0, true)
	render(r, 512)
	pm.capture_arm(m, &c, false) // ends the held one
	pm.capture_poll(m, &c)
	notes := m.project.sequences[0].notes
	testing.expectf(t, len(notes) == 2, "two notes (%v)", notes)
	if len(notes) == 2 {
		testing.expectf(t, notes[0].pad == 1 && notes[0].start == 1 && abs(notes[0].velocity - 0.7) < 1e-6, "on the grid, at its velocity: %v", notes[0])
		testing.expectf(t, abs(notes[0].length - 0.25) < 0.05, "held a quarter of a beat: %v", notes[0].length)
	}
	testing.expect_value(t, app.undo_name(&m.history), "Record")
	app.undo(&m.history) // the whole take
	testing.expect_value(t, len(m.project.sequences[0].notes), 0)
}

@(test)
the_metronome_clicks_while_playing :: proc(t: ^testing.T) {
	r := rig_make(t, "seq_click")
	defer rig_destroy(r)
	m := &r.m
	m.engine.metronome = true
	pm.sync(&m.engine)
	pm.play(&m.engine)
	out := render(r, 48_000)
	got := onsets(out[0][:], 0.01)
	testing.expectf(t, len(got) == 2, "two clicks in a second at 120 BPM (%v)", got)
	m.engine.metronome = false
	pm.sync(&m.engine)
	render(r, 512)
	quiet := render(r, 48_000)
	testing.expect_value(t, kit.peak(quiet[0][:]), 0)
}
