package pads_api

import "core:fmt"
import "core:math"

import fc "fire:core"
import "fire:dsp"
import "fire:graph"
import pm "../model"

// Whose parameter.
Track :: enum i32 {
	None,
	Pad,  // `index` 0..127
	Bus,  // `index` 0..15
	Main,
}

// Which of a track's devices.
Device :: enum i32 {
	Sound,  // a pad's instrument: the sampler, the synth, a plug-in (any of its parameters)
	Insert, // a pad's insert `slot`, or a bus's or main's effect `slot`
	Volume, // a fader (dB)
	Pan,    // a pan (-1..1)
	Send,   // a pad's send `slot` (to bus slot + 1), in dB
	Eq,     // a pad's EQ (its bands' gains)
}

// Any parameter: a device of a track, and its parameter's id (the
// device's own; for Volume, Pan and Send, ignored). Stable: a caller may
// keep it. The same thing automation points at.
Param_Ref :: struct {
	track:  Track,
	index:  i64, // the pad or the bus
	device: Device,
	slot:   i64, // the insert, the effect, the send
	param:  i64, // the parameter's id on its device
}

// What a parameter's values are in.
Param_Unit :: enum i32 {
	None,
	Decibels,
	Hertz,
	Milliseconds,
	Percent,
	Semitones,
	Ratio,
}

// What a parameter is: its range in plain units, where it starts, how it
// is drawn.
Param_Info :: struct {
	min:         f64,
	max:         f64,
	default_value: f64, // where it starts
	unit:        Param_Unit,
	stepped:     bool, // whole values only (a choice)
	log:         bool, // a frequency: drawn on a log scale
	automatable: bool,
}

// Parameters device `ref` has now (`ref.param` ignored; `param_at` lists
// them). Not_Found if the device isn't there (an empty pad, an empty
// slot).
param_count :: proc(api: ^Api, ref: Param_Ref) -> (i64, Result) {
	if fixed, ok := fixed_info(ref); ok {
		_ = fixed
		return 1, .Ok
	}
	ps, r := node_params(api, ref)
	return i64(len(ps)), r
}

// Device `ref`'s parameter `index` (in its order) as a reference.
param_at :: proc(api: ^Api, ref: Param_Ref, index: i64) -> (Param_Ref, Result) {
	out := ref
	if _, ok := fixed_info(ref); ok {
		if index != 0 do return {}, fail(api, .Not_Found, "a fader, pan or send has one parameter")
		out.param = 0
		return out, .Ok
	}
	ps, r := node_params(api, ref)
	if r != .Ok do return {}, r
	if index < 0 || index >= i64(len(ps)) do return {}, fail(api, .Not_Found, "no such parameter")
	out.param = i64(ps[index].id)
	return out, .Ok
}

// What parameter `ref` is: its range, default, unit, steps.
param_info :: proc(api: ^Api, ref: Param_Ref) -> (Param_Info, Result) {
	if info, ok := fixed_info(ref); ok do return info, check_track(api, ref)
	p, r := node_param(api, ref)
	if r != .Ok do return {}, r
	return {min = p.min, max = p.max, default_value = p.default, unit = Param_Unit(p.unit), stepped = .Stepped in p.flags,
		log = p.unit == .Hertz && p.min > 0, automatable = .Automatable in p.flags}, .Ok
}

// Parameter `ref`'s name ("Cutoff", "Volume"). Temporary.
param_name :: proc(api: ^Api, ref: Param_Ref) -> (string, Result) {
	#partial switch ref.device {
	case .Volume: return "Volume", check_track(api, ref)
	case .Send:   return "Send", check_track(api, ref)
	case .Pan:
		if ref.track != .Pad do return "Pan", check_track(api, ref)
	}
	p, r := node_param(api, ref)
	if r != .Ok do return "", r
	return p.name, .Ok
}

