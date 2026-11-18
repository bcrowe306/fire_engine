// Mix on a controller's display (Push 2's): the window's mixer strips for
// eight pads (the selected pad's eight), or the buses with Main at the far
// right; the encoders on what the upper row's first button chose (each
// press the next: volume, pan, a send a bus, audio in, monitoring, output,
// MIDI in and out); the lower row selects, or mutes, solos or arms while
// those are held (ui_ctl.odin's layout).
package pads

import "core:fmt"
import "core:math"

import app "app:core"
import "app:ui"
import pa "api"
import pm "model"
import im "deps:imgui"

// Mix's own state on the controller.
Ctl_Mix :: struct {
	page:      int,  // in the pages list (the pads' or the buses')
	buses:     bool, // the buses (and Main) shown, not the pads
	bus_first: int,  // the buses' first shown (seven at a time; Main the last strip)
	held:      bit_set[Ctl_Mod],
	arm_used:  bool,    // the lower row pressed while Arm was held (its release arms nothing)
	gesture:   [8]bool, // an encoder's edit open: one undo step a touch
	reset:     [8]bool, // Delete held: the knob touched already reset
}

// What a controller holds down: Mix's lower row mutes, solos or arms
// while one is held; Shift steps the pages back; Delete resets a knob
// touched.
Ctl_Mod :: enum {
	Mute,
	Solo,
	Arm,
	Shift,
	Delete,
}

// What Mix's encoders change.
Mix_Kind :: enum {
	Volume,
	Pan,
	Send,
	Cue, // the strip's send to the cue (headphones) mix; the lower row: pre or post
	Audio_In,
	Monitor,
	Output,
	Midi_In,
	Midi_Out,
}

// A page of Mix: what its encoders change (a send: to bus `bus`, 1..).
Mix_Page :: struct {
	kind: Mix_Kind,
	bus:  int,
}

// The pages Mix steps through: the pads' (a send to each bus there is),
// or the buses'.
@(private)
mix_pages :: proc(a: ^App, buses: bool) -> []Mix_Page {
	out := make([dynamic]Mix_Page, context.temp_allocator)
	append(&out, Mix_Page{kind = .Volume}, Mix_Page{kind = .Pan})
	if buses {
		append(&out, Mix_Page{kind = .Cue}, Mix_Page{kind = .Output})
		return out[:]
	}
	for b in 1 ..= a.m.project.bus_count do append(&out, Mix_Page{kind = .Send, bus = b})
	append(&out, Mix_Page{kind = .Cue})
	for k in ([]Mix_Kind{.Audio_In, .Monitor, .Output, .Midi_In, .Midi_Out}) do append(&out, Mix_Page{kind = k})
	return out[:]
}

// A page's name ("Send A", or the bus's own).
@(private)
mix_page_name :: proc(a: ^App, pg: Mix_Page) -> string {
	switch pg.kind {
	case .Volume:   return "Volume"
	case .Pan:      return "Pan"
	case .Send:
		name := pm.bus_name(&a.m.project, pg.bus)
		letters := "ABCDEFGHIJKLMNOP"
		if name == fmt.tprintf("Bus %s", letters[pg.bus - 1:][:1]) do name = letters[pg.bus - 1:][:1] // (unnamed: its letter)
		return fmt.tprintf("Send %s", name)
	case .Cue:      return "Cue"
	case .Audio_In: return "Audio In"
	case .Monitor:  return "Monitor"
	case .Output:   return "Output"
	case .Midi_In:  return "MIDI In"
	case .Midi_Out: return "MIDI Out"
	}
	return ""
}

// A strip: a pad's, a bus's, or Main's.
@(private)
Mix_Strip :: struct {
	pad:      int, // -1: a bus
	bus:      int, // a bus's index (0..BUSES-1; BUSES: Main)
	name:     string,
	color:    ui.Color,
	used:     bool,
	volume:   f32,
	pan:      f32,
	mute:     bool,
	solo:     bool,
	armed:    bool,
	selected: bool,
	view:     ^[2]Meter_View,
}

// A routing page's choice: what it sets.
@(private)
Mix_Value :: union {
	pm.Audio_Input,
	pm.Monitor,
	int, // an output (0 main, 1.. a bus, a direct out)
	pm.Midi_In,
	pm.Midi_Out,
}

