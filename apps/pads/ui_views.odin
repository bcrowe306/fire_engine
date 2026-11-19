// Pads' views for controllers' displays (fire.pads `view_frame`, Push 2's
// display): each view a surface asks for, drawn offscreen after the
// window's frame with Pads' widgets and theme, its pixels handed back to
// the API (a frame later).
package pads


import "core:fmt"
import "core:math"

import "app:ui"
import pa "api"
import pm "model"
import im "deps:imgui"

// An offscreen UI for one view a surface wants (kind, page and size).
@(private)
View_Draw :: struct {
	key:  [4]i64, // kind, page, width, height
	off:  ui.Offscreen,
	put:  int, // the offscreen frames handed to the API
	used: bool,
}

// What a view's drawing is given: the app, what's asked, and the
// controller's input (its encoders' turns, its buttons' presses).
@(private)
View_Ctx :: struct {
	a:       ^App,
	want:    pa.View_Request,
	input:   ^pa.View_Input,
	knobs:   ui.Knob_Input,
	buttons: i64, // drawn (bits: View_Button)
	lit:     i64,
	pages:   int, // its knobs' pages, and the one shown
	page:    int,
	banks:   [16]string, // each page's name (its first knob's)
}

// After the window's frame: the views surfaces want, drawn; their finished
// frames handed to the API. Views no longer wanted are let go.
views_render :: proc(a: ^App) {
	wants := pa.views_wanted(&a.api)
	for v in a.views do v.used = false
	for w in wants {
		key := [4]i64{i64(w.kind), w.page, w.width, w.height}
		v: ^View_Draw
		for x in a.views do if x.key == key do v = x
		if v == nil {
			v = new(View_Draw)
			v.key = key
			if !ui.offscreen_init(&v.off, &a.platform) {
				free(v)
				continue
			}
			append(&a.views, v)
		}
		v.used = true
		if px, pw, ph, n := ui.offscreen_pixels(&v.off); px != nil && n > v.put && i64(pw) == w.width && i64(ph) == w.height {
			pa.views_put(&a.api, w.index, px)
			v.put = n
		}
		ctx := View_Ctx{a = a, want = w, input = pa.views_input(&a.api, w.index)}
		if ctx.input != nil do ctx.knobs = {turn = ctx.input.turn, held = ctx.input.held, ended = ctx.input.ended, size = CTL_KNOB, bar_w = CTL_BAR_W}
		if inp := ctx.input; inp != nil {
			if inp.pressed[int(pa.View_Button.Shift)] do a.ctl.shift = true
			if inp.released[int(pa.View_Button.Shift)] do a.ctl.shift = false
		}
		ctl_shift_now = a.ctl.shift
		// In its track's colour, as the window's bottom area (the device's
		// pad; elsewhere the selected pad's).
		ui.set_accent(&a.platform, track_accent(a, w.kind != .Device))
		drawn := ui.offscreen_draw(&v.off, int(w.width), int(w.height), proc(user: rawptr) {
			ctx := (^View_Ctx)(user)
			ui.knob_input = &ctx.knobs
			defer ui.knob_input = nil
			view_draw(ctx)
		}, &ctx, bg = VIEW_BG)
		ui.set_accent(&a.platform, {})
		// What the drawing took (a step's turn still adding up waits), and
		// what it offers now. (Not drawn this time, the GPU still busy: it
		// all waits for the next.)
		if inp := ctx.input; inp != nil && drawn {
			inp.turn, inp.ended = ctx.knobs.turn, {}
			inp.pressed, inp.released = {}, {}
			inp.state = {knobs = i64(ctx.knobs.drawn), buttons = ctx.buttons, lit = ctx.lit, pages = i64(ctx.pages), page = i64(ctx.page)}
		}
	}
	for i := len(a.views) - 1; i >= 0; i -= 1 do if !a.views[i].used {
		ui.offscreen_destroy(&a.views[i].off)
		free(a.views[i])
		ordered_remove(&a.views, i)
	}
}

// Lets every view's offscreen UI go (before the platform).
views_destroy :: proc(a: ^App) {
	for v in a.views {
		ui.offscreen_destroy(&v.off)
		free(v)
	}
	delete(a.views)
}

