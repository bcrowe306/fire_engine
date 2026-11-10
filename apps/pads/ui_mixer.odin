package pads

import "core:fmt"
import "core:math"

import app "app:core"
import "app:ui"
import pm "model"
import im "deps:imgui"

// A meter's display: what it shows, held peaks falling back, and the
// loudest peak since it was last reset (its readout).
Meter_View :: struct {
	peak, rms, hold: f32,
	hold_left:       f32, // seconds the held peak stays
	max:             f32, // the loudest since reset (click the readout to reset)
}

// The meters of the 64 pads, the buses and main.
Mixer_State :: struct {
	pads:  [pm.PADS][2]Meter_View,
	buses: [pm.BUSES + 1][2]Meter_View,
}

// Reads a meter into its display: the level falls at about 24 dB a second,
// a peak is held a second.
@(private)
meter_update :: proc(v: ^[2]Meter_View, peak, rms: [2]f32, dt: f32) {
	fall := f32(math.pow(10, -24 * f64(dt) / 20))
	for c in 0 ..< 2 {
		m := &v[c]
		m.peak = max(peak[c], m.peak * fall)
		m.rms = max(rms[c], m.rms * fall)
		m.max = max(m.max, peak[c])
		if peak[c] >= m.hold {
			m.hold, m.hold_left = peak[c], 1
		} else {
			m.hold_left -= dt
			if m.hold_left <= 0 do m.hold *= fall
		}
	}
}

// Reads every meter once a frame (whether the mixer shows or not).
update_meters :: proc(a: ^App) {
	e := &a.m.engine
	dt := im.GetIO().DeltaTime
	for i in 0 ..< pm.PADS {
		pk, rms := pm.pad_level(e, i)
		meter_update(&a.mixer.pads[i], pk, rms, dt)
	}
	for b in 0 ..= pm.BUSES {
		pk, rms := pm.bus_level(e, b)
		meter_update(&a.mixer.buses[b], pk, rms, dt)
	}
}

// The strip being drawn's name ("A1", "Bus A", "Main"): its parts are
// named after it for the probe ("A1 fader", "Bus A mute").
@(private) strip_name: string

// Names the item just drawn as part `part` of the strip being drawn.
@(private)
part :: proc(name: string) {
	ui.name(fmt.tprintf("%s %s", strip_name, name))
}

// Sizes of a channel strip, in points.
STRIP_W :: 86
@(private) STRIP_GAP :: 4
@(private) STRIP_PAD :: 5 // inside the strip, each side
@(private) ROW_H :: 18 // a slot, a send, the output
@(private) EQ_H :: 28
@(private) PAN_H :: 30
@(private) SLOT_ROWS :: 6 // pads: 2 inserts and 4 sends; buses: 5 slots and a gap
@(private) FADER_LO :: -60 // the bottom of the fader (off)
@(private) FADER_HI :: 6

// The mixer, as Logic's: a channel strip for every pad with a sound (in
// all banks, scrolling sideways), then the buses and main, pinned on the
// right.
draw_mixer :: proc(user: rawptr) {
	a := (^App)(user)
	m := &a.m
	avail := im.GetContentRegionAvail()
	buses_w := f32(pm.BUSES + 1) * (STRIP_W + STRIP_GAP) + 4
	im.PushStyleVarVec2(.ItemSpacing, {STRIP_GAP, 0})
	defer im.PopStyleVar()
	if im.BeginChild("##pads", {max(avail.x - buses_w - 8, STRIP_W), avail.y}, {}, {.HorizontalScrollbar}) {
		h := im.GetContentRegionAvail().y
		any := false
		for pad, i in m.project.pads do if pad.sample != 0 {
			if any do im.SameLine()
			any = true
			// Off to the side (scrolled away): only its room.
			if !im.IsRectVisibleBySize({STRIP_W, h}) {
				im.Dummy({STRIP_W, h})
				continue
			}
			pad_strip(a, i, h)
		}
		if !any {
			im.SetCursorPos({12, 12})
			im.TextDisabled("Pads with a sound get a channel strip here.")
		}
	}
	im.EndChild()
	im.SameLine(0, 8)
	// The line between the pads and the buses.
	pos := im.GetCursorScreenPos()
	im.DrawList_AddLine(im.GetWindowDrawList(), {pos.x - 5, pos.y + 4}, {pos.x - 5, pos.y + avail.y - 4}, ui.col(ui.theme().border), 1)
	if im.BeginChild("##buses", {buses_w, avail.y}, {}, {.NoScrollbar}) {
		h := im.GetContentRegionAvail().y
		for b in 0 ..= pm.BUSES {
			if b > 0 do im.SameLine()
			bus_strip(a, b, h)
		}
	}
	im.EndChild()
}

