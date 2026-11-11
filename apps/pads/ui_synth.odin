package pads

import "core:fmt"
import "core:math"
import "core:strings"

import app "app:core"
import "app:ui"
import pm "model"
import im "deps:imgui"
import fc "fire:core"
import "fire:dsp"
import "fire:fx"
import "fire:synth"

// The synth device's page: its own tabs (Osc, Filter, Env, LFO, Mod,
// Effects, Macro, Global) in the pad's instrument tab. Every knob is a
// synth parameter: drag a source chip (an envelope's, an LFO's, a
// macro's...) onto it to modulate it; it then wears a ring in the
// source's colour, its end a handle to drag for the amount (right-click
// the handle to take the route away); a dot on the ring shows where the
// newest note has it now.

Synth_Tab :: enum u8 {Osc, Filter, Env, Lfo, Mod, Effects, Macro, Global}

SYNTH_TAB_NAMES := [Synth_Tab]string{.Osc = "Osc", .Filter = "Filter", .Env = "Env", .Lfo = "LFO", .Mod = "Mod", .Effects = "Effects", .Macro = "Macro", .Global = "Global"}
SYNTH_TAB_ICONS := [Synth_Tab]string{.Osc = ui.ICON_AUDIO_WAVEFORM, .Filter = ui.ICON_AUDIO_LINES, .Env = ui.ICON_CHART_SPLINE, .Lfo = ui.ICON_ACTIVITY, .Mod = ui.ICON_WORKFLOW, .Effects = ui.ICON_WAND_SPARKLES, .Macro = ui.ICON_SLIDERS_HORIZONTAL, .Global = ui.ICON_SETTINGS}

// The synth page's own state: which tab, which oscillator (3: the
// sample), envelope and LFO show, and an LFO point being dragged.
Synth_Ui :: struct {
	tab:      Synth_Tab,
	show:     int, // frames left to bring `tab` to the front
	osc:      int,
	env:      int,
	lfo:      int,
	point:    int, // the LFO point dragged (-1: none)
	response: [synth.FILTERS]Filter_Curve,
	effect:   fx.Effect, // the effect the Effects tab shows
	comp_band: int,      // the compressor band its knobs set
	eq_curve: Eq_Curve,
	fx_filter_curve: Filter_Curve,
}

// The drag-and-drop payload a source chip carries: a `synth.Mod_Source`.
SYNTH_MOD_PAYLOAD :: "SYNTH_MOD"

// A source's colour (envelopes warm, LFOs cool, macros green, the
// keyboard's grey).
mod_color :: proc(s: synth.Mod_Source) -> ui.Color {
	#partial switch s {
	case .Env_1 ..= .Env_6:
		c := [6]u32{0xff9f43, 0xffc14d, 0xff7a59, 0xffe066, 0xff6fae, 0xe879f9}
		return ui.rgb(c[int(s) - int(synth.Mod_Source.Env_1)])
	case .Lfo_1 ..= .Lfo_8:
		c := [8]u32{0x4fc3f7, 0x58a6ff, 0x7c6cff, 0x3fc7c4, 0x5ad1a5, 0x9b8cff, 0x5b7cff, 0xc77dff}
		return ui.rgb(c[int(s) - int(synth.Mod_Source.Lfo_1)])
	case .Random_1 ..= .Random_4: return ui.rgb(0xd4a373)
	case .Macro_1 ..= .Macro_4:   return ui.rgb(0x7bd88f)
	}
	return ui.rgb(0xb5c0cf)
}

// A source's name ("Env 2", "LFO 1", "Macro 3", "Velocity").
mod_name :: proc(a: ^App, s: synth.Mod_Source) -> string {
	#partial switch s {
	case .Env_1 ..= .Env_6:       return fmt.tprintf("Env %d", int(s) - int(synth.Mod_Source.Env_1) + 1)
	case .Lfo_1 ..= .Lfo_8:       return fmt.tprintf("LFO %d", int(s) - int(synth.Mod_Source.Lfo_1) + 1)
	case .Random_1 ..= .Random_4: return fmt.tprintf("Random %d", int(s) - int(synth.Mod_Source.Random_1) + 1)
	case .Macro_1 ..= .Macro_4:   return pm.synth_macro_name(&a.m, a.selected, int(s) - int(synth.Mod_Source.Macro_1))
	case .Note_In_Octave:         return "Note in Octave"
	case .Mod_Wheel:              return "Mod Wheel"
	case .Pitch_Wheel:            return "Pitch Wheel"
	}
	return fmt.tprint(s)
}

// How wide source `s`'s chip is.
chip_width :: proc(a: ^App, s: synth.Mod_Source) -> f32 {
	return im.CalcTextSize(fmt.ctprintf("%s  %s", ui.ICON_MOVE, mod_name(a, s))).x + im.GetStyle().FramePadding.x * 2
}

// A chip for source `s`: drag it onto a knob to modulate that knob.
mod_chip :: proc(a: ^App, s: synth.Mod_Source) {
	c := mod_color(s)
	label := mod_name(a, s)
	im.PushStyleColorVec4(.Button, transmute(im.Vec4)ui.with_alpha(c, 0.25))
	im.PushStyleColorVec4(.ButtonHovered, transmute(im.Vec4)ui.with_alpha(c, 0.45))
	im.PushStyleColorVec4(.ButtonActive, transmute(im.Vec4)ui.with_alpha(c, 0.6))
	im.Button(fmt.ctprintf("%s  %s###chip%d", ui.ICON_MOVE, label, int(s)))
	im.PopStyleColor(3)
	ui.name(fmt.tprintf("mod %s", label))
	if im.IsItemHovered() do im.SetTooltip("%s", fmt.ctprintf("Drag %s onto a knob to modulate it", label))
	if im.BeginDragDropSource() {
		v := u8(s)
		im.SetDragDropPayload(SYNTH_MOD_PAYLOAD, &v, 1)
		im.Text("%s", fmt.ctprintf("%s  %s", ui.ICON_MOVE, label))
		im.EndDragDropSource()
	}
}