// Parameter `ref`'s value now, in its plain units (as the project keeps
// it: not what automation moves it to while it plays).
param_get :: proc(api: ^Api, ref: Param_Ref) -> (f64, Result) {
	m := &api.core.m
	r := check_track(api, ref)
	if r != .Ok do return 0, r
	i := int(ref.index)
	switch ref.track {
	case .None:
	case .Pad:
		pad := &m.project.pads[i]
		switch ref.device {
		case .Volume: return f64(pad.volume), .Ok
		case .Pan:    return f64(pad.pan), .Ok
		case .Send:   return f64(pm.send_db(pad.sends[ref.slot])), .Ok
		case .Eq:
			if b, ok := eq_band(ref); ok do return f64(pad.eq[b]), .Ok
			return 0, fail(api, .Unsupported, "only the EQ's band gains are kept")
		case .Insert:
			return slot_get(api, {kind = .Pad, index = i, slot = int(ref.slot)}, ref)
		case .Sound:
			#partial switch pad.kind {
			case .Sampler, .Slicer:
				id := fc.Param_Id(ref.param)
				vals := pm.voice_params(pad^)
				if id < 1 || int(id) > len(vals) do return 0, fail(api, .Not_Found, "no such sampler parameter")
				return vals[id - 1], .Ok
			case .Synth:
				return f64(pm.synth_value(m, i, fc.Param_Id(ref.param))), .Ok
			case .Plugin:
				return slot_get(api, {kind = .Instrument, index = i}, ref)
			}
			return 0, fail(api, .Unsupported, "an audio track has no sound parameters")
		}
	case .Bus, .Main:
		b := bus_index(ref)
		bus := pm.bus_of(m, b)
		#partial switch ref.device {
		case .Volume: return f64(bus.volume), .Ok
		case .Pan:    return f64(bus.pan), .Ok
		case .Insert: return slot_get(api, {kind = .Bus, index = b, slot = int(ref.slot)}, ref)
		}
		return 0, fail(api, .Unsupported, "a bus has a fader, a pan and effects")
	}
	return 0, fail(api, .Not_Found, "no track")
}

