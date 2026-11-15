package pads_api

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

import app "app:core"
import abi "fsurf:abi"
import fsurf "fsurf:host"
import "fire:midi"
import "fire:rt"

// The name a surface asks its host's `get_extension` for, with `VERSION`,
// to get this API's C function table (`Pads_Api_V1`).
EXTENSION_NAME :: "fire.pads"

/*
Control surfaces (fire-surface: extern/fire-surface). Libraries (.fsurf)
are loaded from the surface folders when Pads starts (`surfaces_start`)
and with `surface_load`; the controllers they're for are found on the MIDI
ports and their surfaces started, each a "surface" here (by index, as
found: `surface_count`). A surface gets this API as the "fire.pads"
extension, and the standard "fsurf.daw" (daw.odin).
*/

// Where a surface's controller is.
Surface_State :: enum i32 {
	Identifying,    // asked who it is, waiting for its answer
	Waiting,        // identified; waiting for others on its ports to answer
	Active,         // its surface runs
	Not_Identified, // it didn't answer as the surface's controller
	Passed_Over,    // another surface (more specific, or assigned by hand) has its ports
	Failed,         // its surface wouldn't start
	Gone,           // unplugged; its surface waits for it
}

// Starts the control surfaces: the libraries in `folders` (Pads' own), in
// FSURF_PATH and in the system's surface folders, matched against the MIDI
// ports. `watch`: rebuilt libraries are loaded again (for a surface's
// author). The app calls it once, with its host's MIDI open.
surfaces_start :: proc(api: ^Api, folders: []string = nil, watch := false) {
	if api.surfaces_on do return
	daw_init(api)
	api.virtuals = make([dynamic]fsurf.Virtual)
	app.surfaces_init(&api.surfaces, &api.core.host, {
		folders = folders,
		watch = watch,
		user = api,
		extension = proc(user: rawptr, id: string, version: u32) -> rawptr {
			api := (^Api)(user)
			if id == EXTENSION_NAME && version == VERSION do return &api.table
			if id == abi.DAW_ID && version == abi.DAW_VERSION do return &api.daw.table
			return nil
		},
		has_extension = proc(user: rawptr, id: string) -> bool { return id == EXTENSION_NAME || id == abi.DAW_ID },
		log = proc(user: rawptr, message: string) { fmt.eprintfln("surface: %s", message) },
		notify = proc(user: rawptr, text: string) { ui_message_show((^Api)(user), .Info, text) },
		load_settings = proc(user: rawptr, key: string) -> []u8 {
			data, err := os.read_entire_file(settings_file((^Api)(user), key), context.temp_allocator)
			return data if err == nil else nil
		},
		save_settings = proc(user: rawptr, key: string, data: []u8) {
			api := (^Api)(user)
			dir := settings_file(api, "")
			os.make_directory_all(dir)
			_ = os.write_entire_file(settings_file(api, key), data)
		},
	})
	api.surfaces_on = true
	// Detection turned off before.
	if off, err := os.read_entire_file(settings_file(api, "off.txt"), context.temp_allocator); err == nil {
		for id in strings.split_lines(string(off), context.temp_allocator) do if id != "" do fsurf.host_set_auto_detect(&api.surfaces.fs, id, false)
	}
}

// Where a surface's settings are kept: the app's settings folder.
@(private)
settings_file :: proc(api: ^Api, key: string) -> string {
	safe, _ := strings.replace_all(key, "#", "-", context.temp_allocator)
	p, _ := filepath.join({api.core.files.folders.settings, "Surface Settings", safe if key != "" else ""}, context.temp_allocator)
	return p
}

@(private)
save_detect_off :: proc(api: ^Api) {
	b := strings.builder_make(context.temp_allocator)
	for id in api.surfaces.fs.disabled do fmt.sbprintln(&b, id)
	os.make_directory_all(settings_file(api, ""))
	_ = os.write_entire_file(settings_file(api, "off.txt"), transmute([]u8)strings.to_string(b))
}