// The value a parameter shows (its curve applied, in its units).
param_text :: proc(spec: ^synth.Param_Spec, plain: f32) -> string {
	v := synth.param_curve(spec, plain)
	name := spec.name
	switch {
	case strings.contains(name, "Cutoff"), strings.contains(name, "Center"), strings.has_suffix(name, " Cut"):
		return fmt.tprintf("%.0f Hz", fx.key_to_hz(v))
	case strings.contains(name, "Chorus Delay"):  return fmt.tprintf("%.1f ms", v * 1000)
	case strings.has_suffix(name, "Pre-Delay"):   return fmt.tprintf("%.0f ms", v * 1000)
	case strings.has_suffix(name, "Reverb Decay"): return fmt.tprintf("%.2f s", v)
	case strings.has_suffix(name, "Phaser Depth"): return fmt.tprintf("%.0f st", v)
	case strings.has_suffix(name, "Chorus Voices"): return fmt.tprintf("%.0f", v * 2)
	case spec.curve == .Quartic:                  return fmt.tprintf("%.1f ms", v * 1000) if v < 1 else fmt.tprintf("%.2f s", v)
	case strings.contains(name, "Tempo"):
		names := synth.LFO_TEMPO_NAMES
		return names[clamp(int(v), 0, 12)]
	case strings.contains(name, "Fade"), strings.has_suffix(name, "Delay"): return fmt.tprintf("%.2f s", v)
	case strings.contains(name, "Frequency"):     return fmt.tprintf("%.2f Hz", v)
	case strings.contains(name, "Smooth Time"):   return fmt.tprintf("%.3f s", v)
	case spec.unit == .Decibels:                  return fmt.tprintf("%+.1f dB", v)
	case strings.contains(name, "Level"):         return fmt.tprintf("%.0f%%", v * 100)
	case strings.contains(name, "Detune") && !strings.contains(name, "Power") && !strings.contains(name, "Range"): return fmt.tprintf("%.0f%%", v)
	case strings.contains(name, "Transpose"), strings.contains(name, "Range"): return fmt.tprintf("%+.0f st", v)
	case strings.contains(name, "Tune"):          return fmt.tprintf("%+.0f ct", v * 100)
	case spec.curve == .Indexed:                  return fmt.tprintf("%.0f", v)
	case spec.min < 0:                            return fmt.tprintf("%+.2f", v)
	}
	return fmt.tprintf("%.0f%%", (v - spec.min) / (spec.max - spec.min) * 100) if spec.max - spec.min <= 2 && spec.min >= 0 else fmt.tprintf("%.2f", v)
}

// A knob for synth parameter `id` of the selected pad, labelled `label`:
// its plain value turned, its curved value shown; modulation rings, a
// drop target for sources, and each ring's handle to drag.
synth_knob :: proc(a: ^App, label: cstring, id: fc.Param_Id) {
	m := &a.m
	i := a.selected
	spec := synth.param_spec(id)
	if spec == nil do return
	v := pm.synth_value(m, i, id)
	pos := im.GetCursorScreenPos()
	shown := fmt.ctprintf("%s", param_text(spec, v))
	step: f32 = 1 if spec.curve == .Indexed else 0
	routes := pm.synth_routes_to(m, i, id)
	e := ui.knob(label, &v, spec.min, spec.max, spec.default, "%.3f", shown_value = shown, step = step, overlap = len(routes) > 0)
	knob_id := im.GetItemID()
	if e.changed do pm.set_synth_value(m, i, id, v, spec.name)
	if e.ended do app.seal(&m.history)
	// A source dropped on it: a route (a quarter of the range, to start).
	if im.BeginDragDropTarget() {
		if pl := im.AcceptDragDropPayload(SYNTH_MOD_PAYLOAD); pl != nil {
			src := synth.Mod_Source((^u8)(pl.Data)^)
			pm.add_synth_route(m, i, {source = src, dest = id, amount = 0.25, bipolar = src == .Pitch_Wheel})
		}
		im.EndDragDropTarget()
	}
	_ = knob_id
	if len(routes) == 0 do return
	// The rings: each route's span from the value, a handle at its end.
	t := ui.theme()
	dl := im.GetWindowDrawList()
	c, r := ui.knob_geometry(label, pos)
	arc := ui.KNOB_ARC
	frac :: proc(spec: ^synth.Param_Spec, x: f32) -> f32 { return clamp((x - spec.min) / (spec.max - spec.min), 0, 1) }
	angle :: proc(arc: [2]f32, f: f32) -> f32 { return arc[0] + (arc[1] - arc[0]) * f }
	live, playing := pm.synth_live(&m.engine, i)
	sy := &m.project.pads[i].synth
	ring := r + 4
	for k, n in routes {
		rt := sy.routes[k]
		col := mod_color(rt.source)
		if rt.bypass do col = ui.with_alpha(col, 0.3)
		f0 := frac(spec, v)
		lo := f0 - (rt.amount if rt.bipolar else 0)
		hi := f0 + rt.amount
		a0, a1 := angle(arc, clamp(min(lo, hi), 0, 1)), angle(arc, clamp(max(lo, hi), 0, 1))
		rr := ring + f32(n) * 4
		im.DrawList_PathArcTo(dl, c, rr, a0, a1, 24)
		im.DrawList_PathStroke(dl, ui.col(col), 2.5)
		// Where the newest note has it (a source's value now: envelopes and
		// LFOs from the voice; others at their value).
		if playing && live.sounding {
			sv: f32 = -1
			#partial switch rt.source {
			case .Env_1 ..= .Env_6: sv = live.envs[int(rt.source) - int(synth.Mod_Source.Env_1)]
			case .Lfo_1 ..= .Lfo_8: sv = live.lfos[int(rt.source) - int(synth.Mod_Source.Lfo_1)]
			}
			if sv >= 0 {
				x := sv * 2 - 1 if rt.bipolar else sv
				ad := angle(arc, clamp(f0 + x * rt.amount, 0, 1))
				im.DrawList_AddCircleFilled(dl, {c.x + math.cos(ad) * rr, c.y + math.sin(ad) * rr}, 3, ui.col(t.text))
			}
		}
		// The handle: drag round for the amount, right-click to remove.
		ah := angle(arc, clamp(hi, 0, 1))
		hp := im.Vec2{c.x + math.cos(ah) * rr, c.y + math.sin(ah) * rr}
		im.SetCursorScreenPos({hp.x - 5, hp.y - 5})
		im.PushIDInt(i32(k))
		im.InvisibleButton("##modhandle", {10, 10}, {.MouseButtonLeft, .MouseButtonRight})
		ui.name(fmt.tprintf("%s mod %d", label, n + 1))
		hot := im.IsItemHovered() || im.IsItemActive()
		im.DrawList_AddCircleFilled(dl, hp, 4.5 if hot else 3.5, ui.col(col))
		if hot do im.SetTooltip("%s", fmt.ctprintf("%s: %+.0f%% (drag; right-click to remove)", mod_name(a, rt.source), rt.amount * 100))
		if im.IsItemActive() && im.GetIO().MouseDelta.y != 0 {
			x := rt
			x.amount = clamp(x.amount - im.GetIO().MouseDelta.y * (0.002 if im.GetIO().KeyShift else 0.01), -1, 1)
			pm.set_synth_route(m, i, k, x, "Modulation Amount")
		}
		if im.IsItemDeactivated() do app.seal(&m.history)
		if im.IsItemClicked(.Right) do pm.remove_synth_route(m, i, k)
		im.PopID()
	}
	// Back where the knob left the cursor.
	im.SetCursorScreenPos({pos.x, pos.y + im.GetTextLineHeight() * 2 + ui.KNOB_SIZE + 6})
	im.Dummy({ui.knob_width(label), 0})
}

