package pads

import "core:fmt"
import "core:strings"

import app "app:core"
import "app:ui"
import pm "model"
import im "deps:imgui"
import fc "fire:core"
import "fire:clap"

// A plug-in pad's device page: its plug-in (and a choice of another), its
// editor window, and its parameters as knobs (found with a filter when it
// has many), each of which can be given an automation lane.

// The page's state: the filter typed.
Plugin_Pad_Ui :: struct {
	filter: [64]u8,
}

// A plug-in's own window open: the editor of the plug-in in the slot `t`
// points at (an instrument or an effect).
Plugin_Editor :: struct {
	plugin: ^clap.Plugin,
	t:      pm.Fx_Target,
	win:    ui.Native_Window,
}

draw_plugin_pad :: proc(a: ^App, index: int) {
	m := &a.m
	pad := &m.project.pads[index]
	s := pad.instrument
	t := pm.Fx_Target{.Instrument, index, 0}
	f := a.platform.fonts
	im.PushFontFloat(f.bold, 16)
	im.Text("%s", fmt.ctprintf("%s", pm.slot_name(s)))
	im.PopFont()
	for e in a.plugins.entries do if e.id == s.plugin_id {
		im.SameLine()
		im.TextDisabled("%s", fmt.ctprintf("%s %s · CLAP", e.vendor, e.version))
		break
	}
	// Another instrument, or its editor.
	im.SetNextItemWidth(220)
	if ui.combo("##inst", "Change instrument…") {
		for pe in plugin_instruments(a) {
			if im.Selectable(fmt.ctprintf("%s  %s###pi%s", ui.ICON_PLUG, pe.name, pe.id), pe.id == s.plugin_id) && pe.id != s.plugin_id {
				pm.set_instrument(m, index, pm.new_plugin_effect(&m.project, pe.path, pe.id, pe.name), "Change Instrument")
			}
			if im.IsItemHovered() do im.SetTooltip("%s", fmt.ctprintf("%s %s", pe.vendor, pe.version))
		}
		if len(plugin_instruments(a)) == 0 do im.TextDisabled("No instrument plug-ins found")
		if im.Selectable("Find plug-ins… (Settings)", false) do a.settings.open, a.settings.page = true, .Plugins
		im.EndCombo()
	}
	ui.name("change instrument")
	im.SameLine(0, 12)
	p := pm.pad_plugin(&m.engine, index)
	if pm.pad_plugin_failed(&m.engine, index) {
		im.TextColored(transmute(im.Vec4)ui.theme().danger, "%s", fmt.ctprintf("Could not load %s", s.plugin_path))
		return
	}
	if p == nil {
		im.TextDisabled("Loading…")
		return
	}
	editor_button(a, t, p)
	im.Separator()
	params := pm.target_params(&m.engine, t)
	shown := params
	st := &a.plugin_pad
	if len(params) > 16 {
		im.SetNextItemWidth(220)
		im.InputTextWithHint("##plfilter", fmt.ctprintf("%s  Find a parameter", ui.ICON_SEARCH), cstring(&st.filter[0]), len(st.filter))
		ui.name("parameter filter")
		find := strings.to_lower(strings.truncate_to_byte(string(st.filter[:]), 0), context.temp_allocator)
		if find != "" {
			out := make([dynamic]fc.Param_Info, context.temp_allocator)
			for x in params do if strings.contains(strings.to_lower(x.name, context.temp_allocator), find) do append(&out, x)
			shown = out[:]
		}
		im.SameLine()
		im.TextDisabled("%s", fmt.ctprintf("%d parameters · right-click a knob to automate it", len(params)))
	} else {
		im.TextDisabled("Right-click a knob to give it an automation lane")
	}
	if im.BeginChild("##plknobs", {0, 0}) {
		draw_param_knobs(a, t, s, shown)
	}
	im.EndChild()
}

// The "Open editor" button for the plug-in in `t` (`p`), when it has one
// it can show in a window here.
editor_button :: proc(a: ^App, t: pm.Fx_Target, p: ^clap.Plugin) {
	if !clap.plugin_gui_supported(p, editor_api()) {
		im.TextDisabled("(no editor window)")
		return
	}
	open := false
	for e in a.editors do open ||= e.plugin == p
	if im.Button(fmt.ctprintf("%s  %s###pledit", ui.ICON_EXTERNAL_LINK, "Close editor" if open else "Open editor")) {
		if open do editor_close(a, p)
		else do editor_open(a, t)
	}
	ui.name("plugin editor")
	if im.IsItemHovered() do im.SetTooltip("The plug-in's own window")
}

// The window kind editors embed in here.
@(private)
editor_api :: proc() -> clap.Window_Api {
	when ODIN_OS == .Darwin do return .Cocoa
	else when ODIN_OS == .Windows do return .Win32
	else do return .X11
}

