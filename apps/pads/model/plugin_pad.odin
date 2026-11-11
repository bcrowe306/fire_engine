package pads_model

import "fire:clap"
import fc "fire:core"
import "fire:graph"

import app "app:core"

// Plug-in pads: a CLAP instrument as a pad's device. The pad keeps it as
// an `Effect_Slot` (the plug-in's file, its id, the parameters set from
// Pads, and its state), plays it chromatically like a synth, and gives it
// eight automation lanes, each moving a parameter chosen for it.

// Automation lanes a plug-in pad has for its parameters.
PLUGIN_LANES :: 8

// What a plug-in pad's lane moves: a parameter and its range (as it was
// when the lane was given it).
Plugin_Lane :: struct {
	id:     fc.Param_Id, // 0: none
	lo, hi: f32,
}

// Makes pad `index` a plug-in pad playing plug-in `id` of the CLAP library
// at `path`: one undo step.
make_plugin_pad :: proc(m: ^Model, index: int, path, id, name: string) {
	if index < 0 || index >= PADS do return
	pad := m.project.pads[index]
	if !pad_used(&m.project, index) {
		pad = default_pad()
		set_pad_name(&pad, name)
	}
	pad.kind = .Plugin
	pad.instrument = new_plugin_effect(&m.project, path, id, name)
	pad.plugin_lanes = {}
	set_pad(m, index, .Whole, "Plug-in Instrument", pad)
	app.seal(&m.history)
}

// Puts `s` as pad `index`'s instrument: one undo step named `name`.
set_instrument :: proc(m: ^Model, index: int, s: Effect_Slot, name: string) {
	if index < 0 || index >= PADS do return
	pad := m.project.pads[index]
	pad.instrument = s
	set_pad(m, index, .Instrument, name, pad)
	app.seal(&m.history)
}

// Sets parameter `id` of pad `index`'s instrument (drags merge: seal when
// one ends).
set_instrument_param :: proc(m: ^Model, index: int, id: fc.Param_Id, value: f32) {
	if index < 0 || index >= PADS do return
	pad := m.project.pads[index]
	slot_set(&pad.instrument, id, value)
	set_pad(m, index, .Instrument_Param, "Set Parameter", pad)
}

// Gives pad `index`'s lane `lane` (0..PLUGIN_LANES-1) parameter `p` to
// move (`p.id` 0: none): one undo step.
set_plugin_lane :: proc(m: ^Model, index, lane: int, p: fc.Param_Info) {
	if index < 0 || index >= PADS || lane < 0 || lane >= PLUGIN_LANES do return
	pad := m.project.pads[index]
	pad.plugin_lanes[lane] = {p.id, f32(p.min), f32(p.max)} if p.id != 0 else {}
	set_pad(m, index, .Plugin_Lanes, "Automate Parameter", pad)
	app.seal(&m.history)
}

// The lane of pad `index` that moves parameter `id`, or -1.
plugin_lane_of :: proc(p: ^Project, index: int, id: fc.Param_Id) -> int {
	if index < 0 || index >= PADS || id == 0 do return -1
	for l, k in p.pads[index].plugin_lanes do if l.id == id do return k
	return -1
}

// The plug-in pad `index` plays, once loaded (nil if none or it would not).
pad_plugin :: proc(e: ^Engine, index: int) -> ^clap.Plugin {
	if index < 0 || index >= PADS do return nil
	return e.nodes[index].inst.plugin
}

// Whether pad `index`'s plug-in would not load.
pad_plugin_failed :: proc(e: ^Engine, index: int) -> bool {
	if index < 0 || index >= PADS do return false
	return e.nodes[index].inst.failed
}

// Every loaded plug-in's state (instruments, pad inserts, bus slots) put
// in the project, for a save. Not an undo step: the state is the
// plug-in's own, which the project only keeps.
capture_plugin_states :: proc(m: ^Model) {
	e := &m.engine
	p := &m.project
	keep :: proc(p: ^Project, f: ^Fx_Node, s: ^Effect_Slot) {
		if f.plugin == nil || s.kind != .Plugin || f.key != key_of(s^) do return
		data, err := clap.plugin_save_state(f.plugin, context.temp_allocator)
		if err != .None do return
		s.state = intern(p, string(data))
	}
	for i in 0 ..< PADS {
		keep(p, &e.nodes[i].inst, &p.pads[i].instrument)
		for k in 0 ..< PAD_INSERTS do keep(p, &e.mixer.strips[i].inserts[k], &p.pads[i].inserts[k])
	}
	for b in 0 ..= BUSES {
		bus := bus_of(m, b)
		for k in 0 ..< BUS_SLOTS do keep(p, &e.mixer.buses[b].slots[k], &bus.slots[k])
	}
}