// The status line's height at the top of every view (a controller's
// display): what is true wherever you are (view_status).
CTL_STATUS_H :: 16

// Draws a view, filling the offscreen window: the status line across the
// top, the view itself under it (a child window: its own coordinates, its
// size the rest).
@(private)
view_draw :: proc(ctx: ^View_Ctx) {
	w := ctx.want
	full := im.Vec2{f32(w.width), f32(w.height)}
	view_status(ctx, full)
	im.SetCursorPos({0, CTL_STATUS_H})
	size := im.Vec2{full.x, full.y - CTL_STATUS_H}
	if im.BeginChild("##view", size, {}, {.NoScrollbar, .NoScrollWithMouse, .NoBackground}) {
		switch w.kind {
		case .Device: ctl_device(ctx, size)
		case .Dialog: view_dialog(ctx, size)
		case .Browser: ctl_browser(ctx, size)
		case .Clip:    ctl_perform(ctx, size)
		case .Sequencer: ctl_sequencer(ctx, size)
		case .Mixer:     ctl_mixer(ctx, size)
		case .Song:      ctl_song(ctx, size)
		case .Settings:  ctl_settings(ctx, size)
		case .Projects:  ctl_projects(ctx, size)
		}
	}
	im.EndChild()
}

// A controller's display is black behind Pads' widgets (its own look:
// the window's background would glow on the hardware).
VIEW_BG :: ui.Color{0, 0, 0, 1}

// A page with nothing to show: why, centred.
@(private)
view_empty :: proc(why: cstring, size: im.Vec2) {
	ts := im.CalcTextSize(why)
	im.SetCursorPos({(size.x - ts.x) / 2, (size.y - ts.y) / 2})
	im.TextDisabled("%s", why)
}

// Pad `i`'s stereo meter, at `pos` (in the window), `size` big.
@(private)
view_meter :: proc(a: ^App, i: int, pos, size: im.Vec2) {
	dl := im.GetWindowDrawList()
	o := im.GetWindowPos()
	mw := (size.x - 2) / 2
	meter_bars(a, dl, &a.mixer.pads[i], o.x + pos.x, o.y + pos.y + 2, o.y + pos.y + size.y - 2, mw)
}

