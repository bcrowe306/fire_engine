// Settings > Control Surfaces: the controllers found and their surfaces,
// assigning one by hand, detection per surface, the libraries, the MIDI
// monitor and the surfaces' log, and a surface's virtual controller (its controls drawn, its
// displays mirrored, played with the mouse).
package pads

import "core:fmt"
import "core:path/filepath"
import "core:strings"

import app "app:core"
import "app:ui"
import "fire:midi"
import fsurf "fsurf:host"
import pa "api"
import im "deps:imgui"

// The page's own state.
Surfaces_Page :: struct {
	assign_lib, assign_k: int, // the surface to assign by hand (-1: none chosen)
	assign_in, assign_out: string, // MIDI port ids (owned)
	virtual:  int, // the surface whose virtual controller shows (-1: none)
	play:     Virtual_Play, // the virtual controller's mouse
	follow:   bool, // the monitor follows its newest line
	log_level: pa.Surface_Log_Level, // the log shows this level and above
	log_surface: string, // the log shows only this surface's lines ("": all; owned)
}

@(private)
STATE_TEXT := [pa.Surface_State]cstring{
	.Identifying = "Asking who it is", .Waiting = "Identified", .Active = "Running", .Not_Identified = "Not this surface's",
	.Passed_Over = "Another surface has it", .Failed = "Wouldn't start", .Gone = "Unplugged",
}

@(private)
page_surfaces :: proc(a: ^App) {
	sp := &a.surfaces_page
	api := &a.api
	if !api.surfaces_on {
		im.TextDisabled("Control surfaces aren't started.")
		return
	}
	// The controllers found.
	label("Found")
	im.BeginGroup()
	n, _ := pa.surface_count(api)
	if n == 0 do im.TextDisabled("No controller of a surface Pads has. Plug one in, or assign a surface below.")
	for k in 0 ..< n {
		name, _ := pa.surface_name(api, k)
		st, _ := pa.surface_state(api, k)
		ports, _ := pa.surface_ports(api, k)
		im.PushIDInt(i32(k))
		im.AlignTextToFramePadding()
		im.TextUnformatted(fmt.ctprintf("%s", name))
		im.SameLine()
		im.TextDisabled("%s", fmt.ctprintf("on %s: %s", ports, STATE_TEXT[st]))
		if devs, _ := pa.surface_devices(api, k); devs != "" {
			im.SameLine()
			im.TextDisabled("%s", fmt.ctprintf("(%s)", devs))
		}
		im.SameLine()
		if im.SmallButton("Stop") do pa.surface_unload(api, k)
		ui.name(fmt.tprintf("Stop surface %d", k))
		if pa.surface_virtual(api, k) != nil {
			im.SameLine()
			if im.SmallButton("Show") do sp.virtual = int(k)
			ui.name(fmt.tprintf("Show surface %d", k))
		}
		im.PopID()
	}
	im.EndGroup()
	hint("Pads starts a surface when its controller is plugged in (its MIDI ports' names, and its answer when asked who it is). Stop: one assigned by hand goes; one found has its detection turned off (below).")

	// Assigning by hand.
	label("Assign by hand")
	im.BeginGroup()
	offered_name :: proc(api: ^pa.Api, lib, k: int) -> string {
		if lib < 0 do return "Choose a surface"
		name, _ := pa.surface_offered_name(api, i64(lib), i64(k))
		return name
	}
	im.SetNextItemWidth(230)
	if ui.combo("##assign_surface", fmt.ctprintf("%s", offered_name(api, sp.assign_lib, sp.assign_k))) {
		nl, _ := pa.surface_library_count(api)
		for l in 0 ..< nl {
			m, _ := pa.surface_offered_count(api, l)
			for k in 0 ..< m {
				name, _ := pa.surface_offered_name(api, l, k)
				if im.Selectable(fmt.ctprintf("%s###as%d_%d", name, l, k), int(l) == sp.assign_lib && int(k) == sp.assign_k) do sp.assign_lib, sp.assign_k = int(l), int(k)
			}
		}
		im.EndCombo()
	}
	ports := app.host_midi_ports(&a.host, context.temp_allocator)
	port_name :: proc(ports: []midi.Port_Info, id: string, out: bool, none: string) -> string {
		for p in ports do if p.id == id && (p.direction == .Output) == out do return p.name
		return none
	}
	im.SameLine()
	im.SetNextItemWidth(170)
	if ui.combo("##assign_in", fmt.ctprintf("In: %s", port_name(ports, sp.assign_in, false, "choose"))) {
		for p in ports do if p.direction == .Input {
			if im.Selectable(fmt.ctprintf("%s###ai%s", p.name, p.id), p.id == sp.assign_in) do set_string(&sp.assign_in, p.id)
		}
		im.EndCombo()
	}
	im.SameLine()
	im.SetNextItemWidth(170)
	if ui.combo("##assign_out", fmt.ctprintf("Out: %s", port_name(ports, sp.assign_out, true, "none"))) {
		if im.Selectable("None", sp.assign_out == "") do set_string(&sp.assign_out, "")
		for p in ports do if p.direction == .Output {
			if im.Selectable(fmt.ctprintf("%s###ao%s", p.name, p.id), p.id == sp.assign_out) do set_string(&sp.assign_out, p.id)
		}
		im.EndCombo()
	}
	im.SameLine()
	im.BeginDisabled(sp.assign_lib < 0 || sp.assign_in == "")
	if im.Button("Start") {
		if _, r := pa.surface_assign(api, i64(sp.assign_lib), i64(sp.assign_k), sp.assign_in, sp.assign_out); r != .Ok {
			why, _ := pa.last_error(api)
			pa.ui_message_show(api, .Warning, why)
		}
	}
	ui.name("Start assigned")
	im.EndDisabled()
	im.EndGroup()
	hint("For a controller Pads doesn't recognise by itself: the surface takes these ports, whatever their names.")

	// The libraries, and detection.
	label("Surfaces")
	im.BeginGroup()
	nl, _ := pa.surface_library_count(api)
	if nl == 0 do im.TextDisabled("None yet.")
	for l in 0 ..< nl {
		path, _ := pa.surface_library_path(api, l)
		why, _ := pa.surface_library_error(api, l)
		if why != "" {
			im.TextUnformatted(fmt.ctprintf("%s", filepath.base(path)))
			im.SameLine()
			im.TextDisabled("%s", fmt.ctprintf("didn't load: %s", why))
			continue
		}
		m, _ := pa.surface_offered_count(api, l)
		for k in 0 ..< m {
			name, _ := pa.surface_offered_name(api, l, k)
			on, _ := pa.surface_detect(api, l, k)
			if ui.toggle(fmt.ctprintf("%s###det%d_%d", name, l, k), &on) do pa.surface_set_detect(api, l, k, on)
			im.SameLine()
			im.TextDisabled("%s", fmt.ctprintf("%s", filepath.base(path)))
		}
	}
	im.EndGroup()
	hint(fmt.ctprintf("A surface is a .fsurf file: put it in %s (or FSURF_PATH, or the system's surface folders) and start Pads again. Off: Pads doesn't look for its controller.", surfaces_folder(a)))

	// The MIDI monitor and the log.
	im.SeparatorText("Monitor and log")
	monitor_and_log(a)

	// The virtual controller.
	im.SeparatorText("Virtual controller")
	if sp.virtual >= int(n) do sp.virtual = -1
	v := pa.surface_virtual(api, i64(sp.virtual)) if sp.virtual >= 0 else nil
	if v == nil {
		im.TextDisabled("Show a running surface above that describes its controls.")
		return
	}
	draw_virtual(a, v, &sp.play, {im.GetContentRegionAvail().x, 380})
	hint("Its controls as the surface describes them, lit as it lights them; click, drag up and down (an encoder) or along (a fader); right-click a button to hold it. What you do goes to the surface as its controller's MIDI.")
}

