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

// ProEq's device. One picture, the display, is drawn by the window's panel
// and by a controller's display alike: a subtle grid, the input's spectrum
// faint and the output's over it, the summed response with its boosts and
// cuts tinted, the selected band's own curve filled, the eight bands'
// numbered handles. Around it the window has the selected band's knobs,
// the band cells and the right column; the controller, its bands on the
// upper row and three banks of encoders.

// Names of ProEq's band types, slopes and modes, as shown.
PE_TYPE_NAMES := []string{"Low Cut", "Low Shelf", "Bell", "Notch", "High Shelf", "High Cut", "Band-pass", "Tilt"}
PE_TYPE_SHORT := []string{"Cut", "Shelf", "Bell", "Notch", "Shelf", "Cut", "Band", "Tilt"}
PE_SLOPE_NAMES := []string{"12 dB", "24 dB", "36 dB", "48 dB", "96 dB"}
PE_MODE_NAMES := []string{"Stereo", "L/R", "M/S"}

// Each band's colour (its handle, its own curve, its cell).
@(private) PE_COLORS := [fx.PE_BANDS]u32{0xff9f43, 0xffd166, 0x7bd88f, 0x3fc7c4, 0x58a6ff, 0x9d8cff, 0xe07be0, 0xff6f91}

// The panel's own state, shared by the window and a controller: the band
// selected, the set edited, Audition and the spectrum switched, and what
// is auditioned now.
Pe_Ui :: struct {
	band:        int,  // the selected band + 1 (0: the third, at first)
	edit:        int,  // the set shown and edited in L/R and M/S (0: A, 1: B)
	hear:        bool, // Audition: a band held plays alone
	no_spectrum: bool, // the spectrum hidden
	held_at:     time.Tick, // a band last held (a handle dragged, a band's encoder touched)
	heard:       pm.Fx_Target, // the slot auditioning, its set and band (band -1: none)
	heard_set:   int,
	heard_band:  int,
	drag:        int, // the handle dragged in the window + 1 (0: none)
	pre:         Spectrum_State, // the input's spectrum
}

// The selected band (0..7).
@(private)
pe_band :: proc(a: ^App) -> int { return clamp(a.pe.band - 1, 0, fx.PE_BANDS - 1) if a.pe.band > 0 else 2 }

// A setting of ProEq slot `s` (its default when it has none).
@(private)
pe_get :: proc(s: pm.Effect_Slot, id: fc.Param_Id) -> f32 {
	return pm.slot_value(s, id, f32(fx.pro_eq_params[id - 1].default))
}

// The mode of ProEq slot `s`.
@(private)
pe_mode :: proc(s: pm.Effect_Slot) -> fx.Pro_Eq_Mode {
	return fx.Pro_Eq_Mode(clamp(int(pe_get(s, fx.PE_PARAM_MODE) + 0.5), 0, len(fx.Pro_Eq_Mode) - 1))
}

// The set shown and edited (A in Stereo).
@(private)
pe_set :: proc(a: ^App, s: pm.Effect_Slot) -> int { return 0 if pe_mode(s) == .Stereo else clamp(a.pe.edit, 0, 1) }

// The name of set `set` in ProEq slot `s`'s mode: A/B, Left/Right, Mid/Side.
@(private)
pe_set_name :: proc(s: pm.Effect_Slot, set: int) -> string {
	switch pe_mode(s) {
	case .Stereo:     return "A"
	case .Left_Right: return "Left" if set == 0 else "Right"
	case .Mid_Side:   return "Mid" if set == 0 else "Side"
	}
	return ""
}

// Band `b`'s type in ProEq slot `s`'s set `set`.
@(private)
pe_type :: proc(s: pm.Effect_Slot, set, b: int) -> fx.Pro_Eq_Type {
	return fx.Pro_Eq_Type(clamp(int(pe_get(s, fx.pro_eq_band_param(set, b, .Type)) + 0.5), 0, len(fx.Pro_Eq_Type) - 1))
}

// Whether a band of type `t` has a gain (a shelf, a bell, a tilt).
@(private)
pe_has_gain :: proc(t: fx.Pro_Eq_Type) -> bool { return t == .Low_Shelf || t == .Bell || t == .High_Shelf || t == .Tilt }

// ProEq slot `t`'s settings (`s`), with automation where it plays now.
@(private)
pe_values :: proc(a: ^App, t: pm.Fx_Target, s: pm.Effect_Slot) -> (v: fx.Pro_Eq_Values) {
	v = pm.pro_eq_values(s)
	for p in fx.pro_eq_params {
		if live, automated := pm.automated_value(&a.m, fx_auto_target(t, p.id)); automated do v[p.id] = live
	}
	return
}

// Sets ProEq choice `id` of slot `t` to `v` (one undo step).
@(private)
pe_choose :: proc(a: ^App, t: pm.Fx_Target, id: fc.Param_Id, v: f64) {
	control_effect_param(a, t, i64(id), v, true, true)
}

