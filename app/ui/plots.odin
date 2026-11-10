package ui

import "core:math"

import im "deps:imgui"

// Plots that show what a sound does: an envelope to drag, a filter's
// response, an LFO's trace. Each on black, with a live mark of what is
// playing now, so a change is seen as it is heard.

// The background plots draw on.
PLOT_BG :: Color{0, 0, 0, 1}

// The handle being dragged in a plot (one gesture at a time).
@(private)
plot_drag: struct {
	id:     im.ID,
	handle: int,
}

// Seconds an ADSR segment can span (attack and decay up to 10, release 20).
@(private)
ADSR_MAX :: [4]f32{10, 10, 1, 20}

// Width (0..1 of the plot) a segment of `t` seconds takes: logarithmic, so
// short and long times can both be seen and set.
@(private)
seg_w :: proc "contextless" (t, max_t: f32) -> f32 {
	return 0.3 * math.log10(1 + max(t, 0) * 100) / math.log10(1 + max_t * 100)
}

// The inverse of `seg_w`.
@(private)
seg_t :: proc "contextless" (w, max_t: f32) -> f32 {
	x := clamp(w, 0, 0.3) / 0.3 * math.log10(1 + max_t * 100)
	return (math.pow(10, x) - 1) / 100
}

// An envelope as a curve to drag, `size` big: `adsr` is attack, decay
// (seconds), sustain (0..1) and release (seconds). Drag the attack's peak
// sideways, the decay's end (sustain) anywhere, the release's end
// sideways. `live_level` (0..1, -1: nothing) and `live_t` (seconds since
// the note started) mark what plays now. `amount` scales the curve's
// height (a negative amount draws it upside down, for a pitch or filter
// envelope's depth). Names its handles for the probe: "<id> attack" and so on.
adsr_plot :: proc(id: cstring, adsr: ^[4]f32, size: im.Vec2, color: Color, live_level: f32 = -1, live_t: f32 = -1, amount: f32 = 1) -> (e: Edit) {
	im.PushID(id)
	defer im.PopID()
	t := current
	dl := im.GetWindowDrawList()
	pos := im.GetCursorScreenPos()
	w, h := size.x, size.y
	im.InvisibleButton("##adsr", size)
	name(string(id))
	gid := im.GetItemID()
	hovered := im.IsItemHovered()
	pad: f32 = 10
	x0, x1 := pos.x + pad, pos.x + w - pad
	top, bottom := pos.y + pad, pos.y + h - pad
	iw := x1 - x0
	base := bottom if amount >= 0 else top
	ys :: proc(level, amount, top, bottom: f32) -> f32 {
		a := abs(amount)
		v := level * max(a, 0.15) // a small depth still reads as a curve
		return bottom - v * (bottom - top) if amount >= 0 else top + v * (bottom - top)
	}
	a, d, s, r := adsr[0], adsr[1], adsr[2], adsr[3]
	pa := im.Vec2{x0 + iw * seg_w(a, ADSR_MAX[0]), ys(1, amount, top, bottom)}
	pd := im.Vec2{pa.x + iw * seg_w(d, ADSR_MAX[1]), ys(s, amount, top, bottom)}
	hold := iw * 0.1
	ps := im.Vec2{pd.x + hold, pd.y}
	pr := im.Vec2{ps.x + iw * seg_w(r, ADSR_MAX[3]), base}

	// Black, a grid of quarters, the baseline.
	im.DrawList_AddRectFilled(dl, pos, {pos.x + w, pos.y + h}, col(PLOT_BG), t.radius)
	grid := mix(PLOT_BG, t.text, 0.08)
	for k in 1 ..< 4 {
		y := top + (bottom - top) * f32(k) / 4
		im.DrawList_AddLine(dl, {x0, y}, {x1, y}, col(grid), 1)
	}
	im.DrawList_AddLine(dl, {x0, base}, {x1, base}, col(mix(PLOT_BG, t.text, 0.2)), 1)

	// The curve: a line up, exponential falls (as the engine's), held, then
	// released; filled under.
	pts := make([dynamic]im.Vec2, 0, 96, context.temp_allocator)
	append(&pts, im.Vec2{x0, base}, pa)
	N :: 24
	for k in 1 ..= N {
		u := f32(k) / N
		lv := s + (1 - s) * math.pow(f32(0.001), u)
		append(&pts, im.Vec2{pa.x + (pd.x - pa.x) * u, ys(lv, amount, top, bottom)})
	}
	append(&pts, ps)
	for k in 1 ..= N {
		u := f32(k) / N
		lv := s * math.pow(f32(0.001), u)
		append(&pts, im.Vec2{ps.x + (pr.x - ps.x) * u, ys(lv, amount, top, bottom)})
	}
	fill := color
	fill.a = 0.18
	for k in 1 ..< len(pts) {
		p, q := pts[k - 1], pts[k]
		im.DrawList_AddQuadFilled(dl, {p.x, base}, p, q, {q.x, base}, col(fill))
	}
	im.DrawList_AddPolyline(dl, &pts[0], i32(len(pts)), col(color), 2)

	// Now: a glow along the level, and a dot where the note is.
	if live_level >= 0 {
		ly := ys(live_level, amount, top, bottom)
		glow := color
		glow.a = 0.35
		im.DrawList_AddLine(dl, {x0, ly}, {x1, ly}, col(glow), 1)
		lx := ps.x - hold / 2
		if live_t >= 0 && live_t < a do lx = x0 + (pa.x - x0) * live_t / max(a, 1e-6)
		else if live_t >= 0 && live_t < a + d * 3 do lx = pa.x + (pd.x - pa.x) * clamp((live_t - a) / max(d, 1e-6) / 3, 0, 1)
		im.DrawList_AddCircleFilled(dl, {lx, ly}, 7, col(Color{color.r, color.g, color.b, 0.3}), 16)
		im.DrawList_AddCircleFilled(dl, {lx, ly}, 4, col(lighten(color, 0.5)), 16)
	}

	// Handles: hover shows the nearest; a press picks it.
	handles := [3]im.Vec2{pa, pd, pr}
	io := im.GetIO()
	mouse := io.MousePos
	near := -1
	best: f32 = 14 * 14
	for hp, k in handles {
		dx, dy := mouse.x - hp.x, mouse.y - hp.y
		if dx * dx + dy * dy < best {
			best = dx * dx + dy * dy
			near = k
		}
	}
	if im.IsItemActivated() {
		plot_drag = {gid, near}
		e.started = near >= 0
	}
	dragging := im.IsItemActive() && plot_drag.id == gid && plot_drag.handle >= 0
	for hp, k in handles {
		on := (dragging && plot_drag.handle == k) || (!im.IsItemActive() && hovered && near == k)
		im.DrawList_AddCircleFilled(dl, hp, 6 if on else 4.5, col(t.text if on else lighten(color, 0.3)), 16)
		im.DrawList_AddCircle(dl, hp, 6 if on else 4.5, col(PLOT_BG), 16, 1.5)
	}
	if dragging {
		e.active = true
		switch plot_drag.handle {
		case 0: adsr[0] = clamp(seg_t((mouse.x - x0) / iw, ADSR_MAX[0]), 0.0005, ADSR_MAX[0])
		case 1:
			adsr[1] = clamp(seg_t((mouse.x - pa.x) / iw, ADSR_MAX[1]), 0.005, ADSR_MAX[1])
			lv := (bottom - mouse.y) / (bottom - top) if amount >= 0 else (mouse.y - top) / (bottom - top)
			adsr[2] = clamp(lv / max(abs(amount), 0.15), 0, 1)
		case 2: adsr[3] = clamp(seg_t((mouse.x - ps.x) / iw, ADSR_MAX[3]), 0.005, ADSR_MAX[3])
		}
		e.changed = adsr^ != {a, d, s, r}
	}
	if im.IsItemDeactivated() && plot_drag.id == gid {
		e.ended = plot_drag.handle >= 0
		plot_drag = {}
	}
	return
}

