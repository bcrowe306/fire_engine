package fx

import "core:math"
import "core:simd"

import "fire:core"

// The effects' shared parts: a delay line read between samples, soft
// clipping, equal-power fades and tempo divisions.

// A delay line a side (or a voice): written a sample at a time, read
// `past` samples back (2 or more), cubically between samples. Its length
// is a power of two. Made with `line_make`.
Line :: struct {
	buf:  []f32,
	mask: int,
	at:   int, // where the next sample goes
}

// Control thread. A delay line holding at least `frames` samples.
line_make :: proc(frames: int, allocator := context.allocator) -> (l: Line, err: core.Error) {
	n := 8
	for n < frames + 8 do n *= 2
	b, ae := make([]f32, n, allocator)
	if ae != nil do return {}, .Out_Of_Memory
	return {buf = b, mask = n - 1}, .None
}

// Control thread. Frees a delay line.
line_destroy :: proc(l: ^Line, allocator := context.allocator) {
	delete(l.buf, allocator)
	l^ = {}
}

// The longest delay a line can be read at (samples).
line_max :: #force_inline proc "contextless" (l: ^Line) -> f32 { return f32(len(l.buf) - 6) }

// [rt] Clears a line.
line_clear :: proc "contextless" (l: ^Line) {
	for &v in l.buf do v = 0
}

// [rt] Writes the next sample.
line_push :: #force_inline proc "contextless" (l: ^Line, x: f32) #no_bounds_check {
	l.buf[l.at] = x
	l.at = (l.at + 1) & l.mask
}

// [rt] The sample `past` samples back from the last written (2 ..
// line_max), with a Catmull-Rom cubic between samples.
line_read :: #force_inline proc "contextless" (l: ^Line, past: f32) -> f32 #no_bounds_check {
	p := clamp(past, 2, line_max(l))
	whole := int(p)
	t := f32(whole) - p + 1
	i := l.at - whole - 2
	m := l.mask
	p0, p1, p2, p3 := l.buf[i & m], l.buf[(i + 1) & m], l.buf[(i + 2) & m], l.buf[(i + 3) & m]
	return p1 + 0.5 * t * (p2 - p0 + t * (2 * p0 - 5 * p1 + 4 * p2 - p3 + t * (3 * (p1 - p2) + p3 - p0)))
}

// [rt] Equal-power fade: the wet gain at `t` (0..1) and the dry gain.
equal_power :: #force_inline proc "contextless" (t: f32) -> (wet, dry: f32) {
	x := clamp(t, 0, 1) * math.PI / 2
	return math.sin(x), math.cos(x)
}

// [rt] A soft-knee clip of large values (straight to ±8 × 0.66, then
// tanh): what a feedback loop is held by.
clip_large :: #force_inline proc "contextless" (x: f32) -> f32 {
	if abs(x) <= 8 * 0.66 do return x // (below hard_tanh's knee: x itself, exactly)
	return hard_tanh(x / 8) * 8
}

// Tempo divisions effects sync to (an index), as cycles a beat: 0 is
// frozen, then 32 bars ... 1/64.
TEMPO_RATIOS :: [13]f32{0, 1.0 / 128, 1.0 / 64, 1.0 / 32, 1.0 / 16, 1.0 / 8, 1.0 / 4, 1.0 / 2, 1, 2, 4, 8, 16}

// How a rate is set: free (in Hz), or to the tempo (straight, dotted or
// triplet).
Sync :: enum u8 {Free, Tempo, Dotted, Triplet}

// [rt] A rate in Hz: `hz` free, else tempo division `tempo` at `bpm`.
sync_hz :: proc "contextless" (sync: Sync, hz: f32, tempo: int, bpm: f64) -> f32 {
	ratios := TEMPO_RATIOS
	r := ratios[clamp(tempo, 0, 12)] * f32(bpm / 60)
	switch sync {
	case .Free:    return hz
	case .Tempo:   return r
	case .Dotted:  return r * 2.0 / 3
	case .Triplet: return r * 1.5
	}
	return hz
}

