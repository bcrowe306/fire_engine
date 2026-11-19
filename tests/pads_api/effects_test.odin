package test_pads_api

import "core:os"
import "core:path/filepath"
import "core:testing"

import pa "../../apps/pads/api"
import pm "../../apps/pads/model"
import "fire:fx"

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
	// Only a SuperFilter's key has a high cut; it reads back what it plays.
	testing.expect_value(t, pa.effect_set_key_high_cut(api, comp, 5000), pa.Result.Invalid_Argument)
	sf := pa.Slot_Ref{place = .Insert, index = 0, slot = 1}
	testing.expect_value(t, pa.effect_set(api, sf, kind_of(api, "SuperFilter")), pa.Result.Ok)
	testing.expect_value(t, pa.effect_set_key_high_cut(api, sf, 5000), pa.Result.Ok)
	testing.expect_value(t, pa.effect_set_key_high_cut(api, sf, 50), pa.Result.Invalid_Argument)
	hc, _ := pa.effect_key_high_cut(api, sf)
	testing.expect_value(t, hc, 5000)
	n, _ = pa.history_undo_name(api)
	testing.expect_value(t, n, "Key High Cut")
	testing.expect_value(t, pa.effect_set_key_listen(api, sf, true), pa.Result.Ok)
	testing.expect_value(t, pa.effect_set_key(api, sf, .None, 0), pa.Result.Ok)
	k, _ = pa.effect_key(api, sf)
	testing.expect(t, k.listen, "a SuperFilter still hears its own key")
	render(r, 1024)
	st2, sr := pa.effect_super_filter_state(api, sf)
	testing.expect_value(t, sr, pa.Result.Ok)
	testing.expectf(t, st2.cutoff_l >= 20 && st2.cutoff_l <= 20_000, "its cutoff (%v)", st2)
	_, sr = pa.effect_super_filter_state(api, comp)
	testing.expect_value(t, sr, pa.Result.Not_Found)
	// Factory presets: SuperFilter's, loaded into a slot (its key kept).
	np, _ := pa.effect_preset_count(api)
	testing.expect(t, np >= 50, "SuperFilter's and the Pro devices' presets")
	duck := -1
	for k in 0 ..< np {
		name, _ := pa.effect_preset_name(api, k)
		kind, _ := pa.effect_preset_kind(api, k)
		kn, _ := pa.effect_kind_name(api, kind)
		testing.expect(t, name != "" && (kn == "SuperFilter" || kn == "ProEq" || kn == "ProComp" || kn == "ProSaturator" || kn == "ProVerb"), "named, for one of the Pro devices or SuperFilter")
		if name == "Duck to Kick" do duck = int(k)
	}
	_, sr = pa.effect_preset_name(api, np)
	testing.expect_value(t, sr, pa.Result.Not_Found)
	_, sr = pa.effect_preset_kind(api, -1)
	testing.expect_value(t, sr, pa.Result.Not_Found)
	pa.effect_set_key(api, sf, .Pad, 2)
	testing.expect_value(t, pa.effect_load_preset(api, sf, i64(duck)), pa.Result.Ok)
	n, _ = pa.history_undo_name(api)
	testing.expect_value(t, n, "Load Preset")
	k, _ = pa.effect_key(api, sf)
	hc, _ = pa.effect_key_high_cut(api, sf)
	env, _ := pa.effect_get_param(api, sf, 21)
	testing.expect(t, k.kind == .Pad && k.index == 2 && hc == 150 && env < 0, "the preset, its key kept")
	testing.expect_value(t, pa.effect_load_preset(api, sf, np), pa.Result.Not_Found)
	testing.expect_value(t, pa.effect_load_preset(api, {place = .Perf, index = 0}, 0), pa.Result.Unsupported)
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

