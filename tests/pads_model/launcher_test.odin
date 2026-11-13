package test_pads_model

import "core:testing"

import app "app:core"

import pm "../../apps/pads/model"

// Sequences 1 (column 1: four hits a bar) and 2 (column 2: one hit, off
// the beat), on pad 0.
@(private = "file")
two_columns :: proc(t: ^testing.T, name: string) -> ^Rig {
	r := blips(t, name)
	m := &r.m
	for b in 0 ..< 4 do pm.add_note(m, 0, {start = f64(b), length = 0.25, pad = 0, velocity = 1})
	pm.add_note(m, 1, {start = 0.5, length = 0.25, pad = 0, velocity = 1})
	return r
}

@(test)
launcher_columns_play_together :: proc(t: ^testing.T) {
	r := two_columns(t, "launch_together")
	defer rig_destroy(r)
	m := &r.m
	testing.expect_value(t, pm.launch_col(&m.project, 0), 0)
	testing.expect_value(t, pm.launch_col(&m.project, 1), 1)
	testing.expect_value(t, pm.launch_col(&m.project, 8), 0) // (8 lanes: the row above, the same lane)
	pm.launch_slot(m, 0) // stopped: it starts, alone
	render_synced(r, 1200)
	m.project.switch_at = .Now
	pm.launch_slot(m, 1) // playing: in its own column, beside the first
	out := render_synced(r, 48_000 * 2 - 1200) // the rest of a bar at 120
	got := onsets(out[0][:])
	testing.expectf(t, len(got) == 5, "four from the first column, one from the second (%v)", got)
	s0, _, _, _, _ := pm.column_state(&m.engine, 0)
	s1, _, _, _, _ := pm.column_state(&m.engine, 1)
	testing.expect(t, s0 == 0 && s1 == 1, "both columns playing")
	// The column's own stop: only the first plays on.
	pm.stop_column(&m.engine, 1)
	out = render_synced(r, 48_000 * 2)
	got = onsets(out[0][:])
	testing.expectf(t, len(got) == 4, "the second column stopped (%v)", got)
}

@(test)
a_launch_replaces_only_its_column :: proc(t: ^testing.T) {
	r := two_columns(t, "launch_replace")
	defer rig_destroy(r)
	m := &r.m
	pm.add_note(m, 8, {start = 0, length = 0.25, pad = 0, velocity = 1}) // sequence 9: lane 1 again
	pm.launch_scene(m, 0) // sequences 1 and 2 (the rest of the row is empty)
	m.project.switch_at = .Bar
	render_synced(r, 48_000) // half a bar in
	pm.launch_slot(m, 8)
	next, in_beats, ok := pm.pending_switch(&m.engine)
	testing.expectf(t, ok && next == 8 && abs(in_beats - 2) < 0.1, "queued for the bar (%v %v %v)", next, in_beats, ok)
	_, _, queued_next, _, queued := pm.column_state(&m.engine, 0)
	testing.expect(t, queued && queued_next == 8, "queued in its column")
	render_synced(r, 48_000 + 4800) // past the bar
	s0, _, _, _, _ := pm.column_state(&m.engine, 0)
	s1, _, _, _, _ := pm.column_state(&m.engine, 1)
	testing.expectf(t, s0 == 8 && s1 == 1, "column 1 took over, column 2 played on (%v %v)", s0, s1)
	testing.expect_value(t, m.project.slot, 8) // (the editor shows the one launched)
	// Picking a sequence to edit (not from the launcher): it plays alone.
	pm.select_slot(m, 1)
	render_synced(r, 48_000 * 2 + 2400)
	s0, _, _, _, _ = pm.column_state(&m.engine, 0)
	testing.expectf(t, s0 == -1, "the other column stopped with it (%v)", s0)
}

@(test)
a_row_launches_together_and_the_loop_fits_them_all :: proc(t: ^testing.T) {
	r := two_columns(t, "launch_row")
	defer rig_destroy(r)
	m := &r.m
	s := m.project.sequences[1]
	s.bars = 3
	pm.set_sequence(m, 1, .Bars, "Bars", s)
	pm.launch_scene(m, 0) // sequences 1 and 2 (the rest of the row is empty)
	s0, _, _, _, _ := pm.column_state(&m.engine, 0)
	s1, _, _, _, _ := pm.column_state(&m.engine, 1)
	s2, _, _, _, _ := pm.column_state(&m.engine, 2)
	testing.expect(t, s0 == 0 && s1 == 1 && s2 == -1, "the row's sequences")
	pl := pm.plan_launch(&m.project, &m.engine.launch, m.engine.plan.at)
	testing.expectf(t, pl.loop_end - pl.loop_start == 12, "one bar and three: a 3-bar loop (%v)", pl.loop_end - pl.loop_start)
	// Stop All, playing: nothing more plays.
	render_synced(r, 4800)
	m.project.switch_at = .Now
	pm.stop_all_columns(&m.engine)
	out := render_synced(r, 48_000 * 2)
	testing.expectf(t, len(onsets(out[0][:])) == 0, "stopped (%v)", onsets(out[0][:]))
}

