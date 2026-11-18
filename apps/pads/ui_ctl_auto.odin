// The sequencer's Automation tab on a controller's display (Push 2's
// Clip, the upper row's second tab; Automate held long or with Shift goes
// there): the lane the window's Automation tab shows (one state), its
// curve across the sequence, its points (the selected one ringed), the
// playhead. The knobs: the lane (the sequence's, and the selected pad's
// own), the point, its place and value and curve, the grid. The lower
// row: Add (at the playhead while playing, else a step after the point),
// Delete, Clear Lane, Record (automation recording: the toolbar's Auto).
package pads

import "core:fmt"
import "core:math"

import app "app:core"
import "app:ui"
import pa "api"
import pm "model"
import im "deps:imgui"

// The pad's own lanes, offered whether the sequence has them or not.
PAD_LANES := []pm.Lane_Param{.Volume, .Pitch, .Eq_Low, .Eq_Mid, .Eq_High, .Cutoff, .Resonance}

// The lanes a controller offers: the sequence's (any target) and the
// selected pad's own, without repeats.
@(private)
ctl_auto_lanes :: proc(a: ^App, s: pm.Sequence) -> []pm.Lane {
	out := make([dynamic]pm.Lane, context.temp_allocator)
	has :: proc(out: []pm.Lane, l: pm.Lane) -> bool {
		for x in out do if pm.lane_equal(x, l) do return true
		return false
	}
	pad := auto_target_pad(a)
	for lp in PAD_LANES do append(&out, pm.pad_lane(pad, lp))
	for p in s.points do if !has(out[:], p.lane) do append(&out, p.lane)
	cur := current_lane(a)
	if !has(out[:], cur) do append(&out, cur)
	return out[:]
}

// Shows lane `l` in the Automation tab (the window's too).
@(private)
ctl_auto_show :: proc(a: ^App, l: pm.Lane) {
	if l.target.track != .None {
		a.seq.target = l.target
	} else {
		a.seq.target, a.seq.param, a.seq.auto_pad = {}, l.param, int(l.pad)
	}
	a.ctl.auto_point = 0
}

