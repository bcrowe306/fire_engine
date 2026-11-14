package test_pads_api

import "core:os"
import "core:path/filepath"
import "core:testing"

import pa "../../apps/pads/api"
import pm "../../apps/pads/model"

@(private)
kind_of :: proc(api: ^pa.Api, name: string) -> i64 {
	n, _ := pa.effect_kind_count(api)
	for k in 0 ..< n {
		x, _ := pa.effect_kind_name(api, k)
		if x == name do return k
	}
	return -1
}

@(test)
effects_are_put_in_slots_switched_moved_and_set :: proc(t: ^testing.T) {
	r := rig_make(t, "effects")
	defer rig_destroy(r)
	api := &r.api
	pa.pad_load_sample(api, 0, tone(r))
	reverb, delay := kind_of(api, "Reverb"), kind_of(api, "Delay")
	testing.expect(t, reverb > 0 && delay > 0, "kinds by name")
	empty, _ := pa.effect_kind_name(api, 0)
	testing.expect_value(t, empty, "Empty")
	_, res := pa.effect_kind_name(api, 99)
	testing.expect_value(t, res, pa.Result.Not_Found)
	ins0 := pa.Slot_Ref{place = .Insert, index = 0, slot = 0}
	ins1 := pa.Slot_Ref{place = .Insert, index = 0, slot = 1}
	testing.expect_value(t, pa.effect_set(api, ins0, reverb), pa.Result.Ok)
	n, _ := pa.history_undo_name(api)
	testing.expect_value(t, n, "Add Effect")
	testing.expect_value(t, pa.effect_set(api, ins1, delay), pa.Result.Ok)
	st, _ := pa.effect_state(api, ins0)
	testing.expect(t, st.kind == reverb && st.on && !st.plugin, "a reverb, on")
	nm, _ := pa.effect_name(api, ins0)
	testing.expect_value(t, nm, "Reverb")
	// Bypassed, then on again.
	testing.expect_value(t, pa.effect_set_on(api, ins0, false), pa.Result.Ok)
	st, _ = pa.effect_state(api, ins0)
	testing.expect(t, !st.on, "bypassed")
	pa.effect_set_on(api, ins0, true)
	// Their order: swapped.
	testing.expect_value(t, pa.effect_swap(api, ins0, ins1), pa.Result.Ok)
	st, _ = pa.effect_state(api, ins0)
	testing.expect_value(t, st.kind, delay)
	testing.expect_value(t, pa.effect_swap(api, ins0, {place = .Bus, index = 0, slot = 0}), pa.Result.Invalid_Argument)
	// A parameter, by the effect's id; and the same through params.
	ps := pm.effect_params(pm.Effect_Kind(delay))
	p := ps[0]
	mid := (p.min + p.max) / 2
	testing.expect_value(t, pa.effect_set_param(api, ins0, i64(p.id), mid), pa.Result.Ok)
	got, _ := pa.effect_get_param(api, ins0, i64(p.id))
	testing.expect(t, abs(got - mid) < 1e-3, "set")
	testing.expect_value(t, pa.effect_set_param(api, ins0, i64(p.id), p.max + 1), pa.Result.Invalid_Argument)
	testing.expect_value(t, pa.effect_set_param(api, ins0, 9999, 0), pa.Result.Not_Found)
	pv, _ := pa.param_get(api, {track = .Pad, index = 0, device = .Insert, slot = 0, param = i64(p.id)})
	testing.expect(t, abs(pv - mid) < 1e-3, "the same through params")
	// Main's and a bus's slots; out of range.
	testing.expect_value(t, pa.effect_set(api, {place = .Main, slot = 4}, reverb), pa.Result.Ok)
	testing.expect_value(t, pa.effect_set(api, {place = .Main, slot = 5}, reverb), pa.Result.Not_Found)
	testing.expect_value(t, pa.effect_set(api, {place = .Insert, index = 0, slot = 4}, reverb), pa.Result.Not_Found)
	testing.expect_value(t, pa.effect_set(api, ins1, kind_of(api, "Plug-in")), pa.Result.Unsupported)
	// Cleared.
	testing.expect_value(t, pa.effect_clear(api, ins1), pa.Result.Ok)
	st, _ = pa.effect_state(api, ins1)
	testing.expect_value(t, st.kind, 0)
	testing.expect_value(t, pa.effect_set_on(api, ins1, true), pa.Result.Not_Found)
	// A plug-in is a library's: its slot says so (it needn't load here).
	testing.expect_value(t, pa.effect_set_plugin(api, ins1, "", "", ""), pa.Result.Invalid_Argument)
	testing.expect_value(t, pa.effect_set_plugin(api, ins1, "/no/such.clap", "com.example.fx", "Example"), pa.Result.Ok)
	st, _ = pa.effect_state(api, ins1)
	testing.expect(t, st.plugin, "a plug-in")
	nm, _ = pa.effect_name(api, ins1)
	testing.expect_value(t, nm, "Example")
}

