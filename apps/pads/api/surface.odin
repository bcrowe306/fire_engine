package pads_api

import "core:fmt"
import "core:strings"

import "fire:surface"

// The name a surface asks fire:surface's `get_extension` for, with
// `VERSION`, to get this API's C function table (`Pads_Api_V1`).
EXTENSION_NAME :: "fire.pads"

@(private)
Loaded_Surface :: struct {
	instance: ^surface.Instance,
	path:     string, // owned
	name:     string, // owned
	owner:    i64,    // what its subscriptions made while it started are tagged with
}

// Loads the control-surface library at `path` (a .dylib, .so or .dll
// exporting `fire_surface_entry`) and starts its surface `index`, which
// gets this API by asking for "fire.pads" version 1: its place among the
// surfaces running. Io_Error if the library won't load; Not_Found if it
// has no surface `index` (of an ABI this Pads loads); Unsupported if the
// surface won't start. MIDI ports of its own aren't given yet.
surface_load :: proc(api: ^Api, path: string, index: i64 = 0) -> (i64, Result) {
	m := surface_manager(api)
	if m == nil do return 0, fail(api, .Unsupported, "no surface manager")
	lib, err := surface.library_open(m, path)
	if err != .None do return 0, failf(api, .Io_Error, "could not load the surface library ", path)
	defer surface.library_close(m, lib) // (a running surface keeps it)
	if index < 0 || index >= i64(len(lib.surfaces)) do return 0, fail(api, .Not_Found, "the library has no such surface")
	api.next_owner += 1
	api.owner = api.next_owner
	inst, serr := surface.surface_start(m, lib, int(index), {})
	api.owner = 0
	if serr != .None {
		drop_owned(api, api.next_owner)
		return 0, fail(api, .Unsupported, "the surface would not start")
	}
	append(&api.surfaces, Loaded_Surface{instance = inst, path = strings.clone(path), name = strings.clone(string(lib.surfaces[index].name)), owner = api.next_owner})
	return i64(len(api.surfaces) - 1), .Ok
}

// The surfaces running.
surface_count :: proc(api: ^Api) -> (i64, Result) {
	return i64(len(api.surfaces)), .Ok
}

// Surface `index`'s name, as its library gives it ("Fire Mini"). Temporary.
surface_name :: proc(api: ^Api, index: i64) -> (string, Result) {
	if index < 0 || index >= i64(len(api.surfaces)) do return "", fail(api, .Not_Found, "no such surface")
	return api.surfaces[index].name, .Ok
}

// The library surface `index` came from. Temporary.
surface_path :: proc(api: ^Api, index: i64) -> (string, Result) {
	if index < 0 || index >= i64(len(api.surfaces)) do return "", fail(api, .Not_Found, "no such surface")
	return api.surfaces[index].path, .Ok
}

// Stops surface `index` (the ones after it move down one); its library
// unloads when nothing else uses it. What it subscribed while it started
// goes with it; a surface unsubscribes the rest in its `destroy`.
surface_unload :: proc(api: ^Api, index: i64) -> Result {
	if index < 0 || index >= i64(len(api.surfaces)) do return fail(api, .Not_Found, "no such surface")
	s := api.surfaces[index]
	ordered_remove(&api.surfaces, int(index))
	surface.surface_stop(api.manager, s.instance)
	drop_owned(api, s.owner)
	delete(s.path)
	delete(s.name)
	return .Ok
}

// The manager, made the first time a surface loads.
@(private)
surface_manager :: proc(api: ^Api) -> ^surface.Manager {
	if api.manager != nil do return api.manager
	m, err := surface.manager_create({
		user = api,
		extension = proc(user: rawptr, name: string, version: u32) -> rawptr {
			api := (^Api)(user)
			if name == EXTENSION_NAME && version == VERSION do return &api.table
			return nil
		},
		log = proc(user: rawptr, level: i32, message: string) {
			fmt.eprintfln("surface: %s", message)
		},
	})
	if err != .None do return nil
	api.manager = m
	return m
}

// Stops every surface and the manager.
@(private)
surfaces_destroy :: proc(api: ^Api) {
	for len(api.surfaces) > 0 do surface_unload(api, i64(len(api.surfaces) - 1))
	delete(api.surfaces)
	if api.manager != nil do surface.manager_destroy(api.manager)
	api.manager = nil
}

// Drops the subscriptions tagged `owner`.
@(private)
drop_owned :: proc(api: ^Api, owner: i64) {
	if owner == 0 do return
	for k := len(api.subs) - 1; k >= 0; k -= 1 do if api.subs[k].owner == owner do ordered_remove(&api.subs, k)
}
