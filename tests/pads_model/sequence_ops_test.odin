package test_pads_model

import "core:testing"

import app "app:core"
import fc "fire:core"
import "fire:transport"
import pm "../../apps/pads/model"

@(test)
sequences_are_named_and_duplicated :: proc(t: ^testing.T) {
	r := rig_make(t, "seq_dup")
	defer rig_destroy(r)
	m := &r.m
	testing.expect_value(t, pm.sequence_name(&m.project, 2), "Sequence 3")
	pm.rename_sequence(m, 0, "  Verse ")
	testing.expect_value(t, pm.sequence_name(&m.project, 0), "Verse")
	testing.expect_value(t, app.undo_name(&m.history), "Rename Sequence")
	pm.add_note(m, 0, {start = 1, length = 0.5, pad = 2, velocity = 1})
	pm.set_bars(m, 0, 2)
	pm.add_note(m, 2, {start = 0, length = 1, pad = 0, velocity = 1}) // slot 3 is used: skipped
	to := pm.duplicate_sequence(m, 0)
	testing.expect_value(t, to, 1)
	d := m.project.sequences[1]
	testing.expect(t, len(d.notes) == 1 && d.bars == 2, "notes and length")
	testing.expect_value(t, pm.sequence_name(&m.project, 1), "Verse copy")
	testing.expect_value(t, m.project.slot, 1) // selected (stopped: at once)
	again := pm.duplicate_sequence(m, 1)
	testing.expect_value(t, again, 3) // the next empty one after it
	app.undo(&m.history)
	testing.expect(t, !pm.slot_used(m, 3), "one undo step")
	pm.rename_sequence(m, 1, "")
	testing.expect_value(t, pm.sequence_name(&m.project, 1), "Sequence 2")
}

@(test)
parts_of_sequences_copy_into_others :: proc(t: ^testing.T) {
	r := rig_make(t, "seq_part")
	defer rig_destroy(r)
	m := &r.m
	pm.set_bars(m, 0, 4)
	for bar in 0 ..< 4 do for pad in 0 ..< 3 {
		pm.add_note(m, 0, {start = f64(bar * 4 + pad), length = 0.5, pad = u8(pad), velocity = 1})
	}
	pm.add_point(m, 0, {pad = 1, param = .Volume, beat = 5, value = -6})
	// Bars 2-3, pads 0 and 1 only, into sequence 2 from bar 3: it grows.
	pads: [pm.PADS]bool
	pads[0], pads[1] = true, true
	pm.add_note(m, 1, {start = 8.5, length = 0.25, pad = 0, velocity = 0.3}) // in the way: replaced
	pm.add_note(m, 1, {start = 8.5, length = 0.25, pad = 5, velocity = 0.3}) // another pad: kept
	pm.copy_bars(m, 0, 2, 3, &pads, 1, 3)
	s := m.project.sequences[1]
	testing.expect_value(t, s.bars, 4)
	n0, n1, n2, n5 := 0, 0, 0, 0
	for n in s.notes {
		switch n.pad {
		case 0: n0 += 1; testing.expect(t, n.start >= 8 && n.start < 16, "at bar 3 on")
		case 1: n1 += 1
		case 2: n2 += 1
		case 5: n5 += 1
		}
	}
	testing.expect(t, n0 == 2 && n1 == 2 && n2 == 0 && n5 == 1, "its pads replaced, others kept")
	testing.expect(t, len(s.points) == 1 && s.points[0].beat == 9, "its automation, moved")
	testing.expect_value(t, app.undo_name(&m.history), "Copy Bars")
	// Laid over (not replacing): the old notes stay, the new ones win.
	part: pm.Seq_Part
	defer pm.part_destroy(&part)
	pm.copy_part(&m.project, 0, 0, 4, nil, &part)
	testing.expect_value(t, len(part.notes), 3)
	pm.paste_part(m, 2, &part, 0, replace = false)
	pm.paste_part(m, 2, &part, 2, replace = false) // overlapping itself: trimmed, not doubled
	testing.expect_value(t, len(m.project.sequences[2].notes), 6)
}

@(test)
a_sequence_with_its_own_tempo_sets_it_where_it_takes_over :: proc(t: ^testing.T) {
	r := blips(t, "seq_tempo")
	defer rig_destroy(r)
	m := &r.m
	pm.add_note(m, 0, {start = 0, length = 0.25, pad = 0, velocity = 1})
	pm.add_note(m, 1, {start = 0, length = 0.25, pad = 1, velocity = 1})
	pm.set_sequence_tempo(m, 1, 150)
	testing.expect_value(t, pm.sequence_tempo(&m.project, 0), 120)
	testing.expect_value(t, pm.sequence_tempo(&m.project, 1), 150)
	pm.play(&m.engine)
	render_synced(r, 4800)
	testing.expect_value(t, transport.status(m.engine.host.clock).tempo_bpm, 120)
	// Switch at the end of the sequence (a bar at 120: 2 s): the tempo
	// changes there, not before.
	m.project.switch_at = .End
	pm.select_slot(m, 1)
	render_synced(r, 48_000) // 1.1 s in
	testing.expect_value(t, transport.status(m.engine.host.clock).tempo_bpm, 120)
	render_synced(r, 48_000) // 2.1 s: the second sequence plays
	testing.expect_value(t, m.project.slot, 1)
	testing.expect_value(t, transport.status(m.engine.host.clock).tempo_bpm, 150)
	// Saved and loaded with its name.
	pm.rename_sequence(m, 1, "Fast")
	testing.expect_value(t, pm.model_save(m), fc.Error.None)
	r2 := rig_make(t, "seq_tempo2")
	defer rig_destroy(r2)
	testing.expect_value(t, pm.model_load(&r2.m, m.project.dir), fc.Error.None)
	testing.expect_value(t, r2.m.project.sequences[1].bpm, 150)
	testing.expect_value(t, pm.sequence_name(&r2.m.project, 1), "Fast")
}