// One curve of a `response_plot`: `db` at log-spaced frequencies from
// 20 Hz to 20 kHz (any count ≥ 2).
Plot_Curve :: struct {
	db:    []f32,
	color: Color,
	fill:  bool, // shade under it
	width: f32,  // its line (0: 2)
}

// Frequency ↔ the plot's 0..1 axis (log, 20 Hz to 20 kHz).
freq_x :: proc "contextless" (hz: f32) -> f32 { return math.log10(clamp(hz, 20, 20_000) / 20) / 3 }
// The frequency at 0..1 along a response plot.
x_freq :: proc "contextless" (x: f32) -> f32 { return 20 * math.pow(10, clamp(x, 0, 1) * 3) }

// A frequency response, `size` big, from `lo_db` to `hi_db`: the curves
// (the first one shaded under, if it asks), decades and 0 dB marked, and a
// handle at `handle` (x 0..1 along the log axis, y in dB) to drag; `handle`
// changes while it is dragged (x and y), with Shift for fine.
response_plot :: proc(id: cstring, curves: []Plot_Curve, handle: ^[2]f32, size: im.Vec2, lo_db: f32 = -36, hi_db: f32 = 24) -> (e: Edit) {
	im.PushID(id)
	defer im.PopID()
	t := current
	dl := im.GetWindowDrawList()
	pos := im.GetCursorScreenPos()
	w, h := size.x, size.y
	im.InvisibleButton("##response", size)
	name(string(id))
	pad: f32 = 8
	x0, x1 := pos.x + pad, pos.x + w - pad
	top, bottom := pos.y + pad, pos.y + h - pad
	ydb :: proc(db, lo, hi, top, bottom: f32) -> f32 { return bottom - (clamp(db, lo, hi) - lo) / (hi - lo) * (bottom - top) }
	im.DrawList_AddRectFilled(dl, pos, {pos.x + w, pos.y + h}, col(PLOT_BG), t.radius)
	grid := mix(PLOT_BG, t.text, 0.08)
	for f in ([?]f32{50, 100, 200, 500, 1000, 2000, 5000, 10_000}) {
		x := x0 + (x1 - x0) * freq_x(f)
		im.DrawList_AddLine(dl, {x, top}, {x, bottom}, col(mix(PLOT_BG, t.text, 0.16) if f == 100 || f == 1000 || f == 10_000 else grid), 1)
	}
	for db := lo_db; db <= hi_db; db += 12 {
		y := ydb(db, lo_db, hi_db, top, bottom)
		im.DrawList_AddLine(dl, {x0, y}, {x1, y}, col(mix(PLOT_BG, t.text, 0.22) if db == 0 else grid), 1)
	}
	labels := [3]cstring{"100", "1k", "10k"}
	for f, k in ([3]f32{100, 1000, 10_000}) {
		x := x0 + (x1 - x0) * freq_x(f)
		im.DrawList_AddText(dl, {x + 3, bottom - im.GetTextLineHeight()}, col(mix(PLOT_BG, t.text, 0.4)), labels[k])
	}
	for c in curves {
		n := len(c.db)
		if n < 2 do continue
		pts := make([]im.Vec2, n, context.temp_allocator)
		for v, k in c.db do pts[k] = {x0 + (x1 - x0) * f32(k) / f32(n - 1), ydb(v, lo_db, hi_db, top, bottom)}
		if c.fill {
			fill := c.color
			fill.a = 0.2
			for k in 1 ..< n do im.DrawList_AddQuadFilled(dl, {pts[k - 1].x, bottom}, pts[k - 1], pts[k], {pts[k].x, bottom}, col(fill))
		}
		im.DrawList_AddPolyline(dl, &pts[0], i32(n), col(c.color), c.width if c.width > 0 else 2)
	}
	if handle == nil do return
	hp := im.Vec2{x0 + (x1 - x0) * handle[0], ydb(handle[1], lo_db, hi_db, top, bottom)}
	hot := im.IsItemHovered() || im.IsItemActive()
	im.DrawList_AddCircleFilled(dl, hp, 7 if hot else 5.5, col(t.text if hot else lighten(t.accent, 0.4)), 16)
	im.DrawList_AddCircle(dl, hp, 7 if hot else 5.5, col(PLOT_BG), 16, 1.5)
	if im.IsItemActivated() do e.started = true
	if im.IsItemActive() && !e.started {
		io := im.GetIO()
		d := io.MouseDelta
		if d.x != 0 || d.y != 0 {
			k: f32 = 0.1 if io.KeyShift else 1
			handle[0] = clamp(handle[0] + d.x * k / (x1 - x0), 0, 1)
			handle[1] = clamp(handle[1] - d.y * k * (hi_db - lo_db) / (bottom - top), lo_db, hi_db)
			e.changed, e.active = true, true
		}
	}
	if im.IsItemDeactivated() do e.ended = true
	return
}

