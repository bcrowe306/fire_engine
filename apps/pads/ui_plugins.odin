package pads

import "base:runtime"
import "core:fmt"
import "core:path/filepath"
import "core:strings"

import app "app:core"
import "app:ui"
import im "deps:imgui"
import "fire:clap"
import sdl "deps:sdl3"

// The CLAP plug-ins found: in the system's folders and the user's, each
// library opened once (on the main thread, one a frame, as CLAP asks) to
// list what is inside. Kept in plugins.ini beside settings.ini, so they
// are known at the next start without opening them again. A scan notes
// the library it is opening first: one that brings Pads down is blocked at
// the next start rather than crashing it again.
Plugin_Scan :: struct {
	entries:  [dynamic]Plugin_Entry,
	queue:    [dynamic]string, // libraries still to open
	total:    int,
	scanning: bool,
	cache:    app.Ini,
	filter:   [64]u8,
}

// A plug-in found (or a library that failed to open).
Plugin_Entry :: struct {
	path, id, name, vendor, version: string,
	effect:     bool, // an audio effect (it can go in an effect slot)
	instrument: bool,
	failed:     bool, // the library would not open
}

@(private)
plugins_cache_path :: proc(a: ^App) -> string {
	p, _ := filepath.join({settings_folder(a), "plugins.ini"}, context.temp_allocator)
	return p
}

// Reads what the last scan found; a library that crashed the last scan is
// blocked (and said so). Scans now if the settings ask.
plugins_load :: proc(a: ^App) {
	ps := &a.plugins
	ps.cache, _ = app.ini_load(plugins_cache_path(a))
	c := &ps.cache
	if crashed, ok := app.ini_get(c, "scan", "opening"); ok && crashed != "" {
		if !is_blocked(a, crashed) do append(&a.settings.blocked, strings.clone(crashed))
		ui.toast(&a.ws.toasts, .Warning, fmt.tprintf("%s stopped Pads during the last scan: it is blocked", filepath.base(crashed)))
		app.ini_set(c, "scan", "opening", "")
		app.ini_save(c, plugins_cache_path(a))
		settings_save(a)
	}
	for &sec in c.sections do if strings.has_prefix(sec.name, "plugin.") {
		g :: proc(c: ^app.Ini, sec, key: string) -> string { v, _ := app.ini_get(c, sec, key); return strings.clone(v) }
		append(&ps.entries, Plugin_Entry{
			path = g(c, sec.name, "path"), id = g(c, sec.name, "id"), name = g(c, sec.name, "name"),
			vendor = g(c, sec.name, "vendor"), version = g(c, sec.name, "version"),
			effect = app.ini_bool(c, sec.name, "effect", false), instrument = app.ini_bool(c, sec.name, "instrument", false),
			failed = app.ini_bool(c, sec.name, "failed", false),
		})
	}
	if a.settings.scan_on_start do plugins_scan(a)
}

// Frees the plug-in list.
plugins_destroy :: proc(ps: ^Plugin_Scan) {
	plugins_clear(ps)
	delete(ps.entries)
	for q in ps.queue do delete(q)
	delete(ps.queue)
	app.ini_destroy(&ps.cache)
}

@(private)
plugins_clear :: proc(ps: ^Plugin_Scan) {
	for e in ps.entries {
		delete(e.path)
		delete(e.id)
		delete(e.name)
		delete(e.vendor)
		delete(e.version)
	}
	clear(&ps.entries)
}

// The folders scanned: the system's (and CLAP_PATH's), then the user's.
plugin_folders :: proc(a: ^App) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	append(&out, ..clap.default_search_paths(context.temp_allocator))
	append(&out, ..a.settings.plugin_folders[:])
	return out[:]
}

// Starts a scan of every folder (it runs a library a frame).
plugins_scan :: proc(a: ^App) {
	ps := &a.plugins
	if ps.scanning do return
	plugins_clear(ps)
	for q in ps.queue do delete(q)
	clear(&ps.queue)
	for path in clap.find_libraries(plugin_folders(a), context.temp_allocator) do append(&ps.queue, strings.clone(path))
	ps.total = len(ps.queue)
	ps.scanning = true
}

