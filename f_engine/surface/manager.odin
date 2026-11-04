package surface

import "base:runtime"
import "core:dynlib"
import "core:mem"
import "core:strings"

import "fire:core"
import "fire:graph"
import "fire:midi"
import tb "fire:timebase"
import "fire:transport"

// Settings for `manager_create`.
Manager_Settings :: struct {
	clock:    ^transport.Clock, // the transport surfaces drive and see
	timeline: core.Timeline_Id, // which timeline (the song); zero = no transport
	graph:    ^graph.Graph,     // for `param_set` on named nodes; nil = none
	// MIDI to a controller: `port` is the surface's `Ports.midi_out`.
	midi_out: proc(user: rawptr, port: int, bytes: []u8) -> bool,
	// A surface moved a control: apply it (then report it with `control_changed`).
	on_set:   proc(user: rawptr, id: u32, value: f64),
	// A surface started or ended a gesture on a control.
	on_touch: proc(user: rawptr, id: u32, touched: bool),
	log:      proc(user: rawptr, level: i32, message: string),
	user:     rawptr,
	midi:     midi.Input_Config, // the controllers' MIDI input; zero = defaults
}

// Hosts control-surface scripts. Control thread only. Fields are internal.
Manager :: struct {
	settings:  Manager_Settings,
	allocator: mem.Allocator,
	input:     midi.Midi_Input,
	libraries: [dynamic]^Library,
	surfaces:  [dynamic]^Instance,
	controls:  [dynamic]Control,
	nodes:     [dynamic]Named_Node,
	changed:   [dynamic]Change, // control changes not yet told to the surfaces
	controls_changed: bool,
	last:      Transport_State, // what the surfaces were last told
	told:      bool,
}

// A loaded script library and the surfaces it offers. Fields other than
// `path` and `surfaces` are internal.
Library :: struct {
	path:     string,
	surfaces: []^Descriptor,
	lib:      dynlib.Library,
	refs:     int,
}

// Which MIDI ports a surface uses: the port index the controller's input
// was opened with (on the driver whose `input` is `manager_midi_input`),
// and the app's number for its output (given back to `midi_out`).
Ports :: struct {
	midi_in:  u8,
	midi_out: int,
}

// A running surface. From `surface_start`; stop with `surface_stop`.
// Fields are internal.
Instance :: struct {
	manager:  ^Manager,
	library:  ^Library,
	surface:  ^Surface,
	host:     Host,
	ports:    Ports,
	touched:  [dynamic]u32, // controls this surface is touching
}

@(private)
Control :: struct {
	info:  Control_Info,
	name:  cstring, // owned
	group: cstring,
	value: f64,
}

@(private)
Named_Node :: struct {
	name: string,
	id:   graph.Node_Id,
}

@(private)
Change :: struct {
	id:    u32,
	value: f64,
	from:  ^Instance, // the surface that set it, which needn't be told
}

// Control thread. Makes a manager. Free with `manager_destroy`.
manager_create :: proc(settings: Manager_Settings, allocator := context.allocator) -> (m: ^Manager, err: core.Error) {
	m = new(Manager, allocator)
	if m == nil do return nil, .Out_Of_Memory
	m.settings, m.allocator = settings, allocator
	if midi.input_init(&m.input, settings.midi, allocator) != nil {
		free(m, allocator)
		return nil, .Out_Of_Memory
	}
	m.libraries = make([dynamic]^Library, allocator)
	m.surfaces = make([dynamic]^Instance, allocator)
	m.controls = make([dynamic]Control, allocator)
	m.nodes = make([dynamic]Named_Node, allocator)
	m.changed = make([dynamic]Change, allocator)
	return m, .None
}

// Control thread. Stops every surface, closes the libraries, frees the manager.
manager_destroy :: proc(m: ^Manager) {
	if m == nil do return
	for len(m.surfaces) > 0 do surface_stop(m, m.surfaces[len(m.surfaces) - 1])
	for len(m.libraries) > 0 do library_close(m, m.libraries[0])
	for c in m.controls {
		delete(c.name, m.allocator)
		delete(c.group, m.allocator)
	}
	for n in m.nodes do delete(n.name, m.allocator)
	delete(m.controls)
	delete(m.nodes)
	delete(m.changed)
	delete(m.libraries)
	delete(m.surfaces)
	midi.input_destroy(&m.input, m.allocator)
	free(m, m.allocator)
}

// The input to give a MIDI driver for the controllers' ports (set it as
// the driver's `input` before opening them). Use a driver of its own, so
// controller MIDI stays out of the audio thread's input.
manager_midi_input :: proc(m: ^Manager) -> ^midi.Midi_Input {
	return &m.input
}

