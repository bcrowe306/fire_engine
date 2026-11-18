package test_pads_model

import "core:testing"

import fc "fire:core"
import "fire:fx"
import pm "../../apps/pads/model"

// A SuperFilter low-pass on pad 0 (1 kHz): it cuts the tone at 200 Hz and
// passes it at 20 kHz.
@(test)
a_super_filter_filters_a_pad :: proc(t: ^testing.T) {
	r := tone_rig(t, "sf_pad")
	defer rig_destroy(r)
	m := &r.m
	s := pm.new_effect(.Super_Filter)
	testing.expect(t, s.count == fx.SF_PARAMS, "every parameter kept")
	pm.slot_set(&s, fx.SF_PARAM_FREQ_HZ, 200)
	pm.slot_set(&s, fx.SF_PARAM_LFO_AMOUNT, 0)
	pm.set_insert(m, 0, 0, s, "Add Effect")
	pm.hit(&m.engine, 0, true)
	cut := func_amp(render(r, 9600), 1000)
	pm.slot_set(&s, fx.SF_PARAM_FREQ_HZ, 20_000)
	pm.set_insert(m, 0, 0, s, "Freq")
	open := func_amp(render(r, 9600), 1000)
	testing.expectf(t, cut < open * 0.1 && open > 0.2, "cut at 200 Hz (%v), open at 20 kHz (%v)", cut, open)
	x, ok := pm.slot_super_filter(&m.engine, {.Pad, 0, 0})
	testing.expectf(t, ok && abs(x.cutoff_hz[0] - 20_000) < 100 && x.in_peak > 0.4, "its readout (%v)", x)
	// Off, the pad plays as it was (the dry delayed with it: no comb as it fades).
	s.on = false
	pm.set_insert(m, 0, 0, s, "Off")
	render(r, 4800)
	testing.expectf(t, func_amp(render(r, 9600), 1000) > open * 0.95, "off")
}

// Keyed from nothing, a SuperFilter follows its own input through the
// key's filters: a high cut under the tone turns the envelope down.
// Listening, the strip plays that key.
@(test)
a_super_filter_keys_from_itself :: proc(t: ^testing.T) {
	r := tone_rig(t, "sf_own_key")
	defer rig_destroy(r)
	m := &r.m
	s := pm.new_effect(.Super_Filter)
	pm.slot_set(&s, fx.SF_PARAM_FREQ_HZ, 200)
	pm.slot_set(&s, fx.SF_PARAM_LFO_AMOUNT, 0)
	pm.slot_set(&s, fx.SF_PARAM_ENV_AMOUNT, 0.5)
	pm.set_insert(m, 0, 0, s, "Add Effect")
	pm.hit(&m.engine, 0, true)
	render(r, 9600)
	full, _ := pm.slot_super_filter(&m.engine, {.Pad, 0, 0})
	s.key_lpf = 250
	pm.set_insert(m, 0, 0, s, "Key High Cut")
	render(r, 48_000) // (the envelope's release, 250 ms, falling 24 dB)
	low, _ := pm.slot_super_filter(&m.engine, {.Pad, 0, 0})
	testing.expectf(t, full.env > 0.8 && full.cutoff_hz[0] > 600, "its own input opens it (%v)", full)
	testing.expectf(t, low.env < full.env - 0.2 && low.cutoff_hz[0] < full.cutoff_hz[0] * 0.7, "less through the high cut (%v, from %v)", low, full)
	// Listening: the strip plays the key, the tone through the high cut.
	s.listen = true
	pm.set_insert(m, 0, 0, s, "Listen")
	render(r, 4800)
	heard := func_amp(render(r, 9600), 1000)
	testing.expectf(t, heard > 0.005 && heard < 0.1, "listening to the key, filtered (%v)", heard)
	// Kept by a save (the high cut from version 40).
	testing.expect_value(t, pm.model_save(m), fc.Error.None)
	r2 := rig_make(t, "sf_own_key_load")
	defer rig_destroy(r2)
	testing.expect_value(t, pm.model_load(&r2.m, m.project.dir), fc.Error.None)
	q := r2.m.project.pads[0].inserts[0]
	testing.expect(t, q.kind == .Super_Filter && q.key_lpf == 250 && q.listen && q.key.kind == .None, "the slot back")
	testing.expect_value(t, pm.slot_value(q, fx.SF_PARAM_ENV_AMOUNT, 0), 0.5)
}

// Keyed from pad 1, a SuperFilter's envelope follows pad 1, not its own
// pad; on a bus too.
@(test)
a_super_filter_keyed_from_another_pad :: proc(t: ^testing.T) {
	r := tone_rig(t, "sf_key")
	defer rig_destroy(r)
	m := &r.m
	pm.load_onto_pad(m, 1, tone(r, "key.wav", 200, 4))
	s := pm.new_effect(.Super_Filter)
	pm.slot_set(&s, fx.SF_PARAM_LFO_AMOUNT, 0)
	pm.slot_set(&s, fx.SF_PARAM_ENV_AMOUNT, 0.5)
	s.key = {.Pad, 1}
	pm.set_insert(m, 0, 0, s, "Add Effect")
	pm.set_target_slot(m, {.Bus, pm.BUSES, 0}, s, "Add Effect")
	pm.hit(&m.engine, 0, true)
	render(r, 9600)
	quiet, _ := pm.slot_super_filter(&m.engine, {.Pad, 0, 0})
	testing.expectf(t, quiet.env < 0.05, "the key silent (%v)", quiet.env)
	pm.hit(&m.engine, 1, true)
	render(r, 9600)
	keyed, _ := pm.slot_super_filter(&m.engine, {.Pad, 0, 0})
	testing.expectf(t, keyed.env > 0.8, "the key playing (%v)", keyed.env)
	main, ok := pm.slot_super_filter(&m.engine, {.Bus, pm.BUSES, 0})
	testing.expectf(t, ok && main.env > 0.8, "on main too (%v)", main.env)
}

// Every factory preset plays: a tone through it comes out finite, under
// full scale (Clip), and not silent.
@(test)
every_effect_preset_plays :: proc(t: ^testing.T) {
	r := rig_make(t, "sf_presets")
	defer rig_destroy(r)
	m := &r.m
	pm.load_onto_pad(m, 0, tone(r, "long.wav", 200, 12)) // (struck once: long enough for them all; low, under every low-pass)
	render(r, 256)
	pm.hit(&m.engine, 0, true)
	for p in pm.EFFECT_PRESETS {
		pm.set_insert(m, 0, 0, pm.effect_preset_slot(p), "Load Preset")
		render(r, 4800)
		out := render(r, 24_000)
		peak: f32 = 0
		finite := true
		for x in out[0] {
			if x != x || abs(x) > 1e6 do finite = false
			peak = max(peak, abs(x))
		}
		testing.expectf(t, finite && peak <= 1.0001 && peak > 0.01, "%s: finite, under full scale, heard (peak %v)", p.name, peak)
	}
}