// Each frame while scanning: the next library opened and listed.
plugins_scan_step :: proc(a: ^App) {
	ps := &a.plugins
	if !ps.scanning do return
	if len(ps.queue) == 0 {
		ps.scanning = false
		plugins_save(a)
		ui.toast(&a.ws.toasts, .Success, fmt.tprintf("Found %d plug-in%s", len(ps.entries), "" if len(ps.entries) == 1 else "s"))
		return
	}
	path := pop_front(&ps.queue)
	defer delete(path)
	if is_blocked(a, path) {
		append(&ps.entries, Plugin_Entry{path = strings.clone(path), name = strings.clone(filepath.stem(path)), failed = true})
		return
	}
	// Noted first: if opening it brings Pads down, the next start knows.
	app.ini_set(&ps.cache, "scan", "opening", path)
	app.ini_save(&ps.cache, plugins_cache_path(a))
	lib, err := clap.library_open(path)
	if err != .None {
		append(&ps.entries, Plugin_Entry{path = strings.clone(path), name = strings.clone(filepath.stem(path)), failed = true})
	} else {
		for d in lib.plugins {
			e := Plugin_Entry{path = strings.clone(path), id = strings.clone(d.id), name = strings.clone(d.name), vendor = strings.clone(d.vendor), version = strings.clone(d.version)}
			for f in d.features {
				if f == "audio-effect" do e.effect = true
				if f == "instrument" do e.instrument = true
			}
			append(&ps.entries, e)
		}
		clap.library_close(lib)
	}
	app.ini_set(&ps.cache, "scan", "opening", "")
}

// Writes the list to plugins.ini.
@(private)
plugins_save :: proc(a: ^App) {
	ps := &a.plugins
	app.ini_destroy(&ps.cache)
	c := &ps.cache
	app.ini_set(c, "scan", "opening", "")
	for e, i in ps.entries {
		sec := fmt.tprintf("plugin.%d", i)
		app.ini_set(c, sec, "path", e.path)
		app.ini_set(c, sec, "id", e.id)
		app.ini_set(c, sec, "name", e.name)
		app.ini_set(c, sec, "vendor", e.vendor)
		app.ini_set(c, sec, "version", e.version)
		app.ini_set_bool(c, sec, "effect", e.effect)
		app.ini_set_bool(c, sec, "instrument", e.instrument)
		app.ini_set_bool(c, sec, "failed", e.failed)
	}
	app.ini_save(c, plugins_cache_path(a))
}

// Whether the library at `path` is blocked (not opened).
is_blocked :: proc(a: ^App, path: string) -> bool {
	for b in a.settings.blocked do if b == path do return true
	return false
}

@(private)
set_blocked :: proc(a: ^App, path: string, blocked: bool) {
	s := &a.settings
	if blocked == is_blocked(a, path) do return
	if blocked {
		append(&s.blocked, strings.clone(path))
		return
	}
	for b, i in s.blocked do if b == path {
		delete(b)
		ordered_remove(&s.blocked, i)
		return
	}
}

// The instrument plug-ins found (not blocked, not failed), for a pad.
plugin_instruments :: proc(a: ^App) -> []Plugin_Entry {
	out := make([dynamic]Plugin_Entry, context.temp_allocator)
	for e in a.plugins.entries do if e.instrument && !e.failed && !is_blocked(a, e.path) do append(&out, e)
	return out[:]
}

// The effect plug-ins found (not blocked, not failed), for an effect slot.
plugin_effects :: proc(a: ^App) -> []Plugin_Entry {
	out := make([dynamic]Plugin_Entry, context.temp_allocator)
	for e in a.plugins.entries do if e.effect && !e.failed && !is_blocked(a, e.path) do append(&out, e)
	return out[:]
}

