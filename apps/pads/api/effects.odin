package pads_api

import "core:strings"

import fc "fire:core"
import "fire:fx"
import pc "../core"
import pm "../model"

// Where an effect slot is.
Effect_Place :: enum i32 {
	Insert, // a pad's insert `slot` (0..3) of pad `index`
	Bus,    // bus `index`'s (0..15) effect `slot` (0..4)
	Main,   // main's effect `slot` (0..4)
	Perf,   // performance effect `index` (0..15): played from its pad, held or latched
}

// An effect slot.
Slot_Ref :: struct {
	place: Effect_Place,
	index: i64, // the pad, the bus, the performance effect
	slot:  i64,
}

// What is in a slot.
Effect_State :: struct {
	kind:   i64,  // its effect kind (effect_kind_name; 0: empty)
	on:     bool, // on (off: bypassed)
	plugin: bool, // a CLAP plug-in (its name: effect_name)
}

// Effect kinds there are (effect_kind_name names them; 0 is empty).
effect_kind_count :: proc(api: ^Api) -> (i64, Result) {
	return i64(len(pm.Effect_Kind)), .Ok
}

// Effect kind `kind`'s name, as the UI shows it ("Reverb", "Low-pass").
// Temporary.
effect_kind_name :: proc(api: ^Api, kind: i64) -> (string, Result) {
	if kind < 0 || kind >= i64(len(pm.Effect_Kind)) do return "", fail(api, .Not_Found, "no such effect kind")
	return string(pm.EFFECT_NAMES[pm.Effect_Kind(kind)]), .Ok
}

// What is in slot `s`.
effect_state :: proc(api: ^Api, s: Slot_Ref) -> (Effect_State, Result) {
	slot, r := slot_of(api, s)
	if r != .Ok do return {}, r
	return {kind = i64(slot.kind), on = slot.on, plugin = slot.kind == .Plugin}, .Ok
}

// The name of what is in slot `s` ("Reverb", a plug-in's; "Empty").
// Temporary.
effect_name :: proc(api: ^Api, s: Slot_Ref) -> (string, Result) {
	slot, r := slot_of(api, s)
	if r != .Ok do return "", r
	return strings.clone(pm.slot_name(slot), context.temp_allocator), .Ok
}

// Puts a new effect of kind `kind` (its default settings) in slot `s`,
// undoably (0: empties it). Unsupported for the plug-in kind
// (effect_set_plugin) and an empty performance effect.
effect_set :: proc(api: ^Api, s: Slot_Ref, kind: i64) -> Result {
	old, r := slot_of(api, s)
	if r != .Ok do return r
	if kind < 0 || kind >= i64(len(pm.Effect_Kind)) do return fail(api, .Invalid_Argument, "no such effect kind")
	k := pm.Effect_Kind(kind)
	if k == .Plugin do return fail(api, .Unsupported, "a plug-in is put in by effect_set_plugin")
	if k == .None && s.place == .Perf do return fail(api, .Unsupported, "a performance effect is always one")
	ns: pm.Effect_Slot
	if k != .None do ns = pm.new_effect(k)
	if s.place == .Perf do ns.on = false // (on while its pad is held)
	name := "Remove Effect" if k == .None else ("Add Effect" if old.kind == .None else "Set Effect")
	pm.set_target_slot(&api.core.m, fx_target(s), ns, name)
	edited(api)
	return .Ok
}

// Puts CLAP plug-in `id` from the library at `path` (named `name`) in slot
// `s`, undoably. Unsupported for a performance effect.
effect_set_plugin :: proc(api: ^Api, s: Slot_Ref, path, id, name: string) -> Result {
	if _, r := slot_of(api, s); r != .Ok do return r
	if s.place == .Perf do return fail(api, .Unsupported, "a performance effect is one of Pads' own")
	if path == "" || id == "" do return fail(api, .Invalid_Argument, "a plug-in needs its library's path and its id")
	m := &api.core.m
	pm.set_target_slot(m, fx_target(s), pm.new_plugin_effect(&m.project, path, id, name if name != "" else id), "Add Plug-in")
	edited(api)
	return .Ok
}

// Empties slot `s`, undoably. Unsupported for a performance effect.
effect_clear :: proc(api: ^Api, s: Slot_Ref) -> Result {
	return effect_set(api, s, 0)
}

