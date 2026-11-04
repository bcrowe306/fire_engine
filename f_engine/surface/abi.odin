/*
Control surfaces: scripts, loaded from dynamic libraries, that connect a
hardware controller to the app.

A script library exports `fire_surface_entry`, which lists its surfaces
(`Descriptor`): one per controller model, with hints for finding its MIDI
ports. A surface instance receives the controller's MIDI and the app's
changes (controls moving, the transport), and acts through its `Host`:
it sends MIDI back (LEDs, displays, motorized faders), drives the
transport, moves the controls the app publishes, and sets parameters of
graph nodes the app names. Everything runs on the app's control thread,
from `manager_update`.

Scripts can be written in Odin (import this package for the types) or in
C (`fire_surface.h` in this folder declares the same ABI).

	m, _ := surface.manager_create({clock = clock, timeline = song, graph = g,
		midi_out = send_to_controller, on_set = apply_control})
	lib, _ := surface.library_open(m, "scripts/mini.dylib")
	s, _ := surface.surface_start(m, lib, 0, {})
	surface.control_publish(m, {id = 1, name = "Volume", kind = .Continuous, max = 1}, 0.8)
	// every UI frame:
	surface.manager_update(m)

See /guides/surfaces/.
*/
package surface

// The script ABI's version: a script with another version is refused.
ABI_VERSION :: 1

// The symbol a script library exports: a `Entry_Proc`.
ENTRY_SYMBOL :: "fire_surface_entry"

// What a script library exports: its surfaces by index, nil past the last.
Entry_Proc :: #type proc "c" (index: u32) -> ^Descriptor

// One kind of surface a script library provides.
Descriptor :: struct {
	abi_version:  u32,
	id:           cstring, // reverse-domain, stable: "com.example.mini"
	name:         cstring, // "Example Mini"
	vendor:       cstring,
	input_hints:  [^]cstring, // nil-terminated: substrings of the controller's MIDI input port names
	output_hints: [^]cstring, // likewise for its output ports
	create:       proc "c" (host: ^Host) -> ^Surface, // nil on failure
}

// A running surface, as its script made it. The host calls these on the
// control thread; any may be nil.
Surface :: struct {
	data:                rawptr, // the script's own
	destroy:             proc "c" (s: ^Surface),
	on_midi:             proc "c" (s: ^Surface, port: u32, bytes: [^]u8, size: u32), // a short message or a whole SysEx
	on_control:          proc "c" (s: ^Surface, id: u32, value: f64), // the app moved a control
	on_controls_changed: proc "c" (s: ^Surface), // controls were published or removed: read them again
	on_transport:        proc "c" (s: ^Surface, state: ^Transport_State), // playing, tempo, loop or bar changed
	on_idle:             proc "c" (s: ^Surface), // every `manager_update`: meters, blinking, timeouts
}

// The transport, as a surface sees it.
Transport_State :: struct {
	playing:     bool,
	looping:     bool,
	position:    f64, // beats, on the surface's timeline
	tempo_bpm:   f64,
	bar:         i64, // 0-based, on the clock's bar grid
	loop_start:  f64,
	loop_end:    f64,
	numerator:   i32,
	denominator: i32,
}

// What a control is.
Control_Kind :: enum u32 {
	Continuous, // a knob or fader: min..max
	Toggle,     // on (max) or off (min): mute, solo, arm
	Trigger,    // fires when set to max: launch a clip, tap tempo
	Stepped,    // `steps` values from min to max: a mode, a bank
}

// A control the app publishes: anything a surface may move. Names belong
// to the host.
Control_Info :: struct {
	id:      u32, // the app's, stable while published
	kind:    Control_Kind,
	name:    cstring, // "Volume"
	group:   cstring, // where it belongs, "Track 1", or ""
	min:     f64,
	max:     f64,
	default: f64,
	steps:   u32, // Stepped: how many values
}

// What a surface can do. Every function is for the control thread, during
// the surface's callbacks.
Host :: struct {
	abi_version:   u32,
	data:          rawptr, // the host's own
	// MIDI to the controller (a short message, or SysEx F0 … F7).
	send_midi:     proc "c" (h: ^Host, port: u32, bytes: [^]u8, size: u32) -> bool,
	// The transport (the manager's timeline).
	play:          proc "c" (h: ^Host),
	stop:          proc "c" (h: ^Host),
	locate:        proc "c" (h: ^Host, beats: f64),
	set_loop:      proc "c" (h: ^Host, on: bool, start, end: f64),
	set_tempo:     proc "c" (h: ^Host, bpm: f64),
	get_transport: proc "c" (h: ^Host, out: ^Transport_State),
	// The app's controls.
	control_count: proc "c" (h: ^Host) -> u32,
	control_info:  proc "c" (h: ^Host, index: u32, out: ^Control_Info) -> bool,
	control_get:   proc "c" (h: ^Host, id: u32, out: ^f64) -> bool,
	control_set:   proc "c" (h: ^Host, id: u32, value: f64) -> bool,
	control_touch: proc "c" (h: ^Host, id: u32, touched: bool) -> bool, // a gesture starts or ends (for automation touch)
	// Graph nodes the app names, and their parameters.
	node_find:     proc "c" (h: ^Host, name: cstring) -> u64, // 0 = no such node
	param_set:     proc "c" (h: ^Host, node: u64, param: u32, value: f64) -> bool,
	log:           proc "c" (h: ^Host, level: i32, message: cstring),
}