@(private)
ctl_automation :: proc(ctx: ^View_Ctx, full: im.Vec2, plot: im.Vec2) {
	a := ctx.a
	m := &a.m
	st := &a.seq
	slot := m.project.slot
	s := pm.current_sequence(m)
	l := current_lane(a)
	length := pm.seq_beats(&m.project, s)
	// The lane: the automation's, then MIDI CC lanes.
	lanes := ctl_auto_lanes(a, s)
	ccs := ctl_cc_lanes(a, s)
	names := make([]string, len(lanes) + len(ccs), context.temp_allocator)
	cur := 0
	for x, k in lanes {
		names[k] = lane_name(a, x)
		if a.ctl.auto_cc == 0 && pm.lane_equal(x, l) do cur = k
	}
	for x, k in ccs {
		names[len(lanes) + k] = fmt.tprintf("%s · CC %d", pm.pad_label(x[0]), x[1])
		if a.ctl.auto_cc == x[1] + 1 && a.ctl.auto_cc_pad == x[0] do cur = len(lanes) + k
	}
	if k, _ := ctl_choice(ctx, 0, 8, "Lane", names, cur, plot); k >= 0 && k != cur {
		if k < len(lanes) {
			a.ctl.auto_cc = 0
			ctl_auto_show(a, lanes[k])
		} else {
			a.ctl.auto_cc, a.ctl.auto_cc_pad = ccs[k - len(lanes)][1] + 1, ccs[k - len(lanes)][0]
			a.ctl.auto_point = 0
		}
		l = current_lane(a)
	}
	if a.ctl.auto_cc > 0 {
		ctl_cc_lane(ctx, full, plot, a.ctl.auto_cc_pad, a.ctl.auto_cc - 1)
		return
	}
	points, first := pm.lane_points_of(s, l)
	sel := clamp(a.ctl.auto_point, 0, max(len(points) - 1, 0))
	// The point.
	if len(points) > 0 {
		pnames := make([]string, len(points), context.temp_allocator)
		for p, k in points do pnames[k] = fmt.tprintf("%d · %s", k + 1, ctl_beat_name(&m.project, p.beat))
		if k, _ := ctl_choice(ctx, 1, 8, "Point", pnames, sel, plot); k >= 0 do sel = k
	} else {
		ctl_value_box(ctx, 1, "Point", "None", CTL_STEP, plot)
	}
	a.ctl.auto_point = sel
	grid := pm.grid_beats(st.grid)
	// Its place, value and curve: a turn a step (one undo step a touch).
	edit :: proc(a: ^App, slot, index: int, p: pm.Auto_Point) -> int {
		pm.set_point(&a.m, slot, index, p) // api-lint: a knob's turns, one undo step (as the Automation tab's drags)
		// (kept in order: find it again)
		s := pm.current_sequence(&a.m)
		pts, _ := pm.lane_points_of(s, p.lane)
		for q, k in pts do if q.beat == p.beat && q.value == p.value do return k
		return 0
	}
	if len(points) > 0 {
		p := points[sel]
		if k, en := ctl_value_box(ctx, 2, "Position", ctl_beat_name(&m.project, p.beat), CTL_STEP, plot); k != 0 || en {
			if k != 0 {
				q := p
				q.beat = clamp(math.round(p.beat / grid + f64(k)) * grid, 0, length)
				a.ctl.auto_point = edit(a, slot, first + sel, q)
			}
			if en do app.seal(&m.history)
		}
		if k, en := ctl_value_box(ctx, 3, "Value", lane_text(a, l, p.value), 1.0 / 160, plot); k != 0 || en {
			if k != 0 {
				q := p
				q.value = lane_denorm(l, lane_norm(l, p.value) + f32(k) * 0.01) // (Shift: the controller's turns a tenth already)
				a.ctl.auto_point = edit(a, slot, first + sel, q)
			}
			if en do app.seal(&m.history)
		}
		if k, en := ctl_value_box(ctx, 4, "Curve", "Line" if abs(p.curve) < 1e-3 else fmt.tprintf("%+.0f%%", p.curve * 100), 1.0 / 160, plot); k != 0 || en {
			if k != 0 {
				q := p
				q.curve = clamp(p.curve + f32(k) * 0.05, -1, 1)
				if abs(q.curve) < 0.025 do q.curve = 0
				a.ctl.auto_point = edit(a, slot, first + sel, q)
			}
			if en do app.seal(&m.history)
		}
	}
	gnames := make([]string, len(pm.Grid), context.temp_allocator)
	for g in pm.Grid do gnames[int(g)] = string(pm.GRID_NAMES[g])
	if k, _ := ctl_choice(ctx, 7, 8, "Grid", gnames, int(st.grid), plot); k >= 0 do st.grid = pm.Grid(k)
	// The lower row.
	beat, playing := pm.position(&m.engine)
	if pr, _ := ctl_button(ctx, 0, "Add", false, full); pr {
		at := 0.0
		switch {
		case playing:          at = math.round(math.mod(beat, length) / grid) * grid
		case len(points) > 0: at = points[sel].beat + grid
		}
		at = clamp(at, 0, length)
		v := lane_denorm(l, ui.auto_lane_value(auto_view(l, points), at)) if len(points) > 0 else lane_denorm(l, 0.5)
		pm.add_point(m, slot, {lane = l, beat = at, value = v}) // api-lint: any lane's point (the API's take a pad lane or a parameter)
		pts, _ := pm.lane_points_of(pm.current_sequence(m), l)
		for q, k in pts do if q.beat == at do a.ctl.auto_point = k
	}
	if len(points) > 0 {
		if pr, _ := ctl_button(ctx, 1, "Delete", false, full); pr {
			pa.sequence_remove_point(&a.api, i64(slot), i64(first + sel))
			a.ctl.auto_point = max(sel - 1, 0)
		}
		if pr, _ := ctl_button(ctx, 2, "Clear Lane", false, full); pr {
			pm.clear_lane_of(m, slot, l) // api-lint: any lane (the API's clears take a pad lane)
			a.ctl.auto_point = 0
		}
	}
	armed := a.auto_rec.armed
	if pr, _ := ctl_button(ctx, 3, "Record", armed, full); pr {
		a.auto_rec.armed = !armed
		if armed do record_release(a)
	}
	ctl_auto_draw(a, l, points, a.ctl.auto_point, length, beat if playing else -1, plot)
}

