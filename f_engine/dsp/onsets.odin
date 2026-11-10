package dsp

import "core:math"
import "core:slice"

import "fire:core"

// Settings for `detect_onsets`.
Onset_Settings :: struct {
	sensitivity: f64, // 0..1: higher finds quieter hits; 0 = 0.5
	min_gap_ms:  f64, // closest two onsets may be; 0 = 60 ms
	window:      int, // FFT size in frames (a power of two); 0 = 1024
}

// Control thread. Finds where new sounds start in `samples` (mono; mix
// stereo down first): the hits of a drum loop, the notes of a phrase, for
// slicing a sample at its transients. Returns frame positions, in order,
// allocated with `allocator`; the first is always 0 unless the sound is
// silent there.
//
// Spectral flux: the summed rise in log magnitude across the spectrum from
// one hop to the next, which a hit makes at once and a sustained sound does
// not. Peaks above a running median (how far above: the sensitivity) are
// onsets, each placed where its attack begins in the waveform (just before
// it), so a slice starts before its attack.
detect_onsets :: proc(samples: []f32, sample_rate: f64, settings := Onset_Settings{}, allocator := context.allocator) -> (onsets: []i64, err: core.Error) {
	sens := settings.sensitivity if settings.sensitivity > 0 else 0.5
	gap_ms := settings.min_gap_ms if settings.min_gap_ms > 0 else 60
	size := settings.window if settings.window > 0 else 1024
	hop := size / 4
	frames := (len(samples) - size) / hop + 1
	out := make([dynamic]i64, allocator)
	if len(samples) < size || frames < 3 {
		if len(samples) > 0 && rms(samples) > 1e-4 do append(&out, 0)
		return out[:], .None
	}

	f: Fft
	fft_init(&f, size, context.temp_allocator) or_return
	buf := make([]complex64, size, context.temp_allocator)
	spec := make([]complex64, size, context.temp_allocator)
	prev := make([]f32, size / 2, context.temp_allocator)
	flux := make([]f64, frames, context.temp_allocator)
	for k in 0 ..< frames {
		at := k * hop
		for i in 0 ..< size {
			w := 0.5 - 0.5 * math.cos(math.TAU * f64(i) / f64(size)) // Hann
			buf[i] = complex(f32(w) * samples[at + i], 0)
		}
		fft_forward(&f, buf, spec)
		sum: f64 = 0
		for b in 1 ..< size / 2 {
			m := math.log10(1 + 10 * f32(abs(spec[b]))) // gently compressed magnitude
			d := m - prev[b]
			if d > 0 do sum += f64(d)
			prev[b] = m
		}
		flux[k] = sum // the first hop's is the sound's own start: it sets the scale
	}

	// Peaks of the flux above a running median of a quarter second.
	half := max(int(0.125 * sample_rate) / hop, 2)
	window := make([]f64, 2 * half + 1, context.temp_allocator)
	peak_flux := slice.max(flux)
	if peak_flux <= 0 do return out[:], .None
	threshold_k := 1 + 2 * (1 - sens) // how far above the median, in multiples of it
	floor := peak_flux * (0.02 + 0.5 * (1 - sens) * (1 - sens)) // and above a share of the loudest hit
	min_gap := max(int(gap_ms * 0.001 * sample_rate) / hop, 1)
	last := -min_gap
	for k in 1 ..< frames - 1 {
		if flux[k] < flux[k - 1] || flux[k] < flux[k + 1] do continue // not a peak
		lo, hi := max(k - half, 0), min(k + half, frames - 1)
		n := hi - lo + 1
		copy(window[:n], flux[lo:hi + 1])
		slice.sort(window[:n])
		median := window[n / 2]
		if flux[k] <= median * threshold_k + floor || k - last < min_gap do continue
		last = k
		append(&out, attack_at(samples, k * hop - hop, k * hop + size))
	}
	// A sound that starts at once counts its start as an onset.
	if len(out) == 0 || out[0] > i64(min_gap * hop) {
		if rms(samples[:min(len(samples), size)]) > 1e-4 do inject_at(&out, 0, 0)
	}
	for &o in out do o = clamp(o, 0, i64(len(samples) - 1))
	return out[:], .None
}

// The attack within samples[from:to]: the 64-frame block whose level rises
// most over the one before (a hit stands out from what is still ringing),
// less a block, so a slice starts just before it.
@(private)
attack_at :: proc(samples: []f32, from, to: int) -> i64 {
	BLOCK :: 64
	a, b := max(from, 0), min(to, len(samples))
	best, best_rise := a, f32(-1)
	prev: f32 = 0
	for i := a; i + BLOCK <= b; i += BLOCK {
		m: f32 = 0
		for x in samples[i:i + BLOCK] do m = max(m, abs(x))
		if i > a && m - prev > best_rise do best, best_rise = i, m - prev
		prev = m
	}
	return i64(max(best - BLOCK, 0))
}

@(private)
rms :: proc(x: []f32) -> f64 {
	s: f64 = 0
	for v in x do s += f64(v) * f64(v)
	return math.sqrt(s / f64(max(len(x), 1)))
}