// --- the parts of a strip ------------------------------------------------------------------

// Small text, for slots, sends and readouts.
@(private)
small :: proc(a: ^App) { im.PushFontFloat(a.platform.fonts.regular, 12) }

// Text `s` in `color`, centred in [lo, hi] (clipped to it).
@(private)
text_in :: proc(dl: ^im.DrawList, lo, hi: im.Vec2, s: string, color: ui.Color, left := false) {
	c := fmt.ctprintf("%s", s)
	ts := im.CalcTextSize(c)
	x := lo.x + 5 if left else lo.x + max((hi.x - lo.x - ts.x) / 2, 4)
	im.DrawList_PushClipRect(dl, lo, {hi.x - 3, hi.y}, true)
	im.DrawList_AddText(dl, {math.round(x), math.round(lo.y + (hi.y - lo.y - ts.y) / 2)}, ui.col(color), c)
	im.DrawList_PopClipRect(dl)
}

// The colour of the wells in a strip (slots, readouts, meters): darker
// than the strip in either theme.
@(private)
well :: proc(t: ui.Theme) -> ui.Color {
	dark := 0.3 * t.bg.r + 0.59 * t.bg.g + 0.11 * t.bg.b < 0.5
	return t.bg if dark else ui.mix(t.raised, t.text, 0.1)
}

// The width inside a strip.
@(private)
inner_w :: proc() -> f32 { return STRIP_W - 2 * STRIP_PAD }

// A strip's background, `h` tall from the cursor; the cursor moves inside
// its padding.
@(private)
strip_begin :: proc(h: f32, selected: bool) {
	t := ui.theme()
	dl := im.GetWindowDrawList()
	pos := im.GetCursorScreenPos()
	bg := ui.mix(t.surface, t.raised, 0.55)
	im.DrawList_AddRectFilled(dl, pos, {pos.x + STRIP_W, pos.y + h}, ui.col(bg), t.radius)
	if selected do im.DrawList_AddRect(dl, pos, {pos.x + STRIP_W, pos.y + h}, ui.col(t.accent), t.radius, 1.5)
	im.SetCursorScreenPos({pos.x + STRIP_PAD, pos.y + STRIP_PAD})
	im.BeginGroup() // lines start inside the padding
}

@(private)
strip_end :: proc(top: im.Vec2, h: f32) {
	im.EndGroup()
	im.SetCursorScreenPos(top)
	im.Dummy({STRIP_W, h})
}

// Space between a strip's sections.
@(private)
gap :: proc(h: f32 = 4) {
	im.Dummy({inner_w(), h})
}