// Stops every surface and unloads the libraries: before the model goes
// (a surface stopping may still read Pads). The app calls it; `api_destroy`
// does too, if it hasn't.
surfaces_stop :: proc(api: ^Api) { surfaces_destroy(api) }

@(private)
surfaces_destroy :: proc(api: ^Api) {
	if !api.surfaces_on do return
	for &v in api.virtuals do fsurf.virtual_close(&v)
	delete(api.virtuals)
	app.surfaces_destroy(&api.surfaces)
	daw_destroy(api)
	api.surfaces_on = false
}

@(private)
surfaces_ok :: proc(api: ^Api) -> bool {
	if !api.surfaces_on do fail(api, .Unsupported, "control surfaces aren't started")
	return api.surfaces_on
}

@(private)
device_at :: proc(api: ^Api, index: i64) -> (^fsurf.Device, bool) {
	if !surfaces_ok(api) do return nil, false
	ds := fsurf.host_devices(&api.surfaces.fs)
	if index < 0 || index >= i64(len(ds)) {
		fail(api, .Not_Found, "no such surface")
		return nil, false
	}
	return ds[index], true
}

@(private)
library_at :: proc(api: ^Api, lib: i64) -> (^app.Surface_Library, bool) {
	if !surfaces_ok(api) do return nil, false
	if lib < 0 || lib >= i64(len(api.surfaces.libraries)) {
		fail(api, .Not_Found, "no such library")
		return nil, false
	}
	return &api.surfaces.libraries[lib], true
}

@(private)
offered_at :: proc(api: ^Api, lib, k: i64) -> (^abi.Descriptor, bool) {
	l, ok := library_at(api, lib)
	if !ok do return nil, false
	if l.lib == nil || k < 0 || k >= i64(len(l.lib.descriptors)) {
		fail(api, .Not_Found, "the library has no such surface")
		return nil, false
	}
	return l.lib.descriptors[k], true
}

// ── Libraries ─────────────────────────────────────────────────────────

// Loads the control-surface library at `path` (a .fsurf) and offers its
// surfaces to detection: a controller of theirs on the MIDI ports starts
// one. Its place among the libraries (`surface_library_*`); a library
// loaded already: its place. Io_Error if it won't load. (`index`: kept for
// the first version of the table; any.)
surface_load :: proc(api: ^Api, path: string, index: i64 = 0) -> (i64, Result) {
	if !surfaces_ok(api) do return 0, .Unsupported
	k, err := app.surfaces_load(&api.surfaces, path)
	if err != .None {
		app.surfaces_unload(&api.surfaces, k)
		return 0, failf(api, .Io_Error, "could not load the surface library ", path, ": ", app.surfaces_library_error(err))
	}
	return i64(k), .Ok
}

// The surface libraries loaded (from the folders, and `surface_load`'s),
// those that didn't load included.
surface_library_count :: proc(api: ^Api) -> (i64, Result) {
	if !surfaces_ok(api) do return 0, .Unsupported
	return i64(len(api.surfaces.libraries)), .Ok
}

// Library `lib`'s path. Temporary.
surface_library_path :: proc(api: ^Api, lib: i64) -> (string, Result) {
	l, ok := library_at(api, lib)
	if !ok do return "", .Not_Found
	return l.path, .Ok
}

// Why library `lib` didn't load ("" when it did). Temporary.
surface_library_error :: proc(api: ^Api, lib: i64) -> (string, Result) {
	l, ok := library_at(api, lib)
	if !ok do return "", .Not_Found
	return "" if l.error == .None else app.surfaces_library_error(l.error), .Ok
}

// Unloads library `lib`: its surfaces stop (the libraries after it move
// down one).
surface_library_unload :: proc(api: ^Api, lib: i64) -> Result {
	if _, ok := library_at(api, lib); !ok do return .Not_Found
	app.surfaces_unload(&api.surfaces, int(lib))
	return .Ok
}

