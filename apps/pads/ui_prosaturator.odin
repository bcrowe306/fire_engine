package pads

import "core:fmt"
import "core:time"

import "app:ui"
import pa "api"
import pm "model"
import im "deps:imgui"
import fc "fire:core"
import "fire:fx"

// ProSaturator's device. One picture, the display, is drawn by the window's
// panel and by a controller's display alike: the curve (steepening with
// Drive) with the signal moving along it, the harmonics it adds, Color's
// EQ faint behind, the levels in and out at the edges. Around it the window
// has Drive, DC and Color at the left, Type and Quality under it (and
// Color's and the Waveshaper's knobs when they apply), Soft Clip, Output
// and Dry/Wet at the right; the controller, three banks of encoders.

// Names of ProSaturator's types and qualities, as shown.
PS_TYPE_NAMES := []string{"Analog Clip", "Soft Sine", "Bass Shaper", "Medium Curve", "Hard Curve", "Sinoid Fold", "Digital Clip", "Tube", "Tape", "Waveshaper"}
PS_QUALITY_NAMES := []string{"Off", "2×", "4×"}

// The panel's own state: the meters' held peaks.
Ps_Ui :: struct {
	hold:    [2]f32,
	hold_at: [2]time.Tick,
}

// A setting of ProSaturator slot `s` (its default when it has none).
@(private)
ps_get :: proc(s: pm.Effect_Slot, id: fc.Param_Id) -> f32 {
	return pm.slot_value(s, id, f32(fx.pro_saturator_params[id - 1].default))
}

// ProSaturator slot `s`'s type.
@(private)
ps_type :: proc(s: pm.Effect_Slot) -> fx.Pro_Saturator_Type {
	return fx.Pro_Saturator_Type(clamp(int(ps_get(s, fx.PS_PARAM_TYPE) + 0.5), 0, len(fx.Pro_Saturator_Type) - 1))
}

// ProSaturator slot `t`'s settings (`s`), with automation where it plays now.
@(private)
ps_values :: proc(a: ^App, t: pm.Fx_Target, s: pm.Effect_Slot) -> (v: fx.Pro_Saturator_Values) {
	for p in fx.pro_saturator_params {
		live, automated := pm.automated_value(&a.m, fx_auto_target(t, p.id))
		v[p.id] = live if automated else ps_get(s, p.id)
	}
	return
}

// Sets ProSaturator choice `id` of slot `t` to `v` (one undo step).
@(private)
ps_choose :: proc(a: ^App, t: pm.Fx_Target, id: fc.Param_Id, v: f64) {
	control_effect_param(a, t, i64(id), v, true, true)
}

// How ProSaturator parameter `id` at `v` reads under its knob.
@(private)
ps_shown :: proc(id: fc.Param_Id, v: f32) -> cstring {
	p := fx.pro_saturator_params[id - 1]
	#partial switch p.unit {
	case .Hertz:    return fmt.ctprintf("%s", sf_hz(v))
	case .Decibels: return fmt.ctprintf("%+.1f dB", v)
	case .Percent:  return fmt.ctprintf("%.0f %%", v * 100)
	}
	return fmt.ctprintf("%+.2f" if p.min < 0 else "%.2f", v)
}

// ProSaturator parameter `id` of slot `t` (`s`) as a knob at the cursor:
// automatable, undoably (a drag one step).
@(private)
ps_knob :: proc(a: ^App, t: pm.Fx_Target, s: pm.Effect_Slot, id: fc.Param_Id, label: string, size: f32 = ui.KNOB_SIZE) {
	p := fx.pro_saturator_params[id - 1]
	v := ps_get(s, id)
	log_scale := p.unit == .Hertz
	knob_target(a, fx_auto_target(t, id))
	e := ui.knob(fmt.ctprintf("%s##ps%d", label, int(id)), &v, f32(p.min), f32(p.max), f32(p.default), "%.2f", size = size, log_scale = log_scale, shown_value = ps_shown(id, v))
	knob_target(a, {})
	control_effect_param(a, t, i64(id), clamp(f64(v), p.min, p.max), e.changed, e.ended)
}