// --- libraries -----------------------------------------------------------------------------

// Control thread. Loads a script library (or returns the one already
// loaded from `path`). `.Device_Error` if it won't load, doesn't export
// `fire_surface_entry`, or has another ABI version.
library_open :: proc(m: ^Manager, path: string) -> (l: ^Library, err: core.Error) {
	for x in m.libraries do if x.path == path {
		x.refs += 1
		return x, .None
	}
	lib, ok := dynlib.load_library(path)
	if !ok do return nil, .Device_Error
	entry := Entry_Proc(dynlib.symbol_address(lib, ENTRY_SYMBOL))
	if entry == nil {
		dynlib.unload_library(lib)
		return nil, .Device_Error
	}
	list := make([dynamic]^Descriptor, m.allocator)
	for i: u32 = 0; i < 1024; i += 1 {
		d := entry(i)
		if d == nil do break
		if d.abi_version == ABI_VERSION && d.create != nil do append(&list, d)
	}
	l = new(Library, m.allocator)
	l^ = {path = strings.clone(path, m.allocator), surfaces = list[:], lib = lib, refs = 1}
	append(&m.libraries, l)
	return l, .None
}

// Control thread. Drops a reference; the last, with no surface running
// from it, unloads it.
library_close :: proc(m: ^Manager, l: ^Library) {
	l.refs -= 1
	if l.refs > 0 do return
	for x, i in m.libraries do if x == l {
		ordered_remove(&m.libraries, i)
		break
	}
	dynlib.unload_library(l.lib)
	delete(l.surfaces, m.allocator)
	delete(l.path, m.allocator)
	free(l, m.allocator)
}

// Whether `port_name` matches one of a descriptor's hints (`input_hints`
// for an input, else `output_hints`): for finding a controller's ports.
port_matches :: proc(d: ^Descriptor, port_name: string, input: bool) -> bool {
	hints := d.input_hints if input else d.output_hints
	if hints == nil do return false
	for i := 0; hints[i] != nil; i += 1 do if strings.contains(port_name, string(hints[i])) do return true
	return false
}

// --- surfaces ------------------------------------------------------------------------------

// Control thread. Starts surface `index` of `lib` on `ports`. The library
// stays loaded while it runs. `.Device_Error` if the script fails to start.
surface_start :: proc(m: ^Manager, lib: ^Library, index: int, ports: Ports) -> (s: ^Instance, err: core.Error) {
	if index < 0 || index >= len(lib.surfaces) do return nil, .Invalid_Argument
	s = new(Instance, m.allocator)
	s.manager, s.library, s.ports = m, lib, ports
	s.touched = make([dynamic]u32, m.allocator)
	s.host = host_template
	s.host.data = s
	s.surface = lib.surfaces[index].create(&s.host)
	if s.surface == nil {
		delete(s.touched)
		free(s, m.allocator)
		return nil, .Device_Error
	}
	lib.refs += 1
	append(&m.surfaces, s)
	m.told = false // tell it the transport at the next update
	return s, .None
}

// Control thread. Stops a surface (ending any gestures it was making).
surface_stop :: proc(m: ^Manager, s: ^Instance) {
	for x, i in m.surfaces do if x == s {
		ordered_remove(&m.surfaces, i)
		break
	}
	for id in s.touched do if m.settings.on_touch != nil do m.settings.on_touch(m.settings.user, id, false)
	if s.surface.destroy != nil do s.surface.destroy(s.surface)
	for &c in m.changed do if c.from == s do c.from = nil
	library_close(m, s.library)
	delete(s.touched)
	free(s, m.allocator)
}

// --- the app's side ------------------------------------------------------------------------

// Control thread. Publishes a control surfaces may move (or updates its
// description), at `value`. Surfaces are told the set changed.
control_publish :: proc(m: ^Manager, info: Control_Info, value: f64) {
	c := Control{info = info, value = value}
	c.name = strings.clone_to_cstring(string(info.name), m.allocator)
	c.group = strings.clone_to_cstring(string(info.group) if info.group != nil else "", m.allocator)
	c.info.name, c.info.group = c.name, c.group
	for &x in m.controls do if x.info.id == info.id {
		delete(x.name, m.allocator)
		delete(x.group, m.allocator)
		x = c
		m.controls_changed = true
		return
	}
	append(&m.controls, c)
	m.controls_changed = true
}

