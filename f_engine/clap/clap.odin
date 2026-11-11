/*
Hosting CLAP plug-ins (CLever Audio Plug-in, an open standard) as graph
nodes.

A `Library` is one .clap file (on macOS, a .clap bundle), opened once and
shared; it lists the plug-ins in it. `plugin_create` makes one as a
`core.Node`: its CLAP parameters are the node's parameters (same ids), its
audio ports are the node's channels in order, notes, per-note expression,
parameter changes and MIDI go in as events and come out the same way, and
the clock reaches it as CLAP's transport. Its latency is the node's.

	lib, _ := clap.library_open("/Library/Audio/Plug-Ins/CLAP/Surge XT.clap")
	defer clap.library_close(lib)
	node, p, err := clap.plugin_create(lib, lib.plugins[0].id, {})
	id, _ := graph.add_node(g, node, 0, 2) // an instrument: notes in, stereo out
	graph.connect_events(g, player, id)
	// on the control thread, regularly:
	clap.plugin_idle(p)

Threads: create, the state, editor and idle calls, and the node's prepare
and release belong to one thread, CLAP's "main thread"; the graph's audio
thread processes. `fire:clap/sdk` goes the other way: it makes CLAP
plug-ins from Fire Engine nodes.
*/
package clap

import "base:intrinsics"
import "base:runtime"
import "core:dynlib"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"

import "fire:core"
import c "fire:sys/clap"

// What a library says a plug-in is. Strings belong to the library.
Plugin_Description :: struct {
	id:          string,
	name:        string,
	vendor:      string,
	version:     string,
	description: string,
	features:    []string, // CLAP's feature tags: "instrument", "audio-effect", ...
}

// An open .clap library. Its plug-ins stay valid while it is open, and it
// stays open while any of its plug-ins exist. Opening the same path again
// returns the same library (CLAP libraries are initialized once per
// load). Fields other than `path` and `plugins` are internal.
Library :: struct {
	path:      string,
	plugins:   []Plugin_Description,
	lib:       dynlib.Library,
	entry:     ^c.Plugin_Entry,
	factory:   ^c.Plugin_Factory,
	refs:      int, // under `libraries_lock`
	allocator: mem.Allocator,
}

// Every open library, so a path is loaded and initialized once.
@(private) libraries: [dynamic]^Library
@(private) libraries_lock: sync.Mutex

// Control thread. Opens the library at `path` (a .clap file, or a macOS
// .clap bundle) and lists its plug-ins, or returns the one already open
// there (one more reference; paths are compared made absolute and
// cleaned, so `a/../b.clap` and `b.clap` are one library: CLAP initializes a
// library once). Libraries are shared by the whole process,
// so they live in the heap allocator, whoever opens them. `.Device_Error`
// if it doesn't load or isn't a compatible CLAP library. Close with
// `library_close`.
library_open :: proc(path: string) -> (l: ^Library, err: core.Error) {
	allocator := runtime.heap_allocator()
	path := path
	if abs, aerr := filepath.abs(path, context.temp_allocator); aerr == nil {
		path, _ = filepath.clean(abs, context.temp_allocator)
	}
	sync.guard(&libraries_lock)
	for x in libraries do if x.path == path {
		x.refs += 1
		return x, .None
	}
	binary := binary_path(path, context.temp_allocator)
	lib, ok := dynlib.load_library(binary)
	if !ok do return nil, .Device_Error
	entry := (^c.Plugin_Entry)(dynlib.symbol_address(lib, c.ENTRY_SYMBOL))
	if entry == nil || !c.version_is_compatible(entry.clap_version) {
		dynlib.unload_library(lib)
		return nil, .Device_Error
	}
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	if !entry.init(cpath) {
		dynlib.unload_library(lib)
		return nil, .Device_Error
	}
	factory := (^c.Plugin_Factory)(entry.get_factory(c.PLUGIN_FACTORY_ID))
	if factory == nil {
		entry.deinit()
		dynlib.unload_library(lib)
		return nil, .Device_Error
	}
	l = new(Library, allocator)
	l^ = {path = strings.clone(path, allocator), lib = lib, entry = entry, factory = factory, refs = 1, allocator = allocator}
	n := factory.get_plugin_count(factory)
	plugins := make([dynamic]Plugin_Description, allocator)
	for i in 0 ..< n {
		d := factory.get_plugin_descriptor(factory, i)
		if d == nil || !c.version_is_compatible(d.clap_version) do continue
		p := Plugin_Description{id = text(d.id, allocator), name = text(d.name, allocator), vendor = text(d.vendor, allocator), version = text(d.version, allocator), description = text(d.description, allocator)}
		features := make([dynamic]string, allocator)
		if d.features != nil do for k := 0; d.features[k] != nil; k += 1 do append(&features, text(d.features[k], allocator))
		p.features = features[:]
		append(&plugins, p)
	}
	l.plugins = plugins[:]
	if libraries == nil do libraries = make([dynamic]^Library, runtime.heap_allocator())
	append(&libraries, l)
	return l, .None
}

// Control thread. Drops a reference; the last unloads the library.
library_close :: proc(l: ^Library) {
	if l == nil do return
	sync.guard(&libraries_lock)
	l.refs -= 1
	if l.refs > 0 do return
	for x, i in libraries do if x == l {
		unordered_remove(&libraries, i)
		break
	}
	l.entry.deinit()
	dynlib.unload_library(l.lib)
	a := l.allocator
	for p in l.plugins {
		delete(p.id, a)
		delete(p.name, a)
		delete(p.vendor, a)
		delete(p.version, a)
		delete(p.description, a)
		for f in p.features do delete(f, a)
		delete(p.features, a)
	}
	delete(l.plugins, a)
	delete(l.path, a)
	free(l, a)
}

