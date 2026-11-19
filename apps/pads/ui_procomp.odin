package pads

import "core:fmt"
import "core:math"
import "core:time"

import "app:ui"
import pa "api"
import pm "model"
import im "deps:imgui"
import fc "fire:core"
import "fire:fx"

// ProComp's device. One picture, the display, is drawn by the window's
// panel and by a controller's display alike, in one of three views: the
// transfer curve with a dot where the level is now, the activity over the
// last four seconds, or the meters alone; the input meter (with the
// threshold's arrow), the gain reduction and the output meter (with the
// output gain's arrow) beside the first two. Around it the window has
// Ratio, Attack and Release at the left, the view, Knee, Lookahead and
// Env under it, Makeup, the mode and Dry/Wet at the right; the
// controller, the views on its upper row and three banks of encoders.

// Names of ProComp's views, modes, lookaheads and key EQ types, as shown.
PC_VIEW_NAMES := []string{"Curve", "Activity", "Meters"}
PC_MODE_NAMES := []string{"Peak", "RMS", "Expand"}
PC_LOOK_NAMES := []string{"0 ms", "1 ms", "10 ms"}
PC_ENV_NAMES := []string{"Lin", "Log"}
PC_EQ_NAMES := []string{"Low-pass", "Band-pass", "High-pass", "Notch", "Peak", "Low Shelf", "High Shelf"}

// The panel's own state, shared by the window and a controller: the view,
// the sidechain row shown, the meters' held peaks.
Pc_Ui :: struct {
	view:     int,  // 0 the curve, 1 the activity, 2 the meters
	key:      bool, // the sidechain's row shown (always while it has a key, its EQ or Listen)
	hold:     [2]f32, // the input's and output's held peaks (dB)
	hold_at:  [2]time.Tick,
	drag:     int, // the arrow dragged: 1 the threshold, 2 the output (0: none)
}

// The meters' range (dB).
@(private) PC_LO :: -60
@(private) PC_HI :: 6

// A setting of ProComp slot `s` (its default when it has none).
@(private)
pc_get :: proc(s: pm.Effect_Slot, id: fc.Param_Id) -> f32 {
	return pm.slot_value(s, id, f32(fx.pro_comp_params[id - 1].default))
}

// ProComp slot `t`'s settings (`s`), with automation where it plays now.
@(private)
pc_values :: proc(a: ^App, t: pm.Fx_Target, s: pm.Effect_Slot) -> (v: fx.Pro_Comp_Values) {
	for p in fx.pro_comp_params {
		live, automated := pm.automated_value(&a.m, fx_auto_target(t, p.id))
		v[p.id] = live if automated else pc_get(s, p.id)
	}
	return
}

// Sets ProComp choice `id` of slot `t` to `v` (one undo step).
@(private)
pc_choose :: proc(a: ^App, t: pm.Fx_Target, id: fc.Param_Id, v: f64) {
	control_effect_param(a, t, i64(id), v, true, true)
}

// How ProComp parameter `id` at `v` reads under its knob.
@(private)
pc_shown :: proc(id: fc.Param_Id, v: f32) -> cstring {
	p := fx.pro_comp_params[id - 1]
	switch id {
	case fx.PC_PARAM_RATIO:
		if v >= fx.PC_RATIO_INF - 0.01 do return "∞ : 1"
		return fmt.ctprintf("%.1f : 1", v)
	case fx.PC_PARAM_EQ_HZ: return fmt.ctprintf("%s", sf_hz(v))
	}
	#partial switch p.unit {
	case .Percent:      return fmt.ctprintf("%.0f %%", v * 100)
	case .Decibels:     return fmt.ctprintf("%+.1f dB" if p.min < 0 && p.max > 0 else "%.1f dB", v)
	case .Milliseconds: return fmt.ctprintf("%.2f ms" if v < 10 else "%.0f ms", v)
	}
	return fmt.ctprintf("%.2f", v)
}

// ProComp parameter `id` of slot `t` (`s`) as a knob at the cursor:
// automatable, undoably (a drag one step).
@(private)
pc_knob :: proc(a: ^App, t: pm.Fx_Target, s: pm.Effect_Slot, id: fc.Param_Id, label: string, size: f32 = ui.KNOB_SIZE) {
	p := fx.pro_comp_params[id - 1]
	v := pc_get(s, id)
	log_scale := p.min > 0 && p.max / p.min >= 50
	knob_target(a, fx_auto_target(t, id))
	e := ui.knob(fmt.ctprintf("%s##pc%d", label, int(id)), &v, f32(p.min), f32(p.max), f32(p.default), "%.2f", size = size, log_scale = log_scale, shown_value = pc_shown(id, v))
	knob_target(a, {})
	control_effect_param(a, t, i64(id), clamp(f64(v), p.min, p.max), e.changed, e.ended)
}

