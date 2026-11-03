package dsp

import "core:math"

import "fire:core"

// Per-sample parameter smoother. Nodes own one per smoothed parameter.
// Advancing is per sample, so the result never depends on block boundaries.
Smoothed_Value :: struct {
	current:   f64,
	target:    f64,
	mode:      core.Param_Smoothing,
	// Linear
	step:      f64,
	remaining: int,
	ramp_len:  int,
	// One-pole
	coeff:     f64,
}

// Control thread (prepare). `time_ms` is the linear ramp length or the one-pole time constant.
smoothed_init :: proc(s: ^Smoothed_Value, value: f64, mode: core.Param_Smoothing, time_ms, sample_rate: f64) {
	s^ = {current = value, target = value, mode = mode}
	samples := time_ms * 0.001 * sample_rate
	s.ramp_len = max(int(samples + 0.5), 1)
	s.coeff = samples > 0 ? 1 - math.exp(-1 / samples) : 1
}

smoothed_init_from_param :: proc(s: ^Smoothed_Value, p: core.Param_Info, sample_rate: f64) {
	smoothed_init(s, p.default, p.smoothing, p.smoothing_ms, sample_rate)
}

// [rt]
smoothed_set_target :: proc "contextless" (s: ^Smoothed_Value, target: f64) {
	s.target = target
	switch s.mode {
	case .None:
		s.current = target
	case .Linear:
		s.remaining = s.ramp_len
		s.step = (target - s.current) / f64(s.ramp_len)
	case .One_Pole:
	}
}

// [rt] Jump to `value` with no ramp.
smoothed_reset :: proc "contextless" (s: ^Smoothed_Value, value: f64) {
	s.current, s.target, s.remaining = value, value, 0
}

// [rt]
smoothed_is_smoothing :: #force_inline proc "contextless" (s: ^Smoothed_Value) -> bool {
	return s.current != s.target
}

// [rt] Advance one sample and return the new value.
smoothed_next :: #force_inline proc "contextless" (s: ^Smoothed_Value) -> f64 {
	switch s.mode {
	case .None:
	case .Linear:
		if s.remaining > 0 {
			s.remaining -= 1
			s.current = s.remaining == 0 ? s.target : s.current + s.step
		}
	case .One_Pole:
		if s.current != s.target {
			s.current += (s.target - s.current) * s.coeff
			if abs(s.target - s.current) <= 1e-9 * max(abs(s.target), 1) do s.current = s.target
		}
	}
	return s.current
}
