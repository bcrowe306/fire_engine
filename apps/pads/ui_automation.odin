package pads

import "core:fmt"
import "core:math"
import "core:strings"

import "app:ui"
import pm "model"
import im "deps:imgui"
import fc "fire:core"
import "fire:dsp"
import "fire:graph"

// Automation of any parameter, as the Sequence view's Automation tab shows
// it: which lane it is showing, what each target is called, its values
// in their units, and the menu that makes a new one (a track, a device, a
// parameter).

// The lane the Automation tab shows: the target chosen in its menu, else
// a pad's own lane (`auto_target_pad`'s `a.seq.param`).
current_lane :: proc(a: ^App) -> pm.Lane {
	if a.seq.target.track != .None do return {pad = a.seq.target.index if a.seq.target.track == .Pad else 0, target = a.seq.target}
	return pm.pad_lane(auto_target_pad(a), a.seq.param)
}

// The parameters a target's device has now (from its node; none if it has
// no node), the ones that may be automated and are not hidden.
device_params :: proc(a: ^App, t: pm.Auto_Target) -> []fc.Param_Info {
	id, ok := pm.resolve_target(&a.m.engine, t)
	if !ok do return nil
	n := graph.get_node(a.host.graph, id)
	if n == nil do return nil
	out := make([dynamic]fc.Param_Info, context.temp_allocator)
	for p in fc.node_params(n) do if .Hidden not_in p.flags && .Automatable in p.flags do append(&out, p)
	return out[:]
}

// Target `t` with its parameter `info`: its range and steps.
target_with :: proc(t: pm.Auto_Target, info: fc.Param_Info) -> pm.Auto_Target {
	r := t
	r.param = info.id
	r.lo, r.hi = f32(info.min), f32(info.max)
	r.stepped = .Stepped in info.flags
	r.log = info.unit == .Hertz && info.min > 0
	return r
}

// A fader's or a send's target (dB), or a bus's pan.
fixed_target :: proc(track: pm.Auto_Track, index: int, device: pm.Auto_Device, slot := 0) -> pm.Auto_Target {
	t := pm.Auto_Target{track = track, index = u8(index), device = device, slot = u8(slot)}
	#partial switch device {
	case .Volume, .Send: t.lo, t.hi = -60, 6
	case .Pan:           t.lo, t.hi = -1, 1
	}
	return t
}

// The track's name: "A1 kick", "Bus A", "Main".
track_name :: proc(a: ^App, t: pm.Auto_Target) -> string {
	p := &a.m.project
	switch t.track {
	case .None: return ""
	case .Pad:
		i := int(t.index)
		if pm.pad_used(p, i) do return fmt.tprintf("%s %s", pm.pad_label(i), pm.pad_name(&p.pads[i]))
		return pm.pad_label(i)
	case .Bus:  return pm.bus_name(p, int(t.index) + 1)
	case .Main: return "Main"
	}
	return ""
}

// Target `t`'s name: its track, its device, its parameter ("A1 kick ·
// Filter: Cutoff", "Bus A · Volume").
auto_target_name :: proc(a: ^App, t: pm.Auto_Target) -> string {
	p := &a.m.project
	device := ""
	switch t.device {
	case .Volume: return fmt.tprintf("%s · Volume", track_name(a, t))
	case .Pan:
		if t.track != .Pad do return fmt.tprintf("%s · Pan", track_name(a, t))
		device = "Sound"
	case .Send:   return fmt.tprintf("%s · Send %s", track_name(a, t), pm.bus_name(p, int(t.slot) + 1))
	case .Eq:     device = "EQ"
	case .Sound:  device = "Sound"
	case .Insert:
		s: pm.Effect_Slot
		if t.track == .Pad do s = p.pads[t.index].inserts[t.slot]
		else if t.track == .Main do s = p.main.slots[t.slot]
		else do s = p.buses[t.index].slots[t.slot]
		device = pm.slot_name(s) if s.kind != .None else fmt.tprintf("Effect %d", int(t.slot) + 1)
	}
	name := fmt.tprintf("param %d", u32(t.param))
	for info in device_params(a, t) do if info.id == t.param do name = info.name
	return fmt.tprintf("%s · %s: %s", track_name(a, t), device, name)
}