// How ProEq parameter `id` at `v` reads under its knob.
@(private)
pe_shown :: proc(id: fc.Param_Id, v: f32) -> cstring {
	p := fx.pro_eq_params[id - 1]
	if id == fx.PE_PARAM_SCALE do return fmt.ctprintf("%.0f%%", v * 100)
	#partial switch p.unit {
	case .Hertz:    return fmt.ctprintf("%s", sf_hz(v))
	case .Decibels: return fmt.ctprintf("%+.1f dB", v)
	}
	return fmt.ctprintf("%.2f", v)
}

// ProEq parameter `id` of slot `t` (`s`) as a knob at the cursor:
// automatable, undoably (a drag one step).
@(private)
pe_knob :: proc(a: ^App, t: pm.Fx_Target, s: pm.Effect_Slot, id: fc.Param_Id, label: string, size: f32 = ui.KNOB_SIZE) -> ui.Edit {
	p := fx.pro_eq_params[id - 1]
	v := pe_get(s, id)
	is_q := int(id) >= int(fx.pro_eq_band_param(0, 0, .On)) && (int(id) - int(fx.pro_eq_band_param(0, 0, .On))) % len(fx.Pro_Eq_Field) == int(fx.Pro_Eq_Field.Q)
	log_scale := (p.unit == .Hertz || is_q) && p.min > 0
	knob_target(a, fx_auto_target(t, id))
	e := ui.knob(fmt.ctprintf("%s##pe%d", label, int(id)), &v, f32(p.min), f32(p.max), f32(p.default), "%.2f", size = size, log_scale = log_scale, shown_value = pe_shown(id, v))
	knob_target(a, {})
	control_effect_param(a, t, i64(id), clamp(f64(v), p.min, p.max), e.changed, e.ended)
	return e
}

// Keeps the slot's audition as the panel wants it: Audition on and a band
// held (in the window or on a controller, within the last few frames),
// that band of `t`'s set alone; else none.
@(private)
pe_audition_sync :: proc(a: ^App, t: pm.Fx_Target, s: pm.Effect_Slot) {
	want_band := -1
	if a.pe.hear && a.pe.held_at != {} && time.duration_milliseconds(time.tick_since(a.pe.held_at)) < 150 do want_band = pe_band(a)
	set := pe_set(a, s)
	if a.pe.heard == t && a.pe.heard_band == want_band && (want_band < 0 || a.pe.heard_set == set) do return
	if a.pe.heard_band >= 0 && a.pe.heard != t do pa.effect_set_pro_eq_audition(&a.api, slot_ref(a.pe.heard), 0, -1)
	pa.effect_set_pro_eq_audition(&a.api, slot_ref(t), i64(set), i64(want_band))
	a.pe.heard, a.pe.heard_set, a.pe.heard_band = t, set, want_band
}

// The display's range either side of 0 dB: 12, or more while a band's
// gain (scaled) goes past it.
@(private)
pe_range :: proc(v: ^fx.Pro_Eq_Values, set: int) -> f32 {
	most: f32 = 0
	for b in 0 ..< fx.PE_BANDS {
		typ := fx.Pro_Eq_Type(clamp(int(v[fx.pro_eq_band_param(set, b, .Type)] + 0.5), 0, len(fx.Pro_Eq_Type) - 1))
		if v[fx.pro_eq_band_param(set, b, .On)] < 0.5 || !pe_has_gain(typ) do continue
		g := abs(v[fx.pro_eq_band_param(set, b, .Gain_Db)] * v[fx.PE_PARAM_SCALE])
		if typ == .Tilt do g /= 2
		most = max(most, g)
	}
	return clamp(math.ceil((most + 1) / 6) * 6, 12, 30)
}

