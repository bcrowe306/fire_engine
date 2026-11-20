package pads_api

import "base:runtime"
import "core:fmt"
import "core:math"

import app "app:core"
import abi "fsurf:abi"
import fsurf "fsurf:host"
import pm "../model"

/*
fsurf.daw (extern/fire-surface/include/fsurf_daw.h) over this API: what a
control surface written for any host sees of Pads.

- Tracks are the pads (PADS of them, every bank's); the selected track is
  the selected pad. Volume is the pad's fader on the mixer's taper, pan
  its pan; no sends yet.
- Devices are the selected pad's: its sound, then its inserts that hold
  an effect; their parameters as the API has them (normalized: a
  frequency on a log scale).
- The launcher's columns are its lanes (A, B...), its rows the rows of
  sequences; a scene is a row.
- Notes: the project key's scale and root.
- Changes: the API's topics (transport, selection, mixer, launcher), and,
  once a frame, a look at what it doesn't report (the pads' names and
  colours, the devices, their parameters' values), for the topics a surface
  follows.
*/

@(private)
Daw_State :: struct {
	table:     abi.Daw,
	listeners: [dynamic]Daw_Listener,
	subs:      [dynamic]Subscription, // the API's, while anyone listens
	digest:    [3]u64, // tracks, devices, parameters: what was last told
	device:    [PADS]int, // each pad's selected device
	text:      [256]u8,
}

@(private)
Daw_Listener :: struct {
	host:     ^abi.Host,
	topics:   abi.Daw_Topics,
	listener: ^abi.Daw_Listener,
}

@(private)
daw_init :: proc(api: ^Api) {
	api.daw.table = {
		struct_size = size_of(abi.Daw),
		parts = {.Transport, .Tracks, .Devices, .Launcher, .Notes, .App},
		get = daw_get, get_text = daw_get_text, set = daw_set, action = daw_action,
		set_ring = proc "c" (h: ^abi.Host, ft, nt, fs, ns: i32) {}, // (Pads doesn't draw a ring yet)
		subscribe = daw_subscribe,
	}
	api.daw.listeners = make([dynamic]Daw_Listener)
	api.daw.subs = make([dynamic]Subscription)
}

@(private)
daw_destroy :: proc(api: ^Api) {
	for s in api.daw.subs do unsubscribe(api, s)
	delete(api.daw.subs)
	delete(api.daw.listeners)
}

// The API behind a surface's host (Surfaces' user is the API).
@(private)
api_of :: proc "contextless" (h: ^abi.Host) -> ^Api {
	inst := (^fsurf.Instance)(h.host_data)
	s := (^app.Surfaces)(inst.host.config.user)
	return (^Api)(s.config.user)
}

// ── Reading ───────────────────────────────────────────────────────────

@(private) FADER_LO :: -60 // the mixer's fader: its bottom (off) and top, in dB
@(private) FADER_HI :: 6

@(private)
fader_to_unit :: proc(db: f32) -> f64 {
	if db <= FADER_LO do return 0
	return f64(math.pow(clamp((db - FADER_LO) / (FADER_HI - FADER_LO), 0, 1), 1.5))
}

@(private)
unit_to_fader :: proc(v: f64) -> f32 {
	return FADER_LO + math.pow(f32(clamp(v, 0, 1)), 1 / 1.5) * (FADER_HI - FADER_LO)
}

@(private)
b2f :: proc(b: bool) -> f64 { return 1 if b else 0 }

// The selected pad's devices: its sound (when it has one), then its inserts holding an effect.
@(private)
devices_of :: proc(api: ^Api, pad: i64) -> []Param_Ref {
	out := make([dynamic]Param_Ref, context.temp_allocator)
	if st, r := pad_state(api, pad); r == .Ok && st.used do append(&out, Param_Ref{track = .Pad, index = pad, device = .Sound})
	for k in 0 ..< i64(4) {
		if es, r := effect_state(api, {.Insert, pad, k}); r == .Ok && es.kind != 0 do append(&out, Param_Ref{track = .Pad, index = pad, device = .Insert, slot = k})
	}
	return out[:]
}

@(private)
selected :: proc(api: ^Api) -> i64 { return i64(api.core.selected) }

