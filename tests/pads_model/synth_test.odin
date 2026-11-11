package test_pads_model

import "core:testing"

import app "app:core"
import fc "fire:core"
import "fire:synth"
import kit "fire:testkit"
import pm "../../apps/pads/model"

// A synth pad: a pad hit plays C3 (a saw at 261.6 Hz); the keyboard plays
// its pitches; a sequenced note's pitch picks the key; a route moves it.
@(test)
a_synth_pad_plays_chromatically :: proc(t: ^testing.T) {
	r := rig_make(t, "synth_play")
	defer rig_destroy(r)
	m := &r.m
	pm.make_synth(m, 0)
	testing.expect(t, m.project.pads[0].kind == .Synth && m.project.pads[0].synth.set, "a synth")
	testing.expect_value(t, pm.pad_name(&m.project.pads[0]), "Synth")
	pm.set_synth_value(m, 0, synth.filter_param(1, .On), 0, "Filter")
	pm.set_synth_value(m, 0, synth.osc_param(1, .Random_Phase), 0, "Phase")
	render(r, 256)
	pm.hit(&m.engine, 0, true, 1)
	out := render(r, 24_000)
	hz := kit.tone_amplitude(out[0][4800:], SR, 261.63)
	testing.expectf(t, hz > 0.05, "a pad hit: C3 (%v)", hz)
	lv, _ := pm.synth_live(&m.engine, 0)
	testing.expectf(t, lv.voices == 1, "one voice for a pad hit (%d)", lv.voices)
	pm.hit(&m.engine, 0, false, 0)
	render(r, 48_000)
	pm.hit(&m.engine, 0, true, 1, 12, keyboard = true)
	out = render(r, 24_000)
	lv, _ = pm.synth_live(&m.engine, 0)
	testing.expectf(t, lv.voices == 1, "one voice for a key (%d)", lv.voices)
	testing.expectf(t, kit.tone_amplitude(out[0][4800:], SR, 523.25) > 0.05, "the keyboard, up an octave: C4 (%v)", kit.tone_amplitude(out[0][4800:], SR, 523.25))
	pm.hit(&m.engine, 0, false, 0, 12, keyboard = true)
	render(r, 48_000)
	live, ok := pm.synth_live(&m.engine, 0)
	testing.expect(t, ok && !live.sounding, "silent once released")
}

// Routes add, change and go (undoably); the patch saves and loads whole.
@(test)
a_synth_patch_saves_and_undoes :: proc(t: ^testing.T) {
	r := rig_make(t, "synth_save")
	defer rig_destroy(r)
	m := &r.m
	pm.make_synth(m, 3)
	pm.set_synth_value(m, 3, synth.osc_param(1, .Unison), 7, "Unison")
	pm.set_synth_value(m, 3, synth.filter_param(1, .Model), f32(synth.Filter_Model.Ladder), "Model")
	k := pm.add_synth_route(m, 3, {source = .Lfo_2, dest = synth.filter_param(1, .Cutoff), amount = 0.3, bipolar = true})
	testing.expect_value(t, k, 0)
	testing.expect_value(t, pm.add_synth_route(m, 3, {source = .Lfo_2, dest = synth.filter_param(1, .Cutoff), amount = 0.5}), 0) // (the same pair: changed, not added)
	pm.add_synth_route(m, 3, {source = .Macro_1, dest = synth.osc_param(1, .Frame), amount = 1})
	testing.expect_value(t, m.project.pads[3].synth.route_count, 2)
	testing.expect_value(t, len(pm.synth_routes_to(m, 3, synth.filter_param(1, .Cutoff))), 1)
	sh := synth.lfo_preset(.Square)
	pm.set_synth_shape(m, 3, 1, sh)
	pm.set_synth_table(m, 3, 1, {builtin = u8(synth.Builtin_Table.Vowels)})
	pm.set_synth_macro_name(m, 3, 0, "Brightness")
	testing.expect_value(t, pm.synth_macro_name(m, 3, 0), "Brightness")
	pm.remove_synth_route(m, 3, 0)
	testing.expect_value(t, m.project.pads[3].synth.route_count, 1)
	app.undo(&m.history)
	testing.expect_value(t, m.project.pads[3].synth.route_count, 2)

	testing.expect_value(t, pm.model_save(m), fc.Error.None)
	before := m.project.pads[3]
	r2 := rig_make(t, "synth_load")
	defer rig_destroy(r2)
	testing.expect_value(t, pm.model_load(&r2.m, m.project.dir), fc.Error.None)
	after := r2.m.project.pads[3]
	testing.expect(t, after.kind == .Synth, "still a synth")
	testing.expect(t, after.synth == before.synth, "its patch whole")
	testing.expect(t, r2.m.project.pads[0].synth.set == false, "a pad that never was a synth has none")
	render(r2, 512)
}