// ProEq slot `t`'s display, `size` big. `interactive`: its handles dragged
// (across: Freq; up and down: Gain, or Q for a shape without one; Alt: Q;
// the wheel: Q; Shift: fine), a click selects, a double click turns a band
// on or off.
@(private)
pe_display :: proc(a: ^App, t: pm.Fx_Target, s: pm.Effect_Slot, size: im.Vec2, interactive: bool) {
	th := ui.theme()
	sr := a.host.graph.settings.sample_rate if a.host.graph.settings.sample_rate > 0 else 48_000
	v := pe_values(a, t, s)
	set := pe_set(a, s)
	mode := pe_mode(s)
	sel := pe_band(a)
	pm.watch_slot(&a.m.engine, t)
	pos := im.GetCursorScreenPos()
	im.SetNextItemAllowOverlap() // (the buttons drawn over it take their clicks)
	im.InvisibleButton("##pe display", size)
	ui.name("pe display")
	hovered := im.IsItemHovered()
	dl := im.GetWindowDrawList()
	x0, x1 := pos.x + 8, pos.x + size.x - 8
	top, bottom := pos.y + 6, pos.y + size.y - 6
	mid := (top + bottom) / 2
	r := pe_range(&v, set)
	ydb :: proc(db, r, mid, half: f32) -> f32 { return mid - clamp(db, -r, r) / r * half }
	half := (bottom - top) / 2
	xf :: proc(hz, x0, x1: f32) -> f32 { return x0 + (x1 - x0) * ui.freq_x(hz) }
	im.DrawList_AddRectFilled(dl, pos, {pos.x + size.x, pos.y + size.y}, ui.col(ui.PLOT_BG), th.radius)
	// The grid: decades a little stronger, every 6 dB (12 past ±12), 0 dB stronger still; labels at the edges.
	faint, decade := ui.mix(ui.PLOT_BG, th.text, 0.05), ui.mix(ui.PLOT_BG, th.text, 0.12)
	for dec := f32(10); dec < 20_000; dec *= 10 do for k in 1 ..< 10 {
		hz := dec * f32(k)
		if hz < 20 || hz > 20_000 do continue
		x := xf(hz, x0, x1)
		im.DrawList_AddLine(dl, {x, top}, {x, bottom}, ui.col(decade if k == 1 else faint), 1)
	}
	step: f32 = 6 if r <= 12 else 12
	ui.text_push(.Label)
	label_c := ui.col(ui.mix(ui.PLOT_BG, th.text, 0.38))
	for db := -r; db <= r + 0.01; db += step {
		y := ydb(db, r, mid, half)
		im.DrawList_AddLine(dl, {x0, y}, {x1, y}, ui.col(ui.mix(ui.PLOT_BG, th.text, 0.2) if abs(db) < 0.01 else faint), 1)
		if abs(db) < r - 0.01 && size.y >= 90 do im.DrawList_AddText(dl, {x0 + 2, y - im.GetTextLineHeight() / 2}, label_c, fmt.ctprintf("%.0f", db))
	}
	names := [3]cstring{"100", "1k", "10k"}
	for f, k in ([3]f32{100, 1000, 10_000}) do im.DrawList_AddText(dl, {xf(f, x0, x1) + 3, bottom - im.GetTextLineHeight()}, label_c, names[k])
	ui.text_pop()
	// The spectra: the input faint, the output over it.
	if !a.pe.no_spectrum {
		yspec :: proc(d, top, bottom: f32) -> f32 { return bottom - clamp((d + 36) / 60, 0, 1) * (bottom - top) }
		draw_spec :: proc(dl: ^im.DrawList, spec: []f32, x0, x1, top, bottom: f32, fill, line: ui.Color) {
			n := len(spec)
			if n < 2 do return
			pts := make([]im.Vec2, n, context.temp_allocator)
			for d, k in spec do pts[k] = {x0 + (x1 - x0) * f32(k) / f32(n - 1), yspec(d, top, bottom)}
			for k in 1 ..< n do im.DrawList_AddQuadFilled(dl, {pts[k - 1].x, bottom}, pts[k - 1], pts[k], {pts[k].x, bottom}, ui.col(fill))
			im.DrawList_AddPolyline(dl, &pts[0], i32(n), ui.col(line), 1)
		}
		if st, sr2 := pa.effect_pro_eq_state(&a.api, slot_ref(t)); sr2 == .Ok {
			_ = st
			if eq := pm.slot_pro_eq(&a.m.engine, t); eq != nil {
				x: [SPECTRUM_SIZE]f32
				fx.pro_eq_read_input(eq, x[:])
				if pre := spectrum_of(&a.pe.pre, x[:], sr); pre != nil do draw_spec(dl, pre, x0, x1, top, bottom, ui.with_alpha(th.text, 0.05), ui.with_alpha(th.text, 0.18))
			}
		}
		if post := spectrum(a); post != nil do draw_spec(dl, post, x0, x1, top, bottom, ui.with_alpha(th.text, 0.13), ui.with_alpha(th.text, 0.32))
	}
	// The curves: the other set's faint; the selected band's filled; the sum, its boosts and cuts tinted.
	N :: RESPONSE_POINTS
	hz: [N]f32
	for &h, k in hz do h = ui.x_freq(f32(k) / (N - 1))
	px :: proc(k: int, x0, x1: f32) -> f32 { return x0 + (x1 - x0) * f32(k) / (N - 1) }
	sum, own: [N]f32
	fx.pro_eq_curve(&v, set, sr, hz[:], sum[:])
	color := ui.mix(th.text, th.accent, 0.15) if s.on else ui.mix(ui.PLOT_BG, th.text, 0.45) // (light: the tints' green and red stay its own)
	if mode != .Stereo {
		other: [N]f32
		fx.pro_eq_curve(&v, 1 - set, sr, hz[:], other[:])
		pts: [N]im.Vec2
		for d, k in other do pts[k] = {px(k, x0, x1), ydb(d, r, mid, half)}
		im.DrawList_AddPolyline(dl, &pts[0], N, ui.col(ui.with_alpha(th.text, 0.3)), 1.2)
	}
	zero := ydb(0, r, mid, half)
	aa := dl.Flags
	dl.Flags -= {.AntiAliasedFill} // (side by side, anti-aliased quads leave seams)
	for k in 1 ..< N {
		d := (sum[k - 1] + sum[k]) / 2
		if abs(d) < 0.05 do continue
		tint := ui.with_alpha(th.ok if d > 0 else th.danger, 0.16)
		im.DrawList_AddQuadFilled(dl, {px(k - 1, x0, x1), zero}, {px(k - 1, x0, x1), ydb(sum[k - 1], r, mid, half)}, {px(k, x0, x1), ydb(sum[k], r, mid, half)}, {px(k, x0, x1), zero}, ui.col(tint))
	}
	band_on := v[fx.pro_eq_band_param(set, sel, .On)] >= 0.5
	if band_on {
		fx.pro_eq_curve(&v, set, sr, hz[:], own[:], band = sel)
		bc := ui.rgb(PE_COLORS[sel])
		pts: [N]im.Vec2
		for d, k in own do pts[k] = {px(k, x0, x1), ydb(d, r, mid, half)}
		for k in 1 ..< N do im.DrawList_AddQuadFilled(dl, {pts[k - 1].x, zero}, pts[k - 1], pts[k], {pts[k].x, zero}, ui.col(ui.with_alpha(bc, 0.2)))
		im.DrawList_AddPolyline(dl, &pts[0], N, ui.col(ui.with_alpha(bc, 0.75)), 1.5)
	}
	dl.Flags = aa
	sum_pts: [N]im.Vec2
	for d, k in sum do sum_pts[k] = {px(k, x0, x1), ydb(d, r, mid, half)}
	im.DrawList_AddPolyline(dl, &sum_pts[0], N, ui.col(color), 2)
	// The handles, the selected one last (on top).
	scale := v[fx.PE_PARAM_SCALE]
	handle_at :: proc(v: ^fx.Pro_Eq_Values, set, b: int, scale, r, mid, half, x0, x1: f32) -> im.Vec2 {
		typ := fx.Pro_Eq_Type(clamp(int(v[fx.pro_eq_band_param(set, b, .Type)] + 0.5), 0, len(fx.Pro_Eq_Type) - 1))
		g: f32 = 0
		if pe_has_gain(typ) do g = v[fx.pro_eq_band_param(set, b, .Gain_Db)] * scale * (0.5 if typ == .Tilt else 1)
		return {xf(v[fx.pro_eq_band_param(set, b, .Freq_Hz)], x0, x1), ydb(g, r, mid, half)}
	}
	io := im.GetIO()
	hot := -1
	if interactive && hovered && a.pe.drag == 0 {
		best: f32 = 12 * 12
		for b in 0 ..< fx.PE_BANDS {
			p := handle_at(&v, set, b, scale, r, mid, half, x0, x1)
			dx, dy := p.x - io.MousePos.x, p.y - io.MousePos.y
			if dx * dx + dy * dy < best do best, hot = dx * dx + dy * dy, b
		}
	}
	if a.pe.drag > 0 do hot = a.pe.drag - 1
	ui.text_push(.Label)
	for i in 0 ..= fx.PE_BANDS {
		b := i if i < fx.PE_BANDS else sel
		if i < fx.PE_BANDS && b == sel do continue
		p := handle_at(&v, set, b, scale, r, mid, half, x0, x1)
		on := v[fx.pro_eq_band_param(set, b, .On)] >= 0.5
		bc := ui.rgb(PE_COLORS[b]) if on else ui.mix(ui.PLOT_BG, th.text, 0.4)
		rad: f32 = 8 if b == hot else 7
		num := fmt.ctprintf("%d", b + 1)
		ts := im.CalcTextSize(num)
		if b == sel {
			im.DrawList_AddCircleFilled(dl, p, rad, ui.col(bc), 20)
			im.DrawList_AddText(dl, {p.x - ts.x / 2, p.y - ts.y / 2}, ui.col(ui.PLOT_BG), num)
		} else {
			im.DrawList_AddCircleFilled(dl, p, rad, ui.col(ui.with_alpha(ui.PLOT_BG, 0.85)), 20)
			im.DrawList_AddCircle(dl, p, rad, ui.col(bc), 20, 1.5)
			im.DrawList_AddText(dl, {p.x - ts.x / 2, p.y - ts.y / 2}, ui.col(bc), num)
		}
	}
	// What the selected band is, top left (and the set, in L/R and M/S).
	typ := pe_type(s, set, sel)
	what := fmt.tprintf("%d  %s", sel + 1, PE_TYPE_NAMES[int(typ)])
	if typ == .Low_Cut || typ == .High_Cut do what = fmt.tprintf("%s %s", what, PE_SLOPE_NAMES[clamp(int(v[fx.pro_eq_band_param(set, sel, .Slope)] + 0.5), 0, 4)])
	what = fmt.tprintf("%s  %s", what, sf_hz(v[fx.pro_eq_band_param(set, sel, .Freq_Hz)]))
	if pe_has_gain(typ) do what = fmt.tprintf("%s  %+.1f dB", what, v[fx.pro_eq_band_param(set, sel, .Gain_Db)])
	if typ != .Tilt do what = fmt.tprintf("%s  Q %.2f", what, v[fx.pro_eq_band_param(set, sel, .Q)])
	if !band_on do what = fmt.tprintf("%s  (off)", what)
	if mode != .Stereo do what = fmt.tprintf("%s · %s", pe_set_name(s, set), what)
	im.DrawList_AddText(dl, {x0 + 22, top + 2}, ui.col(ui.with_alpha(th.text, 0.75)), fmt.ctprintf("%s", what))
	ui.text_pop()
	// The levels in and out, at the left and right edges.
	if st, ok := pa.effect_pro_eq_state(&a.api, slot_ref(t)); ok == .Ok && s.on {
		meter :: proc(dl: ^im.DrawList, x, top, bottom, peak: f32, c: ui.Color) {
			db := 20 * math.log10(max(peak, 1e-6))
			f := clamp((db + 48) / 48, 0, 1)
			im.DrawList_AddRectFilled(dl, {x, bottom - (bottom - top) * f}, {x + 3, bottom}, ui.col(c))
		}
		meter(dl, pos.x + 2, top + 2, bottom - 2, st.in_peak, ui.with_alpha(th.text, 0.6))
		meter(dl, pos.x + size.x - 5, top + 2, bottom - 2, st.out_peak, color)
	}
	// Dragging.
	if interactive {
		if im.IsItemActivated() {
			a.pe.drag = hot + 1
			if hot >= 0 do a.pe.band = hot + 1
		}
		if hovered && hot >= 0 && im.IsMouseDoubleClicked(.Left) {
			id := fx.pro_eq_band_param(set, hot, .On)
			pe_choose(a, t, id, 0 if pe_get(s, id) >= 0.5 else 1)
		}
		if b := a.pe.drag - 1; b >= 0 && im.IsItemActive() {
			a.pe.held_at = time.tick_now()
			d := io.MouseDelta
			k: f32 = 0.1 if io.KeyShift else 1
			btyp := pe_type(s, set, b)
			if d.x != 0 && !io.KeyAlt {
				fid := fx.pro_eq_band_param(set, b, .Freq_Hz)
				x := ui.freq_x(pe_get(s, fid)) + d.x * k / (x1 - x0)
				control_effect_param(a, t, i64(fid), f64(clamp(ui.x_freq(x), 10, 22_000)), true, false)
			}
			if d.y != 0 {
				if pe_has_gain(btyp) && !io.KeyAlt {
					gid := fx.pro_eq_band_param(set, b, .Gain_Db)
					sc := scale * (0.5 if btyp == .Tilt else 1)
					if abs(sc) > 0.05 {
						g := pe_get(s, gid) - d.y * k * r / half / sc
						control_effect_param(a, t, i64(gid), f64(clamp(g, -15, 15)), true, false)
					}
				} else if btyp != .Tilt {
					qid := fx.pro_eq_band_param(set, b, .Q)
					q := pe_get(s, qid) * math.pow(2, -d.y * k / 40)
					control_effect_param(a, t, i64(qid), f64(clamp(q, 0.1, 18)), true, false)
				}
			}
		}
		if im.IsItemDeactivated() {
			if a.pe.drag > 0 do pa.history_gesture_end(&a.api)
			a.pe.drag = 0
		}
		if hovered && io.MouseWheel != 0 {
			b := hot if hot >= 0 else sel
			if pe_type(s, set, b) != .Tilt {
				qid := fx.pro_eq_band_param(set, b, .Q)
				q := pe_get(s, qid) * math.pow(2, io.MouseWheel * 0.1)
				pe_choose(a, t, qid, f64(clamp(q, 0.1, 18)))
			}
		}
		if hovered && hot >= 0 && a.pe.drag == 0 do im.SetTooltip("Band %d: drag across for Freq, up and down for %s (Alt: Q; the wheel: Q; Shift: fine); double-click: on or off", i32(hot + 1), cstring("Gain" if pe_has_gain(pe_type(s, set, hot)) else "Q"))
	}
	pe_audition_sync(a, t, s)
}

