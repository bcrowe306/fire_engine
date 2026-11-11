package pads_model

import "core:strings"

import app "app:core"
import fc "fire:core"
import "fire:fx"
import "fire:synth"

// The synth device: a pad playing `fire:synth` (see docs/design/synth.md).
// Its sound is a `Synth_Patch`: every synth parameter's plain value, the
// modulation routes, the LFO shapes, and which wavetables and sample its
// oscillators play.

// A wavetable (or the sample oscillator's sound): built in, or a sample
// of the project's (a WAV of 2048-sample frames for a table; any sound for
// the sample oscillator).
Synth_Source :: struct {
	builtin: u8,     // a `synth.Builtin_Table` (or `synth.Builtin_Noise`)
	sample:  app.Id, // the project's sample, when not 0
	table:   app.Id, // the project's own wavetable (the editor's), when not 0
}

// A synth pad's sound.
Synth_Patch :: struct {
	set:         bool, // made (a pad that never was a synth has none yet)
	values:      [synth.PARAM_SLOTS]f32, // by parameter id
	routes:      [synth.MAX_ROUTES]synth.Route,
	route_count: int,
	shapes:      [synth.LFOS]synth.Lfo_Shape,
	tables:      [synth.OSCS]Synth_Source,
	sample:      Synth_Source,
	macro_names: [synth.MACROS][16]u8,
	fx_order:    [len(fx.Effect)]fx.Effect, // the effects' order
}

// The patch a new synth starts with: every parameter at its default (a
// saw on oscillator 1 into filter 1, the amp envelope on it), triangle
// LFOs.
default_synth_patch :: proc() -> (p: Synth_Patch) {
	p.set = true
	for spec in synth.PARAMS do p.values[spec.id] = spec.default
	for &s in p.shapes do s = synth.lfo_preset(.Triangle)
	p.tables = {{builtin = u8(synth.Builtin_Table.Saw)}, {builtin = u8(synth.Builtin_Table.Basic_Shapes)}, {builtin = u8(synth.Builtin_Table.Basic_Shapes)}}
	p.sample = {builtin = u8(synth.Builtin_Noise.White)}
	names := [synth.MACROS]string{"Macro 1", "Macro 2", "Macro 3", "Macro 4"}
	for &n, k in p.macro_names do copy(n[:], names[k])
	p.fx_order = fx.CHAIN_ORDER
	return
}

// Makes pad `index` a synth (its patch as it was if it was one before,
// else the default), named "Synth" if it had no sound.
make_synth :: proc(m: ^Model, index: int) {
	pad := m.project.pads[index]
	if !pad_used(&m.project, index) {
		pad = default_pad()
		set_pad_name(&pad, "Synth")
	}
	pad.kind = .Synth
	if !pad.synth.set do pad.synth = default_synth_patch()
	set_pad(m, index, .Whole, "Synth", pad)
	app.seal(&m.history)
}

// Pad `index`'s synth parameter `id` set to `v` (its plain value, clamped
// to its range); drags (one name) merge into one undo step.
set_synth_value :: proc(m: ^Model, index: int, id: fc.Param_Id, v: f32, name: string) {
	spec := synth.param_spec(id)
	if spec == nil do return
	pad := m.project.pads[index]
	pad.synth.values[id] = clamp(v, spec.min, spec.max)
	set_pad(m, index, .Synth, name, pad)
}

// A synth parameter's plain value on pad `index`.
synth_value :: proc(m: ^Model, index: int, id: fc.Param_Id) -> f32 {
	return m.project.pads[index].synth.values[id]
}

// Adds route `r` to pad `index`'s synth (or, if one already joins the
// same source to the same parameter, changes that one): its index, or
// -1 when it has as many as it can.
add_synth_route :: proc(m: ^Model, index: int, r: synth.Route) -> int {
	pad := m.project.pads[index]
	s := &pad.synth
	k := -1
	for x, i in s.routes[:s.route_count] do if x.source == r.source && x.dest == r.dest do k = i
	if k < 0 {
		if s.route_count >= synth.MAX_ROUTES do return -1
		k = s.route_count
		s.route_count += 1
	}
	s.routes[k] = r
	set_pad(m, index, .Synth, "Add Modulation", pad)
	app.seal(&m.history)
	return k
}

