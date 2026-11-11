package pads

import "core:fmt"
import "core:math"
import "core:strings"

import app "app:core"
import "app:ui"
import pm "model"
import im "deps:imgui"
import "fire:synth"

// The wavetable editor: a window over the app for one oscillator's table
// of the project's own. Along the top, the keyframes on the table's
// frames (click one, drag it along, double-click for a new one); below,
// the chosen keyframe's editor (a drawing, line shapes, harmonic bars or
// a slice of a sound) beside the table it makes, in 3D.

// The editor's state.
Wave_Editor :: struct {
	open:     bool,
	pad, osc: int,
	key:      int,  // the keyframe chosen
	moving:   int,  // a keyframe being dragged along the strip (-1: none)
	last:     [2]f32, // where a drawing stroke was last (index, value; x < 0: no stroke)
	point:    int,  // a line point being dragged (-1: none)
	curve:    int,  // a segment's curve being dragged (-1: none)
}

KEY_SOURCE_NAMES := []string{"Draw", "Lines", "Harmonics", "Audio"}
BLEND_NAMES := []string{"Crossfade", "Spectral"}

// Opens the editor on oscillator `osc` (0-based) of the selected pad.
open_wave_editor :: proc(a: ^App, osc: int) {
	a.wte = {open = true, pad = a.selected, osc = osc, moving = -1, point = -1, curve = -1, last = {-1, 0}}
}

