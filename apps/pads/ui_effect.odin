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
import "fire:dsp"

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
	im.Text("%s", fmt.ctprintf("%s", target_name(&a.m.project, t)))
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
			if k == .Plugin || pm.effect_kind_legacy(k) do continue
			if t.kind == .Perf && k == .None do continue
			if im.Selectable(pm.EFFECT_NAMES[k], k == s.kind && s.kind != .Plugin) && k != s.kind {
				ns := pm.new_effect(k)
				if t.kind == .Perf do ns.on = false
				pm.set_target_slot(m, t, ns, "Set Effect")
			}
		}
		im.Separator()
		// The plug-ins found (Settings > Plug-ins), then any file.
		for pe in plugin_effects(a) {
			if im.Selectable(fmt.ctprintf("%s  %s###pl%s", ui.ICON_LAYOUT_GRID, pe.name, pe.id), s.kind == .Plugin && s.plugin_id == pe.id) {
				pm.set_target_slot(m, t, pm.new_plugin_effect(&m.project, pe.path, pe.id, pe.name), "Add Plug-in")
			}
			if im.IsItemHovered() do im.SetTooltip("%s", fmt.ctprintf("%s %s", pe.vendor, pe.version))
		}
		if im.Selectable("Plug-in (CLAP) from a file…", false) do open_plugin_dialog(a, t)
		if len(a.plugins.entries) == 0 && im.Selectable("Find plug-ins… (Settings)", false) {
			a.settings.open, a.settings.page = true, .Plugins
		}
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
	sidechain := pm.keyable(s.kind) && (t.kind == .Pad || t.kind == .Bus)
	if sidechain do draw_sidechain(a, t, s)
	// The synth's effects: their own page (its choices on this line, then
	// its picture and knobs).
	if e, twin := pm.synth_twin(s.kind); twin {
		a.param_host = {slot = true, t = t}
		defer a.param_host = {}
		x0 := im.GetCursorScreenPos().x
		avail := im.GetContentRegionAvail()
		top := im.GetCursorScreenPos().y
		if e != .Reverb && !sidechain do im.SameLine(0, 0) // (the reverb has no choices to put there; with a sidechain row, they go on a line of their own)
		draw_synth_effect(a, e, x0, avail.x - im.GetStyle().ScrollbarSize, top + max(avail.y - 6, 240))
		return
	}
	if s.kind == .Plugin {
		if f := pm.target_node(&m.engine, t); f != nil && f.plugin != nil {
			im.SameLine(0, 12)
			editor_button(a, t, f.plugin)
		}
	}
	im.Spacing()
	draw_effect_view(a, t, s)

	// Its settings: a knob each, in rows that wrap.
	draw_param_knobs(a, t, s, pm.target_params(&m.engine, t))
}

