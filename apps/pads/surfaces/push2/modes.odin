package pads_push2

import "core:math"

import abi "fsurf:abi"
import kit "fsurf:surface"
import pa "../../api"

/*
The encoders' modes and the rows above and below the display:

- **Mix:** Pads' own mixer strips (fire.pads: View_Kind.Mixer, drawn and
  driven by Pads): the selected pad's eight, or the buses with Main at
  the far right (the upper row's last). The upper row's first steps the
  encoders through volume, pan, a send a bus, audio in, monitoring,
  output, MIDI in and out (Shift: back); its second arms the selected
  pad (held: the lower row arms). The lower row selects, or mutes, solos
  or arms while Mute, Solo or Arm is held; Delete held and an encoder
  touched: back to its default; Page < >: the eight before or after.
  Without Pads (another host): a page of the eight tracks' volumes, pans
  or a send, the upper row picking it.
- **Device:** Pads' own device panel, the window's and the display's the
  same (mirror.odin). Without Pads' API (another host): the device's banks
  on the upper row (past eight, arrows to the banks either side; Page <
  and > step one bank), the lower row picks the device in the chain.
*/

// The sends Mix pages offer.
MIX_SENDS :: 4

// Mix's pages: volume, pan, then the sends.
MIX_PAGES :: 2 + MIX_SENDS

// A Mix page's name.
mix_page_name :: proc(cs: ^kit.Control_Surface, page: int) -> string {
	switch page {
	case 0: return "Volume"
	case 1: return "Pan"
	}
	names := [MIX_SENDS]string{"Send 1", "Send 2", "Send 3", "Send 4"}
	return names[clamp(page - 2, 0, MIX_SENDS - 1)]
}

// The Mix pages there are now (the sends Pads has).
mix_pages :: proc(cs: ^kit.Control_Surface) -> int {
	if cs.daw == nil do return 2
	return 2 + clamp(int(kit.daw_get(cs, .Send_Count)), 0, MIX_SENDS)
}

// Whether the encoders are in Device (Pads' panel, or a bank of parameters).
in_device :: proc(p: ^Push2) -> bool {
	m := kit.modes_current(p.enc_modes)
	return m == "device" || m == "mirror"
}

// Whether the display is a view of Pads' (Device's panel, Browse, Clip:
// mirror.odin).
in_mirror :: proc(p: ^Push2) -> bool {
	m := kit.modes_current(p.enc_modes)
	return m == "mirror" || m == "browse" || m == "clip" || m == "perform" || m == "mix" || m == "song" || m == "settings" || m == "projects"
}

// Mix: Pads' mixer view (Pads is there), or the surface's own pages.
in_mix :: proc(p: ^Push2) -> bool {
	return kit.modes_current(p.enc_modes) == "mix" || (!in_device(p) && !in_mirror(p))
}

