package dsp

import "core:math"
import "core:mem"

import "fire:core"

// How a `Delay_Line` reads between samples.
Interpolation :: enum u8 {
	None,   // the nearest older sample
	Linear, // cheap; dulls highs a little at fractional delays
	Cubic,  // 4-point Hermite: smooth, for modulated delays (chorus, flanger)
}

// A single-channel delay line of up to `max_delay` frames, with
// fractional reads. Write each frame, then read it back any delay later.
Delay_Line :: struct {
	buffer: []f32, // power-of-two length
	mask:   int,
	pos:    int, // where the next write goes
}

// Control thread. Allocates a delay line that can delay by up to
// `max_delay` frames (plus room for interpolation). Free with
// `delay_line_destroy`.
delay_line_init :: proc(d: ^Delay_Line, max_delay: int, allocator := context.allocator) -> core.Error {
	n := 4
	for n < max_delay + 4 do n *= 2
	err: mem.Allocator_Error
	d.buffer, err = make([]f32, n, allocator)
	d.mask, d.pos = n - 1, 0
	return .Out_Of_Memory if err != nil else .None
}

// Control thread. Frees the delay line.
delay_line_destroy :: proc(d: ^Delay_Line, allocator := context.allocator) {
	delete(d.buffer, allocator)
	d^ = {}
}

// [rt] Silences the delay line.
delay_line_clear :: proc "contextless" (d: ^Delay_Line) {
	for &x in d.buffer do x = 0
}

// [rt] Adds the next frame.
delay_line_write :: #force_inline proc "contextless" (d: ^Delay_Line, x: f32) {
	d.buffer[d.pos] = x
	d.pos = (d.pos + 1) & d.mask
}

// [rt] The frame written `delay` frames before the last write (0 = the last
// write). `delay` is clamped to what the line holds; Cubic reads at least 1
// frame back.
delay_line_read :: #force_inline proc "contextless" (d: ^Delay_Line, delay: f64, interp := Interpolation.Linear) -> f32 {
	top := f64(len(d.buffer) - 4)
	dl := clamp(delay, 1 if interp == .Cubic else 0, top)
	i := int(dl)
	t := f32(dl - f64(i))
	at :: #force_inline proc "contextless" (d: ^Delay_Line, back: int) -> f32 { return d.buffer[(d.pos - 1 - back) & d.mask] }
	switch interp {
	case .None:
		return at(d, int(dl + 0.5))
	case .Linear:
		a, b := at(d, i), at(d, i + 1)
		return a + (b - a) * t
	case .Cubic: // Catmull-Rom through the samples around the read point
		xm1, x0, x1, x2 := at(d, i - 1), at(d, i), at(d, i + 1), at(d, i + 2)
		c1 := 0.5 * (x1 - xm1)
		c2 := xm1 - 2.5 * x0 + 2 * x1 - 0.5 * x2
		c3 := 0.5 * (x2 - xm1) + 1.5 * (x0 - x1)
		return ((c3 * t + c2) * t + c1) * t + x0
	}
	return 0
}

// The shape of an `Lfo`.
Lfo_Shape :: enum u8 {
	Sine,
	Triangle,
	Saw_Up,
	Saw_Down,
	Square,
	Random, // a new random value each cycle, held (sample and hold)
}

// A low-frequency oscillator, from −1 to 1. Free-running at a rate in Hz,
// or locked to a beat position with `lfo_sync`.
Lfo :: struct {
	shape: Lfo_Shape,
	phase: f64, // 0..1
	step:  f64, // cycles per frame
	seed:  u32,
	held:  f64, // Random: the current value
}

// [rt] Sets the rate in Hz.
lfo_set_rate :: proc "contextless" (l: ^Lfo, hz, sample_rate: f64) {
	l.step = max(hz, 0) / sample_rate
}

// [rt] The shape's value at `phase` (0..1, wrapping). Random returns 0;
// use `lfo_next` for it.
lfo_shape_at :: proc "contextless" (shape: Lfo_Shape, phase: f64) -> f64 {
	p := phase - math.floor(phase)
	switch shape {
	case .Sine:     return math.sin(math.TAU * p)
	case .Triangle: return 1 - 4 * abs(p - 0.5) // −1 at 0, 1 at 0.5
	case .Saw_Up:   return 2 * p - 1
	case .Saw_Down: return 1 - 2 * p
	case .Square:   return 1 if p < 0.5 else -1
	case .Random:   return 0
	}
	return 0
}

// [rt] The value now, then advances one frame.
lfo_next :: #force_inline proc "contextless" (l: ^Lfo) -> f64 {
	v := l.held if l.shape == .Random else lfo_shape_at(l.shape, l.phase)
	l.phase += l.step
	if l.phase >= 1 {
		l.phase -= math.floor(l.phase)
		if l.shape == .Random {
			l.seed = l.seed * 1664525 + 1013904223
			l.held = f64(l.seed >> 8) / f64(1 << 23) - 1
		}
	}
	return v
}

// [rt] Locks the LFO to the beat: one cycle per `period_beats`, at phase 0
// on every multiple of it, from timeline position `beat`. Call it once
// per block with the position at the block's start, and set the step from
// the tempo (`lfo_set_rate(l, bpm / 60 / period_beats, sample_rate)`).
lfo_sync :: proc "contextless" (l: ^Lfo, beat, period_beats: f64) {
	if period_beats <= 0 do return
	c := beat / period_beats
	l.phase = c - math.floor(c)
}