// The selected device of the selected pad, and its parameter `i`.
@(private)
param_ref :: proc(api: ^Api, i: i32) -> (Param_Ref, bool) {
	p := selected(api)
	devs := devices_of(api, p)
	d := api.daw.device[p]
	if d < 0 || d >= len(devs) do return {}, false
	ref, r := param_at(api, devs[d], i64(i))
	return ref, r == .Ok
}

// A parameter's value as 0-1 (a frequency on a log scale).
@(private)
param_unit :: proc(api: ^Api, ref: Param_Ref) -> f64 {
	info, r := param_info(api, ref)
	v, r2 := param_get(api, ref)
	if r != .Ok || r2 != .Ok || info.max <= info.min do return 0
	if info.log && info.min > 0 do return clamp(math.ln(v / info.min) / math.ln(info.max / info.min), 0, 1)
	return clamp((v - info.min) / (info.max - info.min), 0, 1)
}

@(private)
param_from_unit :: proc(api: ^Api, ref: Param_Ref, u: f64) -> (f64, bool) {
	info, r := param_info(api, ref)
	if r != .Ok || info.max <= info.min do return 0, false
	x := clamp(u, 0, 1)
	v := info.min * math.pow(info.max / info.min, x) if info.log && info.min > 0 else info.min + x * (info.max - info.min)
	if info.stepped do v = math.round(v)
	return v, true
}

// Scale `s`'s notes as a mask from its root (bit 0 the root).
@(private)
scale_mask :: proc(s: Scale) -> u32 {
	m: u32
	for x in pm.scale_steps(pm.Scale(s)) do m |= 1 << u32(x)
	return m
}

@(private)
clip_state :: proc(api: ^Api, lane, row: i64) -> abi.Clip_State {
	ls, r := launcher_lane(api, lane)
	if r != .Ok || row >= ls.rows do return .Empty
	slot, _ := launcher_slot_at(api, lane, row)
	if slot < 0 do return .Empty
	if ls.playing == slot && ls.queued >= 0 && ls.queued != slot do return .Stopping
	if ls.playing == slot do return .Playing
	if ls.queued == slot do return .Queued
	return .Stopped
}

@(private)
daw_get :: proc "c" (h: ^abi.Host, id: abi.Daw_Id, a, b: i32) -> f64 {
	api := api_of(h)
	context = runtime.default_context()
	#partial switch id {
	case .Playing, .Loop, .Metronome, .Tempo, .Position, .Signature_Numerator, .Signature_Denominator, .Recording:
		ts, _ := transport_state(api)
		#partial switch id {
		case .Playing: return b2f(ts.playing)
		case .Recording: return b2f(ts.recording)
		case .Loop: return b2f(ts.loop)
		case .Metronome: return b2f(ts.metronome)
		case .Tempo: return ts.bpm
		case .Position: return ts.beat
		case .Signature_Numerator: return f64(ts.time_sig_num)
		case .Signature_Denominator: return f64(ts.time_sig_den)
		}
	case .Track_Count: return PADS
	case .Selected_Track: return f64(selected(api))
	case .Send_Count: return 0
	case .Track_Color, .Track_Mute, .Track_Solo, .Track_Arm, .Track_Volume, .Track_Pan, .Track_Meter:
		st, r := pad_state(api, i64(a))
		if r != .Ok do return 0
		#partial switch id {
		case .Track_Color: return f64(st.color)
		case .Track_Mute: return b2f(st.mute)
		case .Track_Solo: return b2f(st.solo)
		case .Track_Arm: return b2f(st.armed)
		case .Track_Volume: return fader_to_unit(st.volume)
		case .Track_Pan: return f64(clamp((st.pan + 1) / 2, 0, 1))
		case .Track_Meter:
			m, _ := mixer_pad_meter(api, i64(a))
			return f64(clamp(m.peak_r if b == 1 else m.peak_l, 0, 1))
		}
	case .Device_Count: return f64(len(devices_of(api, selected(api))))
	case .Selected_Device: return f64(api.daw.device[selected(api)])
	case .Device_On:
		devs := devices_of(api, selected(api))
		if a < 0 || int(a) >= len(devs) do return 0
		if devs[a].device != .Insert do return 1
		es, _ := effect_state(api, {.Insert, devs[a].index, devs[a].slot})
		return b2f(es.on)
	case .Param_Count:
		devs := devices_of(api, selected(api))
		d := api.daw.device[selected(api)]
		if d < 0 || d >= len(devs) do return 0
		n, _ := param_count(api, devs[d])
		return f64(n)
	case .Param_Value, .Param_Steps, .Param_Default:
		ref, ok := param_ref(api, a)
		if !ok do return 0
		#partial switch id {
		case .Param_Value: return param_unit(api, ref)
		case .Param_Steps:
			info, _ := param_info(api, ref)
			return f64(int(info.max - info.min) + 1) if info.stepped else 0
		case .Param_Default:
			info, _ := param_info(api, ref)
			if info.max <= info.min do return 0
			if info.log && info.min > 0 do return math.ln(info.default_value / info.min) / math.ln(info.max / info.min)
			return (info.default_value - info.min) / (info.max - info.min)
		}
	case .Param_Automated: return 0
	case .Scene_Count:
		ls, _ := launcher_state(api)
		rows: i64 = 0
		for l in 0 ..< ls.lanes {
			st, _ := launcher_lane(api, l)
			rows = max(rows, st.rows)
		}
		return f64(rows)
	case .Clip_State: return f64(u32(clip_state(api, i64(a), i64(b))))
	case .Clip_Color:
		slot, r := launcher_slot_at(api, i64(a), i64(b))
		if r != .Ok || slot < 0 do return 0
		ss, _ := sequence_state(api, slot)
		return f64(ss.color)
	case .Scale_Root:
		ps, _ := perform_state(api)
		return f64(ps.root)
	case .Scale_Mask:
		ps, _ := perform_state(api)
		return f64(scale_mask(ps.scale))
	}
	return 0
}

