package pads

import "core:fmt"
import "core:math"

import app "app:core"
import "app:ui"
import pa "api"
import pm "model"
import im "deps:imgui"

// A track's ins and outs, and arming. Every track (pad) can be armed: an
// armed audio track records (and monitors) its input; an armed sampler
// track plays its own MIDI input chromatically and records it. With "Arm
// the selected track" (Settings > Recording, on by default) the selected
// track is armed and the one before disarmed, unless it was armed by hand.
// MIDI activity shows as a light: on the toolbar (all of it), on each
// strip and in each track's I/O (its own).
Track_Io :: struct {
	manual:     Pad_Set, // armed by hand (they stay armed when the selection moves)
	by_select:  int,     // armed because selected (-1: none)
	in_seen, out_seen: [pm.PADS]u32, // the activity counts last frame
	in_lit, out_lit: [pm.PADS]f32,   // seconds a track's light stays on
	all_in, all_out: u64,            // the host's counts last frame
	all_in_lit, all_out_lit: f32,
}

// Each frame: the selected track armed (when the setting says), and the
// activity lights.
track_io_frame :: proc(a: ^App) {
	io := &a.io
	m := &a.m
	if a.settings.arm_selected && a.selected != io.by_select {
		if io.by_select >= 0 && io.by_select not_in io.manual do pa.pad_set_armed(&a.api, i64(io.by_select), false)
		pa.pad_set_armed(&a.api, i64(a.selected), true)
		io.by_select = a.selected
	}
	dt := im.GetIO().DeltaTime
	LIT :: 0.12
	for i in 0 ..< pm.PADS {
		r, s := pm.midi_activity(&m.engine, i)
		if r != io.in_seen[i] do io.in_lit[i] = LIT
		if s != io.out_seen[i] do io.out_lit[i] = LIT
		io.in_seen[i], io.out_seen[i] = r, s
		io.in_lit[i] = max(io.in_lit[i] - dt, 0)
		io.out_lit[i] = max(io.out_lit[i] - dt, 0)
	}
	sent, received := app.host_midi_counts(&a.host)
	if received != io.all_in do io.all_in_lit = LIT
	if sent != io.all_out do io.all_out_lit = LIT
	io.all_in, io.all_out = received, sent
	io.all_in_lit = max(io.all_in_lit - dt, 0)
	io.all_out_lit = max(io.all_out_lit - dt, 0)
}

// A click on track `i`'s arm button: it alone armed (or disarmed), or with
// Cmd or Shift, one more (or one less).
arm_click :: proc(a: ^App, i: int) {
	io := &a.io
	m := &a.m
	keep := im.GetIO().KeyCtrl || im.GetIO().KeyShift
	on := !pm.track_armed(m, i)
	if !keep do for k in 0 ..< pm.PADS do if k != i && pm.track_armed(m, k) {
		pa.pad_set_armed(&a.api, i64(k), false)
		io.manual -= {k}
	}
	pa.pad_set_armed(&a.api, i64(i), on)
	if on do io.manual += {i}
	else do io.manual -= {i}
	// (Disarmed while selected: it stays off; `by_select` still names it,
	// so it isn't armed again until another is selected.)
}

// A square light: lit with `lit_in` (green, MIDI in) or `lit_out` (blue,
// MIDI out) seconds left; dim when quiet.
midi_light :: proc(dl: ^im.DrawList, at: im.Vec2, size: f32, lit_in, lit_out: f32) {
	t := ui.theme()
	c := ui.mix(t.raised, t.text, 0.12)
	if lit_out > 0 do c = ui.mix(c, ui.rgb(0x4f8cff), min(lit_out / 0.12, 1))
	if lit_in > 0 do c = ui.mix(c, t.ok, min(lit_in / 0.12, 1))
	im.DrawList_AddRectFilled(dl, at, {at.x + size, at.y + size}, ui.col(c), 2)
	im.DrawList_AddRect(dl, at, {at.x + size, at.y + size}, ui.col(ui.with_alpha(t.text, 0.25)), 2, 1)
}