// ProEq through the API: its bands as parameters (A and B), its mode (B
// a copy of A on leaving Stereo), its state as it plays and its audition.
@(test)
a_pro_eq_through_the_api :: proc(t: ^testing.T) {
	r := rig_make(t, "effects_pro_eq")
	defer rig_destroy(r)
	api := &r.api
	pa.pad_load_sample(api, 0, tone(r))
	eq := pa.Slot_Ref{place = .Insert, index = 0, slot = 0}
	testing.expect_value(t, pa.effect_set(api, eq, kind_of(api, "ProEq")), pa.Result.Ok)
	gain := i64(fx.pro_eq_band_param(0, 2, .Gain_Db))
	testing.expect_value(t, pa.effect_set_param(api, eq, gain, 6), pa.Result.Ok)
	testing.expect_value(t, pa.effect_set_param(api, eq, gain, 40), pa.Result.Invalid_Argument)
	// The mode: B starts as A.
	testing.expect_value(t, pa.effect_set_pro_eq_mode(api, eq, 2), pa.Result.Ok)
	n, _ := pa.history_undo_name(api)
	testing.expect_value(t, n, "Set EQ Mode")
	b, _ := pa.effect_get_param(api, eq, i64(fx.pro_eq_band_param(1, 2, .Gain_Db)))
	testing.expect_value(t, b, 6)
	testing.expect_value(t, pa.effect_set_pro_eq_mode(api, eq, 3), pa.Result.Invalid_Argument)
	// Playing: its peaks; auditioning a band.
	pa.pad_play(api, 0, true)
	render(r, 4800)
	st, sr := pa.effect_pro_eq_state(api, eq)
	testing.expect_value(t, sr, pa.Result.Ok)
	testing.expectf(t, st.in_peak > 0.1 && st.audition_band == -1, "its state (%v)", st)
	testing.expect_value(t, pa.effect_set_pro_eq_audition(api, eq, 1, 2), pa.Result.Ok)
	st, _ = pa.effect_pro_eq_state(api, eq)
	testing.expect(t, st.audition_set == 1 && st.audition_band == 2, "auditioning B's band 3")
	testing.expect_value(t, pa.effect_set_pro_eq_audition(api, eq, 0, 8), pa.Result.Invalid_Argument)
	testing.expect_value(t, pa.effect_set_pro_eq_audition(api, eq, 0, -1), pa.Result.Ok)
	// Another effect: none of it.
	comp := pa.Slot_Ref{place = .Insert, index = 0, slot = 1}
	pa.effect_set(api, comp, kind_of(api, "Compressor"))
	_, sr = pa.effect_pro_eq_state(api, comp)
	testing.expect_value(t, sr, pa.Result.Not_Found)
	testing.expect_value(t, pa.effect_set_pro_eq_audition(api, comp, 0, 1), pa.Result.Not_Found)
	testing.expect_value(t, pa.effect_set_pro_eq_mode(api, comp, 1), pa.Result.Not_Found)
}

// ProComp through the API: its state as it plays, its activity, keyed
// from another pad (its Listen its own).
@(test)
a_pro_comp_through_the_api :: proc(t: ^testing.T) {
	r := rig_make(t, "effects_pro_comp")
	defer rig_destroy(r)
	api := &r.api
	pa.pad_load_sample(api, 0, tone(r))
	pa.pad_load_sample(api, 1, tone(r, "b.wav"))
	pc := pa.Slot_Ref{place = .Insert, index = 0, slot = 0}
	testing.expect_value(t, pa.effect_set(api, pc, kind_of(api, "ProComp")), pa.Result.Ok)
	testing.expect_value(t, pa.effect_set_param(api, pc, i64(fx.PC_PARAM_THRESHOLD_DB), -40), pa.Result.Ok)
	pa.pad_play(api, 0, true)
	render(r, 9600)
	st, sr := pa.effect_pro_comp_state(api, pc)
	testing.expect_value(t, sr, pa.Result.Ok)
	testing.expectf(t, st.in_peak > 0.1 && st.gr_db < -3 && st.level_db > -30, "its state (%v)", st)
	m, mr := pa.effect_pro_comp_moment(api, pc, 0)
	testing.expect_value(t, mr, pa.Result.Ok)
	testing.expectf(t, m.gr_db < -3 && m.in_db > -30, "its newest moment (%v)", m)
	_, mr = pa.effect_pro_comp_moment(api, pc, 1024)
	testing.expect_value(t, mr, pa.Result.Invalid_Argument)
	// Keyed from pad 1, listening: still its own Listen.
	testing.expect_value(t, pa.effect_set_key(api, pc, .Pad, 1), pa.Result.Ok)
	testing.expect_value(t, pa.effect_set_key_listen(api, pc, true), pa.Result.Ok)
	testing.expect_value(t, pa.effect_set_key(api, pc, .None, 0), pa.Result.Ok)
	k, _ := pa.effect_key(api, pc)
	testing.expect(t, k.listen, "listening to itself (through its EQ)")
	comp := pa.Slot_Ref{place = .Insert, index = 0, slot = 1}
	pa.effect_set(api, comp, kind_of(api, "Compressor"))
	_, sr = pa.effect_pro_comp_state(api, comp)
	testing.expect_value(t, sr, pa.Result.Not_Found)
	_, mr = pa.effect_pro_comp_moment(api, comp, 0)
	testing.expect_value(t, mr, pa.Result.Not_Found)
}

