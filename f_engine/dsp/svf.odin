package dsp

import "core:math"

// What a filter does. Cutoff is where a lowpass or highpass is −3 dB (at
// Q = 0.707), the centre of a bandpass, notch, peak or bell, and the
// midpoint (half the gain) of a shelf.
Filter_Mode :: enum u8 {
	Lowpass,
	Highpass,
	Bandpass,   // 0 dB at the cutoff
	Notch,
	Peak,       // a resonance: lowpass minus highpass
	Allpass,    // flat; phase only
	Bell,       // boost or cut by `gain_db` around the cutoff
	Low_Shelf,  // `gain_db` below the cutoff
	High_Shelf, // `gain_db` above the cutoff
}

// Coefficients of a state-variable filter, from `svf_design`. Any number of
// `Svf_State`s (one per channel) can share them.
Svf_Coeffs :: struct {
	g, k:       f64, // prewarped cutoff, damping
	a1, a2, a3: f64,
	m0, m1, m2: f64, // the mode's mix of input, band and low outputs
}

// One channel's state of a state-variable filter.
Svf_State :: struct {
	ic1, ic2: f64,
}

// [rt] Designs a state-variable filter: Andrew Simper's linear trapezoidal
// SVF ("Solving the continuous SVF equations using trapezoidal integration
// and equivalent currents", Cytomic, 2013). Its response is the analog
// prototype's, bilinear-transformed with the cutoff prewarped, and it stays
// stable and smooth when its coefficients change every sample, so it suits
// modulated filters. `q` > 0 (0.707 is flat); `gain_db` is for Bell and the
// shelves. The cutoff is kept below 0.49 × `sample_rate`.
svf_design :: proc "contextless" (mode: Filter_Mode, cutoff_hz, q, gain_db, sample_rate: f64) -> (c: Svf_Coeffs) {
	fc := clamp(cutoff_hz, 1, sample_rate * 0.49)
	g := math.tan(math.PI * fc / sample_rate)
	k := 1 / max(q, 1e-3)
	a := math.pow(10, gain_db / 40) // amplitude at the shelf or peak is a²
	switch mode {
	case .Lowpass:    c.m0, c.m1, c.m2 = 0, 0, 1
	case .Highpass:   c.m0, c.m1, c.m2 = 1, -k, -1
	case .Bandpass:   c.m0, c.m1, c.m2 = 0, k, 0
	case .Notch:      c.m0, c.m1, c.m2 = 1, -k, 0
	case .Peak:       c.m0, c.m1, c.m2 = 1, -k, -2
	case .Allpass:    c.m0, c.m1, c.m2 = 1, -2 * k, 0
	case .Bell:
		k = 1 / (max(q, 1e-3) * a)
		c.m0, c.m1, c.m2 = 1, k * (a * a - 1), 0
	case .Low_Shelf:
		g /= math.sqrt(a)
		c.m0, c.m1, c.m2 = 1, k * (a - 1), a * a - 1
	case .High_Shelf:
		g *= math.sqrt(a)
		c.m0, c.m1, c.m2 = a * a, k * (1 - a) * a, 1 - a * a
	}
	c.g, c.k = g, k
	c.a1 = 1 / (1 + g * (g + k))
	c.a2 = g * c.a1
	c.a3 = g * c.a2
	return
}

// [rt] Filters one sample.
svf_tick :: #force_inline proc "contextless" (c: ^Svf_Coeffs, s: ^Svf_State, x: f64) -> f64 {
	v3 := x - s.ic2
	v1 := c.a1 * s.ic1 + c.a2 * v3
	v2 := s.ic2 + c.a2 * s.ic1 + c.a3 * v3
	s.ic1 = 2 * v1 - s.ic1
	s.ic2 = 2 * v2 - s.ic2
	return c.m0 * x + c.m1 * v1 + c.m2 * v2
}

// [rt] Filters `buf` in place with one channel's state.
svf_process :: proc "contextless" (c: ^Svf_Coeffs, s: ^Svf_State, buf: []f32) #no_bounds_check {
	// Locals: through the pointers the compiler can't rule out aliasing with
	// `buf`, and stores and reloads the state every sample (1.7× slower).
	k, st := c^, s^
	for &x in buf do x = f32(svf_tick(&k, &st, f64(x)))
	s^ = st
}

// [rt] The filter's exact response at `freq_hz`: gain (linear) and phase in
// radians. For drawing EQ curves.
svf_response :: proc "contextless" (c: ^Svf_Coeffs, freq_hz, sample_rate: f64) -> (gain, phase: f64) {
	// The prototype at s = j·tan(π f / fs) / g: band = s/D, low = 1/D,
	// D = s² + k s + 1.
	w := math.tan(math.PI * clamp(freq_hz, 0, sample_rate * 0.4999) / sample_rate) / c.g
	s := complex(0, w)
	d := s * s + complex(c.k, 0) * s + 1
	h := complex(c.m0, 0) + complex(c.m1, 0) * s / d + complex(c.m2, 0) / d
	return abs(h), math.atan2(imag(h), real(h))
}
