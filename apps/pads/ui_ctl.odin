// The device panel on a controller's display (Push 2's, 960 x 160): the
// device the panel shows and its tab, as Pads shows them, laid out for the
// controller. Both are the same state: a tab or device chosen on the
// controller is chosen in the window, and the other way round.
//
// Under the status line (ui_views.odin: the top 16 points, on every
// view), in the 144 left:
//
//	  0 -  22  the tabs (the upper buttons)
//	 24 -  92  the tab's picture (its plot, its waveform...)
//	 94 - 124  its knobs as value bars, one an encoder (more: pages, the
//	           controller's ◀ ▶; the page strip at the picture's bottom right)
//	126 - 144  its choices (the lower buttons)
//
// The pad's meters down the right. The encoders turn the knobs as the
// mouse does (ui.Knob_Input); the buttons click what they show. The device
// chain is on the status line (▲ ▼ step it); Delete + Device removes the
// device shown, Mute + Device turns it off and on.
package pads

import "core:fmt"
import "core:strings"

import app "app:core"
import "app:ui"
import pa "api"
import pm "model"
import im "deps:imgui"
import "fire:clap"
import fc "fire:core"
import "fire:fx"
import "fire:sampler"
import "fire:synth"

CTL_COL :: 120
CTL_TABS_H :: 22
CTL_PLOT_Y :: 24
CTL_KNOB :: 24
CTL_KNOBS_H :: 30
CTL_BUTTONS_H :: 18
CTL_BAR_W :: CTL_COL - 16 // a knob's value bar
CTL_METER_W :: 14
// A choice's step: this much of an encoder's turn (three of Push 2's detents).
CTL_STEP :: 3.0 / 160

// The controller's own state of the device panel: the knobs' page (of the
// device and tab it is for: another starts at the first), the effect an
// empty slot would get, which of a synth's filters shows.
Ctl_State :: struct {
	page:   int,
	pages:  int, // the tab's pages, as last drawn
	key:    [6]int,
	add:    int,
	filter: int,
	route:  int, // the synth's modulation route shown
	seq_view: ui.Roll_View, // the sequencer's rows shown (its own: the window's are its size)
	seq_pad:  int,          // the selected pad they were brought to (+1; another: brought to it)
	fx_draw_us, fx_draw_max_us: f64, // the last family panel's drawing time, and the most since (ui_ctl_fx.odin's probe)
	seq_row:  int,          // the cursor: its row (the selected pad's, in Drums)
	seq_beat: f64,          // and the step it's on (a grid step's start, or a note's)
	seq_transient: bool,    // the selection's last note is there only because the cursor is on it (moved on: let go; Select: kept)
	mix:      Ctl_Mix,      // Mix (ui_ctl_mixer.odin)
	slice_tab: bool,        // a slicer's Slice tab (else its Slicer tab: both the window's Sample tab)
	song:      Ctl_Song,     // the Song view (ui_ctl_song.odin)
	auto_point: int,         // the Automation tab's point (of its lane's; ui_ctl_auto.odin)
	audio_region: int,       // the Audio tab's region, and the take Use Take plays (ui_ctl_audio.odin)
	audio_take:   int,
	auto_cc:      int, // the Automation tab on a MIDI CC lane: its controller + 1 (0: an automation lane), its pad
	auto_cc_pad:  int,
	settings:   Ctl_Settings, // the Settings view (ui_ctl_settings.odin)
	shift:      bool,        // the controller's Shift held (any view told: its knobs fine, labels say so)
	dev_delete: bool,        // Device: the controller's Delete held (with Device: the device shown removed)
	dev_mute:   bool,        // Device: its Mute held (with Device: the device shown off or on)
	browse_part: int,        // Browse: the part the arrows move in (0 the categories, 1 the list)
}

// Where the picture goes and how big it is.
@(private)
ctl_plot :: proc(full: im.Vec2) -> im.Vec2 {
	return {full.x - CTL_METER_W - 6, full.y - CTL_PLOT_Y - CTL_KNOBS_H - CTL_BUTTONS_H - 4}
}

// The device panel as the controller shows it.
ctl_device :: proc(ctx: ^View_Ctx, full: im.Vec2) {
	a := ctx.a
	m := &a.m
	st := &a.detail
	tr := st.track
	// Another device or tab: its first page.
	tab := int(st.tab)
	if tr.kind == .Pad && st.device.kind == .Instrument && m.project.pads[tr.index].kind == .Synth do tab = int(a.synth_ui.tab)
	kind := int(m.project.pads[tr.index].kind) if tr.kind == .Pad else -1
	key := [6]int{int(tr.kind), tr.index, int(st.device.kind), st.device.slot, tab, kind}
	if key != a.ctl.key {
		a.ctl.key = key
		a.ctl.page = 0
	}
	if inp := ctx.input; inp != nil {
		on :: proc(inp: ^pa.View_Input, b: pa.View_Button) -> bool { return inp.pressed[int(b)] }
		off :: proc(inp: ^pa.View_Input, b: pa.View_Button) -> bool { return inp.released[int(b)] }
		// ◀ ▶: the tab's pages; ▲ ▼: the chain; Device with Delete held:
		// the device shown removed, with Mute held: off or on.
		if on(inp, .Page_Left) do a.ctl.page = max(a.ctl.page - 1, 0)
		if on(inp, .Page_Right) do a.ctl.page = min(a.ctl.page + 1, max(a.ctl.pages - 1, 0))
		if on(inp, .Up) do ctl_next_device(a, -1)
		if on(inp, .Down) do ctl_next_device(a, 1)
		if on(inp, .Delete) do a.ctl.dev_delete = true
		if on(inp, .Mute) do a.ctl.dev_mute = true
		if on(inp, .Next_Device) {
			switch {
			case a.ctl.dev_delete: ctl_device_remove(a)
			case a.ctl.dev_mute:   ctl_device_toggle(a)
			case:                  ctl_next_device(a, 1)
			}
		}
		if off(inp, .Delete) do a.ctl.dev_delete = false
		if off(inp, .Mute) do a.ctl.dev_mute = false
	}
	ctx.buttons |= 1 << uint(pa.View_Button.Next_Device) | 1 << uint(pa.View_Button.Up) | 1 << uint(pa.View_Button.Down)
	ctx.pages = 1
	plot := ctl_plot(full)
	if tr.kind == .Pad do view_meter(a, tr.index, {full.x - CTL_METER_W, CTL_PLOT_Y}, {CTL_METER_W, plot.y}) // (beside the picture: the row under it is the knobs')
	im.SetCursorPos({0, CTL_PLOT_Y})
	switch st.device.kind {
	case .Instrument:
		if tr.kind != .Pad do break
		i := tr.index
		pad := m.project.pads[i]
		a.voice_edit = pad.voice
		switch {
		case !pm.pad_used(&m.project, i): ctl_empty_pad(ctx, i, full)
		case pad.frozen:                  ctl_frozen(ctx, i, full)
		case pad.kind == .Synth:          ctl_synth(ctx, i, plot, full)
		case pad.kind == .Plugin:         ctl_plugin(ctx, {.Instrument, i, 0}, plot, full)
		case:                             ctl_sampler(ctx, i, plot, full)
		}
	case .Eq:
		if tr.kind == .Pad do ctl_eq(ctx, tr.index, plot, full)
	case .Midi:
		if tr.kind == .Pad do ctl_midi(ctx, tr.index, plot, full)
	case .Slot:
		fx: pm.Fx_Target
		switch tr.kind {
		case .Pad:  fx = {.Pad, tr.index, st.device.slot}
		case .Bus:  fx = {.Bus, tr.index, st.device.slot}
		case .Perf: fx = {.Perf, tr.index, 0}
		}
		ctl_effect(ctx, fx, plot, full)
	}
	ctl_banks(ctx, full)
	a.ctl.pages = ctx.pages
	ctx.page = a.ctl.page
	im.SetCursorPos({0, 0})
	im.Dummy({1, 1}) // (an item after the cursor was moved: ImGui wants one)
}

// --- the parts ----------------------------------------------------------------------------------

// The row of tabs, `current` lit. The tab pressed, or -1.
@(private)
ctl_tabs :: proc(ctx: ^View_Ctx, names: []string, current: int) -> int {
	t := ui.theme()
	dl := im.GetWindowDrawList()
	o := im.GetWindowPos()
	cells := make([dynamic]string, context.temp_allocator)
	append(&cells, ..names)
	next := "" // (the next device: on the status line now, ▲ ▼ step it)
	pressed := -1
	ui.text_push(.Label)
	defer ui.text_pop()
	for name, k in cells {
		if k >= 8 do break
		if name == "" do continue
		x0 := o.x + f32(k * CTL_COL) + 4
		x1 := x0 + CTL_COL - 8
		lit := k == current && !(next != "" && k == 7)
		if lit {
			im.DrawList_AddRectFilled(dl, {x0, o.y + 2}, {x1, o.y + CTL_TABS_H - 2}, ui.col(t.raised), t.radius)
			im.DrawList_AddLine(dl, {x0 + 6, o.y + CTL_TABS_H - 2}, {x1 - 6, o.y + CTL_TABS_H - 2}, ui.col(t.accent), 2)
		}
		label := fmt.ctprintf("%s", name)
		ts := im.CalcTextSize(label)
		im.DrawList_AddText(dl, {(x0 + x1 - ts.x) / 2, o.y + (CTL_TABS_H - ts.y) / 2}, ui.col(t.text if lit else t.text_dim), label)
		b := int(pa.View_Button.Upper_1) + k
		ctx.buttons |= 1 << uint(b)
		if lit do ctx.lit |= 1 << uint(b)
		if ctx.input != nil && ctx.input.pressed[b] do pressed = k
	}
	return pressed
}

// Button `k` of the row of choices, `label`, lit when `on`; whether the
// controller pressed it (`released`: let go of it).
ctl_button :: proc(ctx: ^View_Ctx, k: int, label: cstring, on: bool, full: im.Vec2) -> (pressed, released: bool) {
	t := ui.theme()
	dl := im.GetWindowDrawList()
	o := im.GetWindowPos()
	x0 := o.x + f32(k * CTL_COL) + 4
	y0 := o.y + full.y - CTL_BUTTONS_H
	x1, y1 := x0 + CTL_COL - 8, y0 + CTL_BUTTONS_H - 2
	im.DrawList_AddRectFilled(dl, {x0, y0}, {x1, y1}, ui.col(t.accent if on else t.raised), t.radius)
	ui.text_push(.Label)
	ts := im.CalcTextSize(label)
	im.DrawList_AddText(dl, {(x0 + x1 - ts.x) / 2, (y0 + y1 - ts.y) / 2}, ui.col(t.bg if on else t.text), label)
	ui.text_pop()
	ctx.buttons |= 1 << uint(k)
	if on do ctx.lit |= 1 << uint(k)
	if ctx.input != nil do pressed, released = ctx.input.pressed[k], ctx.input.released[k]
	return
}

// Knob `n` of a tab's list: whether it is on this page, the cursor in its
// column (its encoder's) if so. `total` is how many the list has (its
// pages).
@(private)
ctl_knob :: proc(ctx: ^View_Ctx, n, total: int, label: cstring, plot: im.Vec2) -> bool {
	ctx.pages = max(ctx.pages, (total + 7) / 8)
	if n % 8 == 0 && n / 8 < len(ctx.banks) && ctx.banks[n / 8] == "" {
		name := string(label)
		if i := strings.index(name, "##"); i >= 0 do name = name[:i]
		ctx.banks[n / 8] = strings.clone(name, context.temp_allocator)
	}
	if n / 8 != ctx.a.ctl.page do return false
	col := n % 8
	w := ui.knob_width(label, CTL_KNOB)
	im.SetCursorPos({f32(col * CTL_COL) + (CTL_COL - w) / 2, CTL_PLOT_Y + plot.y + 4})
	ui.knob_input.drawn = col // (its encoder's)
	return true
}

