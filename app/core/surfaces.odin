package app

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

import "fire:midi"
import "fire:rt"

import abi "fsurf:abi"
import fsurf "fsurf:host"

/*
Control surfaces (fire-surface, extern/fire-surface): .fsurf libraries
found in the surface folders, the controllers they're for found on the
MIDI ports and started, and each surface's claim table applied to MIDI
from its controller before the engine sees it.

- Short messages: `route` on the audio thread, as the host's MIDI input
  hands them over (a `midi.Input_Filter`): what a surface claims never
  reaches the engine; what it remaps reaches it changed, with no added
  latency.
- SysEx (identity replies, a surface's own): assembled on the control
  thread, routed there (`route_here`).
- A surface's MIDI out goes straight to the port (`midi.send`), on the
  control thread; what it hands on (`inject_midi`) goes into the engine as
  if it came from its port.
- Ports plugged in or out (`host_midi_poll`): the surfaces follow.

Fsurf port ids are the host's port indices: an input's `core.Midi_Raw`
port, an output's place in `Host.midi_outputs`.

	surfaces_init(&s, &host, {folders = {pads_folder}, extension = ..., user = app})
	// each frame, on the control thread:
	surfaces_update(&s)
	// at the end, after the audio stops:
	surfaces_destroy(&s)

USB and HID devices (a display's) aren't opened yet: a surface's
displays are mirrored (its virtual controller shows them), not sent.
*/

// What the app gives the surfaces.
Surfaces_Config :: struct {
	folders:       []string, // where to look first (the app's own); then FSURF_PATH and the system's
	// An extension of the app: "fsurf.daw", "fire.pads"... (nil: none).
	extension:     proc(user: rawptr, id: string, version: u32) -> rawptr,
	has_extension: proc(user: rawptr, id: string) -> bool,
	log:           proc(user: rawptr, message: string),
	notify:        proc(user: rawptr, text: string),
	// A device's settings blob, kept by the app between runs.
	load_settings: proc(user: rawptr, key: string) -> []u8,
	save_settings: proc(user: rawptr, key: string, data: []u8),
	watch:         bool, // hot reload: rebuilt libraries are loaded again
	user:          rawptr,
}

// A library the surfaces scan found: loaded, or why not.
Surface_Library :: struct {
	path:  string,
	lib:   ^fsurf.Library, // nil when it didn't load
	error: fsurf.Library_Error,
}

// The control surfaces. Control thread, but the filter. Fields are read-only.
Surfaces :: struct {
	host:      ^Host,
	config:    Surfaces_Config,
	fs:        fsurf.Host,
	libraries: [dynamic]Surface_Library,
	filter:    midi.Input_Filter,
	started:   bool,
	ports_seen: [dynamic]string, // the port names last given (to see a change)
}

// Starts the surfaces: scans the folders, loads every library there, and
// matches the controllers on the host's MIDI ports. Its MIDI filter goes on
// the host's input.
surfaces_init :: proc(s: ^Surfaces, h: ^Host, config: Surfaces_Config) {
	s.host = h
	s.config = config
	s.libraries = make([dynamic]Surface_Library)
	s.ports_seen = make([dynamic]string)
	fsurf.host_init(&s.fs, {
		name = "Pads", vendor = "fire_engine", url = "https://github.com/bcrowe306/fire_engine",
		user = s,
		send_midi = surfaces_send,
		inject_midi = surfaces_inject,
		get_extension = proc(user: rawptr, inst: ^fsurf.Instance, id: string, version: u32) -> rawptr {
			s := (^Surfaces)(user)
			return s.config.extension(s.config.user, id, version) if s.config.extension != nil else nil
		},
		has_extension = proc(user: rawptr, id: string) -> bool {
			s := (^Surfaces)(user)
			return s.config.has_extension != nil && s.config.has_extension(s.config.user, id)
		},
		log = proc(user: rawptr, inst: ^fsurf.Instance, level: abi.Log_Level, message: string) {
			s := (^Surfaces)(user)
			if s.config.log != nil do s.config.log(s.config.user, message)
		},
		notify = proc(user: rawptr, inst: ^fsurf.Instance, text: string) {
			s := (^Surfaces)(user)
			if s.config.notify != nil do s.config.notify(s.config.user, text)
		},
		now_ns = proc(user: rawptr) -> u64 { return rt.host_time_ns() },
		on_device = proc(user: rawptr, d: ^fsurf.Device, old: fsurf.Device_State) {
			s := (^Surfaces)(user)
			// Leaving: its settings, kept.
			if d.instance != nil && (d.state == .Gone || old == .Active) && s.config.save_settings != nil {
				s.config.save_settings(s.config.user, device_key(d), fsurf.instance_settings(d.instance))
			}
		},
		device_settings = proc(user: rawptr, d: ^fsurf.Device) -> []u8 {
			s := (^Surfaces)(user)
			return s.config.load_settings(s.config.user, device_key(d)) if s.config.load_settings != nil else nil
		},
	})
	// The folders: the app's, then FSURF_PATH and the system's.
	folders := make([dynamic]string, context.temp_allocator)
	append(&folders, ..config.folders)
	defaults := fsurf.default_folders()
	defer fsurf.delete_folders(defaults)
	append(&folders, ..defaults)
	surfaces_scan(s, folders[:])
	s.filter = {filter = surfaces_filter, user = s}
	midi.input_set_filter(&h.midi_in, &s.filter)
	s.started = true
	surfaces_ports(s)
}