// The editor window (when open).
draw_wave_editor :: proc(a: ^App) {
	st := &a.wte
	if !st.open do return
	m := &a.m
	if st.pad < 0 || st.pad >= pm.PADS || m.project.pads[st.pad].kind != .Synth {
		st.open = false
		return
	}
	vp := im.GetMainViewport()
	im.SetNextWindowSize({min(vp.Size.x - 80, 1100), min(vp.Size.y - 80, 660)}, .FirstUseEver)
	im.SetNextWindowPos({vp.Pos.x + vp.Size.x / 2, vp.Pos.y + vp.Size.y / 2}, .FirstUseEver, {0.5, 0.5})
	title := fmt.ctprintf("Wavetable · %s · Osc %c###wte", pm.pad_label(st.pad), 'A' + rune(st.osc))
	if !im.Begin(title, &st.open, {.NoCollapse, .NoScrollbar}) {
		im.End()
		return
	}
	defer im.End()
	src := m.project.pads[st.pad].synth.tables[st.osc]
	doc := app.store_get(&m.project.wave_docs, src.table) if src.table != 0 else nil
	if doc == nil {
		im.Spacing()
		im.Text("%s", fmt.ctprintf("Oscillator %c plays %s, a table you can't edit.", 'A' + rune(st.osc), pm.synth_source_name(m, src)))
		im.Spacing()
		if im.Button(fmt.ctprintf("%s  New table", ui.ICON_PLUS)) do pm.new_wave_doc(m, st.pad, st.osc)
		ui.name("new table")
		im.SameLine(0, 10)
		if im.Button(fmt.ctprintf("%s  Edit a copy of %s", ui.ICON_PENCIL, pm.synth_source_name(m, src))) do pm.new_wave_doc(m, st.pad, st.osc, true)
		ui.name("copy table")
		return
	}
	id := src.table
	d := doc^
	edit := ""
	st.key = clamp(st.key, 0, d.doc.count - 1)
	k := &d.doc.keys[st.key]
	// The header: its name, blend, the keyframe's source, adding and removing.
	{
		buf: [32]u8
		copy(buf[:31], pm.wave_doc_name(m, id))
		im.SetNextItemWidth(170)
		if im.InputText("##wtname", cstring(&buf[0]), len(buf), {.EnterReturnsTrue}) {
			d.name = buf
			edit = "Rename Wavetable"
		}
		ui.name("table name")
		im.SameLine(0, 14)
		blend := int(d.doc.blend)
		if ui.segmented("wt_blend", BLEND_NAMES, &blend) {
			d.doc.blend = synth.Table_Blend(blend)
			edit = "Table Blend"
		}
		im.SameLine(0, 14)
		im.AlignTextToFramePadding()
		im.TextDisabled("%s", fmt.ctprintf("Keyframe %d at frame %d", st.key + 1, k.position + 1))
		im.SameLine(0, 8)
		source := int(k.source)
		if ui.segmented("wt_source", KEY_SOURCE_NAMES, &source) {
			k.source = synth.Key_Source(source)
			edit = "Keyframe Source"
		}
		im.SameLine(0, 14)
		if ui.icon_button(ui.ICON_PLUS, "A keyframe halfway to the next (a copy of this one)", disabled = d.doc.count >= synth.TABLE_KEYS) {
			if add_key(&d.doc, st.key) >= 0 {
				st.key = d.doc.count - 1
				edit = "Add Keyframe"
			}
		}
		ui.name("add keyframe")
		im.SameLine(0, 4)
		if ui.icon_button(ui.ICON_TRASH_2, "Remove this keyframe", disabled = d.doc.count <= 1) {
			for j in st.key ..< d.doc.count - 1 do d.doc.keys[j] = d.doc.keys[j + 1]
			d.doc.count -= 1
			st.key = min(st.key, d.doc.count - 1)
			k = &d.doc.keys[st.key]
			edit = "Remove Keyframe"
		}
		ui.name("remove keyframe")
	}
	color := ui.rgb(m.project.pads[st.pad].color)
	avail := im.GetContentRegionAvail()
	// The keyframes along the frames.
	if e := key_strip(st, &d.doc, avail.x, color); e != "" do edit = e
	k = &d.doc.keys[st.key]
	im.Spacing()
	avail = im.GetContentRegionAvail()
	ew := avail.x * 0.62
	h := max(avail.y - 8, 120)
	top := im.GetCursorScreenPos()
	sound := pm.wave_doc_sound(&m.engine, id)
	switch k.source {
	case .Draw:      if draw_editor(st, k, {ew, h}, color) do edit = "Draw Wave"
	case .Lines:     if line_editor(st, k, {ew, h}, color) do edit = "Shape Lines"
	case .Harmonics: if harmonics_editor(k, {ew, h}, color) do edit = "Harmonic Level"
	case .Audio:
		e, sample := audio_editor(a, k, &d, sound, {ew, h}, color)
		if e do edit = "Slice Audio"
		if sample != 0 {
			d.sample = sample
			edit = "Table Sound"
		}
	}
	// The table it makes, beside.
	im.SetCursorScreenPos({top.x + ew + 12, top.y})
	tab := pm.synth_pad_table(&m.engine, st.pad, st.osc)
	draw_table_3d(tab, {avail.x - ew - 12, h}, color, d.doc.keys[st.key].position if tab != nil && tab.frames > 1 else 0, nil)
	if edit != "" {
		pm.set_wave_doc(m, id, d, edit)
		if !im.IsMouseDown(.Left) do app.seal(&m.history)
	}
	if im.IsMouseReleased(.Left) {
		app.seal(&m.history)
		st.moving, st.point, st.curve = -1, -1, -1
		st.last = {-1, 0}
	}
}

// Adds a keyframe after keyframe `after` (halfway to the next by frame,
// or to the end), a copy of it. Returns its index (-1: full).
@(private = "file")
add_key :: proc(d: ^synth.Table_Doc, after: int) -> int {
	if d.count >= synth.TABLE_KEYS do return -1
	from := d.keys[after].position
	next := synth.WAVE_FRAMES - 1
	for j in 0 ..< d.count do if p := d.keys[j].position; p > from && p < next do next = p
	pos := (from + next) / 2
	if pos == from do pos = min(from + 1, synth.WAVE_FRAMES - 1)
	d.keys[d.count] = d.keys[after]
	d.keys[d.count].position = pos
	d.count += 1
	return d.count - 1
}