// The tab's pages of knobs (more than one): a strip at the picture's
// bottom right, each page by its first knob's name, the one shown bright
// and underlined, ◀ ▶ either side (lit where there is a page that way):
// the controller's ◀ ▶ step them. No button of the lower row goes on them.
@(private)
ctl_banks :: proc(ctx: ^View_Ctx, full: im.Vec2) {
	a := ctx.a
	n := ctx.pages
	if n <= 1 do return
	a.ctl.page = clamp(a.ctl.page, 0, n - 1)
	ctl_page_strip(ctx, full, n, a.ctl.page)
}

// A page strip (ctl_banks): `n` pages, `cur` shown, named by ctx.banks.
ctl_page_strip :: proc(ctx: ^View_Ctx, full: im.Vec2, n, cur: int) {
	t := ui.theme()
	dl := im.GetWindowDrawList()
	o := im.GetWindowPos()
	plot := ctl_plot(full)
	ui.text_push(.Caption)
	defer ui.text_pop()
	name :: proc(ctx: ^View_Ctx, b: int) -> string {
		return ctx.banks[b] if b < len(ctx.banks) && ctx.banks[b] != "" else fmt.tprintf("Page %d", b + 1)
	}
	gap: f32 = 10
	w: f32 = 0
	for b in 0 ..< n do w += im.CalcTextSize(fmt.ctprintf("%s", name(ctx, b))).x + gap
	aw := im.CalcTextSize("◀").x
	w += 2 * (aw + gap)
	lh := im.GetTextLineHeight()
	x1 := o.x + plot.x - 4
	x := x1 - w
	y := o.y + CTL_PLOT_Y + plot.y - lh - 4
	im.DrawList_AddRectFilled(dl, {x - 6, y - 2}, {x1 + 2, y + lh + 3}, ui.col(ui.with_alpha(VIEW_BG, 0.8)), 4)
	tri :: proc(dl: ^im.DrawList, x, y, h: f32, left, on: bool) {
		t := ui.theme()
		c := ui.col(t.text if on else ui.with_alpha(t.text_dim, 0.4))
		m := y + h / 2
		if left do im.DrawList_AddTriangleFilled(dl, {x + 7, m - 4}, {x + 7, m + 4}, {x + 1, m}, c)
		else do im.DrawList_AddTriangleFilled(dl, {x + 1, m - 4}, {x + 1, m + 4}, {x + 7, m}, c)
	}
	tri(dl, x, y, lh, true, cur > 0)
	x += aw + gap
	for b in 0 ..< n {
		c := fmt.ctprintf("%s", name(ctx, b))
		ts := im.CalcTextSize(c)
		im.DrawList_AddText(dl, {x, y}, ui.col(t.text if b == cur else t.text_dim), c)
		if b == cur do im.DrawList_AddLine(dl, {x, y + lh + 1}, {x + ts.x, y + lh + 1}, ui.col(t.accent), 2)
		x += ts.x + gap
	}
	tri(dl, x, y, lh, false, cur < n - 1)
	ctx.buttons |= 1 << uint(pa.View_Button.Page_Left) | 1 << uint(pa.View_Button.Page_Right)
}

// A choice (an enum: `names`) as a dropdown in knob `n`'s place: its name
// in a box, the list open around it while its encoder is touched; a turn
// steps to the next or the one before. The one chosen (-1: no change),
// and whether its encoder was let go.
@(private)
ctl_choice :: proc(ctx: ^View_Ctx, n, total: int, label: cstring, names: []string, current: int, plot: im.Vec2) -> (chosen: int, ended: bool) {
	chosen = -1
	if len(names) == 0 || !ctl_knob(ctx, n, total, label, plot) do return
	col := n % 8
	ki := ui.knob_input
	cur := clamp(current, 0, len(names) - 1)
	held := false
	if ki != nil {
		held = ki.held[col]
		if steps := ctl_whole(ki.turn[col] / CTL_STEP); steps != 0 {
			ki.turn[col] -= f64(steps) * CTL_STEP
			to := clamp(cur + steps, 0, len(names) - 1)
			if to != cur do chosen = to
			cur = to
		}
		if ki.ended[col] {
			ki.ended[col] = false
			ended = true
		}
	}
	t := ui.theme()
	x0, x1, by, bh, lh := ctl_box(col, label, names[cur], held, plot)
	ly1 := by - 2
	_ = bh
	// Touched: the list open over the picture, around the one chosen.
	if held {
		ui.text_push(.Label)
		defer ui.text_pop()
		fg := im.GetForegroundDrawList()
		rows := min(len(names), 5)
		top := clamp(cur - rows / 2, 0, len(names) - rows)
		rh := lh + 4
		ly0 := ly1 - f32(rows) * rh - 4
		im.DrawList_AddRectFilled(fg, {x0 - 2, ly0}, {x1 + 2, ly1}, ui.col(t.bg), t.radius)
		im.DrawList_AddRect(fg, {x0 - 2, ly0}, {x1 + 2, ly1}, ui.col(t.border), t.radius)
		for k in 0 ..< rows {
			idx := top + k
			ry := ly0 + 2 + f32(k) * rh
			if idx == cur do im.DrawList_AddRectFilled(fg, {x0, ry}, {x1, ry + rh}, ui.col(t.accent), 3)
			nc := fmt.ctprintf("%s", names[idx])
			im.DrawList_PushClipRect(fg, {x0 + 2, ry}, {x1 - 2, ry + rh}, true)
			im.DrawList_AddText(fg, {x0 + 6, ry + 2}, ui.col(t.bg if idx == cur else t.text), nc)
			im.DrawList_PopClipRect(fg)
		}
	}
	im.Dummy({1, 1})
	return
}

// Knob column `col`'s value as a box (`text`) under its `label`, outlined
// while its encoder is touched (`held`). Where it went: its sides, the
// box's top and height, a line's height.
@(private)
ctl_box :: proc(col: int, label: cstring, text: string, held: bool, plot: im.Vec2) -> (x0, x1, by, bh, lh: f32) {
	t := ui.theme()
	dl := im.GetWindowDrawList()
	o := im.GetWindowPos()
	x0 = o.x + f32(col * CTL_COL) + 8
	x1 = x0 + CTL_BAR_W
	y := o.y + CTL_PLOT_Y + plot.y + 4
	ui.text_push(.Label)
	defer ui.text_pop()
	shown := string(label)
	if i := strings.index(shown, "##"); i >= 0 do shown = shown[:i]
	lc := fmt.ctprintf("%s", shown)
	if ctl_shift_now do lc = fmt.ctprintf("%s · fine", shown) // (Shift held: every knob a tenth)
	ls := im.CalcTextSize(lc)
	lh = ls.y
	// As a knob's bar: the name at the left, the choice at the right (▾ after
	// it), a line under them (the accent while touched).
	vc := fmt.ctprintf("%s", text)
	vs := im.CalcTextSize(vc)
	vs.x += 10 // (its ▾)
	im.DrawList_PushClipRect(dl, {x0, y}, {x1 - vs.x - 4, y + lh}, true)
	im.DrawList_AddText(dl, {x0, y}, ui.col(t.accent if ctl_shift_now else t.text if held else t.text_dim), lc)
	im.DrawList_PopClipRect(dl)
	im.DrawList_PushClipRect(dl, {x0 + min(ls.x + 6, CTL_BAR_W / 2), y}, {x1 - 10, y + lh}, true)
	im.DrawList_AddText(dl, {max(x1 - vs.x, x0 + min(ls.x + 6, CTL_BAR_W / 2)), y}, ui.col(t.text), vc)
	im.DrawList_PopClipRect(dl)
	ax, ay := x1 - 4, y + lh / 2
	im.DrawList_AddTriangleFilled(dl, {ax - 4, ay - 2}, {ax + 4, ay - 2}, {ax, ay + 3}, ui.col(t.text_dim))
	by = y + lh + 3
	bh = f32(ui.KNOB_BAR_THICK)
	im.DrawList_AddRectFilled(dl, {x0, by}, {x1, by + bh}, ui.col(t.accent if held else t.raised), 2)
	by = y // (a list opened from it: over the picture, above this)
	return
}

OFF_ON := []string{"Off", "On"}
VOICE_MODE_NAMES := []string{"Poly", "Mono", "Legato"}
OVERSAMPLING_NAMES := []string{"1×", "2×", "4×", "8×"}
TEMPO_NAMES := synth.LFO_TEMPO_NAMES

// A line of words over the picture, at its top left.
@(private)
ctl_caption :: proc(text: string, at: f32 = 8) {
	dl := im.GetWindowDrawList()
	o := im.GetWindowPos()
	t := ui.theme()
	c := fmt.ctprintf("%s", text)
	ts := im.CalcTextSize(c)
	im.DrawList_AddRectFilled(dl, {o.x + at - 4, o.y + CTL_PLOT_Y + 3}, {o.x + at + ts.x + 4, o.y + CTL_PLOT_Y + 5 + ts.y}, ui.col(ui.with_alpha(ui.PLOT_BG, 0.85)), 3)
	im.DrawList_AddText(dl, {o.x + at, o.y + CTL_PLOT_Y + 4}, ui.col(t.text), c)
}

// Words in the picture's place, centred.
@(private)
ctl_message :: proc(text: string, plot: im.Vec2) {
	dl := im.GetWindowDrawList()
	o := im.GetWindowPos()
	t := ui.theme()
	c := fmt.ctprintf("%s", text)
	ts := im.CalcTextSize(c)
	im.DrawList_AddText(dl, {o.x + (plot.x - ts.x) / 2, o.y + CTL_PLOT_Y + (plot.y - ts.y) / 2}, ui.col(t.text_dim), c)
}

// --- the chain ----------------------------------------------------------------------------------

// The devices of the track the panel shows, in the window's order (its
// MIDI page, its instrument, its EQ, its effects).
@(private)
ctl_chain :: proc(a: ^App) -> []Device {
	m := &a.m
	tr := a.detail.track
	out := make([dynamic]Device, context.temp_allocator)
	switch tr.kind {
	case .Pad:
		append(&out, Device{.Midi, 0}, Device{.Instrument, 0}, Device{.Eq, 0})
		ctl_chain_slots(m, &out, {.Pad, tr.index, 0}, pm.PAD_INSERTS)
	case .Bus:
		ctl_chain_slots(m, &out, {.Bus, tr.index, 0}, pm.BUS_SLOTS)
	case .Perf:
		append(&out, Device{.Slot, 0})
	}
	return out[:]
}

// A track's effect slots that hold one, then its first empty one (an
// effect to add: "+ Add" on the chain).
@(private)
ctl_chain_slots :: proc(m: ^pm.Model, out: ^[dynamic]Device, t: pm.Fx_Target, n: int) {
	empty := -1
	for k in 0 ..< n {
		s, ok := pm.target_slot(m, {t.kind, t.index, k})
		if !ok do continue
		if s.kind != .None do append(out, Device{.Slot, k})
		else if empty < 0 do empty = k
	}
	if empty >= 0 do append(out, Device{.Slot, empty})
}

// The device `step` from the one shown in the chain (+1 the next, -1 the
// one before; round; the MIDI page last).
@(private)
ctl_next_of :: proc(a: ^App, step := 1) -> (Device, bool) {
	chain := ctl_chain(a)
	if len(chain) < 2 do return {}, false
	order := make([dynamic]Device, context.temp_allocator)
	for d in chain do if d.kind != .Midi do append(&order, d)
	for d in chain do if d.kind == .Midi do append(&order, d)
	n := len(order)
	for d, k in order do if d == a.detail.device do return order[((k + step) % n + n) % n], true
	return order[0], true
}

// Shows the device `step` along the chain (the window too).
@(private)
ctl_next_device :: proc(a: ^App, step := 1) {
	d, ok := ctl_next_of(a, step)
	if !ok do return
	st := &a.detail
	st.device, st.show = d, 2
	if d.kind == .Slot do a.fx = ctl_device_fx(a, d)
}

