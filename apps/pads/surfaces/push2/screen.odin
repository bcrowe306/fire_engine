package pads_push2

import "core:fmt"

import abi "fsurf:abi"
import "fsurf:draw"
import kit "fsurf:surface"
import pa "../../api"

/*
The display, 960 x 160, a column of 120 pixels an encoder:

	  0 -  24  the upper row's labels (Mix's pages, Device's banks)
	 24 -  44  the encoders' names
	 44 - 112  the view: Pads' (the device), or the surface's own (Mix)
	112 - 136  the encoders' values
	136 - 160  the lower row's labels (the pads, the chain's devices)

Device on Pads' panel, and a dialog in the window: drawn all by Pads (its
views, 960 x 160), black behind.

A touched encoder's column is lit, its value large. Drawn again when Pads
says something changed and 25 times a second (the view moves: envelopes,
LFOs, the playhead); sent 30 times a second (Push 2 wants a steady stream).
*/

COL :: 120
UPPER_Y :: 0
NAMES_Y :: 24
VIEW_Y :: 44
VIEW_H :: 68
VALUES_Y :: 112
LOWER_Y :: 136

BG :: 0x000000
FAINT :: 0x8A8A94
TEXT :: 0xE8E8EC
LIT :: 0xFFFFFF
ACCENT :: 0xFFB030
COLUMN_LIT :: 0x1C2230

@(private)
screen_setup :: proc(cs: ^kit.Control_Surface) -> ^kit.Component {
	screen := kit.component_make(cs, "Screen")
	screen.daw_topics = {.Transport, .Tracks, .Mixer, .Devices, .Parameters}
	screen.on_daw = proc(c: ^kit.Component, e: abi.Daw_Event) { invalidate(c.cs) }
	screen.on_activate = proc(c: ^kit.Component) {
		invalidate(c.cs)
		kit.task_every(c.cs, 40, proc(data: rawptr) { invalidate((^kit.Control_Surface)(data)) }, c.cs, c)
	}
	d := kit.display(cs, 0)
	d.draw = draw_screen
	d.send = kit.display_send_push2
	d.resend = true // (a steady stream, as Live sends)
	kit.place_display(d, 66, 36, 234, 39)
	return screen
}

invalidate :: proc(cs: ^kit.Control_Surface) {
	kit.display_invalidate(kit.display(cs, 0))
}

@(private)
draw_screen :: proc(d: ^kit.Display, cv: ^draw.Canvas) {
	cs := d.cs
	p := (^Push2)(cs.user)
	sans, semi := draw.open_sans(), draw.open_sans(.Semibold)
	draw.clear(cv, BG)
	if cs.daw == nil {
		draw.type_text_in(cv, sans, 28, {0, 0, cv.width, cv.height}, "Pads isn't there", TEXT, .Center)
		return
	}
	// A touched encoder's column, lit behind everything.
	for i in 0 ..< 8 do if p.touched[i] do draw.aa_round_rect(cv, f32(i * COL + 2), NAMES_Y, COL - 4, LOWER_Y - NAMES_Y, 6, COLUMN_LIT)
	if p.setup_open {
		draw_setup(cv, p)
		return
	}
	if p.dialog_open {
		view_blit(cv, p, cs, .Dialog, 0, 0, 160)
		return
	}
	if in_device(p) || in_mirror(p) do draw_device(cv, p, cs, sans, semi)
	else do draw_mix(cv, p, cs, sans, semi)
	// The master, tempo and swing encoders, touched: their values, over it all.
	if p.touched[8] do overlay(cv, semi, "Main", main_text(p, cs))
	if p.touched[10] do overlay(cv, semi, "Tempo", fmt.tprintf("%.1f BPM", kit.daw_get(cs, .Tempo)))
	if p.touched[9] do overlay(cv, semi, "Swing (the sequence's and input quantize's)", swing_text(p))
}

// A big value over the middle (an encoder off the strip touched).
@(private)
overlay :: proc(cv: ^draw.Canvas, f: ^draw.Typeface, name, value: string) {
	draw.aa_round_rect(cv, 300, 34, 360, 92, 10, 0x15151A)
	draw.aa_round_rect_outline(cv, 300, 34, 360, 92, 10, 1.5, 0x3A3A44)
	draw.type_text_in(cv, f, 18, {300, 40, 360, 26}, name, FAINT, .Center)
	draw.type_text_in(cv, f, 36, {300, 66, 360, 52}, value, LIT, .Center)
}

