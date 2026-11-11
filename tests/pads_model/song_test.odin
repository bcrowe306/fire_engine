package test_pads_model

import "core:testing"

import app "app:core"
import fc "fire:core"
import "fire:transport"
import pm "../../apps/pads/model"

@(test)
song_steps_play_parts_muted_transposed_at_their_tempo :: proc(t: ^testing.T) {
	r := blips(t, "song_steps")
	defer rig_destroy(r)
	m := &r.m
	p := &m.project
	for b in 0 ..< 4 do pm.add_note(m, 0, {start = f64(b), length = 0.25, pad = 0, velocity = 1})
	pm.song_add(m, 0) // all of it: 4 beats
	pm.song_add(m, 0) // beats 2..3 only, twice
	st := p.song.steps[1]
	st.start, st.length, st.repeats = 2, 2, 2
	pm.set_step(m, 1, st, "Step Part")
	pm.song_add(m, 0) // muted
	st = p.song.steps[2]
	st.mute = true
	pm.set_step(m, 2, st, "Mute Step")
	testing.expect_value(t, pm.song_beats(p), 4 + 4 + 4)
	pl := pm.plan_song(p, 0)
	// Step 2's first pass plays beats 2 and 3 of the sequence: located at
	// song beat 4.5, the sequence is at beat 2.5.
	_, slot, rel, ok := pm.plan_locate(pl, 4.5)
	testing.expect(t, ok && slot == 0 && abs(rel - 2.5) < 1e-9, "a part of the sequence")
	// The notes played: 4, then 2 + 2, then none (muted).
	p.song_mode = true
	m.engine.seq_dirty = true
	pm.play(&m.engine)
	out := render_synced(r, 48_000 * 6) // 12 beats at 120
	got := onsets(out[0][:])
	testing.expectf(t, len(got) == 8, "4 + 2 × 2, the muted step silent (%v)", got)
	// A step's tempo takes over where it does; the song's length in time.
	pm.stop(&m.engine)
	st = p.song.steps[1]
	st.bpm = 60
	pm.set_step(m, 1, st, "Step Tempo")
	secs := pm.song_seconds(p)
	testing.expectf(t, abs(secs - (2 + 4 + 2)) < 1e-9, "2 s + 4 beats at 60 + 2 s (%v)", secs)
	pm.play(&m.engine)
	render_synced(r, 48_000 * 2 + 2400) // past step 1 (4 beats at 120)
	testing.expect_value(t, transport.status(m.engine.host.clock).tempo_bpm, 60)
}

@(test)
arrangements_switch_undo_and_save :: proc(t: ^testing.T) {
	r := rig_make(t, "song_arr")
	defer rig_destroy(r)
	m := &r.m
	p := &m.project
	pm.add_note(m, 0, {start = 0, length = 0.25, pad = 0, velocity = 1})
	pm.song_add(m, 0)
	testing.expect_value(t, p.arrangement_count, 1)
	b := pm.add_arrangement(m, copy_of = 0)
	testing.expect_value(t, b, 1)
	testing.expect_value(t, p.song.count, 1) // the copy's song
	testing.expect_value(t, pm.arrangement_name(p, 1), "Song copy")
	pm.song_add(m, 0)
	testing.expect_value(t, p.song.count, 2)
	pm.select_arrangement(m, 0)
	testing.expect_value(t, p.song.count, 1) // the first is as it was
	pm.select_arrangement(m, 1)
	testing.expect_value(t, p.song.count, 2) // the second kept its step
	pm.rename_arrangement(m, 1, " Radio edit ")
	testing.expect_value(t, pm.arrangement_name(p, 1), "Radio edit")
	app.undo(&m.history)
	testing.expect_value(t, pm.arrangement_name(p, 1), "Song copy")
	app.redo(&m.history)
	// Saved and loaded: both, the current one, a step's settings, colours, curves.
	st := p.song.steps[1]
	st.start, st.length, st.transpose, st.mute = 1, 2, -3, true
	copy(st.label[:], "Drop")
	pm.set_step(m, 1, st, "Step")
	s := p.sequences[0]
	s.color = 0x123456
	pm.set_sequence(m, 0, .Name, "Colour", s)
	pm.add_point(m, 0, {pad = 0, param = .Volume, beat = 0, value = -12, curve = 0.5})
	pm.add_point(m, 0, {pad = 0, param = .Volume, beat = 2, value = 0})
	testing.expect_value(t, pm.model_save(m), fc.Error.None)
	r2 := rig_make(t, "song_arr2")
	defer rig_destroy(r2)
	testing.expect_value(t, pm.model_load(&r2.m, p.dir), fc.Error.None)
	q := &r2.m.project
	testing.expect_value(t, q.arrangement_count, 2)
	testing.expect_value(t, q.arrangement, 1)
	testing.expect_value(t, q.song.count, 2)
	testing.expect(t, q.song.steps[1].start == 1 && q.song.steps[1].length == 2 && q.song.steps[1].transpose == -3 && q.song.steps[1].mute, "the step's settings")
	testing.expect_value(t, pm.step_label(&q.song.steps[1]), "Drop")
	testing.expect_value(t, q.arrangements[0].song.count, 1)
	testing.expect_value(t, pm.sequence_color(q, 0), 0x123456)
	testing.expect_value(t, q.sequences[0].points[0].curve, 0.5)
	pm.delete_arrangement(&r2.m, 0)
	testing.expect_value(t, q.arrangement_count, 1)
	testing.expect_value(t, pm.arrangement_name(q, 0), "Radio edit")
}