// [control] A plug-in's node, with its saved state put back.
@(private)
plugin_node :: proc(e: ^Engine, s: Effect_Slot) -> (node: fc.Node, plugin: ^clap.Plugin, ok: bool) {
	lib, err := clap.library_open(s.plugin_path)
	if err != .None do return {}, nil, false
	n, p, perr := clap.plugin_create(lib, s.plugin_id, {timeline = e.timeline})
	clap.library_close(lib) // the plug-in keeps the library open
	if perr != .None do return {}, nil, false
	if s.state != "" do _ = clap.plugin_load_state(p, transmute([]u8)s.state)
	return n, p, true
}

// [control] Sends the instrument's parameters that changed.
@(private)
apply_instrument :: proc(g: ^graph.Graph, f: ^Fx_Node, s: Effect_Slot, fresh: bool) {
	if !f.has do return
	s := s
	for p in s.params[:s.count] {
		if fresh || slot_value(f.applied, p.id, max(f32)) != p.value do graph.set_param(g, f.id, p.id, f64(p.value))
	}
	reset_dropped(g, f, s)
	f.applied = s
}

// [control] A parameter the slot had and no longer sets (an undo) goes
// back to its default.
@(private)
reset_dropped :: proc(g: ^graph.Graph, f: ^Fx_Node, s: Effect_Slot) {
	old := f.applied
	for p in old.params[:old.count] {
		if slot_value(s, p.id, max(f32)) != max(f32) do continue
		n := graph.get_node(g, f.id)
		if n == nil do return
		for info in fc.node_params(n) do if info.id == p.id do graph.set_param(g, f.id, p.id, info.default)
	}
}

// Editor requests kept a frame.
MAX_GUI_REQUESTS :: 16

// What a plug-in's editor asked for (a size, or it closed itself).
Gui_Request :: struct {
	plugin:   ^clap.Plugin,
	requests: clap.Requests,
}

// This frame's editor requests (from `plugins_idle`).
plugin_gui_requests :: proc(e: ^Engine) -> []Gui_Request {
	return e.gui_requests[:e.gui_request_count]
}

// Each frame (main thread): every loaded plug-in's main-thread callbacks
// and requests. One that asks to restart is made again (its state kept);
// a latency change goes into the graph; its editor's requests are kept
// for the UI (`plugin_gui_requests`).
plugins_idle :: proc(m: ^Model) {
	e := &m.engine
	e.gui_request_count = 0
	restart, latency := false, false
	visit :: proc(e: ^Engine, f: ^Fx_Node, restart, latency: ^bool) -> bool {
		if f.plugin == nil do return false
		r := clap.plugin_idle(f.plugin)
		if (r.gui_resize || r.gui_closed) && e.gui_request_count < MAX_GUI_REQUESTS {
			e.gui_requests[e.gui_request_count] = {f.plugin, r}
			e.gui_request_count += 1
		}
		latency^ ||= r.latency
		restart^ ||= r.restart
		return r.restart
	}
	again: [PADS]bool
	slots := make([dynamic]^Fx_Node, context.temp_allocator)
	for i in 0 ..< PADS {
		again[i] = visit(e, &e.nodes[i].inst, &restart, &latency)
		for &f in e.mixer.strips[i].inserts do if visit(e, &f, &restart, &latency) do append(&slots, &f)
	}
	for &b in e.mixer.buses do for &f in b.slots do if visit(e, &f, &restart, &latency) do append(&slots, &f)
	if restart {
		capture_plugin_states(m) // (what it has now comes back)
		for i in 0 ..< PADS do if again[i] {
			e.nodes[i].inst.key = {} // (sync builds it again)
			e.dirty[i] = true
		}
		for f in slots do f.key = {}
	}
	if latency && !restart do graph.commit(e.host.graph)
}