// Loads the .fsurf libraries in these folders (not loaded already).
surfaces_scan :: proc(s: ^Surfaces, folders: []string) {
	for folder in folders {
		files, err := os.read_all_directory_by_path(folder, context.temp_allocator)
		if err != nil do continue
		paths := make([dynamic]string, context.temp_allocator)
		for f in files do if f.type != .Directory && strings.to_lower(filepath.ext(f.name), context.temp_allocator) == fsurf.EXTENSION do append(&paths, f.fullpath)
		for p in paths do surfaces_load(s, p)
	}
}

// Loads one library and offers its surfaces to detection (a library loaded
// already: nothing). Its index, and why it didn't load.
surfaces_load :: proc(s: ^Surfaces, path: string) -> (int, fsurf.Library_Error) {
	for l, i in s.libraries do if l.path == path do return i, l.error
	lib: ^fsurf.Library
	err: fsurf.Library_Error
	if s.config.watch {
		lib, err = fsurf.library_load_watched(path)
	} else {
		lib, err = fsurf.library_load(path)
	}
	append(&s.libraries, Surface_Library{path = strings.clone(path), lib = lib, error = err})
	if lib != nil do fsurf.host_add_library(&s.fs, lib)
	else if s.config.log != nil do s.config.log(s.config.user, strings.concatenate({path, ": ", lib_error(err)}, context.temp_allocator))
	return len(s.libraries) - 1, err
}

// Adds a surface library linked into the app (its entry), as if loaded
// from `path` (a name for it). Its index.
surfaces_add_static :: proc(s: ^Surfaces, entry: ^abi.Entry, path: string) -> (int, fsurf.Library_Error) {
	lib, err := fsurf.library_static(entry, path)
	append(&s.libraries, Surface_Library{path = strings.clone(path), lib = lib, error = err})
	if lib != nil do fsurf.host_add_library(&s.fs, lib)
	return len(s.libraries) - 1, err
}

// Unloads a library: its surfaces stopped and forgotten.
surfaces_unload :: proc(s: ^Surfaces, index: int) -> bool {
	if index < 0 || index >= len(s.libraries) do return false
	l := s.libraries[index]
	ordered_remove(&s.libraries, index)
	if l.lib != nil {
		fsurf.host_remove_library(&s.fs, l.lib)
		fsurf.library_unload(l.lib)
	}
	delete(l.path)
	return true
}

@(private)
lib_error :: proc(e: fsurf.Library_Error) -> string {
	switch e {
	case .None: return "loaded"
	case .Cannot_Load: return "not a library this system can load"
	case .No_Entry: return "not a control surface (no fsurf_entry)"
	case .Incompatible_Version: return "built for another version of fire-surface"
	case .Init_Failed: return "its library wouldn't start"
	case .No_Factory: return "it offers no surfaces"
	case .Bad_Descriptor: return "a surface it offers is malformed"
	}
	return ""
}

// Why a library didn't load, in words.
surfaces_library_error :: proc(e: fsurf.Library_Error) -> string { return lib_error(e) }