// A knob in a row: its label and parameter.
Knob :: struct {
	label: cstring,
	id:    fc.Param_Id,
}

// A row of synth knobs spread across `w` (0: the rest of the row).
synth_knob_row :: proc(a: ^App, w: f32, knobs: []Knob) {
	row := spread_begin(len(knobs), w)
	for k in knobs {
		spread_next(&row, k.label)
		synth_knob(a, k.label, k.id)
	}
}

// The next item on this line if `need` more fits before `col + w`, else
// on the next line at `col` (wrapping within a column, not the window).
wrap_in :: proc(col, w, need, gap: f32) {
	last := im.GetItemRectMax()
	if last.x + gap + need <= col + w {
		im.SameLine(0, gap)
	} else {
		im.SetCursorScreenPos({col, im.GetCursorScreenPos().y})
	}
}

// A choice (an indexed parameter) as a combo of `names` (shown after
// `prefix`).
synth_choice :: proc(a: ^App, id: fc.Param_Id, names: []string, width: f32, label: cstring, prefix := "") {
	m := &a.m
	v := int(math.round(pm.synth_value(m, a.selected, id)))
	im.SetNextItemWidth(width)
	if ui.combo(label, fmt.ctprintf("%s%s", prefix, names[clamp(v, 0, len(names) - 1)])) {
		for n, k in names do if im.Selectable(fmt.ctprintf("%s###c%d", n, k), k == v) {
			pm.set_synth_value(m, a.selected, id, f32(k), names[k])
			app.seal(&m.history)
		}
		im.EndCombo()
	}
}

// A parameter as a compact number to drag, shown as `format` of its
// value times `scale`, `width` wide.
synth_drag :: proc(a: ^App, id: fc.Param_Id, format: cstring, scale: f64, width: f32) {
	m := &a.m
	spec := synth.param_spec(id)
	if spec == nil do return
	v := f64(pm.synth_value(m, a.selected, id)) * scale
	if e := ui.number_drag(fmt.ctprintf("%s", spec.name), &v, f64(spec.min) * scale, f64(spec.max) * scale, (f64(spec.max) - f64(spec.min)) * scale / 200, 0.1, format, width); e.changed {
		pm.set_synth_value(m, a.selected, id, f32(v / scale), spec.name)
	} else if e.ended do app.seal(&m.history)
}

// An on/off parameter as a toggle.
synth_toggle :: proc(a: ^App, label: cstring, id: fc.Param_Id) {
	m := &a.m
	on := pm.synth_value(m, a.selected, id) > 0.5
	if ui.toggle(label, &on) {
		pm.set_synth_value(m, a.selected, id, 1 if on else 0, string(label))
		app.seal(&m.history)
	}
}

