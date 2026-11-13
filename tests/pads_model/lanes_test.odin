package test_pads_model

import "core:testing"

import app "app:core"
import fc "fire:core"
import pm "../../apps/pads/model"

@(test)
lanes_by_default_and_an_old_projects :: proc(t: ^testing.T) {
	r := rig_make(t, "lanes_default")
	defer rig_destroy(r)
	p := &r.m.project
	testing.expect_value(t, p.lanes.count, pm.DEFAULT_LANES)
	for k in 0 ..< pm.SLOTS {
		testing.expect_value(t, pm.seq_lane(p, k), k % 8)
		testing.expect_value(t, pm.lane_slot(p, k % 8, k / 8), k)
	}
	testing.expect_value(t, pm.launch_lane_name(p, 2), "Lane 3")
	// An older project's 4 lanes: its banks' columns, each bank's rows in turn.
	old := pm.default_lanes(4)
	for bank in 0 ..< 4 do for row in 0 ..< 4 do for col in 0 ..< 4 {
		slot := bank * 16 + row * 4 + col
		testing.expect_value(t, old.place[slot], pm.Seq_Place{u8(col), u8(bank * 4 + row)})
	}
}

@(test)
a_sequence_moved_to_another_lane_launches_there :: proc(t: ^testing.T) {
	r := blips(t, "lanes_move")
	defer rig_destroy(r)
	m := &r.m
	p := &m.project
	for b in 0 ..< 4 do pm.add_note(m, 0, {start = f64(b), length = 0.25, pad = 0, velocity = 1})
	pm.add_note(m, 9, {start = 0.5, length = 0.25, pad = 1, velocity = 1}) // lane 2, row 2
	// Sequence 10 to the top of lane 1: lane 1 is 10, 1, 9...; lane 2 closes up.
	pm.move_sequence(m, 9, 0, 0)
	testing.expect_value(t, app.undo_name(&m.history), "Move Sequence")
	testing.expect_value(t, pm.lane_slot(p, 0, 0), 9)
	testing.expect_value(t, pm.lane_slot(p, 0, 1), 0)
	testing.expect_value(t, pm.lane_slot(p, 1, 0), 1)
	testing.expect_value(t, pm.lane_slot(p, 1, 1), 17)
	testing.expect_value(t, pm.lane_rows(p, 0), 9)
	testing.expect_value(t, pm.lane_rows(p, 1), 7)
	// Launched, it replaces lane 1's sequence (not lane 2's).
	pm.launch_slot(m, 0)
	render_synced(r, 1200)
	m.project.switch_at = .Now
	pm.launch_slot(m, 9)
	render_synced(r, 1200)
	s0, _, _, _, _ := pm.column_state(&m.engine, 0)
	testing.expectf(t, s0 == 9, "lane 1 plays sequence 10 (%v)", s0)
	// Scene 1 (row 1 of every lane): sequence 10 in lane 1 (lane 2's is empty).
	pm.stop(&m.engine)
	pm.launch_scene(m, 0)
	s0, _, _, _, _ = pm.column_state(&m.engine, 0)
	testing.expect_value(t, s0, 9)
	pm.stop(&m.engine)
	// Both lanes have pad 0? No: 10 plays pad 1, 1 plays pad 0. Pad 1 in lane 2 too:
	pm.add_note(m, 1, {start = 0, length = 0.25, pad = 1, velocity = 1})
	pads := pm.all_seq_pads(p)
	testing.expect_value(t, pm.shared_lane(p, &pads, 9), 1)
	testing.expect_value(t, pm.shared_lane(p, &pads, 0), -1)
	app.undo(&m.history) // (the note)
	app.undo(&m.history) // the move
	testing.expect_value(t, pm.lane_slot(p, 1, 1), 9)
}

@(test)
lanes_added_named_deleted_and_saved :: proc(t: ^testing.T) {
	r := rig_make(t, "lanes_edit")
	defer rig_destroy(r)
	m := &r.m
	p := &m.project
	testing.expect(t, pm.add_lane(m), "a ninth lane")
	testing.expect_value(t, p.lanes.count, 9)
	testing.expect_value(t, pm.lane_rows(p, 8), 0)
	// A new sequence at its end: an unused one, moved there.
	slot := pm.new_sequence_in(m, 8)
	testing.expect(t, slot >= 0 && pm.seq_lane(p, slot) == 8, "a sequence in lane 9")
	testing.expect_value(t, pm.lane_rows(p, 8), 1)
	pm.rename_lane(m, 8, "Fills")
	pm.color_lane(m, 8, 0x336699)
	testing.expect_value(t, pm.launch_lane_name(p, 8), "Fills")
	// Saved and opened: the same.
	pm.add_note(m, slot, {start = 0, length = 0.25, pad = 0, velocity = 1})
	testing.expect_value(t, pm.model_save(m), fc.Error.None)
	r2 := rig_make(t, "lanes_edit_load")
	defer rig_destroy(r2)
	testing.expect_value(t, pm.model_load(&r2.m, p.dir), fc.Error.None)
	p2 := &r2.m.project
	testing.expect_value(t, p2.lanes.count, 9)
	testing.expect_value(t, pm.launch_lane_name(p2, 8), "Fills")
	testing.expect_value(t, p2.lanes.lanes[8].color, u32(0x336699))
	testing.expect_value(t, pm.seq_lane(p2, slot), 8)
	// Lane 2 deleted: its sequences at the end of lane 1; the lanes after move down.
	before := pm.lane_rows(p, 0)
	two := pm.lane_rows(p, 1)
	testing.expect(t, pm.delete_lane(m, 1), "deleted")
	testing.expect_value(t, p.lanes.count, 8)
	testing.expect_value(t, pm.lane_rows(p, 0), before + two)
	testing.expect_value(t, pm.launch_lane_name(p, 7), "Fills")
	testing.expect_value(t, pm.seq_lane(p, slot), 7)
	app.undo(&m.history)
	testing.expect_value(t, p.lanes.count, 9)
}