// A level (dB) as a height up a meter from `bottom` to `top`.
@(private)
pc_y :: proc "contextless" (db, top, bottom: f32) -> f32 {
	return bottom - clamp((db - PC_LO) / (PC_HI - PC_LO), 0, 1) * (bottom - top)
}

// A meter from `p0` to `p1`: `peak` and `rms` (dB; rms below -200: none)
// up from the bottom, green to yellow to red, its held peak a line; an
// arrow at `arrow` (dB) on its `side` (−1 left, 1 right, 0 none).
@(private)
pc_meter :: proc(dl: ^im.DrawList, p0, p1: im.Vec2, peak, rms, hold: f32, arrow: f32 = 0, side := 0, arrow_hot := false) {
	th := ui.theme()
	im.DrawList_AddRectFilled(dl, p0, p1, ui.col(ui.mix(ui.PLOT_BG, th.text, 0.07)), 2)
	col :: proc(db: f32) -> ui.Color {
		th := ui.theme()
		if db > -0.5 do return th.danger
		if db > -6 do return th.warn
		return th.ok
	}
	w := p1.x - p0.x
	if rms > -200 do im.DrawList_AddRectFilled(dl, {p0.x, pc_y(rms, p0.y, p1.y)}, p1, ui.col(col(rms)), 2)
	im.DrawList_AddRectFilled(dl, {p0.x + w * 0.25, pc_y(peak, p0.y, p1.y)}, {p1.x - w * 0.25, p1.y}, ui.col(ui.with_alpha(col(peak), 0.55)), 2)
	hy := pc_y(hold, p0.y, p1.y)
	if hold > PC_LO do im.DrawList_AddLine(dl, {p0.x, hy}, {p1.x, hy}, ui.col(col(hold)), 1.5)
	// 0 dB, faint.
	z := pc_y(0, p0.y, p1.y)
	im.DrawList_AddLine(dl, {p0.x, z}, {p1.x, z}, ui.col(ui.with_alpha(th.text, 0.25)), 1)
	if side != 0 {
		ay := pc_y(arrow, p0.y, p1.y)
		x := p1.x + 2 if side > 0 else p0.x - 2
		d: f32 = 9 if side > 0 else -9
		c := th.text if arrow_hot else ui.mix(ui.PLOT_BG, th.text, 0.6)
		im.DrawList_AddTriangleFilled(dl, {x, ay}, {x + d, ay - 6}, {x + d, ay + 6}, ui.col(c))
	}
}

// The input's and output's held peaks: a new peak holds a second, then
// falls.
@(private)
pc_hold :: proc(a: ^App, k: int, db: f32) -> f32 {
	h := &a.pc.hold[k]
	if db >= h^ {
		h^ = db
		a.pc.hold_at[k] = time.tick_now()
	} else if time.duration_seconds(time.tick_since(a.pc.hold_at[k])) > 1 {
		h^ = max(db, h^ - 0.5) // (then falls, half a dB a frame)
	}
	return h^
}

@(private)
pc_db :: proc "contextless" (x: f32) -> f32 { return 20 * math.log10(max(x, 1e-6)) }

