package clap

import "core:mem"

import "fire:core"

// Saved-state ID of hosted plug-ins (`plugin_create`): the library's path,
// the plug-in's id, the host settings and the plug-in's own state.
PLUGIN_TYPE_ID :: "fire.clap"

// Registers hosted plug-ins. Loaded plug-ins log through `log` (nil:
// dropped). A plug-in whose library or id is missing loads as a
// placeholder, keeping its state. Control thread (the plug-ins' main
// thread).
register_types :: proc(reg: ^core.Node_Registry, log: proc(severity: i32, message: string) = nil) -> core.Error {
	return core.register_type(reg, {id = PLUGIN_TYPE_ID, load = load_plugin, data = rawptr(log)})
}

@(private)
save_plugin :: proc(self: rawptr, w: ^core.State_Writer, ctx: ^core.Save_Context) -> core.Error {
	p := (^Plugin)(self)
	core.write_path(w, ctx, p.library.path)
	core.write_string(w, p.id)
	core.write_u32(w, p.settings.timeline.index)
	core.write_u32(w, p.settings.timeline.generation)
	core.write_int(w, p.settings.max_events)
	state, err := plugin_save_state(p, context.temp_allocator)
	#partial switch err {
	case .None:        core.write_bool(w, true); core.write_bytes(w, state)
	case .Unsupported: core.write_bool(w, false)
	case:              return err
	}
	return .None
}

@(private)
load_plugin :: proc(data: rawptr, r: ^core.State_Reader, version: u32, ctx: ^core.Load_Context, allocator: mem.Allocator) -> (core.Node, core.Error) {
	path := core.read_path(r, ctx, context.temp_allocator)
	id := core.read_string(r)
	settings: Host_Settings
	settings.timeline = {core.read_u32(r), core.read_u32(r)}
	if settings.timeline != {} do settings.timeline = core.load_timeline(ctx, settings.timeline)
	settings.max_events = core.read_int(r)
	settings.log = auto_cast data
	has_state := core.read_bool(r)
	state := core.read_bytes(r) if has_state else nil
	if r.err != .None do return {}, .Invalid_Data
	lib, lerr := library_open(path)
	if lerr != .None do return {}, lerr
	defer library_close(lib) // the plug-in keeps the library open
	node, p, err := plugin_create(lib, id, settings, allocator)
	if err != .None do return {}, err
	if has_state {
		if e := plugin_load_state(p, state); e != .None {
			core.node_destroy(&node)
			return {}, e
		}
	}
	return node, .None
}