// A held peak (dB): a new peak holds a second, then falls.
@(private)
ps_hold :: proc(a: ^App, k: int, db: f32) -> f32 {
	h := &a.ps.hold[k]
	if db >= h^ {
		h^ = db
		a.ps.hold_at[k] = time.tick_now()
	} else if time.duration_seconds(time.tick_since(a.ps.hold_at[k])) > 1 {
		h^ = max(db, h^ - 0.5)
	}
	return h^
}

// ProSaturator slot `t`'s display, `size` big.
@(private)
ps_display :: proc(a: ^App, t: pm.Fx_Target, s: pm.Effect_Slot, size: im.Vec2) {
	th := ui.theme()
	v := ps_values(a, t, s)
	sr := a.host.graph.settings.sample_rate if a.host.graph.settings.sample_rate > 0 else 48_000
	pos := im.GetCursorScreenPos()
	im.Dummy(size)
	ui.name("ps display")
	dl := im.GetWindowDrawList()
	im.DrawList_AddRectFilled(dl, pos, {pos.x + size.x, pos.y + size.y}, ui.col(ui.PLOT_BG), th.radius)
	compact := size.y < 90
	top, bottom := pos.y + 6, pos.y + size.y - 6
	ps := pm.slot_pro_saturator(&a.m.engine, t)
	st, sr2 := pa.effect_pro_saturator_state(&a.api, slot_ref(t))
	live := sr2 == .Ok && s.on && ps != nil
	in_db, out_db := f32(PC_LO - 10), f32(PC_LO - 10)
	if live do in_db, out_db = pc_db(st.in_peak), pc_db(st.out_peak)
	MW :: 12
	pc_meter(dl, {pos.x + 8, top}, {pos.x + 8 + MW, bottom}, in_db, -300, ps_hold(a, 0, in_db))
	pc_meter(dl, {pos.x + size.x - 8 - MW, top}, {pos.x + size.x - 8, bottom}, out_db, -300, ps_hold(a, 1, out_db))
	x0, x1 := pos.x + 8 + MW + 10, pos.x + size.x - 8 - MW - 10
	// Color's EQ, faint, across (±12 dB about the lower part's middle).
	if v[fx.PS_PARAM_COLOR] >= 0.5 {
		N :: 96
		pts: [N]im.Vec2
		mid := bottom - (bottom - top) * 0.3
		half := (bottom - top) * 0.25
		for k in 0 ..< N {
			hz := ui.x_freq(f32(k) / (N - 1))
			db := fx.pro_saturator_color_response(&v, f64(hz), sr)
			pts[k] = {x0 + (x1 - x0) * f32(k) / (N - 1), mid - clamp(db / 12, -1, 1) * half}
		}
		im.DrawList_AddLine(dl, {x0, mid}, {x1, mid}, ui.col(ui.mix(ui.PLOT_BG, th.text, 0.08)), 1)
		im.DrawList_AddPolyline(dl, &pts[0], N, ui.col(ui.with_alpha(th.warn, 0.45)), 1.5)
	}
	// The curve: a square at the left (on a short display, as wide as it can be).
	side := min(bottom - top, (x1 - x0) * 0.55)
	c0 := im.Vec2{x0, top}
	c1 := im.Vec2{x0 + side, top + side}
	if compact do c1 = {x0 + (x1 - x0) * 0.6, bottom}
	at :: proc(x, y: f32, c0, c1: im.Vec2) -> im.Vec2 {
		R :: 1.25
		return {c0.x + (c1.x - c0.x) * (clamp(x, -R, R) + R) / (2 * R), c1.y - (c1.y - c0.y) * (clamp(y, -R, R) + R) / (2 * R)}
	}
	grid := ui.mix(ui.PLOT_BG, th.text, 0.08)
	for q in ([]f32{-1, -0.5, 0, 0.5, 1}) {
		a0, a1 := at(q, -1.25, c0, c1), at(q, 1.25, c0, c1)
		b0, b1 := at(-1.25, q, c0, c1), at(1.25, q, c0, c1)
		g := ui.mix(ui.PLOT_BG, th.text, 0.16) if q == 0 else grid
		im.DrawList_AddLine(dl, a0, a1, ui.col(g), 1)
		im.DrawList_AddLine(dl, b0, b1, ui.col(g), 1)
	}
	im.DrawList_AddRect(dl, c0, c1, ui.col(ui.mix(ui.PLOT_BG, th.text, 0.14)), 0)
	{
		N :: 128
		pts: [N]im.Vec2
		for k in 0 ..< N {
			x := -1.25 + 2.5 * f32(k) / (N - 1)
			pts[k] = at(x, fx.pro_saturator_curve(&v, x), c0, c1)
		}
		cc := ui.mix(th.text, th.accent, 0.2) if s.on else ui.mix(ui.PLOT_BG, th.text, 0.45)
		im.DrawList_AddPolyline(dl, &pts[0], N, ui.col(cc), 2)
	}
	// The signal on it: its last points, the newest brightest.
	if live {
		M :: 96
		sig: [M]f32
		fx.pro_saturator_signal(ps, sig[:])
		for x, k in sig {
			f := f32(k + 1) / M
			im.DrawList_AddCircleFilled(dl, at(x, fx.pro_saturator_curve(&v, x), c0, c1), 1.5 + 2 * f, ui.col(ui.with_alpha(ui.lighten(th.accent, 0.3), 0.08 + 0.6 * f * f)), 8)
		}
	}
	// The harmonics: eight bars, the output's (the input's a line on each).
	h0 := c1.x + 14
	if h0 < x1 - 40 {
		hw := (x1 - h0) / fx_harmonics_cols
		inh, outh: [pm.PS_HARMONICS]f32
		ok := false
		if live do inh, outh, ok = pm.pro_saturator_harmonics(ps, sr)
		ui.text_push(.Label)
		defer ui.text_pop()
		lh := im.GetTextLineHeight()
		hb := bottom - (0 if compact else lh + 2)
		if !compact do im.DrawList_AddText(dl, {h0, top}, ui.col(ui.mix(ui.PLOT_BG, th.text, 0.45)), "Harmonics")
		ht := top + (0 if compact else lh + 4)
		ybar :: proc(db, top, bottom: f32) -> f32 { return bottom - clamp((db + 60) / 60, 0, 1) * (bottom - top) }
		for k in 0 ..< pm.PS_HARMONICS {
			bx0 := h0 + f32(k) * hw + 2
			bx1 := bx0 + hw - 4
			im.DrawList_AddRectFilled(dl, {bx0, ht}, {bx1, hb}, ui.col(ui.mix(ui.PLOT_BG, th.text, 0.05)), 2)
			if ok {
				im.DrawList_AddRectFilled(dl, {bx0, ybar(outh[k], ht, hb)}, {bx1, hb}, ui.col(th.accent if k > 0 else ui.mix(th.text, th.accent, 0.3)), 2)
				y := ybar(inh[k], ht, hb)
				im.DrawList_AddLine(dl, {bx0, y}, {bx1, y}, ui.col(ui.with_alpha(th.text, 0.6)), 1.5)
			}
			if !compact {
				n := fmt.ctprintf("%d", k + 1)
				ts := im.CalcTextSize(n)
				im.DrawList_AddText(dl, {(bx0 + bx1 - ts.x) / 2, hb + 1}, ui.col(ui.mix(ui.PLOT_BG, th.text, 0.4)), n)
			}
		}
	}
	// What it is, top left of the curve (in the window).
	if !compact {
		ui.text_push(.Label)
		im.DrawList_AddText(dl, {c0.x + 4, c0.y + 2}, ui.col(ui.with_alpha(th.text, 0.6)), fmt.ctprintf("%s  %+.1f dB", PS_TYPE_NAMES[int(ps_type(s))], v[fx.PS_PARAM_DRIVE_DB]))
		ui.text_pop()
	}
}