// Removes the device shown: an effect; the instrument, the pad cleared (as
// Clear Pad, undoable); a pad's EQ and MIDI page stay.
@(private)
ctl_device_remove :: proc(a: ^App) {
	d := a.detail.device
	if tr := a.detail.track; d.kind == .Instrument && tr.kind == .Pad {
		if !pm.pad_used(&a.m.project, tr.index) do return
		pa.pad_clear(&a.api, i64(tr.index))
		ui.toast(&a.ws.toasts, .Info, fmt.tprintf("Cleared %s", pm.pad_label(tr.index)))
		return
	}
	if d.kind != .Slot || a.detail.track.kind == .Perf {
		ui.toast(&a.ws.toasts, .Warning, "Delete + Device removes an effect or the instrument (its EQ and MIDI stay)")
		return
	}
	fx := ctl_device_fx(a, d)
	if s, ok := pm.target_slot(&a.m, fx); !ok || s.kind == .None do return
	sl, _ := pm.target_slot(&a.m, fx)
	name := pm.slot_name(sl)
	pa.effect_clear(&a.api, slot_ref(fx))
	ui.toast(&a.ws.toasts, .Info, fmt.tprintf("Removed %s", name))
}

// Turns the device shown off or on (an effect; a pad's EQ).
@(private)
ctl_device_toggle :: proc(a: ^App) {
	d := a.detail.device
	#partial switch d.kind {
	case .Slot:
		fx := ctl_device_fx(a, d)
		if fx.kind == .Perf do return
		if s, ok := pm.target_slot(&a.m, fx); ok && s.kind != .None do pa.effect_set_on(&a.api, slot_ref(fx), !s.on)
	case:
		ui.toast(&a.ws.toasts, .Info, "Mute + Device turns an effect off and on")
	}
}

// The effect slot device `d` of the track shown is.
@(private)
ctl_device_fx :: proc(a: ^App, d: Device) -> pm.Fx_Target {
	tr := a.detail.track
	switch tr.kind {
	case .Pad:  return {.Pad, tr.index, d.slot}
	case .Bus:  return {.Bus, tr.index, d.slot}
	case .Perf: return {.Perf, tr.index, 0}
	}
	return {}
}

// A device's name, short.
@(private)
ctl_device_name :: proc(a: ^App, d: Device) -> string {
	m := &a.m
	tr := a.detail.track
	switch d.kind {
	case .Midi:       return "MIDI"
	case .Eq:         return "EQ"
	case .Instrument: return pad_device_name(m.project.pads[tr.index].kind) if tr.kind == .Pad else ""
	case .Slot:
		k := Track_Kind.Pad
		fx := pm.Fx_Target{.Pad, tr.index, d.slot}
		if tr.kind == .Bus do fx = {.Bus, tr.index, d.slot}
		if tr.kind == .Perf do fx = {.Perf, tr.index, 0}
		_ = k
		if s, ok := pm.target_slot(m, fx); ok do return "+ Add" if s.kind == .None else pm.slot_name(s)
	}
	return ""
}

// --- the sampler --------------------------------------------------------------------------------

// The sampler's tabs (Sample, Env, Filter, Pitch, LFO, Global; an audio
// pad's Sample and Global).
@(private)
ctl_sampler :: proc(ctx: ^View_Ctx, i: int, plot, full: im.Vec2) {
	a := ctx.a
	st := &a.detail
	slicer := a.m.project.pads[i].kind == .Slicer
	// The tabs (a slicer's Sample tab is two: Slicer and Slice).
	Ctl_Tab :: struct { tab: Detail_Tab, slice: bool }
	tabs := make([dynamic]Ctl_Tab, context.temp_allocator)
	names := make([dynamic]string, context.temp_allocator)
	if !tab_shown(a, st.tab) do st.tab = .Sample
	if st.tab != .Sample do a.ctl.slice_tab = false
	current := 0
	for tab in Detail_Tab {
		if !tab_shown(a, tab) do continue
		if tab == .Sample && slicer {
			if st.tab == .Sample do current = len(tabs) + (1 if a.ctl.slice_tab else 0)
			append(&tabs, Ctl_Tab{.Sample, false}, Ctl_Tab{.Sample, true})
			append(&names, "Slicer", "Slice")
			continue
		}
		if tab == st.tab do current = len(tabs)
		append(&tabs, Ctl_Tab{tab, false})
		append(&names, DETAIL_NAMES[tab])
	}
	if k := ctl_tabs(ctx, names[:], current); k >= 0 {
		if tabs[k].slice != a.ctl.slice_tab do a.ctl.page = 0
		st.tab, st.show = tabs[k].tab, 2
		a.ctl.slice_tab = tabs[k].slice
		a.ws.bottom_folded = false
	}
	im.SetCursorPos({0, CTL_PLOT_Y})
	pad := a.m.project.pads[i]
	if pad.kind == .Audio {
		if st.tab == .Global do ctl_audio_global(ctx, i, plot, full)
		else do ctl_audio_takes(ctx, i, plot, full)
		return
	}
	switch st.tab {
	case .Sample:
		switch {
		case slicer && a.ctl.slice_tab: ctl_slice(ctx, i, plot, full)
		case slicer:                    ctl_slicer(ctx, i, plot, full)
		case:                           ctl_sample(ctx, i, plot, full)
		}
	case .Env:    ctl_env(ctx, i, plot)
	case .Filter: ctl_filter(ctx, i, plot, full)
	case .Pitch:  ctl_pitch(ctx, i, plot)
	case .Lfo:    ctl_lfo(ctx, i, plot, full)
	case .Global: ctl_global(ctx, i, plot, full)
	}
}

// The Sample tab's knobs: two banks.
SAMPLE_KNOBS :: 20 // (three banks: the region and sound, the fades and loop, Warp)

// Sample: the waveform (its region, the playhead, its sound's spectrum),
// the sample's name over it; start, end, volume, pan, transpose, fine,
// attack and release; how it plays, and Reverse.
@(private)
ctl_sample :: proc(ctx: ^View_Ctx, i: int, plot, full: im.Vec2) {
	a := ctx.a
	m := &a.m
	pad := m.project.pads[i]
	s := pm.pad_sample(m, i)
	if s == nil do return
	w := &a.view_wave
	wave_load(a, w, i)
	start, end := pm.pad_region(m, i)
	t := ui.theme()
	markers := make([dynamic]ui.Marker, context.temp_allocator)
	append(&markers, ui.Marker{frame = start, color = t.ok, label = "S"}, ui.Marker{frame = end, color = t.danger, label = "E"})
	if pad.kind == .Slicer do for k in 1 ..< pad.slicer.count do append(&markers, ui.Marker{frame = pad.slicer.slices[k].start, color = t.warn})
	head, playing := pm.pad_playhead(&m.engine, i)
	spec: []f32
	pm.watch_sound(&m.engine, i)
	if playing do spec = spectrum(a)
	ui.waveform("ctl wave", w.peaks, w.frames, &w.view, markers[:], &w.selection, plot, ui.rgb(pad.color), head if playing else -1, {pyramid = &w.pyramid, backdrop = spec})
	ctl_caption(fmt.tprintf("%s · %.2f s%s", s.name, f64(s.frames) / s.rate, fmt.tprintf(" · %d slices", pad.slicer.count) if pad.kind == .Slicer else ""), 24)
	// Start and end, in seconds.
	secs := f32(f64(s.frames) / s.rate)
	for k in 0 ..< 2 {
		label := cstring("Start") if k == 0 else cstring("End")
		if !ctl_knob(ctx, k, SAMPLE_KNOBS, label, plot) do continue
		v := f32(f64(start if k == 0 else end) / s.rate)
		e := ui.knob(label, &v, 0, secs, 0 if k == 0 else secs, "%.3f s")
		if e.changed {
			f := i64(f64(v) * s.rate)
			p := pad
			if k == 0 do p.start = clamp(f, 0, end - 1)
			else do p.end = clamp(f, start + 1, s.frames)
			pm.set_pad(m, i, .Region, "Move Marker", p) // api-lint: the region (pad_set_region)
		}
		if e.ended do app.seal(&m.history)
	}
	N :: SAMPLE_KNOBS
	pd := pad
	if ctl_knob(ctx, 2, N, "Volume", plot) do knob_f32(a, "Volume", &pd.volume, -48, 12, 0, "%.1f dB", .Volume, "Set Volume")
	if ctl_knob(ctx, 3, N, "Pan", plot) do knob_f32(a, "Pan", &pd.pan, -1, 1, 0, "%+.2f", .Pan, "Set Pan")
	if ctl_knob(ctx, 4, N, "Transpose", plot) do knob_f32(a, "Transpose", &pd.pitch, -24, 24, 0, "%+.0f st", .Pitch, "Set Pitch", snap = 1)
	if ctl_knob(ctx, 5, N, "Fine", plot) do voice_knob(a, "Fine", &a.voice_edit.fine, -100, 100, 0, "%+.0f ct", int(Voice_Key.Fine), "Fine Tune")
	if ctl_knob(ctx, 6, N, "Attack", plot) do knob_f32(a, "Attack", &pd.attack, 0.0005, 10, 0.001, "%.3f s", .Attack, "Set Attack", log_scale = true)
	if ctl_knob(ctx, 7, N, "Release", plot) do knob_f32(a, "Release", &pd.release, 0.005, 20, 0.05, "%.2f s", .Release, "Set Release", log_scale = true)
	// Its second bank: the fades, the loop, its crossfade and mode, the choke group.
	len_s := f32(f64(end - start) / s.rate)
	seconds :: proc(ctx: ^View_Ctx, n: int, label: cstring, frames: i64, hi: f32, rate: f64, plot: im.Vec2) -> (f: i64, changed, ended: bool) {
		if !ctl_knob(ctx, n, SAMPLE_KNOBS, label, plot) do return
		v := f32(f64(frames) / rate)
		e := ui.knob(label, &v, 0, max(hi, 0.001), 0, "%.3f s")
		return i64(f64(v) * rate), e.changed, e.ended
	}
	if f, ch, en := seconds(ctx, 8, "Fade In", pad.fade_in, len_s, s.rate, plot); ch || en {
		p := pad
		p.fade_in = clamp(f, 0, end - start)
		if ch do pm.set_pad(m, i, .Fades, "Fade In", p) // api-lint: as the waveform's fade handle (ui_sample.odin)
		if en do app.seal(&m.history)
	}
	if f, ch, en := seconds(ctx, 9, "Fade Out", pad.fade_out, len_s, s.rate, plot); ch || en {
		p := pad
		p.fade_out = clamp(f, 0, end - start)
		if ch do pm.set_pad(m, i, .Fades, "Fade Out", p) // api-lint: as the waveform's fade handle
		if en do app.seal(&m.history)
	}
	ls := pad.loop_start if pad.loop_end > 0 else start
	le := pad.loop_end if pad.loop_end > 0 else end
	if f, ch, en := seconds(ctx, 10, "Loop Start", ls, secs, s.rate, plot); ch || en {
		p := pad
		p.loop_start, p.loop_end = clamp(f, start, le - 2), le
		if ch do pm.set_pad(m, i, .Loop, "Move Loop", p) // api-lint: as the waveform's loop marker
		if en do app.seal(&m.history)
	}
	if f, ch, en := seconds(ctx, 11, "Loop End", le, secs, s.rate, plot); ch || en {
		p := pad
		p.loop_start, p.loop_end = ls, clamp(f, ls + 2, end)
		if ch do pm.set_pad(m, i, .Loop, "Move Loop", p) // api-lint: as the waveform's loop marker
		if en do app.seal(&m.history)
	}
	if f, ch, en := seconds(ctx, 12, "Crossfade", pad.crossfade, f32(f64(le - ls) / s.rate) / 2, s.rate, plot); ch || en {
		p := pad
		p.crossfade = clamp(f, 0, (le - ls) / 2)
		if ch do pm.set_pad(m, i, .Crossfade, "Loop Crossfade", p) // api-lint: as the sample bar's loop settings
		if en do app.seal(&m.history)
	}
	if k, _ := ctl_choice(ctx, 13, N, "Loop Mode", {"Forward", "Ping-pong"}, int(pad.loop_mode), plot); k >= 0 {
		p := pad
		p.loop_mode = sampler.Loop_Mode(k)
		pm.set_pad(m, i, .Loop_Mode, "Loop Mode", p) // api-lint: as the sample bar's loop settings
		app.seal(&m.history)
	}
	chokes := []string{"No choke", "Choke 1", "Choke 2", "Choke 3", "Choke 4", "Choke 5", "Choke 6"}
	if k, _ := ctl_choice(ctx, 14, N, "Choke", chokes, int(pad.choke), plot); k >= 0 do pa.pad_set_choke(&a.api, i64(i), i64(k))
	ctl_warp(ctx, i, 16, N, plot)
	if pad.kind == .Slicer do return
	modes := [4]cstring{"One-shot", "Gate", "Loop", "Hold"}
	for name, k in modes {
		if p, _ := ctl_button(ctx, k, name, int(pad.mode) == k, full); p do pa.pad_set_mode(&a.api, i64(i), pa.Pad_Mode(k))
	}
	if p, _ := ctl_button(ctx, 4, "Reverse", pad.reverse, full); p {
		np := pad
		np.reverse = !pad.reverse
		pm.set_pad(m, i, .Reverse, "Reverse", np)
		app.seal(&m.history)
	}
}