// The status line over every view, always in the same places, never over
// the view: at the left Shift (held), the sequence (its number and name),
// where it plays (bar.beat; counting in, the beats to the top, red), the
// tempo, then the device chain (Device: the one shown bright, an off one
// dim) or the selected pad; at the right Pads' newest message (a while),
// input quantize, the unsaved dot, and Main's meter.
@(private)
view_status :: proc(ctx: ^View_Ctx, full: im.Vec2) {
	a := ctx.a
	t := ui.theme()
	dl := im.GetWindowDrawList()
	o := im.GetWindowPos()
	h := f32(CTL_STATUS_H)
	im.DrawList_AddRectFilled(dl, o, {o.x + full.x, o.y + h}, ui.col(ui.mix(VIEW_BG, t.surface, 0.6)))
	ui.text_push(.Caption)
	defer ui.text_pop()
	mid := o.y + h / 2
	x := o.x + 6
	put :: proc(dl: ^im.DrawList, x: ^f32, mid: f32, text: string, c: ui.Color, gap: f32 = 12) {
		ct := fmt.ctprintf("%s", text)
		ts := im.CalcTextSize(ct)
		im.DrawList_AddText(dl, {x^, mid - ts.y / 2}, ui.col(c), ct)
		x^ += ts.x + gap
	}
	badge :: proc(dl: ^im.DrawList, x0, mid: f32, text: string, bg, fg: ui.Color) -> f32 {
		ct := fmt.ctprintf("%s", text)
		ts := im.CalcTextSize(ct)
		im.DrawList_AddRectFilled(dl, {x0, mid - 7}, {x0 + ts.x + 8, mid + 7}, ui.col(bg), 3)
		im.DrawList_AddText(dl, {x0 + 4, mid - ts.y / 2}, ui.col(fg), ct)
		return ts.x + 8
	}
	if a.ctl.shift do x += badge(dl, x, mid, "SHIFT", t.warn, t.bg) + 10
	// The sequence and its length, where it plays, the tempo.
	p := &a.m.project
	put(dl, &x, mid, fmt.tprintf("S%d %s", p.slot + 1, pm.sequence_name(p, p.slot)), t.text, 6)
	bars := max(p.sequences[p.slot].bars, 1)
	put(dl, &x, mid, fmt.tprintf("%d bar%s", bars, "" if bars == 1 else "s"), t.text_dim)
	if tr, _ := pa.transport_state(&a.api); true {
		if tr.counting_in do put(dl, &x, mid, fmt.tprintf("-%d", int(math.ceil(-tr.timeline_beat))), t.danger)
		else do put(dl, &x, mid, fmt.tprintf("%d.%d", max(tr.bar, 1), max(tr.beat_in_bar, 1)), t.text if tr.playing else t.text_dim)
		put(dl, &x, mid, fmt.tprintf("%.1f BPM", tr.bpm), t.text_dim, 18)
	}
	// The device chain (Device), or the selected pad.
	if ctx.want.kind == .Device {
		chain := ctl_chain(a)
		for d, k in chain {
			name := ctl_device_name(a, d)
			off := false
			if d.kind == .Slot do if s, ok := pm.target_slot(&a.m, ctl_device_fx(a, d)); ok && s.kind != .None && !s.on do off = true
			c := t.text if d == a.detail.device else t.text_dim
			if off do c = ui.with_alpha(c, 0.5)
			put(dl, &x, mid, fmt.tprintf("%s%s", name, " (off)" if off else ""), c, 4)
			if k < len(chain) - 1 do put(dl, &x, mid, "›", t.text_dim, 4)
		}
	} else {
		put(dl, &x, mid, fmt.tprintf("%s %s", pm.pad_label(a.selected), pm.pad_name(&p.pads[a.selected])), t.text_dim)
	}
	// From the right: Main's meter, the unsaved dot, IQ, the message.
	right := o.x + full.x - 4
	mw: f32 = 110
	view := &a.mixer.buses[pm.BUSES]
	for c in 0 ..< 2 {
		y := o.y + 3 + f32(c) * 6
		im.DrawList_AddRectFilled(dl, {right - mw, y}, {right, y + 4}, ui.col(well(t)), 1)
		lvl := fader_frac(20 * math.log10(view[c].peak)) if view[c].peak > 0 else 0
		cc := t.ok if lvl < fader_frac(-12) else (t.warn if lvl < fader_frac(0) else t.danger)
		if lvl > 0 do im.DrawList_AddRectFilled(dl, {right - mw, y}, {right - mw + mw * clamp(lvl, 0, 1), y + 4}, ui.col(cc), 1)
	}
	right -= mw + 8
	if pm.model_dirty(&a.m) {
		im.DrawList_AddCircleFilled(dl, {right - 4, mid}, 3.5, ui.col(t.warn), 12)
		right -= 14
	}
	if iq, _ := pa.sequence_input_quantize(&a.api); iq.on {
		text := fmt.tprintf("IQ %s", pm.GRID_NAMES[pm.Grid(iq.grid)])
		ts := im.CalcTextSize(fmt.ctprintf("%s", text))
		right -= ts.x + 8
		badge(dl, right, mid, text, t.accent, t.bg)
		right -= 10
	}
	items := a.ws.toasts.items
	if len(items) > 0 {
		toast := items[len(items) - 1]
		if toast.age <= BANNER_S {
			c := t.text
			switch toast.kind {
			case .Info:    c = t.text
			case .Success: c = t.ok
			case .Warning: c = t.warn
			case .Error:   c = t.danger
			}
			ct := fmt.ctprintf("%s", toast.text)
			ts := im.CalcTextSize(ct)
			x0 := max(right - ts.x, x + 8)
			im.DrawList_PushClipRect(dl, {x0, o.y}, {right, o.y + h}, true)
			im.DrawList_AddRectFilled(dl, {x0 - 6, o.y}, {right + 2, o.y + h}, ui.col(ui.mix(VIEW_BG, t.surface, 0.6))) // (over the chain, if it is long)
			im.DrawList_AddText(dl, {x0, mid - ts.y / 2}, ui.col(c), ct)
			im.DrawList_PopClipRect(dl)
		}
	}
}

// How long a message shows on a controller's display (seconds).
BANNER_S :: 2.0