// The view: the upper row (the page, Arm, Buses), eight strips, the lower
// row their names. Its own buttons and modifiers come as View_Buttons.
ctl_mixer :: proc(ctx: ^View_Ctx, full: im.Vec2) {
	a := ctx.a
	m := &a.m
	p := &m.project
	mx := &a.ctl.mix
	inp := ctx.input
	pressed := proc(inp: ^pa.View_Input, b: pa.View_Button) -> bool { return inp != nil && inp.pressed[int(b)] }
	released := proc(inp: ^pa.View_Input, b: pa.View_Button) -> bool { return inp != nil && inp.released[int(b)] }
	// What's held.
	mods := [Ctl_Mod]pa.View_Button{.Mute = .Mute, .Solo = .Solo, .Arm = .Upper_2, .Shift = .Shift, .Delete = .Delete}
	for b, k in mods {
		if pressed(inp, b) {
			mx.held += {k}
			if k == .Arm do mx.arm_used = false
		}
		if released(inp, b) {
			mx.held -= {k}
			// Arm pressed and let go (no strip armed meanwhile): the selected pad's.
			if k == .Arm && !mx.arm_used && !mx.buses do arm_click(a, a.selected)
		}
	}
	if mx.buses do mx.held -= {.Arm}
	// The upper row: the page (Shift: the one before), the pads or the buses.
	if pressed(inp, .Upper_8) {
		mx.buses = !mx.buses
		mx.page = 0
	}
	pages := mix_pages(a, mx.buses)
	if pressed(inp, .Upper_1) do mx.page += -1 if .Shift in mx.held else 1
	mx.page = (mx.page % len(pages) + len(pages)) % len(pages)
	page := pages[mx.page]
	// The strips.
	strips: [8]Mix_Strip
	shown: [8]bool
	first := a.selected / 8 * 8
	if mx.buses {
		mx.bus_first = clamp(mx.bus_first, 0, max(p.bus_count - 1, 0))
		if pressed(inp, .Page_Left) do mx.bus_first = max(mx.bus_first - 7, 0)
		if pressed(inp, .Page_Right) && mx.bus_first + 7 < p.bus_count do mx.bus_first += 7
		for k in 0 ..< 7 do if b := mx.bus_first + k; b < p.bus_count {
			strips[k] = bus_strip_of(a, b)
			shown[k] = true
		}
		strips[7] = bus_strip_of(a, pm.BUSES)
		shown[7] = true
		ctx.pages = max((p.bus_count + 6) / 7, 1)
		ctx.page = mx.bus_first / 7
	} else {
		if pressed(inp, .Page_Left) && a.selected >= 8 do pa.perform_select_pad(&a.api, i64(a.selected - 8))
		if pressed(inp, .Page_Right) && a.selected + 8 < pm.PADS do pa.perform_select_pad(&a.api, i64(a.selected + 8))
		for k in 0 ..< 8 do if i := first + k; i < pm.PADS {
			pad := p.pads[i]
			strips[k] = {pad = i, name = fmt.tprintf("%s %s", pm.pad_label(i), pm.pad_name(&p.pads[i])) if pm.pad_used(p, i) else pm.pad_label(i), color = ui.rgb(pad.color), used = pm.pad_used(p, i), volume = pad.volume, pan = pad.pan, mute = pad.mute, solo = pad.solo, armed = pm.track_armed(m, i), selected = i == a.selected, view = &a.mixer.pads[i]}
			shown[k] = true
		}
		ctx.pages = pm.PADS / 8
		ctx.page = first / 8
	}
	// The upper row.
	ctl_upper(ctx, 0, fmt.tprintf("%s ›", mix_page_name(a, page)), true)
	if !mx.buses do ctl_upper(ctx, 1, "Arm", pm.track_armed(m, a.selected) || .Arm in mx.held, ui.theme().danger)
	ctl_upper(ctx, 7, "Buses", mx.buses)
	// Each strip, its encoder and its lower button.
	for k in 0 ..< 8 {
		ki := ui.knob_input
		if !shown[k] {
			if ki != nil do ki.turn[k] = 0
			continue
		}
		s := strips[k]
		held := ki != nil && ki.held[k]
		choice := mix_strip(ctx, k, s, page, held, full)
		if ki != nil do mix_encoder(a, ctx, k, s, page, choice)
		// The lower row: select, or mute, solo or arm while held.
		b := pa.View_Button(k)
		on := s.selected
		switch {
		case .Mute in mx.held: on = s.mute
		case .Solo in mx.held: on = s.solo
		case .Arm in mx.held:  on = s.armed
		}
		if page.kind == .Cue && mx.held == {} { // (the Cue page: pre or post)
			on = cue_of(a, s).pre
		}
		offered := s.pad >= 0 || .Mute in mx.held || (.Solo in mx.held && s.bus < pm.BUSES) || page.kind == .Cue
		if offered do ctx.buttons |= 1 << uint(b)
		if offered && on do ctx.lit |= 1 << uint(b)
		if !pressed(inp, b) do continue
		switch {
		case .Mute in mx.held:
			if s.pad >= 0 do pa.pad_set_mute(&a.api, i64(s.pad), !s.mute)
			else do pa.mixer_set_bus_mute(&a.api, i64(s.bus), !s.mute)
		case .Solo in mx.held:
			if s.pad >= 0 do pa.pad_set_solo(&a.api, i64(s.pad), !s.solo)
			else if s.bus < pm.BUSES do pa.mixer_set_bus_solo(&a.api, i64(s.bus), !s.solo)
		case .Arm in mx.held:
			if s.pad >= 0 {
				arm_click(a, s.pad)
				mx.arm_used = true
			}
		case page.kind == .Cue:
			c := cue_of(a, s)
			set_cue(a, s, pm.send_db(c) if c.level > 0 else pm.SEND_MIN_DB, !c.pre)
		case:
			if s.pad >= 0 do pa.perform_select_pad(&a.api, i64(s.pad))
		}
	}
	ui.knob_input.drawn = 8
}

