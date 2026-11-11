package test_pads_model

import "core:testing"

import app "app:core"
import fc "fire:core"
import "fire:dsp"
import kit "fire:testkit"
import pm "../../apps/pads/model"

// Pad 0 (1 kHz) through a gate keyed from pad 1 (200 Hz): closed while
// pad 1 is silent, open while it plays; listening, pad 0's strip plays
// the key instead.
@(test)
a_gate_keyed_from_another_pad :: proc(t: ^testing.T) {
	r := tone_rig(t, "sidechain_gate")
	defer rig_destroy(r)
	m := &r.m
	pm.load_onto_pad(m, 1, tone(r, "key.wav", 200, 4))
	s := pm.new_effect(.Gate)
	pm.slot_set(&s, dsp.GATE_PARAM_THRESHOLD_DB, -30)
	pm.slot_set(&s, dsp.GATE_PARAM_RANGE_DB, 80)
	s.key = {.Pad, 1}
	pm.set_insert(m, 0, 0, s, "Add Effect")
	pm.hit(&m.engine, 0, true)
	k1 := func_amp(render(r, 9600), 1000)
	testing.expectf(t, k1 < 0.01, "the key silent: closed (%v)", k1)
	pm.hit(&m.engine, 1, true)
	out := render(r, 9600)
	k2, key := func_amp(out, 1000), func_amp(out, 200)
	testing.expectf(t, k2 > 0.2 && key > 0.2, "the key playing: open (%v, the key %v)", k2, key)
	// Listening: pad 0's strip plays the key (so 200 Hz twice, no 1 kHz).
	s.listen = true
	pm.set_insert(m, 0, 0, s, "Listen")
	out = render(r, 9600)
	testing.expectf(t, func_amp(out, 1000) < 0.01 && func_amp(out, 200) > key * 1.5, "listening (%v, %v)", func_amp(out, 1000), func_amp(out, 200))
	// Kept by a save.
	s.listen, s.key_hpf = false, 120
	pm.set_insert(m, 0, 0, s, "Key Filter")
	testing.expect_value(t, pm.model_save(m), fc.Error.None)
	r2 := rig_make(t, "sidechain_gate_load")
	defer rig_destroy(r2)
	testing.expect_value(t, pm.model_load(&r2.m, m.project.dir), fc.Error.None)
	q := r2.m.project.pads[0].inserts[0]
	testing.expect(t, q.key == pm.Key_Source{.Pad, 1} && q.key_hpf == 120 && !q.listen)
	_ = app.seal
}

// The 1 kHz (or `hz`) part of the left output, over its second half.
@(private)
func_amp :: proc(out: [2][]f32, hz: f64) -> f64 {
	x := out[0]
	return kit.tone_amplitude(x[len(x) / 2:], 48_000, hz)
}

@(test)
keys_that_would_loop_are_refused :: proc(t: ^testing.T) {
	r := rig_make(t, "sidechain_loops")
	defer rig_destroy(r)
	m := &r.m
	p := &m.project
	pm.set_pad_bus(m, 0, 1) // pad 0 into bus A
	testing.expect(t, !pm.key_allowed(p, {.Pad, 0, 0}, {.Pad, 0}), "its own output")
	testing.expect(t, pm.key_allowed(p, {.Pad, 0, 0}, {.Pad, 3}), "another pad's")
	testing.expect(t, !pm.key_allowed(p, {.Pad, 0, 0}, {.Bus, 0}), "the bus it goes to")
	testing.expect(t, pm.key_allowed(p, {.Pad, 2, 0}, {.Bus, 0}), "a bus it doesn't feed")
	testing.expect(t, !pm.key_allowed(p, {.Bus, 0, 0}, {.Bus, 0}), "a bus keyed from itself")
	testing.expect(t, pm.key_allowed(p, {.Bus, pm.BUSES, 0}, {.Bus, 0}), "main keyed from a bus")
	// A send makes a way through too.
	pm.set_send_db(m, 2, 1, -6)
	app.seal(&m.history)
	testing.expect(t, !pm.key_allowed(p, {.Pad, 2, 0}, {.Bus, 0}), "a bus it sends to")
}