@(private)
retain :: proc(l: ^Library) {
	sync.guard(&libraries_lock)
	l.refs += 1
}

// The file to load for `path`: in a macOS bundle, Contents/MacOS/<name>.
@(private)
binary_path :: proc(path: string, allocator: mem.Allocator) -> string {
	when ODIN_OS == .Darwin {
		if os.is_dir(path) {
			name := strings.trim_suffix(filepath.base(path), ".clap")
			candidate, _ := filepath.join({path, "Contents", "MacOS", name}, allocator)
			if os.exists(candidate) do return candidate
			dir, _ := filepath.join({path, "Contents", "MacOS"}, allocator)
			if entries, err := os.read_all_directory_by_path(dir, allocator); err == nil && len(entries) > 0 do return entries[0].fullpath
		}
	}
	return path
}

@(private)
text :: proc(s: cstring, allocator: mem.Allocator) -> string {
	return strings.clone(string(s), allocator) if s != nil else ""
}

// The folders CLAP plug-ins are installed in on this system, then those in
// the CLAP_PATH environment variable. Owned by `allocator`.
default_search_paths :: proc(allocator := context.allocator) -> []string {
	out := make([dynamic]string, allocator)
	env :: proc(name: string) -> string { return os.get_env(name, context.temp_allocator) }
	join :: proc(parts: []string, allocator: mem.Allocator) -> string { s, _ := filepath.join(parts, allocator); return s }
	when ODIN_OS == .Darwin {
		append(&out, join({env("HOME"), "Library/Audio/Plug-Ins/CLAP"}, allocator), strings.clone("/Library/Audio/Plug-Ins/CLAP", allocator))
	} else when ODIN_OS == .Windows {
		append(&out, join({env("COMMONPROGRAMFILES"), "CLAP"}, allocator), join({env("LOCALAPPDATA"), "Programs", "Common", "CLAP"}, allocator))
	} else {
		append(&out, join({env("HOME"), ".clap"}, allocator), strings.clone("/usr/lib/clap", allocator))
	}
	separator := ";" if ODIN_OS == .Windows else ":"
	for p in strings.split(env("CLAP_PATH"), separator, context.temp_allocator) do if p != "" do append(&out, strings.clone(p, allocator))
	return out[:]
}

// Control thread. The .clap files and bundles in `folders` and below.
// Owned by `allocator`. Open them with `library_open` to see what's inside
// (opening runs the library's code).
find_libraries :: proc(folders: []string, allocator := context.allocator) -> []string {
	out := make([dynamic]string, allocator)
	walk :: proc(dir: string, out: ^[dynamic]string, depth: int, allocator: mem.Allocator) {
		if depth > 8 do return
		entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
		if err != nil do return
		for e in entries {
			if strings.has_suffix(e.name, ".clap") {
				append(out, strings.clone(e.fullpath, allocator))
			} else if e.type == .Directory {
				walk(e.fullpath, out, depth + 1, allocator)
			}
		}
	}
	for f in folders do walk(f, &out, 0, allocator)
	return out[:]
}

// --- hosting a plug-in ---------------------------------------------------------------------

// Settings for `plugin_create`.
Host_Settings :: struct {
	timeline:   core.Timeline_Id, // the timeline the plug-in sees as its transport; zero = the leader
	max_events: int, // events per process call, in and out; 0 = 2048
	log:        proc(severity: i32, message: string), // the plug-in's log messages; nil = dropped
}

// What a plug-in has asked the host for since the last `plugin_idle`.
Requests :: struct {
	restart:        bool, // release and prepare the node again (re-add it to the graph)
	params_changed: bool, // its parameters changed (names, ranges, count): read `node_params` again
	latency:        bool, // its latency changed: re-commit the graph
	gui_resize:     bool, // the editor wants `gui_size`
	gui_size:       [2]u32,
	gui_closed:     bool, // the user closed a floating editor
}

// A hosted plug-in. The node made with it owns it. Procs not marked [rt]
// are for the main (control) thread. Fields are internal.
Plugin :: struct {
	library:      ^Library,
	id:           string, // the plug-in's id in the library
	plugin:       ^c.Plugin,
	host:         c.Host,
	settings:     Host_Settings,
	allocator:    mem.Allocator,
	// Extensions.
	params:       ^c.Plugin_Params,
	audio_ports:  ^c.Plugin_Audio_Ports,
	note_ports:   ^c.Plugin_Note_Ports,
	latency_ext:  ^c.Plugin_Latency,
	state:        ^c.Plugin_State,
	gui:          ^c.Plugin_Gui,
	// What the node shows.
	infos:        []core.Param_Info,
	names:        []string,
	cookies:      []rawptr, // per parameter, for its events
	values:       []f64, // audio side: each parameter's last value, as sent or reported
	in_ports:     []int, // channels per audio input port
	out_ports:    []int,
	// Threads.
	main_thread:  int,
	audio_thread: int, // atomic
	// Requests (atomic flags; the plug-in may set them from any thread).
	restart, callback, rescan, latency_changed, gui_resize, gui_closed: bool,
	gui_w, gui_h: u32,
	gui_open:     bool,
	// The audio side, prepared.
	active:       bool,
	latency:      int, // as the plug-in said when activated
	started:      bool,
	steady:       i64,
	in_bufs:      []c.Audio_Buffer,
	out_bufs:     []c.Audio_Buffer,
	in_ptrs:      [][^]f32,
	out_ptrs:     [][^]f32,
	silence:      []f32, // for ports past the node's inputs
	scratch:      [][]f32, // for ports past the node's outputs
	slots:        []Event_Slot,
	n_slots:      int,
	in_list:      c.Input_Events,
	out_list:     c.Output_Events,
	writer:       ^core.Event_Writer, // this call's output, for try_push
	transport:    c.Event_Transport,
	ramps:        [MAX_RAMPS]Ramp,
}