// The pad EQ's curve, as a thumbnail (Logic's EQ display); nil `eq` draws
// a flat, dim one. True when clicked.
@(private)
eq_thumb :: proc(eq: ^[3]f32, color: ui.Color) -> bool {
	t := ui.theme()
	dl := im.GetWindowDrawList()
	pos := im.GetCursorScreenPos()
	w := inner_w()
	clicked := im.InvisibleButton("##eq", {w, EQ_H})
	part("eq")
	hovered := im.IsItemHovered()
	im.DrawList_AddRectFilled(dl, pos, {pos.x + w, pos.y + EQ_H}, ui.col(well(t)), t.radius - 2)
	mid := pos.y + EQ_H / 2
	im.DrawList_AddLine(dl, {pos.x + 2, mid}, {pos.x + w - 2, mid}, ui.col(t.border), 1)
	if eq == nil do return false
	// Low shelf at 100 Hz, a bell near 900 Hz, high shelf at 8 kHz, on a
	// log axis from 20 Hz to 20 kHz; ±15 dB fills the height.
	gain_at :: proc(eq: ^[3]f32, x: f32) -> f32 {
		lf := x * 3 // decades above 20 Hz
		shelf :: proc(at, edge: f32) -> f32 { return 1 / (1 + math.exp(-(at - edge) * 5)) }
		low := 1 - shelf(lf, math.log10(f32(100) / 20))
		high := shelf(lf, math.log10(f32(8000) / 20))
		d := (lf - math.log10(f32(894) / 20)) * 2.2
		bell := math.exp(-d * d)
		return eq[0] * low + eq[1] * bell + eq[2] * high
	}
	flat := eq[0] == 0 && eq[1] == 0 && eq[2] == 0
	c := t.text_dim if flat else color
	if hovered do c = ui.lighten(c, 0.2)
	N :: 40
	pts: [N + 1]im.Vec2
	for k in 0 ..= N {
		x := f32(k) / N
		g := clamp(gain_at(eq, x), -15, 15)
		pts[k] = {pos.x + 2 + x * (w - 4), mid - g / 15 * (EQ_H / 2 - 3)}
	}
	if !flat do for k in 0 ..< N {
		a, b := pts[k], pts[k + 1]
		im.DrawList_AddQuadFilled(dl, a, b, {b.x, mid}, {a.x, mid}, ui.col(ui.with_alpha(c, 0.18)))
	}
	im.DrawList_AddPolyline(dl, &pts[0], N + 1, ui.col(c), 1.5)
	if hovered do im.SetTooltip("EQ: low %+.1f, mid %+.1f, high %+.1f dB", eq[0], eq[1], eq[2])
	return clicked
}

// One row of a strip: a dark well with `label` (an effect, a send, the
// output). Returns the row's corners and whether it was clicked.
@(private)
row :: proc(a: ^App, id: cstring, label: string, color: ui.Color, highlight := false) -> (lo, hi: im.Vec2, clicked: bool) {
	t := ui.theme()
	dl := im.GetWindowDrawList()
	lo = im.GetCursorScreenPos()
	hi = {lo.x + inner_w(), lo.y + ROW_H}
	clicked = im.InvisibleButton(id, {inner_w(), ROW_H})
	part(string(id)[2:]) // "##send B" → "A1 send B", "##slot 1" → "A1 slot 1"
	hovered := im.IsItemHovered()
	bg := t.accent if highlight else (t.hover if hovered else well(t))
	im.DrawList_AddRectFilled(dl, lo, hi, ui.col(bg), 3)
	small(a)
	text_in(dl, lo, hi, label, t.accent_text if highlight else color)
	im.PopFont()
	// The gap below it without an item: callers read the row's own state
	// (hovered, dragged, right-clicked) as the last item's.
	im.SetCursorPosY(im.GetCursorPosY() + 2)
	return
}

// An effect slot: its effect's name (dim when off); click to edit it in
// the Effects tab. An empty slot shows "+" under the mouse.
@(private)
slot_row :: proc(a: ^App, target: pm.Fx_Target, s: pm.Effect_Slot, failed: bool) {
	t := ui.theme()
	name := pm.slot_name(s) if s.kind != .None else ""
	if failed do name = fmt.tprintf("%s (missing)", name)
	color := t.text if s.on else t.text_dim
	if failed do color = t.danger
	_, _, clicked := row(a, fmt.ctprintf("##slot %d", target.slot + 1), name, color, a.fx == target)
	if s.kind == .None && im.IsItemHovered() {
		lo, hi := im.GetItemRectMin(), im.GetItemRectMax()
		small(a)
		text_in(im.GetWindowDrawList(), lo, hi, "+", t.text_dim)
		im.PopFont()
	}
	if clicked {
		a.fx = target
		show_detail(a, .Effects)
	}
	if s.kind != .None && im.IsItemHovered({.DelayShort}) do im.SetTooltip("%s", fmt.ctprintf("%s%s", pm.slot_name(s), "" if s.on else " (off)"))
}