// The surfaces library `lib` offers (one a controller model).
surface_offered_count :: proc(api: ^Api, lib: i64) -> (i64, Result) {
	l, ok := library_at(api, lib)
	if !ok do return 0, .Not_Found
	return i64(len(l.lib.descriptors)) if l.lib != nil else 0, .Ok
}

// The name of surface `k` that library `lib` offers ("Push 2"). Temporary.
surface_offered_name :: proc(api: ^Api, lib: i64, k: i64) -> (string, Result) {
	d, ok := offered_at(api, lib, k)
	if !ok do return "", .Not_Found
	return string(d.name), .Ok
}

// The id of surface `k` that library `lib` offers ("com.example.push2"). Temporary.
surface_offered_id :: proc(api: ^Api, lib: i64, k: i64) -> (string, Result) {
	d, ok := offered_at(api, lib, k)
	if !ok do return "", .Not_Found
	return string(d.id), .Ok
}

// Turns detection of library `lib`'s surface `k` on or off (kept between
// runs). Off, the controllers found for it are forgotten.
surface_set_detect :: proc(api: ^Api, lib: i64, k: i64, on: bool) -> Result {
	d, ok := offered_at(api, lib, k)
	if !ok do return .Not_Found
	fsurf.host_set_auto_detect(&api.surfaces.fs, string(d.id), on)
	save_detect_off(api)
	return .Ok
}

// Whether library `lib`'s surface `k` is detected.
surface_detect :: proc(api: ^Api, lib: i64, k: i64) -> (bool, Result) {
	d, ok := offered_at(api, lib, k)
	if !ok do return false, .Not_Found
	return fsurf.host_auto_detect(&api.surfaces.fs, string(d.id)), .Ok
}

// ── Surfaces: the controllers found, and those assigned by hand ───────

// The surfaces: a controller each, found on the MIDI ports (whatever its
// state) or assigned by hand.
surface_count :: proc(api: ^Api) -> (i64, Result) {
	if !surfaces_ok(api) do return 0, .Unsupported
	return i64(len(fsurf.host_devices(&api.surfaces.fs))), .Ok
}

// Surface `index`'s name, as its library gives it ("Push 2"). Temporary.
surface_name :: proc(api: ^Api, index: i64) -> (string, Result) {
	d, ok := device_at(api, index)
	if !ok do return "", .Not_Found
	return string(d.descriptor.name), .Ok
}

// The library surface `index` comes from. Temporary.
surface_path :: proc(api: ^Api, index: i64) -> (string, Result) {
	d, ok := device_at(api, index)
	if !ok do return "", .Not_Found
	for l in api.surfaces.libraries do if l.lib == d.library do return l.path, .Ok
	return "", .Ok
}

// Where surface `index`'s controller is.
surface_state :: proc(api: ^Api, index: i64) -> (Surface_State, Result) {
	d, ok := device_at(api, index)
	if !ok do return {}, .Not_Found
	return Surface_State(d.state), .Ok
}

// The MIDI ports surface `index` is on: its first pair's names ("in /
// out"). Temporary.
surface_ports :: proc(api: ^Api, index: i64) -> (string, Result) {
	d, ok := device_at(api, index)
	if !ok do return "", .Not_Found
	if len(d.ports) == 0 do return "", .Ok
	p := d.ports[0]
	if p.output_name == "" || p.output_name == p.input_name do return p.input_name, .Ok
	return fmt.tprintf("%s / %s", p.input_name, p.output_name), .Ok
}