@(test)
song_steps_moved_pasted_removed_as_groups :: proc(t: ^testing.T) {
	r := rig_make(t, "song_groups")
	defer rig_destroy(r)
	m := &r.m
	p := &m.project
	for k in 0 ..< 5 do pm.song_add(m, k) // steps play slots 0 1 2 3 4
	slots :: proc(p: ^pm.Project) -> (out: [dynamic]int) {
		out = make([dynamic]int, context.temp_allocator)
		for st in p.song.steps[:p.song.count] do append(&out, int(st.slot))
		return
	}
	same :: proc(a: [dynamic]int, b: []int) -> bool {
		if len(a) != len(b) do return false
		for x, i in a do if x != b[i] do return false
		return true
	}
	// Steps 1 and 3 to the end, then to the front.
	moved := pm.song_move_steps(m, {1, 3}, 5)
	testing.expectf(t, same(slots(p), {0, 2, 4, 1, 3}) && moved == {3, 4}, "to the end: %v %v", slots(p), moved)
	moved = pm.song_move_steps(m, moved, 0)
	testing.expectf(t, same(slots(p), {1, 3, 0, 2, 4}) && moved == {0, 1}, "to the front: %v", slots(p))
	app.undo(&m.history)
	testing.expectf(t, same(slots(p), {0, 2, 4, 1, 3}), "one undo step: %v", slots(p))
	// Pasted after the last selected, then removed together.
	copied := []pm.Song_Step{p.song.steps[0], p.song.steps[1]}
	added := pm.song_insert_steps(m, copied, 2)
	testing.expectf(t, same(slots(p), {0, 2, 0, 2, 4, 1, 3}) && added == {2, 3}, "pasted: %v", slots(p))
	pm.song_remove_steps(m, added)
	testing.expectf(t, same(slots(p), {0, 2, 4, 1, 3}), "removed: %v", slots(p))
	// Full: only as many as fit.
	for p.song.count < pm.SONG_STEPS do pm.song_add(m, 0)
	testing.expect_value(t, pm.song_insert_steps(m, copied, 0), pm.Step_Set{})
}

@(test)
muted_notes_stay_silent :: proc(t: ^testing.T) {
	r := blips(t, "muted_notes")
	defer rig_destroy(r)
	m := &r.m
	for b in 0 ..< 4 do pm.add_note(m, 0, {start = f64(b), length = 0.25, pad = 0, velocity = 1, muted = b % 2 == 1})
	pm.play(&m.engine)
	out := render_synced(r, 48_000 * 2) // 4 beats at 120
	got := onsets(out[0][:])
	testing.expectf(t, len(got) == 2, "two of four notes muted (%v)", got)
}