// ProComp slot `t`'s display, `size` big, in the panel's view.
// `interactive`: the threshold's and the output's arrows dragged up and
// down (Shift: fine).
@(private)
pc_display :: proc(a: ^App, t: pm.Fx_Target, s: pm.Effect_Slot, size: im.Vec2, interactive: bool) {
	th := ui.theme()
	v := pc_values(a, t, s)
	pos := im.GetCursorScreenPos()
	im.SetNextItemAllowOverlap()
	im.InvisibleButton("##pc display", size)
	ui.name("pc display")
	hovered := im.IsItemHovered()
	dl := im.GetWindowDrawList()
	im.DrawList_AddRectFilled(dl, pos, {pos.x + size.x, pos.y + size.y}, ui.col(ui.PLOT_BG), th.radius)
	st, sr := pa.effect_pro_comp_state(&a.api, slot_ref(t))
	live := sr == .Ok && s.on
	in_pk, in_rms, out_pk := f32(PC_LO - 10), f32(-300), f32(PC_LO - 10)
	if live do in_pk, in_rms, out_pk = pc_db(st.in_peak), pc_db(st.in_rms), pc_db(st.out_peak)
	gr := st.gr_db if live else 0
	in_hold, out_hold := pc_hold(a, 0, in_pk), pc_hold(a, 1, out_pk)
	compact := size.y < 90 // (a controller's short display: no labels, the curve as wide as it can be)
	top, bottom := pos.y + 20, pos.y + size.y - 18
	if compact do top, bottom = pos.y + 4, pos.y + size.y - 4
	thresh := v[fx.PC_PARAM_THRESHOLD_DB]
	out_db := v[fx.PC_PARAM_OUTPUT_DB]
	ui.text_push(.Label)
	defer ui.text_pop()
	label :: proc(dl: ^im.DrawList, x0, x1, y: f32, text: string, c: ui.Color) {
		if c.a == 0 do return
		ct := fmt.ctprintf("%s", text)
		ts := im.CalcTextSize(ct)
		im.DrawList_AddText(dl, {(x0 + x1 - ts.x) / 2, y}, ui.col(c), ct)
	}
	dim := ui.mix(ui.PLOT_BG, th.text, 0.5)
	text_c := th.text
	if compact do dim, text_c = {}, {} // (labels off)
	io := im.GetIO()
	// The meters alone: three, wide.
	if a.pc.view == 2 {
		cw := size.x / 3
		names := [3]string{"Threshold", "GR", "Out"}
		for k in 0 ..< 3 {
			x0 := pos.x + f32(k) * cw + cw * 0.3
			x1 := x0 + cw * 0.4
			label(dl, x0, x1, pos.y + 3, names[k], dim)
			switch k {
			case 0: pc_meter(dl, {x0, top}, {x1, bottom}, in_pk, in_rms, in_hold, thresh, 1, a.pc.drag == 1)
			case 1:
				im.DrawList_AddRectFilled(dl, {x0, top}, {x1, bottom}, ui.col(ui.mix(ui.PLOT_BG, th.text, 0.07)), 2)
				im.DrawList_AddRectFilled(dl, {x0, top}, {x1, top + (bottom - top) * clamp(-gr / 30, 0, 1)}, ui.col(th.accent), 2)
			case 2: pc_meter(dl, {x0, top}, {x1, bottom}, out_pk, -300, out_hold, out_db, -1, a.pc.drag == 2)
			}
		}
		label(dl, pos.x, pos.x + cw, bottom + 2, fmt.tprintf("%.1f dB", thresh), text_c)
		label(dl, pos.x + cw, pos.x + 2 * cw, bottom + 2, fmt.tprintf("%.1f dB", gr), text_c)
		label(dl, pos.x + 2 * cw, pos.x + size.x, bottom + 2, fmt.tprintf("%+.1f dB", out_db), text_c)
		if interactive do pc_arrows(a, t, s, hovered, {pos.x + cw * 0.3, top}, {pos.x + cw * 0.7 + 12, bottom}, {pos.x + 2 * cw + cw * 0.3 - 12, top}, {pos.x + 2 * cw + cw * 0.7, bottom})
		return
	}
	// The input meter (and the threshold's arrow) at the left; GR and the
	// output (its arrow) at the right; the curve or the activity between.
	MW :: 22
	in0 := im.Vec2{pos.x + 10, top}
	in1 := im.Vec2{in0.x + MW, bottom}
	out1 := im.Vec2{pos.x + size.x - 10, bottom}
	out0 := im.Vec2{out1.x - MW, top}
	gr1 := im.Vec2{out0.x - 20, bottom}
	gr0 := im.Vec2{gr1.x - 12, top}
	label(dl, in0.x - 6, in1.x + 14, pos.y + 3, "Thresh", dim)
	label(dl, gr0.x - 4, gr1.x + 4, pos.y + 3, "GR", dim)
	label(dl, out0.x - 10, out1.x, pos.y + 3, "Out", dim)
	pc_meter(dl, in0, in1, in_pk, in_rms, in_hold, thresh, 1, a.pc.drag == 1)
	im.DrawList_AddRectFilled(dl, gr0, gr1, ui.col(ui.mix(ui.PLOT_BG, th.text, 0.07)), 2)
	im.DrawList_AddRectFilled(dl, gr0, {gr1.x, gr0.y + (gr1.y - gr0.y) * clamp(-gr / 30, 0, 1)}, ui.col(th.accent), 2)
	pc_meter(dl, out0, out1, out_pk, -300, out_hold, out_db, -1, a.pc.drag == 2)
	label(dl, in0.x - 14, in1.x + 24, bottom + 2, fmt.tprintf("%.1f dB", thresh), text_c)
	label(dl, out0.x - 20, out1.x + 4, bottom + 2, fmt.tprintf("%+.1f dB", out_db), text_c)
	px0, px1 := in1.x + 24, gr0.x - 14
	grid := ui.mix(ui.PLOT_BG, th.text, 0.07)
	if a.pc.view == 0 {
		// The curve: input across, output up, −60..0, square.
		side := min(px1 - px0, bottom - top)
		cx0 := (px0 + px1 - side) / 2
		c0 := im.Vec2{cx0, bottom - side}
		c1 := im.Vec2{cx0 + side, bottom}
		if compact do c0, c1 = {px0, top}, {px1, bottom}
		at :: proc(db_in, db_out: f32, c0, c1: im.Vec2) -> im.Vec2 {
			return {c0.x + (c1.x - c0.x) * clamp((db_in + 60) / 60, 0, 1), c1.y - (c1.y - c0.y) * clamp((db_out + 60) / 60, 0, 1)}
		}
		for db := f32(-54); db < 0; db += 6 {
			p := at(db, db, c0, c1)
			im.DrawList_AddLine(dl, {p.x, c0.y}, {p.x, c1.y}, ui.col(grid), 1)
			im.DrawList_AddLine(dl, {c0.x, p.y}, {c1.x, p.y}, ui.col(grid), 1)
		}
		im.DrawList_AddRect(dl, c0, c1, ui.col(ui.mix(ui.PLOT_BG, th.text, 0.14)), 0)
		im.DrawList_AddLine(dl, at(-60, -60, c0, c1), at(0, 0, c0, c1), ui.col(ui.mix(ui.PLOT_BG, th.text, 0.12)), 1)
		N :: 96
		pts: [N]im.Vec2
		for k in 0 ..< N {
			x := -60 + 60 * f32(k) / (N - 1)
			pts[k] = at(x, fx.pro_comp_curve(&v, x), c0, c1)
		}
		curve_c := ui.mix(th.text, th.accent, 0.2) if s.on else dim
		im.DrawList_AddPolyline(dl, &pts[0], N, ui.col(curve_c), 2)
		// The threshold's ring; the level now, a dot.
		im.DrawList_AddCircle(dl, at(thresh, fx.pro_comp_curve(&v, thresh), c0, c1), 7, ui.col(th.accent), 20, 1.8)
		if live && st.level_db > -60 do im.DrawList_AddCircleFilled(dl, at(st.level_db, fx.pro_comp_curve(&v, st.level_db), c0, c1), 4.5, ui.col(ui.lighten(th.accent, 0.3)), 16)
	} else {
		// The activity: the last four seconds, right to left.
		M :: 750 // (4 s of 256-frame moments at 48 kHz)
		hist: [M]fx.Pro_Comp_Moment
		if pc := pm.slot_pro_comp(&a.m.engine, t); pc != nil do fx.pro_comp_history(pc, hist[:])
		else do for &h in hist do h = {-80, -80, 0}
		for db := f32(-54); db < 0; db += 6 {
			y := pc_y(db, top, bottom)
			im.DrawList_AddLine(dl, {px0, y}, {px1, y}, ui.col(grid), 1)
		}
		ty := pc_y(thresh, top, bottom)
		im.DrawList_AddLine(dl, {px0, ty}, {px1, ty}, ui.col(ui.with_alpha(th.accent, 0.5)), 1)
		xs := (px1 - px0) / (M - 1)
		aa := dl.Flags
		dl.Flags -= {.AntiAliasedFill}
		for k in 1 ..< M {
			xa, xb := px0 + f32(k - 1) * xs, px0 + f32(k) * xs
			ia, ib := pc_y(hist[k - 1].in_db, top, bottom), pc_y(hist[k].in_db, top, bottom)
			im.DrawList_AddQuadFilled(dl, {xa, bottom}, {xa, ia}, {xb, ib}, {xb, bottom}, ui.col(ui.with_alpha(th.text, 0.14)))
			ga, gb := top + (bottom - top) * clamp(-hist[k - 1].gr_db / 30, 0, 1), top + (bottom - top) * clamp(-hist[k].gr_db / 30, 0, 1)
			im.DrawList_AddQuadFilled(dl, {xa, top}, {xa, ga}, {xb, gb}, {xb, top}, ui.col(ui.with_alpha(th.accent, 0.35)))
		}
		dl.Flags = aa
		outs: [M]im.Vec2
		for h, k in hist do outs[k] = {px0 + f32(k) * xs, pc_y(h.out_db, top, bottom)}
		im.DrawList_AddPolyline(dl, &outs[0], M, ui.col(ui.mix(th.text, th.accent, 0.2)), 1.4)
	}
	if interactive do pc_arrows(a, t, s, hovered, in0, {in1.x + 12, in1.y}, {out0.x - 12, out0.y}, out1)
	_ = io
}

