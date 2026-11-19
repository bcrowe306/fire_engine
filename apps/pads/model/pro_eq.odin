package pads_model

import fc "fire:core"
import "fire:fx"

// ProEq in a slot: its settings as the node's values, and its mode, which
// starts set B as a copy of A.

// Slot `s`'s ProEq settings, as `fx.pro_eq_curve` takes them (any it
// doesn't hold at their defaults).
pro_eq_values :: proc(s: Effect_Slot) -> fx.Pro_Eq_Values {
	v := fx.pro_eq_defaults()
	s := s
	for p in s.params[:s.count] do if int(p.id) >= 1 && int(p.id) <= fx.PE_PARAMS do v[p.id] = p.value
	return v
}

// Whether slot `s`'s set B is as it starts (every band at its default).
pro_eq_b_untouched :: proc(s: Effect_Slot) -> bool {
	for b in 0 ..< fx.PE_BANDS do for f in fx.Pro_Eq_Field {
		id := fx.pro_eq_band_param(1, b, f)
		if slot_value(s, id, f32(fx.pro_eq_params[id - 1].default)) != f32(fx.pro_eq_params[id - 1].default) do return false
	}
	return true
}

// Sets the mode of the ProEq in slot `t`, as one undo step. Leaving Stereo
// with set B as it started, B becomes a copy of A first (so both sides
// begin where the EQ was). False if the slot holds no ProEq.
pro_eq_set_mode :: proc(m: ^Model, t: Fx_Target, mode: fx.Pro_Eq_Mode) -> bool {
	s, ok := target_slot(m, t)
	if !ok || s.kind != .Pro_Eq do return false
	if mode != .Stereo && pro_eq_b_untouched(s) {
		for b in 0 ..< fx.PE_BANDS do for f in fx.Pro_Eq_Field {
			a := fx.pro_eq_band_param(0, b, f)
			slot_set(&s, fx.pro_eq_band_param(1, b, f), slot_value(s, a, f32(fx.pro_eq_params[a - 1].default)))
		}
	}
	slot_set(&s, fx.PE_PARAM_MODE, f32(mode))
	set_target_slot(m, t, s, "Set EQ Mode")
	return true
}

// The id of set `set`'s band `band`'s `field` (a shorter name for the UI).
pe_param :: proc "contextless" (set, band: int, field: fx.Pro_Eq_Field) -> fc.Param_Id {
	return fx.pro_eq_band_param(set, band, field)
}