// Sets parameter `ref` to `value` (plain units, in its range), undoably:
// each call a step, or one for a touch (`param_touch`) or a gesture.
param_set :: proc(api: ^Api, ref: Param_Ref, value: f64) -> Result {
	info, r := param_info(api, ref)
	if r != .Ok {
		// (A parameter of no node now: a sampler's, a synth's or an effect's
		// can still be kept.)
		if !(ref.device == .Sound || ref.device == .Insert) do return r
		info = {min = -math.F64_MAX, max = math.F64_MAX}
	}
	if !(value >= info.min && value <= info.max) do return fail(api, .Invalid_Argument, fmt.tprintf("the value is %g..%g", info.min, info.max))
	v := math.round(value) if info.stepped else value
	m := &api.core.m
	// The step is named after the parameter ("Set Cutoff").
	step := "Set Sound"
	if pname, pr := param_name(api, ref); pr == .Ok do step = fmt.tprintf("Set %s", pname)
	i := int(ref.index)
	switch ref.track {
	case .None:
		return fail(api, .Not_Found, "no track")
	case .Pad:
		pad := m.project.pads[i]
		switch ref.device {
		case .Volume:
			pad.volume = f32(v)
			pm.set_pad(m, i, .Volume, "Set Volume", pad)
		case .Pan:
			pad.pan = f32(v)
			pm.set_pad(m, i, .Pan, "Set Pan", pad)
		case .Send:
			if ref.slot < 0 || ref.slot >= pm.BUSES do return fail(api, .Not_Found, "no such send")
			pm.set_send_db(m, i, int(ref.slot) + 1, f32(v))
		case .Eq:
			b, ok := eq_band(ref)
			if !ok do return fail(api, .Unsupported, "only the EQ's band gains are kept")
			pad.eq[b] = f32(v)
			pm.set_pad(m, i, pm.Pad_Field(int(pm.Pad_Field.Eq_Low) + b), "Set EQ", pad)
		case .Insert:
			t := pm.Fx_Target{kind = .Pad, index = i, slot = int(ref.slot)}
			if s, ok := pm.target_slot(m, t); !ok || s.kind == .None do return fail(api, .Not_Found, "no effect in that slot")
			pm.set_target_param(m, t, fc.Param_Id(ref.param), f32(v))
		case .Sound:
			#partial switch pad.kind {
			case .Sampler, .Slicer:
				old := pad
				if !pm.voice_param_set(&pad, fc.Param_Id(ref.param), v) do return fail(api, .Not_Found, "no such sampler parameter")
				// (Attack, release and transpose are the pad's own fields; the rest its voice's.)
				switch {
				case pad.attack != old.attack:   pm.set_pad(m, i, .Attack, step, pad)
				case pad.release != old.release: pm.set_pad(m, i, .Release, step, pad)
				case pad.pitch != old.pitch:     pm.set_pad(m, i, .Pitch, step, pad)
				case:                            pm.set_voice(m, i, int(ref.param), step, pad.voice)
				}
			case .Synth:
				pm.set_synth_value(m, i, fc.Param_Id(ref.param), f32(v), step)
			case .Plugin:
				pm.set_target_param(m, {kind = .Instrument, index = i}, fc.Param_Id(ref.param), f32(v))
			case:
				return fail(api, .Unsupported, "an audio track has no sound parameters")
			}
		}
	case .Bus, .Main:
		b := bus_index(ref)
		bus := pm.bus_of(m, b)^
		#partial switch ref.device {
		case .Volume:
			bus.volume = f32(v)
			pm.set_bus(m, b, 0, "Set Volume", bus)
		case .Pan:
			bus.pan = f32(v)
			pm.set_bus(m, b, 2, "Set Pan", bus)
		case .Insert:
			t := pm.Fx_Target{kind = .Bus, index = b, slot = int(ref.slot)}
			if s, ok := pm.target_slot(m, t); !ok || s.kind == .None do return fail(api, .Not_Found, "no effect in that slot")
			pm.set_target_param(m, t, fc.Param_Id(ref.param), f32(v))
		case:
			return fail(api, .Unsupported, "a bus has a fader, a pan and effects")
		}
	}
	if api.has_touch && api.touched == ref {
		if api.core.hooks.param_moved != nil do api.core.hooks.param_moved(api.core.hooks.user, auto_target(ref), f32(v))
	}
	edited(api)
	return .Ok
}

// Parameter `ref`'s value as the UI shows it ("-6.0 dB", "1.2 kHz").
// Temporary.
param_text :: proc(api: ^Api, ref: Param_Ref) -> (string, Result) {
	v, r := param_get(api, ref)
	if r != .Ok do return "", r
	info, _ := param_info(api, ref)
	if info.stepped do return fmt.tprintf("%.0f", v), .Ok
	switch info.unit {
	case .Decibels:     return fmt.tprintf("%.1f dB", v), .Ok
	case .Hertz:        return fmt.tprintf("%.2f kHz", v / 1000) if v >= 1000 else fmt.tprintf("%.0f Hz", v), .Ok
	case .Milliseconds: return fmt.tprintf("%.0f ms", v), .Ok
	case .Percent:      return fmt.tprintf("%.0f%%", v), .Ok
	case .Semitones:    return fmt.tprintf("%+.1f st", v), .Ok
	case .Ratio:        return fmt.tprintf("%.1f:1", v), .Ok
	case .None:
	}
	return fmt.tprintf("%.2f", v), .Ok
}

// Begins (`on`) or ends touching parameter `ref`, as a knob is held: its
// moves until let go are one undo step, and with automation recording
// armed, they are written while it plays. One parameter is touched at a
// time (touching another lets the first go).
param_touch :: proc(api: ^Api, ref: Param_Ref, on: bool) -> Result {
	if r := check_track(api, ref); r != .Ok do return r
	h := &api.core.hooks
	if api.has_touch && (!on || api.touched != ref) {
		if h.param_touched != nil do h.param_touched(h.user, auto_target(api.touched), false)
		api.has_touch = false
		history_gesture_end(api)
	}
	if on {
		api.touched, api.has_touch = ref, true
		history_gesture_begin(api)
		if h.param_touched != nil do h.param_touched(h.user, auto_target(ref), true)
	}
	return .Ok
}

