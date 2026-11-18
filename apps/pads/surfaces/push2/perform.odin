package pads_push2

import "core:fmt"

import kit "fsurf:surface"
import pa "../../api"

/*
Perform (Session's second mode): the grid as Pads' Perform tab, four 4 x 4
quarters, the window's state and the Push's the same:

	top left: the Perform bar        top right: the 16 effects
	  row 4  Stop All · FX Latch · + Lane · Keys
	  row 3  Launch · Hold · Continue · Rec
	  row 2  End · Bar · Beat · Now (when a launch happens)
	  row 1  Stop each lane shown
	bottom left: the launcher's      bottom right: the pads' bank
	  window (4 lanes, 4 rows)         (16: as the Pads mode's play)

A sequence pad launches it in its lane (Hold: while held); Shift, alone;
Select, goes to it; Delete, clears it; Duplicate, copies it. An empty
one goes to it; a lane's + makes one. A pad plays and selects; Delete
clears it. An effect plays while held (FX Latch: until the next press),
as hard as the pad is pressed (and as the pressure moves); Select shows
it in Device.

The scene buttons beside the launcher's rows launch them; the Up/Down
arrows move its rows, Page < > (the display's) its lanes; Octave Up and
Down the pads' bank.
*/

// The quarter a grid index is in, and the cell in it (0..15, from its
// bottom left along each row).
Quarter :: enum {
	Launcher,
	Pads,
	Bar,
	Effects,
}

perform_cell :: proc(i: int) -> (q: Quarter, col, row: int) {
	gc, gr := i % 8, i / 8
	col, row = gc % 4, gr % 4
	switch {
	case gr < 4 && gc < 4: q = .Launcher
	case gr < 4:           q = .Pads
	case gc < 4:           q = .Bar
	case:                  q = .Effects
	}
	return
}

// Grid index of quarter `q`'s cell `col`, `row`.
perform_index :: proc(q: Quarter, col, row: int) -> int {
	gc := col + (4 if q == .Pads || q == .Effects else 0)
	gr := row + (4 if q == .Bar || q == .Effects else 0)
	return gr * 8 + gc
}

// The effect a cell of the effects' quarter plays: the window's grid,
// its first at the top left.
perform_fx :: proc(col, row: int) -> int { return (3 - row) * 4 + col }

// The pad of the pads' quarter: the bank's, its first at the bottom left.
perform_pad :: proc(t: ^pa.Table_V1, col, row: int) -> int {
	perf: pa.Perform_State
	t.perform_state(t.api, &perf)
	return int(perf.bank) * 16 + row * 4 + col
}

// The launcher's cell: its sequence (-1: none), its lane and row, and
// whether it is a lane's + (after its last).
perform_slot :: proc(t: ^pa.Table_V1, col, row: int) -> (slot, lane, lrow: int, plus: bool) {
	v: pa.Launcher_View
	t.launcher_view(t.api, &v)
	ls: pa.Launcher_State
	t.launcher_state(t.api, &ls)
	lane, lrow = int(v.lane) + col, int(v.row) + row
	slot = -1
	if i64(lane) >= ls.lanes do return
	s: i64
	if t.launcher_slot_at(t.api, i64(lane), i64(lrow), &s) == .Ok do slot = int(s)
	if slot < 0 {
		l: pa.Lane_State
		t.launcher_lane(t.api, i64(lane), &l)
		plus = i64(lrow) == l.rows
	}
	return
}