// Pad `pad`'s send to bus `bus` (1..BUSES): the bus's name and a small
// knob. Drag up and down for its level (Shift: finer), double-click to
// turn it on at 0 dB or off, right-click for pre- or post-fader.
@(private)
send_row :: proc(a: ^App, pad, bus: int) {
	m := &a.m
	t := ui.theme()
	s := m.project.pads[pad].sends[bus - 1]
	on := s.level > 0
	letters := "ABCD"
	name := fmt.tprintf("%s %s", letters[bus - 1:][:1], "pre" if s.pre else "")
	lo, hi, _ := row(a, fmt.ctprintf("##send %s", letters[bus - 1:][:1]), "", t.text)
	dl := im.GetWindowDrawList()
	small(a)
	text_in(dl, lo, {hi.x - 18, hi.y}, name, t.text if on else t.text_dim, left = true)
	im.PopFont()
	// The knob.
	db := pm.send_db(s)
	frac := (db - pm.SEND_MIN_DB) / (6 - pm.SEND_MIN_DB)
	c := im.Vec2{hi.x - 10, (lo.y + hi.y) / 2}
	r: f32 = 6.5
	a0 := f32(math.PI) * 0.75
	sweep := f32(math.PI) * 1.5
	im.DrawList_PathArcTo(dl, c, r, a0, a0 + sweep, 20)
	im.DrawList_PathStroke(dl, ui.col(t.raised), 2.5)
	if on {
		im.DrawList_PathArcTo(dl, c, r, a0, a0 + sweep * frac, 20)
		im.DrawList_PathStroke(dl, ui.col(t.warn if s.pre else t.accent), 2.5)
	}
	// Input: on the row's button (the last item before the knob drawing).
	v := db
	e := ui_drag(&v, pm.SEND_MIN_DB, 6, 0, 140)
	if im.IsItemHovered() && im.IsMouseDoubleClicked(.Left) {
		v = pm.SEND_MIN_DB if on else 0
		e.changed, e.ended = true, true
	}
	if e.changed do pm.set_send_db(m, pad, bus, v)
	if e.ended do app.seal(&m.history)
	if im.BeginPopupContextItem(fmt.ctprintf("##sendmenu%d", bus)) {
		if im.MenuItem("Pre-fader", nil, s.pre) do pm.set_send_pre(m, pad, bus, !s.pre)
		if im.MenuItem("Off", nil, false, on) {
			pm.set_send_db(m, pad, bus, pm.SEND_MIN_DB)
			app.seal(&m.history)
		}
		im.EndPopup()
	}
	if im.IsItemHovered({.DelayShort}) && !im.IsItemActive() {
		im.SetTooltip("%s", fmt.ctprintf("Send to %s: %s, %s-fader", pm.bus_name(bus), "off" if !on else fmt.tprintf("%+.1f dB", db), "pre" if s.pre else "post"))
	}
}

// Dragging the last item changes `value` (as ui's knobs do; the press
// itself doesn't move it), and double-click is left to the caller.
@(private)
ui_drag :: proc(value: ^f32, lo, hi, default, range_px: f32) -> (e: ui.Edit) {
	io := im.GetIO()
	if im.IsItemActivated() do e.started = true
	if im.IsItemActive() && !e.started {
		e.active = true
		d := -io.MouseDelta.y
		if d != 0 {
			speed := (hi - lo) / range_px
			if io.KeyShift do speed *= 0.1
			v := clamp(value^ + d * speed, lo, hi)
			if v != value^ {
				value^ = v
				e.changed = true
			}
		}
	}
	if im.IsItemDeactivated() do e.ended = true
	if im.IsItemHovered() && io.MouseWheel != 0 && !im.IsItemActive() {
		v := clamp(value^ + io.MouseWheel * (hi - lo) * 0.02, lo, hi)
		if v != value^ {
			value^ = v
			e.changed, e.ended = true, true
		}
	}
	return
}

