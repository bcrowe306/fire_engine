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
	bank_end: int, // the last of the lower row the banks may take (0: the row's last)
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
		if ctx.input != nil do ctx.knobs = {turn = ctx.input.turn, held = ctx.input.held, ended = ctx.input.ended, size = CTL_KNOB}
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

// Draws a view, filling the offscreen window.
@(private)
view_draw :: proc(ctx: ^View_Ctx) {
	w := ctx.want
	size := im.Vec2{f32(w.width), f32(w.height)}
	switch w.kind {
	case .Device: ctl_device(ctx, size)
	case .Dialog: view_dialog(ctx, size)
	case .Browser: ctl_browser(ctx, size)
	case .Clip:    ctl_perform(ctx, size)
	case .Sequencer: ctl_sequencer(ctx, size)
	case .Mixer:     ctl_mixer(ctx, size)
	case .Song:      ctl_song(ctx, size)
	case .Settings:  ctl_settings(ctx, size)
	}
	view_overlay(ctx, size)
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

// Over every view: Pads' newest message as a banner that closes by itself
// (the window's toast: saved, loaded, an error), and a dot in the corner
// while the project has changes not saved.
@(private)
view_overlay :: proc(ctx: ^View_Ctx, size: im.Vec2) {
	a := ctx.a
	t := ui.theme()
	dl := im.GetForegroundDrawList()
	o := im.GetWindowPos()
	if pm.model_dirty(&a.m) do im.DrawList_AddCircleFilled(dl, {o.x + size.x - 7, o.y + 7}, 3.5, ui.col(t.warn), 12)
	// Shift held on the controller: a badge at the top left (its knobs'
	// names say "fine"; what else it does, the lit buttons say).
	if a.ctl.shift {
		ui.text_push(.Label)
		text: cstring = "SHIFT"
		ts := im.CalcTextSize(text)
		im.DrawList_AddRectFilled(dl, {o.x + 2, o.y + 2}, {o.x + ts.x + 12, o.y + 20}, ui.col(t.warn), 4)
		im.DrawList_AddText(dl, {o.x + 7, o.y + 11 - ts.y / 2}, ui.col(t.bg), text)
		ui.text_pop()
	}
	// Input quantize on: a badge at the top right ("IQ 1/16"), left of
	// where it plays.
	right := o.x + size.x - 14
	if iq, _ := pa.sequence_input_quantize(&a.api); iq.on {
		ui.text_push(.Label)
		text := fmt.ctprintf("IQ %s", pm.GRID_NAMES[pm.Grid(iq.grid)])
		ts := im.CalcTextSize(text)
		x1 := right
		if tr, _ := pa.transport_state(&a.api); tr.playing do x1 -= 46 // (bar.beat's room)
		x0 := x1 - ts.x - 10
		im.DrawList_AddRectFilled(dl, {x0, o.y + 2}, {x1, o.y + 20}, ui.col(ui.with_alpha(t.accent, 0.85)), 4)
		im.DrawList_AddText(dl, {x0 + 5, o.y + 11 - ts.y / 2}, ui.col(t.bg), text)
		ui.text_pop()
	}
	// Where it plays (bar.beat), at the top right; counting in, the beats
	// to the top, red.
	if tr, _ := pa.transport_state(&a.api); tr.playing {
		text := fmt.ctprintf("%d.%d", tr.bar, tr.beat_in_bar)
		c := t.text
		if tr.counting_in {
			text = fmt.ctprintf("-%d", int(math.ceil(-tr.timeline_beat)))
			c = t.danger
		}
		ui.text_push(.Label)
		ts := im.CalcTextSize(text)
		x1 := o.x + size.x - 14
		x0 := x1 - ts.x - 10
		im.DrawList_AddRectFilled(dl, {x0, o.y + 2}, {x1, o.y + 20}, ui.col(ui.with_alpha(t.bg, 0.9)), 4)
		im.DrawList_AddText(dl, {x0 + 5, o.y + 11 - ts.y / 2}, ui.col(c), text)
		ui.text_pop()
	}
	items := a.ws.toasts.items
	if len(items) == 0 do return
	toast := items[len(items) - 1]
	if toast.age > BANNER_S do return
	fade := clamp((BANNER_S - toast.age) / 0.3, 0, 1) * clamp(toast.age / 0.12, 0, 1)
	c := t.raised
	switch toast.kind {
	case .Info:    c = t.raised
	case .Success: c = t.ok
	case .Warning: c = t.warn
	case .Error:   c = t.danger
	}
	im.PushFontFloat(a.platform.fonts.semibold, 18)
	defer im.PopFont()
	text := fmt.ctprintf("%s", toast.text)
	ts := im.CalcTextSize(text)
	w := min(max(ts.x + 40, 300), size.x - 40)
	x0 := o.x + (size.x - w) / 2
	y0 := o.y + (size.y - 44) / 2
	im.DrawList_AddRectFilled(dl, {x0, y0}, {x0 + w, y0 + 44}, ui.col(ui.with_alpha(ui.mix(t.bg, c, 0.85), 0.96 * fade)), 8)
	im.DrawList_AddRect(dl, {x0, y0}, {x0 + w, y0 + 44}, ui.col(ui.with_alpha(t.text, 0.35 * fade)), 8, 1.5)
	im.DrawList_PushClipRect(dl, {x0 + 12, y0}, {x0 + w - 12, y0 + 44}, true)
	im.DrawList_AddText(dl, {x0 + max((w - ts.x) / 2, 12), y0 + (44 - ts.y) / 2}, ui.col(ui.with_alpha(t.bg if toast.kind != .Info else t.text, fade)), text)
	im.DrawList_PopClipRect(dl)
}

// How long a message shows on a controller's display (seconds).
BANNER_S :: 2.0
