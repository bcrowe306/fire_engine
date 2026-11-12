package pads

import "core:fmt"

import "app:ui"
import pm "model"
import im "deps:imgui"

// The sampler device's tabs (an audio pad has Sample and Global).
Detail_Tab :: enum u8 {
	Sample,
	Env,
	Filter,
	Pitch,
	Lfo,
	Global,
}

// What the bottom panel shows the devices of: a pad's chain (its sampler,
// its EQ, its inserts), a bus's (its slots), or a performance effect.
Track_Kind :: enum u8 {
	Pad,
	Bus,  // `index`: the bus (BUSES: main)
	Perf, // `index`: the performance effect
}

// A track of the bottom panel.
Track :: struct {
	kind:  Track_Kind,
	index: int,
}

// A device of a track's chain: the instrument (a pad's sampler, or its
// audio), its EQ, or effect slot `slot`.
Device :: struct {
	kind: enum u8 { Instrument, Eq, Slot },
	slot: int,
}

// The bottom panel's state: the track it shows, which device and which of
// the sampler's tabs are in front, and how wide the pads are.
Detail_State :: struct {
	track:       Track,
	device:      Device,
	tab:         Detail_Tab,
	show:        int, // frames left to bring `device` (and `tab`) to the front
	pads_width:  f32, // 0: as wide as the pads are tall
	selected_was: int, // the selected pad last frame (choosing a pad shows its chain)
}

DETAIL_NAMES := [Detail_Tab]string{.Sample = "Sample", .Env = "Env", .Filter = "Filter", .Pitch = "Pitch", .Lfo = "LFO", .Global = "Global"}
DETAIL_ICONS := [Detail_Tab]string{.Sample = ui.ICON_AUDIO_WAVEFORM, .Env = ui.ICON_CHART_SPLINE, .Filter = ui.ICON_AUDIO_LINES, .Pitch = ui.ICON_MOVE_VERTICAL, .Lfo = ui.ICON_ACTIVITY, .Global = ui.ICON_SLIDERS_HORIZONTAL}

// Whether a sampler tab belongs to the selected pad (an audio pad has no voice).
@(private)
tab_shown :: proc(a: ^App, tab: Detail_Tab) -> bool {
	if a.m.project.pads[a.selected].kind != .Audio do return true
	return tab == .Sample || tab == .Global
}

// Shows effect slot `fx`'s device: its track's chain, its tab in front.
show_device :: proc(a: ^App, fx: pm.Fx_Target) {
	a.fx = fx
	st := &a.detail
	switch fx.kind {
	case .None: return
	case .Pad:
		a.selected = fx.index
		st.selected_was = fx.index
		st.track, st.device = {.Pad, fx.index}, {.Slot, fx.slot}
	case .Bus:  st.track, st.device = {.Bus, fx.index}, {.Slot, fx.slot}
	case .Perf: st.track, st.device = {.Perf, fx.index}, {.Slot, 0}
	case .Instrument:
		a.selected = fx.index
		st.selected_was = fx.index
		st.track, st.device = {.Pad, fx.index}, {.Instrument, 0}
	}
	st.show = 2
	a.ws.bottom_folded = false
}

// Shows pad `index`'s chain (when it shows something else).
show_pad_chain :: proc(a: ^App, index: int) {
	st := &a.detail
	if st.track == {.Pad, index} do return
	st.track = {.Pad, index}
	if st.device.kind == .Slot do st.device = {.Instrument, 0}
	st.show = 2
}

// Shows the selected pad's EQ.
show_eq :: proc(a: ^App) {
	st := &a.detail
	st.track, st.device, st.show = {.Pad, a.selected}, {.Eq, 0}, 2
	a.ws.bottom_folded = false
}

// Width of the divider between the pads and the tabs.
@(private) DIVIDER :: 9

// Brings the selected pad's sampler, its tab `tab`, to the front (and
// the panel).
show_detail :: proc(a: ^App, tab: Detail_Tab) {
	st := &a.detail
	st.track, st.device, st.tab, st.show = {.Pad, a.selected}, {.Instrument, 0}, tab, 2
	a.ws.bottom_folded = false
}