// The synth's tabs, and on the tab bar's line the sources (small chips:
// drag one onto any knob on any tab).
draw_synth_tabs :: proc(a: ^App) {
	st := &a.synth_ui
	left := im.GetCursorScreenPos().x
	right := left + im.GetContentRegionAvail().x
	line_y := im.GetCursorScreenPos().y
	if !im.BeginTabBar("##synth_tabs") do return
	shown := st.tab
	tabs_end: f32 = 0
	for tab in Synth_Tab {
		flags: im.TabItemFlags
		if st.show > 0 && st.tab == tab do flags += {.SetSelected}
		label := fmt.ctprintf("%s  %s###syn%s", SYNTH_TAB_ICONS[tab], SYNTH_TAB_NAMES[tab], SYNTH_TAB_NAMES[tab])
		if im.BeginTabItem(label, nil, flags) {
			if st.show == 0 do st.tab = tab
			shown = tab
			im.EndTabItem()
		}
		tabs_end = im.GetItemRectMax().x
	}
	im.EndTabBar()
	// The sources, right-aligned on the tab bar's line (if there is room).
	{
		chips := []synth.Mod_Source{.Env_1, .Env_2, .Env_3, .Env_4, .Env_5, .Env_6, .Lfo_1, .Lfo_2, .Lfo_3, .Lfo_4, .Lfo_5, .Lfo_6, .Lfo_7, .Lfo_8, .Random_1, .Random_2, .Random_3, .Random_4, .Macro_1, .Macro_2, .Macro_3, .Macro_4, .Velocity, .Note, .Aftertouch, .Mod_Wheel, .Pitch_Wheel, .Random}
		w: f32 = 0
		for s in chips do w += mini_chip_width(s) + 1
		x := right - w
		after := im.GetCursorScreenPos()
		y := line_y + 1
		if x <= tabs_end + 16 { // no room beside the tabs: a line of its own under them
			x = max(right - w, left)
			y = after.y
			after.y += im.GetFrameHeight() + 2
		}
		for s in chips {
			if x + mini_chip_width(s) > right && x > left { // (wider than the panel: on to another line)
				x = left
				y += im.GetFrameHeight() + 2
				after.y = max(after.y, y + im.GetFrameHeight() + 2)
			}
			im.SetCursorScreenPos({x, y})
			mini_chip(a, s)
			x += mini_chip_width(s) + 1
		}
		im.SetCursorScreenPos(after)
	}
	if im.BeginChild("##syntab", {0, 0}) {
		{
			tab := shown
			{
				switch tab {
				case .Osc:     draw_synth_osc(a)
				case .Filter:  draw_synth_filter(a)
				case .Env:     draw_synth_env(a)
				case .Lfo:     draw_synth_lfo(a)
				case .Mod:     draw_synth_mod(a)
				case .Effects: draw_synth_effects(a)
				case .Macro:   draw_synth_macro(a)
				case .Global:  draw_synth_global(a)
				}
			}
		}
	}
	im.EndChild()
	if st.show > 0 do st.show -= 1
}

// A source's short name for its mini chip ("E2", "L1", "M3", "Vel").
mini_name :: proc(s: synth.Mod_Source) -> string {
	#partial switch s {
	case .Env_1 ..= .Env_6:   return fmt.tprintf("E%d", int(s) - int(synth.Mod_Source.Env_1) + 1)
	case .Lfo_1 ..= .Lfo_8:   return fmt.tprintf("L%d", int(s) - int(synth.Mod_Source.Lfo_1) + 1)
	case .Macro_1 ..= .Macro_4: return fmt.tprintf("M%d", int(s) - int(synth.Mod_Source.Macro_1) + 1)
	case .Random_1 ..= .Random_4: return fmt.tprintf("R%d", int(s) - int(synth.Mod_Source.Random_1) + 1)
	case .Velocity:    return "Vel"
	case .Note:        return "Key"
	case .Aftertouch:  return "AT"
	case .Mod_Wheel:   return "MW"
	case .Pitch_Wheel: return "PB"
	case .Random:      return "Rnd"
	}
	return "?"
}

mini_chip_width :: proc(s: synth.Mod_Source) -> f32 {
	return im.CalcTextSize(fmt.ctprintf("%s", mini_name(s))).x + 8
}

// A small chip for source `s` (its short name), to drag onto a knob.
mini_chip :: proc(a: ^App, s: synth.Mod_Source) {
	t := ui.theme()
	c := mod_color(s)
	dl := im.GetWindowDrawList()
	pos := im.GetCursorScreenPos()
	label := fmt.ctprintf("%s", mini_name(s))
	sz := im.Vec2{mini_chip_width(s), im.GetFrameHeight() - 4}
	im.InvisibleButton(fmt.ctprintf("##mini%d", int(s)), sz)
	ui.name(fmt.tprintf("mod %s", mod_name(a, s)))
	hot := im.IsItemHovered()
	im.DrawList_AddRectFilled(dl, pos, {pos.x + sz.x, pos.y + sz.y}, ui.col(ui.with_alpha(c, 0.55 if hot else 0.32)), 4)
	ts := im.CalcTextSize(label)
	im.DrawList_AddText(dl, {pos.x + (sz.x - ts.x) / 2, pos.y + (sz.y - ts.y) / 2}, ui.col(t.text), label)
	if hot do im.SetTooltip("%s", fmt.ctprintf("%s: drag onto a knob to modulate it", mod_name(a, s)))
	if im.BeginDragDropSource() {
		v := u8(s)
		im.SetDragDropPayload(SYNTH_MOD_PAYLOAD, &v, 1)
		im.Text("%s", fmt.ctprintf("%s  %s", ui.ICON_MOVE, mod_name(a, s)))
		im.EndDragDropSource()
	}
}

// --- Osc -----------------------------------------------------------------------------------------

DESTINATION_NAMES := []string{"Filter 1", "Filter 2", "Both filters", "Effects", "Direct out"}
WARP_NAMES := []string{"None", "Sync", "Formant", "Quantize", "Bend", "Squeeze", "Pulse width", "FM from A", "FM from B", "FM from sample", "RM from A", "RM from B", "RM from sample"}
MORPH_NAMES := []string{"None", "Vocode", "Formant scale", "Harmonic stretch", "Inharmonic stretch", "Smear", "Random amplitudes", "Low-pass", "High-pass", "Phase disperse", "Shepard tone", "Skew"}
STACK_NAMES := []string{"Normal", "Centre −1 oct", "Centre −2 oct", "Octave", "2 octaves", "Power chord", "Power chord 2", "Major chord", "Minor chord", "Harmonics", "Odd harmonics"}

