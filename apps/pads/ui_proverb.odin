package pads

import "core:fmt"
import "core:math"

import "app:ui"
import pa "api"
import pm "model"
import im "deps:imgui"
import fc "fire:core"
import "fire:fx"

// ProVerb's device. Its pictures are its own: the early reflections
// (spikes on a time line, the predelay a gap before them) and the damping
// curve (RT60 against frequency, with handles for the bass and treble
// multipliers and crossovers and the High Cut). The window shows both
// over its bars and pages; a controller one large, picked on its upper
// row.

// Names of ProVerb's modes and qualities, as shown (our own).
PV_MODE_NAMES := []string{"Big Room", "Mid Room", "Bright Room", "Wide Chamber", "Dark Room", "Close Room", "Long Hall", "Tight Space", "Soft Space", "Grand Hall", "Small Space", "Wide Space"}
PV_QUALITY_NAMES := []string{"Eco", "Normal", "High"}
PV_FOCUS_NAMES := []string{"Early", "Damping"}

// The panel's own state, shared by the window and a controller: the knobs'
// page, the picture a controller shows large, the handle dragged.
Pv_Ui :: struct {
	page:  int, // 0 Early, 1 Late
	focus: int, // 0 Early, 1 Damping (a controller's)
	drag:  int, // the damping handle dragged: 1 bass, 2 treble, 3 High Cut (0: none)
}

// A setting of ProVerb slot `s` (its default when it has none).
@(private)
pv_get :: proc(s: pm.Effect_Slot, id: fc.Param_Id) -> f32 {
	return pm.slot_value(s, id, f32(fx.proverb_params[id - 1].default))
}

// ProVerb slot `t`'s settings (`s`), with automation where it plays now.
@(private)
pv_values :: proc(a: ^App, t: pm.Fx_Target, s: pm.Effect_Slot) -> (v: fx.Proverb_Values) {
	for p in fx.proverb_params {
		live, automated := pm.automated_value(&a.m, fx_auto_target(t, p.id))
		v[p.id] = live if automated else pv_get(s, p.id)
	}
	return
}

// Whether ProVerb parameter `p` moves on a log scale.
@(private)
pv_log :: proc(p: fc.Param_Info) -> bool { return p.min > 0 && p.max / p.min >= 50 }

// How ProVerb parameter `id` at `v` reads.
@(private)
pv_shown :: proc(id: fc.Param_Id, v: f32) -> cstring {
	p := fx.proverb_params[id - 1]
	switch id {
	case fx.PV_PARAM_DECAY_S:
		return fmt.ctprintf("%.2f s" if v < 10 else "%.1f s", v)
	case fx.PV_PARAM_BASS_MULT, fx.PV_PARAM_HIGH_MULT:
		return fmt.ctprintf("%.2f ×", v)
	}
	#partial switch p.unit {
	case .Hertz:        return fmt.ctprintf("%.2f Hz", v) if v < 10 else fmt.ctprintf("%s", sf_hz(v))
	case .Milliseconds: return fmt.ctprintf("%.1f ms", v)
	case .Percent:      return fmt.ctprintf("%.0f %%", v * 100)
	}
	return fmt.ctprintf("%.2f", v)
}

// ProVerb parameter `id` of slot `t` (`s`) as a knob at the cursor.
@(private)
pv_knob :: proc(a: ^App, t: pm.Fx_Target, s: pm.Effect_Slot, id: fc.Param_Id, label: string, size: f32 = ui.KNOB_SIZE) {
	p := fx.proverb_params[id - 1]
	v := pv_get(s, id)
	knob_target(a, fx_auto_target(t, id))
	e := ui.knob(fmt.ctprintf("%s##pv%d", label, int(id)), &v, f32(p.min), f32(p.max), f32(p.default), "%.2f", size = size, log_scale = pv_log(p), shown_value = pv_shown(id, v))
	knob_target(a, {})
	control_effect_param(a, t, i64(id), clamp(f64(v), p.min, p.max), e.changed, e.ended)
}

// A value of parameter `p` as 0..1 along its control (log where it is).
@(private)
pv_norm :: proc(p: fc.Param_Info, v: f32) -> f32 {
	if pv_log(p) do return f32(math.log2(f64(v) / p.min) / math.log2(p.max / p.min))
	return f32((f64(v) - p.min) / (p.max - p.min))
}

