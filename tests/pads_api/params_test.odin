package test_pads_api

import "core:testing"

import pa "../../apps/pads/api"
import pm "../../apps/pads/model"
import "fire:sampler"

@(test)
any_parameter_is_listed_read_and_set :: proc(t: ^testing.T) {
	r := rig_make(t, "params")
	defer rig_destroy(r)
	api := &r.api
	pa.pad_load_sample(api, 0, tone(r))
	frame(r) // (its node made)
	sound := pa.Param_Ref{track = .Pad, index = 0, device = .Sound}
	n, res := pa.param_count(api, sound)
	testing.expect(t, res == .Ok && n > 20, "a sampler's parameters")
	found := false
	for k in 0 ..< n {
		ref, _ := pa.param_at(api, sound, k)
		name, _ := pa.param_name(api, ref)
		if name == "Cutoff" do found = true
	}
	testing.expect(t, found, "Cutoff among them")
	cutoff := sound
	cutoff.param = i64(sampler.SAMPLER_PARAM_FILTER_CUTOFF)
	info, _ := pa.param_info(api, cutoff)
	testing.expect(t, info.unit == .Hertz && info.log && info.max > info.min, "a frequency")
	testing.expect_value(t, pa.param_set(api, cutoff, info.max * 2), pa.Result.Invalid_Argument)
	testing.expect_value(t, pa.param_set(api, cutoff, 1200), pa.Result.Ok)
	v, _ := pa.param_get(api, cutoff)
	testing.expect_value(t, v, 1200)
	testing.expect_value(t, r.core.m.project.pads[0].voice.cutoff, 1200)
	txt, _ := pa.param_text(api, cutoff)
	testing.expect_value(t, txt, "1.20 kHz")
	// The pad's own fields among its sound's: attack.
	attack := sound
	attack.param = i64(sampler.SAMPLER_PARAM_ATTACK)
	testing.expect_value(t, pa.param_set(api, attack, 0.05), pa.Result.Ok)
	testing.expect(t, abs(r.core.m.project.pads[0].attack - 0.05) < 1e-6, "the pad's attack")
	name, _ := pa.history_undo_name(api)
	testing.expect_value(t, name, "Set Attack") // (named after the parameter)
	// A fader, a pan, a send: fixed ranges.
	vol := pa.Param_Ref{track = .Pad, index = 0, device = .Volume}
	testing.expect_value(t, pa.param_set(api, vol, -9), pa.Result.Ok)
	testing.expect_value(t, r.core.m.project.pads[0].volume, -9)
	vn, _ := pa.param_name(api, vol)
	testing.expect_value(t, vn, "Volume")
	vt, _ := pa.param_text(api, vol)
	testing.expect_value(t, vt, "-9.0 dB")
	send := pa.Param_Ref{track = .Pad, index = 0, device = .Send, slot = 0}
	testing.expect_value(t, pa.param_set(api, send, -6), pa.Result.Ok)
	sv, _ := pa.param_get(api, send)
	testing.expect(t, abs(sv + 6) < 1e-4, "the send in dB")
	testing.expect_value(t, pa.param_set(api, {track = .Pad, index = 0, device = .Send, slot = 16}, 0), pa.Result.Not_Found)
	main_vol := pa.Param_Ref{track = .Main, device = .Volume}
	testing.expect_value(t, pa.param_set(api, main_vol, -3), pa.Result.Ok)
	testing.expect_value(t, r.core.m.project.main.volume, -3)
	bus_pan := pa.Param_Ref{track = .Bus, index = 0, device = .Pan}
	testing.expect_value(t, pa.param_set(api, bus_pan, 2), pa.Result.Invalid_Argument)
	testing.expect_value(t, pa.param_set(api, bus_pan, -0.5), pa.Result.Ok)
	bp, _ := pa.param_get(api, bus_pan)
	testing.expect_value(t, bp, -0.5)
	// Nothing there: Not_Found.
	_, res = pa.param_count(api, {track = .Pad, index = 9, device = .Sound})
	testing.expect_value(t, res, pa.Result.Not_Found)
	_, res = pa.param_get(api, {track = .Pad, index = 0, device = .Insert, slot = 0, param = 1})
	testing.expect_value(t, res, pa.Result.Not_Found)
	_, res = pa.param_get(api, {track = .Pad, index = 200, device = .Volume})
	testing.expect_value(t, res, pa.Result.Not_Found)
	// A synth's.
	pa.pad_set_kind(api, 1, .Synth)
	frame(r)
	syn := pa.Param_Ref{track = .Pad, index = 1, device = .Sound}
	sn, _ := pa.param_count(api, syn)
	testing.expect(t, sn > 20, "a synth's parameters")
	p0, _ := pa.param_at(api, syn, 0)
	i0, _ := pa.param_info(api, p0)
	mid := (i0.min + i0.max) / 2
	if i0.stepped do mid = f64(i64(mid))
	testing.expect_value(t, pa.param_set(api, p0, mid), pa.Result.Ok)
	got, _ := pa.param_get(api, p0)
	testing.expectf(t, abs(got - mid) < 1e-4, "the synth's value (%v, %v)", got, mid)
}

@(private)
Touches :: struct {
	on, off, moves: int,
	last:           f32,
}

@(test)
a_touch_is_one_step_and_reports_its_moves :: proc(t: ^testing.T) {
	r := rig_make(t, "params_touch")
	defer rig_destroy(r)
	api := &r.api
	to: Touches
	r.core.hooks = {
		user = &to,
		param_touched = proc(user: rawptr, t: pm.Auto_Target, on: bool) { x := (^Touches)(user); if on do x.on += 1; else do x.off += 1 },
		param_moved = proc(user: rawptr, t: pm.Auto_Target, value: f32) { x := (^Touches)(user); x.moves += 1; x.last = value },
	}
	vol := pa.Param_Ref{track = .Pad, index = 5, device = .Volume}
	testing.expect_value(t, pa.param_touch(api, vol, true), pa.Result.Ok)
	for db in ([]f64{-1, -2, -3, -4}) do pa.param_set(api, vol, db)
	testing.expect_value(t, pa.param_touch(api, vol, false), pa.Result.Ok)
	testing.expect(t, to.on == 1 && to.off == 1 && to.moves == 4 && to.last == -4, "touched, moved, let go")
	h, _ := pa.history_state(api)
	testing.expect_value(t, h.undo_steps, 1)
	// Untouched: moves aren't reported, each is a step.
	pa.param_set(api, vol, -5)
	testing.expect_value(t, to.moves, 4)
	h, _ = pa.history_state(api)
	testing.expect_value(t, h.undo_steps, 2)
	// Touching another lets the first go.
	pa.param_touch(api, vol, true)
	pa.param_touch(api, {track = .Main, device = .Volume}, true)
	testing.expect(t, to.on == 3 && to.off == 2, "the first let go")
	pa.param_touch(api, {track = .Main, device = .Volume}, false)
	testing.expect_value(t, pa.param_touch(api, {track = .None}, true), pa.Result.Not_Found)
}
