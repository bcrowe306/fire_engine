package ui

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"

import im "deps:imgui"

// --- waveform -----------------------------------------------------------------------------

// One column of a waveform overview: the lowest and highest sample in it.
Peak :: struct {
	lo, hi: f32,
}

// Reduces `samples` to `columns` peaks (for `waveform`). Allocated with
// `allocator`.
peaks_of :: proc(samples: []f32, columns: int, allocator := context.allocator) -> []Peak {
	out := make([]Peak, max(columns, 1), allocator)
	if len(samples) == 0 do return out
	per := f64(len(samples)) / f64(len(out))
	for &p, i in out {
		a := int(f64(i) * per)
		b := max(int(f64(i + 1) * per), a + 1)
		lo, hi := samples[a], samples[a]
		for s in samples[a:min(b, len(samples))] {
			lo, hi = min(lo, s), max(hi, s)
		}
		p = {lo, hi}
	}
	return out
}

// A marker on a waveform: a position in frames and how it looks.
Marker :: struct {
	frame: i64,
	color: Color,
	label: string, // drawn at the top (a tag, which drags as the line does); "" = none
	drag:  bool,   // the user may drag it
	// A fade's handle: a square at the top at `frame`, with a ramp drawn
	// from `from` (the region's edge it fades from) to it.
	fade:  bool,
	from:  i64,
}

// The visible part of a waveform, in frames.
Wave_View :: struct {
	start, end: f64,
}

// What the user did to a waveform this frame.
Wave_Edit :: struct {
	marker:      int,  // the marker being dragged, or -1
	marker_to:   i64,  // where to (when `moved`)
	moved:       bool,
	released:    bool, // a marker drag ended
	selected:    bool, // the selection changed
	clicked:     bool, // clicked (not dragged) at `click_frame`
	click_frame: i64,
	zoomed:      bool,
	add_at:      i64,  // double-clicked here (`Wave_Options.editable`): a marker to add; -1 = none
	remove:      int,  // a marker right-clicked (`editable`): to take away; -1 = none
	gain:        int,  // a level line being dragged (`Wave_Options.gains`), or -1
	gain_db:     f32,  // ... to this
	gain_released: bool, // a level drag ended
}

// What else a waveform shows and lets you do (see `waveform`).
Wave_Options :: struct {
	rate:          f64,  // the sound's sample rate: a time ruler along the bottom (0: none)
	beat_frames:   f64,  // a beat, in frames: the ruler in bars and beats instead of seconds (0: seconds)
	beats_per_bar: int,  // (0: 4)
	scale:         bool, // a dB scale down the left, lines at -6 dB
	overview:      bool, // a strip under it: the whole sound and the part shown (drag it to pan)
	editable:      bool, // double-click adds a marker (`add_at`), right-click one takes it away (`remove`)
	gains:         []Wave_Gain, // level lines (a slice's), dragged up and down
	pyramid:       ^Peak_Pyramid, // the sound's peaks at every zoom: drawn at the resolution of the pixels shown (else `peaks`, stretched)
	backdrop:      []f32, // a spectrum to draw faint behind it, in its tint (dB, -60 at the floor, along a log frequency axis left to right; nil: none)
}

// A level line over part of a waveform: `db` (-24..+6) from `from` to `to`.
Wave_Gain :: struct {
	from, to: i64,
	db:       f32,
}

// A waveform of `frames` frames shown through `view` (zoom with the wheel,
// pan with Shift+wheel), drawn from `peaks` (of the whole sound), with
// `markers` (start, end, loop points, slices) that can be dragged and a
// selection dragged out with the mouse.
// The waveform editor's background: black, whatever the theme.
WAVE_BG :: Color{0, 0, 0, 1}

// How far below the top fade handles sit (under the tags).
@(private) FADE_ROW :: 24

// Where marker `m` (its line at `x`) shows its grab handle: its tag, or a
// fade's square (empty: neither).
@(private)
marker_handle :: proc(m: Marker, x: f32, pos, size: im.Vec2) -> (lo, hi: im.Vec2) {
	if m.fade {
		// On a row below the tags (a fade of 0 sits on its S or E line).
		hs: f32 = 10
		y := pos.y + FADE_ROW
		return {x - hs / 2, y}, {x + hs / 2, y + hs}
	}
	if m.label == "" do return
	lc := strings.clone_to_cstring(m.label, context.temp_allocator)
	ls := im.CalcTextSize(lc)
	// The tag hangs right of its line, or left of it at the right edge.
	tx := x if x + ls.x + 8 <= pos.x + size.x else x - ls.x - 8
	return {tx, pos.y}, {tx + ls.x + 8, pos.y + ls.y + 4}
}