// A row of eight labels, the lit one bright on its own colour.
@(private)
labels :: proc(cv: ^draw.Canvas, f: ^draw.Typeface, y: int, names: [8]string, lit: int, colours: [8]u32 = {}) {
	for i in 0 ..< 8 {
		if names[i] == "" do continue
		x := i * COL
		c := colours[i]
		if i == lit {
			draw.aa_round_rect(cv, f32(x + 4), f32(y + 3), COL - 8, 18, 4, c if c != 0 else 0x3A3F4C)
			draw.type_text_in(cv, f, 14, {x + 6, y + 2, COL - 12, 20}, names[i], LIT, .Center)
		} else {
			if c != 0 do draw.fill_rect(cv, {x + 10, y + 20, COL - 20, 2}, c)
			draw.type_text_in(cv, f, 14, {x + 6, y + 2, COL - 12, 20}, names[i], FAINT, .Center)
		}
	}
}

// Mix: the pages above, the pads below; each column's level (a bar
// filling up for volume and sends, a mark from the middle for pan), and
// its value.
@(private)
draw_mix :: proc(cv: ^draw.Canvas, p: ^Push2, cs: ^kit.Control_Surface, sans, semi: ^draw.Typeface) {
	pages: [8]string
	for i in 0 ..< mix_pages(cs) do pages[i] = mix_page_name(cs, i)
	labels(cv, semi, UPPER_Y, pages, p.mix_page)
	names: [8]string
	colours: [8]u32
	lit := -1
	sel := kit.selected_track(cs)
	for i in 0 ..< 8 {
		t, ok := kit.mixer_strip_track(p.volumes, i)
		if !ok do continue
		names[i] = kit.daw_text(cs, .Track_Name, t)
		colours[i] = u32(kit.daw_get(cs, .Track_Color, t)) & 0xFFFFFF
		if t == sel do lit = i
		x := f32(i * COL)
		// Its name (the page's), its level, its value.
		head := names[i]
		if kit.daw_flag(cs, .Track_Mute, t) do head = fmt.tprintf("%s · M", head)
		if kit.daw_flag(cs, .Track_Solo, t) do head = fmt.tprintf("%s · S", head)
		draw.type_text_in(cv, sans, 14, {int(x) + 4, NAMES_Y, COL - 8, 20}, head, TEXT if p.touched[i] else FAINT, .Center)
		value: f64
		text: string
		switch p.mix_page {
		case 0:
			value, text = kit.daw_get(cs, .Track_Volume, t), kit.daw_text(cs, .Track_Volume, t)
		case 1:
			value, text = kit.daw_get(cs, .Track_Pan, t), kit.daw_text(cs, .Track_Pan, t)
		case:
			value, text = kit.daw_get(cs, .Track_Send, t, p.mix_page - 2), kit.daw_text(cs, .Track_Send, t, p.mix_page - 2)
		}
		colour := colours[i] if colours[i] != 0 else ACCENT
		cx := x + COL / 2
		if p.mix_page == 1 {
			// Pan: a track, a mark from the middle.
			draw.aa_round_rect(cv, x + 14, VIEW_Y + 30, COL - 28, 8, 4, 0x26262C)
			at := x + 14 + f32(value) * (COL - 28)
			draw.aa_round_rect(cv, min(at, cx), VIEW_Y + 30, abs(at - cx) + 1, 8, 4, colour)
			draw.aa_circle(cv, at, VIEW_Y + 34, 7, LIT)
		} else {
			v := f32(clamp(value, 0, 1))
			draw.aa_round_rect(cv, cx - 14, VIEW_Y + 4, 28, VIEW_H - 8, 5, 0x26262C)
			h := (VIEW_H - 8) * v
			if v > 0.01 do draw.aa_round_rect(cv, cx - 14, VIEW_Y + 4 + (VIEW_H - 8) - h, 28, h, 5, colour)
		}
		size: f32 = 22 if p.touched[i] else 16
		draw.type_text_in(cv, semi if p.touched[i] else sans, size, {int(x) + 2, VALUES_Y, COL - 4, 24}, text, LIT if p.touched[i] else TEXT, .Center)
	}
	labels(cv, semi, LOWER_Y, names, lit, colours)
}