@(private)
page_plugins :: proc(a: ^App) -> (changed: bool) {
	s := &a.settings
	ps := &a.plugins
	label("Folders")
	im.BeginGroup()
	for f in clap.default_search_paths(context.temp_allocator) do im.TextDisabled("%s", fmt.ctprintf("%s", f))
	for f, i in s.plugin_folders {
		im.TextUnformatted(fmt.ctprintf("%s", f))
		im.SameLine()
		if im.SmallButton(fmt.ctprintf("Remove###rmf%d", i)) {
			delete(f)
			ordered_remove(&s.plugin_folders, i)
			changed = true
			break
		}
	}
	if im.SmallButton("Add a folder…") do choose_folder(a, .Plugins)
	im.EndGroup()
	hint("The system's folders (and CLAP_PATH's) first, dimmed; then your own.")
	label("Scan")
	im.BeginDisabled(ps.scanning)
	if im.Button("Scan now") do plugins_scan(a)
	im.EndDisabled()
	if ps.scanning {
		im.SameLine()
		done := ps.total - len(ps.queue)
		im.ProgressBar(f32(done) / f32(max(ps.total, 1)), {220, 0}, fmt.ctprintf("%d of %d", done, ps.total))
	}
	im.SameLine(0, 16)
	if ui.toggle("Scan on start", &s.scan_on_start) do changed = true
	hint("Each library is opened to see what is in it. One that stops Pads during a scan is blocked at the next start.")
	// What was found.
	im.SetNextItemWidth(260)
	im.InputTextWithHint("##pfilter", "Search plug-ins", cstring(&ps.filter[0]), len(ps.filter))
	q := strings.to_lower(strings.truncate_to_byte(string(ps.filter[:]), 0), context.temp_allocator)
	if im.BeginTable("##plugins", 5, {.RowBg, .BordersInnerH, .SizingStretchProp}) {
		im.TableSetupColumn("Name", {.WidthStretch}, 3)
		im.TableSetupColumn("Vendor", {.WidthStretch}, 2)
		im.TableSetupColumn("Version", {.WidthStretch}, 1)
		im.TableSetupColumn("Kind", {.WidthStretch}, 1)
		im.TableSetupColumn("Use", {.WidthStretch}, 1)
		im.TableHeadersRow()
		for e, i in ps.entries {
			if q != "" && !strings.contains(strings.to_lower(e.name, context.temp_allocator), q) && !strings.contains(strings.to_lower(e.vendor, context.temp_allocator), q) do continue
			im.TableNextRow()
			im.TableNextColumn()
			im.TextUnformatted(fmt.ctprintf("%s", e.name))
			ui.name(fmt.tprintf("plugin %s", e.name))
			if im.IsItemHovered() do im.SetTooltip("%s", fmt.ctprintf("%s\n%s", e.path, e.id))
			im.TableNextColumn()
			im.TextDisabled("%s", fmt.ctprintf("%s", e.vendor))
			im.TableNextColumn()
			im.TextDisabled("%s", fmt.ctprintf("%s", e.version))
			im.TableNextColumn()
			kind := "Failed" if e.failed else ("Instrument" if e.instrument else ("Effect" if e.effect else "Other"))
			if e.failed do im.TextColored(transmute(im.Vec4)ui.theme().danger, "%s", fmt.ctprintf("%s", kind))
			else do im.TextUnformatted(fmt.ctprintf("%s", kind))
			im.TableNextColumn()
			on := !is_blocked(a, e.path)
			if ui.toggle(fmt.ctprintf("##use%d", i), &on) {
				set_blocked(a, e.path, !on)
				changed = true
			}
			if im.IsItemHovered() do im.SetTooltip("%s", cstring("Used") if on else cstring("Blocked: never opened"))
		}
		im.EndTable()
	}
	if len(ps.entries) == 0 && !ps.scanning do im.TextDisabled("None found yet: Scan now.")
	return
}

// The system's folder dialog, for a setting; the choice comes back on the bus.
choose_folder :: proc(a: ^App, what: type_of(Folder_Chosen{}.what)) {
	@(static) pending: type_of(Folder_Chosen{}.what)
	pending = what
	cb :: proc "c" (user: rawptr, files: [^]cstring, filter: i32) {
		if files == nil || files[0] == nil do return
		a := (^App)(user)
		context = runtime.default_context()
		app.post_any_thread(&a.bus, Folder_Chosen{pending, strings.clone(string(files[0]))})
	}
	sdl.ShowOpenFolderDialog(cb, a, a.platform.window, nil, false)
}

// What a folder dialog for the settings chose.
subscribe_settings :: proc(a: ^App) {
	app.subscribe(&a.bus, Folder_Chosen, proc(user: rawptr, e: ^Folder_Chosen) {
		a := (^App)(user)
		defer delete(e.path)
		switch e.what {
		case .Projects: set_string(&a.settings.projects_folder, e.path)
		case .Unsaved: set_string(&a.settings.unsaved_folder, e.path)
		case .Plugins:
			for f in a.settings.plugin_folders do if f == e.path do return
			append(&a.settings.plugin_folders, strings.clone(e.path))
		}
		settings_save(a)
	}, a)
}