@(test)
launches_are_recorded_into_the_song :: proc(t: ^testing.T) {
	r := two_columns(t, "launch_record")
	defer rig_destroy(r)
	m := &r.m
	m.project.lanes = pm.default_lanes(4) // (4 lanes, as an older project's: sequence 5 is lane 1's second)
	pm.add_note(m, 4, {start = 0, length = 0.25, pad = 0, velocity = 1}) // sequence 5: column 1
	m.project.switch_at = .Bar
	pm.set_launch_record(m, true)
	pm.launch_slot(m, 0) // from the top: column 1
	render_synced(r, 48_000) // half a bar
	pm.launch_slot(m, 1) // column 2, at bar 2
	render_synced(r, 48_000 * 2) // into bar 2
	pm.launch_slot(m, 4) // column 1 again, at bar 3
	render_synced(r, 48_000 * 2 + 4800) // into bar 3
	pm.stop(&m.engine) // the take ends (just past beat 8)
	pm.launch_record_poll(m)
	s := &m.project.song
	testing.expectf(t, s.count == 3, "three clips (%v)", s.clips[:s.count])
	of :: proc(s: ^pm.Song, slot: u8) -> (c: pm.Song_Clip) {
		for x in s.clips[:s.count] do if x.slot == slot do c = x
		return
	}
	c0, c1, c2 := of(s, 0), of(s, 1), of(s, 4)
	testing.expectf(t, c0.lane == 0 && c0.slot == 0 && c0.at == 0 && abs(c0.length - 8) < 1e-6, "sequence 1, bars 1-2: %v", c0)
	testing.expectf(t, c1.lane == 1 && c1.slot == 1 && c1.at == 4 && c1.length > 4, "sequence 2 from bar 2: %v", c1)
	testing.expectf(t, c2.lane == 0 && c2.slot == 4 && c2.at == 8, "sequence 5 from bar 3: %v", c2)
	testing.expect_value(t, app.undo_name(&m.history), "Record to Song")
	// Disarmed: nothing more is written.
	pm.set_launch_record(m, false)
	pm.launch_slot(m, 0)
	render_synced(r, 48_000)
	pm.stop(&m.engine)
	pm.launch_record_poll(m)
	testing.expect_value(t, s.count, 3)
}

@(test)
continue_carries_on_where_the_playhead_is :: proc(t: ^testing.T) {
	r := two_columns(t, "launch_continue")
	defer rig_destroy(r)
	m := &r.m
	m.project.lanes = pm.default_lanes(4) // (4 lanes, as an older project's: sequence 5 is lane 1's second)
	s := m.project.sequences[4]
	s.bars = 2
	pm.set_sequence(m, 4, .Bars, "Bars", s) // sequence 5: 8 beats, column 1
	pm.add_note(m, 4, {start = 6, length = 0.25, pad = 0, velocity = 1})
	pm.set_launch_continue(m, true)
	m.project.switch_at = .Now
	pm.launch_slot(m, 0) // sequence 1 (4 beats) from the top
	render_synced(r, 48_000 * 2 + 24_000) // 5 beats in: beat 1 of its second pass
	pm.launch_slot(m, 4) // continues: 1 beat into its 8
	c := m.engine.launch.cols[0]
	beat, _ := pm.timeline_beat(&m.engine)
	into := beat - c.since
	testing.expectf(t, c.slot == 4 && abs(into - 1) < 0.05, "a beat into sequence 5 (%v)", into)
	// Shift: launched alone, the others stop.
	pm.launch_slot(m, 1) // column 2, beside it
	pm.launch_slot(m, 0, alone = true)
	render_synced(r, 2400)
	s0, _, _, _, _ := pm.column_state(&m.engine, 0)
	s1, _, _, _, _ := pm.column_state(&m.engine, 1)
	testing.expectf(t, s0 == 0 && s1 == -1, "alone (%v %v)", s0, s1)
	// Into a longer one from a shorter: by the modulo of its length.
	pm.set_launch_continue(m, true)
	render_synced(r, 48_000 * 3) // sequence 1 some way into a pass
	b0, _ := pm.timeline_beat(&m.engine)
	ref := m.engine.launch.cols[0]
	want := mod4(b0 - ref.since)
	pm.launch_slot(m, 4)
	c = m.engine.launch.cols[0]
	testing.expectf(t, abs(mod4(b0 - c.since) - want) < 0.05 && b0 - c.since < 8, "the same place in the pass (%v, %v)", b0 - c.since, want)
}

@(private = "file")
mod4 :: proc(x: f64) -> f64 {
	y := x
	for y >= 4 do y -= 4
	for y < 0 do y += 4
	return y
}