// Control thread. Withdraws a control.
control_remove :: proc(m: ^Manager, id: u32) {
	for x, i in m.controls do if x.info.id == id {
		delete(x.name, m.allocator)
		delete(x.group, m.allocator)
		ordered_remove(&m.controls, i)
		m.controls_changed = true
		return
	}
}

// Control thread. A control's value changed in the app (the mouse moved
// it, automation played): surfaces are told at the next update, to move
// motorized faders and light buttons.
control_changed :: proc(m: ^Manager, id: u32, value: f64) {
	set_value(m, id, value, nil)
}

@(private)
set_value :: proc(m: ^Manager, id: u32, value: f64, from: ^Instance) -> bool {
	for &x in m.controls do if x.info.id == id {
		if x.value == value do return true
		x.value = value
		for &ch in m.changed do if ch.id == id {
			ch.value, ch.from = value, from
			return true
		}
		append(&m.changed, Change{id, value, from})
		return true
	}
	return false
}

// Control thread. Names a graph node so surfaces can set its parameters
// (`node_find`, `param_set`). A name already used is moved to `id`.
node_publish :: proc(m: ^Manager, name: string, id: graph.Node_Id) {
	for &n in m.nodes do if n.name == name {
		n.id = id
		return
	}
	append(&m.nodes, Named_Node{strings.clone(name, m.allocator), id})
}

// Control thread. Delivers what happened since the last call: controller
// MIDI, control changes, and transport changes, then each surface's idle.
// Call it often (every UI frame).
manager_update :: proc(m: ^Manager) {
	// Controller MIDI, to the surfaces listening on its port.
	midi.input_drain(&m.input, proc(user: rawptr, port: u8, bytes: [3]u8, time_ns: u64) {
		m := (^Manager)(user)
		n := midi.message_length(bytes[0])
		if n == 0 do return
		b := bytes
		for s in m.surfaces do if s.ports.midi_in == port && s.surface.on_midi != nil do s.surface.on_midi(s.surface, u32(port), &b[0], u32(n))
	}, m)
	for msg in midi.sysex_pop(&m.input.sysex, context.temp_allocator) {
		// The queue keeps the payload; scripts get the whole message, F0 … F7.
		whole := make([]u8, len(msg.data) + 2, context.temp_allocator)
		whole[0], whole[len(whole) - 1] = 0xF0, 0xF7
		copy(whole[1:], msg.data)
		for s in m.surfaces do if s.ports.midi_in == msg.port && s.surface.on_midi != nil {
			s.surface.on_midi(s.surface, u32(msg.port), raw_data(whole), u32(len(whole)))
		}
	}
	if m.controls_changed {
		m.controls_changed = false
		for s in m.surfaces do if s.surface.on_controls_changed != nil do s.surface.on_controls_changed(s.surface)
	}
	// Control changes, to every surface but the one that made them.
	for ch in m.changed do for s in m.surfaces do if s != ch.from && s.surface.on_control != nil do s.surface.on_control(s.surface, ch.id, ch.value)
	clear(&m.changed)
	// The transport, when more than its position moved.
	now := transport_state(m)
	if !m.told || now.playing != m.last.playing || now.looping != m.last.looping || now.tempo_bpm != m.last.tempo_bpm ||
	   now.bar != m.last.bar || now.loop_start != m.last.loop_start || now.loop_end != m.last.loop_end {
		m.last, m.told = now, true
		for s in m.surfaces do if s.surface.on_transport != nil do s.surface.on_transport(s.surface, &now)
	}
	for s in m.surfaces do if s.surface.on_idle != nil do s.surface.on_idle(s.surface)
}

@(private)
transport_state :: proc(m: ^Manager) -> (st: Transport_State) {
	c := m.settings.clock
	if c == nil do return
	status := transport.status(c)
	st.tempo_bpm, st.bar = status.tempo_bpm, status.bar
	st.numerator, st.denominator = status.meter.numerator, status.meter.denominator
	if m.settings.timeline != {} {
		pos, playing, ok := transport.timeline_status(c, m.settings.timeline)
		if ok do st.position, st.playing = f64(pos), playing
		if loop, start, end, ok2 := transport.timeline_loop(c, m.settings.timeline); ok2 && loop {
			st.looping, st.loop_start, st.loop_end = true, f64(start), f64(end)
		}
	}
	return
}

// --- the host functions --------------------------------------------------------------------

@(private)
instance_of :: #force_inline proc "contextless" (h: ^Host) -> ^Instance {
	return (^Instance)(h.data)
}