// And back.
@(private)
pv_denorm :: proc(p: fc.Param_Info, x: f32) -> f32 {
	u := clamp(x, 0, 1)
	if pv_log(p) do return f32(p.min * math.pow(p.max / p.min, f64(u)))
	return f32(p.min + (p.max - p.min) * f64(u))
}

// ProVerb parameter `id` as a tall bar, `size` big: drag up and down
// (Shift: fine), double-click for its default.
@(private)
pv_bar :: proc(a: ^App, t: pm.Fx_Target, s: pm.Effect_Slot, id: fc.Param_Id, label: string, size: im.Vec2) {
	th := ui.theme()
	p := fx.proverb_params[id - 1]
	v := pv_get(s, id)
	dl := im.GetWindowDrawList()
	im.BeginGroup()
	ui.text_push(.Label)
	lc := fmt.ctprintf("%s", label)
	ts := im.CalcTextSize(lc)
	pos := im.GetCursorScreenPos()
	im.DrawList_AddText(dl, {pos.x + (size.x - ts.x) / 2, pos.y}, ui.col(th.text_dim), lc)
	im.Dummy({size.x, ts.y + 2})
	b0 := im.GetCursorScreenPos()
	im.InvisibleButton(fmt.ctprintf("##pvbar%d", int(id)), size)
	ui.name(fmt.tprintf("pv bar %s", label))
	b1 := im.Vec2{b0.x + size.x, b0.y + size.y}
	x := pv_norm(p, v)
	im.DrawList_AddRectFilled(dl, b0, b1, ui.col(ui.mix(ui.PLOT_BG, th.text, 0.08)), th.radius)
	top := b1.y - (b1.y - b0.y) * x
	im.DrawList_AddRectFilled(dl, {b0.x, top}, b1, ui.col(ui.with_alpha(th.accent, 0.55)), th.radius)
	im.DrawList_AddRectFilled(dl, {b0.x, top}, {b1.x, min(top + 4, b1.y)}, ui.col(th.accent))
	io := im.GetIO()
	if im.IsItemActive() && io.MouseDelta.y != 0 {
		k: f32 = 0.1 if io.KeyShift else 1
		control_effect_param(a, t, i64(id), f64(pv_denorm(p, x - io.MouseDelta.y * k / size.y)), true, false)
	}
	if im.IsItemDeactivated() do pa.history_gesture_end(&a.api)
	if im.IsItemHovered() && im.IsMouseDoubleClicked(.Left) do control_effect_param(a, t, i64(id), p.default, true, true)
	vc := pv_shown(id, v)
	vs := im.CalcTextSize(vc)
	im.Dummy({size.x, 2})
	vp := im.GetCursorScreenPos()
	im.DrawList_AddText(dl, {vp.x + (size.x - vs.x) / 2, vp.y}, ui.col(th.text), vc)
	im.Dummy({size.x, vs.y})
	ui.text_pop()
	im.EndGroup()
}