// The Osc tab: which source (A, B, C, the sample), its on switch, its
// wavetable (a 3D view of its frames, the frame playing lit) and knobs.
draw_synth_osc :: proc(a: ^App) {
	m := &a.m
	st := &a.synth_ui
	i := a.selected
	sy := &m.project.pads[i].synth
	names := []string{"Osc A", "Osc B", "Osc C", "Sample"}
	if ui.segmented("synth_osc", names, &st.osc) {}
	im.SameLine(0, 14)
	o := st.osc + 1
	if st.osc < 3 {
		synth_toggle(a, "On##osc", synth.osc_param(o, .On))
		im.SameLine(0, 14)
		im.SetNextItemWidth(150)
		if ui.combo("##table", fmt.ctprintf("%s  %s", ui.ICON_AUDIO_WAVEFORM, pm.synth_source_name(m, sy.tables[st.osc]))) {
			for b in synth.Builtin_Table do if im.Selectable(fmt.ctprintf("%s###tb%d", synth.BUILTIN_NAMES[b], int(b)), sy.tables[st.osc].sample == 0 && int(sy.tables[st.osc].builtin) == int(b)) {
				pm.set_synth_table(m, i, st.osc, {builtin = u8(b)})
			}
			im.Separator()
			im.TextDisabled("Or drop an audio file on the view")
			im.EndCombo()
		}
		ui.name("wavetable")
		im.SameLine(0, 14)
		synth_choice(a, synth.osc_param(o, .Destination), DESTINATION_NAMES, 110, "##dest")
		ui.flow(100, 14)
		synth_toggle(a, "Key track##osc", synth.osc_param(o, .Keytrack))
		ui.flow(190, 14)
		synth_choice(a, synth.osc_param(o, .Spectral_Morph), MORPH_NAMES, 190, "##morph", "Morph: ")
		ui.name("spectral morph")
	} else {
		synth_toggle(a, "On##smp", synth.sample_param(.On))
		im.SameLine(0, 14)
		im.SetNextItemWidth(170)
		if ui.combo("##sample", fmt.ctprintf("%s  %s", ui.ICON_FILE_AUDIO, pm.synth_source_name(m, sy.sample, noise = true))) {
			for b in synth.Builtin_Noise do if im.Selectable(fmt.ctprintf("%s###nb%d", synth.BUILTIN_NOISE_NAMES[b], int(b)), sy.sample.sample == 0 && int(sy.sample.builtin) == int(b)) {
				pm.set_synth_sample(m, i, {builtin = u8(b)})
			}
			im.Separator()
			im.TextDisabled("Or drop an audio file on the view")
			im.EndCombo()
		}
		im.SameLine(0, 14)
		synth_choice(a, synth.sample_param(.Destination), DESTINATION_NAMES, 120, "##sdest")
		im.SameLine(0, 10)
		synth_toggle(a, "Key track##smp", synth.sample_param(.Keytrack))
		im.SameLine(0, 10)
		synth_toggle(a, "Loop##smp", synth.sample_param(.Loop))
		im.SameLine(0, 10)
		synth_toggle(a, "Bounce##smp", synth.sample_param(.Bounce))
	}
	im.Spacing()
	avail := im.GetContentRegionAvail()
	view_w := avail.x * 0.28
	view_h := max(avail.y - 8, 120)
	pos := im.GetCursorScreenPos()
	draw_table_view(a, st.osc, {view_w, view_h})
	// The knobs, two rows beside the view.
	im.SetCursorScreenPos({pos.x + view_w + 14, pos.y})
	w := avail.x - view_w - 14 - im.GetStyle().ScrollbarSize
	if st.osc < 3 {
		col := pos.x + view_w + 14
		synth_choice(a, synth.osc_param(o, .Stack), STACK_NAMES, 128, "##stack", "Unison: ")
		wrap_in(col, w, 128, 8)
		synth_choice(a, synth.osc_param(o, .Warp), WARP_NAMES, 128, "##warp", "Warp: ")
		wrap_in(col, w, 90, 8)
		synth_drag(a, synth.osc_param(o, .Warp_Spread), "Spread %+.0f%%", 100, 90)
		wrap_in(col, w, 90, 6)
		synth_drag(a, synth.osc_param(o, .Warp_Phase), "Phase %.0f°", 360, 90)
		im.SetCursorScreenPos({pos.x + view_w + 14, im.GetCursorScreenPos().y + 6})
		synth_knob_row(a, w, {{"Level", synth.osc_param(o, .Level)}, {"Pan", synth.osc_param(o, .Pan)}, {"Frame", synth.osc_param(o, .Frame)}, {"Transpose", synth.osc_param(o, .Transpose)}, {"Tune", synth.osc_param(o, .Tune)}, {"Phase", synth.osc_param(o, .Phase)}, {"Random", synth.osc_param(o, .Random_Phase)}})
		im.SetCursorScreenPos({pos.x + view_w + 14, im.GetCursorScreenPos().y + 4})
		synth_knob_row(a, w, {{"Voices", synth.osc_param(o, .Unison)}, {"Detune", synth.osc_param(o, .Detune)}, {"Blend", synth.osc_param(o, .Blend)}, {"Stereo", synth.osc_param(o, .Stereo_Spread)}, {"Curve", synth.osc_param(o, .Detune_Power)}, {"Range", synth.osc_param(o, .Detune_Range)}, {"Warp", synth.osc_param(o, .Warp_Amount)}, {"Morph", synth.osc_param(o, .Spectral_Amount)}})
	} else {
		synth_knob_row(a, w, {{"Level", synth.sample_param(.Level)}, {"Pan", synth.sample_param(.Pan)}, {"Transpose", synth.sample_param(.Transpose)}, {"Tune", synth.sample_param(.Tune)}})
		im.SetCursorScreenPos({pos.x + view_w + 14, im.GetCursorScreenPos().y + 4})
		synth_toggle(a, "Random start##smp", synth.sample_param(.Random_Phase))
	}
}