// Where a strip's sound goes: Main or a bus; click to pick.
@(private)
output_row :: proc(a: ^App, pad: int) {
	m := &a.m
	t := ui.theme()
	cur := int(m.project.pads[pad].bus)
	_, _, clicked := row(a, "##output", pm.bus_name(cur), t.text)
	if clicked do im.OpenPopup("##outmenu")
	if im.BeginPopup("##outmenu") {
		for b in 0 ..= pm.BUSES do if im.MenuItem(fmt.ctprintf("%s", pm.bus_name(b)), nil, b == cur) do pm.set_pad_bus(m, pad, b)
		im.EndPopup()
	}
}

// A small pan knob, centred in the strip: drag up and down, double-click
// to centre.
@(private)
pan_knob :: proc(a: ^App, pan: ^f32) -> ui.Edit {
	t := ui.theme()
	dl := im.GetWindowDrawList()
	pos := im.GetCursorScreenPos()
	w := inner_w()
	im.InvisibleButton("##pan", {w, PAN_H})
	part("pan")
	e := ui_drag(pan, -1, 1, 0, 120)
	if im.IsItemHovered() && im.IsMouseDoubleClicked(.Left) {
		pan^ = 0
		e.changed, e.ended = true, true
	}
	r: f32 = 10
	c := im.Vec2{pos.x + w / 2, pos.y + r + 1}
	a0 := f32(math.PI) * 0.75
	sweep := f32(math.PI) * 1.5
	top := a0 + sweep / 2
	im.DrawList_AddCircleFilled(dl, c, r - 3, ui.col(t.raised), 24)
	im.DrawList_PathArcTo(dl, c, r, a0, a0 + sweep, 24)
	im.DrawList_PathStroke(dl, ui.col(well(t)), 3)
	at := top + pan^ * sweep / 2
	if abs(pan^) > 0.005 {
		im.DrawList_PathArcTo(dl, c, r, min(top, at), max(top, at), 16)
		im.DrawList_PathStroke(dl, ui.col(t.accent), 3)
	}
	im.DrawList_AddLine(dl, c, {c.x + math.cos(at) * (r - 2), c.y + math.sin(at) * (r - 2)}, ui.col(t.text), 1.5)
	text := "C"
	if pan^ < -0.005 do text = fmt.tprintf("L%.0f", -pan^ * 100)
	if pan^ > 0.005 do text = fmt.tprintf("R%.0f", pan^ * 100)
	small(a)
	text_in(dl, {pos.x, c.y + r - 1}, {pos.x + w, pos.y + PAN_H + 2}, text, t.text_dim)
	im.PopFont()
	return e
}

// Where `db` sits on a fader (0 at the bottom, 1 at the top): Logic's
// taper, wider near 0 dB.
@(private)
fader_frac :: proc(db: f32) -> f32 {
	if db <= FADER_LO do return 0
	return math.pow(clamp((db - FADER_LO) / (FADER_HI - FADER_LO), 0, 1), 1.5)
}

@(private)
fader_db :: proc(frac: f32) -> f32 {
	return FADER_LO + math.pow(clamp(frac, 0, 1), 1 / 1.5) * (FADER_HI - FADER_LO)
}

// The fader's value and the loudest peak since reset, as Logic shows them
// above the fader (click the peak to reset it).
@(private)
readouts :: proc(a: ^App, db: f32, view: ^[2]Meter_View) {
	t := ui.theme()
	dl := im.GetWindowDrawList()
	pos := im.GetCursorScreenPos()
	w := (inner_w() - 3) / 2
	h: f32 = 17
	peak := max(view[0].max, view[1].max)
	pk_db := 20 * math.log10(peak) if peak > 0 else -math.F32_MAX
	small(a)
	for k in 0 ..< 2 {
		lo := im.Vec2{pos.x + f32(k) * (w + 3), pos.y}
		hi := im.Vec2{lo.x + w, lo.y + h}
		im.DrawList_AddRectFilled(dl, lo, hi, ui.col(well(t)), 3)
		if k == 0 {
			text_in(dl, lo, hi, "-inf" if db <= FADER_LO else fmt.tprintf("%.1f", db), t.text)
		} else {
			hot := pk_db > 0
			if hot do im.DrawList_AddRectFilled(dl, lo, hi, ui.col(t.danger), 3)
			text_in(dl, lo, hi, "-inf" if pk_db < -60 else fmt.tprintf("%.1f", pk_db), t.bg if hot else t.text_dim)
		}
	}
	im.PopFont()
	im.SetCursorScreenPos({pos.x + w + 3, pos.y})
	if im.InvisibleButton("##peak", {w, h}) do for &v in view do v.max = 0
	part("peak")
	if im.IsItemHovered({.DelayShort}) do im.SetTooltip("Peak since reset: click to reset")
	im.SetCursorScreenPos({pos.x, pos.y + h + 4})
}

