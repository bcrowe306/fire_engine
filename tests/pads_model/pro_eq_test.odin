package test_pads_model

import "core:testing"

import fc "fire:core"
import "fire:fx"
import pm "../../apps/pads/model"

// A ProEq on pad 0 (its 1 kHz tone): a bell cut takes the tone down;
// turned up instead, up. Every parameter is kept in the slot.
@(test)
a_pro_eq_shapes_a_pad :: proc(t: ^testing.T) {
	r := tone_rig(t, "pe_pad")
	defer rig_destroy(r)
	m := &r.m
	s := pm.new_effect(.Pro_Eq)
	testing.expect(t, s.count == fx.PE_PARAMS, "every parameter kept")
	bell := fx.pro_eq_band_param(0, 3, .Freq_Hz)
	pm.slot_set(&s, bell, 1000)
	pm.slot_set(&s, fx.pro_eq_band_param(0, 3, .Gain_Db), -12)
	pm.set_insert(m, 0, 0, s, "Add Effect")
	pm.hit(&m.engine, 0, true)
	render(r, 4800)
	cut := func_amp(render(r, 9600), 1000)
	pm.slot_set(&s, fx.pro_eq_band_param(0, 3, .Gain_Db), 6)
	pm.set_insert(m, 0, 0, s, "Gain")
	render(r, 4800)
	up := func_amp(render(r, 9600), 1000)
	testing.expectf(t, up > cut * 6, "−12 dB (%v), then +6 (%v)", cut, up)
	eq := pm.slot_pro_eq(&m.engine, {.Pad, 0, 0})
	testing.expect(t, eq != nil && fx.pro_eq_readout(eq).in_peak > 0.1, "its readout")
	x: [256]f32
	fx.pro_eq_read_input(eq, x[:])
	heard := false
	for v in x do if abs(v) > 0.05 do heard = true
	testing.expect(t, heard, "its input, for the spectrum")
}

// Oversampling makes a new node (late by its oversampler); off again,
// another (on time). The sound stays.
@(test)
pro_eq_oversampling_makes_a_new_node :: proc(t: ^testing.T) {
	r := tone_rig(t, "pe_os")
	defer rig_destroy(r)
	m := &r.m
	s := pm.new_effect(.Pro_Eq)
	pm.set_insert(m, 0, 0, s, "Add Effect")
	pm.hit(&m.engine, 0, true)
	render(r, 4800)
	plain := pm.slot_pro_eq(&m.engine, {.Pad, 0, 0})
	pm.slot_set(&s, fx.PE_PARAM_OVERSAMPLE, 1)
	pm.set_insert(m, 0, 0, s, "Oversampling")
	render(r, 4800)
	os := pm.slot_pro_eq(&m.engine, {.Pad, 0, 0})
	testing.expect(t, os != nil && os != plain && os.settings.oversample, "a new node, oversampled")
	testing.expectf(t, func_amp(render(r, 9600), 1000) > 0.2, "still playing")
}

// Every setting (both sets) kept by a save; the mode's copy of A into B,
// one undo step.
@(test)
pro_eq_saved_and_its_mode :: proc(t: ^testing.T) {
	r := tone_rig(t, "pe_save")
	defer rig_destroy(r)
	m := &r.m
	s := pm.new_effect(.Pro_Eq)
	pm.slot_set(&s, fx.pro_eq_band_param(0, 2, .Gain_Db), 4.5)
	pm.slot_set(&s, fx.pro_eq_band_param(0, 0, .Slope), 4)
	pm.slot_set(&s, fx.PE_PARAM_SCALE, -0.5)
	pm.set_insert(m, 0, 0, s, "Add Effect")
	testing.expect(t, pm.pro_eq_set_mode(m, {.Pad, 0, 0}, .Left_Right), "the mode")
	q := m.project.pads[0].inserts[0]
	testing.expect_value(t, pm.slot_value(q, fx.pro_eq_band_param(1, 2, .Gain_Db), 0), 4.5)
	testing.expect_value(t, pm.slot_value(q, fx.PE_PARAM_MODE, 0), 1)
	// B, once changed, stays its own when the mode changes again.
	pm.set_insert_param(m, 0, 0, fx.pro_eq_band_param(1, 2, .Gain_Db), -3)
	pm.pro_eq_set_mode(m, {.Pad, 0, 0}, .Stereo)
	pm.pro_eq_set_mode(m, {.Pad, 0, 0}, .Mid_Side)
	q = m.project.pads[0].inserts[0]
	testing.expect_value(t, pm.slot_value(q, fx.pro_eq_band_param(1, 2, .Gain_Db), 0), -3)
	testing.expect_value(t, pm.model_save(m), fc.Error.None)
	r2 := rig_make(t, "pe_save_load")
	defer rig_destroy(r2)
	testing.expect_value(t, pm.model_load(&r2.m, m.project.dir), fc.Error.None)
	back := r2.m.project.pads[0].inserts[0]
	testing.expect(t, back.kind == .Pro_Eq && back.count == fx.PE_PARAMS, "the slot back, every parameter")
	v := pm.pro_eq_values(back)
	testing.expect(t, v == pm.pro_eq_values(q), "every value as it was")
}