// Turns the effect in slot `s` on, or bypasses it, undoably. Not_Found
// for an empty slot.
effect_set_on :: proc(api: ^Api, s: Slot_Ref, on: bool) -> Result {
	slot, r := slot_of(api, s)
	if r != .Ok do return r
	if slot.kind == .None do return fail(api, .Not_Found, "the slot is empty")
	if slot.on == on do return .Ok
	slot.on = on
	pm.set_target_slot(&api.core.m, fx_target(s), slot, "Effect On" if on else "Bypass")
	edited(api)
	return .Ok
}

// Swaps the effects in slots `a` and `b` of one pad's inserts or one bus
// (or main), undoably: how effects are put in another order.
effect_swap :: proc(api: ^Api, a, b: Slot_Ref) -> Result {
	if _, r := slot_of(api, a); r != .Ok do return r
	if _, r := slot_of(api, b); r != .Ok do return r
	if a.place != b.place || a.index != b.index || a.place == .Perf do return fail(api, .Invalid_Argument, "slots of one pad's inserts, or of one bus")
	pm.swap_slots(&api.core.m, fx_target(a), fx_target(b))
	return .Ok
}

// Parameter `id` of the effect in slot `s` (plain units; a performance
// effect's too: param_get covers the others).
effect_get_param :: proc(api: ^Api, s: Slot_Ref, id: i64) -> (f64, Result) {
	slot, r := slot_of(api, s)
	if r != .Ok do return 0, r
	if slot.kind == .None do return 0, fail(api, .Not_Found, "the slot is empty")
	def: f32
	for p in pm.effect_params(slot.kind) do if i64(p.id) == id do def = f32(p.default)
	return f64(pm.slot_value(slot, fc.Param_Id(id), def)), .Ok
}

// Sets parameter `id` of the effect in slot `s` (plain units, in its
// range), undoably (a touch's or a gesture's moves merge).
effect_set_param :: proc(api: ^Api, s: Slot_Ref, id: i64, value: f64) -> Result {
	slot, r := slot_of(api, s)
	if r != .Ok do return r
	if slot.kind == .None do return fail(api, .Not_Found, "the slot is empty")
	if slot.kind != .Plugin {
		known := false
		for p in pm.effect_params(slot.kind) do if i64(p.id) == id {
			known = true
			if !(value >= p.min && value <= p.max) do return fail(api, .Invalid_Argument, "out of the parameter's range")
		}
		if !known do return fail(api, .Not_Found, "no such parameter on that effect")
	}
	pm.set_target_param(&api.core.m, fx_target(s), fc.Param_Id(id), f32(value))
	edited(api)
	return .Ok
}

// Holds performance effect `index` (it plays while held) at `intensity`
// (0..1; -1: its own), or lets it go. Not an edit.
effect_hold :: proc(api: ^Api, index: i64, on: bool, intensity: f32 = -1) -> Result {
	if index < 0 || index >= pm.PERF_FX do return fail(api, .Not_Found, "a performance effect is 0..15")
	if intensity != -1 && !(intensity >= 0 && intensity <= 1) do return fail(api, .Invalid_Argument, "intensity is 0..1 (-1: its own)")
	pm.hold_perf_fx(&api.core.m, int(index), on, intensity)
	return .Ok
}

// Sets performance effect `index`'s own intensity (0..1): what it plays
// at when its pad's press doesn't say. Undoably.
effect_set_intensity :: proc(api: ^Api, index: i64, intensity: f32) -> Result {
	if index < 0 || index >= pm.PERF_FX do return fail(api, .Not_Found, "a performance effect is 0..15")
	if !(intensity >= 0 && intensity <= 1) do return fail(api, .Invalid_Argument, "intensity is 0..1")
	pm.set_perf_intensity(&api.core.m, int(index), intensity)
	edited(api)
	return .Ok
}

// Takes pad `pad`'s send to bus `send` + 1 from before its fader (`pre`)
// or after, undoably. (Its level is a parameter: device Send.)
effect_set_send_pre :: proc(api: ^Api, pad: i64, send: i64, pre: bool) -> Result {
	if _, r := pad_of(api, pad); r != .Ok do return r
	if send < 0 || send >= pm.BUSES do return fail(api, .Not_Found, "a send is 0..15 (to buses 1..16)")
	pm.set_send_pre(&api.core.m, int(pad), int(send) + 1, pre)
	return .Ok
}

