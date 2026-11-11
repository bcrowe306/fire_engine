package test_pads_model

import "core:testing"

import app "app:core"
import fc "fire:core"
import pm "../../apps/pads/model"

@(test)
pads_grouped_under_a_bus :: proc(t: ^testing.T) {
	r := tone_rig(t, "groups")
	defer rig_destroy(r)
	m := &r.m
	p := &m.project
	pm.load_onto_pad(m, 1, tone(r, "b.wav", 300, 4))
	pm.load_onto_pad(m, 2, tone(r, "c.wav", 500, 4))
	buses := p.bus_count
	b := pm.group_pads(m, {0, 2}, "Drums")
	testing.expect_value(t, b, buses + 1)
	testing.expect(t, p.buses[b - 1].group && pm.bus_name(p, b) == "Drums")
	testing.expect(t, int(p.pads[0].bus) == b && int(p.pads[2].bus) == b && p.pads[1].bus == 0)
	testing.expect_value(t, len(pm.group_members(p, b)), 2)
	testing.expect_value(t, m.history.undo[len(m.history.undo) - 1].name, "Group Pads")
	// It plays through the group: its fader moves both.
	pm.hit(&m.engine, 0, true)
	full, _ := level(r)
	g := p.buses[b - 1]
	g.volume = -6.0206
	pm.set_bus(m, b - 1, 1, "Bus Volume", g)
	app.seal(&m.history)
	half, _ := level(r)
	testing.expectf(t, abs(half / full - 0.5) < 0.03, "through the group's fader (%v)", half / full)
	// Folded, and kept by a save.
	pm.set_group_folded(m, b, true)
	testing.expect_value(t, pm.model_save(m), fc.Error.None)
	r2 := rig_make(t, "groups_load")
	defer rig_destroy(r2)
	testing.expect_value(t, pm.model_load(&r2.m, p.dir), fc.Error.None)
	q := &r2.m.project
	testing.expect(t, q.buses[b - 1].group && q.buses[b - 1].folded)
	// Ungrouped: the pads go where the group went (main), the bus goes.
	pm.ungroup(m, b)
	testing.expect(t, p.bus_count == buses && p.pads[0].bus == 0 && p.pads[2].bus == 0)
	app.undo(&m.history)
	testing.expect(t, p.bus_count == buses + 1 && int(p.pads[0].bus) == b, "undone in one step")
	// Grouping with every bus used: no room.
	for p.bus_count < pm.BUSES do pm.add_bus(m)
	testing.expect_value(t, pm.group_pads(m, {1}), 0)
}