// One event of any kind in the input list.
@(private)
Event_Slot :: struct #raw_union {
	header: c.Event_Header,
	note:   c.Event_Note,
	expr:   c.Event_Note_Expression,
	param:  c.Event_Param_Value,
	midi:   c.Event_Midi,
}

// A parameter ramp in progress: CLAP has no ramps, so the host sends
// values along it.
@(private)
Ramp :: struct {
	param:  core.Param_Id,
	start:  f64,
	target: f64,
	slope:  f64, // per frame
	done:   int, // frames into the ramp
	left:   int, // frames to go
	begin:  int, // where in this call it resumes (its event's offset in the call it starts)
	due:    bool, // a value falls on the next call's first frame
}

@(private) MAX_RAMPS :: 64
// Frames between the values sent along a ramp.
@(private) RAMP_STEP :: 32

@(private)
plugin_vtable := core.Node_VTable {
	prepare = plugin_prepare,
	process = plugin_process,
	reset   = proc(self: rawptr) {
		p := (^Plugin)(self)
		if p.started do p.plugin.reset(p.plugin)
		p.ramps = {}
	},
	release = plugin_release,
	latency = proc(self: rawptr) -> int { return (^Plugin)(self).latency },
	params  = proc(self: rawptr) -> []core.Param_Info { return (^Plugin)(self).infos },
	destroy = proc(self: rawptr, allocator: mem.Allocator) { plugin_free((^Plugin)(self)) },
	type_id = PLUGIN_TYPE_ID,
	state_version = 1,
	save    = save_plugin,
}

// Control thread (from here on, the plug-in's main thread). Makes the
// plug-in `id` of `lib` as a node; the library stays open while it exists.
// `.Invalid_Argument` for an unknown id, `.Device_Error` if the plug-in
// fails to start.
plugin_create :: proc(lib: ^Library, id: string, settings: Host_Settings, allocator := context.allocator) -> (node: core.Node, p: ^Plugin, err: core.Error) {
	known := false
	for d in lib.plugins do known ||= d.id == id
	if !known do return {}, nil, .Invalid_Argument
	p = new(Plugin, allocator)
	p.library, p.settings, p.allocator = lib, settings, allocator
	p.id = strings.clone(id, allocator)
	if p.settings.max_events <= 0 do p.settings.max_events = 2048
	p.main_thread = sync.current_thread_id()
	p.host = {
		clap_version = c.VERSION, host_data = p,
		name = "Fire Engine", vendor = "Fire Engine", url = "", version = "0.1",
		get_extension = host_get_extension,
		request_restart = proc "c" (h: ^c.Host) { intrinsics.atomic_store(&host_plugin(h).restart, true) },
		request_process = proc "c" (h: ^c.Host) {}, // the graph processes every node every block
		request_callback = proc "c" (h: ^c.Host) { intrinsics.atomic_store(&host_plugin(h).callback, true) },
	}
	retain(lib)
	cid := strings.clone_to_cstring(id, context.temp_allocator)
	p.plugin = lib.factory.create_plugin(lib.factory, &p.host, cid)
	if p.plugin == nil || !p.plugin.init(p.plugin) {
		if p.plugin != nil do p.plugin.destroy(p.plugin)
		library_close(lib)
		delete(p.id, allocator)
		free(p, allocator)
		return {}, nil, .Device_Error
	}
	ext :: proc(p: ^Plugin, id: cstring, $T: typeid) -> ^T { return (^T)(p.plugin.get_extension(p.plugin, id)) }
	p.params = ext(p, c.EXT_PARAMS, c.Plugin_Params)
	p.audio_ports = ext(p, c.EXT_AUDIO_PORTS, c.Plugin_Audio_Ports)
	p.note_ports = ext(p, c.EXT_NOTE_PORTS, c.Plugin_Note_Ports)
	p.latency_ext = ext(p, c.EXT_LATENCY, c.Plugin_Latency)
	p.state = ext(p, c.EXT_STATE, c.Plugin_State)
	p.gui = ext(p, c.EXT_GUI, c.Plugin_Gui)
	read_params(p)
	read_ports(p)
	return core.node_make(&plugin_vtable, p, allocator), p, .None
}

// The audio channels the plug-in's ports want: inputs and outputs (add
// the node with these). Control thread.
plugin_channels :: proc(p: ^Plugin) -> (inputs, outputs: int) {
	for n in p.in_ports do inputs += n
	for n in p.out_ports do outputs += n
	return
}

@(private)
host_plugin :: #force_inline proc "contextless" (h: ^c.Host) -> ^Plugin {
	return (^Plugin)(h.host_data)
}