// Starts library `lib`'s surface `k` on MIDI ports chosen by hand (by
// their ids: `midi_port_id`; output "" for none), whatever their names:
// it takes them from any surface found there, and keeps them until
// `surface_unload`. Its index among the surfaces.
surface_assign :: proc(api: ^Api, lib: i64, k: i64, input: string, output: string) -> (i64, Result) {
	d, ok := offered_at(api, lib, k)
	if !ok do return 0, .Not_Found
	h := &api.core.host
	in_ := app.host_midi_input_index(h, input)
	out := app.host_midi_output_index(h, output) if output != "" else -1
	if in_ < 0 do return 0, fail(api, .Not_Found, "no such MIDI input open")
	if output != "" && out < 0 do return 0, fail(api, .Not_Found, "no such MIDI output open")
	if d.port_count == 0 do return 0, fail(api, .Unsupported, "the surface uses no MIDI ports")
	names := make(map[string]string, allocator = context.temp_allocator)
	for p in app.host_midi_ports(h, context.temp_allocator) do names[p.id] = p.name
	ports := make([]fsurf.Port_Assignment, d.port_count, context.temp_allocator)
	for &p in ports do p = {input = abi.NO_PORT, output = abi.NO_PORT}
	ports[0] = {input = u32(in_), output = u32(out) if out >= 0 else abi.NO_PORT, input_name = names[input] or_else input, output_name = names[output] or_else output if output != "" else ""}
	dev, err := fsurf.host_assign(&api.surfaces.fs, api.surfaces.libraries[lib].lib, string(d.id), ports)
	if dev == nil do return 0, fail(api, .Unsupported, "the surface would not start")
	_ = err
	for x, i in fsurf.host_devices(&api.surfaces.fs) do if x == dev do return i64(i), .Ok
	return 0, .Ok
}

// Stops surface `index`: one assigned by hand is forgotten; one found has
// its surface's detection turned off (`surface_set_detect` turns it on
// again). The surfaces after it move down.
surface_unload :: proc(api: ^Api, index: i64) -> Result {
	d, ok := device_at(api, index)
	if !ok do return .Not_Found
	if d.manual {
		fsurf.host_unassign(&api.surfaces.fs, d)
	} else {
		fsurf.host_set_auto_detect(&api.surfaces.fs, string(d.descriptor.id), false)
		save_detect_off(api)
	}
	return .Ok
}

// ── The MIDI monitor ──────────────────────────────────────────────────

// Turns the surfaces' MIDI monitor on or off: each message from a
// surface's controller (what its claim table did with it), and each it
// sent, named by its surface.
surface_monitor :: proc(api: ^Api, on: bool) -> Result {
	if !surfaces_ok(api) do return .Unsupported
	fsurf.monitor_enable(&api.surfaces.fs, on)
	return .Ok
}

// The messages the monitor has (the oldest go past 2048).
surface_monitor_count :: proc(api: ^Api) -> (i64, Result) {
	if !surfaces_ok(api) do return 0, .Unsupported
	return i64(len(fsurf.monitor_entries(&api.surfaces.fs))), .Ok
}

// The monitor's message `i` as a line: "in  1  90 24 64  claim (rule 2)
// Grid / Pads 3,0 (Drum)". Temporary.
surface_monitor_line :: proc(api: ^Api, i: i64) -> (string, Result) {
	if !surfaces_ok(api) do return "", .Unsupported
	es := fsurf.monitor_entries(&api.surfaces.fs)
	if i < 0 || i >= i64(len(es)) do return "", fail(api, .Not_Found, "no such message")
	return fsurf.monitor_line(es[i]), .Ok
}

// Empties the monitor.
surface_monitor_clear :: proc(api: ^Api) -> Result {
	if !surfaces_ok(api) do return .Unsupported
	fsurf.monitor_clear(&api.surfaces.fs)
	return .Ok
}

// ── A surface's controls (its virtual controller) ─────────────────────

// The virtual controller of surface `index` (its fsurf.layout), opened
// the first time; nil (and Unsupported) when it has none.
@(private)
virtual_of :: proc(api: ^Api, index: i64) -> (^fsurf.Virtual, Result) {
	d, ok := device_at(api, index)
	if !ok do return nil, .Not_Found if api.surfaces_on else .Unsupported
	if d.instance == nil do return nil, fail(api, .Unsupported, "the surface isn't running")
	for &v in api.virtuals do if v.s == d.instance do return &v, .Ok
	v, vok := fsurf.virtual_open(d.instance)
	if !vok do return nil, fail(api, .Unsupported, "the surface doesn't describe its controls")
	append(&api.virtuals, v)
	return &api.virtuals[len(api.virtuals) - 1], .Ok
}

