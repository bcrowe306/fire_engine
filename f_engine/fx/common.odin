package fx

import "core:math"

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