// What a compressor's or gate's sidechain listens to.
Key_Kind :: enum i32 {
	None, // itself
	Pad,  // another pad (`index`)
	Bus,  // a bus this track doesn't feed (`index`), after its fader
}

// What the effect in slot `s` listens to (a compressor's, a gate's), and
// how.
Key_State :: struct {
	kind:   Key_Kind,
	index:  i64,  // the pad or the bus
	hpf_hz: f32,  // the key's high-pass (0: none)
	listen: bool, // the track plays the key instead (to set it by)
}

// What the effect in slot `s` listens to.
effect_key :: proc(api: ^Api, s: Slot_Ref) -> (Key_State, Result) {
	slot, r := slot_of(api, s)
	if r != .Ok do return {}, r
	return {kind = Key_Kind(slot.key.kind), index = i64(slot.key.index), hpf_hz = slot.key_hpf, listen = slot.listen}, .Ok
}

// Makes the effect in slot `s` (a compressor, a gate) listen to `kind`
// `index` (None: itself; it stops listening), undoably. Invalid_Argument
// for a key it can't have (itself, or a bus it feeds).
effect_set_key :: proc(api: ^Api, s: Slot_Ref, kind: Key_Kind, index: i64) -> Result {
	slot, r := slot_of(api, s)
	if r != .Ok do return r
	if slot.kind == .None do return fail(api, .Not_Found, "the slot is empty")
	if kind < min(Key_Kind) || kind > max(Key_Kind) do return fail(api, .Invalid_Argument, "no such key")
	k := pm.Key_Source{kind = pm.Key_Kind(kind), index = int(index)}
	if kind != .None && !pm.key_allowed(&api.core.m.project, fx_target(s), k) do return fail(api, .Invalid_Argument, "it can't listen to that (itself, or a bus it feeds)")
	slot.key = k
	if kind == .None && !pm.key_has_high_cut(slot.kind) && !pm.listens_itself(slot.kind) do slot.listen = false // (SuperFilter hears itself through its key's filters; ProComp through its EQ)
	pm.set_target_slot(&api.core.m, fx_target(s), slot, "Sidechain")
	edited(api)
	return .Ok
}

// Sets the key's high-pass (0..2000 Hz; 0: none) of the effect in slot
// `s`, undoably.
effect_set_key_filter :: proc(api: ^Api, s: Slot_Ref, hz: f32) -> Result {
	slot, r := slot_of(api, s)
	if r != .Ok do return r
	if slot.kind == .None do return fail(api, .Not_Found, "the slot is empty")
	if !(hz >= 0 && hz <= 2000) do return fail(api, .Invalid_Argument, "the key's high-pass is 0..2000 Hz")
	slot.key_hpf = hz
	pm.set_target_slot(&api.core.m, fx_target(s), slot, "Key Filter")
	edited(api)
	return .Ok
}

// The key's high cut (its low-pass, in Hz; 0: none) of the effect in slot
// `s`: a SuperFilter's (the others have none).
effect_key_high_cut :: proc(api: ^Api, s: Slot_Ref) -> (f32, Result) {
	slot, r := slot_of(api, s)
	if r != .Ok do return 0, r
	return slot.key_lpf, .Ok
}

// Sets the key's high cut (its low-pass: 200..20000 Hz; 0: none) of the
// SuperFilter in slot `s`, undoably. Invalid_Argument for another effect.
effect_set_key_high_cut :: proc(api: ^Api, s: Slot_Ref, hz: f32) -> Result {
	slot, r := slot_of(api, s)
	if r != .Ok do return r
	if slot.kind == .None do return fail(api, .Not_Found, "the slot is empty")
	if !pm.key_has_high_cut(slot.kind) do return fail(api, .Invalid_Argument, "only a SuperFilter's key has a high cut")
	if !(hz == 0 || (hz >= 200 && hz <= 20_000)) do return fail(api, .Invalid_Argument, "the key's high cut is 200..20000 Hz, or 0")
	slot.key_lpf = hz
	pm.set_target_slot(&api.core.m, fx_target(s), slot, "Key High Cut")
	edited(api)
	return .Ok
}

