package clip

import "core:math"
import "core:mem"
import "core:slice"

import "fire:core"
import tb "fire:timebase"

// How the value moves from one automation point to the next.
Segment_Shape :: enum u8 {
	Linear, // a straight line
	Step,   // holds this point's value until the next point, then jumps
	Curve,  // bends by the point's `tension`: positive starts slowly, negative quickly
}

// One breakpoint of an automation lane. Its shape and tension describe the
// segment from it to the next point.
Automation_Point :: struct {
	at:      tb.Beats, // clip position
	value:   f64,      // plain value, in the parameter's own units
	shape:   Segment_Shape,
	tension: f32,      // for `.Curve`: -1..1 (0 is a straight line)
}

// The curve of one parameter. Before its first point it holds the first
// value, after its last point the last.
Automation_Lane :: struct {
	param:  core.Param_Id,
	points: []Automation_Point, // sorted by `at` (points at the same `at` make a jump)
}

// An immutable automation clip: one lane per parameter, in beats. Read its
// fields freely but never change them (players read them on the audio
// thread). Built with an `Automation_Builder`; release with
// `automation_clip_release`.
Automation_Clip :: struct {
	length:     tb.Beats, // the clip's length in beats
	loop_start: tb.Beats, // the part repeated when a placement loops
	loop_end:   tb.Beats,
	lanes:      []Automation_Lane, // sorted by param, one per param
	points:     []Automation_Point, // every lane's points (the lanes' slices point into this)
	refs:       int, // control thread
	allocator:  mem.Allocator,
}

// Collects automation points for a clip. Control thread.
Automation_Builder :: struct {
	length:     tb.Beats,
	loop_start: tb.Beats,
	loop_end:   tb.Beats,
	points:     [dynamic]Builder_Point,
}

@(private)
Builder_Point :: struct {
	param: core.Param_Id,
	point: Automation_Point,
}

// Starts a clip of `length` beats, looping over all of it.
automation_builder_init :: proc(b: ^Automation_Builder, length: tb.Beats, allocator := context.allocator) {
	b^ = {length = length, loop_end = length}
	b.points = make([dynamic]Builder_Point, allocator)
}

// Frees the builder (not the clips built from it).
automation_builder_destroy :: proc(b: ^Automation_Builder) {
	delete(b.points)
	b^ = {}
}

// Adds a point to `param`'s lane (made by its first point). Points may be
// added in any order; two at the same position make a jump, the first
// added giving the value just before it.
automation_add_point :: proc(b: ^Automation_Builder, param: core.Param_Id, at: tb.Beats, value: f64, shape := Segment_Shape.Linear, tension: f32 = 0) {
	append(&b.points, Builder_Point{param, {at = at, value = value, shape = shape, tension = clamp(tension, -1, 1)}})
}

// Sets the part a looping placement repeats (default: the whole clip).
automation_set_loop :: proc(b: ^Automation_Builder, start, end: tb.Beats) {
	b.loop_start, b.loop_end = start, end
}

// Makes an immutable clip from the builder's contents, with one reference
// held by the caller. The builder can keep being edited and built again.
// `.Invalid_Argument` for a bad length or loop, or a point that isn't
// finite.
automation_build :: proc(b: ^Automation_Builder, allocator := context.allocator) -> (c: ^Automation_Clip, err: core.Error) {
	if !(b.length > 0) || b.loop_start < 0 || b.loop_end <= b.loop_start || b.loop_end > b.length {
		return nil, .Invalid_Argument
	}
	for p in b.points {
		if math.is_nan(f64(p.point.at)) || math.is_inf(f64(p.point.at)) || math.is_nan(p.point.value) || math.is_inf(p.point.value) {
			return nil, .Invalid_Argument
		}
	}
	sorted := slice.clone(b.points[:], context.temp_allocator)
	slice.stable_sort_by(sorted, proc(x, y: Builder_Point) -> bool {
		return x.param < y.param || (x.param == y.param && x.point.at < y.point.at)
	})
	lanes := 0
	for p, i in sorted do if i == 0 || p.param != sorted[i - 1].param do lanes += 1

	c = new(Automation_Clip, allocator)
	if c == nil do return nil, .Out_Of_Memory
	c^ = {length = b.length, loop_start = b.loop_start, loop_end = b.loop_end, refs = 1, allocator = allocator}
	ae, ae2: mem.Allocator_Error
	c.points, ae = make([]Automation_Point, len(sorted), allocator)
	c.lanes, ae2 = make([]Automation_Lane, lanes, allocator)
	if ae != nil || ae2 != nil {
		automation_clip_release(c)
		return nil, .Out_Of_Memory
	}
	lane := -1
	for p, i in sorted {
		c.points[i] = p.point
		if i == 0 || p.param != sorted[i - 1].param {
			lane += 1
			c.lanes[lane] = {param = p.param, points = c.points[i:i]}
		}
		c.lanes[lane].points = c.points[i - len(c.lanes[lane].points):i + 1]
	}
	return c, .None
}

