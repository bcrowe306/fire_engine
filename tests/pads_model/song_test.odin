package test_pads_model

import "core:testing"

import app "app:core"
import pm "../../apps/pads/model"
import kit "fire:testkit"

// Which pad (0: 440 Hz, 1: 880 Hz) sounds at each onset.
@(private)
which_pads :: proc(x: []f32, at: []int) -> [dynamic]int {
	out := make([dynamic]int, context.temp_allocator)
	for a in at {
		seg := x[a:][:min(1200, len(x) - a)]
		append(&out, 0 if kit.tone_amplitude(seg, SR, 440) > kit.tone_amplitude(seg, SR, 880) else 1)
	}
	return out
}

@(test)
a_song_plays_its_steps_then_stops :: proc(t: ^testing.T) {
	r := blips(t, "song_chain")
	defer rig_destroy(r)
	m := &r.m
	pm.add_note(m, 0, {start = 0, length = 0.25, pad = 0, velocity = 1}) // sequence 1: pad 0 on beat 1
	pm.add_note(m, 1, {start = 0, length = 0.25, pad = 1, velocity = 1}) // sequence 2: pad 1
	pm.song_add(m, 0, repeats = 2)
	pm.song_add(m, 1)
	testing.expect_value(t, m.project.song.count, 2)
	testing.expect_value(t, pm.song_beats(&m.project), 12)
	m.project.song_mode = true
	pm.play(&m.engine)
	out := render(r, 48_000 * 8) // 16 beats: the song is 12
	got := onsets(out[0][:])
	testing.expectf(t, len(got) == 3, "three bars, then it stops (%v)", got)
	if len(got) == 3 {
		pads := which_pads(out[0][:], got[:])
		testing.expectf(t, pads[0] == 0 && pads[1] == 0 && pads[2] == 1, "1, 1, 2 (%v)", pads)
		testing.expectf(t, abs(got[2] - (8 * 24_000 + 256)) <= 256, "the second sequence at beat 8 (%d)", got[2])
	}
	pm.sync(&m.engine) // (each frame, the app's sync notices the end; the clock stops on its next block)
	render(r, 512)
	_, playing := pm.position(&m.engine)
	testing.expect(t, !playing, "stopped at the end")
	// Looping, it goes round.
	s := m.project.song
	s.loop = true
	pm.set_song(m, "Loop", s)
	pm.play(&m.engine)
	out = render(r, 48_000 * 8)
	testing.expectf(t, len(onsets(out[0][:])) == 4, "round again (%v)", onsets(out[0][:]))
	// Editing the song undoes.
	pm.song_remove(m, 0)
	testing.expect_value(t, m.project.song.count, 1)
	app.undo(&m.history)
	testing.expect_value(t, m.project.song.count, 2)
}

@(test)
picking_a_sequence_while_playing_switches_on_the_grid :: proc(t: ^testing.T) {
	r := blips(t, "song_switch")
	defer rig_destroy(r)
	m := &r.m
	pm.add_note(m, 0, {start = 0, length = 0.25, pad = 0, velocity = 1})
	pm.add_note(m, 0, {start = 2, length = 0.25, pad = 0, velocity = 1})
	pm.add_note(m, 1, {start = 0, length = 0.25, pad = 1, velocity = 1})
	pm.add_note(m, 1, {start = 1, length = 0.25, pad = 1, velocity = 1})
	// At the end of the sequence: picked at beat 1, it takes over at beat 4.
	m.project.switch_at = .End
	pm.play(&m.engine)
	render(r, 24_000 + 2400) // beat 1.1
	pm.select_slot(m, 1)
	testing.expect_value(t, m.project.slot, 0) // not yet
	slot, in_beats, queued := pm.pending_switch(&m.engine)
	testing.expectf(t, queued && slot == 1 && abs(in_beats - 2.9) < 0.05, "queued for beat 4 (%v %v)", slot, in_beats)
	pm.sync(&m.engine)
	out := render(r, 48_000 * 2 - 2400) // to beat 5
	got := onsets(out[0][:])
	pads := which_pads(out[0][:], got[:])
	// Beat 2: pad 0 (still sequence 1); beat 4: pad 1 (sequence 2).
	testing.expectf(t, len(got) == 2 && pads[0] == 0 && pads[1] == 1, "then sequence 2 (%v %v)", got, pads)
	if len(got) == 2 do testing.expectf(t, abs((got[1] + 26_400) - (4 * 24_000 + 256)) <= 256, "exactly at beat 4 (%d)", got[1] + 26_400)
	pm.sync(&m.engine)
	testing.expect_value(t, m.project.slot, 1)
	// At the next beat.
	m.project.switch_at = .Beat
	render(r, 24_000 / 2) // beat 5.5
	pm.select_slot(m, 0)
	pm.sync(&m.engine)
	out = render(r, 24_000 * 3 / 2) // to beat 7
	got = onsets(out[0][:])
	pads = which_pads(out[0][:], got[:])
	testing.expectf(t, len(got) >= 1 && pads[0] == 0, "sequence 1 from beat 6 (%v %v)", got, pads)
	if len(got) >= 1 do testing.expectf(t, abs(got[0] - (12_000 + 256)) <= 256, "at beat 6 (%d)", got[0])
	// Merging: sequence 1's notes laid over sequence 2's.
	pm.merge_sequences(m, 0, 1)
	testing.expect_value(t, len(m.project.sequences[1].notes), 4)
	testing.expect_value(t, app.undo_name(&m.history), "Merge Sequences")
}
