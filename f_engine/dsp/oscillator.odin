package dsp

import "core:math"

// The waveform of an `Oscillator`.
Osc_Shape :: enum u8 {
	Sine,
	Saw,      // falling ramps' opposite: rises, then drops
	Square,
	Triangle,
	Pulse,    // a square with `pulse_width`
}

// A band-limited oscillator, −1..1. Saw, square and pulse use polyBLEP
// (Välimäki and Huovilainen, "Antialiasing Oscillators in Subtractive
// Synthesis", IEEE Signal Processing Magazine 2007): each jump is smoothed
// by a two-sample polynomial step, which removes most of the aliasing a
// naive waveform has. The triangle is that square, integrated.
Oscillator :: struct {
	shape:       Osc_Shape,
	phase:       f64, // 0..1
	step:        f64, // cycles per frame
	pulse_width: f64, // Pulse: the high part of the cycle, 0.01..0.99
	integrated:  f64, // Triangle: the integrator
}

// [rt] Sets the frequency in Hz (up to just below Nyquist).
osc_set_freq :: #force_inline proc "contextless" (o: ^Oscillator, hz, sample_rate: f64) {
	o.step = clamp(hz / sample_rate, 0, 0.49)
}

// [rt] The two-sample polyBLEP correction at phase `t` for a jump at phase
// 0, with `dt` cycles per frame: subtract it (times the jump's size / 2)
// from the naive waveform.
poly_blep :: #force_inline proc "contextless" (t, dt: f64) -> f64 {
	if t < dt {
		x := t / dt
		return x + x - x * x - 1
	}
	if t > 1 - dt {
		x := (t - 1) / dt
		return x * x + x + x + 1
	}
	return 0
}

// [rt] The value now, then advances one frame.
osc_next :: proc "contextless" (o: ^Oscillator) -> f64 {
	t, dt := o.phase, o.step
	v: f64
	switch o.shape {
	case .Sine:
		v = math.sin(math.TAU * t)
	case .Saw:
		v = 2 * t - 1 - poly_blep(t, dt)
	case .Square, .Pulse, .Triangle:
		pw := clamp(o.pulse_width, 0.01, 0.99) if o.shape == .Pulse else 0.5
		v = 1 if t < pw else -1
		v += poly_blep(t, dt)
		u := t - pw
		if u < 0 do u += 1
		v -= poly_blep(u, dt)
		if o.shape == .Triangle {
			// A leaky integral of the square is a triangle; scaled by 4·dt it
			// spans −1..1, and the leak keeps its DC from wandering.
			o.integrated = dt * v * 4 + (1 - 0.1 * dt) * o.integrated
			v = o.integrated
		}
	}
	o.phase += dt
	if o.phase >= 1 do o.phase -= 1
	return v
}

// White and pink noise, −1..1 (pink: Paul Kellet's filtered white noise,
// within 0.05 dB of −3 dB per octave above 10 Hz at 44.1 kHz).
Noise :: struct {
	seed: u32,
	b:    [7]f64, // pink filter states
}

// [rt] White noise, uniform in −1..1.
noise_white :: #force_inline proc "contextless" (n: ^Noise) -> f64 {
	n.seed = n.seed * 1664525 + 1013904223
	return f64(n.seed >> 8) / f64(1 << 23) - 1
}

// [rt] Pink noise, about −1..1.
noise_pink :: proc "contextless" (n: ^Noise) -> f64 {
	w := noise_white(n)
	b := &n.b
	b[0] = 0.99886 * b[0] + w * 0.0555179
	b[1] = 0.99332 * b[1] + w * 0.0750759
	b[2] = 0.96900 * b[2] + w * 0.1538520
	b[3] = 0.86650 * b[3] + w * 0.3104856
	b[4] = 0.55000 * b[4] + w * 0.5329522
	b[5] = -0.7616 * b[5] - w * 0.0168980
	pink := b[0] + b[1] + b[2] + b[3] + b[4] + b[5] + b[6] + w * 0.5362
	b[6] = w * 0.115926
	return pink * 0.11
}

// Where an `Adsr` envelope is.
Adsr_Stage :: enum u8 {
	Idle,
	Attack,
	Decay,
	Sustain,
	Release,
}

// An ADSR envelope, 0..1: a linear attack to 1 in `attack_s`, then
// exponential moves to `sustain` and, on release, to silence, each
// covering all but 60 dB of the way in its time (as analog envelopes
// sound, with a definite length).
Adsr :: struct {
	attack_s, decay_s, sustain, release_s: f64,
	stage:                                 Adsr_Stage,
	level:                                 f64,
	attack_step:                           f64, // per frame
	decay_coeff, release_coeff:            f64,
}

// [rt] Sets the times (seconds) and sustain level (0..1).
adsr_set :: proc "contextless" (a: ^Adsr, attack_s, decay_s, sustain, release_s, sample_rate: f64) {
	a.attack_s, a.decay_s, a.sustain, a.release_s = max(attack_s, 0), max(decay_s, 0), clamp(sustain, 0, 1), max(release_s, 0)
	a.attack_step = 1 / max(a.attack_s * sample_rate, 1)
	// The fraction of the gap left after each frame: 60 dB (×0.001) in the time.
	coeff :: proc "contextless" (s, sr: f64) -> f64 { return math.pow(0.001, 1 / max(s * sr, 1)) }
	a.decay_coeff = coeff(a.decay_s, sample_rate)
	a.release_coeff = coeff(a.release_s, sample_rate)
}

// [rt] Starts (gate on: from the current level, without a click) or
// releases (gate off) the envelope.
adsr_gate :: proc "contextless" (a: ^Adsr, on: bool) {
	if on {
		a.stage = .Attack
	} else if a.stage != .Idle {
		a.stage = .Release
	}
}

// [rt] The level now, then advances one frame.
adsr_next :: proc "contextless" (a: ^Adsr) -> f64 {
	v := a.level
	switch a.stage {
	case .Idle:
	case .Attack:
		a.level += a.attack_step
		if a.level >= 1 {
			a.level = 1
			a.stage = .Decay
		}
	case .Decay:
		a.level = a.sustain + (a.level - a.sustain) * a.decay_coeff
		if abs(a.level - a.sustain) < 1e-5 {
			a.level = a.sustain
			a.stage = .Sustain
		}
	case .Sustain:
		a.level = a.sustain
	case .Release:
		a.level *= a.release_coeff
		if a.level < 1e-5 {
			a.level = 0
			a.stage = .Idle
		}
	}
	return v
}