// A band type's shape as a small picture in the box from `p0` to `p1`.
@(private)
pe_shape_icon :: proc(dl: ^im.DrawList, p0, p1: im.Vec2, typ: fx.Pro_Eq_Type, c: ui.Color) {
	shapes := [fx.Pro_Eq_Type][]im.Vec2{
		.Low_Cut    = {{0.05, 0.95}, {0.3, 0.45}, {0.45, 0.5}, {0.95, 0.5}},
		.Low_Shelf  = {{0.05, 0.2}, {0.3, 0.2}, {0.6, 0.5}, {0.95, 0.5}},
		.Bell       = {{0.05, 0.5}, {0.3, 0.5}, {0.5, 0.12}, {0.7, 0.5}, {0.95, 0.5}},
		.Notch      = {{0.05, 0.5}, {0.4, 0.5}, {0.5, 0.95}, {0.6, 0.5}, {0.95, 0.5}},
		.High_Shelf = {{0.05, 0.5}, {0.4, 0.5}, {0.7, 0.2}, {0.95, 0.2}},
		.High_Cut   = {{0.05, 0.5}, {0.55, 0.5}, {0.7, 0.45}, {0.95, 0.95}},
		.Band_Pass  = {{0.05, 0.95}, {0.38, 0.35}, {0.5, 0.15}, {0.62, 0.35}, {0.95, 0.95}},
		.Tilt       = {{0.05, 0.78}, {0.95, 0.22}},
	}
	sh := shapes[typ]
	pts := make([]im.Vec2, len(sh), context.temp_allocator)
	for q, k in sh do pts[k] = {p0.x + (p1.x - p0.x) * q.x, p0.y + (p1.y - p0.y) * q.y}
	im.DrawList_AddPolyline(dl, &pts[0], i32(len(pts)), ui.col(c), 1.6)
}