// The automation target the model calls `ref`.
@(private)
auto_target :: proc(ref: Param_Ref) -> pm.Auto_Target {
	return {track = pm.Auto_Track(ref.track), index = u8(ref.index), device = pm.Auto_Device(ref.device), slot = u8(ref.slot), param = fc.Param_Id(ref.param)}
}

@(private)
check_track :: proc(api: ^Api, ref: Param_Ref) -> Result {
	switch ref.track {
	case .None: return fail(api, .Not_Found, "no track")
	case .Pad:  if ref.index < 0 || ref.index >= PADS do return fail(api, .Not_Found, "a pad is 0..127")
	case .Bus:  if ref.index < 0 || ref.index >= pm.BUSES do return fail(api, .Not_Found, "a bus is 0..15")
	case .Main:
	}
	if ref.device < min(Device) || ref.device > max(Device) do return fail(api, .Invalid_Argument, "no such device")
	if ref.device == .Send && (ref.track != .Pad || ref.slot < 0 || ref.slot >= pm.BUSES) do return fail(api, .Not_Found, "no such send")
	return .Ok
}

@(private)
bus_index :: proc(ref: Param_Ref) -> int {
	return pm.BUSES if ref.track == .Main else int(ref.index)
}

// A fader's, a send's or a bus's pan: not a node's own parameter.
@(private)
fixed_info :: proc(ref: Param_Ref) -> (Param_Info, bool) {
	#partial switch ref.device {
	case .Volume, .Send: return {min = -60, max = 6, default_value = 0, unit = .Decibels, automatable = true}, true
	case .Pan:           return {min = -1, max = 1, default_value = 0, automatable = true}, true
	}
	return {}, false
}

// The EQ band a parameter is the gain of.
@(private)
eq_band :: proc(ref: Param_Ref) -> (int, bool) {
	for b in 0 ..< 3 do if fc.Param_Id(ref.param) == dsp.eq_band_param(b, .Gain_Db) do return b, true
	return 0, false
}

@(private)
slot_get :: proc(api: ^Api, t: pm.Fx_Target, ref: Param_Ref) -> (f64, Result) {
	s, ok := pm.target_slot(&api.core.m, t)
	if !ok || s.kind == .None do return 0, fail(api, .Not_Found, "no effect in that slot")
	def := 0.0
	if p, r := node_param(api, ref); r == .Ok do def = p.default
	return f64(pm.slot_value(s, fc.Param_Id(ref.param), f32(def))), .Ok
}

// The parameters device `ref`'s node has (the shown ones).
@(private)
node_params :: proc(api: ^Api, ref: Param_Ref) -> ([]fc.Param_Info, Result) {
	if r := check_track(api, ref); r != .Ok do return nil, r
	id, ok := pm.resolve_target(&api.core.m.engine, auto_target(ref))
	if !ok do return nil, fail(api, .Not_Found, "that device isn't there (an empty pad or slot)")
	n := graph.get_node(api.core.host.graph, id)
	if n == nil do return nil, fail(api, .Not_Found, "that device isn't there")
	out := make([dynamic]fc.Param_Info, context.temp_allocator)
	for p in fc.node_params(n) do if .Hidden not_in p.flags do append(&out, p)
	return out[:], .Ok
}

@(private)
node_param :: proc(api: ^Api, ref: Param_Ref) -> (fc.Param_Info, Result) {
	ps, r := node_params(api, ref)
	if r != .Ok do return {}, r
	for p in ps do if i64(p.id) == ref.param do return p, .Ok
	return {}, fail(api, .Not_Found, "no such parameter on that device")
}