// The threshold's arrow (by the input meter, `i0`..`i1`) and the output's
// (by the output meter, `o0`..`o1`), dragged up and down.
@(private)
pc_arrows :: proc(a: ^App, t: pm.Fx_Target, s: pm.Effect_Slot, hovered: bool, i0, i1, o0, o1: im.Vec2) {
	io := im.GetIO()
	m := io.MousePos
	in_box :: proc(p, b0, b1: im.Vec2) -> bool { return p.x >= b0.x && p.x <= b1.x && p.y >= b0.y - 8 && p.y <= b1.y + 8 }
	if im.IsItemActivated() {
		a.pc.drag = 0
		if in_box(m, i0, i1) do a.pc.drag = 1
		else if in_box(m, o0, o1) do a.pc.drag = 2
	}
	if a.pc.drag > 0 && im.IsItemActive() && io.MouseDelta.y != 0 {
		k: f32 = 0.1 if io.KeyShift else 1
		per := (PC_HI - PC_LO) / (i1.y - i0.y) // dB a point
		if a.pc.drag == 1 {
			v := pc_get(s, fx.PC_PARAM_THRESHOLD_DB) - io.MouseDelta.y * k * per
			control_effect_param(a, t, i64(fx.PC_PARAM_THRESHOLD_DB), f64(clamp(v, -60, 0)), true, false)
		} else {
			v := pc_get(s, fx.PC_PARAM_OUTPUT_DB) - io.MouseDelta.y * k * per
			control_effect_param(a, t, i64(fx.PC_PARAM_OUTPUT_DB), f64(clamp(v, -36, 36)), true, false)
		}
	}
	if im.IsItemDeactivated() {
		if a.pc.drag > 0 do pa.history_gesture_end(&a.api)
		a.pc.drag = 0
	}
	if hovered && a.pc.drag == 0 {
		switch {
		case in_box(m, i0, i1): im.SetTooltip("The threshold: drag up and down (Shift: fine)")
		case in_box(m, o0, o1): im.SetTooltip("The output gain: drag up and down (Shift: fine)")
		}
	}
}