// Device: the banks above (arrows to more), the chain's devices below; the
// parameters' names and values, Pads' view of the device between them (a
// sampler's Overview: the sample, taller).
@(private)
draw_device :: proc(cv: ^draw.Canvas, p: ^Push2, cs: ^kit.Control_Surface, sans, semi: ^draw.Typeface) {
	if in_mirror(p) {
		// Pads' panel, all of it (its tabs, picture, knobs and choices).
		view_blit(cv, p, cs, p.mirror_kind, 0, 0, 160)
		return
	}
	row := bank_row(p)
	banks: [8]string
	lit := -1
	for b, i in row {
		switch {
		case b == BANK_LEFT || b == BANK_RIGHT: arrow(cv, i, b == BANK_LEFT)
		case b >= 0:
			banks[i] = bank_name(p, b)
			if b == p.dev_bank do lit = i
		}
	}
	labels(cv, semi, UPPER_Y, banks, lit)
	{
		n := int(kit.daw_get(cs, .Param_Count))
		// Pads' view of the device: none yet (a synth's, an effect's).
		for i in 0 ..< 8 {
			k := p.device.bank * 8 + i
			if k >= n do continue
			x := i * COL
			touched := p.touched[i]
			draw.type_text_in(cv, sans, 14, {x + 4, NAMES_Y, COL - 8, 20}, kit.daw_text(cs, .Param_Name, k), TEXT if touched else FAINT, .Center)
			v := f32(kit.daw_get(cs, .Param_Value, k))
			// A small arc beside the value: where it is.
			draw.aa_arc(cv, f32(x) + 16, f32(VALUES_Y) + 12, 8, 2.5, -135, 135, 0x34343C)
			if v > 0.005 do draw.aa_arc(cv, f32(x) + 16, f32(VALUES_Y) + 12, 8, 2.5, -135, -135 + 270 * v, ACCENT)
			size: f32 = 20 if touched else 15
			draw.type_text_in(cv, semi if touched else sans, size, {x + 28, VALUES_Y, COL - 32, 24}, kit.daw_text(cs, .Param_Value, k), LIT if touched else TEXT, .Center)
		}
	}
	chain: [8]string
	for i in 0 ..< min(int(kit.daw_get(cs, .Device_Count)), 8) do chain[i] = kit.daw_text(cs, .Device_Name, i)
	labels(cv, semi, LOWER_Y, chain, int(kit.daw_get(cs, .Selected_Device)))
}

// An arrow on the upper row's button `i`: to the banks before (left) or after.
@(private)
arrow :: proc(cv: ^draw.Canvas, i: int, left: bool) {
	cx, cy: f32 = f32(i * COL + COL / 2), UPPER_Y + 12
	path := draw.path_make()
	d: f32 = -1 if left else 1
	draw.path_move(&path, cx + 6 * d, cy)
	draw.path_line(&path, cx - 5 * d, cy - 7)
	draw.path_line(&path, cx - 5 * d, cy + 7)
	draw.path_close(&path)
	draw.fill_path(cv, &path, TEXT)
}

// Pads' view (fire.pads `view_frame`) into rows `at` to `at + h`: its
// newest frame (a frame behind). Whether there was one.
@(private)
view_blit :: proc(cv: ^draw.Canvas, p: ^Push2, cs: ^kit.Control_Surface, kind: pa.View_Kind, page: i64, at, h: int) -> bool {
	t := p.pads_api
	if t == nil || t.view_frame == nil do return false
	frame: i64
	if t.view_frame(t.api, kind, page, 960, i64(h), raw_data(p.view), i64(960 * h * 4), &frame) != .Ok || frame == 0 do return false
	p.view_frame = frame
	for y in 0 ..< h {
		row := p.view[y * 960 * 4:]
		for x in 0 ..< 960 {
			c := u32(row[x * 4]) << 16 | u32(row[x * 4 + 1]) << 8 | u32(row[x * 4 + 2])
			draw.set(cv, x, at + y, c)
		}
	}
	return true
}

// The master encoder's value: Main's level (without Pads: the selected
// track's).
@(private)
main_text :: proc(p: ^Push2, cs: ^kit.Control_Surface) -> string {
	t := p.pads_api
	if t == nil do return kit.daw_text(cs, .Track_Volume, kit.selected_track(cs))
	st: pa.Bus_State
	t.mixer_bus_state(t.api, pa.MAIN, &st)
	return "-inf" if st.volume <= -60 else fmt.tprintf("%.1f dB", st.volume)
}