// The keyframes as markers along the table's frames: click to choose,
// drag along, double-click between for a new one. Returns an edit's name.
@(private = "file")
key_strip :: proc(st: ^Wave_Editor, d: ^synth.Table_Doc, w: f32, color: ui.Color) -> (edit: string) {
	t := ui.theme()
	dl := im.GetWindowDrawList()
	pos := im.GetCursorScreenPos()
	h: f32 = 30
	im.InvisibleButton("##keystrip", {w, h})
	ui.name("keyframes")
	im.DrawList_AddRectFilled(dl, pos, {pos.x + w, pos.y + h}, ui.col(ui.PLOT_BG), t.radius)
	x0, x1 := pos.x + 10, pos.x + w - 10
	fx :: proc(x0, x1: f32, f: int) -> f32 { return x0 + (x1 - x0) * f32(f) / (synth.WAVE_FRAMES - 1) }
	for f := 0; f < synth.WAVE_FRAMES; f += 32 do im.DrawList_AddLine(dl, {fx(x0, x1, f), pos.y + h - 6}, {fx(x0, x1, f), pos.y + h}, ui.col(t.text_dim), 1)
	mouse := im.GetMousePos()
	frame := clamp(int(math.round((mouse.x - x0) / (x1 - x0) * (synth.WAVE_FRAMES - 1))), 0, synth.WAVE_FRAMES - 1)
	near := -1
	for j in 0 ..< d.count do if abs(fx(x0, x1, d.keys[j].position) - mouse.x) < 8 do near = j
	if im.IsItemClicked(.Left) {
		if near >= 0 {
			st.key, st.moving = near, near
		} else if im.IsMouseDoubleClicked(.Left) && d.count < synth.TABLE_KEYS {
			d.keys[d.count] = d.keys[st.key]
			d.keys[d.count].position = frame
			st.key = d.count
			d.count += 1
			edit = "Add Keyframe"
		}
	}
	if im.IsItemActive() && st.moving >= 0 && st.moving < d.count && d.keys[st.moving].position != frame {
		d.keys[st.moving].position = frame
		edit = "Move Keyframe"
	}
	for j in 0 ..< d.count {
		x := fx(x0, x1, d.keys[j].position)
		c := color if j == st.key else ui.mix(ui.PLOT_BG, t.text, 0.55)
		im.DrawList_AddTriangleFilled(dl, {x, pos.y + 4}, {x - 7, pos.y + h - 6}, {x + 7, pos.y + h - 6}, ui.col(c))
		im.DrawList_AddText(dl, {x + 9, pos.y + 6}, ui.col(t.text_dim), fmt.ctprintf("%d", j + 1))
	}
	if im.IsItemHovered() do im.SetTooltip("Click a keyframe to edit it, drag it along; double-click between for a new one")
	return
}

// A plot area: its background and the rect inside its padding.
@(private = "file")
area :: proc(id: string, size: im.Vec2) -> (dl: ^im.DrawList, x0, y0, x1, y1: f32) {
	dl = im.GetWindowDrawList()
	pos := im.GetCursorScreenPos()
	im.InvisibleButton(fmt.ctprintf("##%s", id), size, {.MouseButtonLeft, .MouseButtonRight})
	ui.name(id)
	im.DrawList_AddRectFilled(dl, pos, {pos.x + size.x, pos.y + size.y}, ui.col(ui.PLOT_BG), ui.theme().radius)
	p: f32 = 12
	x0, y0, x1, y1 = pos.x + p, pos.y + p, pos.x + size.x - p, pos.y + size.y - p
	mid := (y0 + y1) / 2
	im.DrawList_AddLine(dl, {x0, mid}, {x1, mid}, ui.col(ui.mix(ui.PLOT_BG, ui.theme().text, 0.12)), 1)
	return
}

// The keyframe's cycle drawn across the area.
@(private = "file")
draw_cycle :: proc(dl: ^im.DrawList, k: ^synth.Table_Key, sound: []f32, x0, y0, x1, y1: f32, c: ui.Color, thick: f32) {
	wave: [synth.WAVE_SIZE]f32
	synth.table_key_render(k, sound, wave[:])
	N :: 256
	pts: [N]im.Vec2
	mid, amp := (y0 + y1) / 2, (y1 - y0) / 2
	for i in 0 ..< N do pts[i] = {x0 + (x1 - x0) * f32(i) / (N - 1), mid - clamp(wave[i * synth.WAVE_SIZE / N], -1, 1) * amp}
	im.DrawList_AddPolyline(dl, &pts[0], N, ui.col(c), thick)
}

