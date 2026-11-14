package pads_api

import "core:strings"

import fc "fire:core"
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
	if kind == .None do slot.listen = false
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