// The knobs of the slot `t` points at (`s`), for parameters `params`, in
// rows that wrap. A plug-in's knob shows what the plug-in has (its own
// editor may have moved it); an instrument's knob can be given a lane.
draw_param_knobs :: proc(a: ^App, t: pm.Fx_Target, s: pm.Effect_Slot, params: []fc.Param_Info) {
	m := &a.m
	plugin: ^clap.Plugin
	if f := pm.target_node(&m.engine, t); f != nil do plugin = f.plugin
	// Which to show: a delay synced shows a note value, not milliseconds.
	shown := make([dynamic]fc.Param_Info, 0, len(params), context.temp_allocator)
	synced := s.kind == .Delay && pm.slot_value(s, dsp.DELAY_PARAM_SYNC, 0) >= 0.5
	for p in params {
		if s.kind == .Delay && p.id == dsp.DELAY_PARAM_TIME_MS && synced do continue
		if s.kind == .Delay && p.id == dsp.DELAY_PARAM_BEATS && !synced do continue
		append(&shown, p)
	}
	// Spread evenly across the width: a cell each, as many to a row as fit.
	avail := im.GetContentRegionAvail().x
	x0 := im.GetCursorPosX()
	cell := max(avail / f32(max(len(shown), 1)), ui.KNOB_SIZE + 34)
	per_row := max(int(avail / cell), 1)
	for p, k in shown {
		col := k % per_row
		if col > 0 do im.SameLine()
		is_toggle := p.min == 0 && p.max == 1 && .Stepped in p.flags
		w: f32 = 104 if is_toggle else ui.KNOB_SIZE + 24
		im.SetCursorPosX(x0 + f32(col) * cell + max((cell - w) / 2, 0))
		v := pm.slot_value(s, p.id, max(f32))
		if v == max(f32) {
			v = f32(p.default)
			if plugin != nil do if x, ok := clap.plugin_param_value(plugin, p.id); ok do v = f32(x)
		}
		if is_toggle {
			im.BeginGroup()
			im.Dummy({1, im.GetTextLineHeight() + 4}) // level with the knobs' dials
			on := v >= 0.5
			if ui.toggle(fmt.ctprintf("%s##p%d", p.name, p.id), &on) {
				pm.set_target_param(m, t, p.id, 1 if on else 0)
				app.seal(&m.history)
			}
			im.EndGroup()
			continue
		}
		// A synced delay: note values (1/16, dotted, triplets), not beats.
		if s.kind == .Delay && p.id == dsp.DELAY_PARAM_BEATS {
			// While dragged it keeps where it is between notes (each frame's
			// small move would round back otherwise).
			@(static) dragging: bool
			@(static) between: f32
			idx := between if dragging else f32(nearest_note(v))
			e := ui.knob("Note##pnote", &idx, 0, f32(len(NOTE_VALUES) - 1), f32(nearest_note(0.75)), "%.0f", shown_value = NOTE_VALUES[clamp(int(idx + 0.5), 0, len(NOTE_VALUES) - 1)].name)
			dragging, between = e.active && !e.ended, idx
			if e.changed do pm.set_target_param(m, t, p.id, f32(NOTE_VALUES[clamp(int(idx + 0.5), 0, len(NOTE_VALUES) - 1)].beats))
			if e.ended do app.seal(&m.history)
			continue
		}
		format := param_format(p)
		log_scale := p.unit == .Hertz && p.min > 0 && p.max / p.min >= 50 // frequencies turn in ratios
		e := ui.knob(fmt.ctprintf("%s##p%d", p.name, p.id), &v, f32(p.min), f32(p.max), f32(p.default), format, log_scale = log_scale)
		if e.changed {
			if .Stepped in p.flags do v = f32(int(v + 0.5))
			pm.set_target_param(m, t, p.id, v)
		}
		if e.ended do app.seal(&m.history)
		if t.kind == .Instrument do lane_menu(a, t.index, p)
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
target_name :: proc(p: ^pm.Project, t: pm.Fx_Target) -> string {
	switch t.kind {
	case .None: return ""
	case .Pad:  return fmt.tprintf("%s · Insert %d", pm.pad_label(t.index), t.slot + 1)
	case .Bus:  return fmt.tprintf("%s · Slot %d", pm.bus_index_name(p, t.index), t.slot + 1)
	case .Perf: return fmt.tprintf("Performance effect %d", t.index + 1)
	case .Instrument: return fmt.tprintf("%s · Instrument", pm.pad_label(t.index))
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

// Note values a synced delay steps through, shortest first.
NOTE_VALUES := [?]struct { name: cstring, beats: f64 }{
	{"1/64", 0.0625}, {"1/32T", 1.0 / 12}, {"1/32", 0.125}, {"1/16T", 1.0 / 6}, {"1/16", 0.25}, {"1/8T", 1.0 / 3},
	{"1/16D", 0.375}, {"1/8", 0.5}, {"1/4T", 2.0 / 3}, {"1/8D", 0.75}, {"1/4", 1}, {"1/2T", 4.0 / 3},
	{"1/4D", 1.5}, {"1/2", 2}, {"1/2D", 3}, {"1 bar", 4}, {"2 bars", 8},
}

// The note value nearest `beats`.
@(private)
nearest_note :: proc(beats: f32) -> int {
	best, d := 0, f64(1e9)
	for nv, k in NOTE_VALUES do if abs(nv.beats - f64(beats)) < d {
		best, d = k, abs(nv.beats - f64(beats))
	}
	return best
}

// A compressor's or gate's sidechain: what it listens to (any pad, or a
// bus it doesn't feed), the key's high-pass, and Listen (the track hears
// the key, to set it by).
draw_sidechain :: proc(a: ^App, t: pm.Fx_Target, s: pm.Effect_Slot) {
	m := &a.m
	p := &m.project
	name :: proc(p: ^pm.Project, k: pm.Key_Source) -> string {
		switch k.kind {
		case .None: return "None (itself)"
		case .Pad:  return fmt.tprintf("Pad %s", pm.pad_label(k.index))
		case .Bus:  return fmt.tprintf("Bus %s", pm.bus_index_name(p, k.index))
		}
		return ""
	}
	im.AlignTextToFramePadding()
	im.TextDisabled("Sidechain")
	im.SameLine()
	im.SetNextItemWidth(160)
	if ui.combo("##sidechain", fmt.ctprintf("%s", name(p, s.key))) {
		set :: proc(m: ^pm.Model, t: pm.Fx_Target, s: pm.Effect_Slot, k: pm.Key_Source) {
			ns := s
			ns.key = k
			if k.kind == .None do ns.listen = false
			pm.set_target_slot(m, t, ns, "Sidechain")
		}
		if im.Selectable("None (itself)", s.key.kind == .None) do set(m, t, s, {})
		ui.name("key none")
		im.SeparatorText("Pads")
		for i in 0 ..< pm.PADS do if pm.pad_used(p, i) && pm.key_allowed(p, t, {.Pad, i}) {
			k := pm.Key_Source{.Pad, i}
			label := fmt.ctprintf("%s  %s###kp%d", pm.pad_label(i), pm.pad_name(&p.pads[i]), i)
			if im.Selectable(label, s.key == k) do set(m, t, s, k)
			ui.name(fmt.tprintf("key pad %s", pm.pad_label(i)))
		}
		im.SeparatorText("Buses")
		for b in 0 ..< p.bus_count do if pm.key_allowed(p, t, {.Bus, b}) {
			k := pm.Key_Source{.Bus, b}
			if im.Selectable(fmt.ctprintf("%s###kb%d", pm.bus_index_name(p, b), b), s.key == k) do set(m, t, s, k)
			ui.name(fmt.tprintf("key bus %d", b + 1))
		}
		im.EndCombo()
	}
	ui.name("sidechain")
	if im.IsItemHovered() do im.SetTooltip("What it listens to: another pad, or a bus this track doesn't feed (after its fader)")
	if s.key.kind == .None do return
	im.SameLine(0, 12)
	// (While dragged it shows its own value; the slot is set once, at the end: one step.)
	@(static) dragging: bool
	@(static) held: f64
	hpf := held if dragging else f64(s.key_hpf)
	e := ui.number_drag("key hpf", &hpf, 0, 2000, 10, 1, "Key high-pass %.0f Hz", 170)
	if im.IsItemHovered() do im.SetTooltip("The key's high-pass (0 Hz: none): above the bass, a kick keys by its click")
	dragging, held = e.active && !e.ended, hpf
	if e.ended || (e.changed && !e.active) {
		ns := s
		ns.key_hpf = f32(hpf)
		pm.set_target_slot(m, t, ns, "Key Filter")
	}
	im.SameLine(0, 12)
	listen := s.listen
	if ui.toggle("Listen", &listen) {
		ns := s
		ns.listen = listen
		pm.set_target_slot(m, t, ns, "Listen to Key")
	}
	if im.IsItemHovered() do im.SetTooltip("The track plays the key (filtered) instead, while on")
}
