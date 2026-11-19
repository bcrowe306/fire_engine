// Pads' Settings on a controller's display (Push 2's Setup): what a
// headless Pads needs to be set up from the controller. The window's
// Settings shows with it (one state: the staged audio settings, the page),
// and isn't mirrored as a dialog meanwhile; its "Keep these settings?" is.
// Its tabs on the upper row:
//
// - Audio: the driver, the output and input interfaces, the sample rate,
//   the buffer, main's and the cue's output pairs, the cue's level; Apply
//   (then Keep, or back in 10 s), Undo Changes, Refresh, Test Main (a tone
//   on main's pair). The engine now (rate, buffer, latency, load) over it.
// - Channels: the interface's inputs or outputs (encoder 1), eight pairs a
//   page (encoder 2) on the lower row, each on or off (main's pair stays).
// - MIDI: MIDI on, the output port, the input offset; the input ports on
//   the lower row, each on or off.
// - Sync: what the tempo follows (Pads, MIDI clock, Link), the clock out,
//   Link's start and stop.
package pads

import "core:fmt"
import "core:strings"

import app "app:core"
import "app:ui"
import pm "model"
import im "deps:imgui"
import "fire:backend"
import padslink "padslink:."

SETTINGS_TABS := []string{"Audio", "Channels", "MIDI", "Sync"}

// The Settings view's own state.
Ctl_Settings :: struct {
	tab:      int,
	outputs:  bool, // Channels: the outputs (else the inputs)
	page:     int,  // Channels: eight pairs a page
	refreshed: bool, // the devices looked for since it showed
}

@(private)
ctl_settings :: proc(ctx: ^View_Ctx, full: im.Vec2) {
	a := ctx.a
	s := &a.settings
	cs := &a.ctl.settings
	if !cs.refreshed {
		refresh_devices(a)
		cs.refreshed = true
	}
	ctl_upper(ctx, 7, "Controller ›", false) // (the controller's own settings: it takes the button)
	if k := ctl_tabs(ctx, SETTINGS_TABS, cs.tab); k >= 0 && k < len(SETTINGS_TABS) {
		cs.tab = k
		s.page = .Audio if k < 2 else .Midi // (the window's page follows)
	}
	plot := im.Vec2{full.x, full.y - CTL_PLOT_Y - CTL_KNOBS_H - CTL_BUTTONS_H - 4} // (the knobs: a row of value bars)
	changed := false
	switch cs.tab {
	case 0: ctl_settings_audio(ctx, full, plot)
	case 1: ctl_settings_channels(ctx, full, plot)
	case 2: changed = ctl_settings_midi(ctx, full, plot)
	case 3: changed = ctl_settings_sync(ctx, full, plot)
	}
	if changed do settings_save(a)
	ui.knob_input.drawn = 8
}

// A line of words in the picture's place (`k`: which, from the top).
@(private)
settings_line :: proc(k: int, text: string, warn := false) {
	t := ui.theme()
	dl := im.GetWindowDrawList()
	o := im.GetWindowPos()
	ui.text_push(.Label)
	defer ui.text_pop()
	im.DrawList_AddText(dl, {o.x + 10, o.y + CTL_PLOT_Y + 2 + f32(k) * (im.GetTextLineHeight() + 2)}, ui.col(t.warn if warn else t.text_dim), fmt.ctprintf("%s", text))
}

// A device's name ("System default" for none).
@(private)
settings_device_name :: proc(s: ^App_Settings, id: string) -> string {
	if id == "" do return "System default"
	for d in s.devices do if d.id == id do return d.name
	return id
}