// A lane's name, as the menu shows it.
lane_name :: proc(a: ^App, l: pm.Lane) -> string {
	if l.target.track != .None do return auto_target_name(a, l.target)
	return fmt.tprintf("%s · %s", pm.pad_label(int(l.pad)), lane_label(a, int(l.pad), l.param))
}

// Whether lane `l` is drawn on a log scale (frequencies).
lane_log :: proc(l: pm.Lane) -> bool {
	if l.target.track == .None do return l.param == .Cutoff
	return l.target.log && l.target.lo > 0
}

// Value `v` of lane `l` as 0..1 up its height, and back.
lane_norm :: proc(l: pm.Lane, v: f32) -> f32 {
	lo, hi := pm.lane_range_of(l)
	if hi <= lo do return 0
	if lane_log(l) do return math.ln(max(v, lo) / lo) / math.ln(hi / lo)
	return (v - lo) / (hi - lo)
}
lane_denorm :: proc(l: pm.Lane, n: f32) -> f32 {
	lo, hi := pm.lane_range_of(l)
	u := clamp(n, 0, 1)
	if lane_log(l) && lo > 0 do return lo * math.exp(u * math.ln(hi / lo))
	return lo + u * (hi - lo)
}

// A value of lane `l` as its scale and its points show it, in its units.
lane_text :: proc(a: ^App, l: pm.Lane, v: f32) -> string {
	if l.target.track == .None do return lane_value_text(l.param, v)
	t := l.target
	#partial switch t.device {
	case .Volume, .Send: return fmt.tprintf("%+.1f dB", v)
	case .Pan:
		if t.track != .Pad do return pan_text(v)
	}
	for info in device_params(a, t) do if info.id == t.param {
		switch info.unit {
		case .Decibels:     return fmt.tprintf("%+.1f dB", v)
		case .Hertz:        return fmt.tprintf("%.1f kHz", v / 1000) if v >= 1000 else fmt.tprintf("%.0f Hz", v)
		case .Milliseconds: return fmt.tprintf("%.0f ms", v)
		case .Percent:      return fmt.tprintf("%.0f%%", v * 100 if info.max <= 1 else v)
		case .Semitones:    return fmt.tprintf("%+.1f st", v)
		case .Ratio:        return fmt.tprintf("%.2f:1", v)
		case .None:
		}
	}
	if t.stepped do return fmt.tprintf("%.0f", v)
	return fmt.tprintf("%.2f", v)
}

// A pan position (-1..1) as "L 40", "C", "R 25".
@(private)
pan_text :: proc(v: f32) -> string {
	if abs(v) < 0.005 do return "C"
	return fmt.tprintf("%s %.0f", "L" if v < 0 else "R", abs(v) * 100)
}

// The device's parameters as menu items; the one chosen becomes the
// automation shown. True if one was.
@(private)
param_items :: proc(a: ^App, t: pm.Auto_Target) -> bool {
	params := device_params(a, t)
	if len(params) == 0 {
		im.TextDisabled("Nothing to automate")
		return false
	}
	chosen := false
	for info in params {
		if im.MenuItem(fmt.ctprintf("%s###p%d", info.name, u32(info.id))) {
			a.seq.target = target_with(t, info)
			chosen = true
		}
	}
	return chosen
}

