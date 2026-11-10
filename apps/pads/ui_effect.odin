package pads

import "base:runtime"
import "core:fmt"
import "core:strings"

import app "app:core"
import "app:ui"
import pm "model"
import im "deps:imgui"
import sdl "deps:sdl3"
import fc "fire:core"
import "fire:clap"

// A CLAP file chosen in its dialog.
Plugin_Chosen :: struct {
	path: string,
}

// Plug-ins of a library the user chose, to pick one from.
Plugin_Choice :: struct {
	open:    bool,
	path:    string,
	ids:     [dynamic]string,
	names:   [dynamic]string,
	target:  pm.Fx_Target,
}

// The effect slot being edited: what is in it, on or off, its settings.
draw_effect :: proc(user: rawptr) {
	a := (^App)(user)
	m := &a.m
	t := a.fx
	s, ok := pm.target_slot(m, t)
	if !ok {
		im.TextDisabled("Click an effect slot in the mixer, or a performance effect, to edit it.")
		return
	}
	f := a.platform.fonts
	im.PushFontFloat(f.bold, 16)
	im.Text("%s", fmt.ctprintf("%s", target_name(t)))
	im.PopFont()
	im.Spacing()

	// A performance effect: how hard it plays (unless its press says).
	if t.kind == .Perf {
		x := m.project.perf_intensity[t.index]
		ke := ui.knob("Intensity", &x, 0, 1, 1, "%.2f")
		if ke.changed do pm.set_perf_intensity(m, t.index, x)
		if ke.ended do app.seal(&m.history)
		if im.IsItemHovered() do im.SetTooltip("How hard it plays: where you press its pad sets it while held (the top: all of it)")
		im.SameLine(0, 14)
	}
	// What it holds.
	im.SetNextItemWidth(200)
	if ui.combo("##kind", fmt.ctprintf("%s", pm.slot_name(s))) {
		for k in pm.Effect_Kind {
			if k == .Plugin do continue
			if t.kind == .Perf && k == .None do continue
			if im.Selectable(pm.EFFECT_NAMES[k], k == s.kind && s.kind != .Plugin) && k != s.kind {
				ns := pm.new_effect(k)
				if t.kind == .Perf do ns.on = false
				pm.set_target_slot(m, t, ns, "Set Effect")
			}
		}
		im.Separator()
		if im.Selectable("Plug-in (CLAP)…", false) do open_plugin_dialog(a, t)
		im.EndCombo()
	}
	if s.kind == .None do return
	im.SameLine(0, 12)
	if t.kind == .Perf {
		im.AlignTextToFramePadding()
		im.TextDisabled("On while its pad is held")
	} else {
		on := s.on
		if ui.toggle("On", &on) {
			ns := s
			ns.on = on
			pm.set_target_slot(m, t, ns, "Bypass" if !on else "Effect On")
		}
		im.SameLine(0, 12)
		if ui.icon_button(ui.ICON_TRASH_2, "Remove the effect") {
			pm.set_target_slot(m, t, {}, "Remove Effect")
			return
		}
	}
	if pm.slot_failed(&m.engine, t.index if t.kind == .Pad else -1, t.index if t.kind == .Bus else -1, t.slot) {
		im.TextColored(transmute(im.Vec4)ui.theme().danger, "%s", fmt.ctprintf("Could not load %s", s.plugin_path))
		return
	}
	im.Spacing()
	draw_effect_view(a, t, s)

	// Its settings: a knob each, in rows that wrap.
	params := pm.target_params(&m.engine, t)
	for p, k in params {
		v := pm.slot_value(s, p.id, f32(p.default))
		if p.min == 0 && p.max == 1 && .Stepped in p.flags {
			if k > 0 do ui.flow(110, 14)
			on := v >= 0.5
			if ui.toggle(fmt.ctprintf("%s##p%d", p.name, p.id), &on) {
				pm.set_target_param(m, t, p.id, 1 if on else 0)
				app.seal(&m.history)
			}
			continue
		}
		if k > 0 do ui.flow(ui.KNOB_SIZE + 12, 14)
		format := param_format(p)
		e := ui.knob(fmt.ctprintf("%s##p%d", p.name, p.id), &v, f32(p.min), f32(p.max), f32(p.default), format)
		if e.changed {
			if .Stepped in p.flags do v = f32(int(v + 0.5))
			pm.set_target_param(m, t, p.id, v)
		}
		if e.ended do app.seal(&m.history)
	}
	if len(params) == 0 do im.TextDisabled("No settings.")
}

