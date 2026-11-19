package pads_push2

import "core:fmt"
import "core:math"

import "fsurf:draw"
import kit "fsurf:surface"

/*
Setup's last tab (Controller ›, the upper row's last button while Pads'
Settings show): the Push's own settings on the display (the surface's:
they are the hardware's, not Pads'), kept with the device's settings and
sent again whenever it starts:

- encoder 1: the pads' LEDs' brightness
- encoder 2: the display's brightness
- encoder 3: how hard the pads have to be hit (their velocity curve:
  Hard ... Softer)
- encoder 4: aftertouch: each pad's own (Poly), or one for all (Channel)

The lower row's last button (or Setup again) closes it.
*/

// The Push's own settings.
Push_Settings :: struct {
	led:     u8, // 0..127
	display: u8, // 0..255
	curve:   u8, // CURVES' index
	poly:    bool,
}

DEFAULT_PUSH_SETTINGS :: Push_Settings{led = 127, display = 255, curve = 2, poly = true}

// The pads' velocity curves: names, and each one's power (an output
// velocity is the hit's to this power).
CURVE_NAMES := [5]string{"Hard", "Firm", "Linear", "Soft", "Softer"}
CURVE_POWERS := [5]f64{2.0, 1.5, 1.0, 0.7, 0.5}

// The settings component (on the encoders and the lower row's last
// button while shown).
@(private)
setup_setup :: proc(cs: ^kit.Control_Surface, p: ^Push2) -> ^kit.Component {
	c := kit.component_make(cs, "Push Setup")
	for slot, i in ([4]string{"enc0", "enc1", "enc2", "enc3"}) do kit.layer_bind(c.layer, slot, p.encoders[i])
	kit.layer_bind(c.layer, "close", p.lower[7])
	c.on_owned = proc(c: ^kit.Component, slot: string, control: ^kit.Control) {
		if slot == "close" do kit.light_value(control, W_ON)
	}
	c.on_event = proc(c: ^kit.Component, e: kit.Event) {
		p := (^Push2)(c.cs.user)
		s := &p.push_settings
		switch {
		case e.slot == "close" && e.kind == .Press:
			setup_close(p)
			return
		case e.kind == .Delta:
			fine := p.shift.held
			switch e.slot {
			case "enc0": s.led = u8(clamp(int(s.led) + e.delta * (1 if fine else 2), 0, 127))
			case "enc1": s.display = u8(clamp(int(s.display) + e.delta * (1 if fine else 4), 0, 255))
			case "enc2":
				p.setup_turn[2] += e.delta
				if abs(p.setup_turn[2]) >= 4 {
					s.curve = u8(clamp(int(s.curve) + (1 if p.setup_turn[2] > 0 else -1), 0, len(CURVE_NAMES) - 1))
					p.setup_turn[2] = 0
				}
			case "enc3":
				p.setup_turn[3] += e.delta
				if abs(p.setup_turn[3]) >= 4 {
					s.poly = p.setup_turn[3] < 0
					p.setup_turn[3] = 0
				}
			case: return
			}
			setup_apply(c.cs, s^)
			setup_save(c.cs, s^)
			invalidate(c.cs)
		}
	}
	c.on_activate = proc(c: ^kit.Component) { invalidate(c.cs) }
	return c
}

// Shows the Push's settings (the encoders theirs until closed).
@(private)
setup_show :: proc(p: ^Push2) {
	if p.setup_open do return
	p.setup_before, p.setup_open = p.enc_modes.current, true
	kit.modes_select(p.enc_modes, kit.modes_find(p.enc_modes, "setup"))
	if p.mode_buttons != nil do kit.redraw_owned(p.mode_buttons)
	invalidate(p.enc_modes.cs)
}

@(private)
setup_close :: proc(p: ^Push2) {
	if !p.setup_open do return
	p.setup_open = false
	kit.modes_select(p.enc_modes, p.setup_before)
	if p.mode_buttons != nil do kit.redraw_owned(p.mode_buttons)
	invalidate(p.enc_modes.cs)
}

