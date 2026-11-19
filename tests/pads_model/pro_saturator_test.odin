package test_pads_model

import "core:testing"

import fc "fire:core"
import "fire:fx"
import pm "../../apps/pads/model"

// A ProSaturator on pad 0 drives its tone into a curve (Digital Clip: its
// third harmonic); its Quality makes a new node; kept by a save.
@(test)
a_pro_saturator_on_a_pad :: proc(t: ^testing.T) {
	r := tone_rig(t, "ps_pad")
	defer rig_destroy(r)
	m := &r.m
	s := pm.new_effect(.Pro_Saturator)
	testing.expect(t, s.count == fx.PS_PARAMS, "every parameter kept")
	pm.slot_set(&s, fx.PS_PARAM_TYPE, f32(fx.Pro_Saturator_Type.Digital_Clip))
	pm.slot_set(&s, fx.PS_PARAM_DRIVE_DB, 24)
	pm.set_insert(m, 0, 0, s, "Add Effect")
	pm.hit(&m.engine, 0, true)
	render(r, 9600)
	plain := pm.slot_pro_saturator(&m.engine, {.Pad, 0, 0})
	testing.expect(t, plain != nil, "in the graph")
	_, out, ok := pm.pro_saturator_harmonics(plain, 48_000)
	testing.expectf(t, ok && out[2] > -20, "clipped: a third harmonic (%v)", out)
	pm.slot_set(&s, fx.PS_PARAM_QUALITY, 2)
	pm.set_insert(m, 0, 0, s, "Quality")
	render(r, 4800)
	os := pm.slot_pro_saturator(&m.engine, {.Pad, 0, 0})
	testing.expect(t, os != nil && os != plain && os.settings.quality == .X4, "a new node, 4×")
	testing.expect_value(t, pm.model_save(m), fc.Error.None)
	r2 := rig_make(t, "ps_pad_load")
	defer rig_destroy(r2)
	testing.expect_value(t, pm.model_load(&r2.m, m.project.dir), fc.Error.None)
	q := r2.m.project.pads[0].inserts[0]
	testing.expect(t, q.kind == .Pro_Saturator && q.count == fx.PS_PARAMS, "the slot back")
	testing.expect_value(t, pm.slot_value(q, fx.PS_PARAM_QUALITY, 0), 2)
	testing.expect_value(t, pm.slot_value(q, fx.PS_PARAM_DRIVE_DB, 0), 24)
}