// The lane's curve across the sequence, its points, the playhead.
@(private)
ctl_auto_draw :: proc(a: ^App, l: pm.Lane, points: []pm.Auto_Point, sel: int, length: f64, head: f64, plot: im.Vec2) {
	t := ui.theme()
	dl := im.GetWindowDrawList()
	o := im.GetWindowPos()
	x0, y0 := o.x + 2, o.y + CTL_PLOT_Y
	w, h := plot.x - 4, plot.y
	im.DrawList_AddRectFilled(dl, {x0, y0}, {x0 + w, y0 + h}, ui.col(ui.PLOT_BG), 3)
	col := ui.rgb(a.m.project.pads[clamp(int(l.pad), 0, pm.PADS - 1)].color)
	xb := proc(x0, w: f32, length, b: f64) -> f32 { return x0 + f32(b / max(length, 1e-9)) * w }
	yv := proc(y0, h: f32, n: f32) -> f32 { return y0 + h - 4 - (h - 8) * clamp(n, 0, 1) }
	// Bars.
	bar := pm.bar_beats(&a.m.project)
	for b := 0.0; b < length - 1e-9; b += bar do im.DrawList_AddLine(dl, {xb(x0, w, length, b), y0}, {xb(x0, w, length, b), y0 + h}, ui.col(ui.with_alpha(t.text, 0.10)))
	ui.text_push(.Label)
	defer ui.text_pop()
	name := fmt.ctprintf("%s", lane_name(a, l))
	if len(points) == 0 {
		im.DrawList_AddText(dl, {x0 + 8, y0 + 4}, ui.col(t.text_dim), name)
		msg: cstring = "No points: Add puts one (at the playhead while playing)"
		im.DrawList_AddText(dl, {x0 + (w - im.CalcTextSize(msg).x) / 2, y0 + (h - im.GetTextLineHeight()) / 2}, ui.col(t.text_dim), msg)
	} else {
		// The curve, sampled.
		view := auto_view(l, points)
		prev: im.Vec2
		for k in 0 ..= 240 {
			b := length * f64(k) / 240
			pt := im.Vec2{xb(x0, w, length, b), yv(y0, h, ui.auto_lane_value(view, b))}
			if k > 0 do im.DrawList_AddLine(dl, prev, pt, ui.col(col), 2)
			prev = pt
		}
		for p, k in points {
			c := im.Vec2{xb(x0, w, length, p.beat), yv(y0, h, lane_norm(l, p.value))}
			im.DrawList_AddCircleFilled(dl, c, 4 if k != sel else 5, ui.col(col if k != sel else t.text), 12)
			if k == sel do im.DrawList_AddCircle(dl, c, 8, ui.col(t.text), 16, 1.5)
		}
		im.DrawList_AddText(dl, {x0 + 8, y0 + 4}, ui.col(t.text), name)
		sv := fmt.ctprintf("%s at %s", lane_text(a, l, points[sel].value), ctl_beat_name(&a.m.project, points[sel].beat))
		im.DrawList_AddText(dl, {x0 + w - im.CalcTextSize(sv).x - 8, y0 + 4}, ui.col(t.text_dim), sv)
	}
	if head >= 0 {
		hx := xb(x0, w, length, math.mod(head, max(length, 1e-9)))
		im.DrawList_AddLine(dl, {hx, y0}, {hx, y0 + h}, ui.col(t.text), 1)
	}
}