// ProSaturator through the API: its peaks and harmonics as it plays (Tube
// adding a second one), another effect none of it.
@(test)
a_pro_saturator_through_the_api :: proc(t: ^testing.T) {
	r := rig_make(t, "effects_pro_saturator")
	defer rig_destroy(r)
	api := &r.api
	pa.pad_load_sample(api, 0, tone(r))
	ps := pa.Slot_Ref{place = .Insert, index = 0, slot = 0}
	testing.expect_value(t, pa.effect_set(api, ps, kind_of(api, "ProSaturator")), pa.Result.Ok)
	pa.effect_set_param(api, ps, i64(fx.PS_PARAM_TYPE), f64(fx.Pro_Saturator_Type.Tube))
	pa.effect_set_param(api, ps, i64(fx.PS_PARAM_DRIVE_DB), 12)
	pa.pad_play(api, 0, true)
	render(r, 9600)
	st, sr := pa.effect_pro_saturator_state(api, ps)
	testing.expect_value(t, sr, pa.Result.Ok)
	testing.expectf(t, st.in_peak > 0.5 && st.h1 == 0 && st.h2 > -50, "its state (%v)", st)
	comp := pa.Slot_Ref{place = .Insert, index = 0, slot = 1}
	pa.effect_set(api, comp, kind_of(api, "Compressor"))
	_, sr = pa.effect_pro_saturator_state(api, comp)
	testing.expect_value(t, sr, pa.Result.Not_Found)
}

// ProVerb through the API: its tail as it plays, another effect none of it.
@(test)
a_proverb_through_the_api :: proc(t: ^testing.T) {
	r := rig_make(t, "effects_proverb")
	defer rig_destroy(r)
	api := &r.api
	pa.pad_load_sample(api, 0, tone(r))
	pv := pa.Slot_Ref{place = .Insert, index = 0, slot = 0}
	testing.expect_value(t, pa.effect_set(api, pv, kind_of(api, "ProVerb")), pa.Result.Ok)
	testing.expect_value(t, pa.effect_set_param(api, pv, i64(fx.PV_PARAM_MIX), 1), pa.Result.Ok)
	pa.pad_play(api, 0, true)
	render(r, 9600)
	st, sr := pa.effect_proverb_state(api, pv)
	testing.expect_value(t, sr, pa.Result.Ok)
	testing.expectf(t, st.in_peak > 0.1 && st.tail > 0.001, "its state (%v)", st)
	comp := pa.Slot_Ref{place = .Insert, index = 0, slot = 1}
	pa.effect_set(api, comp, kind_of(api, "Compressor"))
	_, sr = pa.effect_proverb_state(api, comp)
	testing.expect_value(t, sr, pa.Result.Not_Found)
}

// Presets from an installed ValhallaRoom through the API: counted, named,
// loaded (whatever this machine has; out of range, Not_Found).
@(test)
imported_presets_through_the_api :: proc(t: ^testing.T) {
	r := rig_make(t, "effects_imported")
	defer rig_destroy(r)
	api := &r.api
	n, _ := pa.effect_imported_preset_count(api)
	_, nr := pa.effect_imported_preset_name(api, n)
	testing.expect_value(t, nr, pa.Result.Not_Found)
	slot := pa.Slot_Ref{place = .Insert, index = 0, slot = 0}
	testing.expect_value(t, pa.effect_load_imported_preset(api, slot, n), pa.Result.Not_Found)
	if n == 0 do return // (not installed here)
	name, _ := pa.effect_imported_preset_name(api, 0)
	testing.expect(t, name != "", "named")
	testing.expect_value(t, pa.effect_load_imported_preset(api, slot, 0), pa.Result.Ok)
	kn, _ := pa.effect_name(api, slot)
	testing.expect_value(t, kn, "ProVerb")
	u, _ := pa.history_undo_name(api)
	testing.expect_value(t, u, "Load Preset")
}