// The bottom area, open (`draw_detail`) or folded (`draw_pad_bar`).
draw_bottom :: proc(user: rawptr, folded: bool) {
	a := (^App)(user)
	// This area (the pads, the sound's devices and effects, the strip) is
	// drawn in its track's colour; the rest of the window keeps the
	// theme's accent.
	ui.set_accent(&a.platform, track_accent(a, folded))
	defer ui.set_accent(&a.platform, {})
	if folded do draw_pad_bar(a)
	else do draw_detail(a)
}

// The colour the bottom area's accent takes: the pad whose chain it shows
// (folded: the selected pad), if it has a sound; else none (a bus, the
// performance effects, an empty pad: the theme's accent).
track_accent :: proc(a: ^App, folded: bool) -> ui.Color {
	st := &a.detail
	index := a.selected
	if !folded {
		if st.track.kind != .Pad do return {}
		index = st.track.index
	}
	if !pm.pad_used(&a.m.project, index) do return {}
	return ui.rgb(a.m.project.pads[index].color)
}

// The bottom area folded: the bank's 16 pads in a row, each its name and
// colour (bright while it plays), and a button to unfold. Clicking a pad
// selects it and unfolds on it; files and devices drop onto them as onto
// the grid.
draw_pad_bar :: proc(a: ^App) {
	p := &a.m.project
	t := ui.theme()
	h := im.GetFrameHeight()
	gap: f32 = 4
	room := h + t.gap.x
	w := max((im.GetContentRegionAvail().x - room - 15 * gap) / 16, 24)
	dl := im.GetWindowDrawList()
	ui.text_push(.Label)
	for k in 0 ..< pm.PADS_PER_BANK {
		index := a.bank * pm.PADS_PER_BANK + k
		pad := &p.pads[index]
		if k > 0 do im.SameLine(0, gap)
		pos := im.GetCursorScreenPos()
		im.PushIDInt(i32(index))
		clicked := im.InvisibleButton("##barpad", {w, h})
		label := pm.pad_label(index)
		ui.name(fmt.tprintf("bar pad %s", label))
		a.pad_rects[k] = {pos, {pos.x + w, pos.y + h}}
		has := pm.pad_used(p, index)
		lit := a.lit[index] > 0 || a.held[index]
		c := ui.rgb(pad.color)
		hovered := im.IsItemHovered()
		bg := t.hover if hovered else t.raised
		if has do bg = ui.mix(bg, c, 0.6 if lit else 0.25)
		im.DrawList_AddRectFilled(dl, pos, {pos.x + w, pos.y + h}, ui.col(bg), t.radius)
		if has do im.DrawList_AddRectFilled(dl, {pos.x, pos.y + h - 3}, {pos.x + w, pos.y + h}, ui.col(c), t.radius, {.RoundCornersBottomLeft, .RoundCornersBottomRight})
		if index == a.selected do im.DrawList_AddRect(dl, pos, {pos.x + w, pos.y + h}, ui.col(t.accent), t.radius, 1.5)
		text := fmt.ctprintf("%s", pm.pad_name(pad) if has else label)
		ts := im.CalcTextSize(text)
		im.DrawList_PushClipRect(dl, {pos.x + 4, pos.y}, {pos.x + w - 4, pos.y + h}, true)
		im.DrawList_AddText(dl, {pos.x + max((w - ts.x) / 2, 4), pos.y + (h - ts.y) / 2}, ui.col(t.text if has else t.text_dim), text)
		im.DrawList_PopClipRect(dl)
		if hovered do im.SetTooltip("%s", fmt.ctprintf("%s%s: click to select it and unfold", label, fmt.tprintf(" %s", pm.pad_name(pad)) if has else ""))
		if clicked {
			a.pad_sel, a.pad_anchor = {index}, index
			select_pad(a, index, false)
			show_pad_chain(a, index)
			a.ws.bottom_folded = false
		}
		im.PopID()
	}
	ui.text_pop()
	im.SameLine(0, t.gap.x)
	if ui.icon_button(ui.ICON_CHEVRON_UP, "Unfold the pads and the sound (Cmd+J)") do a.ws.bottom_folded = false
}