// The fader, a dB scale, and the stereo meter, `h` tall.
@(private)
fader_meter :: proc(a: ^App, value: ^f32, view: ^[2]Meter_View, h: f32) -> (e: ui.Edit) {
	t := ui.theme()
	dl := im.GetWindowDrawList()
	pos := im.GetCursorScreenPos()
	w := inner_w()
	fader_w: f32 = 24
	meter_w: f32 = 5
	scale_w: f32 = 20
	total := fader_w + scale_w + 2 * meter_w + 2
	x0 := pos.x + (w - total) / 2
	top, bottom := pos.y + 6, pos.y + h - 6
	y_of :: proc(frac, top, bottom: f32) -> f32 { return bottom - (bottom - top) * frac }

	// The fader.
	im.SetCursorScreenPos({x0, pos.y})
	im.InvisibleButton("##fader", {fader_w, h})
	part("fader")
	frac := fader_frac(value^)
	f := frac
	e = ui_drag(&f, 0, 1, 0, bottom - top)
	if e.changed do value^ = fader_db(f)
	if im.IsItemHovered() && im.IsMouseDoubleClicked(.Left) {
		value^ = 0
		e.changed, e.ended = true, true
	}
	hovered := im.IsItemHovered() || im.IsItemActive()
	cx := x0 + fader_w / 2
	im.DrawList_AddRectFilled(dl, {cx - 2, top}, {cx + 2, bottom}, ui.col(well(t)), 2)
	y := y_of(fader_frac(value^), top, bottom)
	cap := t.hover if hovered else t.pressed
	im.DrawList_AddRectFilled(dl, {x0 + 1, y - 9}, {x0 + fader_w - 1, y + 9}, ui.col(cap), 3)
	im.DrawList_AddLine(dl, {x0 + 4, y}, {x0 + fader_w - 4, y}, ui.col(t.text), 1.5)
	if im.IsItemActive() do im.SetTooltip("%s", fmt.ctprintf("%+.1f dB", value^))

	// The scale: marks between the fader and the meter.
	sx := x0 + fader_w + 1
	small(a)
	last := -max(f32)
	for db in ([]f32{6, 0, -6, -12, -24, -40}) {
		yy := y_of(fader_frac(db), top, bottom)
		label := fmt.ctprintf("+%d" if db > 0 else "%d", int(abs(db)))
		ts := im.CalcTextSize(label)
		if yy - last < ts.y do continue // too close to the one above on a short fader
		last = yy
		im.DrawList_AddText(dl, {sx + scale_w - ts.x - 2, yy - ts.y / 2}, ui.col(ui.with_alpha(t.text_dim, 0.8)), label)
		im.DrawList_AddLine(dl, {sx + scale_w - 1, yy}, {sx + scale_w + 2 * meter_w + 2, yy}, ui.col(ui.with_alpha(t.border, 0.6)), 1)
	}
	im.PopFont()

	// The meter, on the fader's scale: green, then yellow above -12 dB, red
	// above 0.
	mx := sx + scale_w
	for c in 0 ..< 2 {
		x := mx + f32(c) * (meter_w + 2)
		im.DrawList_AddRectFilled(dl, {x, top}, {x + meter_w, bottom}, ui.col(well(t)), 1)
		v := view[c]
		lvl := fader_frac(20 * math.log10(v.peak)) if v.peak > 0 else 0
		if lvl > 0 {
			yy := y_of(lvl, top, bottom)
			y12 := y_of(fader_frac(-12), top, bottom)
			y0 := y_of(fader_frac(0), top, bottom)
			im.DrawList_AddRectFilled(dl, {x, max(yy, y12)}, {x + meter_w, bottom}, ui.col(t.ok), 1)
			if yy < y12 do im.DrawList_AddRectFilled(dl, {x, max(yy, y0)}, {x + meter_w, y12}, ui.col(t.warn), 1)
			if yy < y0 do im.DrawList_AddRectFilled(dl, {x, yy}, {x + meter_w, y0}, ui.col(t.danger), 1)
		}
		if v.hold > 0 {
			hy := y_of(fader_frac(20 * math.log10(v.hold)), top, bottom)
			im.DrawList_AddLine(dl, {x, hy}, {x + meter_w, hy}, ui.col(t.text), 1.5)
		}
	}
	im.SetCursorScreenPos({pos.x, pos.y + h})
	im.Dummy({w, 0})
	return
}