// Env: the amp envelope (the newest note's level on it); attack, decay,
// sustain, release.
@(private)
ctl_env :: proc(ctx: ^View_Ctx, i: int, plot: im.Vec2) {
	a := ctx.a
	pad := a.m.project.pads[i]
	live, secs := live_of(a)
	adsr := [4]f32{pad.attack, pad.voice.decay, pad.voice.sustain, pad.release}
	ui.adsr_plot("ctl amp env", &adsr, plot, ui.rgb(pad.color), f32(live.amp) if live.sounding else -1, secs)
	pd := pad
	if ctl_knob(ctx, 0, 4, "Attack", plot) do knob_f32(a, "Attack", &pd.attack, 0.0005, 10, 0.001, "%.3f s", .Attack, "Set Attack", log_scale = true)
	if ctl_knob(ctx, 1, 4, "Decay", plot) do voice_knob(a, "Decay", &a.voice_edit.decay, 0.005, 10, 1, "%.2f s", int(Voice_Key.Amp_Adsr), "Set Decay", true)
	if ctl_knob(ctx, 2, 4, "Sustain", plot) do voice_knob(a, "Sustain", &a.voice_edit.sustain, 0, 1, 1, "%.2f", int(Voice_Key.Amp_Adsr) + 1, "Set Sustain")
	if ctl_knob(ctx, 3, 4, "Release", plot) do knob_f32(a, "Release", &pd.release, 0.005, 20, 0.05, "%.2f s", .Release, "Set Release", log_scale = true)
}

// Filter: its response (what plays bright over the setting) and its
// envelope; cutoff, resonance, envelope depth, velocity, the envelope's
// A D S R (then key tracking: Page >); its type and slope.
@(private)
ctl_filter :: proc(ctx: ^View_Ctx, i: int, plot, full: im.Vec2) {
	a := ctx.a
	m := &a.m
	pad := m.project.pads[i]
	v := pad.voice
	live, secs := live_of(a)
	sr := a.host.graph.settings.sample_rate if a.host.graph.settings.sample_rate > 0 else 48_000
	color := ui.rgb(pad.color)
	curves := make([dynamic]ui.Plot_Curve, context.temp_allocator)
	dim := ui.mix(ui.PLOT_BG, color, 0.55)
	setting := response_db(v.filter, v.steep, f64(v.cutoff), f64(v.resonance), sr)
	if v.filter == .Off {
		append(&curves, ui.Plot_Curve{db = setting, color = dim, width = 1.5})
	} else if live.sounding || abs(live.cutoff - f64(v.cutoff)) > 0.5 {
		append(&curves, ui.Plot_Curve{db = setting, color = dim, width = 1.5})
		append(&curves, ui.Plot_Curve{db = response_db(v.filter, v.steep, live.cutoff, live.resonance, sr), color = color, fill = true, width = 2.5})
	} else {
		append(&curves, ui.Plot_Curve{db = setting, color = color, fill = true, width = 2.5})
	}
	resp_w := f32(4 * CTL_COL) - 6
	handle := [2]f32{ui.freq_x(v.cutoff), v.resonance * 24}
	ui.response_plot("ctl filter", curves[:], &handle, {resp_w, plot.y})
	im.SameLine(0, 6)
	fa := v.filter_adsr
	sign, env_c := env_depth(v.filter_env, color)
	ui.adsr_plot("ctl filter env", &fa, {plot.x - resp_w - 6, plot.y}, env_c, f32(live.filter_env) if live.sounding else -1, secs, sign)
	N :: 10
	if ctl_knob(ctx, 0, N, "Cutoff", plot) do voice_knob(a, "Cutoff", &a.voice_edit.cutoff, 20, 20_000, 20_000, "%.0f Hz", int(Voice_Key.Cutoff), "Set Cutoff", true)
	if ctl_knob(ctx, 1, N, "Resonance", plot) do voice_knob(a, "Resonance", &a.voice_edit.resonance, 0, 1, 0, "%.2f", int(Voice_Key.Resonance), "Set Resonance")
	if ctl_knob(ctx, 2, N, "Env", plot) do voice_knob(a, "Env", &a.voice_edit.filter_env, -1, 1, 0, "%+.2f", int(Voice_Key.Filter_Env), "Set Filter Envelope")
	if ctl_knob(ctx, 3, N, "Velocity", plot) do voice_knob(a, "Velocity", &a.voice_edit.vel_cutoff, -1, 1, 0, "%+.2f", int(Voice_Key.Vel_Cutoff), "Set Filter Velocity")
	ctl_adsr(ctx, &a.voice_edit.filter_adsr, int(Voice_Key.Filter_Adsr), "Filter", 4, N, plot)
	if ctl_knob(ctx, 8, N, "Key", plot) do voice_knob(a, "Key", &a.voice_edit.key_track, 0, 1, 0, "%.2f", int(Voice_Key.Key_Track), "Set Key Tracking")
	if k, _ := ctl_choice(ctx, 9, N, "Slope", {"12 dB", "24 dB"}, 1 if v.steep else 0, plot); k >= 0 {
		nv := v
		nv.steep = k == 1
		put_voice(a, .Slope, "Filter Slope", nv)
	}
	for type, k in sampler.Voice_Filter {
		if p, _ := ctl_button(ctx, k, FILTER_NAMES[type], v.filter == type, full); p {
			nv := v
			nv.filter = type
			put_voice(a, .Filter, "Filter Type", nv)
		}
	}
}

// An envelope's A D S R knobs, knobs `from` to `from + 3` of `total`.
@(private)
ctl_adsr :: proc(ctx: ^View_Ctx, adsr: ^[4]f32, key: int, what: string, from, total: int, plot: im.Vec2) {
	a := ctx.a
	if ctl_knob(ctx, from, total, "A", plot) do voice_knob(a, "A", &adsr[0], 0.0005, 10, 0.001, "%.3f s", key, fmt.tprintf("Set %s Attack", what), true)
	if ctl_knob(ctx, from + 1, total, "D", plot) do voice_knob(a, "D", &adsr[1], 0.005, 10, 0.5, "%.2f s", key, fmt.tprintf("Set %s Decay", what), true)
	if ctl_knob(ctx, from + 2, total, "S", plot) do voice_knob(a, "S", &adsr[2], 0, 1, 0, "%.2f", key, fmt.tprintf("Set %s Sustain", what))
	if ctl_knob(ctx, from + 3, total, "R", plot) do voice_knob(a, "R", &adsr[3], 0.005, 20, 0.2, "%.2f s", key, fmt.tprintf("Set %s Release", what), true)
}

// Pitch: its envelope and what it does to the newest note now; amount,
// velocity, key tracking, the envelope's A D S R.
@(private)
ctl_pitch :: proc(ctx: ^View_Ctx, i: int, plot: im.Vec2) {
	a := ctx.a
	pad := a.m.project.pads[i]
	v := pad.voice
	live, secs := live_of(a)
	color := ui.rgb(pad.color)
	readout_w: f32 = CTL_COL - 6
	pa_ := v.pitch_adsr
	sign, env_c := env_depth(v.pitch_env / 12, color)
	ui.adsr_plot("ctl pitch env", &pa_, {plot.x - readout_w - 6, plot.y}, env_c, f32(live.pitch_env) if live.sounding else -1, secs, sign)
	im.SameLine(0, 6)
	pos := im.GetCursorScreenPos()
	dl := im.GetWindowDrawList()
	t := ui.theme()
	im.DrawList_AddRectFilled(dl, pos, {pos.x + readout_w, pos.y + plot.y}, ui.col(ui.PLOT_BG), t.radius)
	now := f64(v.pitch_env) * live.pitch_env if live.sounding else 0
	im.PushFontFloat(a.platform.fonts.semibold, 20)
	txt := fmt.ctprintf("%+.1f", now + f64(pad.pitch) + f64(v.fine) / 100)
	ts := im.CalcTextSize(txt)
	im.DrawList_AddText(dl, {pos.x + (readout_w - ts.x) / 2, pos.y + plot.y / 2 - ts.y + 2}, ui.col(color if live.sounding else t.text_dim), txt)
	im.PopFont()
	sub := cstring("semitones")
	ss := im.CalcTextSize(sub)
	im.DrawList_AddText(dl, {pos.x + (readout_w - ss.x) / 2, pos.y + plot.y / 2 + 2}, ui.col(t.text_dim), sub)
	N :: 7
	if ctl_knob(ctx, 0, N, "Amount", plot) do voice_knob(a, "Amount", &a.voice_edit.pitch_env, -48, 48, 0, "%+.1f st", int(Voice_Key.Pitch_Env), "Set Pitch Envelope")
	if ctl_knob(ctx, 1, N, "Velocity", plot) do voice_knob(a, "Velocity", &a.voice_edit.vel_pitch, -24, 24, 0, "%+.1f st", int(Voice_Key.Vel_Pitch), "Set Pitch Velocity")
	if ctl_knob(ctx, 2, N, "Key", plot) do voice_knob(a, "Key", &a.voice_edit.pitch_track, 0, 1, 1, "%.2f", int(Voice_Key.Pitch_Track), "Set Pitch Key Tracking")
	ctl_adsr(ctx, &a.voice_edit.pitch_adsr, int(Voice_Key.Pitch_Adsr), "Pitch", 3, N, plot)
}