// Lane `l`'s points as the shared lane widget takes them (0..1 values).
@(private)
auto_view :: proc(l: pm.Lane, points: []pm.Auto_Point) -> []ui.Auto_Lane_Point {
	view := make([]ui.Auto_Lane_Point, len(points), context.temp_allocator)
	for p, i in points do view[i] = {beat = p.beat, value = lane_norm(l, p.value), curve = p.curve}
	return view
}

// --- MIDI CC lanes ------------------------------------------------------------------------------

// The MIDI CC lanes offered: the sequence's (pad, controller), and the
// selected pad's mod wheel (CC 1) and cutoff (CC 74).
@(private)
ctl_cc_lanes :: proc(a: ^App, s: pm.Sequence) -> [][2]int {
	out := make([dynamic][2]int, context.temp_allocator)
	has :: proc(out: [][2]int, x: [2]int) -> bool {
		for y in out do if y == x do return true
		return false
	}
	for c in s.ccs {
		x := [2]int{int(c.pad), int(c.cc)}
		if !has(out[:], x) do append(&out, x)
	}
	pad := auto_target_pad(a)
	for cc in ([]int{1, 74}) {
		x := [2]int{pad, cc}
		if !has(out[:], x) do append(&out, x)
	}
	return out[:]
}

// A MIDI CC lane: its steps (each holds until the next), the selected one
// ringed. The knobs: the step, its place, its value; the lower row: Add,
// Delete, Clear Lane.
@(private)
ctl_cc_lane :: proc(ctx: ^View_Ctx, full, plot: im.Vec2, pad, cc: int) {
	a := ctx.a
	m := &a.m
	slot := m.project.slot
	s := pm.current_sequence(m)
	length := pm.seq_beats(&m.project, s)
	grid := pm.grid_beats(a.seq.grid)
	points, _ := pm.cc_points(s, pad, cc)
	sel := clamp(a.ctl.auto_point, 0, max(len(points) - 1, 0))
	// (a step moved or changed: the old one out, the new one in)
	put :: proc(a: ^App, slot, pad, cc: int, old: pm.Seq_Cc, beat: f64, value: int) {
		pa.sequence_clear_cc(&a.api, i64(slot), i64(pad), i64(cc), old.beat - 1e-9, old.beat + 1e-9)
		pa.sequence_add_cc(&a.api, i64(slot), {beat = beat, pad = i64(pad), cc = i64(cc), value = i64(clamp(value, 0, 127))})
	}
	if len(points) > 0 {
		pnames := make([]string, len(points), context.temp_allocator)
		for c, k in points do pnames[k] = fmt.tprintf("%d · %s", k + 1, ctl_beat_name(&m.project, c.beat))
		if k, _ := ctl_choice(ctx, 1, 8, "Step", pnames, sel, plot); k >= 0 do sel = k
		c := points[sel]
		if k, en := ctl_value_box(ctx, 2, "Position", ctl_beat_name(&m.project, c.beat), CTL_STEP, plot); k != 0 || en {
			if k != 0 do put(a, slot, pad, cc, c, clamp(math.round(c.beat / grid + f64(k)) * grid, 0, length), int(c.value))
			if en do app.seal(&m.history)
		}
		if k, en := ctl_value_box(ctx, 3, "Value", fmt.tprintf("%d", c.value), 1.0 / 160, plot); k != 0 || en {
			if k != 0 do put(a, slot, pad, cc, c, c.beat, int(c.value) + k)
			if en do app.seal(&m.history)
		}
	} else {
		ctl_value_box(ctx, 1, "Step", "None", CTL_STEP, plot)
	}
	a.ctl.auto_point = sel
	gnames := make([]string, len(pm.Grid), context.temp_allocator)
	for g in pm.Grid do gnames[int(g)] = string(pm.GRID_NAMES[g])
	if k, _ := ctl_choice(ctx, 7, 8, "Grid", gnames, int(a.seq.grid), plot); k >= 0 do a.seq.grid = pm.Grid(k)
	beat, playing := pm.position(&m.engine)
	if pr, _ := ctl_button(ctx, 0, "Add", false, full); pr {
		at := 0.0
		v := 64
		switch {
		case playing:          at = math.round(math.mod(beat, length) / grid) * grid
		case len(points) > 0: at = points[sel].beat + grid
		}
		if len(points) > 0 do v = int(points[sel].value)
		pa.sequence_add_cc(&a.api, i64(slot), {beat = clamp(at, 0, length), pad = i64(pad), cc = i64(cc), value = i64(v)})
	}
	if len(points) > 0 {
		if pr, _ := ctl_button(ctx, 1, "Delete", false, full); pr {
			c := points[sel]
			pa.sequence_clear_cc(&a.api, i64(slot), i64(pad), i64(cc), c.beat - 1e-9, c.beat + 1e-9)
			a.ctl.auto_point = max(sel - 1, 0)
		}
		if pr, _ := ctl_button(ctx, 2, "Clear Lane", false, full); pr do pa.sequence_clear_cc(&a.api, i64(slot), i64(pad), i64(cc), 0, length + 1)
	}
	// The picture: steps holding until the next.
	t := ui.theme()
	dl := im.GetWindowDrawList()
	o := im.GetWindowPos()
	x0, y0 := o.x + 2, o.y + CTL_PLOT_Y
	w, h := plot.x - 4, plot.y
	im.DrawList_AddRectFilled(dl, {x0, y0}, {x0 + w, y0 + h}, ui.col(ui.PLOT_BG), 3)
	col := ui.rgb(m.project.pads[pad].color)
	xb :: proc(x0, w: f32, length, b: f64) -> f32 { return x0 + f32(b / max(length, 1e-9)) * w }
	yv :: proc(y0, h: f32, v: u8) -> f32 { return y0 + h - 4 - (h - 8) * f32(v) / 127 }
	ui.text_push(.Label)
	defer ui.text_pop()
	label := fmt.ctprintf("%s · CC %d", pm.pad_label(pad), cc)
	if len(points) == 0 {
		im.DrawList_AddText(dl, {x0 + 8, y0 + 4}, ui.col(t.text_dim), label)
		msg: cstring = "No steps: Add puts one (at the playhead while playing)"
		im.DrawList_AddText(dl, {x0 + (w - im.CalcTextSize(msg).x) / 2, y0 + (h - im.GetTextLineHeight()) / 2}, ui.col(t.text_dim), msg)
		return
	}
	for c, k in points {
		nx := xb(x0, w, length, points[k + 1].beat) if k + 1 < len(points) else x0 + w
		cx := xb(x0, w, length, c.beat)
		y := yv(y0, h, c.value)
		im.DrawList_AddLine(dl, {cx, y}, {nx, y}, ui.col(col), 2)
		if k + 1 < len(points) do im.DrawList_AddLine(dl, {nx, y}, {nx, yv(y0, h, points[k + 1].value)}, ui.col(ui.with_alpha(col, 0.5)), 1)
		im.DrawList_AddCircleFilled(dl, {cx, y}, 4 if k != sel else 5, ui.col(col if k != sel else t.text), 12)
		if k == sel do im.DrawList_AddCircle(dl, {cx, y}, 8, ui.col(t.text), 16, 1.5)
	}
	im.DrawList_AddText(dl, {x0 + 8, y0 + 4}, ui.col(t.text), label)
	sv := fmt.ctprintf("%d at %s", points[sel].value, ctl_beat_name(&m.project, points[sel].beat))
	im.DrawList_AddText(dl, {x0 + w - im.CalcTextSize(sv).x - 8, y0 + 4}, ui.col(t.text_dim), sv)
}