// The bottom panel, as Ableton's detail view: the pad grid on the left,
// the selected pad in tabs (its sample, its settings, its effects, how it
// plays), and its channel strip at the far right. The divider between the
// grid and the tabs drags.
draw_detail :: proc(user: rawptr) {
	a := (^App)(user)
	st := &a.detail
	// Choosing a pad shows its chain.
	if a.selected != st.selected_was {
		st.selected_was = a.selected
		if st.track.kind != .Pad || st.track.index != a.selected {
			st.track = {.Pad, a.selected}
			if st.device.kind == .Slot do st.device = {.Instrument, 0}
		}
	}
	t := ui.theme()
	// Along the top, where a panel's tab would be: the track's devices
	// (and a synth's presets, at the line's right).
	line := im.GetCursorScreenPos()
	line_right := line.x + im.GetContentRegionAvail().x
	device_tabs(a)
	// At the line's right: how the pads play, and folding the area away
	// (a synth's presets before them).
	fh := im.GetFrameHeight()
	right_room := 4 * fh + 3 * 2 + 16
	if st.track.kind == .Pad && st.device.kind == .Instrument && a.m.project.pads[st.track.index].kind == .Synth do draw_preset_bar(a, line_right - right_room, line.y)
	{
		back := im.GetCursorScreenPos()
		im.SetCursorScreenPos({line_right - right_room + 16, line.y})
		draw_play_modes(a)
		im.SameLine(0, 2)
		if ui.icon_button(ui.ICON_CHEVRON_DOWN, "Fold the pads and the sound to a bar (Cmd+J)") do a.ws.bottom_folded = true
		im.SetCursorScreenPos(back)
	}
	avail := im.GetContentRegionAvail()
	// The pads: a square grid as tall as the panel, unless dragged wider or narrower.
	header := im.GetFrameHeight() + im.GetStyle().ItemSpacing.y * 2
	auto := min(avail.y - header + 24, 340) // (square, but no wider than leaves the device room)
	w := st.pads_width if st.pads_width > 0 else auto
	w = clamp(w, 260, max(avail.x * 0.6, 260))
	if im.BeginChild("##pads", {w, avail.y}, {}, {.NoScrollbar, .NoScrollWithMouse}) do draw_pads(a)
	im.EndChild()

	// The divider.
	im.SameLine(0, 0)
	pos := im.GetCursorScreenPos()
	im.InvisibleButton("##divider", {DIVIDER, avail.y})
	ui.name("pads divider")
	hot := im.IsItemHovered() || im.IsItemActive()
	if hot do im.SetMouseCursor(.ResizeEW)
	if im.IsItemActive() do st.pads_width = w + im.GetIO().MouseDelta.x
	if im.IsItemHovered() && im.IsMouseDoubleClicked(.Left) do st.pads_width = 0
	dl := im.GetWindowDrawList()
	x := pos.x + DIVIDER / 2
	im.DrawList_AddLine(dl, {x, pos.y + 4}, {x, pos.y + avail.y - 4}, ui.col(t.accent if hot else t.border), 2 if hot else 1)

	// The selected pad's tabs.
	im.SameLine(0, 0)
	// At the far right, the selected pad's channel strip (the mixer's).
	strip_room: f32 = STRIP_W + 12
	im.PushStyleVarVec2(.WindowPadding, {im.GetStyle().WindowPadding.x, 0})
	if im.BeginChild("##detail", {max(im.GetContentRegionAvail().x - strip_room, 100), avail.y}, {.AlwaysUseWindowPadding}) {
		device_content(a)
	}
	im.EndChild()
	im.PopStyleVar()
	im.SameLine(0, 6)
	if im.BeginChild("##strip", {STRIP_W + 4, avail.y}, {}, {.NoScrollbar, .NoScrollWithMouse}) {
		im.PushStyleVarVec2(.ItemSpacing, {STRIP_GAP, 0}) // as the mixer lays strips out
		switch st.track.kind {
		case .Pad:  pad_strip(a, st.track.index, avail.y, compact = true)
		case .Bus:  bus_strip(a, st.track.index, avail.y)
		case .Perf: bus_strip(a, pm.BUSES, avail.y)
		}
		im.PopStyleVar()
	}
	im.EndChild()
	if st.show > 0 do st.show -= 1
}