// --- the window ---------------------------------------------------------------------------------

// ProComp's choice of `names` for parameter `id` as a row of toggles
// (`vertical`: one under another), `width` each.
@(private)
pc_toggles :: proc(a: ^App, t: pm.Fx_Target, s: pm.Effect_Slot, id: fc.Param_Id, names: []string, vertical: bool) {
	cur := int(pc_get(s, id) + 0.5)
	for n, k in names {
		if k > 0 && !vertical do im.SameLine(0, 2)
		on := k == cur
		if ui.toggle(fmt.ctprintf("%s##pct%d_%d", n, int(id), k), &on) && k != cur do pc_choose(a, t, id, f64(k))
		ui.name(fmt.tprintf("pc %s %s", fx.pro_comp_params[id - 1].name, n))
	}
}

// ProComp's choices on its slot's header line: the sidechain's row, shown
// or not.
pc_header :: proc(a: ^App, t: pm.Fx_Target, s: pm.Effect_Slot) {
	if t.kind != .Pad && t.kind != .Bus {
		im.Dummy({0, 0})
		return
	}
	chev := ui.ICON_CHEVRON_UP if a.pc.key else ui.ICON_CHEVRON_DOWN
	if !(s.key.kind != .None || s.listen || pc_get(s, fx.PC_PARAM_EQ_ON) >= 0.5) {
		if im.Button(fmt.ctprintf("%s  Sidechain##pckey", chev)) do a.pc.key = !a.pc.key
		ui.name("pc key row")
	} else {
		im.Dummy({0, 0}) // (the line ends here: the row, open, is under it)
	}
}

// Whether ProComp slot `s`'s sidechain row shows.
@(private)
pc_key_shown :: proc(a: ^App, s: pm.Effect_Slot) -> bool {
	return a.pc.key || s.key.kind != .None || s.listen || pc_get(s, fx.PC_PARAM_EQ_ON) >= 0.5
}