// Route `k` of pad `index`'s synth changed (drags merge).
set_synth_route :: proc(m: ^Model, index: int, k: int, r: synth.Route, name := "Modulation") {
	pad := m.project.pads[index]
	if k < 0 || k >= pad.synth.route_count do return
	pad.synth.routes[k] = r
	set_pad(m, index, .Synth, name, pad)
}

// Takes route `k` off pad `index`'s synth.
remove_synth_route :: proc(m: ^Model, index: int, k: int) {
	pad := m.project.pads[index]
	s := &pad.synth
	if k < 0 || k >= s.route_count do return
	copy(s.routes[k:s.route_count - 1], s.routes[k + 1:s.route_count])
	s.route_count -= 1
	s.routes[s.route_count] = {}
	set_pad(m, index, .Synth, "Remove Modulation", pad)
	app.seal(&m.history)
}

// The routes on pad `index`'s synth that move parameter `id`.
synth_routes_to :: proc(m: ^Model, index: int, id: fc.Param_Id, allocator := context.temp_allocator) -> []int {
	s := &m.project.pads[index].synth
	out := make([dynamic]int, allocator)
	for r, k in s.routes[:s.route_count] do if r.dest == id do append(&out, k)
	return out[:]
}

// LFO `n`'s (0-based) shape on pad `index` set (drags of its points merge).
set_synth_shape :: proc(m: ^Model, index: int, n: int, shape: synth.Lfo_Shape, name := "LFO Shape") {
	pad := m.project.pads[index]
	pad.synth.shapes[n] = shape
	set_pad(m, index, .Synth, name, pad)
}

// Oscillator `n`'s (0-based) wavetable on pad `index`.
set_synth_table :: proc(m: ^Model, index: int, n: int, src: Synth_Source) {
	pad := m.project.pads[index]
	pad.synth.tables[n] = src
	set_pad(m, index, .Synth, "Wavetable", pad)
	app.seal(&m.history)
}

// The sample oscillator's sound on pad `index`.
set_synth_sample :: proc(m: ^Model, index: int, src: Synth_Source) {
	pad := m.project.pads[index]
	pad.synth.sample = src
	set_pad(m, index, .Synth, "Sample", pad)
	app.seal(&m.history)
}

// Macro `n`'s (0-based) name on pad `index`.
set_synth_macro_name :: proc(m: ^Model, index: int, n: int, name: string) {
	pad := m.project.pads[index]
	buf := &pad.synth.macro_names[n]
	buf^ = {}
	copy(buf[:len(buf) - 1], name)
	set_pad(m, index, .Synth, "Rename Macro", pad)
	app.seal(&m.history)
}

// Pad `index`'s effect `e` moved to place `to` in its chain (the rest
// keep their order).
move_synth_effect :: proc(m: ^Model, index: int, e: fx.Effect, to: int) {
	pad := m.project.pads[index]
	order := &pad.synth.fx_order
	from := -1
	for x, k in order do if x == e do from = k
	t := clamp(to, 0, len(order) - 1)
	if from < 0 || from == t do return
	if from < t {
		for k in from ..< t do order[k] = order[k + 1]
	} else {
		for k := from; k > t; k -= 1 do order[k] = order[k - 1]
	}
	order[t] = e
	set_pad(m, index, .Synth, "Reorder Effects", pad)
	app.seal(&m.history)
}

// Macro `n`'s name on pad `index`.
synth_macro_name :: proc(m: ^Model, index: int, n: int) -> string {
	b := &m.project.pads[index].synth.macro_names[n]
	return strings.truncate_to_byte(string(b[:]), 0)
}

// The name of a wavetable choice (a built-in's, or the sample's).
synth_source_name :: proc(m: ^Model, src: Synth_Source, noise := false) -> string {
	if src.table != 0 {
		if app.store_get(&m.project.wave_docs, src.table) != nil do return wave_doc_name(m, src.table)
		return "(missing)"
	}
	if src.sample != 0 {
		if s := app.store_get(&m.project.samples, src.sample); s != nil do return s.name
		return "(missing)"
	}
	if noise do return synth.BUILTIN_NOISE_NAMES[synth.Builtin_Noise(min(src.builtin, u8(max(synth.Builtin_Noise))))]
	return synth.BUILTIN_NAMES[synth.Builtin_Table(min(src.builtin, u8(max(synth.Builtin_Table))))]
}