// `playhead`: the frame being played (a line across it), or -1.
waveform :: proc(id: cstring, peaks: []Peak, frames: i64, view: ^Wave_View, markers: []Marker, selection: ^[2]i64, size: im.Vec2, tint: Color = {}, playhead: i64 = -1, opts := Wave_Options{}) -> (e: Wave_Edit) {
	im.PushID(id)
	defer im.PopID()
	e.marker, e.add_at, e.remove, e.gain = -1, -1, -1, -1
	t := current
	color := tint if tint != {} else t.accent
	dl := im.GetWindowDrawList()
	full_pos := im.GetCursorScreenPos()
	io := im.GetIO()
	// Room for what goes around it: the dB scale's labels at the left, the
	// overview strip under it (the ruler sits inside, along the bottom).
	SCALE_W :: 30
	OVER_H :: 16
	pos := full_pos
	size := size
	if opts.scale {
		pos.x += SCALE_W
		size.x -= SCALE_W
	}
	if opts.overview do size.y -= OVER_H + 4
	size = {max(size.x, 40), max(size.y, 40)}
	if view.end <= view.start do view^ = {0, f64(max(frames, 1))}
	span := view.end - view.start
	to_x :: proc(f: f64, view: Wave_View, pos: im.Vec2, size: im.Vec2) -> f32 {
		return pos.x + f32((f - view.start) / (view.end - view.start)) * size.x
	}
	to_frame :: proc(x: f32, view: Wave_View, pos: im.Vec2, size: im.Vec2) -> f64 {
		return view.start + f64((x - pos.x) / size.x) * (view.end - view.start)
	}

	im.SetCursorScreenPos(pos)
	im.InvisibleButton("##wave", size, {.MouseButtonLeft, .MouseButtonRight})
	name(widget_name(id, "waveform"))
	hovered := im.IsItemHovered()
	@(static) dragging_marker := -1
	@(static) dragging_gain := -1
	@(static) select_from: i64
	// Level lines: 0 dB four fifths up the wave, -24 dB at the bottom.
	gain_y :: proc(db: f32, pos, size: im.Vec2) -> f32 { return pos.y + size.y * (1 - (clamp(db, -24, 6) + 24) / 30) }
	near_gain := -1
	if hovered || im.IsItemActive() {
		mp := io.MousePos
		for g, i in opts.gains {
			cx := (to_x(f64(g.from), view^, pos, size) + to_x(f64(g.to), view^, pos, size)) / 2
			if abs(mp.x - cx) < 8 && abs(mp.y - gain_y(g.db, pos, size)) < 8 {
				near_gain = i
				break
			}
		}
	}

	// Markers take the mouse first, when it is near one.
	near := -1
	if hovered || im.IsItemActive() {
		// Its handle (a tag, a fade's square) first, then near its line.
		mp := io.MousePos
		for m, i in markers do if m.drag {
			lo, hi := marker_handle(m, to_x(f64(m.frame), view^, pos, size), pos, size)
			if hi.x > lo.x && mp.x >= lo.x && mp.x < hi.x && mp.y >= lo.y && mp.y < hi.y {
				near = i
				break
			}
		}
		if near < 0 do for m, i in markers do if m.drag && !m.fade && abs(to_x(f64(m.frame), view^, pos, size) - mp.x) < 5 {
			near = i
			break
		}
	}
	if near_gain >= 0 && near < 0 do im.SetMouseCursor(.ResizeNS)
	else if near >= 0 do im.SetMouseCursor(.ResizeEW)
	right := im.IsMouseClicked(.Right) && hovered
	if right && opts.editable && near >= 0 do e.remove = near
	if hovered && opts.editable && im.IsMouseDoubleClicked(.Left) && near < 0 && near_gain < 0 {
		e.add_at = i64(clamp(to_frame(io.MousePos.x, view^, pos, size), 0, f64(frames)))
	}
	if im.IsItemActivated() && !right {
		dragging_marker, dragging_gain = near, -1
		if near < 0 && near_gain >= 0 do dragging_gain = near_gain
		f := i64(clamp(to_frame(io.MousePos.x, view^, pos, size), 0, f64(frames)))
		if near < 0 do select_from = f
	}
	if im.IsItemActive() && dragging_gain >= 0 && dragging_gain < len(opts.gains) {
		// A level: up and down (0.25 dB steps; Shift finer).
		db := clamp(-24 + (1 - (io.MousePos.y - pos.y) / size.y) * 30, -24, 6)
		db = math.round(db * (20 if io.KeyShift else 4)) / (20 if io.KeyShift else 4)
		if db != opts.gains[dragging_gain].db do e.gain, e.gain_db = dragging_gain, db
	} else if im.IsItemActive() && !im.IsMouseDown(.Right) {
		f := i64(clamp(to_frame(io.MousePos.x, view^, pos, size), 0, f64(frames)))
		if dragging_marker >= 0 && dragging_marker < len(markers) {
			if f != markers[dragging_marker].frame {
				e.marker, e.marker_to, e.moved = dragging_marker, f, true
			}
		} else if selection != nil && abs(io.MouseDragMaxDistanceSqr[0]) > 9 {
			a, b := min(select_from, f), max(select_from, f)
			if selection^ != {a, b} {
				selection^ = {a, b}
				e.selected = true
			}
		}
	}
	if im.IsItemDeactivated() {
		if dragging_gain >= 0 {
			e.gain_released = true
		} else if dragging_marker >= 0 {
			e.marker, e.released = dragging_marker, true
		} else if io.MouseDragMaxDistanceSqr[0] <= 9 {
			e.clicked, e.click_frame = true, i64(clamp(to_frame(io.MousePos.x, view^, pos, size), 0, f64(frames)))
		}
		dragging_marker, dragging_gain = -1, -1
	}
	// Wheel: zoom around the mouse; Shift+wheel: pan.
	if hovered && io.MouseWheel != 0 {
		if io.KeyShift {
			shift := -f64(io.MouseWheel) * span * 0.1
			shift = clamp(shift, -view.start, f64(frames) - view.end)
			view.start += shift
			view.end += shift
		} else {
			at := to_frame(io.MousePos.x, view^, pos, size)
			k := math.pow(0.85, f64(io.MouseWheel))
			new_span := clamp(span * k, 64, f64(frames))
			frac := (at - view.start) / span
			view.start = clamp(at - frac * new_span, 0, f64(frames) - new_span)
			view.end = view.start + new_span
		}
		e.zoomed = true
	}

	// Drawing: on black (in either theme), as audio editors show waves.
	im.DrawList_AddRectFilled(dl, pos, {pos.x + size.x, pos.y + size.y}, col(WAVE_BG), t.radius)
	// The spectrum behind (playing): a column for each bin, from the
	// bottom, faint in the tint, brighter at the top of each.
	if n := len(opts.backdrop); n > 1 {
		tint_c := tint if tint != {} else t.accent
		fill := col(with_alpha(tint_c, 0.09))
		edge := col(with_alpha(lighten(tint_c, 0.3), 0.3))
		bottom := pos.y + size.y
		prev: im.Vec2
		for v, k in opts.backdrop {
			x0 := pos.x + size.x * f32(k) / f32(n)
			x1 := pos.x + size.x * f32(k + 1) / f32(n)
			h := clamp((v + 48) / 60, 0, 1) * size.y * 0.9 // (the floor's -48 dB and below: nothing)
			im.DrawList_AddRectFilled(dl, {x0, bottom - h}, {x1, bottom}, fill)
			top := im.Vec2{(x0 + x1) / 2, bottom - h}
			if k > 0 do im.DrawList_AddLine(dl, prev, top, edge, 1.5)
			prev = top
		}
	}
	im.DrawList_PushClipRect(dl, pos, {pos.x + size.x, pos.y + size.y}, true)
	mid := pos.y + size.y / 2
	im.DrawList_AddLine(dl, {pos.x, mid}, {pos.x + size.x, mid}, col(rgb(0x2a2c33)), 1) // the zero line
	// The grid: -6 dB (half the height) above and below the zero line.
	if opts.scale {
		half := (size.y / 2 - 2) * 0.5
		for y in ([2]f32{mid - half, mid + half}) do im.DrawList_AddLine(dl, {pos.x, y}, {pos.x + size.x, y}, col(with_alpha(rgb(0xffffff), 0.08)), 1)
	}
	if selection != nil && selection[1] > selection[0] {
		x0 := to_x(f64(selection[0]), view^, pos, size)
		x1 := to_x(f64(selection[1]), view^, pos, size)
		im.DrawList_AddRectFilled(dl, {x0, pos.y}, {x1, pos.y + size.y}, col(with_alpha(color, 0.18)))
	}
	if opts.pyramid != nil && len(opts.pyramid.samples) > 0 && frames > 0 {
		// At the pixels' own resolution: a peak a pixel from the level that
		// fits, or (zoomed in past a frame a pixel) the samples joined up.
		pyr := opts.pyramid
		cols := int(size.x)
		h := size.y / 2 - 2
		fpp := span / f64(max(cols, 1))
		if fpp < 1 {
			a := clamp(int(math.floor(view.start)), 0, len(pyr.samples) - 1)
			b := clamp(int(math.ceil(view.end)) + 1, a + 1, len(pyr.samples))
			pts := make([]im.Vec2, b - a, context.temp_allocator)
			for k in a ..< b do pts[k - a] = {to_x(f64(k), view^, pos, size), mid - pyr.samples[k] * h}
			im.DrawList_AddPolyline(dl, &pts[0], i32(len(pts)), col(color), 1.5)
			if fpp < 0.125 do for q in pts do im.DrawList_AddCircleFilled(dl, q, 2, col(color)) // (each sample, when they are far apart)
		} else {
			for x in 0 ..< cols {
				f0 := view.start + f64(x) / f64(cols) * span
				f1 := view.start + f64(x + 1) / f64(cols) * span
				lo, hi, ok := peak_range(pyr, f0, f1)
				if !ok do continue
				im.DrawList_AddLine(dl, {pos.x + f32(x) + 0.5, mid - hi * h}, {pos.x + f32(x) + 0.5, mid - lo * h + 1}, col(color), 1)
			}
		}
	} else if len(peaks) > 0 && frames > 0 {
		per := f64(frames) / f64(len(peaks))
		cols := int(size.x)
		for x in 0 ..< cols {
			f0 := view.start + f64(x) / f64(cols) * span
			f1 := view.start + f64(x + 1) / f64(cols) * span
			i0 := clamp(int(f0 / per), 0, len(peaks) - 1)
			i1 := clamp(int(f1 / per), i0, len(peaks) - 1)
			lo, hi := peaks[i0].lo, peaks[i0].hi
			for p in peaks[i0:i1 + 1] do lo, hi = min(lo, p.lo), max(hi, p.hi)
			h := size.y / 2 - 2
			im.DrawList_AddLine(dl, {pos.x + f32(x) + 0.5, mid - hi * h}, {pos.x + f32(x) + 0.5, mid - lo * h + 1}, col(color), 1)
		}
	}
	im.DrawList_AddLine(dl, {pos.x, mid}, {pos.x + size.x, mid}, col(with_alpha(t.text, 0.12)), 1)
	for m, i in markers {
		x := to_x(f64(m.frame), view^, pos, size)
		c := m.color if m.color != {} else t.text
		hot := i == near || i == dragging_marker
		lo, hi := marker_handle(m, x, pos, size)
		if m.fade {
			// The ramp: from silence at the region's edge to full at the handle.
			fx := to_x(f64(m.from), view^, pos, size)
			bottom, top := pos.y + size.y - 1, pos.y + FADE_ROW + 5
			im.DrawList_AddTriangleFilled(dl, {fx, top}, {fx, bottom}, {x, top}, col(with_alpha(WAVE_BG, 0.55)))
			im.DrawList_AddLine(dl, {fx, bottom}, {x, top}, col(c), 2 if hot else 1.5)
			im.DrawList_AddRectFilled(dl, lo, hi, col(lighten(c, 0.2) if hot else c), 2)
			continue
		}
		im.DrawList_AddLine(dl, {x, pos.y}, {x, pos.y + size.y}, col(c), 2 if hot else 1.5)
		if m.label != "" {
			lc := strings.clone_to_cstring(m.label, context.temp_allocator)
			im.DrawList_AddRectFilled(dl, lo, hi, col(lighten(c, 0.15) if hot else c), 3)
			im.DrawList_AddText(dl, {lo.x + 4, pos.y + 2}, col(t.bg), lc)
		}
	}
	// Level lines: grey across their part, a handle in the middle (lit
	// under the mouse), the level beside it while it moves.
	for g, i in opts.gains {
		x0, x1 := to_x(f64(g.from), view^, pos, size), to_x(f64(g.to), view^, pos, size)
		y := gain_y(g.db, pos, size)
		hot := i == near_gain || i == dragging_gain
		lc := with_alpha(rgb(0xc8ccd4), 0.55 if hot else 0.32)
		im.DrawList_AddLine(dl, {x0 + 3, y}, {x1 - 3, y}, col(lc), 1.5)
		cx := (x0 + x1) / 2
		im.DrawList_AddCircleFilled(dl, {cx, y}, 5 if hot else 4, col(with_alpha(rgb(0xe8e9ed), 0.9 if hot else 0.6)))
		if hot {
			lt := fmt.ctprintf("%+.1f dB", g.db)
			im.DrawList_AddText(dl, {cx + 8, y - 16}, col(rgb(0xe8e9ed)), lt)
		}
	}
	// The playhead.
	if playhead >= 0 {
		x := to_x(f64(playhead), view^, pos, size)
		if x >= pos.x && x <= pos.x + size.x do im.DrawList_AddLine(dl, {x, pos.y}, {x, pos.y + size.y}, col(rgb(0xffffff)), 1.5)
	}
	// The ruler: time along the bottom, in bars and beats (at the sound's
	// tempo) or seconds, its labels as many as fit.
	if opts.rate > 0 {
		RULER :: 16
		y0 := pos.y + size.y - RULER
		im.DrawList_AddRectFilled(dl, {pos.x, y0}, {pos.x + size.x, pos.y + size.y}, col(with_alpha(WAVE_BG, 0.75)))
		unit := opts.beat_frames if opts.beat_frames > 0 else opts.rate // a beat, or a second
		per_bar := f64(opts.beats_per_bar if opts.beats_per_bar > 0 else 4)
		// A step that leaves room for labels: units, or halves/quarters of them, or many.
		px_per := f64(size.x) / (span / unit)
		step := 1.0
		for step * px_per < 60 do step *= 2
		for step * px_per > 160 && step > 1.0 / 16 do step /= 2
		first := math.floor(view.start / unit / step) * step
		for u := first; u * unit <= view.end; u += step {
			x := to_x(u * unit, view^, pos, size)
			if x < pos.x - 1 do continue
			im.DrawList_AddLine(dl, {x, y0}, {x, y0 + 5}, col(with_alpha(rgb(0xffffff), 0.5)), 1)
			lt: cstring
			if opts.beat_frames > 0 {
				bar := int(math.floor(u / per_bar + 1e-9)) + 1
				beat := math.mod(u, per_bar) + 1
				lt = fmt.ctprintf("%d", bar) if abs(beat - 1) < 1e-6 else fmt.ctprintf("%d.%g", bar, math.round(beat * 100) / 100)
			} else {
				lt = fmt.ctprintf("%.2fs", u) if step < 1 else fmt.ctprintf("%.0fs", u)
			}
			im.DrawList_AddText(dl, {x + 3, y0 + 1}, col(with_alpha(rgb(0xffffff), 0.6)), lt)
		}
	}
	im.DrawList_PopClipRect(dl)
	// The dB scale at the left: 0 at the top and bottom, -6 halfway, -inf at
	// the zero line.
	if opts.scale {
		h := size.y / 2 - 2
		labels := [?]struct { y: f32, text: cstring }{{mid - h, "0"}, {mid - h * 0.5, "-6"}, {mid, "-inf"}, {mid + h * 0.5, "-6"}, {mid + h, "0"}}
		for l in labels {
			ts := im.CalcTextSize(l.text)
			im.DrawList_AddText(dl, {pos.x - ts.x - 4, l.y - ts.y / 2}, col(t.text_dim), l.text)
		}
	}
	// The overview: the whole sound, the part shown as a window to drag.
	if opts.overview && len(peaks) > 0 {
		op := im.Vec2{pos.x, pos.y + size.y + 4}
		osz := im.Vec2{size.x, OVER_H}
		im.SetCursorScreenPos(op)
		im.InvisibleButton("##overview", osz)
		name(strings.concatenate({widget_name(id, "waveform"), " overview"}, context.temp_allocator))
		im.DrawList_AddRectFilled(dl, op, {op.x + osz.x, op.y + osz.y}, col(WAVE_BG), 3)
		om := op.y + osz.y / 2
		cols := int(osz.x)
		per := f64(len(peaks)) / f64(max(cols, 1))
		for x in 0 ..< cols {
			i0 := clamp(int(f64(x) * per), 0, len(peaks) - 1)
			i1 := clamp(int(f64(x + 1) * per), i0, len(peaks) - 1)
			lo, hi := peaks[i0].lo, peaks[i0].hi
			for p in peaks[i0:i1 + 1] do lo, hi = min(lo, p.lo), max(hi, p.hi)
			im.DrawList_AddLine(dl, {op.x + f32(x) + 0.5, om - hi * (osz.y / 2 - 1)}, {op.x + f32(x) + 0.5, om - lo * (osz.y / 2 - 1) + 1}, col(with_alpha(color, 0.6)), 1)
		}
		wx0 := op.x + f32(view.start / f64(frames)) * osz.x
		wx1 := op.x + f32(view.end / f64(frames)) * osz.x
		im.DrawList_AddRectFilled(dl, {wx0, op.y}, {wx1, op.y + osz.y}, col(with_alpha(rgb(0xffffff), 0.12)), 2)
		im.DrawList_AddRect(dl, {wx0, op.y}, {wx1, op.y + osz.y}, col(with_alpha(rgb(0xffffff), 0.5)), 2, 1)
		// Drag (or click) to move the part shown, centred where the mouse is.
		if im.IsItemActive() {
			c := f64((io.MousePos.x - op.x) / osz.x) * f64(frames)
			start := clamp(c - span / 2, 0, f64(frames) - span)
			if start != view.start {
				view.start, view.end = start, start + span
				e.zoomed = true
			}
		}
		if im.IsItemHovered() do im.SetTooltip("Drag: the part shown (the wheel zooms the wave)")
	}
	im.SetCursorScreenPos(full_pos)
	im.Dummy({size.x + (SCALE_W if opts.scale else 0), size.y + (OVER_H + 4 if opts.overview else 0)})
	return
}

