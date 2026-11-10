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
	}
	st.show = 2
	ui.panel_focus(&a.ws, "detail")
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
	ui.panel_focus(&a.ws, "detail")
}

// Width of the divider between the pads and the tabs.
@(private) DIVIDER :: 9

// Brings the selected pad's sampler, its tab `tab`, to the front (and
// the panel).
show_detail :: proc(a: ^App, tab: Detail_Tab) {
	st := &a.detail
	st.track, st.device, st.tab, st.show = {.Pad, a.selected}, {.Instrument, 0}, tab, 2
	ui.panel_focus(&a.ws, "detail")
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
	avail := im.GetContentRegionAvail()
	// The pads: a square grid as tall as the panel, unless dragged wider or narrower.
	header := im.GetFrameHeight() + im.GetStyle().ItemSpacing.y * 2
	auto := avail.y - header + 24
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
		draw_devices(a)
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

// The track's devices, a tab each: a pad's instrument (the sampler's own
// tabs inside), its EQ and its inserts; a bus's slots; a performance
// effect. A + tab puts an effect in the first empty slot.
@(private)
draw_devices :: proc(a: ^App) {
	m := &a.m
	st := &a.detail
	tr := st.track
	if !im.BeginTabBar("##devices") do return
	defer im.EndTabBar()
	tab :: proc(st: ^Detail_State, label: cstring, d: Device) -> bool {
		flags: im.TabItemFlags
		if st.show > 0 && st.device == d do flags += {.SetSelected}
		if !im.BeginTabItem(label, nil, flags) do return false
		if st.show == 0 do st.device = d
		return true
	}
	slot_tab :: proc(a: ^App, st: ^Detail_State, fx: pm.Fx_Target, what: string) {
		s, _ := pm.target_slot(&a.m, fx)
		if s.kind == .None do return
		label := fmt.ctprintf("%s  %s%s###dev%d", ui.ICON_WAND_SPARKLES, pm.slot_name(s), "" if s.on else " (off)", fx.slot)
		if tab(st, label, {.Slot, fx.slot}) {
			item_menu(a, {kind = .Slot, fx = fx}, "##devmenu")
			a.fx = fx
			if im.BeginChild("##device", {0, 0}) do draw_effect(a)
			im.EndChild()
			im.EndTabItem()
		} else {
			item_menu(a, {kind = .Slot, fx = fx}, "##devmenu")
		}
		_ = what
	}
	add_tab :: proc(a: ^App, st: ^Detail_State, fx: pm.Fx_Target) {
		// An empty slot clicked (in the mixer, say): here, to fill it.
		flags: im.TabItemFlags = {.Trailing}
		if st.show > 0 && st.device == {.Slot, fx.slot} do flags += {.SetSelected}
		if im.BeginTabItem(ui.ICON_PLUS + "###devadd", nil, flags) {
			im.TextDisabled("Put an effect in the chain:")
			im.Spacing()
			for k in pm.Effect_Kind {
				if k == .None || k == .Plugin do continue
				defer ui.name(fmt.tprintf("add %s", pm.EFFECT_NAMES[k]))
				if int(k) > 1 && (int(k) - 1) % 6 != 0 do im.SameLine()
				if im.Button(fmt.ctprintf("%s###add%d", pm.EFFECT_NAMES[k], int(k)), {110, 0}) {
					pm.set_target_slot(&a.m, fx, pm.new_effect(k), "Add Effect")
					show_device(a, fx)
				}
			}
			im.EndTabItem()
		}
		if im.IsItemHovered() do im.SetTooltip("Add an effect")
	}
	switch tr.kind {
	case .Pad:
		i := tr.index
		pad := m.project.pads[i]
		instr := fmt.ctprintf("%s  %s###devinst", ui.ICON_MIC if pad.kind == .Audio else ui.ICON_LAYOUT_GRID, "Audio" if pad.kind == .Audio else "Sampler")
		if tab(st, instr, {.Instrument, 0}) {
			draw_sampler_tabs(a)
			im.EndTabItem()
		}
		if tab(st, ui.ICON_SLIDERS_VERTICAL + "  EQ###deveq", {.Eq, 0}) {
			if im.BeginChild("##device", {0, 0}) do draw_pad_eq(a)
			im.EndChild()
			im.EndTabItem()
		}
		empty := -1
		for k in 0 ..< pm.PAD_INSERTS {
			fx := pm.Fx_Target{.Pad, i, k}
			s, _ := pm.target_slot(m, fx)
			if s.kind == .None {
				if empty < 0 do empty = k
				continue
			}
			slot_tab(a, st, fx, "insert")
		}
		if empty >= 0 do add_tab(a, st, {.Pad, i, empty})
	case .Bus:
		empty := -1
		for k in 0 ..< pm.BUS_SLOTS {
			fx := pm.Fx_Target{.Bus, tr.index, k}
			s, _ := pm.target_slot(m, fx)
			if s.kind == .None {
				if empty < 0 do empty = k
				continue
			}
			slot_tab(a, st, fx, "slot")
		}
		if empty >= 0 do add_tab(a, st, {.Bus, tr.index, empty})
		if empty == 0 && st.device.kind == .Slot do im.TextDisabled("%s", fmt.ctprintf("%s has no effects yet: + adds one", pm.bus_name(0 if tr.index == pm.BUSES else tr.index + 1)))
	case .Perf:
		slot_tab(a, st, {.Perf, tr.index, 0}, "performance effect")
	}
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
		label := fmt.ctprintf("%s  %s###%s", DETAIL_ICONS[tab], DETAIL_NAMES[tab], DETAIL_NAMES[tab])
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