// ProVerb slot `t`'s display, `size` big. `focus` −1: both pictures side
// by side (the window's); 0 or 1: that one alone (a controller's).
// `interactive`: the damping curve's handles dragged.
@(private)
pv_display :: proc(a: ^App, t: pm.Fx_Target, s: pm.Effect_Slot, size: im.Vec2, focus: int, interactive: bool) {
	th := ui.theme()
	v := pv_values(a, t, s)
	sr := a.host.graph.settings.sample_rate if a.host.graph.settings.sample_rate > 0 else 48_000
	pos := im.GetCursorScreenPos()
	dl := im.GetWindowDrawList()
	compact := size.y < 90
	gap: f32 = 6
	parts: [3][2]f32 // x0, x1 of each picture (0 width: not shown): [1] the early, [2] the damping
	if focus < 0 {
		w := size.x - gap
		parts[1], parts[2] = {0, w * 0.45}, {w * 0.45 + gap, size.x}
	} else {
		parts[1 + clamp(focus, 0, 1)] = {0, size.x}
	}
	ui.text_push(.Label)
	defer ui.text_pop()
	label_c := ui.col(ui.mix(ui.PLOT_BG, th.text, 0.45))
	// The early reflections: left above the line, right below, after the predelay.
	if parts[1][1] > parts[1][0] {
		p0 := im.Vec2{pos.x + parts[1][0], pos.y}
		p1 := im.Vec2{pos.x + parts[1][1], pos.y + size.y}
		im.DrawList_AddRectFilled(dl, p0, p1, ui.col(ui.PLOT_BG), th.radius)
		mid := (p0.y + p1.y) / 2
		span := max(f32(150), v[fx.PV_PARAM_PREDELAY_MS] + 110) // (ms across: the predelay's gap within it)
		xt :: proc(ms, span, x0, x1: f32) -> f32 { return x0 + 4 + (x1 - x0 - 8) * clamp(ms / span, 0, 1) }
		pre := v[fx.PV_PARAM_PREDELAY_MS]
		im.DrawList_AddRectFilled(dl, {p0.x + 4, p0.y + 4}, {xt(pre, span, p0.x, p1.x), p1.y - 4}, ui.col(ui.mix(ui.PLOT_BG, th.text, 0.05)), 2)
		im.DrawList_AddLine(dl, {p0.x + 4, mid}, {p1.x - 4, mid}, ui.col(ui.mix(ui.PLOT_BG, th.text, 0.2)), 1)
		taps: [fx.PV_EARLY_TAPS]fx.Proverb_Tap
		fx.proverb_early_taps(&v, &taps)
		h := (p1.y - p0.y) / 2 - 6
		depth := v[fx.PV_PARAM_DEPTH]
		ec := ui.with_alpha(th.accent, 0.35 + 0.65 * (1 - depth))
		biggest: f32 = 1e-6
		for tp in taps do biggest = max(biggest, abs(tp.left), abs(tp.right))
		for tp in taps {
			x := xt(pre + tp.ms, span, p0.x, p1.x)
			im.DrawList_AddLine(dl, {x, mid}, {x, mid - h * abs(tp.left) / biggest}, ui.col(ec), 2)
			im.DrawList_AddLine(dl, {x, mid}, {x, mid + h * abs(tp.right) / biggest}, ui.col(ui.with_alpha(ec, ec.a * 0.7)), 2)
		}
		if !compact {
			im.DrawList_AddText(dl, {p0.x + 6, p0.y + 4}, label_c, "Early")
			im.DrawList_AddText(dl, {p1.x - 50, p1.y - im.GetTextLineHeight() - 3}, label_c, fmt.ctprintf("%.0f ms", span))
		}
	}
	// The damping curve: RT60 against frequency, its handles.
	if parts[2][1] > parts[2][0] {
		p0 := im.Vec2{pos.x + parts[2][0], pos.y}
		p1 := im.Vec2{pos.x + parts[2][1], pos.y + size.y}
		im.DrawList_AddRectFilled(dl, p0, p1, ui.col(ui.PLOT_BG), th.radius)
		x0, x1 := p0.x + 6, p1.x - 6
		y0, y1 := p0.y + 6, p1.y - 6
		top := max(f32(fx.proverb_rt60(&v, 100, sr)), v[fx.PV_PARAM_DECAY_S]) * 1.3
		yr :: proc(rt, top, y0, y1: f32) -> f32 { return y1 - (y1 - y0) * clamp(rt / top, 0, 1) }
		for f in ([]f32{100, 1000, 10_000}) {
			x := x0 + (x1 - x0) * ui.freq_x(f)
			im.DrawList_AddLine(dl, {x, y0}, {x, y1}, ui.col(ui.mix(ui.PLOT_BG, th.text, 0.1)), 1)
		}
		N :: 64
		pts: [N]im.Vec2
		for k in 0 ..< N {
			hz := ui.x_freq(f32(k) / (N - 1))
			pts[k] = {x0 + (x1 - x0) * f32(k) / (N - 1), yr(f32(fx.proverb_rt60(&v, f64(hz), sr)), top, y0, y1)}
		}
		// The High Cut: what's above it shaded.
		hc := x0 + (x1 - x0) * ui.freq_x(v[fx.PV_PARAM_HIGH_CUT_HZ])
		im.DrawList_AddRectFilled(dl, {hc, y0}, {x1, y1}, ui.col(ui.with_alpha(th.danger, 0.08)))
		for k in 1 ..< N do im.DrawList_AddQuadFilled(dl, {pts[k - 1].x, y1}, pts[k - 1], pts[k], {pts[k].x, y1}, ui.col(ui.with_alpha(th.accent, 0.15)))
		im.DrawList_AddPolyline(dl, &pts[0], N, ui.col(ui.mix(th.text, th.accent, 0.2)), 2)
		// The handles: bass (Bass Xover across, Bass Mult up and down), treble, High Cut.
		decay := v[fx.PV_PARAM_DECAY_S]
		hb := im.Vec2{x0 + (x1 - x0) * ui.freq_x(v[fx.PV_PARAM_BASS_XOVER_HZ]), yr(decay * v[fx.PV_PARAM_BASS_MULT], top, y0, y1)}
		hh := im.Vec2{x0 + (x1 - x0) * ui.freq_x(v[fx.PV_PARAM_HIGH_XOVER_HZ]), yr(decay * v[fx.PV_PARAM_HIGH_MULT], top, y0, y1)}
		hcut := im.Vec2{hc, y1 - 8}
		handles := [3]im.Vec2{hb, hh, hcut}
		names := [3]cstring{"B", "H", "C"}
		for hp, k in handles {
			hot := a.pv.drag == k + 1
			im.DrawList_AddCircleFilled(dl, hp, 8 if hot else 7, ui.col(th.accent if k < 2 else th.danger), 16)
			ts := im.CalcTextSize(names[k])
			im.DrawList_AddText(dl, {hp.x - ts.x / 2, hp.y - ts.y / 2}, ui.col(ui.PLOT_BG), names[k])
		}
		if !compact do im.DrawList_AddText(dl, {p0.x + 6, p0.y + 4}, label_c, fmt.ctprintf("Damping  %.2f s", decay))
		if interactive {
			im.SetCursorScreenPos(p0)
			im.InvisibleButton("##pv damping", {p1.x - p0.x, p1.y - p0.y})
			ui.name("pv damping")
			io := im.GetIO()
			if im.IsItemActivated() {
				a.pv.drag = 0
				best: f32 = 14 * 14
				for hp, k in handles {
					dx, dy := hp.x - io.MousePos.x, hp.y - io.MousePos.y
					if dx * dx + dy * dy < best do best, a.pv.drag = dx * dx + dy * dy, k + 1
				}
			}
			if a.pv.drag > 0 && im.IsItemActive() {
				d := io.MouseDelta
				k: f32 = 0.1 if io.KeyShift else 1
				set :: proc(a: ^App, t: pm.Fx_Target, id: fc.Param_Id, v: f32) {
					p := fx.proverb_params[id - 1]
					control_effect_param(a, t, i64(id), clamp(f64(v), p.min, p.max), true, false)
				}
				xs: fc.Param_Id = fx.PV_PARAM_BASS_XOVER_HZ if a.pv.drag == 1 else (fx.PV_PARAM_HIGH_XOVER_HZ if a.pv.drag == 2 else fx.PV_PARAM_HIGH_CUT_HZ)
				if d.x != 0 do set(a, t, xs, ui.x_freq(ui.freq_x(pv_get(s, xs)) + d.x * k / (x1 - x0)))
				if d.y != 0 && a.pv.drag < 3 {
					ms: fc.Param_Id = fx.PV_PARAM_BASS_MULT if a.pv.drag == 1 else fx.PV_PARAM_HIGH_MULT
					set(a, t, ms, pv_get(s, ms) - d.y * k * top / (y1 - y0) / max(decay, 0.1))
				}
			}
			if im.IsItemDeactivated() {
				if a.pv.drag > 0 do pa.history_gesture_end(&a.api)
				a.pv.drag = 0
			}
			if im.IsItemHovered() && a.pv.drag == 0 do im.SetTooltip("Drag B (bass) and H (treble): across for the crossover, up and down for the multiplier; C: the High Cut")
		}
	}
	im.SetCursorScreenPos(pos)
	im.Dummy(size)
}