@(private)
daw_get_text :: proc "c" (h: ^abi.Host, id: abi.Daw_Id, a, b: i32) -> cstring {
	api := api_of(h)
	context = runtime.default_context()
	s: string
	#partial switch id {
	case .Track_Name:
		s, _ = pad_name(api, i64(a))
		if s == "" do s = fmt.tprintf("Pad %c%d", 'A' + rune(a / 16), a % 16 + 1)
	case .Track_Volume:
		st, r := pad_state(api, i64(a))
		if r != .Ok do return nil
		s = "-inf dB" if st.volume <= FADER_LO else fmt.tprintf("%.1f dB", st.volume)
	case .Device_Name:
		devs := devices_of(api, selected(api))
		if a < 0 || int(a) >= len(devs) do return nil
		d := devs[a]
		if d.device == .Sound {
			st, _ := pad_state(api, d.index)
			names := [Pad_Kind]string{.Sampler = "Sampler", .Audio = "Audio", .Slicer = "Slicer", .Synth = "Synth", .Plugin = "Plug-in"}
			s = names[st.kind]
		} else {
			es, _ := effect_state(api, {.Insert, d.index, d.slot})
			if es.plugin do s, _ = effect_name(api, {.Insert, d.index, d.slot})
			else do s, _ = effect_kind_name(api, es.kind)
		}
	case .Param_Name, .Param_Value:
		ref, ok := param_ref(api, a)
		if !ok do return nil
		if id == .Param_Name do s, _ = param_name(api, ref)
		else do s, _ = param_text(api, ref)
	case .Scene_Name: s = fmt.tprintf("Row %d", a + 1)
	case .Clip_Name:
		slot, r := launcher_slot_at(api, i64(a), i64(b))
		if r != .Ok || slot < 0 do return nil
		s, _ = sequence_name(api, slot)
	case .Scale_Name:
		ps, _ := perform_state(api)
		s = string(pm.SCALE_NAMES[pm.Scale(ps.scale)])
	case: return nil
	}
	n := min(len(s), len(api.daw.text) - 1)
	copy(api.daw.text[:n], s)
	api.daw.text[n] = 0
	return cstring(&api.daw.text[0])
}

// ── Changing ──────────────────────────────────────────────────────────