// Reads the parameter table. Names in `p.allocator`.
@(private)
read_params :: proc(p: ^Plugin) {
	for n in p.names do delete(n, p.allocator)
	delete(p.names, p.allocator)
	delete(p.infos, p.allocator)
	delete(p.cookies, p.allocator)
	n := int(p.params.count(p.plugin)) if p.params != nil else 0
	p.infos = make([]core.Param_Info, n, p.allocator)
	p.names = make([]string, n, p.allocator)
	p.cookies = make([]rawptr, n, p.allocator)
	for i in 0 ..< n {
		info: c.Param_Info
		if !p.params.get_info(p.plugin, u32(i), &info) do continue
		p.names[i] = strings.clone(string(cstring(&info.name[0])), p.allocator)
		flags: core.Param_Flags
		if info.flags & c.PARAM_IS_AUTOMATABLE != 0 do flags += {.Automatable}
		if info.flags & c.PARAM_IS_STEPPED != 0 do flags += {.Stepped}
		if info.flags & c.PARAM_IS_HIDDEN != 0 do flags += {.Hidden}
		p.infos[i] = {id = core.Param_Id(info.id), name = p.names[i], min = info.min_value, max = info.max_value, default = info.default_value, flags = flags}
		p.cookies[i] = info.cookie
	}
}

@(private)
read_ports :: proc(p: ^Plugin) {
	delete(p.in_ports, p.allocator)
	delete(p.out_ports, p.allocator)
	ports :: proc(p: ^Plugin, input: bool) -> []int {
		n := int(p.audio_ports.count(p.plugin, input)) if p.audio_ports != nil else 0
		out := make([]int, n, p.allocator)
		for i in 0 ..< n {
			info: c.Audio_Port_Info
			if p.audio_ports.get(p.plugin, u32(i), input, &info) do out[i] = int(info.channel_count)
		}
		return out
	}
	p.in_ports, p.out_ports = ports(p, true), ports(p, false)
}

// --- host extensions ----------------------------------------------------------------------

@(private)
host_get_extension :: proc "c" (h: ^c.Host, id: cstring) -> rawptr {
	switch string(id) {
	case c.EXT_THREAD_CHECK: return &host_thread_check
	case c.EXT_LOG:          return &host_log
	case c.EXT_PARAMS:       return &host_params
	case c.EXT_LATENCY:      return &host_latency
	case c.EXT_GUI:          return &host_gui
	}
	return nil
}

@(private)
host_thread_check := c.Host_Thread_Check {
	is_main_thread = proc "c" (h: ^c.Host) -> bool { return sync.current_thread_id() == host_plugin(h).main_thread },
	is_audio_thread = proc "c" (h: ^c.Host) -> bool { return sync.current_thread_id() == intrinsics.atomic_load(&host_plugin(h).audio_thread) },
}

@(private)
host_log := c.Host_Log {
	log = proc "c" (h: ^c.Host, severity: i32, msg: cstring) {
		p := host_plugin(h)
		if p.settings.log == nil || msg == nil do return
		context = runtime.default_context()
		p.settings.log(severity, string(msg))
	},
}

@(private)
host_params := c.Host_Params {
	rescan = proc "c" (h: ^c.Host, flags: u32) {
		if flags & (c.PARAM_RESCAN_INFO | c.PARAM_RESCAN_ALL) != 0 do intrinsics.atomic_store(&host_plugin(h).rescan, true)
	},
	clear = proc "c" (h: ^c.Host, id: c.Id, flags: u32) {},
	request_flush = proc "c" (h: ^c.Host) {}, // the graph calls process every block, which flushes
}

@(private)
host_latency := c.Host_Latency {
	changed = proc "c" (h: ^c.Host) { intrinsics.atomic_store(&host_plugin(h).latency_changed, true) },
}

@(private)
host_gui := c.Host_Gui {
	resize_hints_changed = proc "c" (h: ^c.Host) {},
	request_resize = proc "c" (h: ^c.Host, w, hh: u32) -> bool {
		p := host_plugin(h)
		intrinsics.atomic_store(&p.gui_w, w)
		intrinsics.atomic_store(&p.gui_h, hh)
		intrinsics.atomic_store(&p.gui_resize, true)
		return true
	},
	request_show = proc "c" (h: ^c.Host) -> bool { return false },
	request_hide = proc "c" (h: ^c.Host) -> bool { return false },
	closed = proc "c" (h: ^c.Host, was_destroyed: bool) { intrinsics.atomic_store(&host_plugin(h).gui_closed, true) },
}

// Main thread. Runs what the plug-in asked to do on the main thread, and
// returns what it asked of the host. Call it regularly (every UI frame).
plugin_idle :: proc(p: ^Plugin) -> (r: Requests) {
	if intrinsics.atomic_exchange(&p.callback, false) do p.plugin.on_main_thread(p.plugin)
	r.restart = intrinsics.atomic_exchange(&p.restart, false)
	if intrinsics.atomic_exchange(&p.rescan, false) {
		read_params(p)
		r.params_changed = true
	}
	r.latency = intrinsics.atomic_exchange(&p.latency_changed, false)
	if intrinsics.atomic_exchange(&p.gui_resize, false) {
		r.gui_resize, r.gui_size = true, {intrinsics.atomic_load(&p.gui_w), intrinsics.atomic_load(&p.gui_h)}
	}
	r.gui_closed = intrinsics.atomic_exchange(&p.gui_closed, false)
	return
}

