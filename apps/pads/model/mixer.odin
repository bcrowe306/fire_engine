package pads_model

import "core:math"
import "core:strings"


import app "app:core"
import fc "fire:core"
import fx_pkg "fire:fx"
import "fire:synth"
import "fire:dsp"

// Insert slots on each pad.
PAD_INSERTS :: 2
// Effect slots on each bus and on main.
BUS_SLOTS :: 5
// Buses a project can have (A to P; `Project.bus_count` of them are in
// use): a pad goes to one, or straight to main, and sends to any. Index
// BUSES stands for main where a bus index is taken.
BUSES :: 16
// Buses a new project has.
DEFAULT_BUSES :: 4
// Performance effects (applied to main while held).
PERF_FX :: 16
// Parameters an effect slot keeps.
MAX_EFFECT_PARAMS :: 24

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
	Distortion, // the synth's (as are Compressor, Delay, Reverb, Chorus, Flanger, Phaser: see `synth_twin`)
	Eq,
	Filter,
}

// Effect names, as the UI shows them.
EFFECT_NAMES := [Effect_Kind]cstring{
	.None = "Empty", .Low_Pass = "Low-pass", .High_Pass = "High-pass", .Band_Pass = "Band-pass",
	.Compressor = "Compressor", .Gate = "Gate", .Limiter = "Limiter", .Saturation = "Saturation", .Bitcrush = "Bit-crusher",
	.Delay = "Delay", .Reverb = "Reverb", .Chorus = "Chorus", .Flanger = "Flanger", .Phaser = "Phaser",
	.Ring_Mod = "Ring mod", .Comb = "Comb", .Pitch = "Pitch shift", .Cutter = "Cutter", .Stutter = "Stutter", .Plugin = "Plug-in",
	.Distortion = "Distortion", .Eq = "EQ", .Filter = "Filter",
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
	state:       string, // .Plugin: its saved state (bytes, interned), put back when it loads
	key:         Key_Source, // .Compressor, .Gate: what it listens to (none: itself)
	key_hpf:     f32,  // Hz: the key's high-pass (0: none)
	listen:      bool, // the track hears the key (filtered) instead, to set it by
}

// Where a sidechain key comes from: a pad's or a bus's output (after its
// fader).
Key_Source :: struct {
	kind:  Key_Kind,
	index: int, // the pad (0..), or the bus (0..BUSES-1)
}

// What a key is.
Key_Kind :: enum u8 {
	None,
	Pad,
	Bus,
}

// Whether a slot's effect can be keyed.
keyable :: proc "contextless" (k: Effect_Kind) -> bool {
	return k == .Compressor || k == .Gate
}

// Whether the slot `t` points at can be keyed from `src` without a loop:
// another pad's output (never its own), or a bus its track doesn't feed
// (by its route, its sends, or the buses after them).
key_allowed :: proc(p: ^Project, t: Fx_Target, src: Key_Source) -> bool {
	switch src.kind {
	case .None: return true
	case .Pad:
		if src.index < 0 || src.index >= PADS do return false
		return !(t.kind == .Pad && t.index == src.index) && (t.kind == .Pad || t.kind == .Bus)
	case .Bus:
		b := src.index + 1 // (1-based, as routes are)
		if src.index < 0 || src.index >= p.bus_count do return false
		#partial switch t.kind {
		case .Pad:
			pad := &p.pads[t.index]
			if bus_reaches(p, int(pad.bus), b) do return false
			for sd, k in pad.sends do if sd.level > 0 && bus_reaches(p, k + 1, b) do return false
			return true
		case .Bus:
			if t.index == BUSES do return true // (main feeds nothing)
			return !bus_reaches(p, t.index + 1, b)
		}
	}
	return false
}