@(private)
daw_set :: proc "c" (h: ^abi.Host, id: abi.Daw_Id, a, b: i32, v: f64) -> bool {
	api := api_of(h)
	context = runtime.default_context()
	on := v >= 0.5
	r := Result.Not_Found
	#partial switch id {
	case .Playing:
		ts, _ := transport_state(api)
		if on == ts.playing do return true
		r = transport_play(api) if on else transport_stop(api)
	case .Recording: r = recording_record(api, on)
	case .Loop: r = transport_set_loop(api, on)
	case .Metronome: r = transport_set_metronome(api, on)
	case .Tempo: r = transport_set_tempo(api, v)
	case .Position:
		ts, _ := transport_state(api)
		if ts.playing do r = transport_play(api, max(v, 0))
		else do r = .Ok // (stopped: it starts at the top)
	case .Selected_Track:
		if v < 0 || v >= PADS do return false
		r = ui_select_pads(api, {i64(v)})
	case .Track_Mute: r = pad_set_mute(api, i64(a), on)
	case .Track_Solo: r = pad_set_solo(api, i64(a), on)
	case .Track_Arm: r = pad_set_armed(api, i64(a), on)
	case .Track_Volume: r = pad_set_volume(api, i64(a), unit_to_fader(v))
	case .Track_Pan: r = pad_set_pan(api, i64(a), f32(clamp(v, 0, 1) * 2 - 1))
	case .Selected_Device:
		n := len(devices_of(api, selected(api)))
		if v < 0 || int(v) >= n do return false
		api.daw.device[selected(api)] = int(v)
		daw_tell(api, {.Devices}, .Selected_Device)
		return true
	case .Device_On:
		devs := devices_of(api, selected(api))
		if a < 0 || int(a) >= len(devs) || devs[a].device != .Insert do return false
		r = effect_set_on(api, {.Insert, devs[a].index, devs[a].slot}, on)
	case .Param_Value:
		ref, ok := param_ref(api, a)
		if !ok do return false
		x, ok2 := param_from_unit(api, ref, v)
		if !ok2 do return false
		r = param_set(api, ref, x)
	}
	return r == .Ok
}

@(private)
daw_action :: proc "c" (h: ^abi.Host, id: abi.Daw_Action, a, b: i32) -> bool {
	api := api_of(h)
	context = runtime.default_context()
	r := Result.Not_Found
	switch id {
	case .Undo: r = history_undo(api)
	case .Redo: r = history_redo(api)
	case .Save: r = project_save(api)
	case .Tap_Tempo: _, r = transport_tap(api)
	case .Launch_Clip:
		slot, sr := launcher_slot_at(api, i64(a), i64(b))
		if sr != .Ok || slot < 0 do return false
		r = launcher_launch(api, slot)
	case .Stop_Track: r = launcher_stop_lane(api, i64(a))
	case .Launch_Scene: r = launcher_launch_row(api, i64(a))
	case .Stop_All_Clips: r = launcher_stop_all(api)
	case .Param_Reset:
		ref, ok := param_ref(api, a)
		if !ok do return false
		info, _ := param_info(api, ref)
		r = param_set(api, ref, info.default_value)
	case .Show_View:
		views := [abi.Daw_View]string{.Mixer = "mixer", .Song = "song", .Launcher = "perform", .Devices = "devices"}
		if a < 0 || a > i32(abi.Daw_View.Devices) do return false
		r = ui_show(api, views[abi.Daw_View(a)])
	}
	return r == .Ok
}

// ── Events ────────────────────────────────────────────────────────────

@(private)
daw_subscribe :: proc "c" (h: ^abi.Host, topics: abi.Daw_Topics, listener: ^abi.Daw_Listener) {
	api := api_of(h)
	context = runtime.default_context()
	for l, i in api.daw.listeners do if l.host == h {
		ordered_remove(&api.daw.listeners, i)
		break
	}
	if topics != {} && listener != nil do append(&api.daw.listeners, Daw_Listener{h, topics, listener})
	daw_watch(api)
}