// Drawing: drag to draw the cycle (a stroke fills between where the
// mouse was and is).
@(private = "file")
draw_editor :: proc(st: ^Wave_Editor, k: ^synth.Table_Key, size: im.Vec2, color: ui.Color) -> (changed: bool) {
	dl, x0, y0, x1, y1 := area("wave drawing", size)
	if im.IsItemActive() {
		mp := im.GetMousePos()
		idx := clamp((mp.x - x0) / (x1 - x0) * synth.DRAW_POINTS, 0, synth.DRAW_POINTS - 1)
		val := clamp(1 - 2 * (mp.y - y0) / (y1 - y0), -1, 1)
		from := st.last if st.last.x >= 0 else [2]f32{idx, val}
		a, b := int(min(from.x, idx)), int(max(from.x, idx))
		for i in a ..= b {
			u: f32 = 0 if b == a else (f32(i) - from.x) / (idx - from.x)
			k.draw[i] = from.y + (val - from.y) * clamp(u, 0, 1)
		}
		st.last = {idx, val}
		changed = true
	}
	draw_cycle(dl, k, nil, x0, y0, x1, y1, color, 2.4)
	if im.IsItemHovered() do im.SetTooltip("Drag to draw the wave")
	return
}

// Line shapes: drag a point, double-click for a new one, right-click one
// to remove it; the dot halfway along a line bends it.
@(private = "file")
line_editor :: proc(st: ^Wave_Editor, k: ^synth.Table_Key, size: im.Vec2, color: ui.Color) -> (changed: bool) {
	dl, x0, y0, x1, y1 := area("wave lines", size)
	t := ui.theme()
	c := clamp(k.point_count, 1, synth.LINE_POINTS)
	to_screen :: proc(p: [2]f32, x0, y0, x1, y1: f32) -> im.Vec2 { return {x0 + (x1 - x0) * p[0], (y0 + y1) / 2 - p[1] * (y1 - y0) / 2} }
	mp := im.GetMousePos()
	mx := clamp((mp.x - x0) / (x1 - x0), 0, 1)
	my := clamp(1 - 2 * (mp.y - y0) / (y1 - y0), -1, 1)
	hot, hot_curve := -1, -1
	for q in 0 ..< c {
		s := to_screen(k.points[q], x0, y0, x1, y1)
		if abs(s.x - mp.x) < 8 && abs(s.y - mp.y) < 8 do hot = q
	}
	mids: [synth.LINE_POINTS]im.Vec2
	for q in 0 ..< c - 1 {
		a, b := k.points[q], k.points[q + 1]
		mx2 := (a[0] + b[0]) / 2
		my2 := a[1] + (b[1] - a[1]) * synth.power_scale(0.5, k.powers[q])
		mids[q] = to_screen({mx2, my2}, x0, y0, x1, y1)
		if hot < 0 && abs(mids[q].x - mp.x) < 7 && abs(mids[q].y - mp.y) < 7 do hot_curve = q
	}
	if im.IsItemClicked(.Left) {
		if hot >= 0 do st.point = hot
		else if hot_curve >= 0 do st.curve = hot_curve
		else if im.IsMouseDoubleClicked(.Left) && c < synth.LINE_POINTS {
			at := c
			for q in 0 ..< c do if k.points[q][0] > mx {
				at = q
				break
			}
			for q := c; q > at; q -= 1 {
				k.points[q] = k.points[q - 1]
				k.powers[q] = k.powers[q - 1]
			}
			k.points[at] = {mx, my}
			k.powers[at] = 0
			k.point_count = c + 1
			st.point = at
			changed = true
		}
	}
	if im.IsItemClicked(.Right) && hot >= 0 && c > 2 {
		for q in hot ..< c - 1 {
			k.points[q] = k.points[q + 1]
			k.powers[q] = k.powers[q + 1]
		}
		k.point_count = c - 1
		changed = true
	}
	c = clamp(k.point_count, 1, synth.LINE_POINTS)
	if im.IsItemActive() && st.point >= 0 && st.point < c {
		lo: f32 = k.points[st.point - 1][0] if st.point > 0 else 0
		hi: f32 = k.points[st.point + 1][0] if st.point < c - 1 else 1
		k.points[st.point] = {clamp(mx, lo, hi), my}
		changed = true
	}
	if im.IsItemActive() && st.curve >= 0 && st.curve < c - 1 && im.GetIO().MouseDelta.y != 0 {
		a, b := k.points[st.curve], k.points[st.curve + 1]
		dir: f32 = 1 if b[1] >= a[1] else -1
		k.powers[st.curve] = clamp(k.powers[st.curve] + im.GetIO().MouseDelta.y * 0.08 * dir, -20, 20)
		changed = true
	}
	draw_cycle(dl, k, nil, x0, y0, x1, y1, color, 2.4)
	for q in 0 ..< c - 1 do im.DrawList_AddCircle(dl, mids[q], 4 if q != hot_curve else 5.5, ui.col(ui.mix(color, t.text, 0.4)), 12, 1.5)
	for q in 0 ..< c {
		s := to_screen(k.points[q], x0, y0, x1, y1)
		im.DrawList_AddCircleFilled(dl, s, 6 if q == hot || q == st.point else 4.5, ui.col(t.text))
	}
	if im.IsItemHovered() do im.SetTooltip("Drag a point; double-click for a new one; right-click one to remove it; drag a line's middle dot to bend it")
	return
}