@(private)
modes_setup :: proc(cs: ^kit.Control_Surface, p: ^Push2, master, mix_b, device_b, browse_b, clip_b, page_l, page_r, mute_b, solo_b: ^kit.Control) {
	// The encoders' components: a mixer a Mix page, and the device.
	p.volumes = kit.mixer_make(cs, "Volumes", 8)
	p.pans = kit.mixer_make(cs, "Pans", 8)
	for k in 0 ..< MIX_SENDS do p.sends[k] = kit.mixer_make(cs, "Sends", 8)
	p.device = kit.device_make(cs, "Device", 8)
	for e, i in p.encoders {
		kit.mixer_bind(p.volumes, i, .Volume, e)
		kit.mixer_bind(p.pans, i, .Pan, e)
		for k in 0 ..< MIX_SENDS do kit.mixer_bind(p.sends[k], i, .Send, e, k)
		kit.device_bind_param(p.device, i, e)
	}
	p.device.on_change = proc(d: ^kit.Device) { invalidate(d.cs) }
	mirror_parts := mirror_setup(cs, p, page_l, page_r)
	// The master encoder: Main's level (without Pads: the selected track's).
	p.selected = kit.component_make(cs, "Main Volume")
	kit.layer_bind(p.selected.layer, "volume", master)
	p.selected.on_event = proc(c: ^kit.Component, e: kit.Event) {
		p := (^Push2)(c.cs.user)
		t := p.pads_api
		#partial switch e.kind {
		case .Touch:   if t != nil do t.history_gesture_begin(t.api)
		case .Untouch: if t != nil do t.history_gesture_end(t.api)
		case .Delta:
			if t != nil {
				// Along the fader's travel, as Pads' faders (finer near 0 dB
				// than near the bottom): MAIN_TRAVEL a tick (Shift: a tenth),
				// a fast turn's burst at most MAIN_BURST ticks (no leaps).
				st: pa.Bus_State
				t.mixer_bus_state(t.api, pa.MAIN, &st)
				d := f64(clamp(e.delta, -MAIN_BURST, MAIN_BURST)) * MAIN_TRAVEL / (10 if p.shift.held else 1)
				t.mixer_set_bus_volume(t.api, pa.MAIN, fader_db(fader_frac(st.volume) + d))
			} else {
				tr := kit.selected_track(c.cs)
				kit.daw_set(c.cs, .Track_Volume, tr, 0, clamp(kit.daw_get(c.cs, .Track_Volume, tr) + f64(e.delta) * 0.01, 0, 1))
			}
			invalidate(c.cs)
		}
	}
	// Mix on Pads' strips: its modifiers held, told to Pads' view.
	mods := kit.component_make(cs, "Mix Modifiers")
	kit.layer_bind(mods.layer, "mute", mute_b)
	kit.layer_bind(mods.layer, "solo", solo_b)
	mods.on_owned = proc(c: ^kit.Component, slot: string, control: ^kit.Control) {
		p := (^Push2)(c.cs.user)
		on := p.mute_held if slot == "mute" else p.solo_held
		kit.light_value(control, W_ON if on else W_DIM)
	}
	mods.on_event = proc(c: ^kit.Component, e: kit.Event) {
		if e.kind != .Press && e.kind != .Release do return
		p := (^Push2)(c.cs.user)
		on := e.kind == .Press
		if e.slot == "mute" {
			p.mute_held = on
			press(p, .Mixer, .Mute, on)
		} else {
			p.solo_held = on
			press(p, .Mixer, .Solo, on)
		}
		kit.redraw_owned(c)
	}
	mods.on_activate = proc(c: ^kit.Component) {
		// Shift and Delete (their own components'): told as they change.
		kit.task_every(c.cs, 30, proc(data: rawptr) {
			c := (^kit.Component)(data)
			p := (^Push2)(c.cs.user)
			if p.shift.held != p.mix_told[0] {
				p.mix_told[0] = p.shift.held
				press(p, .Mixer, .Shift, p.shift.held)
			}
			if p.delete_held != p.mix_told[1] {
				p.mix_told[1] = p.delete_held
				press(p, .Mixer, .Delete, p.delete_held)
			}
		}, c, c)
	}
	mods.on_deactivate = proc(c: ^kit.Component) {
		p := (^Push2)(c.cs.user)
		// (let go of: nothing stays held in Pads' view)
		if p.mute_held do press(p, .Mixer, .Mute, false)
		if p.solo_held do press(p, .Mixer, .Solo, false)
		if p.mix_told[0] do press(p, .Mixer, .Shift, false)
		if p.mix_told[1] do press(p, .Mixer, .Delete, false)
		p.mute_held, p.solo_held, p.mix_told = false, false, {}
	}
	// Browse: Shift held told to Pads' browser (a load goes onto the next
	// empty pad).
	bshift := kit.component_make(cs, "Browse Shift")
	bshift.on_activate = proc(c: ^kit.Component) {
		kit.task_every(c.cs, 30, proc(data: rawptr) {
			c := (^kit.Component)(data)
			p := (^Push2)(c.cs.user)
			if p.shift.held != p.browse_told {
				p.browse_told = p.shift.held
				press(p, .Browser, .Shift, p.shift.held)
			}
		}, c, c)
	}
	bshift.on_deactivate = proc(c: ^kit.Component) {
		p := (^Push2)(c.cs.user)
		if p.browse_told do press(p, .Browser, .Shift, false)
		p.browse_told = false
	}
	// Song: Shift told to Pads' Song view (a finer step), Mute and Solo
	// held (a lane button mutes or solos its lane: song.odin).
	smods := kit.component_make(cs, "Song Modifiers")
	kit.layer_bind(smods.layer, "mute", mute_b)
	kit.layer_bind(smods.layer, "solo", solo_b)
	smods.on_owned = proc(c: ^kit.Component, slot: string, control: ^kit.Control) {
		p := (^Push2)(c.cs.user)
		kit.light_value(control, W_ON if (p.mute_held if slot == "mute" else p.solo_held) else W_DIM)
	}
	smods.on_event = proc(c: ^kit.Component, e: kit.Event) {
		if e.kind != .Press && e.kind != .Release do return
		p := (^Push2)(c.cs.user)
		if e.slot == "mute" do p.mute_held = e.kind == .Press
		else do p.solo_held = e.kind == .Press
		kit.redraw_owned(c)
	}
	smods.on_activate = proc(c: ^kit.Component) {
		kit.task_every(c.cs, 30, proc(data: rawptr) {
			c := (^kit.Component)(data)
			p := (^Push2)(c.cs.user)
			if p.shift.held != p.song_told {
				p.song_told = p.shift.held
				press(p, .Song, .Shift, p.shift.held)
			}
		}, c, c)
	}
	smods.on_deactivate = proc(c: ^kit.Component) {
		p := (^Push2)(c.cs.user)
		if p.song_told do press(p, .Song, .Shift, false)
		p.song_told, p.mute_held, p.solo_held = false, false, false
	}
	song_parts := make([]^kit.Component, len(mirror_parts) + 1)
	copy(song_parts, mirror_parts)
	song_parts[len(mirror_parts)] = smods
	browse_parts := make([]^kit.Component, len(mirror_parts) + 1)
	copy(browse_parts, mirror_parts)
	browse_parts[len(mirror_parts)] = bshift
	mix_parts := make([]^kit.Component, len(mirror_parts) + 1)
	copy(mix_parts, mirror_parts)
	mix_parts[len(mirror_parts)] = mods

	// Mix's pages on the upper row; Device's banks there.
	pages := kit.component_make(cs, "Mix Pages")
	for b in p.upper do kit.layer_bind(pages.layer, "page", b)
	pages.on_owned = proc(c: ^kit.Component, slot: string, control: ^kit.Control) {
		p := (^Push2)(c.cs.user)
		i := row_index(p.upper, control)
		kit.light_value(control, OFF if i >= mix_pages(c.cs) else (WHITE if i == p.mix_page else DIM_WHITE))
	}
	pages.on_event = proc(c: ^kit.Component, e: kit.Event) {
		if e.kind != .Press do return
		p := (^Push2)(c.cs.user)
		i := row_index(p.upper, e.control)
		if i < mix_pages(c.cs) do mix_select(p, i)
	}
	banks := kit.component_make(cs, "Banks")
	for b in p.upper do kit.layer_bind(banks.layer, "bank", b)
	kit.layer_bind(banks.layer, "prev", page_l)
	kit.layer_bind(banks.layer, "next", page_r)
	banks.daw_topics = {.Parameters}
	banks.on_daw = proc(c: ^kit.Component, e: abi.Daw_Event) { kit.redraw_owned(c) }
	// Another pad or device: Device on its first (the Sample tab, or its
	// first bank), whichever way it shows.
	follow := kit.component_make(cs, "Device Follow")
	follow.daw_topics = {.Tracks, .Devices, .Parameters}
	follow.on_daw = proc(c: ^kit.Component, e: abi.Daw_Event) {
		p := (^Push2)(c.cs.user)
		at := [3]int{kit.selected_track(c.cs), int(kit.daw_get(c.cs, .Selected_Device)), 0}
		if at != p.bank_of {
			p.bank_of = at
			bank_select(p, 0)
		} else if p.dev_bank >= device_banks(p) {
			bank_select(p, 0)
		}
		if p.banks != nil && p.banks.active do kit.redraw_owned(p.banks)
	}
	p.device_follow = follow
	banks.on_owned = proc(c: ^kit.Component, slot: string, control: ^kit.Control) {
		p := (^Push2)(c.cs.user)
		n := device_banks(p)
		switch slot {
		case "prev": kit.light_value(control, W_ON if p.dev_bank > 0 else W_DIM)
		case "next": kit.light_value(control, W_ON if p.dev_bank < n - 1 else W_DIM)
		case:
			b := bank_row(p)[row_index(p.upper, control)]
			switch {
			case b == BANK_LEFT || b == BANK_RIGHT: kit.light_value(control, W_HALF)
			case b < 0:              kit.light_value(control, OFF)
			case b == p.dev_bank:    kit.light_value(control, WHITE)
			case:                    kit.light_value(control, DIM_WHITE)
			}
		}
	}
	banks.on_event = proc(c: ^kit.Component, e: kit.Event) {
		if e.kind != .Press do return
		p := (^Push2)(c.cs.user)
		switch e.slot {
		case "prev": bank_select(p, p.dev_bank - 1)
		case "next": bank_select(p, p.dev_bank + 1)
		case:
			switch b := bank_row(p)[row_index(p.upper, e.control)]; b {
			case BANK_LEFT:  p.bank_first = 0 if p.bank_first <= 7 else p.bank_first - 6
			case BANK_RIGHT: p.bank_first += 7 if p.bank_first == 0 else 6
			case:            if b >= 0 do bank_select(p, b)
			}
		}
		kit.redraw_owned(c)
		invalidate(c.cs)
	}
	p.banks = banks

	// The lower row: select (Mix), or mute or solo while held; the chain's
	// devices (Device).
	rows := kit.mixer_make(cs, "Select Row", 8)
	mutes := kit.mixer_make(cs, "Mute Row", 8, priority = 1)
	solos := kit.mixer_make(cs, "Solo Row", 8, priority = 1)
	for b, i in p.lower {
		kit.mixer_bind(rows, i, .Select, b)
		kit.mixer_bind(mutes, i, .Mute, b)
		kit.mixer_bind(solos, i, .Solo, b)
	}
	mute := kit.modifier_make(cs, "Mute", mute_b, {mutes})
	solo := kit.modifier_make(cs, "Solo", solo_b, {solos})
	chain := kit.component_make(cs, "Chain", priority = 2)
	for b in p.lower do kit.layer_bind(chain.layer, "device", b)
	chain.daw_topics = {.Devices}
	chain.on_daw = proc(c: ^kit.Component, e: abi.Daw_Event) { kit.redraw_owned(c) }
	chain.on_owned = proc(c: ^kit.Component, slot: string, control: ^kit.Control) {
		p := (^Push2)(c.cs.user)
		i := row_index(p.lower, control)
		n := int(kit.daw_get(c.cs, .Device_Count))
		kit.light_value(control, OFF if i >= n else (WHITE if i == int(kit.daw_get(c.cs, .Selected_Device)) else DIM_WHITE))
	}
	chain.on_event = proc(c: ^kit.Component, e: kit.Event) {
		if e.kind != .Press do return
		p := (^Push2)(c.cs.user)
		i := row_index(p.lower, e.control)
		if i < int(kit.daw_get(c.cs, .Device_Count)) do kit.daw_set(c.cs, .Selected_Device, 0, 0, f64(i))
	}

	// The modes: a Mix page each, and Device; Mix and Device switch.
	p.enc_modes = kit.modes_make(cs, "Encoders")
	kit.modes_add(p.enc_modes, "volume", {p.volumes, pages, rows, &mute.component, &solo.component})
	kit.modes_add(p.enc_modes, "pan", {p.pans, pages, rows, &mute.component, &solo.component})
	for k in 0 ..< MIX_SENDS do kit.modes_add(p.enc_modes, "send", {p.sends[k], pages, rows, &mute.component, &solo.component})
	kit.modes_add(p.enc_modes, "device", {p.device, banks, chain, rows})
	// Device: Mute held (with Device: the device shown off or on).
	dmods := kit.component_make(cs, "Device Modifiers")
	kit.layer_bind(dmods.layer, "mute", mute_b)
	dmods.on_owned = proc(c: ^kit.Component, slot: string, control: ^kit.Control) {
		kit.light_value(control, W_ON if (^Push2)(c.cs.user).mute_held else W_DIM)
	}
	dmods.on_event = proc(c: ^kit.Component, e: kit.Event) {
		if e.kind != .Press && e.kind != .Release do return
		(^Push2)(c.cs.user).mute_held = e.kind == .Press
		kit.redraw_owned(c)
	}
	dmods.on_deactivate = proc(c: ^kit.Component) { (^Push2)(c.cs.user).mute_held = false }
	device_parts := make([dynamic]^kit.Component)
	append(&device_parts, ..mirror_parts)
	append(&device_parts, dmods)
	kit.modes_add(p.enc_modes, "mirror", device_parts[:])
	kit.modes_add(p.enc_modes, "browse", browse_parts) // (Pads' browser: mirror.odin)
	kit.modes_add(p.enc_modes, "clip", mirror_parts)   // (Pads' sequencer)
	kit.modes_add(p.enc_modes, "perform", mirror_parts) // (Pads' launcher: Session's Sequences)
	kit.modes_add(p.enc_modes, "mix", mix_parts)        // (Pads' mixer strips)
	kit.modes_add(p.enc_modes, "song", song_parts)      // (Pads' Song view: song.odin)
	// Pads' Settings (Setup): the upper row's last button, Controller ›, the Push's own (setup.odin).
	own := kit.component_make(cs, "Push Settings Button")
	kit.layer_bind(own.layer, "own", p.upper[7])
	own.on_owned = proc(c: ^kit.Component, slot: string, control: ^kit.Control) { kit.light_value(control, W_DIM) }
	own.on_event = proc(c: ^kit.Component, e: kit.Event) {
		if e.kind == .Press do setup_show((^Push2)(c.cs.user))
	}
	settings_parts := make([]^kit.Component, len(mirror_parts) + 1)
	copy(settings_parts, mirror_parts)
	settings_parts[len(mirror_parts)] = own
	kit.modes_add(p.enc_modes, "settings", settings_parts)
	kit.modes_add(p.enc_modes, "projects", mirror_parts) // (Pads' project page: Shift + Setup, and at start)
	p.enc_modes.on_change = proc(m: ^kit.Modes, from, to: int) {
		p := (^Push2)(m.cs.user)
		p.touched = {}
		if p.mode_buttons != nil do kit.redraw_owned(p.mode_buttons)
		invalidate(m.cs)
	}
	buttons := kit.component_make(cs, "Mode Buttons")
	kit.layer_bind(buttons.layer, "mix", mix_b)
	kit.layer_bind(buttons.layer, "device", device_b)
	kit.layer_bind(buttons.layer, "browse", browse_b)
	kit.layer_bind(buttons.layer, "clip", clip_b)
	buttons.on_owned = proc(c: ^kit.Component, slot: string, control: ^kit.Control) {
		p := (^Push2)(c.cs.user)
		m := kit.modes_current(p.enc_modes)
		on: bool
		switch slot {
		case "device": on = in_device(p)
		case "browse": on = m == "browse"
		case "clip":   on = m == "clip"
		case:          on = in_mix(p)
		}
		kit.light(control, "Mode.On" if on else "Mode.Off")
	}
	buttons.on_event = proc(c: ^kit.Component, e: kit.Event) {
		if e.kind != .Press do return
		p := (^Push2)(c.cs.user)
		if p.delete_held do p.delete_used = true
		if e.slot != "clip" do steps_leave(p) // (Clip's pads: the ones before)
		switch e.slot {
		case "device":
			if in_device(p) && in_mirror(p) { // (again: the next device; Delete held: it removed; Mute held: off or on)
				mod: pa.View_Button = .Delete if p.delete_held else .Mute
				held := p.delete_held || p.mute_held
				if held do press(p, .Device, mod, true)
				press(p, .Device, .Next_Device, true)
				if held do press(p, .Device, mod, false)
			}
			p.mirror_kind = .Device
			if !in_device(p) do bank_select(p, p.dev_bank, force = true)
			app_show(p, "device")
		case "browse":
			// From Device: the Library for the device shown (its samples,
			// presets, effects: a load replaces it).
			from_device := in_device(p)
			p.mirror_kind = .Browser
			kit.modes_select(p.enc_modes, kit.modes_find(p.enc_modes, "browse"))
			app_show(p, "browse device" if from_device else "browser")
		case "clip":
			p.mirror_kind = .Sequencer
			kit.modes_select(p.enc_modes, kit.modes_find(p.enc_modes, "clip"))
			app_show(p, "sequence")
			steps_show(p)
		case:
			mix_select(p, p.mix_page)
			app_show(p, "mixer")
		}
		kit.redraw_owned(c)
		invalidate(c.cs)
	}
	p.mode_buttons = buttons
	kit.surface_add(cs, buttons)
}