// Bus `b`'s strip (BUSES: Main's).
@(private)
bus_strip_of :: proc(a: ^App, b: int) -> Mix_Strip {
	bus := pm.bus_of(&a.m, b)
	t := ui.theme()
	c := t.accent if b >= pm.BUSES else ui.mix(t.accent, t.text_dim, 0.55)
	return {pad = -1, bus = b, name = pm.bus_index_name(&a.m.project, b), color = c, used = true, volume = bus.volume, pan = bus.pan, mute = bus.mute, solo = bus.solo, view = &a.mixer.buses[b]}
}

// Upper button `k`: `label`, lit when `on` (its underline `lit`: the accent).
@(private)
ctl_upper :: proc(ctx: ^View_Ctx, k: int, label: string, on: bool, lit: ui.Color = {}) {
	t := ui.theme()
	dl := im.GetWindowDrawList()
	o := im.GetWindowPos()
	x0 := o.x + f32(k * CTL_COL) + 4
	x1 := x0 + CTL_COL - 8
	if on {
		im.DrawList_AddRectFilled(dl, {x0, o.y + 2}, {x1, o.y + CTL_TABS_H - 2}, ui.col(t.raised), t.radius)
		im.DrawList_AddLine(dl, {x0 + 6, o.y + CTL_TABS_H - 2}, {x1 - 6, o.y + CTL_TABS_H - 2}, ui.col(lit if lit != {} else t.accent), 2)
	}
	ui.text_push(.Label)
	text_in(dl, {x0, o.y}, {x1, o.y + CTL_TABS_H}, label, t.text if on else t.text_dim)
	ui.text_pop()
	b := int(pa.View_Button.Upper_1) + k
	ctx.buttons |= 1 << uint(b)
	if on do ctx.lit |= 1 << uint(b)
}