// --- the window ---------------------------------------------------------------------------------

// ProEq's choices on its slot's header line: its mode, the set edited
// (L/R and M/S), Adaptive Q.
pe_header :: proc(a: ^App, t: pm.Fx_Target, s: pm.Effect_Slot) {
	mode := pe_mode(s)
	im.SetNextItemWidth(84)
	if ui.combo("##pe mode", fmt.ctprintf("%s", PE_MODE_NAMES[int(mode)])) {
		for n, k in PE_MODE_NAMES {
			if im.Selectable(fmt.ctprintf("%s##pem%d", n, k), k == int(mode)) && k != int(mode) do pa.effect_set_pro_eq_mode(&a.api, slot_ref(t), i64(k))
			ui.name(fmt.tprintf("pe Mode %s", n))
		}
		im.EndCombo()
	}
	ui.name("pe Mode")
	if im.IsItemHovered() do im.SetTooltip("Stereo: one set of bands for both sides; L/R: A the left, B the right; M/S: A the mid, B the side")
	im.SameLine(0, 6)
	im.BeginDisabled(mode == .Stereo)
	for set in 0 ..< 2 {
		if set > 0 do im.SameLine(0, 2)
		on := pe_set(a, s) == set
		name := pe_set_name(s, set) if mode != .Stereo else ("A" if set == 0 else "B")
		if ui.toggle(fmt.ctprintf("%s##peedit%d", name, set), &on) do a.pe.edit = set
		ui.name(fmt.tprintf("pe Edit %d", set))
	}
	im.EndDisabled()
	if im.IsItemHovered({.AllowWhenDisabled}) do im.SetTooltip("Edit: which side's bands are shown and edited (L/R and M/S)")
	im.SameLine(0, 10)
	adaptive := pe_get(s, fx.PE_PARAM_ADAPTIVE_Q) >= 0.5
	if ui.toggle("Adaptive Q##pe", &adaptive) do pe_choose(a, t, fx.PE_PARAM_ADAPTIVE_Q, 1 if adaptive else 0)
	ui.name("pe Adaptive Q")
	if im.IsItemHovered() do im.SetTooltip("A bell narrows as its boost or cut grows")
}

