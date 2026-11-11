package synth

import "core:math"

// Spectral morphs: a frame's harmonics changed before they become a wave
// (`wave_build`), so whatever they do stays free of aliasing. Each takes
// an amount, 0..1; those that go two ways (formant scale, the stretches,
// skew) do nothing at 0.5, the rest nothing at 0.

// How an oscillator morphs its frame's spectrum.
Spectral_Morph :: enum u8 {
	None,
	Vocode,             // the frame's spectral envelope over every harmonic: a buzz through its formants
	Formant_Scale,      // the spectrum's shape drawn in (down) or out (up), the harmonics where they are
	Harmonic_Stretch,   // harmonic k moved to k^p: a bell or a squash, still harmonic
	Inharmonic_Stretch, // partials spread as a stiff string's are (wider apart going up), or squeezed
	Smear,              // each harmonic's level carried up into the ones above it
	Random_Amplitudes,  // each harmonic's level scattered (the same scatter each time)
	Low_Pass,           // harmonics above a cutoff gone (the cutoff falls as the amount rises)
	High_Pass,          // harmonics below a cutoff gone
	Phase_Disperse,     // each harmonic's phase turned by the square of its number: a chirp
	Shepard_Tone,       // crossfaded to itself an octave up (1: the octave)
	Skew,               // each harmonic read from a frame further along the table (or back), the higher the further
}

// [rt] Writes into `out` (`WAVE_BINS`) the spectrum of frame `frame` of
// `t`, harmonics 1 ..= `h` morphed by `morph` at `amount` (and DC kept,
// the rest zero).
spectral_build :: proc "contextless" (t: ^Wavetable, frame: int, h: int, morph: Spectral_Morph, amount: f32, out: []complex64) #no_bounds_check {
	src := &t.spectra[frame]
	for k in 0 ..< WAVE_BINS do out[k] = 0
	out[0] = complex(real(src[0]), 0) // DC kept, Nyquist dropped
	a := clamp(amount, 0, 1)
	top := WAVE_BINS - 1
	switch morph {
	case .None:
		for k in 1 ..= h do out[k] = src[k]
	case .Vocode:
		// The envelope: magnitudes averaged over a band that widens with
		// the amount; every harmonic toward it.
		sums: [WAVE_BINS + 1]f32
		for k in 1 ..< WAVE_BINS do sums[k + 1] = sums[k] + abs(src[k])
		half := 1 + int(a * 24)
		for k in 1 ..= h {
			lo, hi := max(k - half, 1), min(k + half, top)
			env := (sums[hi + 1] - sums[lo]) / f32(hi - lo + 1)
			out[k] = with_magnitude(src[k], abs(src[k]) + (env - abs(src[k])) * a)
		}
	case .Formant_Scale:
		scale := math.pow(f32(2), (a - 0.5) * 4) // ¼ .. 4
		for k in 1 ..= h {
			x := f32(k) / scale
			if x < 1 || x > f32(top) do continue
			i := int(x)
			f := x - f32(i)
			m := abs(src[i]) + (abs(src[min(i + 1, top)]) - abs(src[i])) * f
			out[k] = with_magnitude(src[clamp(int(x + 0.5), 1, top)], m)
		}
	case .Harmonic_Stretch:
		p := math.pow(f32(2), (a - 0.5) * 1.2) // k^0.66 .. k^1.5
		for k in 1 ..< WAVE_BINS {
			j := int(math.round(math.pow(f32(k), p)))
			if j > h do break
			if j >= 1 do out[j] += src[k]
		}
	case .Inharmonic_Stretch:
		b := (a - 0.5) * 2 * 0.002 // a string's stiffness: f_k = k √(1 + b k²)
		for k in 1 ..< WAVE_BINS {
			j := int(math.round(f32(k) * math.sqrt(max(1 + b * f32(k * k), 0.01))))
			if j > h do break
			if j >= 1 do out[j] += src[k]
		}
	case .Smear:
		acc: f32 = 0
		keep := a * 0.985
		for k in 1 ..= h {
			acc = max(abs(src[k]), acc * keep)
			out[k] = with_magnitude(src[k], abs(src[k]) + (acc - abs(src[k])) * a)
		}
	case .Random_Amplitudes:
		for k in 1 ..= h {
			x := u32(k) * 2654435761
			x ~= x >> 15
			x *= 2246822519
			x ~= x >> 13
			r := f32(x >> 8) / 16_777_216 // 0..1, the same for harmonic k each time
			out[k] = src[k] * complex(1 - a + a * r * 2, 0)
		}
	case .Low_Pass:
		cut := math.pow(f32(WAVE_BINS), 1 - a)
		for k in 1 ..= h do out[k] = src[k] * complex(clamp(cut - f32(k) + 1, 0, 1), 0)
	case .High_Pass:
		cut := math.pow(f32(WAVE_BINS), a) - 1
		for k in 1 ..= h do out[k] = src[k] * complex(clamp(f32(k) - cut, 0, 1), 0)
	case .Phase_Disperse:
		for k in 1 ..= h {
			rot := a * f32(k * k) * math.PI / 64
			out[k] = src[k] * complex(math.cos(rot), math.sin(rot))
		}
	case .Shepard_Tone:
		for k in 1 ..= h {
			out[k] += src[k] * complex(1 - a, 0)
			if 2 * k <= h do out[2 * k] += src[k] * complex(a, 0)
		}
	case .Skew:
		span := (a - 0.5) * 2 * f32(t.frames - 1)
		for k in 1 ..= h {
			f := clamp(frame + int(math.round(span * f32(k) / f32(max(h, 1)))), 0, t.frames - 1)
			out[k] = t.spectra[f][k]
		}
	}
}

// [rt] `c` with magnitude `m` (its phase kept; a sine's, if it had none).
@(private)
with_magnitude :: #force_inline proc "contextless" (c: complex64, m: f32) -> complex64 {
	n := abs(c)
	if n > 1e-12 do return c * complex(m / n, 0)
	return complex(0, -m)
}