// A routing page's choices for a strip: their names, what each sets, and
// the one it has (-1: none of them).
@(private)
mix_choices :: proc(a: ^App, s: Mix_Strip, kind: Mix_Kind) -> (names: [dynamic]string, values: [dynamic]Mix_Value, cur: int) {
	m := &a.m
	p := &m.project
	names = make([dynamic]string, context.temp_allocator)
	values = make([dynamic]Mix_Value, context.temp_allocator)
	cur = -1
	add :: proc(names: ^[dynamic]string, values: ^[dynamic]Mix_Value, name: string, v: Mix_Value) {
		append(names, name)
		append(values, v)
	}
	if s.pad < 0 {
		// A bus: where it goes (Main: the interface).
		if kind != .Output || s.bus >= pm.BUSES do return
		here := int(p.buses[s.bus].dest)
		for d in 0 ..= p.bus_count do if d != s.bus + 1 && pm.bus_dest_ok(p, s.bus + 1, d) {
			if d == here do cur = len(names)
			add(&names, &values, pm.bus_name(p, d), d)
		}
		mix_direct_outs(a, &names, &values, here, &cur)
		return
	}
	i := s.pad
	pad := p.pads[i]
	switch kind {
	case .Volume, .Pan, .Send, .Cue:
	case .Audio_In:
		x := pad.input
		pick :: proc(names: ^[dynamic]string, values: ^[dynamic]Mix_Value, cur: ^int, here: pm.Audio_Input, name: string, v: pm.Audio_Input) {
			if same_input(here, v) do cur^ = len(names)
			append(names, name)
			append(values, v)
		}
		pick(&names, &values, &cur, x, "No input", {from = .None, channel = x.channel, stereo = x.stereo})
		open := a.host.open_inputs
		f := interface_find(&a.settings.audio, a.settings.audio.input)
		dev := find_device(&a.settings, a.settings.audio.input, false)
		for c in mask_pairs(open) do pick(&names, &values, &cur, x, pair_label(f, dev, false, c), {channel = u8(c), stereo = true})
		for c in open do pick(&names, &values, &cur, x, channel_label(f, dev, false, c), {channel = u8(c)})
		if cur < 0 && x.from == .Interface do pick(&names, &values, &cur, x, audio_in_text(a, i), x)
		if pad.kind == .Audio {
			keep := pm.Audio_Input{channel = x.channel, stereo = x.stereo}
			for k in 0 ..< pm.PADS do if k != i && pm.pad_used(p, k) {
				v := keep
				v.from, v.source = .Pad, u8(k)
				pick(&names, &values, &cur, x, fmt.tprintf("From %s", pm.pad_label(k)), v)
			}
			for b in 0 ..< p.bus_count {
				v := keep
				v.from, v.source = .Bus, u8(b)
				pick(&names, &values, &cur, x, fmt.tprintf("From %s", pm.bus_name(p, b + 1)), v)
			}
			v := keep
			v.from = .Main
			pick(&names, &values, &cur, x, "Main (resample)", v)
		}
	case .Monitor:
		if pad.input.from != .Interface do return // (resampling, or none: nothing to monitor)
		NAMES := [pm.Monitor]string{.Auto = "Auto", .In = "In", .Off = "Off"}
		for mo in pm.Monitor {
			if mo == pad.monitor do cur = len(names)
			add(&names, &values, NAMES[mo], mo)
		}
	case .Output:
		here := int(pad.bus)
		for d in 0 ..= p.bus_count {
			if d == here do cur = len(names)
			add(&names, &values, pm.bus_name(p, d), d)
		}
		mix_direct_outs(a, &names, &values, here, &cur)
	case .Midi_In:
		mi := pad.midi_in
		if mi.mode == .All do cur = len(names)
		add(&names, &values, "All MIDI", pm.Midi_In{mode = .All})
		if mi.mode == .None do cur = len(names)
		add(&names, &values, "No MIDI", pm.Midi_In{mode = .None})
		for port in app.host_midi_ports(&a.host, context.temp_allocator) do if port.direction == .Input {
			for ch in 0 ..= 16 {
				if mi.mode == .Port && mi.port == port.id && int(mi.channel) == ch do cur = len(names)
				name := port.name if ch == 0 else fmt.tprintf("%s · ch %d", port.name, ch)
				add(&names, &values, name, pm.Midi_In{mode = .Port, port = port.id, channel = u8(ch)})
			}
		}
	case .Midi_Out:
		out := pad.midi_out
		off := out
		off.on = false
		if !out.on do cur = len(names)
		add(&names, &values, "No MIDI out", off)
		on := out
		on.on, on.port = true, ""
		if on.key == 0 do on.key = u8(pm.pad_key(i))
		if out.on && out.port == "" do cur = len(names)
		add(&names, &values, "Default out", on)
		for port in app.host_midi_ports(&a.host, context.temp_allocator) do if port.direction == .Output {
			v := on
			v.port = port.id
			if out.on && out.port == port.id do cur = len(names)
			add(&names, &values, fmt.tprintf("%s · %d", port.name, out.channel + 1), v)
		}
	}
	return
}

// The interface's output pairs (not main's or the cue's) as routes, and
// the route `here` when it is a pair not open now.
@(private)
mix_direct_outs :: proc(a: ^App, names: ^[dynamic]string, values: ^[dynamic]Mix_Value, here: int, cur: ^int) {
	f, dev := output_interface(a)
	main_first, cue_first := 0, -1
	if f != nil do main_first, cue_first = f.main, f.cue
	for pr in mask_pairs(a.host.open_outputs) do if pr != main_first && pr != cue_first {
		d := pm.out_dest(pr / 2)
		if d == here do cur^ = len(names)
		append(names, pair_label(f, dev, true, pr))
		append(values, d)
	}
	if cur^ < 0 && pm.is_out_dest(here) {
		cur^ = len(names)
		append(names, route_name(a, here))
		append(values, here)
	}
}