// Audio: the interfaces, the rate and buffer, main's and the cue's pairs.
@(private)
ctl_settings_audio :: proc(ctx: ^View_Ctx, full, plot: im.Vec2) {
	a := ctx.a
	s := &a.settings
	h := &a.host
	st := &s.staged
	// The driver (where there is more than one): opened at once, as the
	// window's.
	drivers := app.host_drivers(context.temp_allocator)
	if len(drivers) > 1 && !h.settings.fake {
		names := make([]string, len(drivers), context.temp_allocator)
		cur := 0
		for d, k in drivers {
			names[k] = d.name if d.needs == "" else fmt.tprintf("%s (%s)", d.name, d.needs)
			if d.id == h.driver_id do cur = k
		}
		if k, _ := ctl_choice(ctx, 0, 8, "Driver", names, cur, plot); k >= 0 && k != cur && drivers[k].needs == "" {
			set_string(&st.driver, drivers[k].id)
			set_string(&st.output, "")
			set_string(&st.input, "")
			audio_apply(a)
		}
	} else {
		ctl_value_box(ctx, 0, "Driver", h.driver_id if h.driver_id != "" else "The system's", CTL_STEP, plot)
	}
	// The interfaces.
	pick :: proc(ctx: ^View_Ctx, col: int, label: cstring, s: ^App_Settings, id: ^string, output: bool, plot: im.Vec2) {
		ids := make([dynamic]string, context.temp_allocator)
		names := make([dynamic]string, context.temp_allocator)
		append(&ids, "")
		append(&names, "System default")
		for d in s.devices do if (d.output_channels if output else d.input_channels) > 0 {
			append(&ids, d.id)
			append(&names, d.name)
		}
		cur := 0
		for x, k in ids do if x == id^ do cur = k
		if k, _ := ctl_choice(ctx, col, 8, label, names[:], cur, plot); k >= 0 do set_string(id, ids[k])
	}
	pick(ctx, 1, "Output", s, &st.output, true, plot)
	pick(ctx, 2, "Input", s, &st.input, false, plot)
	dev := find_device(s, st.output, true)
	rates := []f64{44_100, 48_000, 88_200, 96_000, 176_400, 192_000}
	if dev != nil && len(dev.sample_rates) > 0 do rates = dev.sample_rates
	rnames := make([]string, len(rates) + 1, context.temp_allocator)
	rnames[0] = "The device's"
	rcur := 0
	for r, k in rates {
		rnames[k + 1] = fmt.tprintf("%.0f Hz", r)
		if r == st.rate do rcur = k + 1
	}
	if k, _ := ctl_choice(ctx, 3, 8, "Sample Rate", rnames, rcur, plot); k >= 0 do st.rate = 0 if k == 0 else rates[k - 1]
	sizes := []int{32, 64, 128, 256, 512, 1024, 2048}
	if dev != nil && len(dev.buffer_sizes) > 0 do sizes = dev.buffer_sizes
	bnames := make([]string, len(sizes) + 1, context.temp_allocator)
	bnames[0] = "The device's"
	bcur := 0
	for n, k in sizes {
		bnames[k + 1] = fmt.tprintf("%d frames", n)
		if n == st.buffer do bcur = k + 1
	}
	if k, _ := ctl_choice(ctx, 4, 8, "Buffer", bnames, bcur, plot); k >= 0 do st.buffer = 0 if k == 0 else sizes[k - 1]
	// Main's and the cue's pairs. (Read without making the interface's
	// entry: one made is a change to apply.)
	seen := Interface_Config{inputs = {0, 1}, outputs = {0, 1}, main = 0, cue = -1}
	of := interface_find(st, st.output)
	if of == nil do of = &seen
	pairs := mask_pairs(of.outputs + {of.main, of.main + 1})
	mnames := make([]string, len(pairs), context.temp_allocator)
	mcur := 0
	for p, k in pairs {
		mnames[k] = pair_label(of, dev, true, p)
		if p == of.main do mcur = k
	}
	if len(pairs) > 0 {
		if k, _ := ctl_choice(ctx, 5, 8, "Main Out", mnames, mcur, plot); k >= 0 && pairs[k] != of.main do interface_for(st, st.output).main = pairs[k]
	}
	cnames := make([dynamic]string, context.temp_allocator)
	cpairs := make([dynamic]int, context.temp_allocator)
	append(&cnames, "None")
	append(&cpairs, -1)
	for p in pairs do if p != of.main {
		append(&cnames, pair_label(of, dev, true, p))
		append(&cpairs, p)
	}
	ccur := 0
	for p, k in cpairs do if p == of.cue do ccur = k
	if k, _ := ctl_choice(ctx, 6, 8, "Cue Out", cnames[:], ccur, plot); k >= 0 && cpairs[k] != of.cue do interface_for(st, st.output).cue = cpairs[k]
	if k, _ := ctl_value_box(ctx, 7, "Cue Level", fmt.tprintf("%.1f dB", st.cue_db), 1.0 / 160, plot); k != 0 {
		st.cue_db = clamp(st.cue_db + f32(k) * 0.5, -60, 6)
	}
	// Apply (lit while something waits), Undo Changes, Refresh, Test Main.
	pending := st.output != s.audio.output || st.input != s.audio.input || st.rate != s.audio.rate || st.buffer != s.audio.buffer || st.cue_db != s.audio.cue_db || st.click_cue != s.audio.click_cue || !interfaces_equal(st.interfaces, s.audio.interfaces)
	if pr, _ := ctl_button(ctx, 0, "Apply", pending, full); pr && pending do audio_apply(a)
	if pr, _ := ctl_button(ctx, 1, "Undo Changes", false, full); pr && pending {
		audio_free(st)
		s.staged = audio_clone(s.audio)
	}
	if pr, _ := ctl_button(ctx, 2, "Refresh", false, full); pr do refresh_devices(a)
	if pr, _ := ctl_button(ctx, 3, "Test Main", false, full); pr do pm.test_tone(&a.m.engine, interface_for(&s.audio, s.audio.output).main)
	// The engine now.
	f := h.format
	rate := f.sample_rate if f.sample_rate > 0 else 1
	_, _, rt := app.host_latency(h)
	settings_line(0, fmt.tprintf("Now: %s%s · %.0f Hz · %d frames (%.1f ms) · round trip %.1f ms", settings_device_name(s, s.audio.output), " (simulated)" if h.settings.fake else "", f.sample_rate, f.buffer_frames, f64(f.buffer_frames) * 1000 / rate, f64(rt) * 1000 / rate))
	settings_line(1, fmt.tprintf("Load %.0f%% · %d dropouts · %d out, %d in", app.host_load(h) * 100, h.xruns, h.settings.outputs, h.settings.inputs))
	if pending do settings_line(2, "Not applied yet: Apply opens the device with these (Keep, or back in 10 s)", warn = true)
	else if st.output != "" && dev == nil do settings_line(2, fmt.tprintf("%s is not connected: the system's plays until it is back", settings_device_name(s, st.output)), warn = true)
}

