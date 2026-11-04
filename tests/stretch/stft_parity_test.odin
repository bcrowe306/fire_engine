package test_stretch

import "core:log"
import "core:math"
import "core:testing"

import "fire:dsp"
import ss "fire:sys/signalsmith"
import kit "fire:testkit"

// The same loop as fss_test_stft (wrapper.cpp), through fire:dsp's STFT.
odin_stft :: proc(block, interval, extra: int, kind: dsp.Stft_Spectrum, hops: []i32, input: []f32) -> []f32 {
	s: dsp.Stft
	dsp.stft_init(&s, {in_channels = 1, out_channels = 1, block = block, extra_history = extra, spectrum = kind})
	defer dsp.stft_destroy(&s)
	dsp.stft_set_interval(&s, interval, .Kaiser)
	dsp.stft_reset(&s)
	out := make([]f32, len(input), context.temp_allocator)
	at, k := 0, 0
	for {
		h := int(hops[k % len(hops)])
		k += 1
		if at + h > len(input) do break
		dsp.stft_write_input(&s, 0, 0, input[at:at + h])
		dsp.stft_move_input(&s, h)
		dsp.stft_analyse(&s)
		spec := dsp.stft_spectrum(&s, 0)
		for &v, b in spec {
			phase := f32(0.01) * f32(b)
			v *= complex(math.cos(phase), math.sin(phase)) / complex(1 + 0.002 * f32(b), 0)
		}
		dsp.stft_synthesise(&s)
		dsp.stft_read_output(&s, 0, 0, out[at:at + h])
		dsp.stft_move_output(&s, h)
		at += h
	}
	return out
}

// fire:dsp's STFT matches Signalsmith Linear's DynamicSTFT, sample for
// sample, with spectral changes and irregular hops, in every layout.
@(test)
stft_matches_linear :: proc(t: ^testing.T) {
	x := make([]f32, 48_000 * 2, context.temp_allocator)
	kit.white_noise(x, 21, 0.5)
	cases := []struct {
		block, interval, extra: int,
		hops:                   []i32,
	}{
		{5760, 1440, 1441, {1440}},          // Stretch's default at 48 kHz
		{5760, 1440, 1441, {1000, 1800}},    // irregular hops
		{4800, 1920, 1921, {1920, 7, 1500}}, // Stretch's cheaper preset, odd hops
		{64, 16, 0, {16, 3}},
	}
	for c in cases {
		for kind in dsp.Stft_Spectrum {
			want := make([]f32, len(x), context.temp_allocator)
			ss.test_stft(i32(c.block), i32(c.interval), i32(c.extra), i32(kind), raw_data(c.hops), i32(len(c.hops)), raw_data(x), i32(len(x)), raw_data(want))
			got := odin_stft(c.block, c.interval, c.extra, kind, c.hops, x)
			cmp := kit.compare_slices(want, got)
			db := kit.linear_to_db(cmp.max_abs_error / max(kit.peak(want), 1e-12))
			log.infof("block %d hops %v %v: %.1f dB from Linear (peak %.3f)", c.block, c.hops, kind, db, kit.peak(want))
			testing.expectf(t, db < -110, "block %d hops %v %v: differs from Linear by %.1f dB at %d", c.block, c.hops, kind, db, cmp.max_error_at)
		}
	}
}