// Harmonics: each harmonic's level as a bar (drag across them to set
// them), its phase as a bar below.
@(private = "file")
harmonics_editor :: proc(k: ^synth.Table_Key, size: im.Vec2, color: ui.Color) -> (changed: bool) {
	t := ui.theme()
	dl := im.GetWindowDrawList()
	pos := im.GetCursorScreenPos()
	im.InvisibleButton("##harmonics", size)
	ui.name("harmonics")
	im.DrawList_AddRectFilled(dl, pos, {pos.x + size.x, pos.y + size.y}, ui.col(ui.PLOT_BG), t.radius)
	p: f32 = 12
	x0, x1 := pos.x + p, pos.x + size.x - p
	ly0, ly1 := pos.y + p, pos.y + (size.y - p) * 0.72
	py0, py1 := ly1 + 14, pos.y + size.y - p
	bw := (x1 - x0) / synth.TABLE_HARMONICS
	if im.IsItemActive() {
		mp := im.GetMousePos()
		h := clamp(int((mp.x - x0) / bw), 0, synth.TABLE_HARMONICS - 1)
		if im.GetIO().MouseClickedPos[0].y < ly1 + 7 {
			k.levels[h] = clamp((ly1 - mp.y) / (ly1 - ly0), 0, 1)
		} else {
			k.phases[h] = clamp((py1 - mp.y) / (py1 - py0), 0, 1)
		}
		changed = true
	}
	for h in 0 ..< synth.TABLE_HARMONICS {
		x := x0 + f32(h) * bw
		im.DrawList_AddRectFilled(dl, {x + 1, ly1 - k.levels[h] * (ly1 - ly0)}, {x + bw - 1, ly1}, ui.col(color))
		im.DrawList_AddRectFilled(dl, {x + 1, py1 - k.phases[h] * (py1 - py0)}, {x + bw - 1, py1}, ui.col(ui.with_alpha(ui.mix(color, t.text, 0.4), 0.7)))
	}
	im.DrawList_AddText(dl, {x1 - 40, ly0}, ui.col(t.text_dim), "Level")
	im.DrawList_AddText(dl, {x1 - 44, py0 - 2}, ui.col(t.text_dim), "Phase")
	if im.IsItemHovered() {
		h := clamp(int((im.GetMousePos().x - x0) / bw), 0, synth.TABLE_HARMONICS - 1)
		im.SetTooltip("%s", fmt.ctprintf("Harmonic %d: level %.0f%%, phase %.0f° (drag across the bars)", h + 1, k.levels[h] * 100, k.phases[h] * 360))
	}
	return
}