// Channels: the interface's inputs or outputs, eight pairs a page, on or
// off on the lower row.
@(private)
ctl_settings_channels :: proc(ctx: ^View_Ctx, full, plot: im.Vec2) {
	a := ctx.a
	s := &a.settings
	cs := &a.ctl.settings
	st := &s.staged
	if k, _ := ctl_choice(ctx, 0, 8, "Channels", []string{"Inputs", "Outputs"}, int(cs.outputs), plot); k >= 0 {
		cs.outputs = k == 1
		cs.page = 0
	}
	dev := find_device(s, st.output if cs.outputs else st.input, cs.outputs)
	seen := Interface_Config{inputs = {0, 1}, outputs = {0, 1}, main = 0, cue = -1}
	f := interface_find(st, st.output if cs.outputs else st.input)
	if f == nil do f = &seen
	mask := &f.outputs if cs.outputs else &f.inputs
	n := 0
	if dev != nil do n = min(dev.output_channels if cs.outputs else dev.input_channels, 64)
	npairs := (n + 1) / 2
	pages := max((npairs + 7) / 8, 1)
	pnames := make([]string, pages, context.temp_allocator)
	for &x, k in pnames do x = fmt.tprintf("%d-%d", k * 16 + 1, min(k * 16 + 16, n))
	cs.page = clamp(cs.page, 0, pages - 1)
	if k, _ := ctl_choice(ctx, 1, 8, "Page", pnames, cs.page, plot); k >= 0 do cs.page = k
	if n == 0 {
		settings_line(0, fmt.tprintf("No %s on %s", "outputs" if cs.outputs else "inputs", settings_device_name(s, st.output if cs.outputs else st.input)), warn = true)
		return
	}
	for b in 0 ..< 8 {
		pair := cs.page * 8 + b
		c := pair * 2
		if c >= n do break
		on := c in mask^ || (c + 1 < n && c + 1 in mask^)
		locked := cs.outputs && c == f.main
		label := fmt.ctprintf("%s %d/%d", "Out" if cs.outputs else "In", c + 1, min(c + 2, n))
		if pr, _ := ctl_button(ctx, b, label, on || locked, full); pr && !locked {
			// (the entry made now: a change to apply)
			g := interface_for(st, st.output if cs.outputs else st.input)
			mask = &g.outputs if cs.outputs else &g.inputs
			if on do mask^ -= {c, c + 1}
			else {
				mask^ += {c}
				if c + 1 < n do mask^ += {c + 1}
			}
		}
	}
	settings_line(0, fmt.tprintf("%s of %s: a pair on or off (lit: open). %s", "Outputs" if cs.outputs else "Inputs", settings_device_name(s, st.output if cs.outputs else st.input), "Main's pair stays on." if cs.outputs else ""))
	settings_line(1, fmt.tprintf("On now: %s", mask_text(mask^) if mask^ != {} else "none"))
	pending := !interfaces_equal(st.interfaces, s.audio.interfaces)
	if pending do settings_line(2, "Not applied yet: Apply on the Audio tab", warn = true)
}