// The wavetable of oscillator `osc` (3: the sample's waveform) as frames
// stacked back in perspective, the one playing (the newest note's, else
// its frame setting) in the pad's colour. A sound dropped on it becomes
// the table (or the sample).
draw_table_view :: proc(a: ^App, osc: int, size: im.Vec2) {
	m := &a.m
	i := a.selected
	t := ui.theme()
	dl := im.GetWindowDrawList()
	pos := im.GetCursorScreenPos()
	im.InvisibleButton("##tableview", size)
	ui.name("wavetable view")
	im.DrawList_AddRectFilled(dl, pos, {pos.x + size.x, pos.y + size.y}, ui.col(ui.PLOT_BG), t.radius)
	color := ui.rgb(m.project.pads[i].color)
	if im.BeginDragDropTarget() {
		if pl := im.AcceptDragDropPayload("PADS_FILE"); pl != nil {
			path := strings.string_from_ptr((^u8)(pl.Data), int(pl.DataSize))
			if id, err := pm.import_sample(m, path); err == .None {
				if osc < 3 do pm.set_synth_table(m, i, osc, {sample = id})
				else do pm.set_synth_sample(m, i, {sample = id})
			}
		}
		im.EndDragDropTarget()
	}
	if osc >= 3 {
		msg: cstring = "The sample oscillator: noise, or any sound dropped here"
		ts := im.CalcTextSize(msg)
		im.DrawList_AddText(dl, {pos.x + (size.x - ts.x) / 2, pos.y + (size.y - ts.y) / 2}, ui.col(t.text_dim), msg)
		return
	}
	tab := pm.synth_pad_table(&m.engine, i, osc)
	if tab == nil do return
	live, playing := pm.synth_live(&m.engine, i)
	frame_pos := synth.param_curve(synth.param_spec(synth.osc_param(osc + 1, .Frame)), pm.synth_value(m, i, synth.osc_param(osc + 1, .Frame)))
	if playing && live.sounding do frame_pos = live.frames[osc]
	now := synth.wave_frame_at(tab, frame_pos)
	// Up to 24 frames drawn, back to front, each shifted up and right.
	shown := min(tab.frames, 24)
	pad: f32 = 10
	depth := size.y * 0.35 if tab.frames > 1 else 0
	w := size.x - 2 * pad - depth * 0.6
	h := (size.y - 2 * pad - depth) * 0.5
	for k := shown - 1; k >= 0; k -= 1 {
		f := k * (tab.frames - 1) / max(shown - 1, 1)
		d := f32(k) / f32(max(shown - 1, 1))
		ox := pos.x + pad + d * depth * 0.6
		oy := pos.y + pad + h + (1 - d) * depth
		c := ui.with_alpha(ui.mix(ui.PLOT_BG, t.text, 0.25), 0.7)
		draw_frame(dl, tab.waves[f][:], ox, oy, w, h * 0.9, c, 1)
	}
	d := f32(now) / f32(max(tab.frames - 1, 1))
	lit := tab.waves[now][:]
	// Morphed: the frame as the morph makes it (its first 256 harmonics).
	morph := synth.Spectral_Morph(int(math.round(pm.synth_value(m, i, synth.osc_param(osc + 1, .Spectral_Morph)))))
	if morph != .None {
		fft: dsp.Real_Fft
		if dsp.real_fft_init(&fft, synth.WAVE_SIZE, allocator = context.temp_allocator) == .None {
			spec := make([]complex64, synth.WAVE_BINS, context.temp_allocator)
			buf := make([]f32, synth.WAVE_SIZE + synth.WAVE_PAD, context.temp_allocator)
			amount := pm.synth_value(m, i, synth.osc_param(osc + 1, .Spectral_Amount))
			synth.wave_build(&fft, tab, now, 256, spec, buf, morph, amount)
			peak: f32 = 1
			for x in buf do peak = max(peak, abs(x))
			for &x in buf do x /= peak
			lit = buf[1:synth.WAVE_SIZE + 1]
		}
	}
	draw_frame(dl, lit, pos.x + pad + d * depth * 0.6, pos.y + pad + h + (1 - d) * depth, w, h * 0.9, color, 2)
	im.DrawList_AddText(dl, {pos.x + 8, pos.y + size.y - im.GetTextLineHeight() - 6}, ui.col(t.text_dim), fmt.ctprintf("%s · frame %d of %d", tab.name, now + 1, tab.frames))
}

// One frame's wave as a line `w` wide about `y`, `h` up and down.
draw_frame :: proc(dl: ^im.DrawList, wave: []f32, x, y, w, h: f32, c: ui.Color, thick: f32) {
	N :: 96
	pts: [N]im.Vec2
	for k in 0 ..< N {
		s := wave[k * len(wave) / N]
		pts[k] = {x + w * f32(k) / f32(N - 1), y - s * h}
	}
	im.DrawList_AddPolyline(dl, &pts[0], N, ui.col(c), thick)
}

// --- Mod -----------------------------------------------------------------------------------------