// A routing choice made: set, undoably (one step a touch).
@(private)
mix_apply :: proc(a: ^App, s: Mix_Strip, v: Mix_Value) {
	m := &a.m
	switch x in v {
	case pm.Audio_Input:
		pa.pad_set_input(&a.api, i64(s.pad), {from = pa.Input_From(x.from), channel = i64(x.channel), stereo = x.stereo, source = i64(x.source)})
	case pm.Monitor:
		pa.pad_set_monitor(&a.api, i64(s.pad), pa.Monitor(x))
	case int:
		if s.pad >= 0 do pa.mixer_set_pad_output(&a.api, i64(s.pad), dest_output(x))
		else do pa.mixer_set_bus_output(&a.api, i64(s.bus), dest_output(x))
	case pm.Midi_In:
		port := pm.intern(&m.project, x.port) if x.port != "" else ""
		pa.midi_set_pad_input(&a.api, i64(s.pad), pa.Midi_In_Mode(x.mode), port, i64(x.channel))
	case pm.Midi_Out:
		port := pm.intern(&m.project, x.port) if x.port != "" else ""
		pa.midi_set_pad_output(&a.api, i64(s.pad), x.on, i64(x.channel), i64(x.key), port)
	}
}

// Strip `k`: its readouts (or a routing page's choice, its list open
// while its encoder is held), its fader filled in its colour beside the
// dB scale and the meter, its pan (a send page: the send), mute, solo and
// arm, its name plate. The choice the page shows, if it is a routing one.
@(private)
mix_strip :: proc(ctx: ^View_Ctx, k: int, s: Mix_Strip, page: Mix_Page, held: bool, full: im.Vec2) -> (choice: Mix_Choice) {
	a := ctx.a
	t := ui.theme()
	dl := im.GetWindowDrawList()
	o := im.GetWindowPos()
	top := o.y + CTL_PLOT_Y
	bottom := o.y + full.y - CTL_BUTTONS_H - 2
	x0 := o.x + f32(k * CTL_COL) + 3
	x1 := x0 + CTL_COL - 6
	color := s.color
	bg := ui.mix(t.surface, t.raised, 0.55)
	if held do bg = ui.mix(bg, color, 0.18)
	im.DrawList_AddRectFilled(dl, {x0, top}, {x1, bottom}, ui.col(bg), t.radius)
	if s.selected do im.DrawList_AddRect(dl, {x0, top}, {x1, bottom}, ui.col(color), t.radius, 1.5)
	fill := color if s.used else ui.mix(t.text_dim, bg, 0.4)
	send: pm.Send
	if page.kind == .Send && s.pad >= 0 do send = a.m.project.pads[s.pad].sends[page.bus - 1]
	routing := page.kind > .Cue
	cue: pm.Send // (the Cue page: the strip's cue send)
	if page.kind == .Cue do cue = a.m.project.pads[s.pad].cue if s.pad >= 0 else pm.bus_of(&a.m, s.bus).cue
	ui.text_push(.Label)
	// The readouts: the page's value, the peak since reset; a routing
	// page: its choice.
	if routing {
		choice.names, choice.values, choice.cur = mix_choices(a, s, page.kind)
		lo, hi := im.Vec2{x0 + 4, top + 4}, im.Vec2{x1 - 4, top + 20}
		im.DrawList_AddRectFilled(dl, lo, hi, ui.col(t.raised if held else well(t)), 3)
		text := choice.names[choice.cur] if choice.cur >= 0 else "—"
		im.DrawList_PushClipRect(dl, {lo.x + 3, lo.y}, {hi.x - 3, hi.y}, true)
		text_in(dl, lo, hi, text, t.text if len(choice.names) > 0 else t.text_dim)
		im.DrawList_PopClipRect(dl)
	} else {
		rw := (x1 - x0 - 11) / 2
		for r in 0 ..< 2 {
			lo := im.Vec2{x0 + 4 + f32(r) * (rw + 3), top + 4}
			hi := im.Vec2{lo.x + rw, lo.y + 16}
			im.DrawList_AddRectFilled(dl, lo, hi, ui.col(well(t)), 3)
			if r == 0 {
				text: string
				switch page.kind {
				case .Pan:  text = strip_pan_text(s.pan)
				case .Send: text = "off" if send.level <= 0 else fmt.tprintf("%.1f", pm.send_db(send))
				case .Cue:  text = "off" if cue.level <= 0 else fmt.tprintf("%.1f", pm.send_db(cue))
				case .Volume, .Audio_In, .Monitor, .Output, .Midi_In, .Midi_Out:
					text = "-inf" if s.volume <= FADER_LO else fmt.tprintf("%.1f", s.volume)
				}
				text_in(dl, lo, hi, text, t.text)
			} else if page.kind == .Cue {
				pre := cue.pre
				im.DrawList_AddRectFilled(dl, lo, hi, ui.col(ui.with_alpha(t.accent, 0.8) if pre else well(t)), 3)
				text_in(dl, lo, hi, "pre" if pre else "post", t.bg if pre else t.text_dim)
			} else {
				pk := max(s.view[0].max, s.view[1].max)
				db := 20 * math.log10(pk) if pk > 0 else -math.F32_MAX
				if db > 0 do im.DrawList_AddRectFilled(dl, lo, hi, ui.col(t.danger), 3)
				text_in(dl, lo, hi, "-inf" if db < -60 else fmt.tprintf("%.1f", db), t.bg if db > 0 else t.text_dim)
			}
		}
	}
	// The fader, filled in its colour to the cap; the scale; the meter.
	ft, fb := top + 28, bottom - 6
	y_of :: proc(frac, top, bottom: f32) -> f32 { return bottom - (bottom - top) * frac }
	fx := x0 + 8
	fw: f32 = 16
	cx := fx + fw / 2
	active := page.kind == .Volume
	y := y_of(fader_frac(s.volume), ft, fb)
	im.DrawList_AddRectFilled(dl, {cx - 2, ft}, {cx + 2, fb}, ui.col(well(t)), 2)
	im.DrawList_AddRectFilled(dl, {cx - 2, y}, {cx + 2, fb}, ui.col(ui.with_alpha(fill, 0.9)), 2)
	im.DrawList_AddRectFilled(dl, {fx, y - 6}, {fx + fw, y + 6}, ui.col(fill if active else ui.mix(fill, t.pressed, 0.45)), 3)
	im.DrawList_AddLine(dl, {fx + 3, y}, {fx + fw - 3, y}, ui.col(t.bg if active else t.text), 1.5)
	sx := fx + fw + 1
	sw: f32 = 18
	mw: f32 = 4
	last := -max(f32)
	for db in ([]f32{6, 0, -12, -40}) {
		yy := y_of(fader_frac(db), ft, fb)
		label := fmt.ctprintf("+%d" if db > 0 else "%d", int(abs(db)))
		ts := im.CalcTextSize(label)
		if yy - last < ts.y do continue
		last = yy
		im.DrawList_AddText(dl, {sx + sw - ts.x - 2, yy - ts.y / 2}, ui.col(ui.with_alpha(t.text_dim, 0.8)), label)
		im.DrawList_AddLine(dl, {sx + sw - 1, yy}, {sx + sw + 2 * mw + 2, yy}, ui.col(ui.with_alpha(t.border, 0.6)), 1)
	}
	meter_bars(a, dl, s.view, sx + sw, ft, fb, mw)
	// At the right: its pan (a send page: the send's level), then mute,
	// solo and arm.
	rx := sx + sw + 2 * mw + 6
	r: f32 = 12
	c := im.Vec2{(rx + x1) / 2, ft + r + 2}
	a0 := f32(math.PI) * 0.75
	sweep := f32(math.PI) * 1.5
	im.DrawList_AddCircleFilled(dl, c, r - 3, ui.col(t.raised), 24)
	im.DrawList_PathArcTo(dl, c, r, a0, a0 + sweep, 24)
	im.DrawList_PathStroke(dl, ui.col(well(t)), 3)
	under: string
	if page.kind == .Send {
		frac := clamp((pm.send_db(send) - pm.SEND_MIN_DB) / (6 - pm.SEND_MIN_DB), 0, 1) if send.level > 0 else 0
		at := a0 + sweep * frac
		if send.level > 0 {
			im.DrawList_PathArcTo(dl, c, r, a0, at, 24)
			im.DrawList_PathStroke(dl, ui.col(t.warn if send.pre else fill), 3)
		}
		im.DrawList_AddLine(dl, c, {c.x + math.cos(at) * (r - 2), c.y + math.sin(at) * (r - 2)}, ui.col(t.text), 1.5)
		letters := "ABCDEFGHIJKLMNOP"
		under = letters[page.bus - 1:][:1]
	} else {
		up := a0 + sweep / 2
		at := up + s.pan * sweep / 2
		if abs(s.pan) > 0.005 {
			im.DrawList_PathArcTo(dl, c, r, min(up, at), max(up, at), 16)
			im.DrawList_PathStroke(dl, ui.col(fill), 3)
		}
		im.DrawList_AddLine(dl, c, {c.x + math.cos(at) * (r - 2), c.y + math.sin(at) * (r - 2)}, ui.col(t.text), 1.5)
		under = strip_pan_text(s.pan)
	}
	text_in(dl, {rx, c.y + r}, {x1 - 2, c.y + r + 14}, under, t.text if page.kind == .Pan || page.kind == .Send else t.text_dim)
	{
		letters := [3]string{"M", "S", "R"}
		ons := [3]bool{s.mute, s.solo, s.armed}
		colors := [3]ui.Color{t.warn, ui.rgb(0x3d9cf5), t.danger} // (mute yellow, solo blue, arm red: the window's)
		n := 3 if s.pad >= 0 else (2 if s.bus < pm.BUSES else 1)
		bw := (x1 - rx - 2 - 2 * f32(n - 1)) / f32(n)
		by := c.y + r + 18
		for b in 0 ..< n {
			lo := im.Vec2{rx + f32(b) * (bw + 2), by}
			hi := im.Vec2{lo.x + bw, by + 16}
			im.DrawList_AddRectFilled(dl, lo, hi, ui.col(colors[b] if ons[b] else well(t)), 3)
			text_in(dl, lo, hi, letters[b], t.bg if ons[b] else t.text_dim)
		}
	}
	// A routing page's list, open over the strip while its encoder is held.
	if routing && held && len(choice.names) > 0 {
		fg := im.GetForegroundDrawList()
		rows := min(len(choice.names), 5)
		cur := max(choice.cur, 0)
		first := clamp(cur - rows / 2, 0, len(choice.names) - rows)
		rh := im.GetTextLineHeight() + 4
		ly0 := top + 22
		ly1 := ly0 + f32(rows) * rh + 4
		im.DrawList_AddRectFilled(fg, {x0 + 2, ly0}, {x1 - 2, ly1}, ui.col(t.bg), t.radius)
		im.DrawList_AddRect(fg, {x0 + 2, ly0}, {x1 - 2, ly1}, ui.col(t.border), t.radius)
		for n in 0 ..< rows {
			idx := first + n
			ry := ly0 + 2 + f32(n) * rh
			if idx == choice.cur do im.DrawList_AddRectFilled(fg, {x0 + 4, ry}, {x1 - 4, ry + rh}, ui.col(t.accent), 3)
			im.DrawList_PushClipRect(fg, {x0 + 6, ry}, {x1 - 6, ry + rh}, true)
			im.DrawList_AddText(fg, {x0 + 8, ry + 2}, ui.col(t.bg if idx == choice.cur else t.text), fmt.ctprintf("%s", choice.names[idx]))
			im.DrawList_PopClipRect(fg)
		}
	}
	ui.text_pop()
	// Its name plate, in its colour (dark or light text for it).
	py0, py1 := o.y + full.y - CTL_BUTTONS_H, o.y + full.y - 2
	plate := color if s.used else ui.mix(t.raised, color, 0.3)
	im.DrawList_AddRectFilled(dl, {x0, py0}, {x1, py1}, ui.col(plate), t.radius)
	if s.selected do im.DrawList_AddRect(dl, {x0 - 1, py0 - 1}, {x1 + 1, py1 + 1}, ui.col(t.text), t.radius, 1.5)
	lum := 0.3 * plate.r + 0.59 * plate.g + 0.11 * plate.b
	im.DrawList_PushClipRect(dl, {x0 + 3, py0}, {x1 - 3, py1}, true)
	ui.text_push(.Label)
	text_in(dl, {x0 + 3, py0}, {x1 - 3, py1}, s.name, ui.rgb(0x111214) if lum > 0.55 else ui.rgb(0xffffff))
	ui.text_pop()
	im.DrawList_PopClipRect(dl)
	return
}