// --- step grid ----------------------------------------------------------------------------

// A grid of `rows` × `steps` cells (a drum pattern): `cells[row * steps +
// step]` says whether each is on. Click or drag to paint (on if the first
// cell was off, else off); returns whether anything changed. `playhead` (a
// step, -1 = none) is highlighted; every 4th step is shaded.
step_grid :: proc(id: cstring, cells: []bool, rows, steps: int, row_names: []string, playhead := -1, cell := im.Vec2{26, 26}) -> (e: Edit) {
	im.PushID(id)
	defer im.PopID()
	t := current
	dl := im.GetWindowDrawList()
	label_w: f32 = 0
	for n in row_names do label_w = max(label_w, im.CalcTextSize(strings.clone_to_cstring(n, context.temp_allocator)).x)
	if label_w > 0 do label_w += t.gap.x
	pos := im.GetCursorScreenPos()
	gap: f32 = 3
	size := im.Vec2{label_w + f32(steps) * (cell.x + gap), f32(rows) * (cell.y + gap)}
	im.InvisibleButton("##grid", size)
	name(widget_name(id, "step grid"))
	io := im.GetIO()
	@(static) paint: bool
	hit_cell :: proc(m: im.Vec2, pos: im.Vec2, label_w, gap: f32, cell: im.Vec2, rows, steps: int) -> (int, bool) {
		cx := int((m.x - pos.x - label_w) / (cell.x + gap))
		cy := int((m.y - pos.y) / (cell.y + gap))
		if m.x < pos.x + label_w || cx < 0 || cy < 0 || cx >= steps || cy >= rows do return 0, false
		return cy * steps + cx, true
	}
	if im.IsItemActivated() {
		e.started = true
		if i, ok := hit_cell(io.MousePos, pos, label_w, gap, cell, rows, steps); ok do paint = !cells[i]
	}
	if im.IsItemActive() {
		e.active = true
		if i, ok := hit_cell(io.MousePos, pos, label_w, gap, cell, rows, steps); ok && cells[i] != paint {
			cells[i] = paint
			e.changed = true
		}
	}
	if im.IsItemDeactivated() do e.ended = true
	for r in 0 ..< rows {
		y := pos.y + f32(r) * (cell.y + gap)
		if r < len(row_names) {
			nc := strings.clone_to_cstring(row_names[r], context.temp_allocator)
			im.DrawList_AddText(dl, {pos.x, y + (cell.y - im.GetTextLineHeight()) / 2}, col(t.text_dim), nc)
		}
		for s in 0 ..< steps {
			x := pos.x + label_w + f32(s) * (cell.x + gap)
			on := cells[r * steps + s]
			c := t.raised
			if (s / 4) % 2 == 1 do c = mix(t.raised, t.bg, 0.35)
			if s == playhead do c = t.hover
			if on do c = t.accent
			im.DrawList_AddRectFilled(dl, {x, y}, {x + cell.x, y + cell.y}, col(c), 4)
		}
	}
	return
}