// The Mod tab: every source as a chip to drag, and every route: its
// source, what it moves, its amount, curve, bipolar, stereo, bypass.
draw_synth_mod :: proc(a: ^App) {
	m := &a.m
	i := a.selected
	sy := &m.project.pads[i].synth
	im.TextDisabled("Drag a source onto any knob:")
	n := 0
	for s in synth.Mod_Source {
		if s == .None do continue
		if n > 0 do ui.flow(chip_width(a, s), 4)
		mod_chip(a, s)
		n += 1
	}
	im.Spacing()
	im.Separator()
	if sy.route_count == 0 {
		im.TextDisabled("No modulation yet.")
		return
	}
	if !im.BeginTable("##routes", 7, {.RowBg, .SizingStretchProp}) do return
	defer im.EndTable()
	for h in ([]cstring{"Source", "Destination", "Amount", "Curve", "Bipolar", "Stereo", ""}) do im.TableSetupColumn(h)
	im.TableHeadersRow()
	for k := 0; k < sy.route_count; k += 1 {
		r := sy.routes[k]
		im.PushIDInt(i32(k))
		im.TableNextRow()
		im.TableNextColumn()
		im.TextColored(transmute(im.Vec4)mod_color(r.source), "%s", fmt.ctprintf("%s", mod_name(a, r.source)))
		im.TableNextColumn()
		spec := synth.param_spec(r.dest)
		im.Text("%s", fmt.ctprintf("%s", spec.name if spec != nil else "?"))
		im.TableNextColumn()
		amt := f64(r.amount * 100)
		if e := ui.number_drag("amount", &amt, -100, 100, 1, 0.1, "%+.0f%%", 90); e.changed {
			x := r
			x.amount = f32(amt / 100)
			pm.set_synth_route(m, i, k, x, "Modulation Amount")
		} else if e.ended do app.seal(&m.history)
		im.TableNextColumn()
		pw := f64(r.power)
		if e := ui.number_drag("curve", &pw, -10, 10, 0.1, 0.01, "%+.1f", 70); e.changed {
			x := r
			x.power = f32(pw)
			pm.set_synth_route(m, i, k, x, "Modulation Curve")
		} else if e.ended do app.seal(&m.history)
		im.TableNextColumn()
		flags := [3]bool{r.bipolar, r.stereo, !r.bypass}
		if ui.toggle("##bi", &flags[0]) {
			x := r
			x.bipolar = flags[0]
			pm.set_synth_route(m, i, k, x, "Bipolar")
			app.seal(&m.history)
		}
		im.TableNextColumn()
		if ui.toggle("##st", &flags[1]) {
			x := r
			x.stereo = flags[1]
			pm.set_synth_route(m, i, k, x, "Stereo")
			app.seal(&m.history)
		}
		im.TableNextColumn()
		if ui.toggle("##on", &flags[2]) {
			x := r
			x.bypass = !flags[2]
			pm.set_synth_route(m, i, k, x, "Bypass")
			app.seal(&m.history)
		}
		im.SameLine(0, 8)
		if ui.icon_button(ui.ICON_TRASH_2, "Remove this modulation") {
			pm.remove_synth_route(m, i, k)
			k -= 1
		}
		ui.name(fmt.tprintf("remove route %d", k + 1))
		im.PopID()
	}
}

// --- Macro ---------------------------------------------------------------------------------------

// The Macro tab: four macro knobs (named; drag their chips to assign)
// and the keyboard's sources.
draw_synth_macro :: proc(a: ^App) {
	m := &a.m
	i := a.selected
	avail := im.GetContentRegionAvail()
	row := spread_begin(synth.MACROS, avail.x)
	top := im.GetCursorScreenPos()
	for k in 0 ..< synth.MACROS {
		name := pm.synth_macro_name(m, i, k)
		label := fmt.ctprintf("%s###macro%d", name, k)
		spread_next(&row, label)
		x := im.GetCursorScreenPos().x
		synth_knob(a, label, fc.Param_Id(int(synth.global_param(.Macro_1)) + k))
		im.SetCursorScreenPos({x, top.y + im.GetTextLineHeight() * 2 + ui.KNOB_SIZE + 12})
		mod_chip(a, synth.Mod_Source(int(synth.Mod_Source.Macro_1) + k))
		im.SetCursorScreenPos(top)
	}
	im.SetCursorScreenPos({top.x, top.y + im.GetTextLineHeight() * 3 + ui.KNOB_SIZE + 30})
	// Renaming: a field each.
	for k in 0 ..< synth.MACROS {
		if k > 0 do im.SameLine(0, 8)
		buf: [16]u8
		copy(buf[:15], pm.synth_macro_name(m, i, k))
		im.SetNextItemWidth(avail.x / 4 - 12)
		if im.InputText(fmt.ctprintf("##mname%d", k), cstring(&buf[0]), len(buf), {.EnterReturnsTrue}) {
			pm.set_synth_macro_name(m, i, k, strings.truncate_to_byte(string(buf[:]), 0))
		}
	}
	im.Spacing()
	im.Separator()
	im.TextDisabled("The keyboard's sources:")
	for s, n in ([]synth.Mod_Source{.Velocity, .Note, .Note_In_Octave, .Aftertouch, .Mod_Wheel, .Pitch_Wheel, .Stereo, .Random}) {
		if n > 0 do ui.flow(chip_width(a, s), 4)
		mod_chip(a, s)
	}
}

// --- Global --------------------------------------------------------------------------------------

PRIORITY_NAMES := []string{"Newest first", "Oldest first", "Highest first", "Lowest first", "Round robin"}