// ProComp's sidechain row: its source, its EQ (on, type, Freq, Q, Gain),
// the key's Gain and Mix, Listen.
@(private)
pc_sidechain :: proc(a: ^App, t: pm.Fx_Target, s: pm.Effect_Slot) {
	draw_key_source(a, t, s)
	im.SameLine(0, 12)
	eq := pc_get(s, fx.PC_PARAM_EQ_ON) >= 0.5
	if ui.toggle("EQ##pc", &eq) do pc_choose(a, t, fx.PC_PARAM_EQ_ON, 1 if eq else 0)
	ui.name("pc Key EQ")
	im.SameLine(0, 6)
	im.BeginDisabled(!eq)
	typ := clamp(int(pc_get(s, fx.PC_PARAM_EQ_TYPE) + 0.5), 0, len(PC_EQ_NAMES) - 1)
	im.SetNextItemWidth(110)
	if ui.combo("##pc eq type", fmt.ctprintf("%s", PC_EQ_NAMES[typ])) {
		for n, k in PC_EQ_NAMES {
			if im.Selectable(fmt.ctprintf("%s##pceq%d", n, k), k == typ) && k != typ do pc_choose(a, t, fx.PC_PARAM_EQ_TYPE, f64(k))
			ui.name(fmt.tprintf("pc EQ Type %s", n))
		}
		im.EndCombo()
	}
	ui.name("pc EQ Type")
	im.EndDisabled()
	im.SameLine(0, 12)
	listen := s.listen
	if ui.toggle("Listen##pc", &listen) do pa.effect_set_key_listen(&a.api, slot_ref(t), listen)
	ui.name("pc Listen")
	if im.IsItemHovered() do im.SetTooltip("Hear what it listens to (after the key's EQ), to set it by")
	// Its knobs, a line of their own.
	cells := []struct {id: fc.Param_Id, label: string, off: bool}{
		{fx.PC_PARAM_EQ_HZ, "Freq", !eq}, {fx.PC_PARAM_EQ_Q, "Q", !eq}, {fx.PC_PARAM_EQ_GAIN_DB, "Gain", !eq || typ < 4},
		{fx.PC_PARAM_KEY_GAIN_DB, "Key Gain", false}, {fx.PC_PARAM_KEY_MIX, "Key Mix", s.key.kind == .None},
	}
	for c, k in cells {
		if k > 0 do im.SameLine(0, 18)
		im.BeginDisabled(c.off)
		pc_knob(a, t, s, c.id, c.label, 26)
		im.EndDisabled()
	}
}

// The window's knobs.
@(private) PC_KNOB :: 34