// Forgets the virtual controllers of surfaces that are gone.
@(private)
virtuals_prune :: proc(api: ^Api) {
	for i := len(api.virtuals) - 1; i >= 0; i -= 1 {
		alive := false
		if api.surfaces_on do for d in fsurf.host_devices(&api.surfaces.fs) do if d.instance == api.virtuals[i].s do alive = true
		if !alive {
			fsurf.virtual_close(&api.virtuals[i])
			unordered_remove(&api.virtuals, i)
		}
	}
}

// The controls surface `index` describes (buttons, pads, encoders,
// faders, displays). Unsupported if it doesn't describe them.
surface_control_count :: proc(api: ^Api, index: i64) -> (i64, Result) {
	v, r := virtual_of(api, index)
	if r != .Ok do return 0, r
	return i64(len(v.controls)), .Ok
}

// The name of surface `index`'s control `k` ("Play", "Pads 3,0"). Temporary.
surface_control_name :: proc(api: ^Api, index: i64, k: i64) -> (string, Result) {
	v, r := virtual_of(api, index)
	if r != .Ok do return "", r
	if k < 0 || k >= i64(len(v.controls)) do return "", fail(api, .Not_Found, "no such control")
	return v.controls[k].label, .Ok
}

// Presses surface `index`'s control `name` (a button or pad, at `velocity`
// 0..1), as its controller would send it: into Pads' MIDI input on its
// port, through its claim table. Not_Found for no such control.
surface_press :: proc(api: ^Api, index: i64, name: string, velocity: f32 = 1) -> Result {
	return virtual_do(api, index, name, 0, f64(velocity))
}

// Releases surface `index`'s control `name`.
surface_release :: proc(api: ^Api, index: i64, name: string) -> Result {
	return virtual_do(api, index, name, 1, 0)
}

// Turns surface `index`'s encoder `name` by `steps` (negative: down).
surface_turn :: proc(api: ^Api, index: i64, name: string, steps: i64) -> Result {
	return virtual_do(api, index, name, 2, f64(steps))
}

// Moves surface `index`'s fader `name` to `value` (0..1).
surface_move :: proc(api: ^Api, index: i64, name: string, value: f64) -> Result {
	return virtual_do(api, index, name, 3, value)
}

@(private)
virtual_do :: proc(api: ^Api, index: i64, name: string, what: int, x: f64) -> Result {
	v, r := virtual_of(api, index)
	if r != .Ok do return r
	k := fsurf.virtual_find(v, name)
	if k < 0 do return fail(api, .Not_Found, "no such control")
	m: fsurf.Virtual_Messages
	switch what {
	case 0: m = fsurf.virtual_press(v, k, u8(clamp(x * 127 + 0.5, 1, 127)))
	case 1: m = fsurf.virtual_release(v, k)
	case 2: m = fsurf.virtual_turn(v, k, int(x))
	case 3: m = fsurf.virtual_move(v, k, f32(x))
	}
	if m.count == 0 do return fail(api, .Unsupported, "the control isn't used that way")
	surface_play(api, m)
	return .Ok
}

// Surface `index`'s virtual controller (its controls from its fsurf.layout,
// for the app to draw and play), or nil when it has none or isn't running.
surface_virtual :: proc(api: ^Api, index: i64) -> ^fsurf.Virtual {
	v, r := virtual_of(api, index)
	return v if r == .Ok else nil
}

// Plays a virtual controller's messages into Pads' MIDI input, on the
// surface's port, as its controller would (through the claim table).
surface_play :: proc(api: ^Api, msgs: fsurf.Virtual_Messages) {
	m := msgs
	if m.port == abi.NO_PORT || m.port > 255 do return
	for i in 0 ..< m.count do midi.input_push_short(&api.core.host.midi_in, rt.host_time_ns(), u8(m.port), m.bytes[i])
}
