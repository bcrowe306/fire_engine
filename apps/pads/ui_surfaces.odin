// Settings > Control Surfaces: the controllers found and their surfaces,
// assigning one by hand, detection per surface, the libraries, the MIDI
// monitor, and a surface's virtual controller (its controls drawn, its
// displays mirrored, played with the mouse).
package pads

import "core:fmt"
import "core:math"
import "core:path/filepath"

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
	held:     int, // the control held with the mouse (-1)
	drag:     f32, // an encoder's drag not yet turned
	follow:   bool, // the monitor follows its newest line
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

	// The MIDI monitor.
	im.SeparatorText("MIDI monitor")
	on := a.surface_monitor
	label("Monitor")
	if ui.toggle("Record the surfaces' MIDI###monitor_on", &on) {
		pa.surface_monitor(api, on)
		a.surface_monitor = on
		sp.follow = true
	}
	im.SameLine()
	if im.SmallButton("Clear") do pa.surface_monitor_clear(api)
	ui.name("Clear monitor")
	if a.surface_monitor {
		es := fsurf.monitor_entries(&api.surfaces.fs)
		if im.BeginChild("##monitor", {0, 180}, {.Borders}) {
			first := max(len(es) - 400, 0)
			for e in es[first:] do im.TextUnformatted(fmt.ctprintf("%s", fsurf.monitor_line(e)))
			if sp.follow && im.GetScrollY() >= im.GetScrollMaxY() - 4 do im.SetScrollHereY(1)
		}
		im.EndChild()
		hint("Each message from a surface's controller (what its claim table did, and which rule), and each it sent, with its control and the component that has it.")
	}

	// The virtual controller.
	im.SeparatorText("Virtual controller")
	if sp.virtual >= int(n) do sp.virtual = -1
	v := pa.surface_virtual(api, i64(sp.virtual)) if sp.virtual >= 0 else nil
	if v == nil {
		im.TextDisabled("Show a running surface above that describes its controls.")
		return
	}
	draw_virtual(a, v)
}

// Pads' own surface folder.
@(private)
surfaces_folder :: proc(a: ^App) -> string {
	p, _ := filepath.join({settings_folder(a), "Surfaces"}, context.temp_allocator)
	return p
}