// Subscribes to the API's topics while any surface listens (and not when none does).
@(private)
daw_watch :: proc(api: ^Api) {
	want := len(api.daw.listeners) > 0
	if want == (len(api.daw.subs) > 0) do return
	if !want {
		for s in api.daw.subs do unsubscribe(api, s)
		clear(&api.daw.subs)
		return
	}
	cb :: proc "c" (api: ^Api, topic: Topic, index: i64, user: rawptr) {
		context = runtime.default_context()
		#partial switch topic {
		case .Transport: daw_tell(api, {.Transport})
		case .Selection: daw_tell(api, {.Tracks, .Devices, .Parameters, .Notes})
		case .Mixer: daw_tell(api, {.Mixer})
		case .Launcher: daw_tell(api, {.Launcher})
		}
	}
	for topic in ([]Topic{.Transport, .Selection, .Mixer, .Launcher}) {
		owner := api.owner
		api.owner = 0 // (Pads' own, not a surface's)
		if s, r := subscribe(api, topic, -1, cb, nil); r == .Ok do append(&api.daw.subs, s)
		api.owner = owner
	}
	api.daw.digest = daw_digests(api)
}

// Tells the listeners following `topics` that `id` changed (None: several things).
@(private)
daw_tell :: proc(api: ^Api, topics: abi.Daw_Topics, id := abi.Daw_Id.None, a := 0, b := 0) {
	for t in abi.Daw_Topic do if t in topics {
		e := abi.Daw_Event{struct_size = size_of(abi.Daw_Event), topic = {t}, id = id, a = i32(a), b = i32(b)}
		for i := 0; i < len(api.daw.listeners); i += 1 {
			l := api.daw.listeners[i]
			if t in l.topics do l.listener.on_event(l.listener, &e)
		}
	}
}

// What the API doesn't report: the pads' names, colours and arms, the
// selected pad's devices, and their parameters' values, as numbers to
// compare from frame to frame.
@(private)
daw_digests :: proc(api: ^Api) -> (d: [3]u64) {
	mix :: proc(h: ^u64, x: u64) { h^ = (h^ ~ x) * 0x100000001b3 }
	d = {0xcbf29ce484222325, 0xcbf29ce484222325, 0xcbf29ce484222325}
	for p in 0 ..< i64(PADS) {
		st, _ := pad_state(api, p)
		mix(&d[0], u64(st.color) | u64(st.armed) << 32 | u64(st.used) << 33 | u64(st.kind) << 34)
		name, _ := pad_name(api, p)
		for c in transmute([]u8)name do mix(&d[0], u64(c))
	}
	devs := devices_of(api, selected(api))
	mix(&d[1], u64(len(devs)) | u64(api.daw.device[selected(api)]) << 8 | u64(selected(api)) << 16)
	for r in devs {
		mix(&d[1], u64(r.device) << 8 | u64(r.slot))
		if r.device == .Insert {
			es, _ := effect_state(api, {.Insert, r.index, r.slot})
			mix(&d[1], u64(es.kind) | u64(es.on) << 32)
		}
	}
	dv := api.daw.device[selected(api)]
	if dv >= 0 && dv < len(devs) {
		n, _ := param_count(api, devs[dv])
		for i in 0 ..< min(n, 64) {
			ref, _ := param_at(api, devs[dv], i)
			v, _ := param_get(api, ref)
			mix(&d[2], transmute(u64)v)
		}
	}
	return
}

// Once a frame: what changed that the API doesn't report.
@(private)
daw_frame :: proc(api: ^Api) {
	if len(api.daw.listeners) == 0 do return
	follow: abi.Daw_Topics
	for l in api.daw.listeners do follow += l.topics
	if follow & {.Tracks, .Devices, .Parameters} == {} do return
	now := daw_digests(api)
	if now[0] != api.daw.digest[0] do daw_tell(api, {.Tracks})
	if now[1] != api.daw.digest[1] {
		// Another pad's devices: its own selection (kept per pad).
		devs := len(devices_of(api, selected(api)))
		if api.daw.device[selected(api)] >= devs do api.daw.device[selected(api)] = max(devs - 1, 0)
		daw_tell(api, {.Devices})
	}
	if now[2] != api.daw.digest[2] do daw_tell(api, {.Parameters})
	api.daw.digest = now
}