// --- piano roll ----------------------------------------------------------------------------

// A note as the piano roll edits it: beats and a key.
Roll_Note :: struct {
	start:    f64, // beats
	length:   f64,
	key:      int, // 0..127
	velocity: f32,
	selected: bool,
	color:    Color, // {} = the accent
	muted:    bool,  // drawn hollow: there, but silent
}

// What the user did to the notes this frame. The caller makes commands
// of it; the roll itself never changes `notes`.
Roll_Edit :: struct {
	add:      bool, // a click on empty space: add a note at `at_beat`/`at_key`
	at_beat:  f64,
	at_key:   int,
	menu:     int,  // a right-clicked note (its index), or -1: open its menu
	menu_part: bool, // a right-click on the marked range (not on a note)
	moving:   int,  // a note being dragged (index), or -1
	resizing: int,  // a note whose end is being dragged, or -1
	to_start: f64,  // where the dragged note goes (snapped)
	to_key:   int,
	to_length: f64,
	released: bool, // a drag ended: commit the move or resize
	select:   int,  // a note clicked to select, or -1
}

// A range of a piano roll marked with Shift-drag: beats `beat0` to `beat1`,
// keys `key0` to `key1` (inclusive). Copy and paste work on it.
Roll_Range :: struct {
	on:           bool,
	beat0, beat1: f64,
	key0, key1:   int,
}