// The Global tab: voices, glide, bend, velocity, tuning, oversampling,
// and its level; the voices sounding now.
draw_synth_global :: proc(a: ^App) {
	m := &a.m
	i := a.selected
	g :: synth.global_param
	mode := int(pm.synth_value(m, i, g(.Mono)))
	if ui.segmented("voice_mode", {"Poly", "Mono", "Legato"}, &mode) {
		pm.set_synth_value(m, i, g(.Mono), f32(mode), "Voice Mode")
		app.seal(&m.history)
	}
	im.SameLine(0, 14)
	os := int(pm.synth_value(m, i, g(.Oversampling)))
	im.AlignTextToFramePadding()
	im.TextDisabled("Oversampling")
	im.SameLine()
	if ui.segmented("oversampling", {"1×", "2×", "4×", "8×"}, &os) {
		pm.set_synth_value(m, i, g(.Oversampling), f32(os), "Oversampling")
		app.seal(&m.history)
	}
	im.SameLine(0, 14)
	synth_choice(a, g(.Priority), PRIORITY_NAMES, 130, "##prio")
	synth_toggle(a, "Always glide", g(.Glide_Always))
	im.SameLine(0, 10)
	synth_toggle(a, "Glide by octaves", g(.Glide_Octave))
	if live, ok := pm.synth_live(&m.engine, i); ok {
		im.SameLine(0, 14)
		im.AlignTextToFramePadding()
		im.TextDisabled("%s", fmt.ctprintf("%d sounding", live.voices))
	}
	im.Spacing()
	avail := im.GetContentRegionAvail()
	synth_knob_row(a, avail.x, {{"Volume", g(.Volume)}, {"Voices", g(.Polyphony)}, {"Glide", g(.Glide)}, {"Glide Curve", g(.Glide_Slope)}, {"Bend Range", g(.Bend_Range)}, {"Velocity", g(.Velocity_Track)}, {"Transpose", g(.Transpose)}, {"Tune", g(.Tune)}})
	im.Spacing()
	avail = im.GetContentRegionAvail()
	draw_synth_scope(a, {avail.x, max(avail.y - 6, 60)})
}

// The synth's output: an oscilloscope (a few cycles, steadied on a
// rising zero crossing) and its spectrum beside it.
draw_synth_scope :: proc(a: ^App, size: im.Vec2) {
	m := &a.m
	t := ui.theme()
	dl := im.GetWindowDrawList()
	pos := im.GetCursorScreenPos()
	im.Dummy(size)
	ui.name("synth scope")
	buf: [synth.SCOPE_FRAMES]f32
	if !pm.synth_scope(&m.engine, a.selected, buf[:]) do return
	color := ui.rgb(m.project.pads[a.selected].color)
	half := (size.x - 10) / 2
	// The scope: 1024 frames from a rising zero crossing in the first half.
	im.DrawList_AddRectFilled(dl, pos, {pos.x + half, pos.y + size.y}, ui.col(ui.PLOT_BG), t.radius)
	start := 0
	for k in 1 ..< 1024 do if buf[k - 1] < 0 && buf[k] >= 0 {
		start = k
		break
	}
	N :: 256
	pts: [N]im.Vec2
	mid := pos.y + size.y / 2
	peak: f32 = 0.05
	for k in 0 ..< 1024 do peak = max(peak, abs(buf[start + k]))
	for k in 0 ..< N {
		v := buf[start + k * 1024 / N] / peak
		pts[k] = {pos.x + 6 + (half - 12) * f32(k) / f32(N - 1), mid - v * (size.y / 2 - 8)}
	}
	im.DrawList_AddLine(dl, {pos.x + 6, mid}, {pos.x + half - 6, mid}, ui.col(ui.mix(ui.PLOT_BG, t.text, 0.1)), 1)
	im.DrawList_AddPolyline(dl, &pts[0], N, ui.col(color), 1.6)
	// The spectrum (Hann-windowed), on the response plots' log axis.
	sp := im.Vec2{pos.x + half + 10, pos.y}
	im.DrawList_AddRectFilled(dl, sp, {sp.x + half, sp.y + size.y}, ui.col(ui.PLOT_BG), t.radius)
	fft: dsp.Real_Fft
	dsp.real_fft_init(&fft, synth.SCOPE_FRAMES, allocator = context.temp_allocator)
	win := make([]f32, synth.SCOPE_FRAMES, context.temp_allocator)
	for &w, k in win do w = buf[k] * (0.5 - 0.5 * math.cos(math.TAU * f32(k) / f32(synth.SCOPE_FRAMES - 1)))
	spec := make([]complex64, synth.SCOPE_FRAMES / 2, context.temp_allocator)
	dsp.real_fft_forward(&fft, win, spec)
	sr := a.host.graph.settings.sample_rate if a.host.graph.settings.sample_rate > 0 else 48_000
	M :: 160
	spts: [M]im.Vec2
	for k in 0 ..< M {
		hz := f64(ui.x_freq(f32(k) / (M - 1)))
		bin := clamp(int(hz / sr * synth.SCOPE_FRAMES + 0.5), 1, synth.SCOPE_FRAMES / 2 - 1)
		db := 20 * math.log10(max(f64(abs(spec[bin])) / (synth.SCOPE_FRAMES / 4), 1e-6))
		f := clamp(f32((db + 90) / 90), 0, 1)
		spts[k] = {sp.x + 6 + (half - 12) * f32(k) / (M - 1), sp.y + size.y - 6 - f * (size.y - 12)}
	}
	im.DrawList_AddPolyline(dl, &spts[0], M, ui.col(color), 1.6)
	im.DrawList_AddText(dl, {sp.x + 8, sp.y + 4}, ui.col(t.text_dim), "Spectrum")
	im.DrawList_AddText(dl, {pos.x + 8, pos.y + 4}, ui.col(t.text_dim), "Output")
}
