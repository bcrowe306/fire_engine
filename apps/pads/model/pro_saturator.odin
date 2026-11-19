package pads_model

import "core:math"

import "fire:dsp"
import "fire:fx"

// ProSaturator in a slot: the harmonics it adds, read from its taps.

// Harmonics ProSaturator's display and the API show.
PS_HARMONICS :: 8

// Frames analysed for ProSaturator's harmonics.
@(private = "file")
PS_HARMONICS_FFT :: 2048

// Control thread. The harmonics of the loudest partial ProSaturator `ps`
// took in, as its input had them (`in_db`) and as its output has them
// (`out_db`), each in dB against that side's own fundamental (the first
// 0 dB); false while nothing has been heard. Allocates in the temp
// allocator.
pro_saturator_harmonics :: proc(ps: ^fx.Pro_Saturator, sample_rate: f64) -> (in_db, out_db: [PS_HARMONICS]f32, ok: bool) {
	N :: PS_HARMONICS_FFT
	x := make([]f32, N, context.temp_allocator)
	y := make([]f32, N, context.temp_allocator)
	fx.pro_saturator_read_taps(ps, x, y)
	fft: dsp.Real_Fft
	if dsp.real_fft_init(&fft, N, allocator = context.temp_allocator) != .None do return
	spectrum :: proc(fft: ^dsp.Real_Fft, s: []f32) -> []f32 {
		w := make([]f32, len(s), context.temp_allocator)
		for v, i in s do w[i] = v * (0.5 - 0.5 * math.cos(math.TAU * f32(i) / f32(len(s) - 1)))
		c := make([]complex64, len(s) / 2, context.temp_allocator)
		dsp.real_fft_forward(fft, w, c)
		m := make([]f32, len(c), context.temp_allocator)
		for v, k in c do m[k] = abs(v)
		return m
	}
	xi, yo := spectrum(&fft, x), spectrum(&fft, y)
	// The fundamental: the input's loudest bin above 20 Hz.
	lo := max(int(20 * N / sample_rate), 2)
	f0 := lo
	for k in lo ..< len(xi) do if xi[k] > xi[f0] do f0 = k
	if xi[f0] < 1e-4 do return
	peak :: proc(m: []f32, k: int) -> f32 {
		if k + 1 >= len(m) do return 0
		return max(m[k - 1], m[k], m[k + 1])
	}
	ref_in, ref_out := peak(xi, f0), max(peak(yo, f0), 1e-9)
	for h in 0 ..< PS_HARMONICS {
		k := f0 * (h + 1)
		in_db[h] = f32(20 * math.log10(max(f64(peak(xi, k) / ref_in), 1e-6)))
		out_db[h] = f32(20 * math.log10(max(f64(peak(yo, k) / ref_out), 1e-6)))
	}
	return in_db, out_db, true
}