// How many factory effect presets there are.
effect_preset_count :: proc(api: ^Api) -> (i64, Result) {
	return i64(len(pm.EFFECT_PRESETS)), .Ok
}

// Factory effect preset `index`'s name ("Wobble 1/8"). Not_Found past
// the last.
effect_preset_name :: proc(api: ^Api, index: i64) -> (string, Result) {
	if index < 0 || index >= i64(len(pm.EFFECT_PRESETS)) do return "", fail(api, .Not_Found, "no such preset")
	return pm.EFFECT_PRESETS[index].name, .Ok
}

// The effect kind factory effect preset `index` is for (as
// effect_kind_name counts them).
effect_preset_kind :: proc(api: ^Api, index: i64) -> (i64, Result) {
	if index < 0 || index >= i64(len(pm.EFFECT_PRESETS)) do return 0, fail(api, .Not_Found, "no such preset")
	return i64(pm.EFFECT_PRESETS[index].kind), .Ok
}

// Puts factory effect preset `index` (its effect, set as it says) in
// slot `s`, undoably; the slot's sidechain source stays. Not_Found for no
// such preset.
effect_load_preset :: proc(api: ^Api, s: Slot_Ref, index: i64) -> Result {
	slot, r := slot_of(api, s)
	if r != .Ok do return r
	if index < 0 || index >= i64(len(pm.EFFECT_PRESETS)) do return fail(api, .Not_Found, "no such preset")
	p := pm.EFFECT_PRESETS[index]
	t := fx_target(s)
	if t.kind == .Perf do return fail(api, .Unsupported, "a performance effect takes no presets")
	n := pm.effect_preset_slot(p)
	if pm.key_allowed(&api.core.m.project, t, slot.key) do n.key = slot.key
	pm.set_target_slot(&api.core.m, t, n, "Load Preset")
	edited(api)
	return .Ok
}

// How many presets ProVerb has from an installed ValhallaRoom (its own
// preset files on this machine, read when first asked; 0 where it isn't
// installed).
effect_imported_preset_count :: proc(api: ^Api) -> (i64, Result) {
	return i64(len(pm.imported_presets())), .Ok
}

// Imported preset `index`'s name, with its folder ("Halls / Big Hall").
// Not_Found for no such preset.
effect_imported_preset_name :: proc(api: ^Api, index: i64) -> (string, Result) {
	list := pm.imported_presets()
	if index < 0 || index >= i64(len(list)) do return "", fail(api, .Not_Found, "no such preset")
	p := list[index]
	if p.folder == "" do return p.name, .Ok
	return strings.concatenate({p.folder, " / ", p.name}, context.temp_allocator), .Ok
}

// Loads imported preset `index` (a ProVerb at its settings) into slot `s`,
// undoably. Not_Found for no such preset; Unsupported for a performance
// effect.
effect_load_imported_preset :: proc(api: ^Api, s: Slot_Ref, index: i64) -> Result {
	if _, r := slot_of(api, s); r != .Ok do return r
	list := pm.imported_presets()
	if index < 0 || index >= i64(len(list)) do return fail(api, .Not_Found, "no such preset")
	t := fx_target(s)
	if t.kind == .Perf do return fail(api, .Unsupported, "a performance effect takes no presets")
	pm.set_target_slot(&api.core.m, t, pm.imported_preset_slot(list[index]), "Load Preset")
	edited(api)
	return .Ok
}

// What a SuperFilter is doing as it plays (as of the last block it ran).
Super_Filter_State :: struct {
	cutoff_l:  f32, // the modulated cutoff (Hz), left
	cutoff_r:  f32, // and right
	lfo_l:     f32, // the LFO, left (-1..1)
	lfo_r:     f32, // and right
	env:       f32,    // the envelope (0..1)
	in_peak:   f32,    // the peak in (linear)
	out_peak:  f32,    // and out
}