// A press (`on`) or a release of grid index `i` in Perform.
@(private)
perform_press :: proc(g: ^Grid, i: int, on: bool, velocity: f32) {
	p := (^Push2)(g.cs.user)
	t := p.pads_api
	q, col, row := perform_cell(i)
	switch q {
	case .Launcher:
		slot, lane, _, plus := perform_slot(t, col, row)
		if !on {
			if slot >= 0 do t.launcher_press(t.api, i64(slot), false, false)
			return
		}
		if slot < 0 {
			if plus {
				n: i64
				if t.launcher_new_sequence(t.api, i64(lane), &n) == .Ok do t.sequence_select(t.api, n)
			}
			return
		}
		st: pa.Sequence_State
		t.sequence_state(t.api, i64(slot), &st)
		n: i64
		switch {
		case p.delete_held:   t.sequence_clear(t.api, i64(slot))
		case p.dup_held:      t.sequence_duplicate(t.api, i64(slot), &n)
		case p.select_held:   t.sequence_select(t.api, i64(slot))
		case !st.used:        t.sequence_select(t.api, i64(slot)) // (empty: gone to, to make it)
		case p.shift.held:    t.launcher_press(t.api, i64(slot), true, true) // (alone)
		case:                 t.launcher_press(t.api, i64(slot), true, false)
		}
	case .Pads:
		if !on do return
		n := perform_pad(t, col, row)
		if n >= pa.PADS do return
		if p.delete_held do t.pad_clear(t.api, i64(n))
		else do t.perform_select_pad(t.api, i64(n)) // (it sounds through its remap)
	case .Effects:
		fx := perform_fx(col, row)
		if on && p.select_held { // (Select: it in Device)
			app_show(p, fmt.tprintf("fx %d", fx + 1))
			p.mirror_kind = .Device
			bank_select(p, 0, force = true)
			return
		}
		t.effect_press(t.api, i64(fx), on, clamp(velocity, 0, 1) if on else -1)
	case .Bar:
		if !on do return
		ls: pa.Launcher_State
		t.launcher_state(t.api, &ls)
		v: pa.Launcher_View
		t.launcher_view(t.api, &v)
		switch row {
		case 0: if lane := v.lane + i64(col); lane < ls.lanes do t.launcher_stop_lane(t.api, lane)
		case 1: t.launcher_set_quantize(t.api, pa.Launch_Quantize(col))
		case 2:
			switch col {
			case 0: t.launcher_set_hold(t.api, false)
			case 1: t.launcher_set_hold(t.api, true)
			case 2: t.launcher_set_continue(t.api, !ls.continue_)
			case 3: t.launcher_set_recording(t.api, !ls.recording)
			}
		case 3:
			switch col {
			case 0: t.launcher_stop_all(t.api)
			case 1: t.effect_set_latch(t.api, !v.fx_latch)
			case 2: n: i64; t.launcher_add_lane(t.api, &n)
			case 3: t.launcher_set_keys(t.api, !v.keys)
			}
		}
	}
}

// An effect pad's pressure (0..1): how hard it plays while held.
@(private)
perform_pressure :: proc(g: ^Grid, i: int, pressure: f32) {
	t := (^Push2)(g.cs.user).pads_api
	q, col, row := perform_cell(i)
	if q == .Effects do t.effect_pressure(t.api, i64(perform_fx(col, row)), clamp(pressure, 0, 1))
}

// --- the layers ---------------------------------------------------------------------------------

PERFORM_LAYERS := []Layer{perform_launcher, perform_pads, perform_effects, perform_bar, held_layer}

// The launcher's window: each sequence in its colour (an empty one dark, a
// lane's + dim), the one shown white, a playing one green on every beat,
// a queued one every other eighth.
@(private)
perform_launcher :: proc(g: ^Grid, f: ^Frame) {
	t := (^Push2)(g.cs.user).pads_api
	if t == nil do return
	tr: pa.Transport_State
	t.transport_state(t.api, &tr)
	ph := beat_phase(tr.timeline_beat)
	for row in 0 ..< 4 do for col in 0 ..< 4 {
		i := perform_index(.Launcher, col, row)
		slot, lane, _, plus := perform_slot(t, col, row)
		if slot < 0 {
			if plus do f[i] = cell_index(W_DIM_CELL)
			continue
		}
		st: pa.Sequence_State
		t.sequence_state(t.api, i64(slot), &st)
		if st.used do f[i] = cell_colour(u32(st.color))
		if st.current do f[i] = cell_index(WHITE if st.used else DIM_WHITE)
		if !tr.playing do continue
		l: pa.Lane_State
		t.launcher_lane(t.api, i64(lane), &l)
		if l.playing == i64(slot) && ph < 0.5 do f[i] = cell_index(GREEN)
		if l.queued == i64(slot) && (ph < 0.25 || (ph >= 0.5 && ph < 0.75)) do f[i] = cell_index(GREEN)
	}
}

// A dim cell (a lane's +).
W_DIM_CELL :: DIM_WHITE

// The pads' bank: as the Pads mode shows them (their colours, the
// selected white, a sounding one flashing).
@(private)
perform_pads :: proc(g: ^Grid, f: ^Frame) {
	p := (^Push2)(g.cs.user)
	t := p.pads_api
	if t == nil do return
	perf: pa.Perform_State
	t.perform_state(t.api, &perf)
	if perf.bank != g.routed_bank { // (another bank, here or in the window: its notes)
		g.routed_bank = perf.bank
		for c in g.pads.controls do if kit.owns(g, c) do grid_route(g, c)
	}
	for row in 0 ..< 4 do for col in 0 ..< 4 {
		n := int(perf.bank) * 16 + row * 4 + col
		if n >= pa.PADS do continue
		f[perform_index(.Pads, col, row)] = pad_cell(g, n, perf.selected == i64(n))
	}
}

// The effects: each dim in its kind's colour, bright while it plays.
@(private)
perform_effects :: proc(g: ^Grid, f: ^Frame) {
	t := (^Push2)(g.cs.user).pads_api
	if t == nil do return
	for row in 0 ..< 4 do for col in 0 ..< 4 {
		fx := perform_fx(col, row)
		es: pa.Effect_State
		t.effect_state(t.api, {place = .Perf, index = i64(fx)}, &es)
		c := kind_colour(es.kind)
		f[perform_index(.Effects, col, row)] = cell_colour(c if es.on else scale(c, PAD_UNLIT))
	}
}