// How a parameter's value reads under its knob.
@(private)
param_format :: proc(p: fc.Param_Info) -> cstring {
	#partial switch p.unit {
	case .Decibels:     return "%.1f dB"
	case .Hertz:        return "%.0f Hz"
	case .Milliseconds: return "%.0f ms"
	case .Semitones:    return "%+.0f st"
	case .Percent:      return "%.2f" if p.max <= 1 else "%.0f%%"
	}
	if .Stepped in p.flags do return "%.0f"
	return "%.2f"
}

// "A1 · Insert 1", "Bus B · Slot 3", "Performance 5".
target_name :: proc(t: pm.Fx_Target) -> string {
	switch t.kind {
	case .None: return ""
	case .Pad:  return fmt.tprintf("%s · Insert %d", pm.pad_label(t.index), t.slot + 1)
	case .Bus:  return fmt.tprintf("%s · Slot %d", pm.bus_name(t.index + 1 if t.index < pm.BUSES else 0), t.slot + 1)
	case .Perf: return fmt.tprintf("Performance effect %d", t.index + 1)
	}
	return ""
}

// The system's file dialog for a .clap; the choice comes back on the bus.
open_plugin_dialog :: proc(a: ^App, t: pm.Fx_Target) {
	a.plugin_choice.target = t
	filters := [1]sdl.DialogFileFilter{{name = "CLAP plug-ins", pattern = "clap"}}
	sdl.ShowOpenFileDialog(proc "c" (user: rawptr, files: [^]cstring, filter: i32) {
		if files == nil || files[0] == nil do return
		a := (^App)(user)
		context = runtime.default_context()
		app.post_any_thread(&a.bus, Plugin_Chosen{strings.clone(string(files[0]))})
	}, a, a.platform.window, &filters[0], 1, nil, false)
}

// Puts a plug-in from the library at `path` in the target slot: the only
// one it has, or a choice among them.
choose_plugin :: proc(a: ^App, path: string, t: pm.Fx_Target) -> bool {
	lib, err := clap.library_open(path)
	if err != .None {
		ui.toast(&a.ws.toasts, .Error, "Not a CLAP plug-in")
		return false
	}
	defer clap.library_close(lib)
	effects := make([dynamic]clap.Plugin_Description, context.temp_allocator)
	for p in lib.plugins do append(&effects, p)
	if len(effects) == 0 {
		ui.toast(&a.ws.toasts, .Error, "No plug-ins in that file")
		return false
	}
	if len(effects) == 1 {
		pm.set_target_slot(&a.m, t, pm.new_plugin_effect(&a.m.project, path, effects[0].id, effects[0].name), "Add Plug-in")
		return true
	}
	c := &a.plugin_choice
	plugin_choice_clear(c)
	c.open, c.path, c.target = true, strings.clone(path), t
	for p in effects {
		append(&c.ids, strings.clone(p.id))
		append(&c.names, strings.clone(p.name))
	}
	return true
}

// Frees a choice's strings.
plugin_choice_clear :: proc(c: ^Plugin_Choice) {
	delete(c.path)
	for s in c.ids do delete(s)
	for s in c.names do delete(s)
	delete(c.ids)
	delete(c.names)
	c^ = {}
}

// The plug-in choice, as a popup over everything.
draw_plugin_choice :: proc(a: ^App) {
	c := &a.plugin_choice
	if !c.open do return
	im.OpenPopup("Choose a plug-in")
	if im.BeginPopupModal("Choose a plug-in", nil, {.AlwaysAutoResize}) {
		for name, i in c.names {
			if im.Selectable(fmt.ctprintf("%s##%d", name, i)) {
				pm.set_target_slot(&a.m, c.target, pm.new_plugin_effect(&a.m.project, c.path, c.ids[i], name), "Add Plug-in")
				plugin_choice_clear(c)
				im.CloseCurrentPopup()
				break
			}
		}
		im.Separator()
		if im.Button("Cancel") {
			plugin_choice_clear(c)
			im.CloseCurrentPopup()
		}
		im.EndPopup()
	}
}