// ProComp's panel in the window (under its slot's header and sidechain
// row): Ratio, Attack, Release and Auto at the left; the display and,
// under it, the view, Knee, Lookahead and Env; Makeup, the mode and
// Dry/Wet at the right.
draw_pro_comp :: proc(a: ^App, t: pm.Fx_Target, s: pm.Effect_Slot) {
	if pc_key_shown(a, s) && (t.kind == .Pad || t.kind == .Bus) do pc_sidechain(a, t, s)
	avail := im.GetContentRegionAvail().x
	LEFT, RIGHT :: 74, 110
	top := im.GetCursorPosY()
	x0 := im.GetCursorPosX()
	im.BeginGroup()
	pc_knob(a, t, s, fx.PC_PARAM_RATIO, "Ratio", 28)
	pc_knob(a, t, s, fx.PC_PARAM_ATTACK_MS, "Attack", 28)
	im.BeginDisabled(pc_get(s, fx.PC_PARAM_AUTO) >= 0.5)
	pc_knob(a, t, s, fx.PC_PARAM_RELEASE_MS, "Release", 28)
	im.EndDisabled()
	im.EndGroup()
	mid_w := avail - LEFT - RIGHT - 16
	im.SetCursorPos({x0 + LEFT + 8, top})
	im.BeginGroup()
	pc_display(a, t, s, {mid_w, 176}, true)
	// The views, small, at the display's top.
	{
		r0, r1 := im.GetItemRectMin(), im.GetItemRectMax()
		keep := im.GetCursorScreenPos()
		ui.text_push(.Label)
		w: f32 = 0
		for n in PC_VIEW_NAMES do w += im.CalcTextSize(fmt.ctprintf("%s", n)).x + 16
		im.SetCursorScreenPos({(r0.x + r1.x - w) / 2, r0.y + 3})
		for n, k in PC_VIEW_NAMES {
			if k > 0 do im.SameLine(0, 4)
			on := a.pc.view == k
			if on do im.PushStyleColorVec4(.Button, transmute(im.Vec4)ui.theme().accent)
			if im.SmallButton(fmt.ctprintf("%s##pcv%d", n, k)) do a.pc.view = k
			if on do im.PopStyleColor()
			ui.name(fmt.tprintf("pc view %s", n))
		}
		ui.text_pop()
		im.SetCursorScreenPos(keep)
	}
	// The strip under it: Knee, Lookahead, Env, the mode.
	{
		@(static) dragging: bool
		@(static) held: f64
		knee := held if dragging else f64(pc_get(s, fx.PC_PARAM_KNEE_DB))
		e := ui.number_drag("pc knee", &knee, 0, 18, 0.1, 1, "Knee %.1f dB", 110)
		dragging, held = e.active && !e.ended, knee
		control_effect_param(a, t, i64(fx.PC_PARAM_KNEE_DB), clamp(knee, 0, 18), e.changed, e.ended)
	}
	im.SameLine(0, 10)
	im.AlignTextToFramePadding()
	im.TextDisabled("Look.")
	im.SameLine(0, 4)
	la := clamp(int(pc_get(s, fx.PC_PARAM_LOOKAHEAD) + 0.5), 0, 2)
	im.SetNextItemWidth(80)
	if ui.combo("##pc look", fmt.ctprintf("%s", PC_LOOK_NAMES[la])) {
		for n, k in PC_LOOK_NAMES {
			if im.Selectable(fmt.ctprintf("%s##pcl%d", n, k), k == la) && k != la do pc_choose(a, t, fx.PC_PARAM_LOOKAHEAD, f64(k))
			ui.name(fmt.tprintf("pc Lookahead %s", n))
		}
		im.EndCombo()
	}
	ui.name("pc Lookahead")
	if im.IsItemHovered() do im.SetTooltip("Lookahead: the detector hears this much early (the sound is as late)")
	im.SameLine(0, 10)
	im.AlignTextToFramePadding()
	im.TextDisabled("Env")
	im.SameLine(0, 4)
	pc_toggles(a, t, s, fx.PC_PARAM_ENV_LOG, PC_ENV_NAMES, false)
	im.SameLine(0, 14)
	pc_toggles(a, t, s, fx.PC_PARAM_MODE, PC_MODE_NAMES, false)
	im.EndGroup()
	// The right column.
	im.SetCursorPos({x0 + avail - RIGHT, top})
	im.BeginGroup()
	mk := pc_get(s, fx.PC_PARAM_MAKEUP) >= 0.5
	if ui.toggle("Makeup##pc", &mk) do pc_choose(a, t, fx.PC_PARAM_MAKEUP, 1 if mk else 0)
	ui.name("pc Makeup")
	if im.IsItemHovered() do im.SetTooltip("Raise the output by what the curve takes off a full-scale level")
	auto := pc_get(s, fx.PC_PARAM_AUTO) >= 0.5
	if ui.toggle("Auto##pc", &auto) do pc_choose(a, t, fx.PC_PARAM_AUTO, 1 if auto else 0)
	ui.name("pc Auto")
	if im.IsItemHovered() do im.SetTooltip("Auto release: quick after a short peak, slow after a long squeeze")
	im.Dummy({1, 12})
	pc_knob(a, t, s, fx.PC_PARAM_MIX, "Dry/Wet", PC_KNOB)
	im.EndGroup()
}

// --- a controller's display ---------------------------------------------------------------------