// --- the window ---------------------------------------------------------------------------------

// ProVerb's choices on its slot's header line: its mode and quality.
pv_header :: proc(a: ^App, t: pm.Fx_Target, s: pm.Effect_Slot) {
	combo :: proc(a: ^App, t: pm.Fx_Target, s: pm.Effect_Slot, id: fc.Param_Id, names: []string, width: f32, what: string) {
		cur := clamp(int(pv_get(s, id) + 0.5), 0, len(names) - 1)
		im.SetNextItemWidth(width)
		if ui.combo(fmt.ctprintf("##pv%d", int(id)), fmt.ctprintf("%s", names[cur]), {.HeightLarge}) {
			for n, k in names {
				if im.Selectable(fmt.ctprintf("%s##pvc%d", n, k), k == cur) && k != cur do control_effect_param(a, t, i64(id), f64(k), true, true)
				ui.name(fmt.tprintf("pv %s %s", what, n))
			}
			im.EndCombo()
		}
		ui.name(fmt.tprintf("pv %s", what))
	}
	combo(a, t, s, fx.PV_PARAM_MODE, PV_MODE_NAMES, 130, "Mode")
	if im.IsItemHovered() do im.SetTooltip("The mode: the room's shape, how it builds, how it moves")
	im.SameLine(0, 6)
	combo(a, t, s, fx.PV_PARAM_QUALITY, PV_QUALITY_NAMES, 84, "Quality")
	if im.IsItemHovered() do im.SetTooltip("Eco: four lines, for small machines; Normal; High: sixteen lines")
}

