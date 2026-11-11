package ui

import "core:math"

// A waveform's peaks at every zoom: the sound's samples, and levels of
// peaks over blocks of `PEAK_BASE` frames, then 2×, 4×... as many, so a
// view at any zoom reads one or two peaks a pixel (or, zoomed in past a
// block a pixel, the samples themselves). Made once per sound; drawing
// costs a pixel's worth of work whatever the zoom.
Peak_Pyramid :: struct {
	samples: []f32,    // the sound (one channel), kept
	levels:  [][]Peak, // level k: peaks over PEAK_BASE << k frames
}

// Frames a pyramid's finest peaks each cover.
PEAK_BASE :: 16

// Makes the pyramid of `samples` (copied).
peak_pyramid_make :: proc(samples: []f32, allocator := context.allocator) -> (p: Peak_Pyramid) {
	p.samples = make([]f32, len(samples), allocator)
	copy(p.samples, samples)
	levels := make([dynamic][]Peak, allocator)
	n := (len(samples) + PEAK_BASE - 1) / PEAK_BASE
	if n == 0 {
		p.levels = levels[:]
		return
	}
	base := make([]Peak, n, allocator)
	for &pk, i in base {
		a := i * PEAK_BASE
		b := min(a + PEAK_BASE, len(samples))
		lo, hi := samples[a], samples[a]
		for s in samples[a:b] do lo, hi = min(lo, s), max(hi, s)
		pk = {lo, hi}
	}
	append(&levels, base)
	for len(levels[len(levels) - 1]) > 1 {
		prev := levels[len(levels) - 1]
		next := make([]Peak, (len(prev) + 1) / 2, allocator)
		for &pk, i in next {
			x := prev[2 * i]
			if 2 * i + 1 < len(prev) {
				y := prev[2 * i + 1]
				x = {min(x.lo, y.lo), max(x.hi, y.hi)}
			}
			pk = x
		}
		append(&levels, next)
	}
	p.levels = levels[:]
	return
}

// Frees a pyramid.
peak_pyramid_destroy :: proc(p: ^Peak_Pyramid, allocator := context.allocator) {
	for l in p.levels do delete(l, allocator)
	delete(p.levels, allocator)
	delete(p.samples, allocator)
	p^ = {}
}

// The lowest and highest sample from frame `f0` to `f1`, from the
// coarsest level whose blocks are no wider than the span (or the samples).
peak_range :: proc(p: ^Peak_Pyramid, f0, f1: f64) -> (lo, hi: f32, ok: bool) {
	n := len(p.samples)
	if n == 0 do return
	a := clamp(int(math.floor(f0)), 0, n - 1)
	b := clamp(int(math.ceil(f1)), a + 1, n)
	span := f64(b - a)
	if span < PEAK_BASE * 2 || len(p.levels) == 0 {
		lo, hi = p.samples[a], p.samples[a]
		for s in p.samples[a:b] do lo, hi = min(lo, s), max(hi, s)
		return lo, hi, true
	}
	// The level: blocks of at most half the span (so a pixel reads 2 or 3).
	k := clamp(int(math.log2(span / PEAK_BASE)) - 1, 0, len(p.levels) - 1)
	block := PEAK_BASE << uint(k)
	l := p.levels[k]
	i0 := clamp(a / block, 0, len(l) - 1)
	i1 := clamp((b - 1) / block, i0, len(l) - 1)
	lo, hi = l[i0].lo, l[i0].hi
	for pk in l[i0:i1 + 1] do lo, hi = min(lo, pk.lo), max(hi, pk.hi)
	return lo, hi, true
}