// What track `i`'s MIDI input is, in a few words.
midi_in_text :: proc(a: ^App, i: int) -> string {
	mi := a.m.project.pads[i].midi_in
	switch mi.mode {
	case .All:  return "All MIDI"
	case .None: return "No MIDI"
	case .Port:
		name := port_name(a, mi.port, true)
		return name if mi.channel == 0 else fmt.tprintf("%s · ch %d", name, mi.channel)
	}
	return ""
}

// The name of MIDI port `id` (as the system calls it), or the id when it
// isn't there now.
port_name :: proc(a: ^App, id: string, input: bool) -> string {
	for p in app.host_midi_ports(&a.host, context.temp_allocator) do if p.id == id && (p.direction == .Input) == input do return p.name
	return id
}

// What track `i`'s audio input is: "In 1/2", "In 3 · Kick mic" (its
// alias, or the interface's name), "(not open)" when it isn't.
audio_in_text :: proc(a: ^App, i: int) -> string {
	in_ := a.m.project.pads[i].input
	switch in_.from {
	case .Interface:
	case .Pad:
		k := int(in_.source)
		name := pm.pad_name(&a.m.project.pads[k]) if k < pm.PADS else ""
		return fmt.tprintf("From %s", pm.pad_label(k)) if name == "" else fmt.tprintf("From %s · %s", pm.pad_label(k), name)
	case .Bus:  return fmt.tprintf("From %s", pm.bus_name(&a.m.project, int(in_.source) + 1))
	case .Main: return "Main mix"
	case .None: return "No input"
	}
	c := int(in_.channel)
	f := interface_find(&a.settings.audio, a.settings.audio.input)
	dev := find_device(&a.settings, a.settings.audio.input, false)
	text := pair_label(f, dev, false, c) if in_.stereo else channel_label(f, dev, false, c)
	if !pm.input_open(&a.m.engine, i) do text = fmt.tprintf("%s (not open)", text)
	return text
}

// The menu of track `i`'s MIDI inputs (inside an open popup or menu).
midi_in_items :: proc(a: ^App, i: int) {
	m := &a.m
	pad := m.project.pads[i]
	set :: proc(m: ^pm.Model, i: int, mi: pm.Midi_In) {
		p := m.project.pads[i]
		p.midi_in = mi
		pm.set_pad(m, i, .Midi_In, "MIDI In", p)
		app.seal(&m.history)
	}
	if im.MenuItem("All MIDI (the drum map)", nil, pad.midi_in.mode == .All) do set(m, i, {mode = .All})
	if im.MenuItem("No MIDI", nil, pad.midi_in.mode == .None) do set(m, i, {mode = .None})
	ports := app.host_midi_ports(&a.host, context.temp_allocator)
	any := false
	for p in ports do if p.direction == .Input {
		if !any do im.Separator()
		any = true
		here := pad.midi_in.mode == .Port && pad.midi_in.port == p.id
		if im.BeginMenu(fmt.ctprintf("%s%s###mip%s", p.name, "  ✓" if here else "", p.id)) {
			if im.MenuItem("Any channel", nil, here && pad.midi_in.channel == 0) do set(m, i, {mode = .Port, port = pm.intern(&m.project, p.id)})
			for ch in 1 ..= 16 do if im.MenuItem(fmt.ctprintf("Channel %d", ch), nil, here && int(pad.midi_in.channel) == ch) {
				set(m, i, {mode = .Port, port = pm.intern(&m.project, p.id), channel = u8(ch)})
			}
			im.EndMenu()
		}
	}
	if !any {
		im.Separator()
		im.TextDisabled("No MIDI inputs (Settings > MIDI)")
	}
}