// The eight band cells under the display, `width` wide: each its type (a
// picture; a menu of the types, and a cut's slopes) and its on switch with
// its number, the selected one marked.
@(private)
pe_band_cells :: proc(a: ^App, t: pm.Fx_Target, s: pm.Effect_Slot, width: f32) {
	th := ui.theme()
	set := pe_set(a, s)
	sel := pe_band(a)
	cell := width / fx.PE_BANDS
	start := im.GetCursorScreenPos()
	dl := im.GetWindowDrawList()
	bh: f32 = 20
	for b in 0 ..< fx.PE_BANDS {
		x := start.x + f32(b) * cell
		bc := ui.rgb(PE_COLORS[b])
		on := pe_get(s, fx.pro_eq_band_param(set, b, .On)) >= 0.5
		typ := pe_type(s, set, b)
		if b == sel do im.DrawList_AddRectFilled(dl, {x + 1, start.y}, {x + cell - 1, start.y + bh * 2 + 6}, ui.col(ui.with_alpha(bc, 0.14)), th.radius)
		// The type: its picture; pressed, the menu.
		im.SetCursorScreenPos({x + 3, start.y + 2})
		if im.Button(fmt.ctprintf("##petype%d", b), {cell - 6, bh}) {
			a.pe.band = b + 1
			im.OpenPopup(fmt.ctprintf("pe types %d", b))
		}
		ui.name(fmt.tprintf("pe type %d", b + 1))
		if im.IsItemHovered() do im.SetTooltip("%s", fmt.ctprintf("Band %d: %s", b + 1, PE_TYPE_NAMES[int(typ)]))
		r0, r1 := im.GetItemRectMin(), im.GetItemRectMax()
		pe_shape_icon(dl, {r0.x + 6, r0.y + 3}, {r1.x - 6, r1.y - 3}, typ, bc if on else th.text_dim)
		if im.BeginPopup(fmt.ctprintf("pe types %d", b)) {
			for n, k in PE_TYPE_NAMES {
				if im.Selectable(fmt.ctprintf("%s##pet%d", n, k), k == int(typ)) && k != int(typ) do pe_choose(a, t, fx.pro_eq_band_param(set, b, .Type), f64(k))
				ui.name(fmt.tprintf("pe type %d %s", b + 1, n))
			}
			if typ == .Low_Cut || typ == .High_Cut {
				im.Separator()
				slope := int(pe_get(s, fx.pro_eq_band_param(set, b, .Slope)) + 0.5)
				for n, k in PE_SLOPE_NAMES {
					if im.Selectable(fmt.ctprintf("%s an octave##pes%d", n, k), k == slope) && k != slope do pe_choose(a, t, fx.pro_eq_band_param(set, b, .Slope), f64(k))
					ui.name(fmt.tprintf("pe slope %d %s", b + 1, n))
				}
			}
			im.EndPopup()
		}
		// On, with its number.
		im.SetCursorScreenPos({x + 3, start.y + bh + 5})
		v := on
		if ui.toggle(fmt.ctprintf("%d##peon%d", b + 1, b), &v) {
			pe_choose(a, t, fx.pro_eq_band_param(set, b, .On), 1 if v else 0)
			a.pe.band = b + 1
		}
		ui.name(fmt.tprintf("pe band %d", b + 1))
	}
	im.SetCursorScreenPos({start.x, start.y + bh * 2 + 10})
	im.Dummy({width, 1})
}

