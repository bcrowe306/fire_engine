package pads_model

import "core:strings"


import app "app:core"
import fc "fire:core"
import "fire:dsp"

// Insert slots on each pad.
PAD_INSERTS :: 2
// Effect slots on each bus and on main.
BUS_SLOTS :: 5
// Buses (A to D); a pad goes to one, or straight to main.
BUSES :: 4
// Performance effects (applied to main while held).
PERF_FX :: 16
// Parameters an effect slot keeps.
MAX_EFFECT_PARAMS :: 16

// What an effect slot holds.
Effect_Kind :: enum u8 {
	None,
	Low_Pass,
	High_Pass,
	Band_Pass,
	Compressor,
	Gate,
	Limiter,
	Saturation,
	Bitcrush,
	Delay,
	Reverb,
	Chorus,
	Flanger,
	Phaser,
	Ring_Mod,
	Comb,
	Pitch,
	Cutter,
	Stutter,
	Plugin, // a CLAP plug-in: `plugin_path` and `plugin_id`
}

// Effect names, as the UI shows them.
EFFECT_NAMES := [Effect_Kind]cstring{
	.None = "Empty", .Low_Pass = "Low-pass", .High_Pass = "High-pass", .Band_Pass = "Band-pass",
	.Compressor = "Compressor", .Gate = "Gate", .Limiter = "Limiter", .Saturation = "Saturation", .Bitcrush = "Bit-crusher",
	.Delay = "Delay", .Reverb = "Reverb", .Chorus = "Chorus", .Flanger = "Flanger", .Phaser = "Phaser",
	.Ring_Mod = "Ring mod", .Comb = "Comb", .Pitch = "Pitch shift", .Cutter = "Cutter", .Stutter = "Stutter", .Plugin = "Plug-in",
}

// One parameter value an effect slot keeps.
Slot_Param :: struct {
	id:    fc.Param_Id,
	value: f32,
}

// An effect slot: what is in it, whether it is on, and its settings. A
// plain value (strings interned in the project), for undo.
Effect_Slot :: struct {
	kind:        Effect_Kind,
	on:          bool,
	params:      [MAX_EFFECT_PARAMS]Slot_Param,
	count:       int,
	plugin_path: string, // .Plugin: the .clap file
	plugin_id:   string, // .Plugin: which of its plug-ins
	plugin_name: string,
}

// The value a slot has for parameter `id`, or `default`.
slot_value :: proc(s: Effect_Slot, id: fc.Param_Id, default: f32) -> f32 {
	s := s
	for p in s.params[:s.count] do if p.id == id do return p.value
	return default
}

// Sets parameter `id` of slot `s` (adding it if it has room).
slot_set :: proc(s: ^Effect_Slot, id: fc.Param_Id, value: f32) {
	for &p in s.params[:s.count] do if p.id == id {
		p.value = value
		return
	}
	if s.count < MAX_EFFECT_PARAMS {
		s.params[s.count] = {id, value}
		s.count += 1
	}
}

// The built-in parameter table of an effect kind (nil for none and
// plug-ins: theirs come from the plug-in).
effect_params :: proc(k: Effect_Kind) -> []fc.Param_Info {
	switch k {
	case .None, .Plugin: return nil
	case .Low_Pass, .High_Pass, .Band_Pass: return dsp.filter_params[1:3] // cutoff and Q (the mode is the kind)
	case .Compressor: return dsp.compressor_params[:]
	case .Gate:       return dsp.gate_params[:]
	case .Limiter:    return dsp.limiter_params[:]
	case .Saturation: return dsp.saturation_params[:]
	case .Bitcrush:   return dsp.bitcrush_params[:]
	case .Delay:      return dsp.delay_params[:]
	case .Reverb:     return dsp.reverb_params[:]
	case .Chorus:     return dsp.chorus_params[:]
	case .Flanger:    return dsp.flanger_params[:]
	case .Phaser:     return dsp.phaser_params[:]
	case .Ring_Mod:   return dsp.ring_params[:]
	case .Comb:       return dsp.comb_params[:]
	case .Pitch:      return dsp.pitch_params[:]
	case .Cutter:     return dsp.cutter_params[:]
	case .Stutter:    return dsp.stutter_params[:1] // the length (on is the slot's switch)
	}
	return nil
}

// A slot holding a new `kind` effect at its defaults, on.
new_effect :: proc(kind: Effect_Kind) -> Effect_Slot {
	s := Effect_Slot{kind = kind, on = kind != .None}
	for p in effect_params(kind) do slot_set(&s, p.id, f32(p.default))
	#partial switch kind {
	case .Low_Pass:  slot_set(&s, dsp.FILTER_PARAM_CUTOFF_HZ, 900)
	case .High_Pass: slot_set(&s, dsp.FILTER_PARAM_CUTOFF_HZ, 1200)
	case .Band_Pass: slot_set(&s, dsp.FILTER_PARAM_CUTOFF_HZ, 1000); slot_set(&s, dsp.FILTER_PARAM_Q, 2)
	}
	return s
}