// Once a frame, on the control thread: ports plugged in or out, SysEx from
// the controllers, then the surfaces (MIDI for them, timers, displays,
// identification).
surfaces_update :: proc(s: ^Surfaces) {
	if !s.started do return
	if host_midi_poll(s.host) do surfaces_ports(s)
	// SysEx: assembled by the host's input, routed here. (Nothing else in
	// the app reads it.)
	buf := make([dynamic]u8, context.temp_allocator)
	for msg in midi.sysex_pop(&s.host.midi_in.sysex, context.temp_allocator) {
		clear(&buf)
		append(&buf, 0xF0)
		append(&buf, ..msg.data)
		append(&buf, 0xF7)
		out: [3]u8
		fsurf.route_here(&s.fs, u32(msg.port), buf[:], msg.time_ns, &out)
	}
	fsurf.host_update(&s.fs)
}

// Gives detection the host's ports as they are now (names from the driver).
surfaces_ports :: proc(s: ^Surfaces) {
	h := s.host
	names := make(map[string]string, allocator = context.temp_allocator)
	for p in host_midi_ports(h, context.temp_allocator) do names[strings.concatenate({"i" if p.direction == .Input else "o", p.id}, context.temp_allocator)] = p.name
	ins := make([dynamic]fsurf.Port_Info, context.temp_allocator)
	outs := make([dynamic]fsurf.Port_Info, context.temp_allocator)
	for id, i in h.midi_input_ids do if id != "" {
		append(&ins, fsurf.Port_Info{id = u32(i), name = names[strings.concatenate({"i", id}, context.temp_allocator)] or_else id})
	}
	for id, i in h.midi_output_ids do if id != "" {
		append(&outs, fsurf.Port_Info{id = u32(i), name = names[strings.concatenate({"o", id}, context.temp_allocator)] or_else id})
	}
	fsurf.host_set_ports(&s.fs, ins[:], outs[:])
}

// Stops every surface and unloads the libraries. After the audio stops (or
// it waits a moment for the filter to be off the audio thread).
surfaces_destroy :: proc(s: ^Surfaces) {
	if !s.started do return
	midi.input_set_filter(&s.host.midi_in, nil)
	if s.host.running do time.sleep(50 * time.Millisecond) // (a block or two, for a route in progress)
	fsurf.host_destroy(&s.fs)
	for l in s.libraries {
		if l.lib != nil do fsurf.library_unload(l.lib)
		delete(l.path)
	}
	delete(s.libraries)
	for p in s.ports_seen do delete(p)
	delete(s.ports_seen)
	s.started = false
}

// A device's key for its settings: its surface and which of its model.
@(private)
device_key :: proc(d: ^fsurf.Device) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, string(d.descriptor.id))
	strings.write_byte(&b, '#')
	strings.write_int(&b, d.index)
	return strings.to_string(b)
}

// [rt] The claim table, on the audio thread: each short message from a
// port, as the host's input hands it over.
@(private)
surfaces_filter :: proc "contextless" (user: rawptr, port: u8, b: [3]u8, time_ns: u64) -> ([3]u8, bool) {
	s := (^Surfaces)(user)
	n := message_size(b[0])
	if n == 0 do return b, true
	in_ := b
	out: [3]u8
	r := fsurf.route(&s.fs, u32(port), in_[:n], time_ns, &out)
	if r.host == nil do return b, false
	res: [3]u8
	for x, i in r.host do if i < 3 do res[i] = x
	return res, true
}

@(private)
message_size :: proc "contextless" (status: u8) -> int {
	switch status & 0xF0 {
	case 0x80, 0x90, 0xA0, 0xB0, 0xE0: return 3
	case 0xC0, 0xD0: return 2
	}
	switch status {
	case 0xF1, 0xF3: return 2
	case 0xF2: return 3
	}
	return 1 if status >= 0xF4 else 0
}

@(private)
surfaces_send :: proc(user: rawptr, inst: ^fsurf.Instance, port: u32, bytes: []u8) -> bool {
	s := (^Surfaces)(user)
	h := s.host
	if h.midi_driver == nil || int(port) >= len(h.midi_outputs) || h.midi_outputs[port] == 0 do return false
	return midi.send(h.midi_driver, h.midi_outputs[port], bytes) == .None
}

@(private)
surfaces_inject :: proc(user: rawptr, inst: ^fsurf.Instance, port: u32, bytes: []u8) -> bool {
	s := (^Surfaces)(user)
	if len(bytes) == 0 || len(bytes) > 3 || bytes[0] == 0xF0 || port > 255 do return false
	msg: [3]u8
	copy(msg[:], bytes)
	host_midi_inject(s.host, msg, u8(port))
	return true
}