// How wide a piano roll's row labels are for `rows` (to line things up
// with its grid).
roll_rows_width :: proc(rows: []Roll_Row) -> f32 {
	w: f32 = 0
	for r in rows do w = max(w, im.CalcTextSize(strings.clone_to_cstring(r.name, context.temp_allocator)).x)
	return w + 2 * current.pad.x + 6
}

// A named row of a piano roll used as a drum editor.
Roll_Row :: struct {
	name:  string,
	color: Color, // {} = the accent
}

// The visible part of a piano roll.
Roll_View :: struct {
	beat0, beats: f64, // first beat shown, beats across
	key0, keys:   int, // lowest key shown, keys high
}

// A piano roll: keys up the left, beats across, `notes` as bars. Click
// empty space to add, drag a note to move it, drag its right end to resize,
// right-click for its menu (`menu`). Positions snap to `snap` beats (0 = free).
// With `range`, Shift-drag marks a range of beats and keys (snapped to
// bars when the drag is long, else to `snap`); a plain click clears it.
// `rows` names the rows instead of a keyboard (a drum editor: `rows[k]` is
// key k, counted from the bottom), with a colour each.
piano_roll :: proc(id: cstring, notes: []Roll_Note, view: ^Roll_View, snap: f64, size: im.Vec2, playhead: f64 = -1, rows: []Roll_Row = nil, range: ^Roll_Range = nil, bar: f64 = 4) -> (e: Roll_Edit) {
	im.PushID(id)
	defer im.PopID()
	e.menu, e.moving, e.resizing, e.select = -1, -1, -1, -1
	t := current
	dl := im.GetWindowDrawList()
	pos := im.GetCursorScreenPos()
	io := im.GetIO()
	keys_w: f32 = 40 if len(rows) == 0 else roll_rows_width(rows)
	grid := im.Vec2{pos.x + keys_w, pos.y}
	gw := size.x - keys_w
	row_h := size.y / f32(max(view.keys, 1))
	beat_w := gw / f32(max(view.beats, 1))
	to_beat :: proc(x: f32, grid: im.Vec2, beat_w: f32, view: ^Roll_View) -> f64 { return view.beat0 + f64((x - grid.x) / beat_w) }
	to_key :: proc(y: f32, grid: im.Vec2, row_h: f32, size: im.Vec2, view: ^Roll_View) -> int {
		return view.key0 + int((grid.y + size.y - y) / row_h)
	}
	snap_to :: proc(b, snap: f64) -> f64 { return math.round(b / snap) * snap if snap > 0 else b }

	im.InvisibleButton("##roll", size, {.MouseButtonLeft, .MouseButtonRight})
	name(widget_name(id, "piano roll"))
	hovered := im.IsItemHovered()
	@(static) drag_note := -1
	@(static) drag_resize := false
	@(static) grab: f64 // beats between the note's start and where it was grabbed

	hit := -1
	edge := false
	m := io.MousePos
	for n, i in notes {
		x0 := grid.x + f32(n.start - view.beat0) * beat_w
		x1 := x0 + f32(n.length) * beat_w
		y0 := grid.y + size.y - f32(n.key - view.key0 + 1) * row_h
		if m.x >= x0 && m.x <= x1 && m.y >= y0 && m.y < y0 + row_h {
			hit = i
			edge = m.x > x1 - 6
		}
	}
	if hit >= 0 && edge do im.SetMouseCursor(.ResizeEW)
	if hovered && im.IsMouseClicked(.Right) {
		if hit >= 0 {
			e.menu = hit
		} else if range != nil && range.on {
			b, k := to_beat(m.x, grid, beat_w, view), to_key(m.y, grid, row_h, size, view)
			e.menu_part = b >= range.beat0 && b < range.beat1 && k >= range.key0 && k <= range.key1
		}
	}
	@(static) marking := false
	@(static) mark_from: [2]f64
	if range != nil && im.IsItemActivated() && im.IsMouseClicked(.Left) && io.KeyShift && m.x > grid.x {
		marking = true
		mark_from = {to_beat(m.x, grid, beat_w, view), f64(clamp(to_key(m.y, grid, row_h, size, view), 0, 127))}
	} else if im.IsItemActivated() && im.IsMouseClicked(.Left) {
		if range != nil do range.on = false
		if hit >= 0 {
			drag_note, drag_resize = hit, edge
			grab = to_beat(m.x, grid, beat_w, view) - notes[hit].start
			e.select = hit
		} else if m.x > grid.x {
			e.add = true
			e.at_beat = max(snap_to(to_beat(m.x, grid, beat_w, view) - (snap / 2 if snap > 0 else 0), snap), 0)
			e.at_key = clamp(to_key(m.y, grid, row_h, size, view), 0, 127)
		}
	}
	// While dragging, and on the frame it ends (so the release says where to).
	if (im.IsItemActive() || im.IsItemDeactivated()) && drag_note >= 0 && drag_note < len(notes) {
		n := notes[drag_note]
		if drag_resize {
			end := max(snap_to(to_beat(m.x, grid, beat_w, view), snap), n.start + (snap if snap > 0 else 1.0 / 64))
			e.resizing, e.to_start, e.to_key, e.to_length = drag_note, n.start, n.key, end - n.start
		} else {
			e.moving = drag_note
			e.to_start = max(snap_to(to_beat(m.x, grid, beat_w, view) - grab, snap), 0)
			e.to_key = clamp(to_key(m.y, grid, row_h, size, view), 0, 127)
			e.to_length = n.length
		}
	}
	if marking && range != nil {
		b := to_beat(m.x, grid, beat_w, view)
		k := clamp(to_key(m.y, grid, row_h, size, view), 0, 127)
		lo, hi := min(mark_from[0], b), max(mark_from[0], b)
		step := bar if hi - lo >= bar * 0.5 else (snap if snap > 0 else 0.25)
		lo, hi = math.floor(lo / step + 1e-9) * step, math.ceil(hi / step - 1e-9) * step
		if hi <= lo do hi = lo + step
		range^ = {on = true, beat0 = max(lo, 0), beat1 = hi, key0 = min(int(mark_from[1]), k), key1 = max(int(mark_from[1]), k)}
		if !im.IsItemActive() do marking = false
	}
	if im.IsItemDeactivated() && drag_note >= 0 {
		e.released = true
		if drag_resize do e.resizing = drag_note
		else do e.moving = drag_note
		drag_note = -1
	}
	if hovered && io.MouseWheel != 0 {
		if io.KeyShift {
			view.beat0 = max(view.beat0 - f64(io.MouseWheel) * view.beats * 0.1, 0)
		} else {
			view.key0 = clamp(view.key0 + int(io.MouseWheel * 2), 0, 128 - view.keys)
		}
	}

	// Keys and rows.
	if len(rows) > 0 do for k in 0 ..< view.keys {
		y := grid.y + size.y - f32(k + 1) * row_h
		im.DrawList_AddRectFilled(dl, {grid.x, y}, {grid.x + gw, y + row_h}, col(t.raised if k % 2 == 0 else mix(t.raised, t.bg, 0.3)))
		if row := view.key0 + k; row >= 0 && row < len(rows) {
			r := rows[row]
			c := r.color if r.color != {} else t.accent
			im.DrawList_AddRectFilled(dl, {pos.x, y + 1}, {pos.x + 4, y + row_h - 1}, col(c), 2)
			nc := strings.clone_to_cstring(r.name, context.temp_allocator)
			// Smaller text when the rows are short (down to 10 points).
			fs := min(im.GetFontSize(), row_h * 0.78)
			if fs >= 10 {
				im.DrawList_AddTextFontPtr(dl, im.GetFont(), fs, {pos.x + 4 + t.pad.x, y + (row_h - fs * 1.2) / 2 + 1}, col(t.text_dim), nc)
			}
		}
	} else do for k in 0 ..< view.keys {
		key := view.key0 + k
		y := grid.y + size.y - f32(k + 1) * row_h
		black := (key % 12) in bit_set[0 ..< 12]{1, 3, 6, 8, 10}
		im.DrawList_AddRectFilled(dl, {grid.x, y}, {grid.x + gw, y + row_h}, col(mix(t.raised, t.bg, 0.45) if black else t.raised))
		im.DrawList_AddRectFilled(dl, {pos.x, y}, {pos.x + keys_w - 2, y + row_h - 1}, col(t.bg if black else t.text_dim))
		if key % 12 == 0 && row_h >= 9 {
			label := strings.clone_to_cstring(note_name(key), context.temp_allocator)
			im.DrawList_AddText(dl, {pos.x + 3, y + (row_h - im.GetTextLineHeight()) / 2}, col(t.bg), label)
		}
	}
	// Snap lines when there is room, then beat lines, bars stronger.
	if snap > 0 && f32(snap) * beat_w >= 10 {
		for b := math.floor(view.beat0 / snap) * snap; b <= view.beat0 + view.beats; b += snap {
			x := grid.x + f32(b - view.beat0) * beat_w
			im.DrawList_AddLine(dl, {x, grid.y}, {x, grid.y + size.y}, col(with_alpha(t.text, 0.035)), 1)
		}
	}
	for b := math.floor(view.beat0); b <= view.beat0 + view.beats; b += 1 {
		x := grid.x + f32(b - view.beat0) * beat_w
		strong := int(b) % 4 == 0
		im.DrawList_AddLine(dl, {x, grid.y}, {x, grid.y + size.y}, col(with_alpha(t.text, 0.18 if strong else 0.07)), 1)
	}
	im.DrawList_PushClipRect(dl, grid, {grid.x + gw, grid.y + size.y}, true)
	if range != nil && range.on {
		x0 := grid.x + f32(range.beat0 - view.beat0) * beat_w
		x1 := grid.x + f32(range.beat1 - view.beat0) * beat_w
		y0 := grid.y + size.y - f32(range.key1 - view.key0 + 1) * row_h
		y1 := grid.y + size.y - f32(range.key0 - view.key0) * row_h
		im.DrawList_AddRectFilled(dl, {x0, y0}, {x1, y1}, col(with_alpha(t.accent, 0.16)), 3)
		im.DrawList_AddRect(dl, {x0, y0}, {x1, y1}, col(with_alpha(t.accent, 0.8)), 3, 1.5)
	}
	for n, i in notes {
		start, key, length := n.start, n.key, n.length
		if (e.moving == i || e.resizing == i) && !e.released do start, key, length = e.to_start, e.to_key, e.to_length
		x0 := grid.x + f32(start - view.beat0) * beat_w
		x1 := max(x0 + f32(length) * beat_w, x0 + 6) // the shortest stays visible
		y0 := grid.y + size.y - f32(key - view.key0 + 1) * row_h
		base := n.color if n.color != {} else t.accent
		c := mix(base, t.text, 0.15) if n.selected || i == hit else base
		c = with_alpha(c, 0.45 + 0.55 * n.velocity)
		im.DrawList_AddRectFilled(dl, {x0 + 1, y0 + 1}, {x1 - 1, y0 + row_h - 1}, col(c), 3)
		if n.selected do im.DrawList_AddRect(dl, {x0 + 1, y0 + 1}, {x1 - 1, y0 + row_h - 1}, col(t.text), 3, 1.5)
	}
	if playhead >= view.beat0 {
		x := grid.x + f32(playhead - view.beat0) * beat_w
		im.DrawList_AddLine(dl, {x, grid.y}, {x, grid.y + size.y}, col(t.warn), 2)
	}
	im.DrawList_PopClipRect(dl)
	return
}