// The Perform bar: lane stops (red while their lane plays), when a launch
// happens (the one set white), Launch or Hold, Continue, Rec (red),
// Stop All, FX Latch, + Lane, Keys (lit when on).
@(private)
perform_bar :: proc(g: ^Grid, f: ^Frame) {
	t := (^Push2)(g.cs.user).pads_api
	if t == nil do return
	ls: pa.Launcher_State
	t.launcher_state(t.api, &ls)
	v: pa.Launcher_View
	t.launcher_view(t.api, &v)
	tr: pa.Transport_State
	t.transport_state(t.api, &tr)
	on_off :: proc(on: bool) -> Cell { return cell_index(WHITE if on else DIM_WHITE) }
	any_playing := false
	for col in 0 ..< 4 {
		lane := v.lane + i64(col)
		if lane >= ls.lanes do continue
		l: pa.Lane_State
		t.launcher_lane(t.api, lane, &l)
		playing := tr.playing && l.playing >= 0
		f[perform_index(.Bar, col, 0)] = cell_index(RED if playing else DIM_RED)
	}
	for lane in 0 ..< ls.lanes {
		l: pa.Lane_State
		t.launcher_lane(t.api, lane, &l)
		if tr.playing && l.playing >= 0 do any_playing = true
	}
	for col in 0 ..< 4 do f[perform_index(.Bar, col, 1)] = on_off(int(ls.quantize) == col)
	f[perform_index(.Bar, 0, 2)] = on_off(!ls.hold)
	f[perform_index(.Bar, 1, 2)] = on_off(ls.hold)
	f[perform_index(.Bar, 2, 2)] = on_off(ls.continue_)
	f[perform_index(.Bar, 3, 2)] = cell_index(RED if ls.recording else DIM_RED)
	f[perform_index(.Bar, 0, 3)] = cell_index(RED if any_playing else DIM_RED)
	f[perform_index(.Bar, 1, 3)] = on_off(v.fx_latch)
	f[perform_index(.Bar, 2, 3)] = cell_index(DIM_WHITE if ls.lanes < pa.MAX_LANES else OFF)
	f[perform_index(.Bar, 3, 3)] = on_off(v.keys)
}

// An effect kind's colour (each its own hue).
@(private)
kind_colour :: proc(kind: i64) -> u32 {
	if kind <= 0 do return 0x404040
	return kit.rgb_to_hex(kit.hsv_to_rgb(f64(kind * 47 % 360), 0.75, 1))
}

// Perform's own buttons beside the grid: the scene buttons launch the
// launcher's rows shown (the bottom four), Octave Up and Down turn the
// pads' bank.
@(private)
perform_nav_setup :: proc(cs: ^kit.Control_Surface, p: ^Push2, octave_up, octave_down: ^kit.Control) -> ^kit.Component {
	c := kit.component_make(cs, "Perform Buttons")
	for r in 0 ..< 4 do kit.layer_bind(c.layer, "scene", p.scenes[7 - r]) // (scenes[7] at the bottom)
	kit.layer_bind(c.layer, "up", octave_up)
	kit.layer_bind(c.layer, "down", octave_down)
	c.on_activate = proc(c: ^kit.Component) {
		kit.task_every(c.cs, 200, proc(data: rawptr) { kit.redraw_owned((^kit.Component)(data)) }, c, c)
	}
	c.on_owned = proc(c: ^kit.Component, slot: string, control: ^kit.Control) {
		p := (^Push2)(c.cs.user)
		t := p.pads_api
		if t == nil do return
		perf: pa.Perform_State
		t.perform_state(t.api, &perf)
		switch slot {
		case "up":   kit.light_value(control, W_ON if perf.bank < 7 else W_DIM)
		case "down": kit.light_value(control, W_ON if perf.bank > 0 else W_DIM)
		case:        kit.light_value(control, W_ON)
		}
	}
	c.on_event = proc(c: ^kit.Component, e: kit.Event) {
		if e.kind != .Press do return
		p := (^Push2)(c.cs.user)
		t := p.pads_api
		if t == nil do return
		perf: pa.Perform_State
		t.perform_state(t.api, &perf)
		switch e.slot {
		case "up":   t.perform_set_bank(t.api, min(perf.bank + 1, 7))
		case "down": t.perform_set_bank(t.api, max(perf.bank - 1, 0))
		case:
			for r in 0 ..< 4 do if p.scenes[7 - r] == e.control {
				v: pa.Launcher_View
				t.launcher_view(t.api, &v)
				t.launcher_launch_row(t.api, v.row + i64(r))
			}
		}
		kit.redraw_owned(c)
		render(p)
	}
	return c
}