// Audio: the table's sound, the cycle taken from it marked (drag it
// along); a sound dropped here becomes the table's. Returns whether the
// slice moved, and a new sound's id.
@(private = "file")
audio_editor :: proc(a: ^App, k: ^synth.Table_Key, d: ^pm.Wave_Doc, sound: []f32, size: im.Vec2, color: ui.Color) -> (changed: bool, sample: app.Id) {
	t := ui.theme()
	dl, x0, y0, x1, y1 := area("wave audio", size)
	if im.BeginDragDropTarget() {
		if pl := im.AcceptDragDropPayload("PADS_FILE"); pl != nil {
			path := strings.string_from_ptr((^u8)(pl.Data), int(pl.DataSize))
			if id, err := pm.import_sample(&a.m, path); err == .None do sample = id
		}
		im.EndDragDropTarget()
	}
	if len(sound) == 0 {
		msg: cstring = "Drop a sound here: each audio keyframe takes a cycle of it"
		ts := im.CalcTextSize(msg)
		im.DrawList_AddText(dl, {(x0 + x1 - ts.x) / 2, (y0 + y1 - ts.y) / 2}, ui.col(t.text_dim), msg)
		return
	}
	// The whole sound above, the cycle taken below.
	split := y0 + (y1 - y0) * 0.45
	N :: 400
	mid := (y0 + split) / 2
	amp := (split - y0) / 2
	for i in 0 ..< N {
		lo, hi: f32 = 0, 0
		a0, a1 := i * len(sound) / N, (i + 1) * len(sound) / N
		for j in a0 ..< max(a1, a0 + 1) do if j < len(sound) {
			lo, hi = min(lo, sound[j]), max(hi, sound[j])
		}
		x := x0 + (x1 - x0) * f32(i) / N
		im.DrawList_AddLine(dl, {x, mid - hi * amp}, {x, mid - lo * amp + 1}, ui.col(ui.mix(ui.PLOT_BG, t.text, 0.35)), 1)
	}
	frac := f32(synth.WAVE_SIZE) / f32(max(len(sound), synth.WAVE_SIZE))
	wx0 := x0 + (x1 - x0) * k.audio_at * (1 - frac)
	wx1 := wx0 + max((x1 - x0) * frac, 3)
	im.DrawList_AddRectFilled(dl, {wx0, y0}, {wx1, split}, ui.col(ui.with_alpha(color, 0.35)))
	im.DrawList_AddRect(dl, {wx0, y0}, {wx1, split}, ui.col(color), 0, 1.5)
	if im.IsItemActive() && im.GetIO().MouseClickedPos[0].y < split {
		k.audio_at = clamp((im.GetMousePos().x - x0) / (x1 - x0), 0, 1)
		changed = true
	}
	draw_cycle(dl, k, sound, x0, split + 10, x1, y1, color, 2.4)
	if im.IsItemHovered() do im.SetTooltip("Drag along the sound to choose the cycle; drop another sound to change it")
	_ = d
	return
}

// Table `tab`'s frames stacked back in perspective, `size` big, frame
// `now` lit (or `lit`, drawn in its place).
draw_table_3d :: proc(tab: ^synth.Wavetable, size: im.Vec2, color: ui.Color, now: int, lit: []f32) {
	t := ui.theme()
	dl := im.GetWindowDrawList()
	pos := im.GetCursorScreenPos()
	im.Dummy(size)
	ui.name("table preview")
	im.DrawList_AddRectFilled(dl, pos, {pos.x + size.x, pos.y + size.y}, ui.col(ui.PLOT_BG), t.radius)
	if tab == nil do return
	shown := min(tab.frames, 24)
	pad: f32 = 10
	depth := size.y * 0.35 if tab.frames > 1 else 0
	w := size.x - 2 * pad - depth * 0.6
	h := (size.y - 2 * pad - depth) * 0.5
	for k := shown - 1; k >= 0; k -= 1 {
		f := k * (tab.frames - 1) / max(shown - 1, 1)
		d := f32(k) / f32(max(shown - 1, 1))
		draw_frame(dl, tab.waves[f][:], pos.x + pad + d * depth * 0.6, pos.y + pad + h + (1 - d) * depth, w, h * 0.9, ui.with_alpha(ui.mix(ui.PLOT_BG, t.text, 0.25), 0.7), 1)
	}
	n := clamp(now, 0, tab.frames - 1)
	d := f32(n) / f32(max(tab.frames - 1, 1))
	wave := lit if lit != nil else tab.waves[n][:]
	draw_frame(dl, wave, pos.x + pad + d * depth * 0.6, pos.y + pad + h + (1 - d) * depth, w, h * 0.9, color, 2)
	im.DrawList_AddText(dl, {pos.x + 8, pos.y + size.y - im.GetTextLineHeight() - 6}, ui.col(t.text_dim), fmt.ctprintf("%s · %d frame%s", tab.name, tab.frames, "" if tab.frames == 1 else "s"))
}
