package test_pads_model

import "core:math"
import "core:testing"
import "core:time"

import app "app:core"
import fc "fire:core"
import "fire:fx"
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
	pm.set_synth_value(m, 3, synth.filter_param(1, .Model), f32(fx.Filter_Model.Ladder), "Model")
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

// An armed synth taking any MIDI plays MIDI keys chromatically (not the
// drum map); pitch bend moves it by its bend range (2 semitones).
@(test)
midi_plays_and_bends_an_armed_synth :: proc(t: ^testing.T) {
	r := rig_make(t, "synth_midi")
	defer rig_destroy(r)
	m := &r.m
	pm.make_synth(m, 0)
	pm.set_synth_value(m, 0, synth.filter_param(1, .On), 0, "Filter")
	pm.arm_track(m, 0, true)
	render(r, 256)
	app.host_midi_inject(&r.host, {0x90, 69, 110}) // A4
	out := render(r, 24_000)
	testing.expectf(t, kit.tone_amplitude(out[0][4800:], SR, 440) > 0.05, "A4 at 440 Hz (%v)", kit.tone_amplitude(out[0][4800:], SR, 440))
	app.host_midi_inject(&r.host, {0xE0, 0x7F, 0x7F}) // bend fully up
	out = render(r, 24_000)
	up := 440 * math.pow(2, 2.0 / 12)
	testing.expectf(t, kit.tone_amplitude(out[0][4800:], SR, up) > 0.05 && kit.tone_amplitude(out[0][4800:], SR, 440) < 0.01, "bent up 2 semitones (%v)", kit.tone_amplitude(out[0][4800:], SR, up))
	app.host_midi_inject(&r.host, {0x80, 69, 0})
	render(r, 48_000)
}

// A Cutoff lane on a synth pad moves its filter 1's cutoff (as a key) as
// the sequence plays.
@(test)
a_cutoff_lane_moves_a_synths_filter :: proc(t: ^testing.T) {
	r := rig_make(t, "synth_lane")
	defer rig_destroy(r)
	m := &r.m
	pm.make_synth(m, 0)
	pm.add_point(m, 0, {pad = 0, param = .Cutoff, beat = 0, value = 200})
	pm.add_point(m, 0, {pad = 0, param = .Cutoff, beat = 4, value = 3200})
	pm.play(&m.engine)
	render(r, 24_000) // half a second at 120 BPM: a beat in
	key := r.m.engine.nodes[0].synth.values[synth.filter_param(1, .Cutoff)]
	lo := f32(69 + 12 * math.log2(200.0 / 440))
	hi := f32(69 + 12 * math.log2(3200.0 / 440))
	testing.expectf(t, key > lo + 2 && key < hi - 2, "between the points' keys (%v in %v..%v)", key, lo, hi)
}

// A sequenced note on a synth plays its pitch (as a keyboard-recorded
// note has): pitch 7 is G3.
@(test)
a_sequenced_note_plays_its_pitch_on_a_synth :: proc(t: ^testing.T) {
	r := rig_make(t, "synth_seq")
	defer rig_destroy(r)
	m := &r.m
	pm.make_synth(m, 0)
	pm.set_synth_value(m, 0, synth.filter_param(1, .On), 0, "Filter")
	pm.add_note(m, 0, {start = 0, length = 2, pad = 0, pitch = 7, velocity = 0.9, probability = 1})
	pm.play(&m.engine)
	out := render(r, 24_000)
	g3 := 261.63 * math.pow(2, 7.0 / 12)
	testing.expectf(t, kit.tone_amplitude(out[0][4800:], SR, g3) > 0.05 && kit.tone_amplitude(out[0][4800:], SR, 261.63) < 0.01, "G3 (%v), not C3 (%v)", kit.tone_amplitude(out[0][4800:], SR, g3), kit.tone_amplitude(out[0][4800:], SR, 261.63))
}

// The piano roll's pitch on a sampler pad: an octave up plays it twice as
// fast (its own 440 Hz at 880).
@(test)
a_sequenced_pitch_plays_on_a_sampler :: proc(t: ^testing.T) {
	r := rig_make(t, "sampler_seq_pitch")
	defer rig_destroy(r)
	m := &r.m
	testing.expect_value(t, pm.load_onto_pad(m, 0, tone(r, "a.wav", 440, 1)), fc.Error.None)
	pm.add_note(m, 0, {start = 0, length = 1, pad = 0, pitch = 12, velocity = 0.9, probability = 1})
	pm.play(&m.engine)
	out := render(r, 12_000)
	testing.expectf(t, kit.tone_amplitude(out[0][2400:], SR, 880) > 4 * kit.tone_amplitude(out[0][2400:], SR, 440), "an octave up (880 %v, 440 %v)", kit.tone_amplitude(out[0][2400:], SR, 880), kit.tone_amplitude(out[0][2400:], SR, 440))
}

