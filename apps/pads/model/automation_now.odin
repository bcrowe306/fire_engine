package pads_model

import "core:math"

import "fire:dsp"
import "fire:sampler"
import "fire:transport"

// The value target `t`'s automation gives it now, in the target's units,
// while the sequencer plays (false: stopped, or no lane of it in what
// plays here): for the UI to show a parameter moving on its own. Read
// from the lanes where the playhead is, as the engine plays them (a pad's
// own lanes too: its volume, transpose, cutoff, resonance, EQ).
automated_value :: proc(m: ^Model, t: Auto_Target) -> (value: f32, ok: bool) {
	e := &m.engine
	if t.track == .None || e.stopped do return
	pos, playing, _ := transport.timeline_status(e.host.clock, e.timeline)
	if !playing || f64(pos) < 0 do return // (counting in: nothing moves yet)
	_, slot, rel, found := plan_locate(e.plan, f64(pos), editing_slot(m))
	if !found || slot < 0 || slot >= SLOTS do return
	s := m.project.sequences[slot]
	if len(s.points) == 0 do return
	pts, _ := lane_points_of(s, {pad = t.index if t.track == .Pad else 0, target = t})
	if len(pts) == 0 && t.track == .Pad {
		if param, own := own_lane(m, t); own do pts, _ = lane_points(s, int(t.index), param)
	}
	if len(pts) == 0 do return
	return lane_value_at(pts, rel), true
}

// A pad's own lane (from before lanes had targets) that moves what target
// `t` is, if there is one.
@(private)
own_lane :: proc(m: ^Model, t: Auto_Target) -> (Lane_Param, bool) {
	#partial switch t.device {
	case .Volume: return .Volume, true
	case .Eq:
		for k in 0 ..< 3 do if t.param == dsp.eq_band_param(k, .Gain_Db) do return Lane_Param(int(Lane_Param.Eq_Low) + k), true
	case .Sound:
		if int(t.index) >= PADS || m.project.pads[t.index].kind != .Sampler do return {}, false
		switch t.param {
		case sampler.SAMPLER_PARAM_TRANSPOSE:        return .Pitch, true
		case sampler.SAMPLER_PARAM_FILTER_CUTOFF:    return .Cutoff, true
		case sampler.SAMPLER_PARAM_FILTER_RESONANCE: return .Resonance, true
		}
	}
	return {}, false
}

// Where a lane's points put it at `beat`: lines, or curves bent as the
// engine bends them; held before the first and after the last.
@(private)
lane_value_at :: proc(pts: []Auto_Point, beat: f64) -> f32 {
	if beat <= pts[0].beat do return pts[0].value
	for k in 1 ..< len(pts) {
		a, b := pts[k - 1], pts[k]
		if beat > b.beat do continue
		span := b.beat - a.beat
		if span <= 0 do return b.value
		x := (beat - a.beat) / span
		if abs(a.curve) > 1e-6 {
			kk := 8 * f64(a.curve)
			x = (math.exp(kk * x) - 1) / (math.exp(kk) - 1)
		}
		return a.value + (b.value - a.value) * f32(x)
	}
	return pts[len(pts) - 1].value
}