// [rt] A two-pole state-variable low-pass and high-pass at `g` (a TPT
// coefficient, tan(π f / sr)) and Q 1/√2: a Butterworth section. `st` is
// its two states; returns (low, high).
@(private)
butter :: #force_inline proc "contextless" (st: []f32, x, g: f32) -> (low, high: f32) #no_bounds_check {
	k: f32 = math.SQRT_TWO
	h := (x - (k + g) * st[0] - st[1]) / (1 + g * (k + g))
	b := g * h + st[0]
	st[0] = g * h + b
	l := g * b + st[1]
	st[1] = g * b + l
	return l, h
}

// Four delay lines written together, interleaved: a sample of each at
// every place, so a write is one vector. Each reads as the `Line`
// `line_make` would have made it (the same longest delay), the buffer as
// long as the longest's. The reverb's rows.
Line4 :: struct {
	buf:  []#simd[4]f32,
	mask: int,
	at:   int,
	max:  #simd[4]f32, // each line's `line_max`
}

// Control thread. Four lines holding at least `frames` samples each.
@(private)
line4_make :: proc(frames: [4]int, allocator := context.allocator) -> (l: Line4, err: core.Error) {
	size :: proc(frames: int) -> int {
		n := 8
		for n < frames + 8 do n *= 2
		return n
	}
	n := 0
	maxes: [4]f32
	for f, j in frames {
		n = max(n, size(f))
		maxes[j] = f32(size(f) - 6)
	}
	b, ae := make([]#simd[4]f32, n, allocator)
	if ae != nil do return {}, .Out_Of_Memory
	return {buf = b, mask = n - 1, max = #simd[4]f32{maxes[0], maxes[1], maxes[2], maxes[3]}}, .None
}

// Control thread. Frees four lines.
@(private)
line4_destroy :: proc(l: ^Line4, allocator := context.allocator) {
	delete(l.buf, allocator)
	l^ = {}
}

// [rt] Clears four lines.
@(private)
line4_clear :: proc "contextless" (l: ^Line4) {
	for &v in l.buf do v = 0
	l.at = 0
}

// [rt] Clears line `j` of four (the others kept).
@(private)
line4_clear_lane :: proc "contextless" (l: ^Line4, j: int) #no_bounds_check {
	for &v in l.buf do (^[4]f32)(&v)[j] = 0
}

// [rt] Writes the next sample of each.
@(private)
line4_push :: #force_inline proc "contextless" (l: ^Line4, x: #simd[4]f32) #no_bounds_check {
	l.buf[l.at] = x
	l.at = (l.at + 1) & l.mask
}

// [rt] `line_read` of each line, `past` a lane each.
@(private)
line4_read :: #force_inline proc "contextless" (l: ^Line4, past: #simd[4]f32) -> #simd[4]f32 #no_bounds_check {
	V :: #simd[4]f32
	I :: #simd[4]i32
	p := simd.clamp(past, V(2), l.max)
	whole := cast(I)p
	t := cast(V)whole - p + 1
	m := I(i32(l.mask))
	i := (I(i32(l.at)) - whole - 2) & m
	ia := simd.to_array(i)
	q0, q1, q2, q3: [4]f32
	#unroll for j in 0 ..< 4 {
		k := int(ia[j])
		q0[j] = (^[4]f32)(&l.buf[k])[j]
		q1[j] = (^[4]f32)(&l.buf[(k + 1) & l.mask])[j]
		q2[j] = (^[4]f32)(&l.buf[(k + 2) & l.mask])[j]
		q3[j] = (^[4]f32)(&l.buf[(k + 3) & l.mask])[j]
	}
	p0, p1 := V{q0[0], q0[1], q0[2], q0[3]}, V{q1[0], q1[1], q1[2], q1[3]}
	p2, p3 := V{q2[0], q2[1], q2[2], q2[3]}, V{q3[0], q3[1], q3[2], q3[3]}
	return p1 + 0.5 * t * (p2 - p0 + t * (2 * p0 - 5 * p1 + 4 * p2 - p3 + t * (3 * (p1 - p2) + p3 - p0)))
}
