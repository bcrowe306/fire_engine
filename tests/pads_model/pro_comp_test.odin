package test_pads_model

import "core:testing"

import fc "fire:core"
import "fire:fx"
import pm "../../apps/pads/model"

// A ProComp on pad 0 turns its tone down; keyed from pad 1 (silent, then
// playing), it presses only while pad 1 plays; its Listen plays what it
// hears. A lookahead makes a new node. Kept by a save.
@(test)
a_pro_comp_on_a_pad :: proc(t: ^testing.T) {
	r := tone_rig(t, "pc_pad")
	defer rig_destroy(r)
	m := &r.m
	pm.load_onto_pad(m, 1, tone(r, "key.wav", 200, 4))
	s := pm.new_effect(.Pro_Comp)
	testing.expect(t, s.count == fx.PC_PARAMS, "every parameter kept")
	pm.slot_set(&s, fx.PC_PARAM_THRESHOLD_DB, -40)
	pm.slot_set(&s, fx.PC_PARAM_RATIO, 100)
	pm.set_insert(m, 0, 0, s, "Add Effect")
	pm.hit(&m.engine, 0, true)
	render(r, 4800)
	squeezed := func_amp(render(r, 9600), 1000)
	s.on = false
	pm.set_insert(m, 0, 0, s, "Off")
	render(r, 4800)
	open := func_amp(render(r, 9600), 1000)
	testing.expectf(t, squeezed < open * 0.3, "turned down (%v of %v)", squeezed, open)
	// Keyed from pad 1: quiet until it plays.
	s.on = true
	s.key = {.Pad, 1}
	pm.slot_set(&s, fx.PC_PARAM_THRESHOLD_DB, -20)
	pm.set_insert(m, 0, 0, s, "Sidechain")
	render(r, 9600)
	before := pm.slot_pro_comp(&m.engine, {.Pad, 0, 0})
	testing.expect(t, before != nil && fx.pro_comp_readout(before).gr_db > -1, "the key silent: no reduction")
	pm.hit(&m.engine, 1, true)
	render(r, 9600)
	testing.expectf(t, fx.pro_comp_readout(before).gr_db < -6, "the key playing (%v)", fx.pro_comp_readout(before))
	// Looking ahead: a new node.
	pm.slot_set(&s, fx.PC_PARAM_LOOKAHEAD, 2)
	pm.set_insert(m, 0, 0, s, "Lookahead")
	render(r, 4800)
	after := pm.slot_pro_comp(&m.engine, {.Pad, 0, 0})
	testing.expect(t, after != nil && after != before && after.settings.lookahead == .Ms_10, "a new node, 10 ms ahead")
	// Saved.
	s.listen = true
	pm.set_insert(m, 0, 0, s, "Listen")
	testing.expect_value(t, pm.model_save(m), fc.Error.None)
	r2 := rig_make(t, "pc_pad_load")
	defer rig_destroy(r2)
	testing.expect_value(t, pm.model_load(&r2.m, m.project.dir), fc.Error.None)
	q := r2.m.project.pads[0].inserts[0]
	testing.expect(t, q.kind == .Pro_Comp && q.listen && q.key.kind == .Pad && q.count == fx.PC_PARAMS, "the slot back")
	testing.expect_value(t, pm.slot_value(q, fx.PC_PARAM_LOOKAHEAD, 0), 2)
}