// Opens the editor of the plug-in in slot `t` in a window of its own (or
// raises it, when open).
editor_open :: proc(a: ^App, t: pm.Fx_Target) -> bool {
	f := pm.target_node(&a.m.engine, t)
	if f == nil || f.plugin == nil do return false
	p := f.plugin
	for e in a.editors do if e.plugin == p {
		ui.native_window_raise(e.win)
		return true
	}
	s, _ := pm.target_slot(&a.m, t)
	win, ok := ui.native_window_open(&a.platform, fmt.tprintf("%s — %s", pm.slot_name(s), target_name(&a.m.project, t)), 480, 320)
	if !ok {
		ui.toast(&a.ws.toasts, .Error, "Could not open a window for the editor")
		return false
	}
	api, handle := ui.native_window_handle(win)
	want := editor_api()
	if handle == 0 || int(api) != int(want) + 1 {
		ui.native_window_close(&win)
		ui.toast(&a.ws.toasts, .Error, "No native window here for a plug-in's editor")
		return false
	}
	w, h, err := clap.plugin_gui_open(p, {api = want, handle = handle})
	if err != .None {
		ui.native_window_close(&win)
		ui.toast(&a.ws.toasts, .Error, fmt.tprintf("%s would not open its editor", pm.slot_name(s)))
		return false
	}
	if w > 0 && h > 0 do ui.native_window_resize(win, int(w), int(h))
	append(&a.editors, Plugin_Editor{p, t, win})
	return true
}

// Closes plug-in `p`'s editor window.
editor_close :: proc(a: ^App, p: ^clap.Plugin) {
	for i := len(a.editors) - 1; i >= 0; i -= 1 do if a.editors[i].plugin == p {
		clap.plugin_gui_close(p)
		ui.native_window_close(&a.editors[i].win)
		ordered_remove(&a.editors, i)
	}
}

// Each frame: editor windows whose plug-in has gone (removed, changed,
// made again) or whose close was clicked close; editors' size requests.
editors_frame :: proc(a: ^App) {
	for r in pm.plugin_gui_requests(&a.m.engine) {
		for &e in a.editors do if e.plugin == r.plugin && r.requests.gui_resize {
			ui.native_window_resize(e.win, int(r.requests.gui_size[0]), int(r.requests.gui_size[1]))
		}
		if r.requests.gui_closed do editor_close(a, r.plugin)
	}
	for i := len(a.editors) - 1; i >= 0; i -= 1 {
		e := &a.editors[i]
		f := pm.target_node(&a.m.engine, e.t)
		gone := f == nil || f.plugin != e.plugin
		if gone || ui.native_window_closed(&a.platform, e.win) {
			if !gone do clap.plugin_gui_close(e.plugin) // (gone: the engine closed it first)
			ui.native_window_close(&e.win)
			ordered_remove(&a.editors, i)
		}
	}
}

// Closes every editor window (before the plug-ins go).
editors_close_all :: proc(a: ^App) {
	for &e in a.editors {
		clap.plugin_gui_close(e.plugin)
		ui.native_window_close(&e.win)
	}
	delete(a.editors)
	a.editors = nil
}

// The right-click menu of instrument knob `p` of pad `pad`: which lane
// moves it.
lane_menu :: proc(a: ^App, pad: int, p: fc.Param_Info) {
	if !im.BeginPopupContextItem(fmt.ctprintf("##lane%d", p.id)) do return
	defer im.EndPopup()
	m := &a.m
	cur := pm.plugin_lane_of(&m.project, pad, p.id)
	im.TextDisabled("%s", fmt.ctprintf("Automate %s", p.name))
	for k in 0 ..< pm.PLUGIN_LANES {
		l := m.project.pads[pad].plugin_lanes[k]
		label := fmt.ctprintf("Lane %d%s%s###ln%d", k + 1, " · " if l.id != 0 else "", plugin_param_name(a, pad, l.id), k)
		if im.MenuItem(label, nil, cur == k) && cur != k do pm.set_plugin_lane(m, pad, k, p)
	}
	if cur >= 0 {
		im.Separator()
		if im.MenuItem("Stop automating") do pm.set_plugin_lane(m, pad, cur, {})
	}
}

// The name of pad `pad`'s plug-in parameter `id` ("" if none).
plugin_param_name :: proc(a: ^App, pad: int, id: fc.Param_Id) -> string {
	if id == 0 do return ""
	for p in pm.target_params(&a.m.engine, {.Instrument, pad, 0}) do if p.id == id do return p.name
	return fmt.tprintf("#%d", id)
}

// Whether a lane is one pad `pad` has: a plug-in pad's are its volume,
// EQ and the lanes given parameters; the others', all but those.
lane_shown :: proc(a: ^App, pad: int, lp: pm.Lane_Param) -> bool {
	if pad < 0 || pad >= pm.PADS do return true
	plugin := a.m.project.pads[pad].kind == .Plugin
	#partial switch lp {
	case .Plugin_1 ..= .Plugin_8:
		return plugin && a.m.project.pads[pad].plugin_lanes[int(lp) - int(pm.Lane_Param.Plugin_1)].id != 0
	case .Pitch, .Cutoff, .Resonance:
		return !plugin
	}
	return true
}

// A lane's name: a plug-in lane's says what it moves.
lane_label :: proc(a: ^App, pad: int, lp: pm.Lane_Param) -> cstring {
	if lp >= .Plugin_1 && pad >= 0 && pad < pm.PADS {
		l := a.m.project.pads[pad].plugin_lanes[int(lp) - int(pm.Lane_Param.Plugin_1)]
		if l.id != 0 do return fmt.ctprintf("%s", plugin_param_name(a, pad, l.id))
	}
	return pm.LANE_NAMES[lp]
}

_ :: app.seal
