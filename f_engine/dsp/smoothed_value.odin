package dsp

import "core:math"

import "fire:core"

// Per-sample parameter smoother. Nodes own one per smoothed parameter.
// Advancing is per sample, so the result never depends on block boundaries.
Smoothed_Value :: struct {
	current:   f64,                  // value at the last `smoothed_next`
	target:    f64,                  // value being approached
	mode:      core.Param_Smoothing,
	// Linear
	step:      f64,
	remaining: int,
	ramp_len:  int,
	// One-pole
	coeff:     f64,
	// A `smoothed_ramp` in progress (any mode)
	ramp_step: f64,
	ramp_left: int,
}

// Control thread (prepare). `time_ms` is the linear ramp length or the one-pole time constant.
smoothed_init :: proc(s: ^Smoothed_Value, value: f64, mode: core.Param_Smoothing, time_ms, sample_rate: f64) {
	s^ = {current = value, target = value, mode = mode}
	samples := time_ms * 0.001 * sample_rate
	s.ramp_len = max(int(samples + 0.5), 1)
	s.coeff = samples > 0 ? 1 - math.exp(-1 / samples) : 1
}

// Control thread (prepare). `smoothed_init` with the parameter's default value,
// smoothing mode and smoothing time.
smoothed_init_from_param :: proc(s: ^Smoothed_Value, p: core.Param_Info, sample_rate: f64) {
	smoothed_init(s, p.default, p.smoothing, p.smoothing_ms, sample_rate)
}

// [rt] Starts moving toward `target`. With `.None` smoothing the value jumps;
// with `.Linear` a new ramp of the full length starts from the current value.
smoothed_set_target :: proc "contextless" (s: ^Smoothed_Value, target: f64) {
	s.target = target
	s.ramp_left = 0
	switch s.mode {
	case .None:
		s.current = target
	case .Linear:
		s.remaining = s.ramp_len
		s.step = (target - s.current) / f64(s.ramp_len)
	case .One_Pole:
	}
}

// [rt] Moves in a straight line from the current value to `target`,
// whatever the smoothing mode, as `core.Param_Ramp` asks: the next
// `smoothed_next` still returns the current value, and the one `frames`
// calls later returns `target` (for 0, the next one already does).
smoothed_ramp :: proc "contextless" (s: ^Smoothed_Value, target: f64, frames: int) {
	s.target, s.remaining = target, 0
	if frames <= 0 {
		s.current, s.ramp_left = target, 0
		return
	}
	s.ramp_left = frames
	s.ramp_step = (target - s.current) / f64(frames)
}

// [rt] Applies a parameter change read by `core.param_event`: a ramp when
// `ramp_frames` ≥ 0, otherwise the parameter's own smoothing.
smoothed_apply :: proc "contextless" (s: ^Smoothed_Value, value: f64, ramp_frames: int) {
	if ramp_frames >= 0 {
		smoothed_ramp(s, value, ramp_frames)
	} else {
		smoothed_set_target(s, value)
	}
}

// [rt] Jump to `value` with no ramp.
smoothed_reset :: proc "contextless" (s: ^Smoothed_Value, value: f64) {
	s.current, s.target, s.remaining, s.ramp_left = value, value, 0, 0
}

// [rt] Reports whether the value has not yet reached its target.
smoothed_is_smoothing :: #force_inline proc "contextless" (s: ^Smoothed_Value) -> bool {
	return s.current != s.target
}

// [rt] Advance one sample and return the new value.
smoothed_next :: #force_inline proc "contextless" (s: ^Smoothed_Value) -> f64 {
	if s.ramp_left > 0 { // a ramp's first frame keeps the value it starts from
		v := s.current
		s.ramp_left -= 1
		s.current = s.target if s.ramp_left == 0 else s.current + s.ramp_step
		return v
	}
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