// "C3", "F#4": a MIDI key's name (middle C, 60, is C3).
note_name :: proc(key: int) -> string {
	names := [12]string{"C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"}
	return strings.concatenate({names[key % 12], itoa(key / 12 - 2)}, context.temp_allocator)
}

@(private)
itoa :: proc(n: int) -> string {
	buf := make([]u8, 24, context.temp_allocator)
	return strconv.write_int(buf, i64(n), 10)
}

// --- automation lane -----------------------------------------------------------------------

// A breakpoint as the lane edits it.
Lane_Point :: struct {
	beat:  f64,
	value: f32, // 0..1
}

// What the user did to a lane: add a point (click empty space), move one
// (drag), right-click one for its menu. The caller makes commands of it.
Lane_Edit :: struct {
	add:      bool,
	at:       Lane_Point,
	moving:   int, // index, or -1
	to:       Lane_Point,
	released: bool,
	menu:     int, // a right-clicked point (index), or -1
}

// An automation lane: `points` (sorted by beat) joined by lines across
// `beats` beats from `beat0`.
automation_lane :: proc(id: cstring, points: []Lane_Point, beat0, beats: f64, snap: f64, size: im.Vec2, tint: Color = {}) -> (e: Lane_Edit) {
	im.PushID(id)
	defer im.PopID()
	e.moving, e.menu = -1, -1
	t := current
	color := tint if tint != {} else t.accent
	dl := im.GetWindowDrawList()
	pos := im.GetCursorScreenPos()
	io := im.GetIO()
	im.InvisibleButton("##lane", size, {.MouseButtonLeft, .MouseButtonRight})
	name(widget_name(id, "lane"))
	bw := size.x / f32(beats)
	to_screen :: proc(p: Lane_Point, pos, size: im.Vec2, beat0: f64, bw: f32) -> im.Vec2 {
		return {pos.x + f32(p.beat - beat0) * bw, pos.y + (1 - p.value) * size.y}
	}
	from_screen :: proc(m, pos, size: im.Vec2, beat0: f64, bw: f32, snap: f64) -> Lane_Point {
		b := beat0 + f64((m.x - pos.x) / bw)
		if snap > 0 do b = math.round(b / snap) * snap
		return {max(b, 0), clamp(1 - (m.y - pos.y) / size.y, 0, 1)}
	}
	@(static) drag := -1
	hit := -1
	for p, i in points {
		s := to_screen(p, pos, size, beat0, bw)
		dx, dy := io.MousePos.x - s.x, io.MousePos.y - s.y
		if dx * dx + dy * dy < 64 do hit = i
	}
	if im.IsItemHovered() && im.IsMouseClicked(.Right) && hit >= 0 do e.menu = hit
	if im.IsItemActivated() && im.IsMouseClicked(.Left) {
		if hit >= 0 {
			drag = hit
		} else {
			e.add, e.at = true, from_screen(io.MousePos, pos, size, beat0, bw, snap)
		}
	}
	if im.IsItemActive() && drag >= 0 do e.moving, e.to = drag, from_screen(io.MousePos, pos, size, beat0, bw, snap)
	if im.IsItemDeactivated() && drag >= 0 {
		e.moving, e.to, e.released = drag, from_screen(io.MousePos, pos, size, beat0, bw, snap), true
		drag = -1
	}
	im.DrawList_AddRectFilled(dl, pos, {pos.x + size.x, pos.y + size.y}, col(t.raised), t.radius)
	prev: im.Vec2
	for p, i in points {
		pp := p
		if i == e.moving do pp = e.to
		s := to_screen(pp, pos, size, beat0, bw)
		if i > 0 do im.DrawList_AddLine(dl, prev, s, col(color), 2)
		prev = s
	}
	for p, i in points {
		pp := p
		if i == e.moving do pp = e.to
		s := to_screen(pp, pos, size, beat0, bw)
		im.DrawList_AddCircleFilled(dl, s, 5 if i == hit else 4, col(t.text if i == hit else color), 16)
	}
	return
}