// The window's knobs (as SuperFilter's rows').
@(private) PE_KNOB :: 34

// ProEq's panel in the window (under its slot's header): the selected
// band's Freq, Gain and Q at the left; the display, the band cells under
// it; Audition, the spectrum, Oversampling, Scale and the output's Gain
// at the right.
draw_pro_eq :: proc(a: ^App, t: pm.Fx_Target, s: pm.Effect_Slot) {
	avail := im.GetContentRegionAvail().x
	LEFT, RIGHT :: 70, 118
	set := pe_set(a, s)
	sel := pe_band(a)
	typ := pe_type(s, set, sel)
	top := im.GetCursorPosY()
	// The selected band.
	im.BeginGroup()
	pe_knob(a, t, s, fx.pro_eq_band_param(set, sel, .Freq_Hz), "Freq", PE_KNOB)
	im.BeginDisabled(!pe_has_gain(typ))
	pe_knob(a, t, s, fx.pro_eq_band_param(set, sel, .Gain_Db), "Gain", PE_KNOB)
	im.EndDisabled()
	im.BeginDisabled(typ == .Tilt)
	pe_knob(a, t, s, fx.pro_eq_band_param(set, sel, .Q), "Q", PE_KNOB)
	im.EndDisabled()
	im.EndGroup()
	// The display and the cells.
	mid_w := avail - LEFT - RIGHT - 16
	im.SetCursorPos({im.GetCursorStartPos().x + LEFT + 8, top})
	im.BeginGroup()
	pe_display(a, t, s, {mid_w, 136}, true)
	pe_band_cells(a, t, s, mid_w)
	im.EndGroup()
	// The right column.
	im.SetCursorPos({im.GetCursorStartPos().x + avail - RIGHT, top})
	im.BeginGroup()
	if ui.toggle(ui.ICON_HEADPHONES + "  Audition##pe", &a.pe.hear) {}
	ui.name("pe Audition")
	if im.IsItemHovered() do im.SetTooltip("Hold a band's handle to hear only what it touches")
	spec := !a.pe.no_spectrum
	if ui.toggle("Spectrum##pe", &spec) do a.pe.no_spectrum = !spec
	ui.name("pe Spectrum")
	os := pe_get(s, fx.PE_PARAM_OVERSAMPLE) >= 0.5
	if ui.toggle("2× Quality##pe", &os) do pe_choose(a, t, fx.PE_PARAM_OVERSAMPLE, 1 if os else 0)
	ui.name("pe Oversampling")
	if im.IsItemHovered() do im.SetTooltip("Oversampling: the bands at twice the rate, cleaner high bands and boosts near the top, a little latency, about twice the work")
	pe_knob(a, t, s, fx.PE_PARAM_SCALE, "Scale", 28)
	im.SameLine(0, 4)
	pe_knob(a, t, s, fx.PE_PARAM_GAIN_DB, "Gain##out", 28)
	im.EndGroup()
}

// --- a controller's display ---------------------------------------------------------------------