// The menu of track `i`'s audio inputs: the interface's open channels
// (physical, by name), each pair whose both halves are open, and the one
// it has when that isn't open now; then, to resample, another track, a
// bus or main.
audio_in_items :: proc(a: ^App, i: int) {
	m := &a.m
	p := &m.project
	pad := p.pads[i]
	set :: proc(m: ^pm.Model, i: int, in_: pm.Audio_Input) {
		p := m.project.pads[i]
		p.input = in_
		pm.set_pad(m, i, .Input, "Set Input", p)
		app.seal(&m.history)
	}
	open := a.host.open_inputs
	here := pad.input.from == .Interface
	// None: it records (and monitors) nothing.
	if im.MenuItem("No input", nil, pad.input.from == .None) do set(m, i, {channel = pad.input.channel, stereo = pad.input.stereo, from = .None})
	im.Separator()
	if open == {} {
		im.TextDisabled("No inputs open (Settings > Audio)")
	} else {
		f := interface_find(&a.settings.audio, a.settings.audio.input)
		dev := find_device(&a.settings, a.settings.audio.input, false)
		for c in mask_pairs(open) do if im.MenuItem(fmt.ctprintf("%s (stereo)###ip%d", pair_label(f, dev, false, c), c), nil, here && pad.input.stereo && int(pad.input.channel) == c) do set(m, i, {channel = u8(c), stereo = true})
		im.Separator()
		for c in open do if im.MenuItem(fmt.ctprintf("%s###ic%d", channel_label(f, dev, false, c), c), nil, here && !pad.input.stereo && int(pad.input.channel) == c) do set(m, i, {channel = u8(c)})
		if here && !pm.input_open(&m.engine, i) {
			im.Separator()
			im.MenuItem(fmt.ctprintf("%s###icmissing", audio_in_text(a, i)), nil, true, false)
		}
	}
	// Resampling (an audio track's): what plays inside, lined up after its
	// effects' latency.
	if pad.kind != .Audio do return
	im.Separator()
	keep := pm.Audio_Input{channel = pad.input.channel, stereo = pad.input.stereo} // (the channels come back with the interface)
	if im.BeginMenu("From a track") {
		any := false
		for k in 0 ..< pm.PADS do if k != i && pm.pad_used(p, k) {
			any = true
			name := pm.pad_name(&p.pads[k])
			label := fmt.ctprintf("%s###it%d", pm.pad_label(k) if name == "" else fmt.tprintf("%s · %s", pm.pad_label(k), name), k)
			in_ := keep
			in_.from, in_.source = .Pad, u8(k)
			if im.MenuItem(label, nil, pad.input.from == .Pad && int(pad.input.source) == k) do set(m, i, in_)
		}
		if !any do im.TextDisabled("No other tracks")
		im.EndMenu()
	}
	if im.BeginMenu("From a bus") {
		for b in 0 ..< p.bus_count {
			in_ := keep
			in_.from, in_.source = .Bus, u8(b)
			if im.MenuItem(fmt.ctprintf("%s###ib%d", pm.bus_name(p, b + 1), b), nil, pad.input.from == .Bus && int(pad.input.source) == b) do set(m, i, in_)
		}
		im.EndMenu()
	}
	main := keep
	main.from = .Main
	if im.MenuItem("Main (resample)", nil, pad.input.from == .Main) do set(m, i, main)
}

// A horizontal input meter, `w` wide: the level of track `i`'s input
// (its louder side), green to red.
input_meter :: proc(a: ^App, i: int, w, h: f32) {
	level_bar(input_peak(a, i), w, h)
}

// The peak on pad `i`'s audio input now, as its source has it (an
// interface channel or pair; a pad's, a bus's or main's output; none:
// silence).
input_peak :: proc(a: ^App, i: int) -> (lvl: f32) {
	in_ := a.m.project.pads[i].input
	switch in_.from {
	case .Interface:
		// (Physical channels: their graph channels, through the host.)
		lvl = input_view(a, app.host_input_channel(&a.host, int(in_.channel))).peak
		if in_.stereo do lvl = max(lvl, input_view(a, app.host_input_channel(&a.host, int(in_.channel) + 1)).peak)
	case .Pad:
		// (The strips' meters, as read this frame.)
		if v := a.mixer.pads[min(int(in_.source), pm.PADS - 1)]; true do lvl = max(v[0].peak, v[1].peak)
	case .Bus:
		if v := a.mixer.buses[min(int(in_.source), pm.BUSES - 1)]; true do lvl = max(v[0].peak, v[1].peak)
	case .Main:
		v := a.mixer.buses[pm.BUSES]
		lvl = max(v[0].peak, v[1].peak)
	case .None:
	}
	return
}