// ProVerb's panel in the window: the two pictures across the top; the five
// main bars at the left; the Early and Late pages of knobs at the right.
draw_pro_verb :: proc(a: ^App, t: pm.Fx_Target, s: pm.Effect_Slot) {
	avail := im.GetContentRegionAvail().x
	pv_display(a, t, s, {avail, 120}, -1, true)
	im.Dummy({1, 4})
	top := im.GetCursorPosY()
	x0 := im.GetCursorPosX()
	bars := [5]struct {id: fc.Param_Id, label: string}{
		{fx.PV_PARAM_MIX, "Mix"}, {fx.PV_PARAM_PREDELAY_MS, "Predelay"}, {fx.PV_PARAM_DECAY_S, "Decay"}, {fx.PV_PARAM_HIGH_CUT_HZ, "High Cut"}, {fx.PV_PARAM_DEPTH, "Depth"},
	}
	BW :: 58
	for b, k in bars {
		if k > 0 do im.SameLine(0, 8)
		pv_bar(a, t, s, b.id, b.label, {BW, 90})
	}
	// The pages.
	im.SetCursorPos({x0 + 5 * (BW + 8) + 16, top})
	im.BeginGroup()
	for n, k in ([2]string{"Early", "Late"}) {
		if k > 0 do im.SameLine(0, 2)
		on := a.pv.page == k
		if ui.toggle(fmt.ctprintf("%s##pvpage%d", n, k), &on) do a.pv.page = k
		ui.name(fmt.tprintf("pv page %s", n))
	}
	row :: proc(a: ^App, t: pm.Fx_Target, s: pm.Effect_Slot, cells: []struct {id: fc.Param_Id, label: string}) {
		for c, k in cells {
			if k > 0 do im.SameLine(0, 14)
			pv_knob(a, t, s, c.id, c.label, 28)
		}
	}
	if a.pv.page == 0 {
		row(a, t, s, {{fx.PV_PARAM_EARLY_SIZE, "Size"}, {fx.PV_PARAM_EARLY_CROSS, "Cross"}, {fx.PV_PARAM_EARLY_MOD_RATE, "Mod Rate"}, {fx.PV_PARAM_EARLY_MOD_DEPTH, "Mod Depth"}})
		row(a, t, s, {{fx.PV_PARAM_EARLY_SEND, "Send"}, {fx.PV_PARAM_DIFFUSION, "Diffusion"}})
	} else {
		row(a, t, s, {{fx.PV_PARAM_LATE_SIZE, "Size"}, {fx.PV_PARAM_LATE_CROSS, "Cross"}, {fx.PV_PARAM_LATE_MOD_RATE, "Mod Rate"}, {fx.PV_PARAM_LATE_MOD_DEPTH, "Mod Depth"}})
		row(a, t, s, {{fx.PV_PARAM_BASS_MULT, "Bass Mult"}, {fx.PV_PARAM_BASS_XOVER_HZ, "Bass Xover"}, {fx.PV_PARAM_HIGH_MULT, "High Mult"}, {fx.PV_PARAM_HIGH_XOVER_HZ, "High Xover"}})
	}
	im.EndGroup()
}

// --- a controller's display ---------------------------------------------------------------------