// Mute and Solo (Mute alone without `solo`), as Logic colours them.
@(private)
mute_solo :: proc(a: ^App, mute, solo: ^bool) -> (changed: bool) {
	t := ui.theme()
	n := 2 if solo != nil else 1
	w := (inner_w() - 4) / 2 if n == 2 else inner_w()
	dl := im.GetWindowDrawList()
	for which in 0 ..< n {
		on := mute if which == 0 else solo
		if which == 1 do im.SameLine(0, 4)
		pos := im.GetCursorScreenPos()
		pressed := im.InvisibleButton("M##m" if which == 0 else "S##s", {w, ROW_H})
		part("mute" if which == 0 else "solo")
		if pressed {
			on^ = !on^
			changed = true
		}
		hovered := im.IsItemHovered()
		c := ui.rgb(0x3d9cf5) if which == 0 else t.warn
		bg := c if on^ else (t.hover if hovered else well(t))
		im.DrawList_AddRectFilled(dl, pos, {pos.x + w, pos.y + ROW_H}, ui.col(bg), 3)
		im.PushFontFloat(a.platform.fonts.semibold, 12)
		text_in(dl, pos, {pos.x + w, pos.y + ROW_H}, "M" if which == 0 else "S", t.bg if on^ else t.text_dim)
		im.PopFont()
		if hovered do im.SetTooltip("Mute" if which == 0 else "Solo")
	}
	return
}

// The strip's name on its colour, at the bottom. True when clicked.
@(private)
name_plate :: proc(name: string, color: ui.Color) -> bool {
	t := ui.theme()
	dl := im.GetWindowDrawList()
	pos := im.GetCursorScreenPos()
	h: f32 = 21
	clicked := im.InvisibleButton("##name", {inner_w(), h})
	part("name")
	im.DrawList_AddRectFilled(dl, pos, {pos.x + inner_w(), pos.y + h}, ui.col(color), 3)
	// Dark or light text, for the colour.
	lum := 0.3 * color.r + 0.59 * color.g + 0.11 * color.b
	text_in(dl, pos, {pos.x + inner_w(), pos.y + h}, name, ui.rgb(0x111214) if lum > 0.55 else ui.rgb(0xffffff))
	_ = t
	return clicked
}

// The height a strip's fader gets: what is left of `h` after the rest.
@(private)
fader_h :: proc(h: f32) -> f32 {
	fixed: f32 = 2 * STRIP_PAD + EQ_H + 4 + SLOT_ROWS * (ROW_H + 2) + 4 + (ROW_H + 2) + 4 + PAN_H + 4 + 21 + 4 + ROW_H + 4 + 21
	return max(h - fixed, 90)
}

// --- strips --------------------------------------------------------------------------------