// MIDI: on, the output port, the input offset; the input ports.
@(private)
ctl_settings_midi :: proc(ctx: ^View_Ctx, full, plot: im.Vec2) -> (changed: bool) {
	a := ctx.a
	s := &a.settings
	h := &a.host
	if k, _ := ctl_choice(ctx, 0, 8, "MIDI", OFF_ON, int(s.midi_on), plot); k >= 0 && (k == 1) != s.midi_on {
		s.midi_on = k == 1
		midi_apply(a)
		changed = true
	}
	ports := app.host_midi_ports(h, context.temp_allocator)
	onames := make([dynamic]string, context.temp_allocator)
	oids := make([dynamic]string, context.temp_allocator)
	append(&onames, "None")
	append(&oids, "")
	for p in ports do if p.direction == .Output {
		append(&onames, p.name)
		append(&oids, p.id)
	}
	ocur := 0
	for x, k in oids do if x == s.midi_output do ocur = k
	if k, _ := ctl_choice(ctx, 1, 8, "Output", onames[:], ocur, plot); k >= 0 && oids[k] != s.midi_output {
		set_string(&s.midi_output, oids[k])
		midi_apply(a)
		changed = true
	}
	if k, en := ctl_value_box(ctx, 2, "In Offset", fmt.tprintf("%.1f ms", s.midi_offset_ms), 1.0 / 160, plot); k != 0 || en {
		s.midi_offset_ms = clamp(s.midi_offset_ms + f32(k) * 0.5, -100, 100)
		if en do changed = true
	}
	// The inputs, each on or off.
	b := 0
	for p in ports do if p.direction == .Input && b < 8 {
		on := true
		for x in s.midi_off do if x == p.id do on = false
		if pr, _ := ctl_button(ctx, b, fmt.ctprintf("%s", p.name), on, full); pr {
			if on {
				append(&s.midi_off, strings.clone(p.id))
			} else {
				for x, k in s.midi_off do if x == p.id {
					delete(x)
					ordered_remove(&s.midi_off, k)
					break
				}
			}
			midi_apply(a)
			changed = true
		}
		b += 1
	}
	sent, received := app.host_midi_counts(h)
	settings_line(0, "The lower row: the MIDI inputs, each on or off (lit: on)." if b > 0 else ("No MIDI inputs." if s.midi_on else "MIDI is off."))
	settings_line(1, fmt.tprintf("Activity: %d in, %d out", received, sent))
	return
}

// Sync: what the tempo follows, the clock out, Link's start and stop.
@(private)
ctl_settings_sync :: proc(ctx: ^View_Ctx, full, plot: im.Vec2) -> (changed: bool) {
	a := ctx.a
	s := &a.settings
	modes := []string{"Pads", "MIDI Clock", "Link" if padslink.AVAILABLE else "Link (not built in)"}
	if k, _ := ctl_choice(ctx, 0, 8, "Tempo Follows", modes, int(s.sync), plot); k >= 0 && Sync_Mode(k) != s.sync {
		if Sync_Mode(k) != .Link || padslink.AVAILABLE {
			s.sync = Sync_Mode(k)
			sync_apply(a)
			changed = true
		}
	}
	if k, _ := ctl_choice(ctx, 1, 8, "Clock Out", OFF_ON, int(s.clock_out), plot); k >= 0 && (k == 1) != s.clock_out {
		s.clock_out = k == 1
		sync_apply(a)
		changed = true
	}
	if s.sync == .Link {
		if k, _ := ctl_choice(ctx, 2, 8, "Start/Stop", []string{"Its own", "With the session"}, int(s.link_start_stop), plot); k >= 0 && (k == 1) != s.link_start_stop {
			s.link_start_stop = k == 1
			padslink.set_start_stop(&s.link, s.link_start_stop)
			changed = true
		}
	}
	switch s.sync {
	case .Internal:   settings_line(0, "Pads keeps its own tempo.")
	case .Midi_Clock:
		f := pm.midi_clock_heard(&a.m.engine)
		settings_line(0, fmt.tprintf("From the MIDI clock at the inputs: %s", fmt.tprintf("%.1f BPM, %s", f.bpm, "running" if f.running else "stopped") if f.bpm > 0 else "none heard yet"))
	case .Link:       settings_line(0, fmt.tprintf("Ableton Link: %d other app%s in the session", padslink.peers(&s.link), "" if padslink.peers(&s.link) == 1 else "s"))
	}
	settings_line(1, "Clock out: 24 ticks a beat, Start, Stop and Song Position to the MIDI output." if s.clock_out else "Clock out is off.")
	_ = backend.Channel_Mask{}
	return
}