// ProComp on a controller's display: its views on the upper row, the
// display over three banks of encoders (Main, Detail, Sidechain).
@(private)
ctl_pro_comp :: proc(ctx: ^View_Ctx, t: pm.Fx_Target, s: pm.Effect_Slot, plot, full: im.Vec2) {
	a := ctx.a
	p := &a.m.project
	for n, k in PC_VIEW_NAMES {
		ctl_upper(ctx, k, n, a.pc.view == k)
		b := int(pa.View_Button.Upper_1) + k
		if ctx.input != nil && ctx.input.pressed[b] do a.pc.view = k
	}
	im.SetCursorPos({0, CTL_PLOT_Y})
	pc_display(a, t, s, plot, false)
	ctx.banks[0], ctx.banks[1], ctx.banks[2] = "Main", "Detail", "Sidechain"
	N :: 24
	knob :: proc(ctx: ^View_Ctx, n: int, t: pm.Fx_Target, s: pm.Effect_Slot, id: fc.Param_Id, label: string, plot: im.Vec2) {
		if ctl_knob(ctx, n, N, fmt.ctprintf("%s##pc%d", label, int(id)), plot) do pc_knob(ctx.a, t, s, id, label)
	}
	choice :: proc(ctx: ^View_Ctx, n: int, t: pm.Fx_Target, s: pm.Effect_Slot, id: fc.Param_Id, label: string, names: []string, plot: im.Vec2) {
		cur := int(pc_get(s, id) + 0.5)
		if k, _ := ctl_choice(ctx, n, N, fmt.ctprintf("%s##pc%d", label, int(id)), names, cur, plot); k >= 0 do pc_choose(ctx.a, t, id, f64(k))
	}
	// Main.
	knob(ctx, 0, t, s, fx.PC_PARAM_THRESHOLD_DB, "Threshold", plot)
	knob(ctx, 1, t, s, fx.PC_PARAM_RATIO, "Ratio", plot)
	knob(ctx, 2, t, s, fx.PC_PARAM_ATTACK_MS, "Attack", plot)
	knob(ctx, 3, t, s, fx.PC_PARAM_RELEASE_MS, "Release", plot)
	knob(ctx, 4, t, s, fx.PC_PARAM_KNEE_DB, "Knee", plot)
	choice(ctx, 5, t, s, fx.PC_PARAM_MAKEUP, "Makeup", OFF_ON, plot)
	knob(ctx, 6, t, s, fx.PC_PARAM_OUTPUT_DB, "Output", plot)
	knob(ctx, 7, t, s, fx.PC_PARAM_MIX, "Dry/Wet", plot)
	// Detail.
	choice(ctx, 8, t, s, fx.PC_PARAM_MODE, "Mode", PC_MODE_NAMES, plot)
	choice(ctx, 9, t, s, fx.PC_PARAM_AUTO, "Auto", OFF_ON, plot)
	choice(ctx, 10, t, s, fx.PC_PARAM_LOOKAHEAD, "Lookahead", PC_LOOK_NAMES, plot)
	choice(ctx, 11, t, s, fx.PC_PARAM_ENV_LOG, "Env", PC_ENV_NAMES, plot)
	if k, _ := ctl_choice(ctx, 12, N, "View##pcview", PC_VIEW_NAMES, a.pc.view, plot); k >= 0 do a.pc.view = k
	knob(ctx, 13, t, s, fx.PC_PARAM_KEY_MIX, "Key Mix", plot)
	// Sidechain: its key (itself, a pad or a bus), its EQ, Listen.
	if t.kind == .Pad || t.kind == .Bus {
		keys := make([dynamic]pm.Key_Source, context.temp_allocator)
		names := make([dynamic]string, context.temp_allocator)
		append(&keys, pm.Key_Source{})
		append(&names, "Itself")
		for i in 0 ..< pm.PADS do if pm.pad_used(p, i) && pm.key_allowed(p, t, {.Pad, i}) {
			append(&keys, pm.Key_Source{.Pad, i})
			append(&names, fmt.tprintf("Pad %s", pm.pad_label(i)))
		}
		for b in 0 ..< p.bus_count do if pm.key_allowed(p, t, {.Bus, b}) {
			append(&keys, pm.Key_Source{.Bus, b})
			append(&names, pm.bus_index_name(p, b))
		}
		cur := 0
		for k, i in keys do if k == s.key do cur = i
		if k, _ := ctl_choice(ctx, 16, N, "Source##pckey", names[:], cur, plot); k >= 0 {
			pa.effect_set_key(&a.api, slot_ref(t), pa.Key_Kind(keys[k].kind), i64(keys[k].index))
		}
	}
	choice(ctx, 17, t, s, fx.PC_PARAM_EQ_ON, "EQ", OFF_ON, plot)
	choice(ctx, 18, t, s, fx.PC_PARAM_EQ_TYPE, "EQ Type", PC_EQ_NAMES, plot)
	knob(ctx, 19, t, s, fx.PC_PARAM_EQ_HZ, "EQ Freq", plot)
	knob(ctx, 20, t, s, fx.PC_PARAM_EQ_Q, "EQ Q", plot)
	knob(ctx, 21, t, s, fx.PC_PARAM_EQ_GAIN_DB, "EQ Gain", plot)
	knob(ctx, 22, t, s, fx.PC_PARAM_KEY_GAIN_DB, "Key Gain", plot)
	if t.kind == .Pad || t.kind == .Bus {
		if k, _ := ctl_choice(ctx, 23, N, "Listen##pclisten", OFF_ON, 1 if s.listen else 0, plot); k >= 0 do pa.effect_set_key_listen(&a.api, slot_ref(t), k == 1)
	}
	_ = full
}