// LFO: one LFO a page (Page < and >: the other), its trace over its shape;
// its rate, fade-in, phase and its routes' amounts (each named where it
// goes); its shape, and how it runs.
@(private)
ctl_lfo :: proc(ctx: ^View_Ctx, i: int, plot, full: im.Vec2) {
	a := ctx.a
	m := &a.m
	pad := m.project.pads[i]
	v := pad.voice
	ctx.pages = sampler.LFOS
	for j in 0 ..< sampler.LFOS do ctx.banks[j] = fmt.tprintf("LFO %d", j + 1)
	k := clamp(a.ctl.page, 0, sampler.LFOS - 1)
	l := v.lfos[k]
	live, _ := live_of(a)
	st := &a.device
	if st.trace_pad != i do st^ = {trace_pad = i}
	if a.detail.tab != .Lfo || a.ws.bottom_folded { // (the tab's own moves it while it shows)
		for j in 0 ..< sampler.LFOS do st.trace[j][st.trace_head] = f32(live.lfo[j])
		st.trace_head = (st.trace_head + 1) % TRACE_LEN
	}
	colors := [2]ui.Color{ui.rgb(pad.color), ui.rgb(0xf5a623)}
	ui.trace_plot(fmt.ctprintf("ctl lfo %d", k), st.trace[k][:], st.trace_head, shape_points(l.shape, 64), plot, colors[k])
	ctl_caption(fmt.tprintf("LFO %d", k + 1))
	lk := &a.voice_edit.lfos[k]
	key := int(Voice_Key.Lfo) + k * 10
	place :: proc(ctx: ^View_Ctx, col: int, label: cstring, plot: im.Vec2) {
		w := ui.knob_width(label, CTL_KNOB)
		im.SetCursorPos({f32(col * CTL_COL) + (CTL_COL - w) / 2, CTL_PLOT_Y + plot.y + 4})
		ui.knob_input.drawn = col
	}
	place(ctx, 0, "Rate", plot)
	if l.mode == .Sync {
		x := f32(l.sync)
		e := ui.knob("Rate", &x, 0, f32(len(sampler.LFO_SYNC_NAMES) - 1), 4, "%.0f", shown_value = fmt.ctprintf("%s", sampler.LFO_SYNC_NAMES[l.sync]), step = 1)
		if e.changed {
			nv := v
			nv.lfos[k].sync = u8(x)
			put_voice(a, Voice_Key(key + 2), "LFO Rate", nv)
		}
	} else {
		voice_knob(a, "Rate", &lk.rate, 0.01, 40, 2, "%.2f Hz", key + 2, "LFO Rate", true)
	}
	place(ctx, 1, "Fade in", plot)
	voice_knob(a, "Fade in", &lk.fade, 0, 10, 0, "%.2f s", key + 3, "LFO Fade In")
	place(ctx, 2, "Phase", plot)
	voice_knob(a, "Phase", &lk.phase, 0, 360, 0, "%.0f°", key + 4, "LFO Phase")
	for r in k * 3 ..< k * 3 + 3 {
		route := v.routes[r]
		label := fmt.ctprintf("%s##route%d", MOD_DEST_NAMES[route.dest] if route.dest != .None else "Route", r)
		place(ctx, 3 + r - k * 3, label, plot)
		amt := route.amount * 100
		e := ui.knob(label, &amt, -100, 100, 0, "%+.0f%%")
		if e.changed && route.dest != .None {
			nv := v
			nv.routes[r].amount = amt / 100
			pm.set_voice(m, i, int(Voice_Key.Route) + r * 10 + 1, "Route Amount", nv) // api-lint: as the LFO tab (ui_device.odin)
		}
		if e.ended do app.seal(&m.history)
	}
	shapes := [sampler.Lfo_Shape]cstring{.Sine = "Sine", .Triangle = "Triangle", .Saw_Up = "Saw Up", .Saw_Down = "Saw Down", .Square = "Square", .Sample_Hold = "S & H"}
	for shape, j in sampler.Lfo_Shape {
		if p, _ := ctl_button(ctx, j, shapes[shape], l.shape == shape, full); p {
			nv := v
			nv.lfos[k].shape = shape
			put_voice(a, Voice_Key(key), "LFO Shape", nv)
		}
	}
	if j, _ := ctl_choice(ctx, k * 8 + 6, sampler.LFOS * 8, "Mode", {"Auto", "Trigger", "Sync"}, int(l.mode), plot); j >= 0 {
		nv := v
		nv.lfos[k].mode = sampler.Lfo_Mode(j)
		put_voice(a, Voice_Key(key + 1), "LFO Mode", nv)
	}
}

// Global: the pad (its name, its sample); volume, pan, transpose, fine,
// voices and (mono) glide; poly, mono or legato; Clear Pad.
@(private)
ctl_global :: proc(ctx: ^View_Ctx, i: int, plot, full: im.Vec2) {
	a := ctx.a
	m := &a.m
	pad := m.project.pads[i]
	ctl_pad_card(a, i, plot)
	pd := pad
	if ctl_knob(ctx, 0, 6, "Volume", plot) do knob_f32(a, "Volume", &pd.volume, -48, 12, 0, "%.1f dB", .Volume, "Set Volume")
	if ctl_knob(ctx, 1, 6, "Pan", plot) do knob_f32(a, "Pan", &pd.pan, -1, 1, 0, "%+.2f", .Pan, "Set Pan")
	if ctl_knob(ctx, 2, 6, "Transpose", plot) do knob_f32(a, "Transpose", &pd.pitch, -24, 24, 0, "%+.0f st", .Pitch, "Set Pitch", snap = 1)
	if ctl_knob(ctx, 3, 6, "Fine", plot) do voice_knob(a, "Fine", &a.voice_edit.fine, -100, 100, 0, "%+.0f ct", int(Voice_Key.Fine), "Fine Tune")
	if ctl_knob(ctx, 4, 6, "Voices", plot) {
		voices := f32(pad.voice.voices)
		if e := ui.knob("Voices", &voices, 1, 32, 8, "%.0f", step = 1); e.changed {
			nv := pad.voice
			nv.voices = int(voices)
			pm.set_voice(m, i, int(Voice_Key.Voices), "Set Voices", nv) // api-lint: as the Global tab (ui_device.odin)
		} else if e.ended do app.seal(&m.history)
	}
	if pad.kind != .Slicer && pad.voice.mode != .Poly && ctl_knob(ctx, 5, 6, "Glide", plot) {
		voice_knob(a, "Glide", &a.voice_edit.glide, 0, 2, 0, "%.3f s", int(Voice_Key.Glide), "Set Glide")
	}
	if pad.kind != .Slicer {
		modes := [3]cstring{"Poly", "Mono", "Legato"}
		for name, k in modes {
			if p, _ := ctl_button(ctx, k, name, int(pad.voice.mode) == k, full); p {
				nv := pad.voice
				nv.mode = sampler.Voice_Mode(k)
				put_voice(a, .Voice_Mode, "Voice Mode", nv)
			}
		}
	}
}

// The pad's card over the picture: its letter and name, its sample.
@(private)
ctl_pad_card :: proc(a: ^App, i: int, plot: im.Vec2) {
	m := &a.m
	pad := m.project.pads[i]
	t := ui.theme()
	dl := im.GetWindowDrawList()
	o := im.GetWindowPos()
	y := o.y + CTL_PLOT_Y
	im.DrawList_AddRectFilled(dl, {o.x, y}, {o.x + plot.x, y + plot.y}, ui.col(ui.PLOT_BG), t.radius)
	im.PushFontFloat(a.platform.fonts.bold, 22)
	im.DrawList_AddText(dl, {o.x + 12, y + 4}, ui.col(ui.rgb(pad.color)), fmt.ctprintf("%s  %s", pm.pad_label(i), pm.pad_name(&m.project.pads[i])))
	im.PopFont()
	if s := pm.pad_sample(m, i); s != nil {
		im.DrawList_AddText(dl, {o.x + 12, y + plot.y - 20}, ui.col(t.text_dim), fmt.ctprintf("%s · %.2f s · %.0f Hz · %s", s.name, f64(s.frames) / s.rate, s.rate, "stereo" if s.channels > 1 else "mono"))
	} else {
		im.DrawList_AddText(dl, {o.x + 12, y + plot.y - 20}, ui.col(t.text_dim), fmt.ctprintf("%s", pad_device_name(pad.kind)))
	}
}


// An audio pad's takes: the current sequence's, its playhead; volume and
// pan; armed, and how it monitors.
@(private)
ctl_audio_takes :: proc(ctx: ^View_Ctx, i: int, plot, full: im.Vec2) {
	a := ctx.a
	m := &a.m
	pad := m.project.pads[i]
	ctl_pad_card(a, i, plot)
	ctl_caption("Takes: record them with the pad armed", 300)
	pd := pad
	if ctl_knob(ctx, 0, 2, "Volume", plot) do knob_f32(a, "Volume", &pd.volume, -48, 12, 0, "%.1f dB", .Volume, "Set Volume")
	if ctl_knob(ctx, 1, 2, "Pan", plot) do knob_f32(a, "Pan", &pd.pan, -1, 1, 0, "%+.2f", .Pan, "Set Pan")
	ctl_audio_buttons(ctx, i, full)
}

// An audio pad's Global tab: its card; volume and pan; armed, monitoring.
@(private)
ctl_audio_global :: proc(ctx: ^View_Ctx, i: int, plot, full: im.Vec2) {
	ctl_audio_takes(ctx, i, plot, full)
}

@(private)
ctl_audio_buttons :: proc(ctx: ^View_Ctx, i: int, full: im.Vec2) {
	a := ctx.a
	st, _ := pa.pad_state(&a.api, i64(i))
	if p, _ := ctl_button(ctx, 0, ui.ICON_CIRCLE + "  Arm", st.armed, full); p do pa.pad_set_armed(&a.api, i64(i), !st.armed)
	names := [3]cstring{"Monitor Auto", "Monitor In", "Monitor Off"}
	for name, k in names {
		if p, _ := ctl_button(ctx, 2 + k, name, int(st.monitor) == k, full); p do pa.pad_set_monitor(&a.api, i64(i), pa.Monitor(k))
	}
}

// A frozen pad: what it is, and the way back (or on).
@(private)
ctl_frozen :: proc(ctx: ^View_Ctx, i: int, full: im.Vec2) {
	a := ctx.a
	plot := ctl_plot(full)
	ctl_tabs(ctx, {"Frozen"}, 0)
	ctl_pad_card(a, i, plot)
	ctl_message(fmt.tprintf("%s plays its renderings: unfreeze it to edit its sound", pm.pad_label(i)), plot)
	if p, _ := ctl_button(ctx, 0, ui.ICON_SNOWFLAKE + "  Unfreeze", false, full); p do pa.export_unfreeze(&a.api, i64(i))
	if p, _ := ctl_button(ctx, 1, "Flatten", false, full); p do pa.export_flatten(&a.api, i64(i))
}

// An empty pad: what to put on it, as its Sample tab offers (Browse, hold
// to record a sample into it, an audio track, a synth, a slicer).
@(private)
ctl_empty_pad :: proc(ctx: ^View_Ctx, i: int, full: im.Vec2) {
	a := ctx.a
	t := ui.theme()
	dl := im.GetWindowDrawList()
	o := im.GetWindowPos()
	ctl_tabs(ctx, {"Empty"}, 0)
	im.PushFontFloat(a.platform.fonts.bold, 24)
	im.DrawList_AddText(dl, {o.x + 16, o.y + 36}, ui.col(t.text), fmt.ctprintf("%s is empty", pm.pad_label(i)))
	im.PopFont()
	im.DrawList_AddText(dl, {o.x + 16, o.y + 72}, ui.col(t.text_dim), "Drop a sound on it in Pads, or start one with the buttons below. Hold Record to sample into it.")
	recording := a.rec.active && a.rec.pad == i
	if p, _ := ctl_button(ctx, 0, ui.ICON_FOLDER_OPEN + "  Browse", false, full); p do library_show(a, 0)
	if p, r := ctl_button(ctx, 1, ui.ICON_CIRCLE + "  Record", recording, full); p {
		pa.recording_sample_start(&a.api, i64(i), .Hold)
	} else if r && recording {
		pa.recording_sample_stop(&a.api)
	}
	if p, _ := ctl_button(ctx, 2, ui.ICON_MIC + "  Audio", false, full); p do put_device(a, i, "inst audio")
	if p, _ := ctl_button(ctx, 3, ui.ICON_AUDIO_WAVEFORM + "  Synth", false, full); p do put_device(a, i, "inst synth")
	if p, _ := ctl_button(ctx, 4, ui.ICON_SCISSORS + "  Slicer", false, full); p do put_device(a, i, "inst slicer")
}

// --- the EQ and MIDI ----------------------------------------------------------------------------