// Whether bus `from` (1-based; 0 = main) is bus `b` or goes through it.
@(private)
bus_reaches :: proc(p: ^Project, from, b: int) -> bool {
	at := from
	for _ in 0 ..= BUSES {
		if at == 0 do return false
		if at == b do return true
		if at < 1 || at > BUSES do return false
		at = int(p.buses[at - 1].dest)
	}
	return false
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
	if e, ok := synth_twin(k); ok do return synth.effect_node_params(e)
	#partial switch k {
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

// A slot holding a new `kind` effect at its defaults, on (one of the
// app's old kinds: the synth effect it became, set as it was).
new_effect :: proc(kind: Effect_Kind) -> Effect_Slot {
	s := Effect_Slot{kind = kind, on = kind != .None}
	for p in effect_params(kind) do slot_set(&s, p.id, f32(p.default))
	#partial switch kind {
	case .Low_Pass:  slot_set(&s, dsp.FILTER_PARAM_CUTOFF_HZ, 900)
	case .High_Pass: slot_set(&s, dsp.FILTER_PARAM_CUTOFF_HZ, 1200)
	case .Band_Pass: slot_set(&s, dsp.FILTER_PARAM_CUTOFF_HZ, 1000); slot_set(&s, dsp.FILTER_PARAM_Q, 2)
	}
	if effect_kind_legacy(kind) do return convert_slot(s)
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

// A bus (A to P) or main: its effects, then its fader, into its
// destination.
Bus :: struct {
	volume: f32, // dB
	pan:    f32, // -1..1
	mute:   bool,
	solo:   bool,
	slots:  [BUS_SLOTS]Effect_Slot,
	name:   [16]u8, // "" = "Bus A"...
	dest:   u8,     // where it goes: 0 = main, 1..BUSES = another bus (never round to itself)
	group:  bool,   // a group: the pads going to it show with it in the mixer
	folded: bool,   // a group whose pads' strips are hidden
}

// The name of where sound goes: 0 = "Main", 1..BUSES = a bus (its own
// name, else "Bus A"...).
bus_name :: proc(p: ^Project, b: int) -> string {
	if b <= 0 || b > BUSES do return "Main"
	if n := strings.truncate_to_byte(string(p.buses[b - 1].name[:]), 0); n != "" do return n
	letters := "ABCDEFGHIJKLMNOP"
	return strings.concatenate({"Bus ", letters[b - 1:][:1]}, context.temp_allocator)
}

// The name of bus index `index` as the mixer counts them (0..BUSES-1, or
// BUSES: main).
bus_index_name :: proc(p: ^Project, index: int) -> string {
	return bus_name(p, 0 if index >= BUSES else index + 1)
}

// Whether bus `b` (1..BUSES) may go to `dest` (0 = main, 1..BUSES): never
// round to itself, through other buses or directly.
bus_dest_ok :: proc(p: ^Project, b, dest: int) -> bool {
	if dest == 0 do return true
	if dest < 1 || dest > p.bus_count || dest == b do return false
	at := dest
	for _ in 0 ..< BUSES { // follow where dest goes
		if at == 0 do return true
		if at == b do return false
		at = int(p.buses[at - 1].dest)
	}
	return false
}

// Sends bus `b` (1..BUSES) to `dest` (0 = main, or another bus), undoably;
// false (and nothing changes) if that would go round in a loop.
set_bus_dest :: proc(m: ^Model, b, dest: int) -> bool {
	p := &m.project
	if b < 1 || b > p.bus_count || !bus_dest_ok(p, b, dest) do return false
	nb := p.buses[b - 1]
	nb.dest = u8(dest)
	set_bus(m, b - 1, 3, "Route Bus", nb)
	app.seal(&m.history)
	return true
}

// Renames bus `b` (1..BUSES); "" gives it its letter name back.
rename_bus :: proc(m: ^Model, b: int, name: string) {
	p := &m.project
	if b < 1 || b > p.bus_count do return
	nb := p.buses[b - 1]
	nb.name = {}
	copy(nb.name[:len(nb.name) - 1], strings.trim_space(name))
	set_bus(m, b - 1, 4, "Rename Bus", nb)
	app.seal(&m.history)
}

// Adds a bus (after the others), going to main. Returns it (1..BUSES), or
// 0 when there are BUSES already.
add_bus :: proc(m: ^Model) -> int {
	p := &m.project
	if p.bus_count >= BUSES do return 0
	b := p.bus_count + 1
	app.begin(&m.history, "Add Bus")
	defer app.end(&m.history)
	set_bus(m, b - 1, 5, "Add Bus", Bus{})
	set_bus_count(m, b)
	return b
}

// Deletes bus `b` (1..BUSES; not the last one left): pads going to it go
// to main, their sends to it go, buses going to it go to main; the buses
// after it move up a letter (and what goes to them follows). One undo step.
delete_bus :: proc(m: ^Model, b: int) {
	p := &m.project
	n := p.bus_count
	if b < 1 || b > n || n <= 1 do return
	app.begin(&m.history, "Delete Bus")
	defer app.end(&m.history)
	after :: proc(x, b: int) -> int { // where bus x (1..) is once b is gone (0: main)
		if x == b do return 0
		return x - 1 if x > b else x
	}
	for i in 0 ..< PADS {
		pad := p.pads[i]
		np := pad
		np.bus = u8(after(int(pad.bus), b))
		for k in b - 1 ..< BUSES - 1 do np.sends[k] = pad.sends[k + 1]
		np.sends[BUSES - 1] = {}
		if np != pad do set_pad(m, i, .Whole, "Delete Bus", np)
	}
	buses := p.buses
	for k in b - 1 ..< n - 1 do buses[k] = p.buses[k + 1]
	buses[n - 1] = {}
	for k in 0 ..< n - 1 do buses[k].dest = u8(after(int(buses[k].dest), b))
	for k in 0 ..< n do if buses[k] != p.buses[k] do set_bus(m, k, 5, "Delete Bus", buses[k])
	set_bus_count(m, n - 1)
}

// Sets how many buses are in use, undoably.
@(private)
set_bus_count :: proc(m: ^Model, n: int) {
	old := m.project.bus_count
	app.set_value(&m.history, "Buses", {app.Id(BUS_COUNT_KEY), 0}, old, clamp(n, 1, BUSES), proc(ctx: rawptr, k: app.Key, v: int) {
		mm := (^Model)(ctx)
		mm.project.bus_count = v
		mm.engine.mix_dirty = true
	})
}

@(private)
BUS_COUNT_KEY :: 1 << 23

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
	f :: synth.Fx_Filter_Field
	slot_set(&fx[0], synth.effect_param(.Filter, f.Cutoff), hz_key(500))
	slot_set(&fx[1], synth.effect_param(.Filter, f.Cutoff), hz_key(2000))
	slot_set(&fx[4], dsp.STUTTER_PARAM_BEATS, 0.5)
	slot_set(&fx[5], dsp.STUTTER_PARAM_BEATS, 0.25)
	slot_set(&fx[6], dsp.STUTTER_PARAM_BEATS, 0.125)
	slot_set(&fx[7], dsp.CUTTER_PARAM_BEATS, 0.5)
	slot_set(&fx[8], dsp.CUTTER_PARAM_BEATS, 0.25)
	slot_set(&fx[11], dsp.PITCH_PARAM_SEMITONES, 12)
	slot_set(&fx[12], dsp.PITCH_PARAM_SEMITONES, -12)
	slot_set(&fx[13], synth.effect_param(.Delay, synth.Delay_Field.Sync), f32(fx_pkg.Sync.Tempo))
	slot_set(&fx[13], synth.effect_param(.Delay, synth.Delay_Field.Wet), 0.5)
	slot_set(&fx[14], synth.effect_param(.Reverb, synth.Reverb_Field.Wet), 0.5)
	slot_set(&fx[15], synth.effect_param(.Distortion, synth.Distortion_Field.Drive), 18)
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
	case .Filter:
		b := slot_value(s, synth.effect_param(.Filter, synth.Fx_Filter_Field.Blend), 0)
		return "Low-pass" if b < 0.5 else ("High-pass" if b > 1.5 else "Band-pass")
	case .Distortion:
		if fx_pkg.Distortion_Type(int(slot_value(s, synth.effect_param(.Distortion, synth.Distortion_Field.Type), 0))) == .Bit_Crush do return "Bit-crusher"
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

// Bus `index` (0..BUSES-1), or main for BUSES.
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
hold_perf_fx :: proc(m: ^Model, i: int, on: bool, intensity: f32 = -1) {
	if i < 0 || i >= PERF_FX do return
	m.project.perf_fx[i].on = on
	m.engine.perf_live[i] = intensity if on else -1
	m.engine.mix_dirty = true
}

// While performance effect `i` is held: how hard (0..1; where its pad is
// pressed), moving as the press does.
perf_intensity_live :: proc(m: ^Model, i: int, intensity: f32) {
	if i < 0 || i >= PERF_FX || !m.project.perf_fx[i].on do return
	x := clamp(intensity, 0, 1)
	if m.engine.perf_live[i] == x do return
	m.engine.perf_live[i] = x
	m.engine.mix_dirty = true
}

// Sets performance effect `i`'s own intensity (0..1), undoably: what it
// plays at when its pad's press doesn't say.
set_perf_intensity :: proc(m: ^Model, i: int, x: f32) {
	if i < 0 || i >= PERF_FX do return
	app.set_value(&m.history, "Effect Intensity", {app.Id(PERF_INTENSITY_KEY + i), 0}, m.project.perf_intensity[i], clamp(x, 0, 1), proc(ctx: rawptr, key: app.Key, v: f32) {
		m := (^Model)(ctx)
		m.project.perf_intensity[int(key.id) - PERF_INTENSITY_KEY] = v
		m.engine.mix_dirty = true
	})
}

@(private)
PERF_INTENSITY_KEY :: 1 << 21

// A pad's send to a bus: how much of its sound also goes there, from
// before its fader (`pre`: the fader doesn't change it) or after.
Send :: struct {
	level: f32, // linear gain: 0 = off, 1 = 0 dB, up to SEND_MAX
	pre:   bool,
}

// The most a send can be (+6 dB).
SEND_MAX :: 2
// A send's knob runs from this (where it is off) to +6 dB.
SEND_MIN_DB :: -60

// A send's level in dB (SEND_MIN_DB or less: off).
send_db :: proc(s: Send) -> f32 {
	if s.level <= 0 do return SEND_MIN_DB
	return max(20 * math.log10(s.level), SEND_MIN_DB)
}

// A send's level for `db` (off at SEND_MIN_DB and below).
send_level :: proc(db: f32) -> f32 {
	if db <= SEND_MIN_DB do return 0
	return min(math.pow(10, db / 20), SEND_MAX)
}

// Sets pad `pad`'s send to bus `bus` (1..BUSES) to `db` (drags merge into
// one step; seal when the drag ends).
set_send_db :: proc(m: ^Model, pad, bus: int, db: f32) {
	if pad < 0 || pad >= PADS || bus < 1 || bus > BUSES do return
	p := m.project.pads[pad]
	p.sends[bus - 1].level = send_level(db)
	set_pad(m, pad, Pad_Field(int(Pad_Field.Send_0) + bus - 1), "Set Send", p)
}

// Takes pad `pad`'s send to bus `bus` from before its fader (`pre`) or
// after.
set_send_pre :: proc(m: ^Model, pad, bus: int, pre: bool) {
	if pad < 0 || pad >= PADS || bus < 1 || bus > BUSES do return
	p := m.project.pads[pad]
	if p.sends[bus - 1].pre == pre do return
	p.sends[bus - 1].pre = pre
	set_pad(m, pad, .Send_Pre, "Pre-fader Send" if pre else "Post-fader Send", p)
	app.seal(&m.history)
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
	p.bus = u8(clamp(bus, 0, m.project.bus_count))
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
	Instrument, // a plug-in pad's instrument (`index` the pad; no slot)
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
	case .Instrument:
		if t.index >= 0 && t.index < PADS do return m.project.pads[t.index].instrument, true
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
	case .Instrument:
		set_instrument(m, t.index, s, name)
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
	case .Instrument:
		set_instrument_param(m, t.index, id, value)
	}
}