// The track's devices, a tab each, across the top of the panel: a pad's
// sampler ("A1 kick · Sampler"; an audio pad's "· Audio"), its EQ and its
// inserts; a bus's slots; a performance effect. A + tab puts an effect in
// the first empty slot. The tabs choose; `device_content` draws.
@(private)
device_tabs :: proc(a: ^App) {
	m := &a.m
	st := &a.detail
	tr := st.track
	if !im.BeginTabBar("##devices", {.FittingPolicyScroll}) do return
	defer im.EndTabBar()
	tab :: proc(st: ^Detail_State, label: cstring, d: Device, flags: im.TabItemFlags = {}) -> bool {
		f := flags
		if st.show > 0 && st.device == d do f += {.SetSelected}
		if !im.BeginTabItem(label, nil, f) do return false
		if st.show == 0 do st.device = d
		im.EndTabItem()
		return true
	}
	slot_tab :: proc(a: ^App, st: ^Detail_State, fx: pm.Fx_Target) -> bool {
		s, _ := pm.target_slot(&a.m, fx)
		if s.kind == .None do return false
		label := fmt.ctprintf("%s  %s%s###dev%d", ui.ICON_WAND_SPARKLES, pm.slot_name(s), "" if s.on else " (off)", fx.slot)
		tab(st, label, {.Slot, fx.slot})
		item_menu(a, {kind = .Slot, fx = fx}, "##devmenu")
		return true
	}
	add_tab :: proc(st: ^Detail_State, slot: int) {
		tab(st, ui.ICON_PLUS + "###devadd", {.Slot, slot}, {.Trailing})
		if im.IsItemHovered() do im.SetTooltip("Add an effect")
	}
	first_empty :: proc(a: ^App, kind: pm.Fx_Target_Kind, index, slots: int) -> int {
		for k in 0 ..< slots do if s, _ := pm.target_slot(&a.m, {kind, index, k}); s.kind == .None do return k
		return -1
	}
	switch tr.kind {
	case .Pad:
		i := tr.index
		pad := &m.project.pads[i]
		name := pm.pad_name(pad) if pm.pad_used(&m.project, i) else ""
		instr := fmt.ctprintf("%s  %s%s%s · %s###devinst", ui.ICON_SNOWFLAKE if pad.frozen else (ui.ICON_MIC if pad.kind == .Audio else (ui.ICON_PLUG if pad.kind == .Plugin else ui.ICON_LAYOUT_GRID)), pm.pad_label(i), " " if name != "" else "", name, fmt.tprintf("%s (frozen)", pad_device_name(pad.kind)) if pad.frozen else pad_device_name(pad.kind))
		tab(st, instr, {.Instrument, 0})
		item_menu(a, pad_target(i), "##instmenu")
		tab(st, ui.ICON_SLIDERS_VERTICAL + "  EQ###deveq", {.Eq, 0})
		for k in 0 ..< pm.PAD_INSERTS do slot_tab(a, st, {.Pad, i, k})
		if e := first_empty(a, .Pad, i, pm.PAD_INSERTS); e >= 0 do add_tab(st, e)
	case .Bus:
		bus_label := fmt.ctprintf("%s  %s###devbus", ui.ICON_SLIDERS_VERTICAL, pm.bus_index_name(&a.m.project, tr.index))
		im.TabItemButton(bus_label, {.Leading, .NoTooltip})
		for k in 0 ..< pm.BUS_SLOTS do slot_tab(a, st, {.Bus, tr.index, k})
		if e := first_empty(a, .Bus, tr.index, pm.BUS_SLOTS); e >= 0 do add_tab(st, e)
	case .Perf:
		slot_tab(a, st, {.Perf, tr.index, 0})
	}
}