// The pad's EQ: its three bands, on or off.
@(private)
ctl_eq :: proc(ctx: ^View_Ctx, i: int, plot, full: im.Vec2) {
	a := ctx.a
	pad := a.m.project.pads[i]
	{
		panel := Fx_Panel{ctx = ctx, where_ = .Pad_Eq, pad = i, plot = plot, full = full}
		if fx_panel(&panel) do return // (ui_ctl_fx_tone.odin)
	}
	ctl_tabs(ctx, {"EQ"}, 0)
	im.SetCursorPos({0, CTL_PLOT_Y})
	// Its shape: the three bands' gains, low to high.
	curve := make([]f32, 160, context.temp_allocator)
	for &v, k in curve {
		x := f32(k) / 159
		lo := pad.eq[0] * (1 - smooth(x, 0.15, 0.45))
		hi := pad.eq[2] * smooth(x, 0.55, 0.85)
		mid := pad.eq[1] * (1 - abs(x - 0.5) * 2.2) if abs(x - 0.5) < 0.45 else 0
		v = (lo + mid + hi) if pad.eq_on else 0
	}
	color := ui.rgb(pad.color) if pad.eq_on else ui.mix(ui.PLOT_BG, ui.rgb(pad.color), 0.4)
	ui.response_plot("ctl eq", {{db = curve, color = color, fill = true, width = 2.5}}, nil, plot)
	pd := pad
	if ctl_knob(ctx, 0, 3, "Low", plot) do knob_f32(a, "Low", &pd.eq[0], -15, 15, 0, "%+.1f dB", .Eq_Low, "Set EQ Low")
	if ctl_knob(ctx, 1, 3, "Mid", plot) do knob_f32(a, "Mid", &pd.eq[1], -15, 15, 0, "%+.1f dB", .Eq_Mid, "Set EQ Mid")
	if ctl_knob(ctx, 2, 3, "High", plot) do knob_f32(a, "High", &pd.eq[2], -15, 15, 0, "%+.1f dB", .Eq_High, "Set EQ High")
	if p, _ := ctl_button(ctx, 0, "EQ On", pad.eq_on, full); p {
		np := pad
		np.eq_on = !pad.eq_on
		pm.set_pad(&a.m, i, .Eq_Low, "EQ On" if np.eq_on else "EQ Off", np)
		app.seal(&a.m.history)
	}
}

@(private)
smooth :: proc(x, a, b: f32) -> f32 {
	t := clamp((x - a) / (b - a), 0, 1)
	return t * t * (3 - 2 * t)
}

// The pad's MIDI effects: note repeat and the arpeggiator.
@(private)
ctl_midi :: proc(ctx: ^View_Ctx, i: int, plot, full: im.Vec2) {
	a := ctx.a
	{
		panel := Fx_Panel{ctx = ctx, where_ = .Midi, pad = i, plot = plot, full = full}
		if fx_panel(&panel) do return // (ui_ctl_fx_midi_plugin.odin)
	}
	ctl_tabs(ctx, {"MIDI"}, 0)
	fx, _ := pa.sequence_midi_fx(&a.api, i64(i))
	ctl_message(fmt.tprintf("Note repeat %s · Arpeggiator %s", "on" if fx.repeat else "off", "on" if fx.arp else "off"), plot)
	set :: proc(a: ^App, i: int, fx: pa.Midi_Fx) { pa.sequence_set_midi_fx(&a.api, i64(i), fx) }
	grids := [6]cstring{"1/4", "1/8", "1/8T", "1/16", "1/16T", "1/32"}
	stepped :: proc(ctx: ^View_Ctx, col: int, label: cstring, v: ^f32, hi: f32, shown: cstring, plot: im.Vec2) -> bool {
		if !ctl_knob(ctx, col, 6, label, plot) do return false
		return ui.knob(label, v, 0, hi, 0, "%.0f", shown_value = shown, step = 1).changed
	}
	r := f32(fx.repeat_rate)
	if stepped(ctx, 0, "Repeat Rate", &r, 5, grids[clamp(int(fx.repeat_rate), 0, 5)], plot) {
		fx.repeat_rate = pa.Grid(r)
		set(a, i, fx)
	}
	if ctl_knob(ctx, 1, 6, "Repeat Gate", plot) {
		g := fx.repeat_gate
		if e := ui.knob("Repeat Gate", &g, 0.05, 1, 0.5, "%.2f"); e.changed {
			fx.repeat_gate = g
			set(a, i, fx)
		}
	}
	modes := [5]cstring{"Up", "Down", "Up & Down", "Random", "As played"}
	am := f32(fx.arp_mode)
	if stepped(ctx, 2, "Arp Mode", &am, 4, modes[clamp(int(fx.arp_mode), 0, 4)], plot) {
		fx.arp_mode = pa.Arp_Mode(am)
		set(a, i, fx)
	}
	ar := f32(fx.arp_rate)
	if stepped(ctx, 3, "Arp Rate", &ar, 5, grids[clamp(int(fx.arp_rate), 0, 5)], plot) {
		fx.arp_rate = pa.Grid(ar)
		set(a, i, fx)
	}
	oc := f32(fx.arp_octaves - 1)
	if stepped(ctx, 4, "Octaves", &oc, 3, fmt.ctprintf("%d", fx.arp_octaves), plot) {
		fx.arp_octaves = i64(oc) + 1
		set(a, i, fx)
	}
	if ctl_knob(ctx, 5, 6, "Arp Gate", plot) {
		g := fx.arp_gate
		if e := ui.knob("Arp Gate", &g, 0.05, 1, 0.5, "%.2f"); e.changed {
			fx.arp_gate = g
			set(a, i, fx)
		}
	}
	if p, _ := ctl_button(ctx, 0, "Repeat", fx.repeat, full); p {
		fx.repeat = !fx.repeat
		set(a, i, fx)
	}
	if p, _ := ctl_button(ctx, 2, "Arpeggiator", fx.arp, full); p {
		fx.arp = !fx.arp
		set(a, i, fx)
	}
	if p, _ := ctl_button(ctx, 3, "Latch", fx.arp_latch, full); p {
		fx.arp_latch = !fx.arp_latch
		set(a, i, fx)
	}
}

// --- effects and plug-ins -----------------------------------------------------------------------

// An effect slot: its picture and every setting, a knob each (an on/off
// or stepped one a dropdown; eight a bank, the banks on the lower row), On,
// its editor (a plug-in's), Remove; an empty one: which effect to put in
// it (the first encoder's dropdown), and Add.
@(private)
ctl_effect :: proc(ctx: ^View_Ctx, t: pm.Fx_Target, plot, full: im.Vec2) {
	a := ctx.a
	m := &a.m
	s, ok := pm.target_slot(m, t)
	if !ok do return
	if s.kind == .None {
		ctl_tabs(ctx, {"Add an Effect"}, 0)
		kinds := make([dynamic]pm.Effect_Kind, context.temp_allocator)
		names := make([dynamic]string, context.temp_allocator)
		for k in pm.Effect_Kind do if k != .None && k != .Plugin && !pm.effect_kind_legacy(k) {
			append(&kinds, k)
			append(&names, string(pm.EFFECT_NAMES[k]))
		}
		a.ctl.add = clamp(a.ctl.add, 0, len(kinds) - 1)
		ctl_message("Choose the effect with the first encoder, then Add", plot)
		if k, _ := ctl_choice(ctx, 0, 1, "Effect", names[:], a.ctl.add, plot); k >= 0 do a.ctl.add = k
		if p, _ := ctl_button(ctx, 0, ui.ICON_PLUS + "  Add", false, full); p {
			pa.effect_set(&a.api, slot_ref(t), i64(kinds[a.ctl.add]))
			show_device(a, t)
		}
		return
	}
	a.fx = t
	pm.watch_slot(&m.engine, t)
	if s.kind == .Pro_Eq || s.kind == .Pro_Comp || s.kind == .Proverb { // (its bands, or its views, on the upper row in place of the tabs)
		#partial switch s.kind {
		case .Pro_Eq:   ctl_pro_eq(ctx, t, s, plot, full)
		case .Pro_Comp: ctl_pro_comp(ctx, t, s, plot, full)
		case .Proverb:  ctl_pro_verb(ctx, t, s, plot, full)
		}
		return // (On: Mute + Device; Remove: Delete + Device)
	}
	ctl_tabs(ctx, {fmt.tprintf("%s%s", pm.slot_name(s), "" if s.on || t.kind == .Perf else " (off)")}, 0)
	im.SetCursorPos({0, CTL_PLOT_Y})
	if s.kind == .Super_Filter || s.kind == .Pro_Saturator {
		if s.kind == .Super_Filter do ctl_super_filter(ctx, t, s, plot, full)
		else do ctl_pro_saturator(ctx, t, s, plot, full)
		return // (On: Mute + Device; Remove: Delete + Device)
	}
	twin_e, twin := pm.synth_twin(s.kind)
	{
		panel := Fx_Panel{ctx = ctx, where_ = .Slot, kind = s.kind, t = t, s = s, effect = twin_e, twin = twin, plot = plot, full = full, lead = 1 if t.kind == .Perf else 0}
		if f := pm.target_node(&m.engine, t); f != nil do panel.plugin = f.plugin
		if fx_panel(&panel) do return // (its family's own: ui_ctl_fx_*.odin)
	}
	if !twin do draw_effect_view(a, t, s, plot)
	else do ctl_message(fmt.tprintf("%s%s", pm.slot_name(s), "" if s.on else " (off)"), plot)
	knobs := make([dynamic]Ctl_Param, context.temp_allocator)
	if t.kind == .Perf do append(&knobs, Ctl_Param{intensity = true})
	if twin {
		for id in synth_effect_ids(twin_e) do append(&knobs, Ctl_Param{synth = id})
	} else {
		for p in shown_params(s, pm.target_params(&m.engine, t)) do append(&knobs, Ctl_Param{info = p, is = true})
	}
	plugin: ^clap.Plugin
	if f := pm.target_node(&m.engine, t); f != nil do plugin = f.plugin
	if twin {
		a.param_host = {slot = true, t = t}
		defer a.param_host = {}
		ctl_params(ctx, t, s, plugin, knobs[:], twin_e, plot)
	} else {
		ctl_params(ctx, t, s, plugin, knobs[:], {}, plot)
	}
	if s.kind == .Plugin && plugin != nil do ctl_editor_button(ctx, 0, t, plugin, full) // (On: Mute + Device; Remove: Delete + Device)
}

// A knob of an effect's or a plug-in's: a parameter (`is`), a synth effect's
// (`synth`), or a performance effect's intensity.
@(private)
Ctl_Param :: struct {
	info:      fc.Param_Info,
	is:        bool,
	synth:     fc.Param_Id,
	intensity: bool,
}

// An effect's or plug-in's knobs, eight a bank: a stepped parameter a
// dropdown (Off and On, or its steps; a synth effect's choices by name).
@(private)
ctl_params :: proc(ctx: ^View_Ctx, t: pm.Fx_Target, s: pm.Effect_Slot, plugin: ^clap.Plugin, knobs: []Ctl_Param, e: fx.Effect, plot: im.Vec2) {
	a := ctx.a
	m := &a.m
	for k, n in knobs {
		switch {
		case k.intensity:
			if !ctl_knob(ctx, n, len(knobs), "Intensity", plot) do continue
			x := m.project.perf_intensity[t.index]
			ke := ui.knob("Intensity", &x, 0, 1, 1, "%.2f")
			if ke.changed {
				pa.history_gesture_begin(&a.api)
				pa.effect_set_intensity(&a.api, i64(t.index), clamp(x, 0, 1))
			}
			if ke.ended do pa.history_gesture_end(&a.api)
		case k.synth != 0:
			spec := synth.param_spec(k.synth)
			label := fmt.ctprintf("%s##s%d", synth_effect_label(e, spec.name), int(k.synth))
			ctl_synth_param(ctx, n, len(knobs), label, k.synth, plot)
		case k.is:
			p := k.info
			label := fmt.ctprintf("%s##p%d", p.name, p.id)
			if .Stepped in p.flags && p.max - p.min <= 64 {
				v := pm.slot_value(s, p.id, max(f32))
				if v == max(f32) {
					v = f32(p.default)
					if plugin != nil do if x, ok := clap.plugin_param_value(plugin, p.id); ok do v = f32(x)
				}
				names := make([dynamic]string, context.temp_allocator)
				if p.min == 0 && p.max == 1 do append(&names, ..OFF_ON)
				else do for x := int(p.min); x <= int(p.max); x += 1 do append(&names, fmt.tprintf("%d", x))
				if j, _ := ctl_choice(ctx, n, len(knobs), label, names[:], int(v) - int(p.min), plot); j >= 0 {
					control_effect_param(a, t, i64(p.id), p.min + f64(j), true, true)
				}
				continue
			}
			if ctl_knob(ctx, n, len(knobs), label, plot) do param_knob(a, t, s, p, plugin, as_knob = true)
		}
	}
}