// Main thread. A parameter's current value, as the plug-in has it.
plugin_param_value :: proc(p: ^Plugin, id: core.Param_Id) -> (value: f64, ok: bool) {
	if p.params == nil do return 0, false
	ok = p.params.get_value(p.plugin, c.Id(id), &value)
	return
}

// Main thread. A parameter value as the plug-in displays it ("−6.0 dB").
plugin_param_text :: proc(p: ^Plugin, id: core.Param_Id, value: f64, allocator := context.allocator) -> string {
	if p.params == nil do return ""
	buf: [256]u8
	if !p.params.value_to_text(p.plugin, c.Id(id), value, &buf[0], len(buf)) do return ""
	return strings.clone(string(cstring(&buf[0])), allocator)
}

// --- state ---------------------------------------------------------------------------------

// Main thread. The plug-in's state (everything it needs to be restored
// later), owned by `allocator`. `.Unsupported` if it keeps none.
plugin_save_state :: proc(p: ^Plugin, allocator := context.allocator) -> (data: []u8, err: core.Error) {
	if p.state == nil do return nil, .Unsupported
	buf := make([dynamic]u8, allocator)
	s := c.Ostream {
		ctx = &buf,
		write = proc "c" (s: ^c.Ostream, data: rawptr, size: u64) -> i64 {
			context = runtime.default_context()
			b := (^[dynamic]u8)(s.ctx)
			append(b, ..([^]u8)(data)[:size])
			return i64(size)
		},
	}
	if !p.state.save(p.plugin, &s) {
		delete(buf)
		return nil, .Device_Error
	}
	return buf[:], .None
}

// Main thread. Restores state saved by `plugin_save_state` (from this
// plug-in, or the same plug-in elsewhere).
plugin_load_state :: proc(p: ^Plugin, data: []u8) -> core.Error {
	if p.state == nil do return .Unsupported
	Reader :: struct {
		data: []u8,
		at:   int,
	}
	r := Reader{data = data}
	s := c.Istream {
		ctx = &r,
		read = proc "c" (s: ^c.Istream, buffer: rawptr, size: u64) -> i64 {
			r := (^Reader)(s.ctx)
			n := min(int(size), len(r.data) - r.at)
			if n > 0 do intrinsics.mem_copy(buffer, &r.data[r.at], n)
			r.at += n
			return i64(n)
		},
	}
	return .None if p.state.load(p.plugin, &s) else .Device_Error
}

// --- editors -------------------------------------------------------------------------------

// The kinds of native window an editor can be embedded in.
Window_Api :: enum u8 {
	Cocoa, // an NSView
	Win32, // an HWND
	X11,   // an X11 Window id
}

// A native window to embed an editor in.
Window :: struct {
	api:    Window_Api,
	handle: uintptr, // the NSView pointer, HWND, or X11 window id
}

@(private)
api_name :: proc "contextless" (a: Window_Api) -> cstring {
	switch a {
	case .Cocoa: return c.WINDOW_API_COCOA
	case .Win32: return c.WINDOW_API_WIN32
	case .X11:   return c.WINDOW_API_X11
	}
	return ""
}

// Main thread. Whether the plug-in has an editor it can embed in `api`.
plugin_gui_supported :: proc(p: ^Plugin, api: Window_Api) -> bool {
	return p.gui != nil && p.gui.is_api_supported(p.plugin, api_name(api), false)
}

// Main thread. Opens the plug-in's editor inside `parent` and returns the
// size it wants (in pixels, or points on macOS). `.Unsupported` without an
// embeddable editor for that window kind. Close with `plugin_gui_close`.
plugin_gui_open :: proc(p: ^Plugin, parent: Window) -> (width, height: u32, err: core.Error) {
	if !plugin_gui_supported(p, parent.api) do return 0, 0, .Unsupported
	if p.gui_open do return 0, 0, .Invalid_State
	api := api_name(parent.api)
	if !p.gui.create(p.plugin, api, false) do return 0, 0, .Device_Error
	w := c.Window{api = api}
	switch parent.api {
	case .Cocoa: w.cocoa = rawptr(parent.handle)
	case .Win32: w.win32 = rawptr(parent.handle)
	case .X11:   w.x11 = auto_cast parent.handle
	}
	if !p.gui.set_parent(p.plugin, &w) {
		p.gui.destroy(p.plugin)
		return 0, 0, .Device_Error
	}
	p.gui.get_size(p.plugin, &width, &height)
	p.gui.show(p.plugin)
	p.gui_open = true
	return width, height, .None
}

// Main thread. Resizes the open editor to the nearest size it allows
// (returned), when it can be resized.
plugin_gui_set_size :: proc(p: ^Plugin, width, height: u32) -> (w, h: u32, ok: bool) {
	if !p.gui_open || !p.gui.can_resize(p.plugin) do return 0, 0, false
	w, h = width, height
	p.gui.adjust_size(p.plugin, &w, &h)
	return w, h, p.gui.set_size(p.plugin, w, h)
}

// Main thread. Closes the editor.
plugin_gui_close :: proc(p: ^Plugin) {
	if !p.gui_open do return
	p.gui.hide(p.plugin)
	p.gui.destroy(p.plugin)
	p.gui_open = false
}

// --- the node ------------------------------------------------------------------------------