// A routing page's choices for a strip, as drawn.
@(private)
Mix_Choice :: struct {
	names:  [dynamic]string,
	values: [dynamic]Mix_Value,
	cur:    int,
}

// Encoder `k` on strip `s`: the page's value (a gesture a touch: one undo
// step), Delete held and touched: back to its default; a routing page: a
// step through its choices each three detents.
@(private)
mix_encoder :: proc(a: ^App, ctx: ^View_Ctx, k: int, s: Mix_Strip, page: Mix_Page, choice: Mix_Choice) {
	ki := ui.knob_input
	mx := &a.ctl.mix
	m := &a.m
	if !ki.held[k] do mx.reset[k] = false
	set_volume :: proc(a: ^App, s: Mix_Strip, db: f32) {
		v := clamp(db, FADER_LO, FADER_HI)
		if s.pad >= 0 do pa.pad_set_volume(&a.api, i64(s.pad), v)
		else do pa.mixer_set_bus_volume(&a.api, i64(s.bus), v)
	}
	set_pan :: proc(a: ^App, s: Mix_Strip, pan: f32) {
		v := clamp(pan, -1, 1)
		if s.pad >= 0 do pa.pad_set_pan(&a.api, i64(s.pad), v)
		else do pa.mixer_set_bus_pan(&a.api, i64(s.bus), v)
	}
	begin :: proc(a: ^App, k: int) {
		if !a.ctl.mix.gesture[k] {
			pa.history_gesture_begin(&a.api)
			a.ctl.mix.gesture[k] = true
		}
	}
	// Delete held: a touch resets it.
	if .Delete in mx.held && ki.held[k] && !mx.reset[k] {
		mx.reset[k] = true
		ki.turn[k] = 0
		#partial switch page.kind {
		case .Volume: set_volume(a, s, 0)
		case .Pan:    set_pan(a, s, 0)
		case .Send:   if s.pad >= 0 do pm.set_send_db(m, s.pad, page.bus, pm.SEND_MIN_DB)
		case .Cue:    set_cue(a, s, pm.SEND_MIN_DB, cue_of(a, s).pre)
		}
		app.seal(&m.history)
		return
	}
	switch page.kind {
	case .Volume:
		if d := ki.turn[k]; d != 0 {
			ki.turn[k] = 0
			begin(a, k)
			set_volume(a, s, fader_db(fader_frac(s.volume) + f32(d)))
		}
	case .Pan:
		if d := ki.turn[k]; d != 0 {
			ki.turn[k] = 0
			begin(a, k)
			set_pan(a, s, s.pan + f32(d) * 2)
		}
	case .Send:
		if d := ki.turn[k]; d != 0 && s.pad >= 0 {
			ki.turn[k] = 0
			send := m.project.pads[s.pad].sends[page.bus - 1]
			db := pm.send_db(send) if send.level > 0 else pm.SEND_MIN_DB
			pm.set_send_db(m, s.pad, page.bus, clamp(db + f32(d) * (6 - pm.SEND_MIN_DB), pm.SEND_MIN_DB, 6))
		}
	case .Cue:
		if d := ki.turn[k]; d != 0 {
			ki.turn[k] = 0
			begin(a, k)
			c := cue_of(a, s)
			db := pm.send_db(c) if c.level > 0 else pm.SEND_MIN_DB
			set_cue(a, s, clamp(db + f32(d) * (6 - pm.SEND_MIN_DB), pm.SEND_MIN_DB, 6), c.pre)
		}
	case .Audio_In, .Monitor, .Output, .Midi_In, .Midi_Out:
		if steps := int(ki.turn[k] / CTL_STEP); steps != 0 {
			ki.turn[k] -= f64(steps) * CTL_STEP
			if len(choice.names) > 0 {
				to := clamp(max(choice.cur, 0) + steps, 0, len(choice.names) - 1)
				if to != choice.cur {
					begin(a, k)
					mix_apply(a, s, choice.values[to])
				}
			}
		}
	}
	if ki.ended[k] {
		ki.ended[k] = false
		if mx.gesture[k] {
			pa.history_gesture_end(&a.api)
			mx.gesture[k] = false
		}
		app.seal(&m.history)
	}
}