// What the SuperFilter in slot `s` is doing: its cutoffs as modulated,
// its LFO and envelope, its peaks. Not_Found if the slot holds no
// SuperFilter (or it isn't in the graph).
effect_super_filter_state :: proc(api: ^Api, s: Slot_Ref) -> (Super_Filter_State, Result) {
	slot, r := slot_of(api, s)
	if r != .Ok do return {}, r
	if slot.kind != .Super_Filter do return {}, fail(api, .Not_Found, "the slot holds no SuperFilter")
	x, ok := pm.slot_super_filter(&api.core.m.engine, fx_target(s))
	if !ok do return {}, fail(api, .Not_Found, "the SuperFilter isn't playing")
	return {cutoff_l = x.cutoff_hz[0], cutoff_r = x.cutoff_hz[1], lfo_l = x.lfo[0], lfo_r = x.lfo[1], env = x.env, in_peak = x.in_peak, out_peak = x.out_peak}, .Ok
}

// What a ProEq is doing as it plays (as of the last block it ran).
Pro_Eq_State :: struct {
	in_peak:       f32, // the peak in (linear)
	out_peak:      f32, // and out
	audition_set:  i64, // the set (0: A, 1: B) of the band being auditioned, or -1
	audition_band: i64, // and the band (0..7), or -1
}

// What the ProEq in slot `s` is doing: its peaks and the band it is
// auditioning. Not_Found if the slot holds no ProEq (or it isn't in the
// graph).
effect_pro_eq_state :: proc(api: ^Api, s: Slot_Ref) -> (Pro_Eq_State, Result) {
	slot, r := slot_of(api, s)
	if r != .Ok do return {}, r
	if slot.kind != .Pro_Eq do return {}, fail(api, .Not_Found, "the slot holds no ProEq")
	eq := pm.slot_pro_eq(&api.core.m.engine, fx_target(s))
	if eq == nil do return {}, fail(api, .Not_Found, "the ProEq isn't playing")
	x := fx.pro_eq_readout(eq)
	set, band := fx.pro_eq_auditioning(eq)
	return {in_peak = x.in_peak, out_peak = x.out_peak, audition_set = i64(set), audition_band = i64(band)}, .Ok
}

// Auditions band `band` (0..7) of set `set` (0: A, 1: B) of the ProEq in
// slot `s`: the slot plays only what that band touches until it is called
// with `band` -1. Not an edit (not saved, not undone). Not_Found if the
// slot holds no ProEq playing; Invalid_Argument for no such band.
effect_set_pro_eq_audition :: proc(api: ^Api, s: Slot_Ref, set, band: i64) -> Result {
	slot, r := slot_of(api, s)
	if r != .Ok do return r
	if slot.kind != .Pro_Eq do return fail(api, .Not_Found, "the slot holds no ProEq")
	if band >= i64(fx.PE_BANDS) || band < -1 || set < 0 || set >= i64(fx.PE_SETS) do return fail(api, .Invalid_Argument, "no such band")
	eq := pm.slot_pro_eq(&api.core.m.engine, fx_target(s))
	if eq == nil do return fail(api, .Not_Found, "the ProEq isn't playing")
	fx.pro_eq_audition(eq, int(set), int(band))
	return .Ok
}

// Sets the mode of the ProEq in slot `s` (0: Stereo, 1: L/R, 2: M/S),
// undoably. Leaving Stereo while set B is as it started, B becomes a copy
// of A first. Not_Found if the slot holds no ProEq.
effect_set_pro_eq_mode :: proc(api: ^Api, s: Slot_Ref, mode: i64) -> Result {
	if _, r := slot_of(api, s); r != .Ok do return r
	if mode < 0 || mode > i64(max(fx.Pro_Eq_Mode)) do return fail(api, .Invalid_Argument, "no such mode")
	if !pm.pro_eq_set_mode(&api.core.m, fx_target(s), fx.Pro_Eq_Mode(mode)) do return fail(api, .Not_Found, "the slot holds no ProEq")
	edited(api)
	return .Ok
}

// What a ProComp is doing as it plays (as of the last block it ran).
Pro_Comp_State :: struct {
	in_peak:  f32, // the peak in (linear)
	in_rms:   f32, // its RMS
	level_db: f32, // the detector's level (dB): where the signal is on the curve
	gr_db:    f32, // the gain reduction (dB, at most 0)
	out_peak: f32, // the peak out (linear)
}