// A synth's effects: reordered (saved, undone), and on, they reach its
// node: the reverb rings on after the note.
@(test)
a_synths_effects_reorder_and_sound :: proc(t: ^testing.T) {
	r := rig_make(t, "synth_fx")
	defer rig_destroy(r)
	m := &r.m
	pm.make_synth(m, 0)
	pm.move_synth_effect(m, 0, .Reverb, 0)
	testing.expect_value(t, m.project.pads[0].synth.fx_order[0], fx.Effect.Reverb)
	testing.expect_value(t, m.project.pads[0].synth.fx_order[1], fx.Effect.Chorus)
	testing.expect_value(t, app.undo_name(&m.history), "Reorder Effects")
	pm.move_synth_effect(m, 0, .Chorus, 8)
	testing.expect_value(t, m.project.pads[0].synth.fx_order[8], fx.Effect.Chorus)
	testing.expect_value(t, m.project.pads[0].synth.fx_order[7], fx.Effect.Phaser)
	app.undo(&m.history)
	testing.expect_value(t, m.project.pads[0].synth.fx_order[1], fx.Effect.Chorus)
	testing.expect(t, fx.chain_order_valid(m.project.pads[0].synth.fx_order), "each effect once")

	pm.set_synth_value(m, 0, synth.filter_param(1, .On), 0, "Filter")
	pm.set_synth_value(m, 0, synth.effect_param(.Reverb, synth.Reverb_Field.On), 1, "Reverb")
	pm.set_synth_value(m, 0, synth.effect_param(.Reverb, synth.Reverb_Field.Wet), 0.6, "Reverb Mix")
	pm.set_synth_value(m, 0, synth.effect_param(.Reverb, synth.Reverb_Field.Decay), 2, "Reverb Decay") // 4 s
	render(r, 256)
	testing.expect_value(t, r.m.engine.nodes[0].synth.patch.fx_order[0], fx.Effect.Reverb)
	pm.hit(&m.engine, 0, true, 1)
	render(r, 4800)
	pm.hit(&m.engine, 0, false, 0)
	out := render(r, 48_000)
	testing.expectf(t, kit.rms(out[0][24_000:]) > 1e-3, "a tail half a second after the release (%v)", kit.rms(out[0][24_000:]))

	testing.expect_value(t, pm.model_save(m), fc.Error.None)
	r2 := rig_make(t, "synth_fx_load")
	defer rig_destroy(r2)
	testing.expect_value(t, pm.model_load(&r2.m, m.project.dir), fc.Error.None)
	testing.expect(t, r2.m.project.pads[0].synth == m.project.pads[0].synth, "the order and effects saved")
}

// A wavetable of the project's own: made for an oscillator, it plays
// (a sine at frame 0); an edit (its first keyframe a saw's harmonics)
// reaches the sound; undone, it is a sine again; saved and loaded whole.
@(test)
a_projects_wavetable_plays_and_saves :: proc(t: ^testing.T) {
	r := rig_make(t, "synth_wave_doc")
	defer rig_destroy(r)
	m := &r.m
	pm.make_synth(m, 0)
	pm.set_synth_value(m, 0, synth.filter_param(1, .On), 0, "Filter")
	pm.set_synth_value(m, 0, synth.osc_param(1, .Random_Phase), 0, "Phase")
	id := pm.new_wave_doc(m, 0, 0)
	testing.expect(t, id != 0 && m.project.pads[0].synth.tables[0].table == id, "the oscillator plays it")
	testing.expect_value(t, pm.synth_source_name(m, m.project.pads[0].synth.tables[0]), "Wavetable")
	render(r, 256)
	harmonic2 :: proc(r: ^Rig) -> f64 {
		pm.hit(&r.m.engine, 0, true, 1)
		out := render(r, 9_600)
		pm.hit(&r.m.engine, 0, false, 0)
		render(r, 24_000)
		return kit.tone_amplitude(out[0][4800:], SR, 523.25) / max(kit.tone_amplitude(out[0][4800:], SR, 261.63), 1e-9)
	}
	testing.expectf(t, harmonic2(r) < 0.05, "a sine at frame 0 (%v)", harmonic2(r))
	d := app.store_get(&m.project.wave_docs, id)^
	for h in 0 ..< synth.TABLE_HARMONICS do d.doc.keys[0].levels[h] = 1 / f32(h + 1)
	pm.set_wave_doc(m, id, d, "Harmonic Level")
	app.seal(&m.history)
	time.sleep(100 * time.Millisecond) // (rebuilt no sooner than 80 ms after the last)
	render(r, 256)
	testing.expectf(t, abs(harmonic2(r) - 0.5) < 0.1, "edited: a saw (%v)", harmonic2(r))
	app.undo(&m.history)
	time.sleep(100 * time.Millisecond)
	render(r, 256)
	testing.expectf(t, harmonic2(r) < 0.05, "undone: a sine again")
	app.redo(&m.history)

	testing.expect_value(t, pm.model_save(m), fc.Error.None)
	r2 := rig_make(t, "synth_wave_doc_load")
	defer rig_destroy(r2)
	testing.expect_value(t, pm.model_load(&r2.m, m.project.dir), fc.Error.None)
	got := app.store_get(&r2.m.project.wave_docs, id)
	testing.expect(t, got != nil && got.doc == app.store_get(&m.project.wave_docs, id).doc, "the table saved whole")
	testing.expect_value(t, r2.m.project.pads[0].synth.tables[0].table, id)
}