// A plug-in's editor (its own window, on the computer), as button `k`.
@(private)
ctl_editor_button :: proc(ctx: ^View_Ctx, k: int, t: pm.Fx_Target, p: ^clap.Plugin, full: im.Vec2) {
	a := ctx.a
	if !clap.plugin_gui_supported(p, editor_api()) do return
	open := false
	for e in a.editors do open ||= e.plugin == p
	if b, _ := ctl_button(ctx, k, "Close Editor" if open else "Open Editor", open, full); b {
		if open do editor_close(a, p)
		else do editor_open(a, t)
	}
}

// A plug-in instrument: every parameter, a knob each (eight a bank), its
// editor, Clear Pad.
@(private)
ctl_plugin :: proc(ctx: ^View_Ctx, t: pm.Fx_Target, plot, full: im.Vec2) {
	a := ctx.a
	m := &a.m
	i := t.index
	s := m.project.pads[i].instrument
	p := pm.pad_plugin(&m.engine, i)
	ctl_tabs(ctx, {pm.slot_name(s)}, 0)
	ctl_pad_card(a, i, plot)
	if p == nil {
		ctl_message("Loading…" if !pm.pad_plugin_failed(&m.engine, i) else fmt.tprintf("Could not load %s", s.plugin_path), plot)
		return
	}
	if panel := (Fx_Panel{ctx = ctx, where_ = .Plugin_Instrument, kind = .Plugin, t = t, s = s, pad = i, plugin = p, plot = plot, full = full}); fx_panel(&panel) do return // (ui_ctl_fx_midi_plugin.odin)
	knobs := make([dynamic]Ctl_Param, context.temp_allocator)
	for q in pm.target_params(&m.engine, t) do append(&knobs, Ctl_Param{info = q, is = true})
	ctl_params(ctx, t, s, p, knobs[:], {}, plot)
	ctl_editor_button(ctx, 0, t, p, full)
}

// --- the synth ----------------------------------------------------------------------------------

// The synth's tabs (Osc, Filter, Env, LFO, Mod, Effects, Macro, Global),
// as the window's: their pictures, every parameter a knob (its choices
// dropdowns, named as the window names them; eight a bank, the banks on the
// lower row), which oscillator, filter or envelope on its buttons; which
// LFO, route or effect a dropdown of its own, first in each bank.
@(private)
ctl_synth :: proc(ctx: ^View_Ctx, i: int, plot, full: im.Vec2) {
	a := ctx.a
	st := &a.synth_ui
	names: [len(Synth_Tab)]string
	for tab in Synth_Tab do names[int(tab)] = SYNTH_TAB_NAMES[tab]
	if k := ctl_tabs(ctx, names[:], int(st.tab)); k >= 0 {
		st.tab, st.show = Synth_Tab(k), 2
		a.ws.bottom_folded = false
	}
	im.SetCursorPos({0, CTL_PLOT_Y})
	m := &a.m
	sy := &m.project.pads[i].synth
	o :: synth.osc_param
	switch st.tab {
	case .Osc:
		draw_table_view(a, st.osc, plot)
		osc_names := [4]string{"Osc A", "Osc B", "Osc C", "Sample"}
		ctl_caption(fmt.tprintf("%s · %s", osc_names[clamp(st.osc, 0, 3)], pm.synth_source_name(m, sy.sample if st.osc == 3 else sy.tables[clamp(st.osc, 0, 2)], noise = st.osc == 3)))
		knobs: []Knob
		if st.osc < 3 {
			n := st.osc + 1
			knobs = {{"On", o(n, .On)}, {"Level", o(n, .Level)}, {"Pan", o(n, .Pan)}, {"Frame", o(n, .Frame)}, {"Transpose", o(n, .Transpose)}, {"Tune", o(n, .Tune)}, {"Phase", o(n, .Phase)}, {"Random", o(n, .Random_Phase)},
				{"Voices", o(n, .Unison)}, {"Detune", o(n, .Detune)}, {"Blend", o(n, .Blend)}, {"Stereo", o(n, .Stereo_Spread)}, {"Curve", o(n, .Detune_Power)}, {"Range", o(n, .Detune_Range)}, {"Unison", o(n, .Stack)}, {"Key Track", o(n, .Keytrack)},
				{"Warp", o(n, .Warp)}, {"Warp Amount", o(n, .Warp_Amount)}, {"Warp Spread", o(n, .Warp_Spread)}, {"Warp Phase", o(n, .Warp_Phase)}, {"Morph", o(n, .Spectral_Morph)}, {"Morph Amount", o(n, .Spectral_Amount)}, {"Destination", o(n, .Destination)}}
		} else {
			sp :: synth.sample_param
			knobs = {{"On", sp(.On)}, {"Level", sp(.Level)}, {"Pan", sp(.Pan)}, {"Transpose", sp(.Transpose)}, {"Tune", sp(.Tune)}, {"Random Start", sp(.Random_Phase)}, {"Key Track", sp(.Keytrack)}, {"Loop", sp(.Loop)},
				{"Bounce", sp(.Bounce)}, {"Destination", sp(.Destination)}}
		}
		// The sound first (a dropdown, as the window's): the oscillator's
		// wavetable (Basic Shapes, Saw...), the sample oscillator's noise.
		ctl_osc_source(ctx, i, st.osc, len(knobs) + 1, plot)
		for k, n in knobs do ctl_synth_param(ctx, n + 1, len(knobs) + 1, k.label, k.id, plot)
		for name, k in ([4]cstring{"Osc A", "Osc B", "Osc C", "Sample"}) {
			if p, _ := ctl_button(ctx, k, name, st.osc == k, full); p do st.osc = k
		}
	case .Filter:
		k := clamp(a.ctl.filter, 0, synth.FILTERS - 1)
		n := k + 1
		f :: synth.filter_param
		sr := a.host.graph.settings.sample_rate if a.host.graph.settings.sample_rate > 0 else 48_000
		p := filter_ui_params(a, n)
		c := &a.synth_ui.response[k]
		measure_filter(c, p, sr)
		on := pm.synth_value(m, i, f(n, .On)) > 0.5
		color := ui.rgb(m.project.pads[i].color)
		if !on do color = ui.mix(ui.PLOT_BG, color, 0.4)
		handle := [2]f32{ui.freq_x(fx.key_to_hz(p.cutoff)), p.resonance * 24}
		ui.response_plot("ctl synth filter", {{db = c.db[:], color = color, fill = true, width = 2.5}}, &handle, plot)
		ctl_caption(fmt.tprintf("Filter %d", n))
		knobs := make([dynamic]Knob, context.temp_allocator)
		append(&knobs, Knob{"On", f(n, .On)}, Knob{"Model", f(n, .Model)}, Knob{"Style", f(n, .Style)}, Knob{"Cutoff", f(n, .Cutoff)}, Knob{"Resonance", f(n, .Resonance)})
		#partial switch p.model {
		case .Formant: append(&knobs, Knob{"Vowel X", f(n, .Formant_X)}, Knob{"Vowel Y", f(n, .Formant_Y)}, Knob{"Formant", f(n, .Formant_Transpose)}, Knob{"Q", f(n, .Formant_Resonance)}, Knob{"Spread", f(n, .Formant_Spread)})
		case .Comb:    append(&knobs, Knob{"Blend", f(n, .Blend)}, Knob{"Offset", f(n, .Comb_Offset)})
		case:
			append(&knobs, Knob{"Drive", f(n, .Drive)}, Knob{"Blend", f(n, .Blend)})
			if p.style == .Shelving do append(&knobs, Knob{"Gain", f(n, .Gain)})
		}
		append(&knobs, Knob{"Key", f(n, .Keytrack)}, Knob{"Mix", f(n, .Mix)})
		if n == 2 do append(&knobs, Knob{"In Series", f(2, .From_Filter)})
		ctl_synth_knobs(ctx, knobs[:], plot)
		for name, j in ([2]cstring{"Filter 1", "Filter 2"}) {
			if b, _ := ctl_button(ctx, j, name, k == j, full); b do a.ctl.filter = j
		}
	case .Env:
		n := st.env + 1
		env_editor(a, n, plot)
		ctl_caption(fmt.tprintf("Env %d%s", n, " (amp)" if n == 1 else ""))
		e :: synth.env_param
		ctl_synth_knobs(ctx, {{"Delay", e(n, .Delay)}, {"Attack", e(n, .Attack)}, {"Hold", e(n, .Hold)}, {"Decay", e(n, .Decay)}, {"Sustain", e(n, .Sustain)}, {"Release", e(n, .Release)}, {"A Curve", e(n, .Attack_Power)}, {"D Curve", e(n, .Decay_Power)}, {"R Curve", e(n, .Release_Power)}}, plot)
		for k in 0 ..< synth.ENVS {
			if b, _ := ctl_button(ctx, k, fmt.ctprintf("Env %d", k + 1), st.env == k, full); b do st.env = k
		}
	case .Lfo:
		// Which: LFO 1..8, random 1..4 (a dropdown first in each bank).
		which := make([dynamic]string, context.temp_allocator)
		for k in 0 ..< synth.LFOS do append(&which, fmt.tprintf("LFO %d", k + 1))
		for k in 0 ..< 4 do append(&which, fmt.tprintf("Random %d", k + 1))
		st.lfo = clamp(st.lfo, 0, len(which) - 1)
		knobs := make([dynamic]Knob, context.temp_allocator)
		if st.lfo < synth.LFOS {
			k := st.lfo
			n := k + 1
			l :: synth.lfo_param
			lfo_editor(a, k, plot)
			rate := synth.Lfo_Rate(int(pm.synth_value(m, i, l(n, .Rate))))
			speed := l(n, .Hz) if rate == .Seconds else (l(n, .Key_Transpose) if rate == .Keytrack else l(n, .Tempo))
			append(&knobs, Knob{"Mode", l(n, .Mode)}, Knob{"Rate By", l(n, .Rate)}, Knob{"Rate" if rate != .Keytrack else "Transpose", speed}, Knob{"Phase", l(n, .Phase)}, Knob{"Fade In", l(n, .Fade)}, Knob{"Delay", l(n, .Delay)}, Knob{"Stereo", l(n, .Stereo)},
				Knob{"Smooth", l(n, .Smooth)}, Knob{"Smooth Time", l(n, .Smooth_Time)})
		} else {
			n := st.lfo - synth.LFOS + 1
			r :: synth.random_param
			ctl_message("A random modulator: drag it onto a knob in Pads", plot)
			rate := synth.Lfo_Rate(int(pm.synth_value(m, i, r(n, .Rate))))
			speed := r(n, .Hz) if rate == .Seconds else (r(n, .Key_Transpose) if rate == .Keytrack else r(n, .Tempo))
			append(&knobs, Knob{"Style", r(n, .Style)}, Knob{"Rate By", r(n, .Rate)}, Knob{"Rate" if rate != .Keytrack else "Transpose", speed}, Knob{"Stereo", r(n, .Stereo)}, Knob{"Retrigger", r(n, .Retrigger)})
			if rate == .Keytrack do append(&knobs, Knob{"Tune", r(n, .Key_Tune)})
		}
		ctl_caption(which[st.lfo])
		// The dropdown, then seven knobs a bank (each named by its first knob).
		total := (len(knobs) + 6) / 7 * 8
		for b in 0 ..< (len(knobs) + 6) / 7 do ctx.banks[b] = string(knobs[b * 7].label)
		for b in 0 ..< (len(knobs) + 6) / 7 {
			if k, _ := ctl_choice(ctx, b * 8, total, "LFO", which[:], st.lfo, plot); k >= 0 do st.lfo = k
		}
		for kn, n in knobs do ctl_synth_param(ctx, n / 7 * 8 + 1 + n % 7, total, kn.label, kn.id, plot)
	case .Mod:
		if sy.route_count == 0 {
			ctl_message("No modulation yet: drag a source onto a knob in Pads", plot)
			break
		}
		routes := make([dynamic]string, context.temp_allocator)
		for k in 0 ..< sy.route_count {
			r := sy.routes[k]
			spec := synth.param_spec(r.dest)
			append(&routes, fmt.tprintf("%s › %s", mini_name(r.source), spec.name if spec != nil else "?"))
		}
		k := clamp(a.ctl.route, 0, sy.route_count - 1)
		r := sy.routes[k]
		ctl_message(fmt.tprintf("%s: from %s", routes[k], mod_name(a, r.source)), plot)
		N :: 6
		if j, _ := ctl_choice(ctx, 0, N, "Route", routes[:], k, plot); j >= 0 do a.ctl.route = j
		if ctl_knob(ctx, 1, N, "Amount", plot) {
			amt := r.amount * 100
			if e := ui.knob("Amount", &amt, -100, 100, 0, "%+.0f%%"); e.changed {
				x := r
				x.amount = amt / 100
				pm.set_synth_route(m, i, k, x, "Modulation Amount")
			} else if e.ended do app.seal(&m.history)
		}
		if ctl_knob(ctx, 2, N, "Curve", plot) {
			pw := r.power
			if e := ui.knob("Curve", &pw, -10, 10, 0, "%+.1f"); e.changed {
				x := r
				x.power = pw
				pm.set_synth_route(m, i, k, x, "Modulation Curve")
			} else if e.ended do app.seal(&m.history)
		}
		flags := [3]bool{r.bipolar, r.stereo, !r.bypass}
		for name, j in ([3]cstring{"Bipolar", "Stereo", "On"}) {
			if c, _ := ctl_choice(ctx, 3 + j, N, name, OFF_ON, 1 if flags[j] else 0, plot); c >= 0 {
				x := r
				switch j {
				case 0: x.bipolar = c == 1
				case 1: x.stereo = c == 1
				case 2: x.bypass = c == 0
				}
				pm.set_synth_route(m, i, k, x, string(name))
				app.seal(&m.history)
			}
		}
	case .Effects:
		e := st.effect
		{
			panel := Fx_Panel{ctx = ctx, where_ = .Synth, kind = fx_kind_of_synth(e), effect = e, twin = true, pad = i, plot = plot, full = full, lead = 1}
			if fx_panel(&panel) do break // (its family's own: ui_ctl_fx_*.odin)
		}
		order := make([dynamic]string, context.temp_allocator)
		at := 0
		for x, k in sy.fx_order {
			xon := pm.synth_value(m, i, effect_on(x)) > 0.5
			append(&order, fmt.tprintf("%d %s%s", k + 1, synth.EFFECT_NAMES[x], "" if xon else " (off)"))
			if x == e do at = k
		}
		on := pm.synth_value(m, i, effect_on(e)) > 0.5
		ctl_message(fmt.tprintf("%s%s", synth.EFFECT_NAMES[e], "" if on else " (off)"), plot)
		ids := make([dynamic]fc.Param_Id, context.temp_allocator)
		append(&ids, effect_on(e))
		append(&ids, ..synth_effect_ids(e)[:])
		total := (len(ids) + 6) / 7 * 8
		for b in 0 ..< (len(ids) + 6) / 7 do ctx.banks[b] = "On" if b == 0 else synth_effect_label(e, synth.param_spec(ids[b * 7]).name)
		for b in 0 ..< (len(ids) + 6) / 7 {
			if k, _ := ctl_choice(ctx, b * 8, total, "Effect", order[:], at, plot); k >= 0 do st.effect = sy.fx_order[k]
		}
		for id, n in ids {
			spec := synth.param_spec(id)
			label := fmt.ctprintf("%s##s%d", "On" if id == effect_on(e) else synth_effect_label(e, spec.name), int(id))
			ctl_synth_param(ctx, n / 7 * 8 + 1 + n % 7, total, label, id, plot)
		}
	case .Macro:
		ctl_message("The macros: drag one onto a knob in Pads", plot)
		for k in 0 ..< synth.MACROS {
			label := fmt.ctprintf("%s###macro%d", pm.synth_macro_name(m, i, k), k)
			if ctl_knob(ctx, k, synth.MACROS, label, plot) do synth_knob(a, label, fc.Param_Id(int(synth.global_param(.Macro_1)) + k))
		}
	case .Global:
		draw_synth_scope(a, plot)
		g :: synth.global_param
		ctl_synth_knobs(ctx, {{"Volume", g(.Volume)}, {"Voices", g(.Polyphony)}, {"Glide", g(.Glide)}, {"Glide Curve", g(.Glide_Slope)}, {"Bend Range", g(.Bend_Range)}, {"Velocity", g(.Velocity_Track)}, {"Transpose", g(.Transpose)}, {"Tune", g(.Tune)},
			{"Voice Mode", g(.Mono)}, {"Oversampling", g(.Oversampling)}, {"Priority", g(.Priority)}, {"Always Glide", g(.Glide_Always)}, {"Glide Octaves", g(.Glide_Octave)}}, plot)
	}
}