// Whether two audio inputs are the same choice.
@(private)
same_input :: proc(x, y: pm.Audio_Input) -> bool {
	if x.from != y.from do return false
	#partial switch x.from {
	case .Interface: return x.channel == y.channel && x.stereo == y.stereo
	case .Pad, .Bus: return x.source == y.source
	}
	return true
}

// A pan as the window's strips write it: C, L50, R20.
@(private)
strip_pan_text :: proc(pan: f32) -> string {
	if pan < -0.005 do return fmt.tprintf("L%.0f", -pan * 100)
	if pan > 0.005 do return fmt.tprintf("R%.0f", pan * 100)
	return "C"
}

// Strip `s`'s cue send.
@(private)
cue_of :: proc(a: ^App, s: Mix_Strip) -> pm.Send {
	return a.m.project.pads[s.pad].cue if s.pad >= 0 else pm.bus_of(&a.m, s.bus).cue
}

// Sets strip `s`'s cue send: `db` (SEND_MIN_DB: off), before or after its
// fader.
@(private)
set_cue :: proc(a: ^App, s: Mix_Strip, db: f32, pre: bool) {
	if s.pad >= 0 do pa.mixer_set_pad_cue(&a.api, i64(s.pad), db, pre)
	else do pa.mixer_set_bus_cue(&a.api, i64(s.bus), db, pre)
}