// The MIDI monitor, the surfaces' log, and both in one timeline (their
// times are on the same clock).
@(private)
monitor_and_log :: proc(a: ^App) {
	sp := &a.surfaces_page
	api := &a.api
	if !im.BeginTabBar("##surface_tools") do return
	defer im.EndTabBar()
	if im.BeginTabItem("MIDI###tab_midi") {
		monitor_controls(a)
		if a.surface_monitor {
			es := fsurf.monitor_entries(&api.surfaces.fs)
			if tool_lines_begin("##monitor") {
				for e in es[max(len(es) - 400, 0):] do im.TextUnformatted(fmt.ctprintf("%s", fsurf.monitor_line(e)))
				tool_lines_end(sp)
			}
		}
		hint("Each message from a surface's controller (what its claim table did, and which rule), and each it sent, with its control and the component that has it.")
		im.EndTabItem()
	}
	if im.BeginTabItem("Log###tab_log") {
		log_controls(a)
		es := fsurf.log_entries(&api.surfaces.fs)
		if tool_lines_begin("##log") {
			// The newest 400 that pass the filters.
			skip := -400
			for e in es do if log_shows(sp, e) do skip += 1
			for e in es do if log_shows(sp, e) {
				if skip <= 0 do log_text(e)
				else do skip -= 1
			}
			tool_lines_end(sp)
		}
		hint("What each surface logged (core:log, or log in fsurf.h), and what Pads wrote about one. Debug lines are kept while their toggle is on (and with --surface-dev).")
		im.EndTabItem()
	}
	if im.BeginTabItem("Both###tab_both") {
		monitor_controls(a)
		im.SameLine()
		log_controls(a)
		ms := fsurf.monitor_entries(&api.surfaces.fs) if a.surface_monitor else nil
		ls := fsurf.log_entries(&api.surfaces.fs)
		if tool_lines_begin("##both") {
			// The last 400 of the two, oldest first, by time.
			i, j := max(len(ms) - 400, 0), max(len(ls) - 400, 0)
			for i < len(ms) || j < len(ls) {
				if j >= len(ls) || (i < len(ms) && ms[i].time_ns <= ls[j].time_ns) {
					im.TextDisabled("%s", fmt.ctprintf("%s", fsurf.monitor_line(ms[i])))
					i += 1
				} else {
					if log_shows(sp, ls[j]) do log_text(ls[j])
					j += 1
				}
			}
			tool_lines_end(sp)
		}
		hint("The MIDI and the log lines together, in the order they came: what was pressed, what the surface made of it.")
		im.EndTabItem()
	}
}