// The controls where they are on the device (scaled to the page's width),
// lit as the surface lit them, and played with the mouse: buttons and pads
// pressed, encoders dragged up and down, faders moved.
@(private)
draw_virtual :: proc(a: ^App, v: ^fsurf.Virtual) {
	sp := &a.surfaces_page
	dl := im.GetWindowDrawList()
	avail := im.GetContentRegionAvail().x
	scale := min(avail / max(v.width, 1), 380 / max(v.height, 1), 6) // (the whole device in view)
	o := im.GetCursorScreenPos()
	ox, oy := o.x, o.y
	col :: proc(rgb: u32, alpha: f32 = 1) -> u32 {
		return im.ColorConvertFloat4ToU32({f32((rgb >> 16) & 0xFF) / 255, f32((rgb >> 8) & 0xFF) / 255, f32(rgb & 0xFF) / 255, alpha})
	}
	im.DrawList_AddRectFilled(dl, {ox, oy}, {ox + v.width * scale, oy + v.height * scale}, col(0x1b1c20), 6)
	for c, k in v.controls {
		if c.w <= 0 || c.h <= 0 do continue
		x0, y0 := ox + c.x * scale, oy + c.y * scale
		x1, y1 := x0 + c.w * scale, y0 + c.h * scale
		st := fsurf.virtual_state(v, k)
		lit := u32(0x2a2b30)
		if st.has_rgb do lit = st.rgb
		else if st.value > 0 do lit = mix_rgb(0x2a2b30, 0xffb030, f32(st.value) / 127)
		edge := col(0xffffff) if st.pressed || sp.held == k else col(0x4a4b52)
		switch c.kind {
		case .Button, .Pad, .Other:
			im.DrawList_AddRectFilled(dl, {x0, y0}, {x1, y1}, col(lit), 3)
			im.DrawList_AddRect(dl, {x0, y0}, {x1, y1}, edge, 3)
		case .Encoder:
			r := min(x1 - x0, y1 - y0) / 2
			cx, cy := (x0 + x1) / 2, (y0 + y1) / 2
			im.DrawList_AddCircleFilled(dl, {cx, cy}, r, col(0x2c2d33))
			im.DrawList_AddCircle(dl, {cx, cy}, r, edge)
			ang := (-135 + 270 * f64(clamp(st.position, 0, 1)) - 90) * math.PI / 180
			im.DrawList_AddLine(dl, {cx, cy}, {cx + f32(math.cos(ang)) * r * 0.85, cy + f32(math.sin(ang)) * r * 0.85}, col(0x9a9ba3) if lit == 0x2a2b30 else col(lit), 2)
		case .Fader:
			im.DrawList_AddRectFilled(dl, {x0, y0}, {x1, y1}, col(0x141418), 2)
			im.DrawList_AddRect(dl, {x0, y0}, {x1, y1}, edge, 2)
			pos := clamp(st.position, 0, 1)
			if c.h >= c.w {
				th := min((y1 - y0) * 0.15, x1 - x0)
				y := y0 + (y1 - y0 - th) * (1 - pos)
				im.DrawList_AddRectFilled(dl, {x0, y}, {x1, y + th}, col(0xc9cad1), 2)
			} else {
				tw := min((x1 - x0) * 0.15, y1 - y0)
				x := x0 + (x1 - x0 - tw) * pos
				im.DrawList_AddRectFilled(dl, {x, y0}, {x + tw, y1}, col(0xc9cad1), 2)
			}
		case .Display:
			im.DrawList_AddRectFilled(dl, {x0, y0}, {x1, y1}, col(0x000000))
			if m := fsurf.virtual_display(v, k); m != nil do draw_mirror(dl, m, x0, y0, x1, y1)
		}
		// Its name: inside a button or pad, under a knob or fader (where it fits).
		if c.kind != .Display && c.kind != .Other {
			name := fmt.ctprintf("%s", c.label)
			tw := im.CalcTextSize(name).x
			if tw <= x1 - x0 - 4 {
				inside := c.kind == .Button || c.kind == .Pad
				ty := (y0 + y1) / 2 - im.GetFontSize() / 2 if inside else y1 + 2
				ink := col(0x1b1c20) if inside && light(lit) else col(0x9a9ba3)
				im.DrawList_AddText(dl, {(x0 + x1) / 2 - tw / 2, ty}, ink, name)
			}
		}
		// The mouse.
		if c.kind == .Display || c.kind == .Other do continue
		im.SetCursorScreenPos({x0, y0})
		im.PushIDInt(i32(k))
		im.InvisibleButton("##ctl", {x1 - x0, y1 - y0})
		ui.name(fmt.tprintf("Virtual %s", c.label))
		if im.IsItemHovered() do im.SetTooltip("%s", fmt.ctprintf("%s", c.label))
		#partial switch c.kind {
		case .Button, .Pad:
			if im.IsItemActivated() {
				sp.held = k
				vel := clamp(1 - (im.GetMousePos().y - y0) / max(y1 - y0, 1), 0.2, 1) if c.kind == .Pad else 1 // (lower on a pad: softer)
				pa.surface_play(&a.api, fsurf.virtual_press(v, k, u8(vel * 127)))
			}
			if im.IsItemDeactivated() {
				sp.held = -1
				pa.surface_play(&a.api, fsurf.virtual_release(v, k))
			}
		case .Encoder:
			if im.IsItemActivated() do sp.drag = 0
			if im.IsItemActive() {
				sp.drag -= im.GetIO().MouseDelta.y
				if steps := int(sp.drag / 4); steps != 0 {
					pa.surface_play(&a.api, fsurf.virtual_turn(v, k, steps))
					sp.drag -= f32(steps) * 4
				}
			}
		case .Fader:
			if im.IsItemActive() {
				mp := im.GetMousePos()
				x := 1 - (mp.y - y0) / max(y1 - y0, 1) if c.h >= c.w else (mp.x - x0) / max(x1 - x0, 1)
				pa.surface_play(&a.api, fsurf.virtual_move(v, k, clamp(x, 0, 1)))
			}
		}
		im.PopID()
	}
	im.SetCursorScreenPos({ox, oy})
	im.Dummy({v.width * scale, v.height * scale})
	hint("Its controls as the surface describes them, lit as it lights them; click, drag up and down (an encoder) or along (a fader). What you do goes to the surface as its controller's MIDI.")
}

// A display's mirrored pixels, scaled into its place (runs of a colour
// along each row as one rectangle).
@(private)
draw_mirror :: proc(dl: ^im.DrawList, m: ^fsurf.Mirror, x0, y0, x1, y1: f32) {
	sx := (x1 - x0) / f32(m.width)
	sy := (y1 - y0) / f32(m.height)
	px := m.rgba[:]
	for y in 0 ..< m.height {
		x := 0
		for x < m.width {
			i := (y * m.width + x) * 4
			r, g, b := px[i], px[i + 1], px[i + 2]
			run := 1
			for x + run < m.width {
				j := i + run * 4
				if px[j] != r || px[j + 1] != g || px[j + 2] != b do break
				run += 1
			}
			if r | g | b != 0 {
				c := im.ColorConvertFloat4ToU32({f32(r) / 255, f32(g) / 255, f32(b) / 255, 1})
				ax, ay := x0 + f32(x) * sx, y0 + f32(y) * sy
				im.DrawList_AddRectFilled(dl, {ax, ay}, {ax + f32(run) * sx, ay + sy}, c)
			}
			x += run
		}
	}
}

// Whether a colour is light (dark text on it).
@(private)
light :: proc(rgb: u32) -> bool {
	return 0.2126 * f32((rgb >> 16) & 0xFF) + 0.7152 * f32((rgb >> 8) & 0xFF) + 0.0722 * f32(rgb & 0xFF) > 128
}

@(private)
mix_rgb :: proc(a, b: u32, k: f32) -> u32 {
	ch :: proc(a, b: u32, k: f32, s: u32) -> u32 {
		x, y := f32((a >> s) & 0xFF), f32((b >> s) & 0xFF)
		return u32(x + (y - x) * clamp(k, 0, 1)) << s
	}
	return ch(a, b, k, 16) | ch(a, b, k, 8) | ch(a, b, k, 0)
}