@(test)
performance_effects_sends_and_sidechains :: proc(t: ^testing.T) {
	r := rig_make(t, "effects_perf")
	defer rig_destroy(r)
	api := &r.api
	pa.pad_load_sample(api, 0, tone(r))
	pa.pad_load_sample(api, 1, tone(r, "b.wav"))
	perf := pa.Slot_Ref{place = .Perf, index = 2}
	testing.expect_value(t, pa.effect_set(api, perf, kind_of(api, "Stutter")), pa.Result.Ok)
	st, _ := pa.effect_state(api, perf)
	testing.expect(t, !st.on, "off until held")
	testing.expect_value(t, pa.effect_clear(api, perf), pa.Result.Unsupported)
	testing.expect_value(t, pa.effect_hold(api, 2, true, 0.5), pa.Result.Ok)
	st, _ = pa.effect_state(api, perf)
	testing.expect(t, st.on, "held")
	testing.expect_value(t, pa.effect_hold(api, 2, false), pa.Result.Ok)
	testing.expect_value(t, pa.effect_hold(api, 16, true), pa.Result.Not_Found)
	testing.expect_value(t, pa.effect_hold(api, 2, true, 3), pa.Result.Invalid_Argument)
	testing.expect_value(t, pa.effect_set_intensity(api, 2, 0.25), pa.Result.Ok)
	testing.expect_value(t, r.core.m.project.perf_intensity[2], 0.25)
	n, _ := pa.history_undo_name(api)
	testing.expect_value(t, n, "Effect Intensity")
	// A send before the fader.
	testing.expect_value(t, pa.effect_set_send_pre(api, 0, 0, true), pa.Result.Ok)
	testing.expect(t, r.core.m.project.pads[0].sends[0].pre, "pre-fader")
	testing.expect_value(t, pa.effect_set_send_pre(api, 0, 16, true), pa.Result.Not_Found)
	// A compressor keyed from pad 1.
	comp := pa.Slot_Ref{place = .Insert, index = 0, slot = 0}
	pa.effect_set(api, comp, kind_of(api, "Compressor"))
	testing.expect_value(t, pa.effect_set_key(api, comp, .Pad, 0), pa.Result.Invalid_Argument) // (itself)
	testing.expect_value(t, pa.effect_set_key(api, comp, .Pad, 1), pa.Result.Ok)
	testing.expect_value(t, pa.effect_set_key_filter(api, comp, 120), pa.Result.Ok)
	testing.expect_value(t, pa.effect_set_key_filter(api, comp, 5000), pa.Result.Invalid_Argument)
	testing.expect_value(t, pa.effect_set_key_listen(api, comp, true), pa.Result.Ok)
	k, _ := pa.effect_key(api, comp)
	testing.expect(t, k.kind == .Pad && k.index == 1 && k.hpf_hz == 120 && k.listen, "keyed")
	pa.effect_set_key(api, comp, .None, 0)
	k, _ = pa.effect_key(api, comp)
	testing.expect(t, k.kind == .None && !k.listen, "itself again, not listening")
}

@(test)
devices_presets_and_plugins :: proc(t: ^testing.T) {
	r := rig_make(t, "devices")
	defer rig_destroy(r)
	api := &r.api
	n, _ := pa.device_preset_count(api)
	testing.expect(t, n > 0, "built-in presets")
	name, _ := pa.device_preset_name(api, 0)
	cat, _ := pa.device_preset_category(api, 0)
	testing.expect(t, name != "" && cat != "", "named, with a kind")
	_, res := pa.device_preset_name(api, n)
	testing.expect_value(t, res, pa.Result.Not_Found)
	testing.expect_value(t, pa.device_load_preset(api, 3, 0), pa.Result.Ok)
	s, _ := pa.pad_state(api, 3)
	testing.expect_value(t, s.kind, pa.Pad_Kind.Synth)
	of, _ := pa.device_preset_of(api, 3)
	testing.expect_value(t, of, name)
	// Saved and loaded again onto another pad.
	dir, _ := filepath.join({r.dir, "Presets"}, context.temp_allocator)
	path, sr := pa.device_save_preset(api, 3, dir, "Mine")
	testing.expect(t, sr == .Ok && os.exists(path), "saved")
	_, sr = pa.device_save_preset(api, 4, dir, "Not a synth")
	testing.expect_value(t, sr, pa.Result.Unsupported)
	testing.expect_value(t, pa.device_load_preset_file(api, 5, path), pa.Result.Ok)
	of, _ = pa.device_preset_of(api, 5)
	testing.expect_value(t, of, "Mine")
	testing.expect_value(t, pa.device_load_preset_file(api, 5, "/no/such.preset"), pa.Result.Io_Error)
	pa.pad_set_kind(api, 6, .Audio)
	testing.expect_value(t, pa.device_load_preset(api, 6, 0), pa.Result.Unsupported)
	// A plug-in instrument (it needn't load here: the pad says what it plays).
	testing.expect_value(t, pa.device_load_plugin(api, 7, "/no/such.clap", "com.example.synth", "Example Synth"), pa.Result.Ok)
	s, _ = pa.pad_state(api, 7)
	testing.expect_value(t, s.kind, pa.Pad_Kind.Plugin)
	testing.expect_value(t, pa.device_load_plugin(api, 7, "", "x", ""), pa.Result.Invalid_Argument)
}