// The harmonics' columns (eight bars).
@(private) fx_harmonics_cols :: f32(pm.PS_HARMONICS)

// --- the window ---------------------------------------------------------------------------------

// The window's knobs.
@(private) PS_KNOB :: 32

// A dropdown of ProSaturator choice `id` (its `names`), `width` wide.
@(private)
ps_combo :: proc(a: ^App, t: pm.Fx_Target, s: pm.Effect_Slot, id: fc.Param_Id, names: []string, width: f32) {
	cur := clamp(int(ps_get(s, id) + 0.5), 0, len(names) - 1)
	im.SetNextItemWidth(width)
	pname := fx.pro_saturator_params[id - 1].name
	if ui.combo(fmt.ctprintf("##ps%d", int(id)), fmt.ctprintf("%s", names[cur]), {.HeightLarge}) { // (all ten types in sight)
		for n, k in names {
			if im.Selectable(fmt.ctprintf("%s##psc%d", n, k), k == cur) && k != cur do ps_choose(a, t, id, f64(k))
			ui.name(fmt.tprintf("ps %s %s", pname, n))
		}
		im.EndCombo()
	}
	ui.name(fmt.tprintf("ps %s", pname))
}

// ProSaturator's panel in the window: Drive, DC and Color at the left; the
// display, Type and Quality under it, and Color's knobs (Color on) and the
// Waveshaper's (its type) under those; Soft Clip, Output and Dry/Wet at
// the right.
draw_pro_saturator :: proc(a: ^App, t: pm.Fx_Target, s: pm.Effect_Slot) {
	avail := im.GetContentRegionAvail().x
	LEFT, RIGHT :: 80, 96
	top := im.GetCursorPosY()
	x0 := im.GetCursorPosX()
	im.BeginGroup()
	ps_knob(a, t, s, fx.PS_PARAM_DRIVE_DB, "Drive", PS_KNOB + 4)
	dc := ps_get(s, fx.PS_PARAM_DC) >= 0.5
	if ui.toggle("DC##ps", &dc) do ps_choose(a, t, fx.PS_PARAM_DC, 1 if dc else 0)
	ui.name("ps DC")
	if im.IsItemHovered() do im.SetTooltip("Take out the offset an asymmetric curve leaves (a 10 Hz high-pass)")
	color := ps_get(s, fx.PS_PARAM_COLOR) >= 0.5
	if ui.toggle("Color##ps", &color) do ps_choose(a, t, fx.PS_PARAM_COLOR, 1 if color else 0)
	ui.name("ps Color")
	if im.IsItemHovered() do im.SetTooltip("An EQ before the curve and its opposite after: which frequencies saturate")
	im.EndGroup()
	mid_w := avail - LEFT - RIGHT - 16
	im.SetCursorPos({x0 + LEFT + 8, top})
	im.BeginGroup()
	ps_display(a, t, s, {mid_w, 128})
	im.AlignTextToFramePadding()
	im.TextDisabled("Type")
	im.SameLine(0, 6)
	ps_combo(a, t, s, fx.PS_PARAM_TYPE, PS_TYPE_NAMES, 160)
	im.SameLine(0, 16)
	im.AlignTextToFramePadding()
	im.TextDisabled("Quality")
	im.SameLine(0, 6)
	ps_combo(a, t, s, fx.PS_PARAM_QUALITY, PS_QUALITY_NAMES, 70)
	if im.IsItemHovered() do im.SetTooltip("Oversampling: less aliasing when driven hard, a little latency, more work")
	row :: proc(a: ^App, t: pm.Fx_Target, s: pm.Effect_Slot, cells: []struct {id: fc.Param_Id, label: string}) {
		for c, k in cells {
			if k > 0 do im.SameLine(0, 14)
			ps_knob(a, t, s, c.id, c.label, 26)
		}
	}
	if color do row(a, t, s, {{fx.PS_PARAM_BASE, "Base"}, {fx.PS_PARAM_FREQ_HZ, "Freq"}, {fx.PS_PARAM_WIDTH, "Width"}, {fx.PS_PARAM_DEPTH, "Depth"}})
	if ps_type(s) == .Waveshaper {
		row(a, t, s, {{fx.PS_PARAM_WS_DRIVE, "WS Drive"}, {fx.PS_PARAM_WS_LIN, "Lin"}, {fx.PS_PARAM_WS_CURVE, "Curve"}, {fx.PS_PARAM_WS_DAMP, "Damp"}, {fx.PS_PARAM_WS_DEPTH, "WS Depth"}, {fx.PS_PARAM_WS_PERIOD, "Period"}})
	}
	im.EndGroup()
	im.SetCursorPos({x0 + avail - RIGHT, top})
	im.BeginGroup()
	soft := ps_get(s, fx.PS_PARAM_SOFT_CLIP) >= 0.5
	if ui.toggle("Soft Clip##ps", &soft) do ps_choose(a, t, fx.PS_PARAM_SOFT_CLIP, 1 if soft else 0)
	ui.name("ps Soft Clip")
	if im.IsItemHovered() do im.SetTooltip("A gentle clip at the end: never past full scale")
	ps_knob(a, t, s, fx.PS_PARAM_OUTPUT_DB, "Output", PS_KNOB)
	ps_knob(a, t, s, fx.PS_PARAM_MIX, "Dry/Wet", PS_KNOB)
	im.EndGroup()
}