// The settings, as kept (the defaults when none are).
@(private)
setup_load :: proc(cs: ^kit.Control_Surface) -> Push_Settings {
	b := kit.settings_get(cs, context.temp_allocator)
	if len(b) != 4 do return DEFAULT_PUSH_SETTINGS
	return {led = min(b[0], 127), display = b[1], curve = min(b[2], u8(len(CURVE_NAMES) - 1)), poly = b[3] != 0}
}

@(private)
setup_save :: proc(cs: ^kit.Control_Surface, s: Push_Settings) {
	b := [4]u8{s.led, s.display, s.curve, 1 if s.poly else 0}
	kit.settings_set(cs, b[:])
}

// Sends settings `s` to the Push: the LEDs' and the display's brightness,
// the pads' velocity curve (eight messages of 16 entries), aftertouch.
@(private)
setup_apply :: proc(cs: ^kit.Control_Surface, s: Push_Settings) {
	led := [?]u8{0xF0, 0x00, 0x21, 0x1D, 0x01, 0x01, 0x06, s.led & 0x7F, 0xF7}
	kit.send(cs, led[:])
	disp := [?]u8{0xF0, 0x00, 0x21, 0x1D, 0x01, 0x01, 0x08, s.display & 0x7F, s.display >> 7, 0xF7}
	kit.send(cs, disp[:])
	at := [?]u8{0xF0, 0x00, 0x21, 0x1D, 0x01, 0x01, 0x1E, 1 if s.poly else 0, 0xF7}
	kit.send(cs, at[:])
	power := CURVE_POWERS[min(int(s.curve), len(CURVE_POWERS) - 1)]
	for start := 0; start < 128; start += 16 {
		m: [8 + 16 + 1]u8
		copy(m[:], []u8{0xF0, 0x00, 0x21, 0x1D, 0x01, 0x01, 0x20, u8(start)})
		for k in 0 ..< 16 {
			x := f64(start + k) / 127
			m[8 + k] = u8(clamp(math.round(127 * math.pow(x, power)), 1 if start + k > 0 else 0, 127))
		}
		m[24] = 0xF7
		kit.send(cs, m[:])
	}
}

// The settings page: a column an encoder, its name, its value, a bar.
@(private)
draw_setup :: proc(cv: ^draw.Canvas, p: ^Push2) {
	sans, semi := draw.open_sans(), draw.open_sans(.Semibold)
	s := p.push_settings
	draw.type_text_in(cv, semi, 18, {10, 0, 600, NAMES_Y}, "Push 2 settings", TEXT, .Left)
	draw.type_text_in(cv, sans, 14, {480, 0, 470, NAMES_Y}, "Shift: finer · Setup or Close: back", FAINT, .Right)
	names := [8]string{"LEDs", "Display", "Pad response", "Aftertouch", "", "", "", ""}
	values := [4]string{
		fmt.tprintf("%d%%", int(math.round(f64(s.led) / 1.27))),
		fmt.tprintf("%d%%", int(math.round(f64(s.display) / 2.55))),
		CURVE_NAMES[min(int(s.curve), len(CURVE_NAMES) - 1)],
		"Poly" if s.poly else "Channel",
	}
	fracs := [4]f32{f32(s.led) / 127, f32(s.display) / 255, f32(s.curve) / f32(len(CURVE_NAMES) - 1), 1 if s.poly else 0}
	labels(cv, sans, NAMES_Y, names, -1)
	for k in 0 ..< 4 {
		x := k * COL
		draw.type_text_in(cv, semi, 24, {x, VIEW_Y + 6, COL, 32}, values[k], LIT if p.touched[k] else TEXT, .Center)
		draw.aa_round_rect(cv, f32(x + 14), f32(VIEW_Y + 48), f32(COL - 28), 6, 3, 0x2A2A33)
		draw.aa_round_rect(cv, f32(x + 14), f32(VIEW_Y + 48), max(f32(COL - 28) * fracs[k], 6), 6, 3, ACCENT)
	}
	labels(cv, sans, LOWER_Y, {"", "", "", "", "", "", "", "Close"}, 7)
}