// What the ProComp in slot `s` is doing: its levels in and out, its
// detector's level and its gain reduction. Not_Found if the slot holds no
// ProComp (or it isn't in the graph).
effect_pro_comp_state :: proc(api: ^Api, s: Slot_Ref) -> (Pro_Comp_State, Result) {
	slot, r := slot_of(api, s)
	if r != .Ok do return {}, r
	if slot.kind != .Pro_Comp do return {}, fail(api, .Not_Found, "the slot holds no ProComp")
	pc := pm.slot_pro_comp(&api.core.m.engine, fx_target(s))
	if pc == nil do return {}, fail(api, .Not_Found, "the ProComp isn't playing")
	x := fx.pro_comp_readout(pc)
	return {in_peak = x.in_peak, in_rms = x.in_rms, level_db = x.level_db, gr_db = x.gr_db, out_peak = x.out_peak}, .Ok
}

// A moment of a ProComp's activity: over 256 frames, the peaks in and out
// and the deepest gain reduction (dB).
Pro_Comp_Moment :: struct {
	in_db:  f32,
	out_db: f32,
	gr_db:  f32,
}

// The ProComp in slot `s`'s activity `ago` moments back (0: the newest;
// each 256 frames, up to 1023 back), for a picture of it over time.
// Not_Found if the slot holds no ProComp playing; Invalid_Argument past
// what it keeps.
effect_pro_comp_moment :: proc(api: ^Api, s: Slot_Ref, ago: i64) -> (Pro_Comp_Moment, Result) {
	slot, r := slot_of(api, s)
	if r != .Ok do return {}, r
	if slot.kind != .Pro_Comp do return {}, fail(api, .Not_Found, "the slot holds no ProComp")
	if ago < 0 || ago >= fx.PC_HISTORY do return {}, fail(api, .Invalid_Argument, "past what it keeps")
	pc := pm.slot_pro_comp(&api.core.m.engine, fx_target(s))
	if pc == nil do return {}, fail(api, .Not_Found, "the ProComp isn't playing")
	h: [fx.PC_HISTORY]fx.Pro_Comp_Moment
	fx.pro_comp_history(pc, h[:ago + 1])
	m := h[0]
	return {in_db = m.in_db, out_db = m.out_db, gr_db = m.gr_db}, .Ok
}

// What a ProSaturator is doing as it plays: its peaks, and the harmonics
// it puts out of the loudest partial it takes in (each in dB against that
// partial: h1 is 0; -120 for none).
Pro_Saturator_State :: struct {
	in_peak:  f32, // the peak into its curve, after Drive (linear)
	out_peak: f32, // the peak out (linear)
	h1, h2, h3, h4, h5, h6, h7, h8: f32,
}

// What the ProSaturator in slot `s` is doing: its peaks and the harmonics
// in its output. Not_Found if the slot holds no ProSaturator (or it isn't
// in the graph).
effect_pro_saturator_state :: proc(api: ^Api, s: Slot_Ref) -> (Pro_Saturator_State, Result) {
	slot, r := slot_of(api, s)
	if r != .Ok do return {}, r
	if slot.kind != .Pro_Saturator do return {}, fail(api, .Not_Found, "the slot holds no ProSaturator")
	ps := pm.slot_pro_saturator(&api.core.m.engine, fx_target(s))
	if ps == nil do return {}, fail(api, .Not_Found, "the ProSaturator isn't playing")
	x := fx.pro_saturator_readout(ps)
	st := Pro_Saturator_State{in_peak = x.in_peak, out_peak = x.out_peak}
	h := [8]f32{-120, -120, -120, -120, -120, -120, -120, -120}
	if _, out, ok := pm.pro_saturator_harmonics(ps, ps.sample_rate); ok do h = out
	st.h1, st.h2, st.h3, st.h4, st.h5, st.h6, st.h7, st.h8 = h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7]
	return st, .Ok
}

// What a ProVerb is doing as it plays (as of the last block it ran).
Proverb_State :: struct {
	in_peak:  f32, // the peak in (linear)
	out_peak: f32, // the peak out (linear)
	tail:     f32, // the wet's RMS (linear): how much tail is ringing
}