// The device in front: the sampler (its own tabs), the EQ, an effect, or
// the + tab's effects to put in an empty slot.
@(private)
device_content :: proc(a: ^App) {
	m := &a.m
	st := &a.detail
	tr := st.track
	pm.watch_slot(&m.engine, {}) // the effect in front is watched (below)
	switch st.device.kind {
	case .Instrument:
		if tr.kind == .Pad && a.m.project.pads[tr.index].frozen {
			draw_frozen(a, tr.index)
			return
		}
		if tr.kind == .Pad {
			#partial switch a.m.project.pads[tr.index].kind {
			case .Synth:  draw_synth_tabs(a)
			case .Plugin: draw_plugin_pad(a, tr.index)
			case:         draw_sampler_tabs(a)
			}
		}
	case .Eq:
		if tr.kind == .Pad do draw_pad_eq(a)
	case .Slot:
		fx: pm.Fx_Target
		switch tr.kind {
		case .Pad:  fx = {.Pad, tr.index, st.device.slot}
		case .Bus:  fx = {.Bus, tr.index, st.device.slot}
		case .Perf: fx = {.Perf, tr.index, 0}
		}
		s, ok := pm.target_slot(m, fx)
		if !ok do return
		if s.kind != .None || tr.kind == .Perf {
			a.fx = fx
			pm.watch_slot(&m.engine, fx)
			draw_effect(a)
			return
		}
		// An empty slot: what to put in it.
		im.TextDisabled("Put an effect in the chain:")
		im.Spacing()
		n := 0
		for k in pm.Effect_Kind {
			if k == .None || k == .Plugin || pm.effect_kind_legacy(k) do continue
			if n % 6 != 0 do im.SameLine()
			n += 1
			if im.Button(fmt.ctprintf("%s###add%d", pm.EFFECT_NAMES[k], int(k)), {110, 0}) {
				pm.set_target_slot(m, fx, pm.new_effect(k), "Add Effect")
				show_device(a, fx)
			}
			ui.name(fmt.tprintf("add %s", pm.EFFECT_NAMES[k]))
		}
	}
}

// What a pad's device is called (its instrument tab says).
pad_device_name :: proc(k: pm.Pad_Kind) -> string {
	switch k {
	case .Sampler: return "Sampler"
	case .Audio:   return "Audio"
	case .Slicer:  return "Slicer"
	case .Synth:   return "Synth"
	case .Plugin:  return "Plug-in"
	}
	return ""
}

// The sampler's own tabs (Sample, Env, Filter, Pitch, LFO, Global), inside
// its device tab.
@(private)
draw_sampler_tabs :: proc(a: ^App) {
	st := &a.detail
	if !im.BeginTabBar("##detail_tabs") do return
	defer im.EndTabBar()
	for tab in Detail_Tab {
		if !tab_shown(a, tab) do continue
		flags: im.TabItemFlags
		if st.show > 0 && st.tab == tab do flags += {.SetSelected}
		name := DETAIL_NAMES[tab]
		if tab == .Sample && a.m.project.pads[a.selected].kind == .Slicer do name = "Slicer" // (its id stays: ###Sample)
		label := fmt.ctprintf("%s  %s###%s", DETAIL_ICONS[tab], name, DETAIL_NAMES[tab])
		if im.BeginTabItem(label, nil, flags) {
			if st.show == 0 do st.tab = tab
			if im.BeginChild("##tab", {0, 0}) {
				switch tab {
				case .Sample: draw_sample(a)
				case .Env:    draw_env(a)
				case .Filter: draw_filter(a)
				case .Pitch:  draw_pitch(a)
				case .Lfo:    draw_lfo(a)
				case .Global: draw_global(a)
				}
			}
			im.EndChild()
			im.EndTabItem()
		}
	}
}

// A frozen pad's device: what it is, and the way back (or on).
@(private)
draw_frozen :: proc(a: ^App, i: int) {
	t := ui.theme()
	im.Spacing()
	im.TextColored(transmute(im.Vec4)t.accent, "%s", fmt.ctprintf("%s  Frozen", ui.ICON_SNOWFLAKE))
	im.TextWrapped("%s", fmt.ctprintf("%s plays its renderings (one a sequence): its device and inserts are off, its fader, sends and output still work. Unfreeze it to edit its sound.", pm.pad_label(i)))
	im.Spacing()
	if im.Button(fmt.ctprintf("%s  Unfreeze###unfreeze", ui.ICON_SNOWFLAKE)) do pm.set_frozen(&a.m, i, false)
	ui.name("unfreeze")
	im.SameLine()
	if im.Button("Flatten to Audio") do pm.flatten(&a.m, i)
	ui.name("flatten")
	if im.IsItemHovered() do im.SetTooltip("An audio pad whose takes are its renderings (its device and inserts go)")
}