// A slot holding plug-in `id` of the CLAP library at `path`.
new_plugin_effect :: proc(p: ^Project, path, id, name: string) -> Effect_Slot {
	return {kind = .Plugin, on = true, plugin_path = intern(p, path), plugin_id = intern(p, id), plugin_name = intern(p, name)}
}

// What a slot is called in the UI.
slot_name :: proc(s: Effect_Slot) -> string {
	if s.kind == .Plugin do return s.plugin_name if s.plugin_name != "" else s.plugin_id
	return string(EFFECT_NAMES[s.kind])
}

// A bus (A to D) or main: its effects, then its fader.
Bus :: struct {
	volume: f32, // dB
	pan:    f32, // -1..1
	mute:   bool,
	solo:   bool,
	slots:  [BUS_SLOTS]Effect_Slot,
}

// Where a pad's sound goes: 0 = main, 1..BUSES = a bus.
bus_name :: proc(b: int) -> string {
	names := [?]string{"Main", "Bus A", "Bus B", "Bus C", "Bus D"}
	return names[clamp(b, 0, BUSES)]
}

// The performance effects a project starts with, one per pad of the
// performance grid.
default_perf_fx :: proc() -> [PERF_FX]Effect_Slot {
	fx: [PERF_FX]Effect_Slot
	kinds := [PERF_FX]Effect_Kind{.Low_Pass, .High_Pass, .Band_Pass, .Comb, .Stutter, .Stutter, .Stutter, .Cutter,
		.Cutter, .Bitcrush, .Ring_Mod, .Pitch, .Pitch, .Delay, .Reverb, .Saturation}
	for k, i in kinds {
		fx[i] = new_effect(k)
		fx[i].on = false // the slot is set up; holding its pad turns it on
	}
	slot_set(&fx[0], dsp.FILTER_PARAM_CUTOFF_HZ, 500)
	slot_set(&fx[1], dsp.FILTER_PARAM_CUTOFF_HZ, 2000)
	slot_set(&fx[4], dsp.STUTTER_PARAM_BEATS, 0.5)
	slot_set(&fx[5], dsp.STUTTER_PARAM_BEATS, 0.25)
	slot_set(&fx[6], dsp.STUTTER_PARAM_BEATS, 0.125)
	slot_set(&fx[7], dsp.CUTTER_PARAM_BEATS, 0.5)
	slot_set(&fx[8], dsp.CUTTER_PARAM_BEATS, 0.25)
	slot_set(&fx[11], dsp.PITCH_PARAM_SEMITONES, 12)
	slot_set(&fx[12], dsp.PITCH_PARAM_SEMITONES, -12)
	slot_set(&fx[13], dsp.DELAY_PARAM_SYNC, 1)
	slot_set(&fx[13], dsp.DELAY_PARAM_MIX, 0.5)
	slot_set(&fx[14], dsp.REVERB_PARAM_MIX, 0.5)
	slot_set(&fx[15], dsp.SATURATION_PARAM_DRIVE_DB, 18)
	return fx
}

// A performance effect's label on its pad.
perf_label :: proc(s: Effect_Slot) -> string {
	#partial switch s.kind {
	case .Stutter: return strings.concatenate({"Stutter ", beats_name(slot_value(s, dsp.STUTTER_PARAM_BEATS, 0.25))}, context.temp_allocator)
	case .Cutter:  return strings.concatenate({"Cutter ", beats_name(slot_value(s, dsp.CUTTER_PARAM_BEATS, 0.25))}, context.temp_allocator)
	case .Pitch:
		st := slot_value(s, dsp.PITCH_PARAM_SEMITONES, 12)
		return "Pitch up" if st > 0 else "Pitch down"
	}
	return slot_name(s)
}

// "1/4", "1/16": a length in beats.
@(private)
beats_name :: proc(b: f32) -> string {
	if b >= 1 do return "1/4"
	return strings.concatenate({"1/", itoa(int(4 / b + 0.5))}, context.temp_allocator)
}

// --- commands ------------------------------------------------------------------------------

// Changes bus `index` (0..BUSES-1; BUSES is main) to `new`, undoably, as
// an edit named `name` of part `field` (drags of the same field merge).
set_bus :: proc(m: ^Model, index: int, field: int, name: string, new: Bus) {
	if index < 0 || index > BUSES do return
	old := bus_of(m, index)^
	if old == new do return
	app.set_value(&m.history, name, {app.Id(1000 + index), field}, old, new, proc(ctx: rawptr, k: app.Key, v: Bus) {
		mm := (^Model)(ctx)
		bus_of(mm, int(k.id) - 1000)^ = v
		mm.engine.mix_dirty = true
	})
}

// Bus `index`, or main for BUSES.
bus_of :: proc(m: ^Model, index: int) -> ^Bus {
	return &m.project.main if index >= BUSES else &m.project.buses[index]
}

