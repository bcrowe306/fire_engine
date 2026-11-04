package dsp

import "core:math"

// Normalised biquad coefficients (a0 = 1), from `biquad_design`.
Biquad_Coeffs :: struct {
	b0, b1, b2, a1, a2: f64,
}

// One channel's state of a biquad (transposed direct form II).
Biquad_State :: struct {
	z1, z2: f64,
}

// [rt] Designs a biquad from Robert Bristow-Johnson's "Audio EQ Cookbook"
// formulas: the same responses as `svf_design` (the bilinear transform with
// the cutoff prewarped), so the two are interchangeable for fixed filters.
// Prefer the SVF for anything modulated: a biquad's coefficients jumping
// while it runs can click or, at high Q, blow up. Shelves use the
// cookbook's slope S = 1 when `q` is 0.707 (the same curve the SVF gives).
biquad_design :: proc "contextless" (mode: Filter_Mode, cutoff_hz, q, gain_db, sample_rate: f64) -> Biquad_Coeffs {
	fc := clamp(cutoff_hz, 1, sample_rate * 0.49)
	w := 2 * math.PI * fc / sample_rate
	cw, sw := math.cos(w), math.sin(w)
	alpha := sw / (2 * max(q, 1e-3))
	a := math.pow(10, gain_db / 40)
	b0, b1, b2, a0, a1, a2: f64
	switch mode {
	case .Lowpass:
		b0, b1, b2 = (1 - cw) / 2, 1 - cw, (1 - cw) / 2
		a0, a1, a2 = 1 + alpha, -2 * cw, 1 - alpha
	case .Highpass:
		b0, b1, b2 = (1 + cw) / 2, -(1 + cw), (1 + cw) / 2
		a0, a1, a2 = 1 + alpha, -2 * cw, 1 - alpha
	case .Bandpass: // 0 dB peak gain
		b0, b1, b2 = alpha, 0, -alpha
		a0, a1, a2 = 1 + alpha, -2 * cw, 1 - alpha
	case .Notch:
		b0, b1, b2 = 1, -2 * cw, 1
		a0, a1, a2 = 1 + alpha, -2 * cw, 1 - alpha
	case .Peak: // lowpass minus highpass, as the SVF's Peak
		b0, b1, b2 = -cw, 2, -cw
		a0, a1, a2 = 1 + alpha, -2 * cw, 1 - alpha
	case .Allpass:
		b0, b1, b2 = 1 - alpha, -2 * cw, 1 + alpha
		a0, a1, a2 = 1 + alpha, -2 * cw, 1 - alpha
	case .Bell:
		b0, b1, b2 = 1 + alpha * a, -2 * cw, 1 - alpha * a
		a0, a1, a2 = 1 + alpha / a, -2 * cw, 1 - alpha / a
	case .Low_Shelf:
		r := 2 * math.sqrt(a) * alpha
		b0 = a * ((a + 1) - (a - 1) * cw + r)
		b1 = 2 * a * ((a - 1) - (a + 1) * cw)
		b2 = a * ((a + 1) - (a - 1) * cw - r)
		a0 = (a + 1) + (a - 1) * cw + r
		a1 = -2 * ((a - 1) + (a + 1) * cw)
		a2 = (a + 1) + (a - 1) * cw - r
	case .High_Shelf:
		r := 2 * math.sqrt(a) * alpha
		b0 = a * ((a + 1) + (a - 1) * cw + r)
		b1 = -2 * a * ((a - 1) + (a + 1) * cw)
		b2 = a * ((a + 1) + (a - 1) * cw - r)
		a0 = (a + 1) - (a - 1) * cw + r
		a1 = 2 * ((a - 1) - (a + 1) * cw)
		a2 = (a + 1) - (a - 1) * cw - r
	}
	return {b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0}
}

// [rt] Filters one sample.
biquad_tick :: #force_inline proc "contextless" (c: ^Biquad_Coeffs, s: ^Biquad_State, x: f64) -> f64 {
	y := c.b0 * x + s.z1
	s.z1 = c.b1 * x - c.a1 * y + s.z2
	s.z2 = c.b2 * x - c.a2 * y
	return y
}

// [rt] Filters `buf` in place with one channel's state.
biquad_process :: proc "contextless" (c: ^Biquad_Coeffs, s: ^Biquad_State, buf: []f32) #no_bounds_check {
	k, st := c^, s^ // locals, as in `svf_process`
	for &x in buf do x = f32(biquad_tick(&k, &st, f64(x)))
	s^ = st
}

// [rt] The response at `freq_hz`: gain (linear) and phase in radians.
biquad_response :: proc "contextless" (c: ^Biquad_Coeffs, freq_hz, sample_rate: f64) -> (gain, phase: f64) {
	w := 2 * math.PI * freq_hz / sample_rate
	z1 := complex(math.cos(w), -math.sin(w)) // z⁻¹
	z2 := z1 * z1
	h := (complex(c.b0, 0) + complex(c.b1, 0) * z1 + complex(c.b2, 0) * z2) / (1 + complex(c.a1, 0) * z1 + complex(c.a2, 0) * z2)
	return abs(h), math.atan2(imag(h), real(h))
}