@(private)
plugin_prepare :: proc(self: rawptr, cfg: core.Prepare_Config, allocator: mem.Allocator) -> core.Error {
	p := (^Plugin)(self)
	if !p.plugin.activate(p.plugin, cfg.sample_rate, 1, u32(cfg.max_block)) do return .Device_Error
	p.active, p.steady = true, 0
	p.latency = int(p.latency_ext.get(p.plugin)) if p.latency_ext != nil else 0 // CLAP answers only while active
	ins, outs := plugin_channels(p)
	ae: mem.Allocator_Error
	p.in_bufs, ae = make([]c.Audio_Buffer, len(p.in_ports), allocator)
	if ae == nil do p.out_bufs, ae = make([]c.Audio_Buffer, len(p.out_ports), allocator)
	if ae == nil do p.in_ptrs, ae = make([][^]f32, ins, allocator)
	if ae == nil do p.out_ptrs, ae = make([][^]f32, outs, allocator)
	if ae == nil do p.silence, ae = make([]f32, cfg.max_block, allocator)
	if ae == nil do p.scratch, ae = make([][]f32, outs, allocator)
	if ae == nil do for &s in p.scratch do if ae == nil do s, ae = make([]f32, cfg.max_block, allocator)
	if ae == nil do p.slots, ae = make([]Event_Slot, p.settings.max_events, allocator)
	if ae == nil do p.values, ae = make([]f64, len(p.infos), allocator)
	if ae != nil {
		plugin_release(p, allocator)
		return .Out_Of_Memory
	}
	for info, i in p.infos {
		p.values[i] = info.default
		if p.params != nil do p.params.get_value(p.plugin, c.Id(info.id), &p.values[i]) // here, on the main thread
	}
	k := 0
	for n, i in p.in_ports {
		p.in_bufs[i] = {data32 = raw_data(p.in_ptrs[k:]) if n > 0 else nil, channel_count = u32(n)}
		k += n
	}
	k = 0
	for n, i in p.out_ports {
		p.out_bufs[i] = {data32 = raw_data(p.out_ptrs[k:]) if n > 0 else nil, channel_count = u32(n)}
		k += n
	}
	p.in_list = {
		ctx = p,
		size = proc "c" (l: ^c.Input_Events) -> u32 { return u32((^Plugin)(l.ctx).n_slots) },
		get = proc "c" (l: ^c.Input_Events, i: u32) -> ^c.Event_Header {
			p := (^Plugin)(l.ctx)
			return &p.slots[i].header if int(i) < p.n_slots else nil
		},
	}
	p.out_list = {ctx = p, try_push = plugin_push}
	return .None
}

@(private)
plugin_release :: proc(self: rawptr, allocator: mem.Allocator) {
	p := (^Plugin)(self)
	// The audio thread has stopped calling: stopping on this thread is the
	// best a node can do (CLAP asks for the processing thread).
	if p.started do p.plugin.stop_processing(p.plugin)
	if p.active do p.plugin.deactivate(p.plugin)
	p.started, p.active = false, false
	delete(p.in_bufs, allocator)
	delete(p.out_bufs, allocator)
	delete(p.in_ptrs, allocator)
	delete(p.out_ptrs, allocator)
	delete(p.silence, allocator)
	for s in p.scratch do delete(s, allocator)
	delete(p.scratch, allocator)
	delete(p.slots, allocator)
	delete(p.values, allocator)
	p.in_bufs, p.out_bufs, p.in_ptrs, p.out_ptrs, p.silence, p.scratch, p.slots, p.values = nil, nil, nil, nil, nil, nil, nil, nil
}

@(private)
plugin_free :: proc(p: ^Plugin) {
	plugin_gui_close(p)
	if p.active do plugin_release(p, p.allocator)
	p.plugin.destroy(p.plugin)
	library_close(p.library)
	for n in p.names do delete(n, p.allocator)
	delete(p.names, p.allocator)
	delete(p.infos, p.allocator)
	delete(p.cookies, p.allocator)
	delete(p.in_ports, p.allocator)
	delete(p.out_ports, p.allocator)
	delete(p.id, p.allocator)
	free(p, p.allocator)
}

// [rt]
@(private)
plugin_process :: proc(self: rawptr, ctx: ^core.Process_Context) {
	p := (^Plugin)(self)
	n := ctx.frames
	if n <= 0 do return
	intrinsics.atomic_store(&p.audio_thread, sync.current_thread_id())
	if !p.started {
		if !p.plugin.start_processing(p.plugin) {
			for out in ctx.outputs do for &x in out do x = 0
			return
		}
		p.started = true
	}
	// Audio: the node's channels in port order; silence and scratch past them.
	for &ptr, i in p.in_ptrs do ptr = raw_data(ctx.inputs[i]) if i < len(ctx.inputs) else raw_data(p.silence)
	for &ptr, i in p.out_ptrs do ptr = raw_data(ctx.outputs[i]) if i < len(ctx.outputs) else raw_data(p.scratch[i])
	for out in ctx.outputs[min(len(ctx.outputs), len(p.out_ptrs)):] do for &x in out[:n] do x = 0
	gather_events(p, ctx)
	process := c.Process {
		steady_time = p.steady, frames_count = u32(n),
		transport = transport_of(p, ctx.transport),
		audio_inputs = raw_data(p.in_bufs), audio_outputs = raw_data(p.out_bufs),
		audio_inputs_count = u32(len(p.in_bufs)), audio_outputs_count = u32(len(p.out_bufs)),
		in_events = &p.in_list, out_events = &p.out_list,
	}
	p.writer = ctx.events_out
	p.plugin.process(p.plugin, &process)
	p.writer = nil
	p.steady += i64(n)
}