// Changes performance effect `i` (its kind and settings; holding it is
// not an edit), undoably.
set_perf_fx :: proc(m: ^Model, i: int, field: int, name: string, new: Effect_Slot) {
	if i < 0 || i >= PERF_FX do return
	old := m.project.perf_fx[i]
	if old == new do return
	app.set_value(&m.history, name, {app.Id(2000 + i), field}, old, new, proc(ctx: rawptr, k: app.Key, v: Effect_Slot) {
		mm := (^Model)(ctx)
		on := mm.project.perf_fx[int(k.id) - 2000].on
		mm.project.perf_fx[int(k.id) - 2000] = v
		mm.project.perf_fx[int(k.id) - 2000].on = on
		mm.engine.mix_dirty = true
	})
}

// Turns performance effect `i` on or off (while its pad is held, or
// latched). Not an edit.
hold_perf_fx :: proc(m: ^Model, i: int, on: bool) {
	if i < 0 || i >= PERF_FX do return
	m.project.perf_fx[i].on = on
	m.engine.mix_dirty = true
}

// Sets insert `slot` of pad `pad` to `s`, undoably.
set_insert :: proc(m: ^Model, pad, slot: int, s: Effect_Slot, name := "Set Insert") {
	if pad < 0 || pad >= PADS || slot < 0 || slot >= PAD_INSERTS do return
	p := m.project.pads[pad]
	p.inserts[slot] = s
	set_pad(m, pad, .Inserts, name, p)
	app.seal(&m.history) // each its own step (a knob on it: use set_insert_param)
}

// Sets one parameter of insert `slot` of pad `pad` (drags merge into one
// step; seal when the drag ends).
set_insert_param :: proc(m: ^Model, pad, slot: int, id: fc.Param_Id, value: f32) {
	if pad < 0 || pad >= PADS || slot < 0 || slot >= PAD_INSERTS do return
	p := m.project.pads[pad]
	slot_set(&p.inserts[slot], id, value)
	set_pad(m, pad, .Insert_Param, "Set Effect", p)
}

// Sends pad `pad` to bus `bus` (0 = main).
set_pad_bus :: proc(m: ^Model, pad, bus: int) {
	if pad < 0 || pad >= PADS do return
	p := m.project.pads[pad]
	p.bus = u8(clamp(bus, 0, BUSES))
	set_pad(m, pad, .Bus, "Set Output", p)
	app.seal(&m.history)
}

// Which effect slot an editor shows: a pad's insert, a bus's (or main's)
// slot, or a performance effect.
Fx_Target :: struct {
	kind:  Fx_Target_Kind,
	index: int, // the pad, the bus (BUSES = main), or the performance effect
	slot:  int, // insert or bus slot (not used for performance effects)
}

// What an `Fx_Target` points at.
Fx_Target_Kind :: enum u8 {
	None,
	Pad,
	Bus,
	Perf,
}

// The slot `t` points at (a copy), or false.
target_slot :: proc(m: ^Model, t: Fx_Target) -> (Effect_Slot, bool) {
	switch t.kind {
	case .None:
	case .Pad:
		if t.index >= 0 && t.index < PADS && t.slot >= 0 && t.slot < PAD_INSERTS do return m.project.pads[t.index].inserts[t.slot], true
	case .Bus:
		if t.index >= 0 && t.index <= BUSES && t.slot >= 0 && t.slot < BUS_SLOTS do return bus_of(m, t.index).slots[t.slot], true
	case .Perf:
		if t.index >= 0 && t.index < PERF_FX do return m.project.perf_fx[t.index], true
	}
	return {}, false
}

// Puts `s` in the slot `t` points at, as one undo step named `name`.
set_target_slot :: proc(m: ^Model, t: Fx_Target, s: Effect_Slot, name: string) {
	switch t.kind {
	case .None:
	case .Pad:  set_insert(m, t.index, t.slot, s, name)
	case .Bus:
		b := bus_of(m, t.index)^
		b.slots[t.slot] = s
		set_bus(m, t.index, 100 + t.slot, name, b)
		app.seal(&m.history)
	case .Perf:
		set_perf_fx(m, t.index, 100, name, s)
		app.seal(&m.history)
	}
}

// Sets parameter `id` of the slot `t` points at (drags merge: seal when
// one ends).
set_target_param :: proc(m: ^Model, t: Fx_Target, id: fc.Param_Id, value: f32) {
	s, ok := target_slot(m, t)
	if !ok do return
	slot_set(&s, id, value)
	switch t.kind {
	case .None:
	case .Pad: set_insert_param(m, t.index, t.slot, id, value)
	case .Bus:
		b := bus_of(m, t.index)^
		b.slots[t.slot] = s
		set_bus(m, t.index, 200 + t.slot * 64 + int(id) % 64, "Set Effect", b)
	case .Perf:
		set_perf_fx(m, t.index, 200 + int(id) % 64, "Set Effect", s)
	}
}