@(private)
host_template := Host {
	abi_version = ABI_VERSION,
	send_midi = proc "c" (h: ^Host, port: u32, bytes: [^]u8, size: u32) -> bool {
		context = runtime.default_context()
		s := instance_of(h)
		m := s.manager
		if m.settings.midi_out == nil || bytes == nil || size == 0 do return false
		return m.settings.midi_out(m.settings.user, s.ports.midi_out, bytes[:size])
	},
	play = proc "c" (h: ^Host) {
		context = runtime.default_context()
		m := instance_of(h).manager
		if m.settings.clock != nil && m.settings.timeline != {} do transport.play(m.settings.clock, m.settings.timeline)
	},
	stop = proc "c" (h: ^Host) {
		context = runtime.default_context()
		m := instance_of(h).manager
		if m.settings.clock != nil && m.settings.timeline != {} do transport.stop(m.settings.clock, m.settings.timeline)
	},
	locate = proc "c" (h: ^Host, beats: f64) {
		context = runtime.default_context()
		m := instance_of(h).manager
		if m.settings.clock != nil && m.settings.timeline != {} do transport.locate(m.settings.clock, m.settings.timeline, tb.Beats(beats))
	},
	set_loop = proc "c" (h: ^Host, on: bool, start, end: f64) {
		context = runtime.default_context()
		m := instance_of(h).manager
		if m.settings.clock == nil || m.settings.timeline == {} do return
		if on {
			transport.set_loop(m.settings.clock, m.settings.timeline, tb.Beats(start), tb.Beats(end))
		} else {
			transport.clear_loop(m.settings.clock, m.settings.timeline)
		}
	},
	set_tempo = proc "c" (h: ^Host, bpm: f64) {
		context = runtime.default_context()
		m := instance_of(h).manager
		if m.settings.clock != nil do transport.set_tempo(m.settings.clock, bpm)
	},
	get_transport = proc "c" (h: ^Host, out: ^Transport_State) {
		context = runtime.default_context()
		if out != nil do out^ = transport_state(instance_of(h).manager)
	},
	control_count = proc "c" (h: ^Host) -> u32 { return u32(len(instance_of(h).manager.controls)) },
	control_info = proc "c" (h: ^Host, index: u32, out: ^Control_Info) -> bool {
		m := instance_of(h).manager
		if int(index) >= len(m.controls) || out == nil do return false
		out^ = m.controls[index].info
		return true
	},
	control_get = proc "c" (h: ^Host, id: u32, out: ^f64) -> bool {
		m := instance_of(h).manager
		for c in m.controls do if c.info.id == id {
			if out != nil do out^ = c.value
			return true
		}
		return false
	},
	control_set = proc "c" (h: ^Host, id: u32, value: f64) -> bool {
		context = runtime.default_context()
		s := instance_of(h)
		m := s.manager
		v := value
		for c in m.controls do if c.info.id == id do v = clamp(value, min(c.info.min, c.info.max), max(c.info.min, c.info.max))
		if !set_value(m, id, v, s) do return false
		if m.settings.on_set != nil do m.settings.on_set(m.settings.user, id, v)
		return true
	},
	control_touch = proc "c" (h: ^Host, id: u32, touched: bool) -> bool {
		context = runtime.default_context()
		s := instance_of(h)
		m := s.manager
		known := false
		for c in m.controls do known ||= c.info.id == id
		if !known do return false
		at := -1
		for x, i in s.touched do if x == id do at = i
		if touched && at < 0 do append(&s.touched, id)
		if !touched && at >= 0 do unordered_remove(&s.touched, at)
		if m.settings.on_touch != nil do m.settings.on_touch(m.settings.user, id, touched)
		return true
	},
	node_find = proc "c" (h: ^Host, name: cstring) -> u64 {
		m := instance_of(h).manager
		for n in m.nodes do if n.name == string(name) do return u64(n.id.generation) << 32 | u64(n.id.index)
		return 0
	},
	param_set = proc "c" (h: ^Host, node: u64, param: u32, value: f64) -> bool {
		context = runtime.default_context()
		m := instance_of(h).manager
		if m.settings.graph == nil || node == 0 do return false
		id := graph.Node_Id{index = u32(node & 0xFFFF_FFFF), generation = u32(node >> 32)}
		return graph.set_param(m.settings.graph, id, core.Param_Id(param), value) == .None
	},
	log = proc "c" (h: ^Host, level: i32, message: cstring) {
		context = runtime.default_context()
		m := instance_of(h).manager
		if m.settings.log != nil && message != nil do m.settings.log(m.settings.user, level, string(message))
	},
}