// [rt] The call's events, as CLAP events in time order: the context's, and
// values along any parameter ramps.
@(private)
gather_events :: proc "contextless" (p: ^Plugin, ctx: ^core.Process_Context) {
	p.n_slots = 0
	add :: proc "contextless" (p: ^Plugin) -> ^Event_Slot {
		if p.n_slots == len(p.slots) do return nil
		p.n_slots += 1
		return &p.slots[p.n_slots - 1]
	}
	head :: proc "contextless" (time: u32, type: u16, $T: typeid) -> c.Event_Header {
		return {size = size_of(T), time = time, space_id = c.CORE_EVENT_SPACE_ID, type = type}
	}
	for e in ctx.events_in {
		t := e.offset
		#partial switch v in e.payload {
		case core.Note_On:
			if s := add(p); s != nil do s.note = {head(t, c.EVENT_NOTE_ON, c.Event_Note), i32(v.id), 0, i16(v.channel), i16(v.key), f64(v.velocity)}
		case core.Note_Off:
			if s := add(p); s != nil do s.note = {head(t, c.EVENT_NOTE_OFF, c.Event_Note), i32(v.id), 0, i16(v.channel), i16(v.key), f64(v.velocity)}
		case core.Note_Choke:
			all := v.key == core.NOTE_KEY_ALL // CLAP's wildcard: -1
			if s := add(p); s != nil do s.note = {head(t, c.EVENT_NOTE_CHOKE, c.Event_Note), -1 if all else i32(v.id), 0, -1 if all else i16(v.channel), -1 if all else i16(v.key), 0}
		case core.Note_Expression:
			if s := add(p); s != nil do s.expr = {head(t, c.EVENT_NOTE_EXPRESSION, c.Event_Note_Expression), expression_id(v.kind), i32(v.id), 0, i16(v.channel), i16(v.key), v.value}
		case core.Param_Value:
			end_ramp(p, v.param)
			add_param(p, t, v.param, v.value)
		case core.Param_Ramp:
			start_ramp(p, t, v)
		case core.Midi_Raw:
			if s := add(p); s != nil do s.midi = {head(t, c.EVENT_MIDI, c.Event_Midi), u16(v.port), v.bytes}
		}
	}
	// Values along the ramps: every RAMP_STEP frames of the ramp (counted
	// from its start, whatever the blocks), and its target at its end.
	for &r in p.ramps do if r.left > 0 || r.due {
		at := r.begin
		r.begin = 0
		if r.due {
			add_param(p, 0, r.param, ramp_value(&r))
			r.due = false
		}
		for r.left > 0 {
			step := min(RAMP_STEP - r.done % RAMP_STEP, r.left)
			if at + step >= ctx.frames { // the next value is in a later call
				used := ctx.frames - at
				r.done += used
				r.left -= used
				r.due = at + step == ctx.frames // exactly on the next call's first frame
				break
			}
			at += step
			r.done += step
			r.left -= step
			add_param(p, u32(at), r.param, ramp_value(&r))
		}
	}
	// In time order (the ramps' values were appended after the rest).
	for i in 1 ..< p.n_slots {
		x := p.slots[i]
		j := i
		for j > 0 && p.slots[j - 1].header.time > x.header.time {
			p.slots[j] = p.slots[j - 1]
			j -= 1
		}
		p.slots[j] = x
	}
}

// [rt]
@(private)
add_param :: proc "contextless" (p: ^Plugin, t: u32, id: core.Param_Id, value: f64) {
	if p.n_slots == len(p.slots) do return
	cookie: rawptr
	for info, i in p.infos do if info.id == id {
		cookie = p.cookies[i]
		p.values[i] = value
	}
	p.slots[p.n_slots].param = {
		header = {size = size_of(c.Event_Param_Value), time = t, space_id = c.CORE_EVENT_SPACE_ID, type = c.EVENT_PARAM_VALUE},
		param_id = c.Id(id), cookie = cookie, note_id = -1, port_index = -1, channel = -1, key = -1, value = value,
	}
	p.n_slots += 1
}

// [rt] A ramp: the value at its start now, then values along it. (The
// first value goes out at the event's frame; the rest are sent as the
// ramp advances, this call and the next ones.)
@(private)
start_ramp :: proc "contextless" (p: ^Plugin, t: u32, v: core.Param_Ramp) {
	end_ramp(p, v.param)
	current := 0.0
	for info, i in p.infos do if info.id == v.param do current = p.values[i] // get_value is for the main thread
	if v.frames == 0 {
		add_param(p, t, v.param, v.target)
		return
	}
	for &r in p.ramps do if r.left == 0 && !r.due {
		r = {param = v.param, start = current, target = v.target, slope = (v.target - current) / f64(v.frames), left = int(v.frames), begin = int(t)}
		return
	}
	add_param(p, t, v.param, v.target) // no room for another ramp: jump
}

// [rt]
@(private)
end_ramp :: proc "contextless" (p: ^Plugin, id: core.Param_Id) {
	for &r in p.ramps do if (r.left > 0 || r.due) && r.param == id do r.left, r.due = 0, false
}