// Control thread. Adds a reference (one per place the clip is kept).
automation_clip_retain :: proc(c: ^Automation_Clip) {
	if c != nil do c.refs += 1
}

// Control thread. Drops a reference; the clip is freed with the last one.
automation_clip_release :: proc(c: ^Automation_Clip) {
	if c == nil do return
	c.refs -= 1
	if c.refs > 0 do return
	delete(c.points, c.allocator)
	delete(c.lanes, c.allocator)
	free(c, c.allocator)
}

// Control thread. A new clip like `base`, with `param`'s lane replaced from
// clip position `start` to `end` by `points` (sorted, within the range): what
// writing automation over a range does. The curve jumps to the new points
// at `start` and back to the old curve at `end`. With a nil `base`, makes a
// clip of `length` beats with only this lane. The caller owns the result.
automation_merge :: proc(base: ^Automation_Clip, param: core.Param_Id, start, end: tb.Beats, points: []Automation_Point, length: tb.Beats = 0, allocator := context.allocator) -> (c: ^Automation_Clip, err: core.Error) {
	if !(end >= start) do return nil, .Invalid_Argument
	b: Automation_Builder
	automation_builder_init(&b, base.length if base != nil else length, context.temp_allocator)
	defer automation_builder_destroy(&b)
	if base != nil {
		automation_set_loop(&b, base.loop_start, base.loop_end)
		for &l in base.lanes {
			if l.param != param {
				for p in l.points do automation_add_point(&b, l.param, p.at, p.value, p.shape, p.tension)
				continue
			}
			for p in l.points do if p.at < start do automation_add_point(&b, param, p.at, p.value, p.shape, p.tension)
			if len(l.points) > 0 && start > l.points[0].at do automation_add_point(&b, param, start, left_of(&l, start))
		}
	}
	for p in points do automation_add_point(&b, param, p.at, p.value, p.shape, p.tension)
	if base != nil {
		if l := automation_lane(base, param); l != nil && len(l.points) > 0 {
			if end < l.points[len(l.points) - 1].at do automation_add_point(&b, param, end, automation_value(l, end))
			for p in l.points do if p.at > end do automation_add_point(&b, param, p.at, p.value, p.shape, p.tension)
		}
	}
	return automation_build(&b, allocator)
}

// The lane's value just before `at` (before any jump there).
@(private)
left_of :: proc "contextless" (l: ^Automation_Lane, at: tb.Beats) -> f64 {
	i := segment_at(l, at)
	for i >= 0 && l.points[i].at >= at do i -= 1
	return segment_value(l, i, at)
}

// [rt] The lane for `param`, or nil.
automation_lane :: proc "contextless" (c: ^Automation_Clip, param: core.Param_Id) -> ^Automation_Lane {
	if c == nil do return nil
	for &l in c.lanes do if l.param == param do return &l
	return nil
}

// [rt] The lane's value at clip position `at` (the value after any jump
// there). For drawing curves, and what the player sends.
automation_value :: proc "contextless" (l: ^Automation_Lane, at: tb.Beats) -> f64 {
	return segment_value(l, segment_at(l, at), at)
}

// The segment containing `at`: the index of the last point at or before it
// (-1 before the first).
@(private)
segment_at :: proc "contextless" (l: ^Automation_Lane, at: tb.Beats) -> int {
	lo, hi := 0, len(l.points)
	for lo < hi {
		mid := (lo + hi) / 2
		if l.points[mid].at <= at {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo - 1
}

// Segment `i`'s value at `at`, which may be its end (giving the value just
// before the next point).
@(private)
segment_value :: proc "contextless" (l: ^Automation_Lane, i: int, at: tb.Beats) -> f64 {
	if len(l.points) == 0 do return 0
	if i < 0 do return l.points[0].value
	if i >= len(l.points) - 1 do return l.points[len(l.points) - 1].value
	a, b := l.points[i], l.points[i + 1]
	span := f64(b.at - a.at)
	if a.shape == .Step || !(span > 0) do return a.value
	x := clamp(f64(at - a.at) / span, 0, 1)
	if a.shape == .Curve && abs(a.tension) > 1e-6 {
		k := 8 * f64(a.tension)
		x = (math.exp(k * x) - 1) / (math.exp(k) - 1)
	}
	return a.value + (b.value - a.value) * x
}