// --- value lane ----------------------------------------------------------------------------

// One bar of a value lane: a note's velocity or chance, at its beat.
Lane_Bar :: struct {
	beat:     f64,
	value:    f32, // 0..1
	color:    Color, // {} = the accent
	selected: bool,
}

// What the user did to a value lane this frame.
Lane_Bar_Edit :: struct {
	index:   int,  // the bar being set, or -1
	value:   f32,  // its new value
	changed: bool,
	ended:   bool, // the drag ended: seal the undo step
}

// Bars standing at their beats, `beat0`..`beat0 + beats` across (lined up
// with a piano roll above it: give the same `left` as its row labels'
// width). Drag up and down on one to set it; the bar nearest the press is
// the one that moves.
value_lane :: proc(id: cstring, bars: []Lane_Bar, beat0, beats: f64, size: im.Vec2, left: f32 = 0) -> (e: Lane_Bar_Edit) {
	im.PushID(id)
	defer im.PopID()
	e.index = -1
	t := current
	dl := im.GetWindowDrawList()
	pos := im.GetCursorScreenPos()
	im.InvisibleButton("##lane", size)
	name(widget_name(id, "lane"))
	gx := pos.x + left
	gw := size.x - left
	beat_w := gw / f32(max(beats, 1e-6))
	x_of :: proc(b, beat0: f64, gx, beat_w: f32) -> f32 { return gx + f32(b - beat0) * beat_w }
	@(static) dragging := -1
	io := im.GetIO()
	if im.IsItemActivated() {
		dragging = -1
		best: f32 = 12
		for b, i in bars {
			d := abs(x_of(b.beat, beat0, gx, beat_w) - io.MousePos.x)
			if d < best do best, dragging = d, i
		}
	}
	if (im.IsItemActive() || im.IsItemDeactivated()) && dragging >= 0 && dragging < len(bars) {
		v := clamp(1 - (io.MousePos.y - pos.y) / size.y, 0, 1)
		e.index, e.value = dragging, v
		e.changed = v != bars[dragging].value
	}
	if im.IsItemDeactivated() {
		e.ended = dragging >= 0
		dragging = -1
	}
	im.DrawList_AddRectFilled(dl, {gx, pos.y}, {gx + gw, pos.y + size.y}, col(t.raised), t.radius)
	for b, i in bars {
		x := x_of(b.beat, beat0, gx, beat_w)
		if x < gx - 1 || x > gx + gw do continue
		v := e.value if i == e.index else b.value
		h := v * (size.y - 4)
		c := b.color if b.color != {} else t.accent
		if b.selected || i == e.index do c = mix(c, t.text, 0.25)
		im.DrawList_AddRectFilled(dl, {x, pos.y + size.y - 2 - h}, {x + 4, pos.y + size.y - 2}, col(c), 1)
		im.DrawList_AddCircleFilled(dl, {x + 2, pos.y + size.y - 2 - h}, 3, col(c))
	}
	return
}
