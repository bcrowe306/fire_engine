package test_pads_model

import "core:testing"

import pm "../../apps/pads/model"
import "fire:sampler"

// What a parameter's automation gives it now, for the UI to show it
// moving: while playing, from the lanes where the playhead is (a lane of
// a target, and a pad's own lane of the same thing); nothing while stopped.
@(test)
the_ui_reads_what_automation_gives_a_parameter_now :: proc(t: ^testing.T) {
	r := rig_make(t, "auto_now")
	defer rig_destroy(r)
	m := &r.m
	pm.load_onto_pad(m, 0, tone(r, "kick.wav", 440, 0.05))
	cutoff := pm.Auto_Target{track = .Pad, index = 0, device = .Sound, param = sampler.SAMPLER_PARAM_FILTER_CUTOFF, lo = 20, hi = 20_000, log = true}
	volume := pm.Auto_Target{track = .Pad, index = 0, device = .Volume}
	// The cutoff a target's lane (200 Hz to 4200 Hz over the bar); the
	// volume the pad's own (-30 dB to 0).
	pm.add_point(m, 0, {lane = {pad = 0, target = cutoff}, beat = 0, value = 200})
	pm.add_point(m, 0, {lane = {pad = 0, target = cutoff}, beat = 4, value = 4200})
	pm.add_point(m, 0, {pad = 0, param = .Volume, beat = 0, value = -30})
	pm.add_point(m, 0, {pad = 0, param = .Volume, beat = 4, value = 0})
	render(r, 256)
	_, stopped := pm.automated_value(m, cutoff)
	testing.expect(t, !stopped, "nothing while stopped")
	pm.play(&m.engine)
	render(r, 24_000) // a beat at 120 BPM
	c, cok := pm.automated_value(m, cutoff)
	v, vok := pm.automated_value(m, volume)
	testing.expectf(t, cok && abs(c - 1200) < 60, "a quarter of the way: 1200 Hz (%v)", c)
	testing.expectf(t, vok && abs(v + 22.5) < 0.6, "the pad's own lane: -22.5 dB (%v)", v)
	other := pm.Auto_Target{track = .Pad, index = 1, device = .Volume}
	_, none := pm.automated_value(m, other)
	testing.expect(t, !none, "a pad with no lane: nothing")
	pm.stop(&m.engine)
	_, after := pm.automated_value(m, cutoff)
	testing.expect(t, !after, "stopped again: nothing")
}