// The New automation menu (inside an open menu): every track (the pads
// with a sound, the buses in use, main), then its devices, then their
// parameters. The one chosen becomes the automation shown.
new_automation_items :: proc(a: ^App) {
	p := &a.m.project
	st := &a.seq
	pick :: proc(a: ^App, t: pm.Auto_Target) { a.seq.target = t }
	effects :: proc(a: ^App, track: pm.Auto_Track, index: int, slots: []pm.Effect_Slot) {
		for s, k in slots do if s.kind != .None {
			if im.BeginMenu(fmt.ctprintf("%s###fx%d", pm.slot_name(s), k)) {
				param_items(a, {track = track, index = u8(index), device = .Insert, slot = u8(k)})
				im.EndMenu()
			}
		}
	}
	for i in 0 ..< pm.PADS do if pm.pad_used(p, i) {
		pad := &p.pads[i]
		if im.BeginMenu(fmt.ctprintf("%s  %s###np%d", pm.pad_label(i), pm.pad_name(pad), i)) {
			if im.MenuItem("Volume") do pick(a, fixed_target(.Pad, i, .Volume))
			if im.BeginMenu("Sound") {
				param_items(a, {track = .Pad, index = u8(i), device = .Sound})
				im.EndMenu()
			}
			if im.BeginMenu("EQ") {
				param_items(a, {track = .Pad, index = u8(i), device = .Eq})
				im.EndMenu()
			}
			effects(a, .Pad, i, pad.inserts[:])
			for s, k in pad.sends do if s.level > 0 {
				if im.MenuItem(fmt.ctprintf("Send %s###sd%d", pm.bus_name(p, k + 1), k)) do pick(a, fixed_target(.Pad, i, .Send, k))
			}
			im.EndMenu()
		}
	}
	im.Separator()
	for b in 0 ..< p.bus_count {
		if im.BeginMenu(fmt.ctprintf("%s###nb%d", pm.bus_name(p, b + 1), b)) {
			if im.MenuItem("Volume") do pick(a, fixed_target(.Bus, b, .Volume))
			if im.MenuItem("Pan") do pick(a, fixed_target(.Bus, b, .Pan))
			effects(a, .Bus, b, p.buses[b].slots[:])
			im.EndMenu()
		}
	}
	if im.BeginMenu("Main###nmain") {
		if im.MenuItem("Volume") do pick(a, fixed_target(.Main, 0, .Volume))
		if im.MenuItem("Pan") do pick(a, fixed_target(.Main, 0, .Pan))
		effects(a, .Main, 0, p.main.slots[:])
		im.EndMenu()
	}
	_ = st
	_ = strings.clone
}

// --- knobs: Automate, and learning ------------------------------------------------------

// Says what the knob (or fader) about to be drawn moves, for its menu's
// Automate, learning and recording; `scale` turns what the knob shows
// into the target's units (a sustain shown 0..1 that is 0..100 % on the
// node: 100). Give it {} after it.
knob_target :: proc(a: ^App, t: pm.Auto_Target, scale: f32 = 1) {
	a.knob_target, a.knob_scale = t, scale
}

// Pad `pad`'s sound parameter named `name` ("Cutoff", "Transpose"), as a
// target ({} if its instrument has none).
sound_target :: proc(a: ^App, pad: int, name: string) -> pm.Auto_Target {
	t := pm.Auto_Target{track = .Pad, index = u8(pad), device = .Sound}
	for info in device_params(a, t) do if info.name == name do return target_with(t, info)
	return {}
}

// A pad's sound parameter `id` as a target (a synth's, a plug-in's).
sound_param_target :: proc(pad: int, id: fc.Param_Id) -> pm.Auto_Target {
	return {track = .Pad, index = u8(pad), device = .Sound, param = id}
}

// Target `t` with its range filled in (from its device, or a fader's,
// a send's or a bus's pan); false if it is not one.
complete_target :: proc(a: ^App, t: pm.Auto_Target) -> (pm.Auto_Target, bool) {
	if t.track == .None do return {}, false
	#partial switch t.device {
	case .Volume, .Send: return fixed_target(t.track, int(t.index), t.device, int(t.slot)), true
	case .Pan:
		if t.track != .Pad do return fixed_target(t.track, int(t.index), .Pan), true
	}
	if t.hi > t.lo do return t, true
	for info in device_params(a, t) do if info.id == t.param do return target_with(t, info), true
	return {}, false
}

// Shows target `t`'s automation in the Sequence view (a new one if the
// sequence has none yet: points drawn there make it).
show_automation :: proc(a: ^App, t: pm.Auto_Target) {
	full, ok := complete_target(a, t)
	if !ok do return
	a.seq.target = full
	a.seq.mode = .Automation
	a.seq.learning = false
	ui.panel_focus(&a.ws, "sequence")
}