// Oscillator `osc`'s sound as knob 0 of `total`: a built-in table, one of
// the project's own (its wave documents) or, for the sample oscillator, a
// noise. A sound dropped on the oscillator in Pads shows as one more name.
@(private)
ctl_osc_source :: proc(ctx: ^View_Ctx, i, osc, total: int, plot: im.Vec2) {
	m := &ctx.a.m
	sy := &m.project.pads[i].synth
	names := make([dynamic]string, context.temp_allocator)
	srcs := make([dynamic]pm.Synth_Source, context.temp_allocator)
	cur := sy.sample if osc == 3 else sy.tables[clamp(osc, 0, 2)]
	at := -1
	add :: proc(names: ^[dynamic]string, srcs: ^[dynamic]pm.Synth_Source, at: ^int, cur, src: pm.Synth_Source, name: string) {
		if src == cur do at^ = len(names)
		append(names, name)
		append(srcs, src)
	}
	if osc == 3 {
		for b in synth.Builtin_Noise do add(&names, &srcs, &at, cur, {builtin = u8(b)}, synth.BUILTIN_NOISE_NAMES[b])
	} else {
		for b in synth.Builtin_Table do add(&names, &srcs, &at, cur, {builtin = u8(b)}, synth.BUILTIN_NAMES[b])
		for it in m.project.wave_docs.items do add(&names, &srcs, &at, cur, {table = it.id}, pm.wave_doc_name(m, it.id))
	}
	if at < 0 do add(&names, &srcs, &at, cur, cur, pm.synth_source_name(m, cur, noise = osc == 3))
	label: cstring = "Noise" if osc == 3 else "Wavetable"
	if k, _ := ctl_choice(ctx, 0, total, label, names[:], at, plot); k >= 0 && srcs[k] != cur {
		if osc == 3 do pm.set_synth_sample(m, i, srcs[k])
		else do pm.set_synth_table(m, i, osc, srcs[k])
	}
}

// A synth tab's knobs, eight a bank.
@(private)
ctl_synth_knobs :: proc(ctx: ^View_Ctx, knobs: []Knob, plot: im.Vec2) {
	for k, n in knobs do ctl_synth_param(ctx, n, len(knobs), k.label, k.id, plot)
}

// Synth parameter `id` as knob `n` of `total`: a choice (an indexed one) a
// dropdown of its names, else a knob.
@(private)
ctl_synth_param :: proc(ctx: ^View_Ctx, n, total: int, label: cstring, id: fc.Param_Id, plot: im.Vec2) {
	a := ctx.a
	spec := synth.param_spec(id)
	if spec == nil do return
	if names := synth_choice_names(a, id); names != nil {
		if k, ended := ctl_choice(ctx, n, total, label, names, int(host_value(a, id) + 0.5) - int(spec.min), plot); k >= 0 || ended {
			if k >= 0 do host_set(a, id, spec.min + f32(k), spec.name)
			pa.history_gesture_end(&a.api)
		}
		return
	}
	if ctl_knob(ctx, n, total, label, plot) do synth_knob(a, label, id)
}

// The names of synth choice `id`'s values, as the window's dropdowns show
// them; nil for a number (a knob: transposition, voices, a tempo division
// by its index).
@(private)
synth_choice_names :: proc(a: ^App, id: fc.Param_Id) -> []string {
	spec := synth.param_spec(id)
	name := spec.name
	has :: strings.has_suffix
	if spec.curve != .Indexed && !has(name, " Tempo") do return nil
	switch {
	case has(name, " Tempo"):                         return TEMPO_NAMES[:int(spec.max) - int(spec.min) + 1]
	case spec.min == 0 && spec.max == 1:              return OFF_ON
	case name == "Voice Mode":                        return VOICE_MODE_NAMES
	case name == "Oversampling":                      return OVERSAMPLING_NAMES
	case name == "Voice Priority":                    return PRIORITY_NAMES
	case has(name, " Destination"):                   return DESTINATION_NAMES
	case has(name, " Spectral Morph"):                return MORPH_NAMES
	case has(name, " Stack"):                         return STACK_NAMES
	case has(name, " Warp"):                          return WARP_NAMES
	case has(name, " Model"):                         return FILTER_MODEL_NAMES
	case has(name, " Style") && strings.has_prefix(name, "Random"): return RANDOM_STYLE_NAMES
	case has(name, " Style") && strings.has_prefix(name, "Delay"):  return DELAY_STYLE_NAMES
	case has(name, " Style"): // a filter's: by its model (the parameter before)
		return filter_style_names(fx.Filter_Model(int(host_value(a, fc.Param_Id(int(id) - 1)) + 0.5)))
	case strings.has_prefix(name, "LFO") && has(name, " Mode"): return LFO_MODE_NAMES
	case has(name, " Rate"):                          return LFO_RATE_NAMES
	case has(name, " Sync"):                          return SYNC_NAMES
	case name == "Distortion Type":                   return DISTORTION_NAMES
	case name == "Distortion Filter":                 return DISTORTION_FILTER_NAMES
	case name == "Compressor Bands":                  return COMPRESSOR_BAND_NAMES
	}
	return nil
}

// A synth effect's parameters (their names start with the effect's).
@(private)
synth_effect_ids :: proc(e: fx.Effect) -> [dynamic]fc.Param_Id {
	out := make([dynamic]fc.Param_Id, context.temp_allocator)
	prefix := fmt.tprintf("%s ", synth.EFFECT_NAMES[e])
	for id in 1 ..< 1024 { // (param_spec: nil past the last)
		spec := synth.param_spec(fc.Param_Id(id))
		if spec == nil || !strings.has_prefix(spec.name, prefix) do continue
		if fc.Param_Id(id) == effect_on(e) do continue // (its switch: a button)
		append(&out, fc.Param_Id(id))
	}
	return out
}

// A synth effect's parameter's name without the effect's.
@(private)
synth_effect_label :: proc(e: fx.Effect, name: string) -> string {
	return strings.trim_prefix(name, fmt.tprintf("%s ", synth.EFFECT_NAMES[e]))
}

// The controller's Shift held, for the view being drawn (its knobs' names
// say "fine": a turn is a tenth).
@(private)
ctl_shift_now: bool