// ProVerb on a controller's display: the picture its upper row picks
// (Early, Damping), over four banks of encoders (Main, Early, Late,
// Decay).
@(private)
ctl_pro_verb :: proc(ctx: ^View_Ctx, t: pm.Fx_Target, s: pm.Effect_Slot, plot, full: im.Vec2) {
	a := ctx.a
	for n, k in PV_FOCUS_NAMES {
		ctl_upper(ctx, k, n, a.pv.focus == k)
		b := int(pa.View_Button.Upper_1) + k
		if ctx.input != nil && ctx.input.pressed[b] do a.pv.focus = k
	}
	im.SetCursorPos({0, CTL_PLOT_Y})
	pv_display(a, t, s, plot, clamp(a.pv.focus, 0, 1), false)
	ctx.banks[0], ctx.banks[1], ctx.banks[2], ctx.banks[3] = "Main", "Early", "Late", "Decay"
	N :: 32
	knob :: proc(ctx: ^View_Ctx, n: int, t: pm.Fx_Target, s: pm.Effect_Slot, id: fc.Param_Id, label: string, plot: im.Vec2) {
		if ctl_knob(ctx, n, N, fmt.ctprintf("%s##pv%d", label, int(id)), plot) do pv_knob(ctx.a, t, s, id, label)
	}
	choice :: proc(ctx: ^View_Ctx, n: int, t: pm.Fx_Target, s: pm.Effect_Slot, id: fc.Param_Id, label: string, names: []string, plot: im.Vec2) {
		cur := int(pv_get(s, id) + 0.5)
		if k, _ := ctl_choice(ctx, n, N, fmt.ctprintf("%s##pv%d", label, int(id)), names, cur, plot); k >= 0 do control_effect_param(ctx.a, t, i64(id), f64(k), true, true)
	}
	// Main.
	knob(ctx, 0, t, s, fx.PV_PARAM_MIX, "Mix", plot)
	knob(ctx, 1, t, s, fx.PV_PARAM_PREDELAY_MS, "Predelay", plot)
	knob(ctx, 2, t, s, fx.PV_PARAM_DECAY_S, "Decay", plot)
	knob(ctx, 3, t, s, fx.PV_PARAM_HIGH_CUT_HZ, "High Cut", plot)
	knob(ctx, 4, t, s, fx.PV_PARAM_DEPTH, "Depth", plot)
	choice(ctx, 5, t, s, fx.PV_PARAM_MODE, "Mode", PV_MODE_NAMES, plot)
	choice(ctx, 6, t, s, fx.PV_PARAM_QUALITY, "Quality", PV_QUALITY_NAMES, plot)
	knob(ctx, 7, t, s, fx.PV_PARAM_DIFFUSION, "Diffusion", plot)
	// Early.
	knob(ctx, 8, t, s, fx.PV_PARAM_EARLY_SIZE, "Size", plot)
	knob(ctx, 9, t, s, fx.PV_PARAM_EARLY_CROSS, "Cross", plot)
	knob(ctx, 10, t, s, fx.PV_PARAM_EARLY_MOD_RATE, "Mod Rate", plot)
	knob(ctx, 11, t, s, fx.PV_PARAM_EARLY_MOD_DEPTH, "Mod Depth", plot)
	knob(ctx, 12, t, s, fx.PV_PARAM_EARLY_SEND, "Send", plot)
	// Late.
	knob(ctx, 16, t, s, fx.PV_PARAM_LATE_SIZE, "Size", plot)
	knob(ctx, 17, t, s, fx.PV_PARAM_LATE_CROSS, "Cross", plot)
	knob(ctx, 18, t, s, fx.PV_PARAM_LATE_MOD_RATE, "Mod Rate", plot)
	knob(ctx, 19, t, s, fx.PV_PARAM_LATE_MOD_DEPTH, "Mod Depth", plot)
	// Decay.
	knob(ctx, 24, t, s, fx.PV_PARAM_BASS_MULT, "Bass Mult", plot)
	knob(ctx, 25, t, s, fx.PV_PARAM_BASS_XOVER_HZ, "Bass Xover", plot)
	knob(ctx, 26, t, s, fx.PV_PARAM_HIGH_MULT, "High Mult", plot)
	knob(ctx, 27, t, s, fx.PV_PARAM_HIGH_XOVER_HZ, "High Xover", plot)
	_ = full
}