// [rt] Where a ramp is: exactly its target at its end.
@(private)
ramp_value :: proc "contextless" (r: ^Ramp) -> f64 {
	return r.target if r.left == 0 else r.start + r.slope * f64(r.done)
}

@(private)
expression_id :: proc "contextless" (k: core.Note_Expression_Kind) -> i32 {
	switch k {
	case .Volume:     return c.NOTE_EXPRESSION_VOLUME
	case .Pan:        return c.NOTE_EXPRESSION_PAN
	case .Tuning:     return c.NOTE_EXPRESSION_TUNING
	case .Vibrato:    return c.NOTE_EXPRESSION_VIBRATO
	case .Brightness: return c.NOTE_EXPRESSION_BRIGHTNESS
	case .Pressure:   return c.NOTE_EXPRESSION_PRESSURE
	}
	return c.NOTE_EXPRESSION_EXPRESSION
}

// [rt] An event the plug-in sends, into the node's events out.
@(private)
plugin_push :: proc "c" (l: ^c.Output_Events, h: ^c.Event_Header) -> bool {
	p := (^Plugin)(l.ctx)
	if p.writer == nil || h == nil || h.space_id != c.CORE_EVENT_SPACE_ID do return false
	payload: core.Event_Payload
	switch h.type {
	case c.EVENT_NOTE_ON, c.EVENT_NOTE_OFF, c.EVENT_NOTE_END, c.EVENT_NOTE_CHOKE:
		e := (^c.Event_Note)(h)
		id := core.Note_Id(e.note_id)
		if h.type == c.EVENT_NOTE_ON {
			payload = core.Note_On{id = id, channel = u8(max(e.channel, 0)), key = u8(max(e.key, 0)), velocity = f32(e.velocity)}
		} else {
			payload = core.Note_Off{id = id, channel = u8(max(e.channel, 0)), key = u8(max(e.key, 0)), velocity = f32(e.velocity)}
		}
	case c.EVENT_NOTE_EXPRESSION:
		e := (^c.Event_Note_Expression)(h)
		kind: core.Note_Expression_Kind
		switch e.expression_id {
		case c.NOTE_EXPRESSION_VOLUME:     kind = .Volume
		case c.NOTE_EXPRESSION_PAN:        kind = .Pan
		case c.NOTE_EXPRESSION_TUNING:     kind = .Tuning
		case c.NOTE_EXPRESSION_VIBRATO:    kind = .Vibrato
		case c.NOTE_EXPRESSION_BRIGHTNESS: kind = .Brightness
		case c.NOTE_EXPRESSION_PRESSURE:   kind = .Pressure
		case: return true
		}
		payload = core.Note_Expression{id = core.Note_Id(e.note_id), channel = u8(max(e.channel, 0)), key = u8(max(e.key, 0)), kind = kind, value = e.value}
	case c.EVENT_PARAM_VALUE: // the user moved it in the plug-in's editor
		e := (^c.Event_Param_Value)(h)
		for info, i in p.infos do if info.id == core.Param_Id(e.param_id) do p.values[i] = e.value
		payload = core.Param_Value{param = core.Param_Id(e.param_id), value = e.value}
	case c.EVENT_MIDI:
		e := (^c.Event_Midi)(h)
		payload = core.Midi_Raw{bytes = e.data, port = u8(e.port_index)}
	case:
		return true // other kinds are dropped
	}
	return core.event_writer_push(p.writer, {offset = h.time, payload = payload})
}

// [rt] CLAP's view of the clock: the chosen timeline (or the leader).
@(private)
transport_of :: proc "contextless" (p: ^Plugin, t: ^core.Transport) -> ^c.Event_Transport {
	if t == nil do return nil
	tr := &p.transport
	tr^ = {header = {size = size_of(c.Event_Transport), space_id = c.CORE_EVENT_SPACE_ID, type = c.EVENT_TRANSPORT}}
	tr.flags = c.TRANSPORT_HAS_TEMPO | c.TRANSPORT_HAS_BEATS_TIMELINE | c.TRANSPORT_HAS_SECONDS_TIMELINE | c.TRANSPORT_HAS_TIME_SIGNATURE
	tr.tempo = t.tempo_bpm
	tr.tempo_inc = t.tempo_slope * t.tempo_bpm / 60 / t.sample_rate // bpm per grid beat, as bpm per frame
	tr.tsig_num, tr.tsig_denom = u16(t.meter.numerator), u16(t.meter.denominator)
	id := p.settings.timeline if p.settings.timeline != {} else t.leader
	beats := f64(t.grid)
	if tl := core.transport_timeline(t, id); tl != nil {
		beats = f64(tl.position)
		if tl.playing do tr.flags |= c.TRANSPORT_IS_PLAYING
		if tl.looping {
			tr.flags |= c.TRANSPORT_IS_LOOP_ACTIVE
			tr.loop_start_beats = i64(f64(tl.loop_start) * f64(c.BEATTIME_FACTOR))
			tr.loop_end_beats = i64(f64(tl.loop_end) * f64(c.BEATTIME_FACTOR))
		}
	}
	tr.song_pos_beats = i64(beats * f64(c.BEATTIME_FACTOR))
	tr.song_pos_seconds = i64(beats * 60 / t.tempo_bpm * f64(c.SECTIME_FACTOR)) // at the current tempo
	tr.bar_start = i64(f64(t.bar_start) * f64(c.BEATTIME_FACTOR))
	tr.bar_number = i32(t.bar)
	return tr
}