// Starts in Mix's volume page.
@(private)
modes_start :: proc(p: ^Push2) {
	mix_select(p, 0)
}

// Mix: Pads' strips (Pads is there), or the surface's page `page`.
@(private)
mix_select :: proc(p: ^Push2, page: int) {
	if uses_tabs(p) {
		p.mirror_kind = .Mixer
		kit.modes_select(p.enc_modes, kit.modes_find(p.enc_modes, "mix"))
		invalidate(p.enc_modes.cs)
		return
	}
	p.mix_page = page
	kit.modes_select(p.enc_modes, page) // (the modes' order: volume, pan, the sends, device)
	for c in p.enc_modes.modes[page].components do kit.redraw_owned(c)
	invalidate(p.enc_modes.cs)
}

@(private)
row_index :: proc(row: [8]^kit.Control, c: ^kit.Control) -> int {
	for x, i in row do if x == c do return i
	return -1
}

// The selected device's banks of eight parameters.
@(private)
bank_count :: proc(cs: ^kit.Control_Surface) -> int {
	if cs.daw == nil do return 0
	return (int(kit.daw_get(cs, .Param_Count)) + 7) / 8
}

// Device's banks: the device's parameters', eight a bank.
@(private)
device_banks :: proc(p: ^Push2) -> int {
	return bank_count(p.enc_modes.cs)
}

