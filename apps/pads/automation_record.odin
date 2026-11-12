package pads

import "core:math"

import app "app:core"
import pm "model"

// Recording knob moves: with the Automation arm on (beside Rec, off by
// default) and recording while playing, a knob or fader moved writes its
// moves into the current sequence as points on its target, over what was
// there for as long as it is held (touch); a pass round the loop is one
// undo step. Off, knobs only change the sound.

// A move being recorded.
Auto_Rec :: struct {
	armed:   bool, // the Automation arm (Settings it is not: it is the toolbar's)
	active:  bool, // a knob is held and being written
	target:  pm.Auto_Target,
	points:  [dynamic]pm.Auto_Point,
	last:    f64, // the beat of the newest point (a smaller one: the loop went round)
	passes:  int, // passes written (for tests)
}

// Whether moves are being written: armed, recording and playing.
@(private)
recording_moves :: proc(a: ^App) -> bool {
	if !a.auto_rec.armed || !a.capture.armed do return false
	_, playing := pm.position(&a.m.engine)
	return playing
}

// A knob on target `t` was touched: a pass begins (if recording moves).
record_touch :: proc(a: ^App, t: pm.Auto_Target) {
	r := &a.auto_rec
	if !recording_moves(a) do return
	full, ok := complete_target(a, t)
	if !ok do return
	record_flush(a)
	r.active, r.target, r.last = true, full, -1
	clear(&r.points)
}

// The knob held moved to `value` (in its target's units, `a.knob_scale`
// times what the knob shows): a point where the playhead is.
record_move :: proc(a: ^App, value: f32) {
	r := &a.auto_rec
	if !r.active do return
	if !recording_moves(a) {
		record_release(a)
		return
	}
	beat, _ := pm.position(&a.m.engine)
	v := clamp(value * a.knob_scale, r.target.lo, r.target.hi)
	if r.last >= 0 && beat < r.last - 1e-6 do record_flush(a) // round the loop: that pass is written, a new one begins
	if len(r.points) > 0 && beat - r.points[len(r.points) - 1].beat < 1.0 / 64 {
		r.points[len(r.points) - 1].value = v
	} else {
		append(&r.points, pm.Auto_Point{lane = {pad = r.target.index if r.target.track == .Pad else 0, target = r.target}, beat = beat, value = v})
	}
	r.last = beat
}

// The knob let go: what was written goes into the sequence.
record_release :: proc(a: ^App) {
	record_flush(a)
	a.auto_rec.active = false
}

// Writes the points of this pass (thinned: a point kept only where the
// line through its neighbours misses it by more than 1% of the range)
// over the beats they cover, one undo step.
@(private)
record_flush :: proc(a: ^App) {
	r := &a.auto_rec
	defer clear(&r.points)
	if !r.active || len(r.points) == 0 do return
	pts := thin_points(r.points[:], (r.target.hi - r.target.lo) * 0.01)
	lo, hi := pts[0].beat, pts[len(pts) - 1].beat
	m := &a.m
	pm.replace_lane_range_of(m, m.project.slot, pts[0].lane, lo, hi, pts)
	app.seal(&m.history)
	r.passes += 1
	r.last = -1
}

// `pts` with the points a straight line through their neighbours passes
// within `tol` of left out (the first and last kept).
@(private)
thin_points :: proc(pts: []pm.Auto_Point, tol: f32) -> []pm.Auto_Point {
	if len(pts) <= 2 do return pts
	out := make([dynamic]pm.Auto_Point, 0, len(pts), context.temp_allocator)
	append(&out, pts[0])
	for k in 1 ..< len(pts) - 1 {
		prev := out[len(out) - 1]
		next := pts[k + 1]
		span := next.beat - prev.beat
		f := f32((pts[k].beat - prev.beat) / span) if span > 1e-9 else 0
		line := prev.value + (next.value - prev.value) * f
		if math.abs(pts[k].value - line) > tol do append(&out, pts[k])
	}
	append(&out, pts[len(pts) - 1])
	return out[:]
}