// Pad `i`'s strip, `h` tall.
@(private)
pad_strip :: proc(a: ^App, i: int, h: f32) {
	m := &a.m
	pad := m.project.pads[i]
	im.PushIDInt(i32(i))
	defer im.PopID()
	strip_name = pm.pad_label(i)
	top := im.GetCursorScreenPos()
	strip_begin(h, a.selected == i)
	defer strip_end(top, h)
	t := ui.theme()
	color := ui.rgb(pad.color)

	eq := pad.eq
	if eq_thumb(&eq, color) {
		a.selected = i
		show_detail(a, .Pad)
	}
	gap()
	for s, k in pad.inserts {
		failed := pm.slot_failed(&m.engine, i, -1, k)
		slot_row(a, {.Pad, i, k}, s, failed)
	}
	for b in 1 ..= pm.BUSES do send_row(a, i, b)
	gap()
	output_row(a, i)
	gap()
	pan := pad.pan
	pe := pan_knob(a, &pan)
	if pe.changed {
		p := pad
		p.pan = pan
		pm.set_pad(m, i, .Pan, "Set Pan", p)
	}
	if pe.ended do app.seal(&m.history)
	gap()
	vol := pad.volume
	readouts(a, vol, &a.mixer.pads[i])
	fe := fader_meter(a, &vol, &a.mixer.pads[i], fader_h(h))
	if fe.changed {
		p := pad
		p.volume = vol
		pm.set_pad(m, i, .Volume, "Set Volume", p)
	}
	if fe.ended do app.seal(&m.history)
	gap()
	mute, solo := pad.mute, pad.solo
	if mute_solo(a, &mute, &solo) {
		p := pad
		p.mute, p.solo = mute, solo
		pm.set_pad(m, i, .Mute if mute != pad.mute else .Solo, "Mute" if mute != pad.mute else "Solo", p)
		app.seal(&m.history)
	}
	gap()
	if name_plate(fmt.tprintf("%s %s", pm.pad_label(i), pm.pad_name(&m.project.pads[i])), color) do a.selected = i
	_ = t
}

// Bus `b`'s strip (BUSES: main), `h` tall.
@(private)
bus_strip :: proc(a: ^App, b: int, h: f32) {
	m := &a.m
	bus := pm.bus_of(m, b)^
	im.PushIDInt(i32(1000 + b))
	defer im.PopID()
	strip_name = pm.bus_name(0 if b == pm.BUSES else b + 1)
	top := im.GetCursorScreenPos()
	strip_begin(h, false)
	defer strip_end(top, h)
	t := ui.theme()
	is_main := b == pm.BUSES

	eq_thumb(nil, t.text_dim) // buses have no EQ: a flat, dim display keeps the rows in line
	gap()
	for s, k in bus.slots do slot_row(a, {.Bus, b, k}, s, pm.slot_failed(&m.engine, -1, b, k))
	for _ in pm.BUS_SLOTS ..< SLOT_ROWS do im.Dummy({inner_w(), ROW_H + 2})
	gap()
	row(a, "##output", "Main" if !is_main else "Output", t.text_dim)
	gap()
	pan := bus.pan
	pe := pan_knob(a, &pan)
	if pe.changed {
		nb := bus
		nb.pan = pan
		pm.set_bus(m, b, 2, "Set Pan", nb)
	}
	if pe.ended do app.seal(&m.history)
	gap()
	vol := bus.volume
	readouts(a, vol, &a.mixer.buses[b])
	fe := fader_meter(a, &vol, &a.mixer.buses[b], fader_h(h))
	if fe.changed {
		nb := bus
		nb.volume = vol
		pm.set_bus(m, b, 0, "Set Volume", nb)
	}
	if fe.ended do app.seal(&m.history)
	gap()
	mute, solo := bus.mute, bus.solo
	if mute_solo(a, &mute, nil if is_main else &solo) {
		nb := bus
		nb.mute, nb.solo = mute, solo
		pm.set_bus(m, b, 1, "Mute" if mute != bus.mute else "Solo", nb)
		app.seal(&m.history)
	}
	gap()
	name_plate(pm.bus_name(0 if is_main else b + 1), t.accent if is_main else ui.mix(t.accent, t.text_dim, 0.55))
}
