package test_app_ui

import "core:math"
import "core:math/rand"
import "core:testing"

import "app:ui"

// A waveform's pyramid: for any span, at any zoom, the lowest and highest
// sample in it (as a scan of the samples finds), from a level whose
// blocks fit the span; and as fast as a pixel's worth of reads.
@(test)
peak_pyramid_finds_each_spans_extremes :: proc(t: ^testing.T) {
	n := 200_003
	x := make([]f32, n, context.temp_allocator)
	for &v, i in x do v = f32(math.sin(f64(i) * 0.01)) * 0.5 + rand.float32_range(-0.1, 0.1)
	x[123_457] = 0.99 // (a spike to find)
	p := ui.peak_pyramid_make(x)
	defer ui.peak_pyramid_destroy(&p)
	testing.expect(t, len(p.levels) > 10 && len(p.levels[len(p.levels) - 1]) == 1, "levels down to one peak")
	for span in ([]f64{3, 15, 40, 300, 5_000, 90_000}) {
		for _ in 0 ..< 40 {
			f0 := f64(rand.int_max(n - int(span) - 1))
			f1 := f0 + span
			lo, hi, ok := ui.peak_range(&p, f0, f1)
			// The span read whole by the blocks the level holds: within them,
			// and never short of the true extremes.
			wlo, whi := x[int(f0)], x[int(f0)]
			for v in x[int(f0):int(math.ceil(f1))] do wlo, whi = min(wlo, v), max(whi, v)
			testing.expectf(t, ok && lo <= wlo && hi >= whi, "span %v at %v: %v..%v covers %v..%v", span, f0, lo, hi, wlo, whi)
			if span < 2 * ui.PEAK_BASE do testing.expectf(t, lo == wlo && hi == whi, "span %v: exact (the samples)", span)
		}
	}
	lo, hi, _ := ui.peak_range(&p, 123_000, 124_000)
	testing.expectf(t, hi == 0.99 && lo < 0, "the spike found (%v)", hi)
}