// Gives the shared knobs and faders Pads' hooks (Automate in their menus,
// learning when touched).
install_knob_hooks :: proc(a: ^App) {
	ui.knob_hooks = {
		has_menu = proc(user: rawptr) -> bool { return (^App)(user).knob_target.track != .None },
		menu     = proc(user: rawptr) { knob_menu_items((^App)(user)) },
		touched  = proc(user: rawptr) { knob_touched((^App)(user)) },
		moved    = proc(user: rawptr, value: f32) { knob_moved((^App)(user), value) },
		released = proc(user: rawptr) { knob_released((^App)(user)) },
		user     = a,
	}
}

// The knob's own menu items: Automate (or Show Automation when the
// sequence has some of it).
knob_menu_items :: proc(a: ^App) {
	t := a.knob_target
	if t.track == .None do return
	s := pm.current_sequence(&a.m)
	has := false
	for pt in s.points do if pm.lane_equal(pt.lane, {target = t}) do has = true
	im.Separator()
	if im.MenuItem(ui.ICON_SPLINE + "  Show Automation###automate" if has else ui.ICON_SPLINE + "  Automate###automate") do show_automation(a, t)
	ui.name("Automate")
}

// A knob or fader began to move: while learning, it becomes the automation
// shown (and see `knob_moved` for recording).
knob_touched :: proc(a: ^App) {
	t := a.knob_target
	if t.track == .None do return
	if a.seq.learning {
		show_automation(a, t)
		ui.toast(&a.ws.toasts, .Info, fmt.tprintf("Automating %s", auto_target_name(a, a.seq.target)))
	}
	record_touch(a, t)
}

// A knob or fader moved to `value` (recording writes it).
knob_moved :: proc(a: ^App, value: f32) {
	record_move(a, value)
}

// A knob or fader let go.
knob_released :: proc(a: ^App) {
	record_release(a)
}

// An effect's parameter `id` as a target: a pad's insert, a bus's or
// main's effect, a plug-in pad's instrument ({} for the performance
// effects, which are played, not automated).
fx_auto_target :: proc(t: pm.Fx_Target, id: fc.Param_Id) -> pm.Auto_Target {
	#partial switch t.kind {
	case .Pad:        return {track = .Pad, index = u8(t.index), device = .Insert, slot = u8(t.slot), param = id}
	case .Bus:
		if t.index >= pm.BUSES do return {track = .Main, device = .Insert, slot = u8(t.slot), param = id}
		return {track = .Bus, index = u8(t.index), device = .Insert, slot = u8(t.slot), param = id}
	case .Instrument: return sound_param_target(t.index, id)
	}
	return {}
}

// What a pad's field moves, as a target: its volume (its fader), pan,
// transpose, attack and release (its sampler's), an EQ band ({} for the
// rest).
pad_field_target :: proc(a: ^App, pad: int, field: pm.Pad_Field) -> pm.Auto_Target {
	#partial switch field {
	case .Volume:  return fixed_target(.Pad, pad, .Volume)
	case .Pan:     return sound_target(a, pad, "Pan")
	case .Pitch:   return sound_target(a, pad, "Transpose")
	case .Attack:  return sound_target(a, pad, "Attack")
	case .Release: return sound_target(a, pad, "Release")
	case .Eq_Low, .Eq_Mid, .Eq_High:
		band := int(field) - int(pm.Pad_Field.Eq_Low)
		t := pm.Auto_Target{track = .Pad, index = u8(pad), device = .Eq, param = dsp.eq_band_param(band, .Gain_Db)}
		return t
	}
	return {}
}

// A right-click menu on the last item (an app-drawn control: the mixer's
// fader, pan) with Automate, when the control has a target.
automation_menu :: proc(a: ^App, id: cstring) {
	if a.knob_target.track == .None do return
	if im.BeginPopupContextItem(id) {
		knob_menu_items(a)
		im.EndPopup()
	}
}