// ProEq on a controller's display: its bands on the upper row (pressed:
// selected; with Shift: on or off), the display over three banks of
// encoders (the selected band; every band's frequency, a touch selecting
// it; the global settings).
@(private)
ctl_pro_eq :: proc(ctx: ^View_Ctx, t: pm.Fx_Target, s: pm.Effect_Slot, plot, full: im.Vec2) {
	a := ctx.a
	set := pe_set(a, s)
	sel := pe_band(a)
	for k in 0 ..< fx.PE_BANDS {
		on := pe_get(s, fx.pro_eq_band_param(set, k, .On)) >= 0.5
		label := fmt.tprintf("%d %s", k + 1, PE_TYPE_SHORT[int(pe_type(s, set, k))]) if on else fmt.tprintf("%d off", k + 1)
		ctl_upper(ctx, k, label, k == sel, ui.rgb(PE_COLORS[k]))
		b := int(pa.View_Button.Upper_1) + k
		if ctx.input != nil && ctx.input.pressed[b] {
			if a.ctl.shift do pe_choose(a, t, fx.pro_eq_band_param(set, k, .On), 0 if on else 1)
			else do a.pe.band = k + 1
		}
	}
	im.SetCursorPos({0, CTL_PLOT_Y})
	pe_display(a, t, s, plot, false)
	ctx.banks[0], ctx.banks[1], ctx.banks[2] = "Band", "Bands", "Global"
	N :: 24
	knob :: proc(ctx: ^View_Ctx, n: int, t: pm.Fx_Target, s: pm.Effect_Slot, id: fc.Param_Id, label: string, plot: im.Vec2) -> bool {
		if !ctl_knob(ctx, n, N, fmt.ctprintf("%s##pe%d", label, int(id)), plot) do return false
		pe_knob(ctx.a, t, s, id, label)
		ki := ui.knob_input
		return ki != nil && ki.held[n % 8]
	}
	choice :: proc(ctx: ^View_Ctx, n: int, label: string, names: []string, cur: int, plot: im.Vec2) -> int {
		k, _ := ctl_choice(ctx, n, N, fmt.ctprintf("%s##pec%d", label, n), names, cur, plot)
		return k
	}
	typ := pe_type(s, set, sel)
	held := false
	// The selected band.
	held |= knob(ctx, 0, t, s, fx.pro_eq_band_param(set, sel, .Freq_Hz), "Freq", plot)
	held |= knob(ctx, 1, t, s, fx.pro_eq_band_param(set, sel, .Gain_Db), "Gain" if pe_has_gain(typ) else "(Gain)", plot)
	held |= knob(ctx, 2, t, s, fx.pro_eq_band_param(set, sel, .Q), "Q", plot)
	if k := choice(ctx, 3, "Type", PE_TYPE_NAMES, int(typ), plot); k >= 0 do pe_choose(a, t, fx.pro_eq_band_param(set, sel, .Type), f64(k))
	if k := choice(ctx, 4, "Slope", PE_SLOPE_NAMES if typ == .Low_Cut || typ == .High_Cut else {"—"}, int(pe_get(s, fx.pro_eq_band_param(set, sel, .Slope)) + 0.5), plot); k >= 0 && (typ == .Low_Cut || typ == .High_Cut) do pe_choose(a, t, fx.pro_eq_band_param(set, sel, .Slope), f64(k))
	on := pe_get(s, fx.pro_eq_band_param(set, sel, .On)) >= 0.5
	if k := choice(ctx, 5, "On", OFF_ON, 1 if on else 0, plot); k >= 0 do pe_choose(a, t, fx.pro_eq_band_param(set, sel, .On), f64(k))
	knob(ctx, 6, t, s, fx.PE_PARAM_SCALE, "Scale", plot)
	knob(ctx, 7, t, s, fx.PE_PARAM_GAIN_DB, "Gain", plot)
	if held do a.pe.held_at = time.tick_now()
	// Every band's frequency (a touch selects it).
	for b in 0 ..< fx.PE_BANDS {
		if knob(ctx, 8 + b, t, s, fx.pro_eq_band_param(set, b, .Freq_Hz), fmt.tprintf("%d Freq", b + 1), plot) do a.pe.band = b + 1
	}
	// Global.
	if k := choice(ctx, 16, "Mode", PE_MODE_NAMES, int(pe_mode(s)), plot); k >= 0 do pa.effect_set_pro_eq_mode(&a.api, slot_ref(t), i64(k))
	sides := []string{pe_set_name(s, 0), pe_set_name(s, 1)} if pe_mode(s) != .Stereo else []string{"A"}
	if k := choice(ctx, 17, "Edit", sides, set, plot); k >= 0 do a.pe.edit = k
	if k := choice(ctx, 18, "Adaptive Q", OFF_ON, 1 if pe_get(s, fx.PE_PARAM_ADAPTIVE_Q) >= 0.5 else 0, plot); k >= 0 do pe_choose(a, t, fx.PE_PARAM_ADAPTIVE_Q, f64(k))
	if k := choice(ctx, 19, "Oversampling", OFF_ON, 1 if pe_get(s, fx.PE_PARAM_OVERSAMPLE) >= 0.5 else 0, plot); k >= 0 do pe_choose(a, t, fx.PE_PARAM_OVERSAMPLE, f64(k))
	if k := choice(ctx, 20, "Spectrum", OFF_ON, 0 if a.pe.no_spectrum else 1, plot); k >= 0 do a.pe.no_spectrum = k == 0
	if k := choice(ctx, 21, "Audition", OFF_ON, 1 if a.pe.hear else 0, plot); k >= 0 do a.pe.hear = k == 1
	knob(ctx, 22, t, s, fx.PE_PARAM_SCALE, "Scale", plot)
	knob(ctx, 23, t, s, fx.PE_PARAM_GAIN_DB, "Gain", plot)
	_ = full
}