@(private)
monitor_controls :: proc(a: ^App) {
	on := a.surface_monitor
	if ui.toggle("Record MIDI###monitor_on", &on) {
		pa.surface_monitor(&a.api, on)
		a.surface_monitor = on
		a.surfaces_page.follow = true
	}
	im.SameLine()
	if im.SmallButton("Clear###clear_monitor") do pa.surface_monitor_clear(&a.api)
	ui.name("Clear monitor")
}

LOG_LEVELS := [pa.Surface_Log_Level]cstring{.Debug = "Debug and up", .Info = "Info and up", .Warning = "Warnings and errors", .Error = "Errors"}

@(private)
log_controls :: proc(a: ^App) {
	sp := &a.surfaces_page
	api := &a.api
	im.SetNextItemWidth(150)
	if ui.combo("##log_level", LOG_LEVELS[sp.log_level]) {
		for l in pa.Surface_Log_Level do if im.Selectable(fmt.ctprintf("%s###lv%d", LOG_LEVELS[l], int(l)), sp.log_level == l) do sp.log_level = l
		im.EndCombo()
	}
	im.SameLine()
	im.SetNextItemWidth(170)
	if ui.combo("##log_surface", fmt.ctprintf("%s", sp.log_surface if sp.log_surface != "" else "Every surface")) {
		if im.Selectable("Every surface###ls_all", sp.log_surface == "") do log_filter_surface(sp, "")
		seen := make(map[string]bool, allocator = context.temp_allocator)
		for e in fsurf.log_entries(&api.surfaces.fs) do if e.surface != "" && !seen[e.surface] {
			seen[e.surface] = true
			if im.Selectable(fmt.ctprintf("%s###ls_%s", e.surface, e.surface), sp.log_surface == e.surface) do log_filter_surface(sp, e.surface)
		}
		im.EndCombo()
	}
	im.SameLine()
	debug, _ := pa.surface_log_debug(api)
	if ui.toggle("Debug lines###log_debug", &debug) do pa.surface_log_set_debug(api, debug)
	im.SameLine()
	if im.SmallButton("Copy###copy_log") {
		b := strings.builder_make(context.temp_allocator)
		for e in fsurf.log_entries(&api.surfaces.fs) do if log_shows(sp, e) {
			strings.write_string(&b, fsurf.log_line(e))
			strings.write_byte(&b, '\n')
		}
		im.SetClipboardText(strings.to_cstring(&b))
	}
	ui.name("Copy log")
	im.SameLine()
	if im.SmallButton("Clear###clear_log") do pa.surface_log_clear(api)
	ui.name("Clear log")
}

@(private)
log_filter_surface :: proc(sp: ^Surfaces_Page, name: string) {
	delete(sp.log_surface)
	sp.log_surface = strings.clone(name)
}

@(private)
log_shows :: proc(sp: ^Surfaces_Page, e: fsurf.Log_Entry) -> bool {
	return int(e.level) >= int(sp.log_level) && (sp.log_surface == "" || e.surface == sp.log_surface)
}

// A log line, coloured by its level.
@(private)
log_text :: proc(e: fsurf.Log_Entry) {
	line := fmt.ctprintf("%s", fsurf.log_line(e))
	switch e.level {
	case .Debug:   im.TextDisabled("%s", line)
	case .Info:    im.TextUnformatted(line)
	case .Warning: im.TextColored(transmute(im.Vec4)ui.theme().warn, "%s", line)
	case .Error:   im.TextColored(transmute(im.Vec4)ui.theme().danger, "%s", line)
	}
}

@(private)
tool_lines_begin :: proc(id: cstring) -> bool {
	ok := im.BeginChild(id, {0, 200}, {.Borders}, {.HorizontalScrollbar})
	if !ok do im.EndChild()
	return ok
}

// (Following the newest line while scrolled to the end.)
@(private)
tool_lines_end :: proc(sp: ^Surfaces_Page) {
	if sp.follow || im.GetScrollY() >= im.GetScrollMaxY() - 4 do im.SetScrollHereY(1)
	sp.follow = false
	im.EndChild()
}

// Pads' own surface folder.
@(private)
surfaces_folder :: proc(a: ^App) -> string {
	p, _ := filepath.join({settings_folder(a), "Surfaces"}, context.temp_allocator)
	return p
}

@(private)
mix_rgb :: proc(a, b: u32, k: f32) -> u32 {
	ch :: proc(a, b: u32, k: f32, s: u32) -> u32 {
		x, y := f32((a >> s) & 0xFF), f32((b >> s) & 0xFF)
		return u32(x + (y - x) * clamp(k, 0, 1)) << s
	}
	return ch(a, b, k, 16) | ch(a, b, k, 8) | ch(a, b, k, 0)
}