// --- a controller's display ---------------------------------------------------------------------

// ProSaturator on a controller's display: the display over three banks of
// encoders (Main, Color, Waveshaper).
@(private)
ctl_pro_saturator :: proc(ctx: ^View_Ctx, t: pm.Fx_Target, s: pm.Effect_Slot, plot, full: im.Vec2) {
	a := ctx.a
	ps_display(a, t, s, plot)
	ctx.banks[0], ctx.banks[1], ctx.banks[2] = "Main", "Color", "Waveshaper"
	N :: 24
	knob :: proc(ctx: ^View_Ctx, n: int, t: pm.Fx_Target, s: pm.Effect_Slot, id: fc.Param_Id, label: string, plot: im.Vec2) {
		if ctl_knob(ctx, n, N, fmt.ctprintf("%s##ps%d", label, int(id)), plot) do ps_knob(ctx.a, t, s, id, label)
	}
	choice :: proc(ctx: ^View_Ctx, n: int, t: pm.Fx_Target, s: pm.Effect_Slot, id: fc.Param_Id, label: string, names: []string, plot: im.Vec2) {
		cur := int(ps_get(s, id) + 0.5)
		if k, _ := ctl_choice(ctx, n, N, fmt.ctprintf("%s##ps%d", label, int(id)), names, cur, plot); k >= 0 do ps_choose(ctx.a, t, id, f64(k))
	}
	// Main.
	knob(ctx, 0, t, s, fx.PS_PARAM_DRIVE_DB, "Drive", plot)
	choice(ctx, 1, t, s, fx.PS_PARAM_TYPE, "Type", PS_TYPE_NAMES, plot)
	knob(ctx, 2, t, s, fx.PS_PARAM_OUTPUT_DB, "Output", plot)
	knob(ctx, 3, t, s, fx.PS_PARAM_MIX, "Dry/Wet", plot)
	choice(ctx, 4, t, s, fx.PS_PARAM_SOFT_CLIP, "Soft Clip", OFF_ON, plot)
	choice(ctx, 5, t, s, fx.PS_PARAM_DC, "DC", OFF_ON, plot)
	choice(ctx, 6, t, s, fx.PS_PARAM_COLOR, "Color", OFF_ON, plot)
	choice(ctx, 7, t, s, fx.PS_PARAM_QUALITY, "Quality", PS_QUALITY_NAMES, plot)
	// Color.
	color := ps_get(s, fx.PS_PARAM_COLOR) >= 0.5
	knob(ctx, 8, t, s, fx.PS_PARAM_BASE, "Base" if color else "(Base)", plot)
	knob(ctx, 9, t, s, fx.PS_PARAM_FREQ_HZ, "Freq" if color else "(Freq)", plot)
	knob(ctx, 10, t, s, fx.PS_PARAM_WIDTH, "Width" if color else "(Width)", plot)
	knob(ctx, 11, t, s, fx.PS_PARAM_DEPTH, "Depth" if color else "(Depth)", plot)
	// Waveshaper (its type's own knobs).
	ws := ps_type(s) == .Waveshaper
	knob(ctx, 16, t, s, fx.PS_PARAM_WS_DRIVE, "WS Drive" if ws else "(WS Drive)", plot)
	knob(ctx, 17, t, s, fx.PS_PARAM_WS_LIN, "Lin" if ws else "(Lin)", plot)
	knob(ctx, 18, t, s, fx.PS_PARAM_WS_CURVE, "Curve" if ws else "(Curve)", plot)
	knob(ctx, 19, t, s, fx.PS_PARAM_WS_DAMP, "Damp" if ws else "(Damp)", plot)
	knob(ctx, 20, t, s, fx.PS_PARAM_WS_DEPTH, "WS Depth" if ws else "(WS Depth)", plot)
	knob(ctx, 21, t, s, fx.PS_PARAM_WS_PERIOD, "Period" if ws else "(Period)", plot)
	_ = full
}