// A modulation source's trace, `size` big: `history` (-1..1, oldest first;
// a ring whose newest is just before `head`) scrolling right to left, with
// a dot at its newest level, over `shape` (one cycle of its waveform,
// -1..1) drawn faintly behind.
trace_plot :: proc(id: cstring, history: []f32, head: int, shape: []f32, size: im.Vec2, color: Color) {
	im.PushID(id)
	defer im.PopID()
	t := current
	dl := im.GetWindowDrawList()
	pos := im.GetCursorScreenPos()
	w, h := size.x, size.y
	im.Dummy(size)
	name(string(id))
	pad: f32 = 8
	x0, x1 := pos.x + pad, pos.x + w - pad
	mid := pos.y + h / 2
	amp := h / 2 - pad
	im.DrawList_AddRectFilled(dl, pos, {pos.x + w, pos.y + h}, col(PLOT_BG), t.radius)
	im.DrawList_AddLine(dl, {x0, mid}, {x1, mid}, col(mix(PLOT_BG, t.text, 0.18)), 1)
	if len(shape) >= 2 {
		faint := color
		faint.a = 0.22
		pts := make([]im.Vec2, len(shape) * 2, context.temp_allocator)
		for k in 0 ..< len(pts) {
			v := shape[k % len(shape)]
			pts[k] = {x0 + (x1 - x0) * f32(k) / f32(len(pts) - 1), mid - v * amp}
		}
		im.DrawList_AddPolyline(dl, &pts[0], i32(len(pts)), col(faint), 1.5)
	}
	n := len(history)
	if n < 2 do return
	pts := make([]im.Vec2, n, context.temp_allocator)
	for k in 0 ..< n {
		v := history[(head + k) % n]
		pts[k] = {x0 + (x1 - x0) * f32(k) / f32(n - 1), mid - clamp(v, -1, 1) * amp}
	}
	im.DrawList_AddPolyline(dl, &pts[0], i32(n), col(color), 2)
	last := pts[n - 1]
	im.DrawList_AddCircleFilled(dl, last, 8, col(Color{color.r, color.g, color.b, 0.3}), 16)
	im.DrawList_AddCircleFilled(dl, last, 4.5, col(lighten(color, 0.5)), 16)
}