// The upper row's buttons for Device: a bank each, or an arrow to the
// banks before or after (more than eight).
BANK_LEFT :: -2
BANK_RIGHT :: -3

@(private)
bank_row :: proc(p: ^Push2) -> (row: [8]int) {
	n := device_banks(p)
	for &x in row do x = -1
	if n <= 8 {
		for i in 0 ..< n do row[i] = i
		return
	}
	first := clamp(p.bank_first, 0, n - 1)
	k := 0
	if first > 0 {
		row[0] = BANK_LEFT
		k = 1
	}
	for b := first; k < 8 && b < n; b += 1 {
		if k == 7 && b < n - 1 {
			row[7] = BANK_RIGHT
			break
		}
		row[k] = b
		k += 1
	}
	return
}

// A bank's name: its first parameter's.
bank_name :: proc(p: ^Push2, b: int) -> string {
	return kit.daw_text(p.enc_modes.cs, .Param_Name, b * 8)
}

// Device: Pads' tabs (a sampler, a slicer, an empty pad), or bank `b` of
// the device's parameters, the upper row's window moved to show it.
@(private)
bank_select :: proc(p: ^Push2, to: int, force := false) {
	if !force && !in_device(p) {
		p.dev_bank = max(to, 0)
		return
	}
	n := device_banks(p)
	b := clamp(to, 0, max(n - 1, 0))
	p.dev_bank = b
	if n > 8 {
		for {
			row := bank_row(p)
			seen := false
			for x in row do if x == b do seen = true
			if seen do break
			if b < p.bank_first do p.bank_first = 0 if p.bank_first <= 7 else p.bank_first - 6
			else do p.bank_first += 7 if p.bank_first == 0 else 6
		}
	} else {
		p.bank_first = 0
	}
	mirror := uses_tabs(p)
	p.mirror_kind = .Device
	if !mirror do p.device.bank = b
	kit.modes_select(p.enc_modes, kit.modes_find(p.enc_modes, "mirror" if mirror else "device"))
	kit.redraw_owned(p.device)
	if p.banks != nil do kit.redraw_owned(p.banks)
	invalidate(p.enc_modes.cs)
}

// The master encoder: a tick moves Main's fader this much of its travel.
MAIN_TRAVEL :: 1.0 / 400

// The most ticks one of its messages moves it (a fast turn sends several).
MAIN_BURST :: 3

// Pads' fader curve (ui_mixer.odin's): -60 dB (off) at the bottom, +6 at
// the top, a 1.5 power between.
@(private)
fader_frac :: proc(db: f32) -> f64 {
	if db <= -60 do return 0
	return math.pow(clamp(f64(db + 60) / 66, 0, 1), 1.5)
}

@(private)
fader_db :: proc(frac: f64) -> f32 {
	return f32(-60 + math.pow(clamp(frac, 0, 1), 1 / 1.5) * 66)
}
