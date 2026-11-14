package pads

import pa "api"
import pm "model"

// The UI's controls through the API: a knob, a fader, a toggle sets a
// parameter by reference (`pa.param_set`), its moves one undo step named
// as the control names it (a gesture: the knob's own hooks record its
// moves as automation, so it isn't touched through the API too).

// The API's reference for automation target `t` (its range left behind).
param_ref :: proc(t: pm.Auto_Target) -> pa.Param_Ref {
	return {track = pa.Track(t.track), index = i64(t.index), device = pa.Device(t.device), slot = i64(t.slot), param = i64(t.param)}
}

// A control moved parameter `ref` to `v` (its plain units; clamped to its
// range): `changed` this frame, `ended` let go. Its moves are one step
// named `step`. False if the API wouldn't take it (it has no such
// parameter: the caller does it its own way).
control_param :: proc(a: ^App, ref: pa.Param_Ref, v: f64, step: string, changed, ended: bool) -> bool {
	if changed {
		x := v
		if info, r := pa.param_info(&a.api, ref); r == .Ok do x = clamp(v, info.min, info.max)
		pa.history_gesture_begin(&a.api)
		pa.history_name_next(&a.api, step)
		if pa.param_set(&a.api, ref, x) != .Ok {
			pa.history_gesture_end(&a.api)
			return false
		}
	}
	if ended do pa.history_gesture_end(&a.api)
	return true
}

// A click set synth pad `pad`'s parameter `id` to `v`: one step named `step`.
set_synth_param :: proc(a: ^App, pad: int, id: i64, v: f64, step: string) {
	pa.history_name_next(&a.api, step)
	pa.param_set(&a.api, {track = .Pad, index = i64(pad), device = .Sound, param = id}, v)
}

// A control moved effect slot `t`'s parameter `id` to `v` (a performance
// effect's too: `pa.effect_set_param`). Clamped to its range by the caller.
control_effect_param :: proc(a: ^App, t: pm.Fx_Target, id: i64, v: f64, changed, ended: bool) {
	if changed {
		pa.history_gesture_begin(&a.api)
		pa.effect_set_param(&a.api, slot_ref(t), id, v)
	}
	if ended do pa.history_gesture_end(&a.api)
}
