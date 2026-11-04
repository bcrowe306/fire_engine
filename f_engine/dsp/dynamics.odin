package dsp

import "core:math"

// How a dynamics processor measures level.
Detector :: enum u8 {
	Peak, // the largest sample of any detected channel
	Rms,  // mean square over `rms_ms`
}

// [rt] The static curve of a downward compressor: the gain reduction in dB
// (≥ 0) for a level of `level_db`, with a soft knee `knee_db` wide centred
// on the threshold (Giannoulis, Massberg and Reiss, "Digital Dynamic Range
// Compressor Design — A Tutorial and Analysis", JAES 2012, eq. 4).
compressor_curve :: proc "contextless" (level_db, threshold_db, ratio, knee_db: f64) -> f64 {
	over := level_db - threshold_db
	slope := 1 - 1 / max(ratio, 1)
	if knee_db > 0 && 2 * abs(over) <= knee_db {
		x := over + knee_db / 2
		return slope * x * x / (2 * knee_db)
	}
	return slope * over if over > 0 else 0
}

// [rt] The static curve of a downward expander (a gate at infinite ratio):
// the gain reduction in dB (≥ 0, at most `range_db`) for a level of
// `level_db`, with the same soft knee as `compressor_curve`.
expander_curve :: proc "contextless" (level_db, threshold_db, ratio, knee_db, range_db: f64) -> f64 {
	under := threshold_db - level_db
	slope := max(ratio, 1) - 1 // dB of reduction per dB under the threshold
	r: f64
	if knee_db > 0 && 2 * abs(under) <= knee_db {
		x := under + knee_db / 2
		r = slope * x * x / (2 * knee_db)
	} else if under > 0 {
		r = slope * under
	}
	return min(r, range_db)
}

// [rt] The per-sample coefficient of a one-pole smoother that covers
// 1 − 1/e (63%) of a step in `time_ms`.
time_coeff :: proc "contextless" (time_ms, sample_rate: f64) -> f64 {
	n := time_ms * 0.001 * sample_rate
	return math.exp(-1 / n) if n > 0 else 0
}

// The state of a compressor or expander's gain smoothing: the gain
// reduction in dB moving towards its target with separate attack and
// release (the "smooth branching" detector of Giannoulis et al., in the
// log domain).
Gain_Smoother :: struct {
	reduction_db: f64,
	attack:       f64, // from `time_coeff`
	release:      f64,
}

// [rt] Moves towards a gain reduction of `target_db`: attacking when it
// must reduce more, releasing when less. Returns the new reduction in dB.
gain_smoother_next :: #force_inline proc "contextless" (s: ^Gain_Smoother, target_db: f64) -> f64 {
	a := s.attack if target_db > s.reduction_db else s.release
	s.reduction_db = a * s.reduction_db + (1 - a) * target_db
	return s.reduction_db
}

// A level detector across channels: the peak, or the mean square over a
// window (as a one-pole of `rms_ms`).
Level_Detector :: struct {
	mode:  Detector,
	coeff: f64, // Rms: from `time_coeff`
	power: f64, // Rms: mean square so far
}

// [rt] The detector's level in dB for one frame, from the samples of every
// detected channel at that frame.
level_detector_next :: #force_inline proc "contextless" (d: ^Level_Detector, frame: []f64) -> f64 {
	switch d.mode {
	case .Peak:
		m := 0.0
		for x in frame do m = max(m, abs(x))
		return 20 * math.log10(max(m, 1e-10))
	case .Rms:
		p := 0.0
		for x in frame do p = max(p, x * x)
		d.power = d.coeff * d.power + (1 - d.coeff) * p
		return 10 * math.log10(max(d.power, 1e-20))
	}
	return -200
}