// A level as a bar `w` by `h` at the cursor (-60..0 dB), and its item.
level_bar :: proc(peak: f32, w, h: f32) {
	t := ui.theme()
	dl := im.GetWindowDrawList()
	pos := im.GetCursorScreenPos()
	im.Dummy({w, h})
	im.DrawList_AddRectFilled(dl, pos, {pos.x + w, pos.y + h}, ui.col(ui.PLOT_BG), 2)
	db := 20 * math.log10(max(peak, 1e-6))
	f := clamp((db + 60) / 60, 0, 1)
	c := t.ok if db < -12 else (t.warn if db < -1 else t.danger)
	if f > 0 do im.DrawList_AddRectFilled(dl, pos, {pos.x + w * f, pos.y + h}, ui.col(c), 2)
}

// Track `i`'s ins and outs, for its device page: armed; its MIDI in (and
// light); its MIDI out's port; an audio track's input (and meter) and
// monitoring.
track_io_section :: proc(a: ^App, i: int) {
	m := &a.m
	pad := m.project.pads[i]
	dl := im.GetWindowDrawList()
	armed := pm.track_armed(m, i)
	if ui.toggle("Armed", &armed) do arm_click(a, i)
	if im.IsItemHovered() do im.SetTooltip("Armed, it records what comes in (and plays it): Cmd-click arms more than one")
	if pad.kind == .Audio {
		im.SameLine(0, 14)
		im.SetNextItemWidth(150)
		if ui.combo("##audioin", fmt.ctprintf("%s", audio_in_text(a, i))) {
			audio_in_items(a, i)
			im.EndCombo()
		}
		im.SameLine(0, 8)
		input_meter(a, i, 90, 8)
		return
	}
	im.SameLine(0, 14)
	im.SetNextItemWidth(170)
	if ui.combo("##midiin", fmt.ctprintf("%s  %s", ui.ICON_MUSIC, midi_in_text(a, i))) {
		midi_in_items(a, i)
		im.EndCombo()
	}
	if im.IsItemHovered() do im.SetTooltip("Its MIDI in: All MIDI plays it by the drum map; a port of its own plays it chromatically while it is armed")
	im.SameLine(0, 6)
	at := im.GetCursorScreenPos()
	im.Dummy({12, im.GetFrameHeight()})
	midi_light(dl, {at.x, at.y + (im.GetFrameHeight() - 12) / 2}, 12, a.io.in_lit[i], a.io.out_lit[i])
}

// Track `i`'s MIDI out port (a combo `w` wide).
midi_out_port_combo :: proc(a: ^App, i: int, w: f32) {
	m := &a.m
	pad := m.project.pads[i]
	name := "Default output" if pad.midi_out.port == "" else port_name(a, pad.midi_out.port, false)
	im.SetNextItemWidth(w)
	if ui.combo("##midioutport", fmt.ctprintf("%s", name)) {
		set :: proc(m: ^pm.Model, i: int, port: string) {
			p := m.project.pads[i]
			p.midi_out.port = pm.intern(&m.project, port)
			pm.set_pad(m, i, .Midi_Out, "MIDI Out Port", p)
			app.seal(&m.history)
		}
		if im.Selectable("Default output (Settings)", pad.midi_out.port == "") do set(m, i, "")
		for p in app.host_midi_ports(&a.host, context.temp_allocator) do if p.direction == .Output {
			if im.Selectable(fmt.ctprintf("%s###mop%s", p.name, p.id), p.id == pad.midi_out.port) do set(m, i, p.id)
		}
		im.EndCombo()
	}
}