// What the ProVerb in slot `s` is doing: its peaks and its tail's level.
// Not_Found if the slot holds no ProVerb (or it isn't in the graph).
effect_proverb_state :: proc(api: ^Api, s: Slot_Ref) -> (Proverb_State, Result) {
	slot, r := slot_of(api, s)
	if r != .Ok do return {}, r
	if slot.kind != .Proverb do return {}, fail(api, .Not_Found, "the slot holds no ProVerb")
	pv := pm.slot_proverb(&api.core.m.engine, fx_target(s))
	if pv == nil do return {}, fail(api, .Not_Found, "the ProVerb isn't playing")
	x := fx.proverb_readout(pv)
	return {in_peak = x.in_peak, out_peak = x.out_peak, tail = x.tail}, .Ok
}

// Makes the track play the key of the effect in slot `s` (filtered)
// instead, to set it by, or not. Undoably.
effect_set_key_listen :: proc(api: ^Api, s: Slot_Ref, on: bool) -> Result {
	slot, r := slot_of(api, s)
	if r != .Ok do return r
	if slot.kind == .None do return fail(api, .Not_Found, "the slot is empty")
	slot.listen = on
	pm.set_target_slot(&api.core.m, fx_target(s), slot, "Listen to Key")
	edited(api)
	return .Ok
}

@(private)
fx_target :: proc(s: Slot_Ref) -> pm.Fx_Target {
	switch s.place {
	case .Insert: return {kind = .Pad, index = int(s.index), slot = int(s.slot)}
	case .Bus:    return {kind = .Bus, index = int(s.index), slot = int(s.slot)}
	case .Main:   return {kind = .Bus, index = pm.BUSES, slot = int(s.slot)}
	case .Perf:   return {kind = .Perf, index = int(s.index)}
	}
	return {}
}

@(private)
slot_of :: proc(api: ^Api, s: Slot_Ref) -> (pm.Effect_Slot, Result) {
	switch s.place {
	case .Insert:
		if s.index < 0 || s.index >= PADS do return {}, fail(api, .Not_Found, "a pad is 0..127")
		if s.slot < 0 || s.slot >= pm.PAD_INSERTS do return {}, fail(api, .Not_Found, "a pad's inserts are 0..3")
	case .Bus, .Main:
		if s.place == .Bus && (s.index < 0 || s.index >= pm.BUSES) do return {}, fail(api, .Not_Found, "a bus is 0..15")
		if s.slot < 0 || s.slot >= pm.BUS_SLOTS do return {}, fail(api, .Not_Found, "a bus's effects are 0..4")
	case .Perf:
		if s.index < 0 || s.index >= pm.PERF_FX do return {}, fail(api, .Not_Found, "a performance effect is 0..15")
	case:
		return {}, fail(api, .Invalid_Argument, "no such place")
	}
	slot, ok := pm.target_slot(&api.core.m, fx_target(s))
	if !ok do return {}, fail(api, .Not_Found, "no such slot")
	return slot, .Ok
}

// Performance effect `index`'s pad pressed (`on`, at `intensity`: 0..1,
// -1 its own) or let go, as the Perform tab's: held while held, or, with
// effects latching, on until the next press.
effect_press :: proc(api: ^Api, index: i64, on: bool, intensity: f32 = -1) -> Result {
	if index < 0 || index >= pm.PERF_FX do return fail(api, .Not_Found, "a performance effect is 0..15")
	if intensity != -1 && !(intensity >= 0 && intensity <= 1) do return fail(api, .Invalid_Argument, "intensity is 0..1 (-1: its own)")
	pc.fx_press(api.core, int(index), on, intensity)
	return .Ok
}

// How hard effect `index` plays while its pad is held (0..1: its pressure),
// as the press moves. Nothing when it isn't held or latched.
effect_pressure :: proc(api: ^Api, index: i64, intensity: f32) -> Result {
	if index < 0 || index >= pm.PERF_FX do return fail(api, .Not_Found, "a performance effect is 0..15")
	if !(intensity >= 0 && intensity <= 1) do return fail(api, .Invalid_Argument, "intensity is 0..1")
	pc.fx_pressure(api.core, int(index), intensity)
	return .Ok
}

// Effects latch (`on`: a press turns one on until the next), or play
// while held; turned off, the latched ones not held go off.
effect_set_latch :: proc(api: ^Api, on: bool) -> Result {
	pc.fx_set_latch(api.core, on)
	return .Ok
}
