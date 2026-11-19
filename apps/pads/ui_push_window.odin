// The on-screen Push 2 (View > Push 2 on Screen, --virtual-push2): Push 2's
// surface drawn as the device, its display as Pads draws it, played with
// the mouse. With no Push 2 plugged in, Pads starts the surface with no
// controller (`surface_assign_virtual`): what you click reaches it as the
// device's MIDI would, and its lights and display show here. With one
// plugged in, the window shows that one (both play it). Closing the window
// stops the one Pads started.
//
// Its lights are the device's: Pads keeps a copy of Push 2's colour
// palette from what the surface sends it (its SysEx palette entries, as
// the hardware does), so a pad, a row's strip or a button's backlit name
// shows the colour (or the white's brightness) the device would, blinking
// and pulsing as its MIDI channel says.
package pads

import "core:fmt"
import "core:math"
import "core:strings"

import "app:ui"
import abi "fsurf:abi"
import fsurf "fsurf:host"
import pa "api"
import im "deps:imgui"

// Push 2's surface's id (apps/pads/surfaces/push2).
PUSH2_ID :: "org.fire_engine.pads.push2"

// Its touches, which its layout doesn't give (surfaces/push2: NOTE_TOUCH,
// NOTE_STRIP_TOUCH): the track encoders' notes 0-7, master 8, swing 9,
// tempo 10.
@(private) PUSH2_TOUCH_MASTER :: 8
@(private) PUSH2_TOUCH_SWING :: 9
@(private) PUSH2_TOUCH_TEMPO :: 10

// How the window shows: a window of its own size, filling Pads' window, or
// over the whole screen.
Push_Window_Mode :: enum { Window, Fill, Full_Screen }

// The window's state.
Push_Window :: struct {
	open:    bool,
	shown:   bool, // open last frame (opening starts the surface; closing stops it)
	mode:    Push_Window_Mode,
	play:    Virtual_Play,
	shift:   bool, // the keyboard's Shift held Push 2's
	started: bool, // Pads started one with no controller
	why:     string, // why it wouldn't start (owned)
	palette: Push2_Palette,
	bpm:     f64, // (the lights' blinking and pulsing)
}

// Push 2's LED palette as the device has it: an index's colour (RGB LEDs)
// and white (the white LEDs' brightness, 0-127), set by the surface's
// SysEx (Set LED Color Palette Entry).
Push2_Palette :: struct {
	rgb:   [128]u32,
	white: [128]u8,
}

// The palette before the surface sets any: off, a grey ramp, white at the
// top (an index's white its own value).
push2_palette_init :: proc(pp: ^Push2_Palette) {
	for i in 0 ..< 128 {
		g := u32(i * 2)
		pp.rgb[i] = g << 16 | g << 8 | g
		pp.white[i] = u8(i)
	}
	pp.rgb[0], pp.rgb[127] = 0, 0xFFFFFF
}

// Hears what Push 2's surface sends: its palette entries kept.
push_window_listen :: proc(a: ^App) {
	push2_palette_init(&a.push_window.palette)
	a.api.surfaces.listen_user = a
	a.api.surfaces.listen = proc(user: rawptr, inst: ^fsurf.Instance, port: u32, b: []u8) {
		a := (^App)(user)
		if inst == nil || inst.descriptor == nil || string(inst.descriptor.id) != PUSH2_ID do return
		// F0 00 21 1D 01 01 03 index r(2) g(2) b(2) w(2) F7
		if len(b) == 17 && b[0] == 0xF0 && b[1] == 0x00 && b[2] == 0x21 && b[3] == 0x1D && b[6] == 0x03 && b[16] == 0xF7 {
			i := int(b[7] & 0x7F)
			c := proc(b: []u8, k: int) -> u32 { return u32(b[k] & 0x7F) | u32(b[k + 1] & 1) << 7 }
			pp := &a.push_window.palette
			pp.rgb[i] = c(b, 8) << 16 | c(b, 10) << 8 | c(b, 12)
			pp.white[i] = u8(min(c(b, 14), 127))
		}
	}
}

// The Push 2 surface running: its place, and whether it has no controller
// (one with a controller first).
@(private)
push_window_find :: proc(a: ^App) -> (index: i64, virtual: bool, ok: bool) {
	n, _ := pa.surface_count(&a.api)
	found := false
	for k in 0 ..< n {
		id, _ := pa.surface_id(&a.api, k)
		st, _ := pa.surface_state(&a.api, k)
		if id != PUSH2_ID || st != .Active do continue
		ports, _ := pa.surface_ports(&a.api, k)
		v := ports == "Virtual"
		if !v do return k, false, true
		if !found do index, virtual, found = k, true, true
	}
	return index, virtual, found
}

// Starts Push 2's surface with no controller (none running). Whether one
// is running now.
@(private)
push_window_start :: proc(a: ^App) -> bool {
	pw := &a.push_window
	if _, _, ok := push_window_find(a); ok do return true
	nl, _ := pa.surface_library_count(&a.api)
	for lib in 0 ..< nl {
		no, _ := pa.surface_offered_count(&a.api, lib)
		for k in 0 ..< no do if id, _ := pa.surface_offered_id(&a.api, lib, k); id == PUSH2_ID {
			if _, r := pa.surface_assign_virtual(&a.api, lib, k); r == .Ok {
				pw.started = true
				return true
			}
			why, _ := pa.last_error(&a.api)
			delete(pw.why)
			pw.why = fmt.aprintf("Push 2 wouldn't start: %s", why)
			return false
		}
	}
	delete(pw.why)
	pw.why = fmt.aprintf("Pads has no Push 2 surface (control surfaces aren't started)")
	return false
}

// Stops the Push 2 Pads started (if it did), letting everything held go.
@(private)
push_window_stop :: proc(a: ^App) {
	pw := &a.push_window
	if k, virtual, ok := push_window_find(a); ok {
		virtual_play_release(a, pa.surface_virtual(&a.api, k), &pw.play)
		if pw.shift do push_window_shift(a, k, false)
		if virtual && pw.started do pa.surface_unload(&a.api, k)
	}
	pw.started, pw.shift = false, false
	push_window_set_mode(a, .Window)
}

// Push 2's Shift held or let go (the keyboard's).
@(private)
push_window_shift :: proc(a: ^App, index: i64, on: bool) {
	if on do pa.surface_press(&a.api, index, "Shift")
	else do pa.surface_release(&a.api, index, "Shift")
	a.push_window.shift = on
}

// The window shown as `mode` (over the whole screen: Pads' window is).
push_window_set_mode :: proc(a: ^App, mode: Push_Window_Mode) {
	pw := &a.push_window
	if pw.mode == mode do return
	if pw.mode == .Full_Screen do ui.set_fullscreen(&a.platform, false)
	if mode == .Full_Screen do ui.set_fullscreen(&a.platform, true)
	pw.mode = mode
}

// Lets the window go (Pads closing).
push_window_destroy :: proc(a: ^App) {
	a.api.surfaces.listen = nil
	virtual_play_destroy(&a.push_window.play)
	delete(a.push_window.why)
	a.push_window.why = ""
}

@(private)
push_touch :: proc(v: ^fsurf.Virtual, k: int, on: bool) -> fsurf.Virtual_Messages {
	note := -1
	switch v.controls[k].label {
	case "Encoder":
		nth, _ := virtual_ordinal(v, k)
		note = nth - 1
	case "Master Encoder": note = PUSH2_TOUCH_MASTER
	case "Swing Encoder":  note = PUSH2_TOUCH_SWING
	case "Tempo Encoder":  note = PUSH2_TOUCH_TEMPO
	}
	if note < 0 do return {}
	c := v.controls[k]
	port := v.s.ports[c.port].input if int(c.port) < len(v.s.ports) else 0xFFFF_FFFF
	return {port = port, bytes = {{0x90, u8(note), 127 if on else 0}, {}}, sizes = {3, 0}, count = 1}
}

@(private)
push_bend :: proc(v: ^fsurf.Virtual, k: int) -> bool { return v.controls[k].label == "Touch Strip" }

// ── The device, drawn ─────────────────────────────────────────────────

// The buttons with RGB LEDs (the rest are white: their names backlit).
@(private)
push2_rgb :: proc(label: string) -> bool {
	switch label {
	case "Upper", "Lower", "Mute", "Solo", "Stop", "Play", "Record", "Automate": return true
	}
	return strings.contains(label, "/") // (the scene buttons: 1/32t...)
}

// Names as they're printed on the device (two lines where it has two).
@(private)
push2_print :: proc(label: string) -> string {
	switch label {
	case "Stop":         return "Stop\nClip"
	case "Double Loop":  return "Double\nLoop"
	case "Fixed Length": return "Fixed\nLength"
	case "Add Device":   return "Add\nDevice"
	case "Add Track":    return "Add\nTrack"
	}
	return label
}

@(private) PUSH2_BODY :: 0x141416
@(private) PUSH2_RUBBER :: 0x1c1c1f
@(private) PUSH2_UNLIT :: 0x46464d // a name with its light off (printed, unlit)
@(private) PUSH2_STRIP_OFF :: 0x2a2a2e

@(private)
rgba :: proc(rgb: u32, alpha: f32 = 1) -> u32 {
	return im.ColorConvertFloat4ToU32({f32((rgb >> 16) & 0xFF) / 255, f32((rgb >> 8) & 0xFF) / 255, f32(rgb & 0xFF) / 255, alpha})
}

// How bright a light is now (1: on), by its MIDI channel: 0 solid, 1-5 a
// one-shot (shown on), 6-10 pulsing and 11-15 blinking, at 1/24, 1/16,
// 1/8, 1/4 and 1/2 of a beat... of a bar's quarter notes.
@(private)
push2_anim :: proc(channel: i32, bpm: f64) -> f32 {
	if channel < 6 do return 1
	periods := [5]f64{1.0 / 6, 1.0 / 4, 1.0 / 2, 1, 2} // beats: a 24th note .. a half note
	beat := 60 / max(bpm, 20)
	period := periods[(channel - 6) % 5] * beat
	phase := math.mod(im.GetTime(), period) / period
	if channel <= 10 do return f32(0.5 + 0.5 * math.cos(phase * 2 * math.PI))
	return 1 if phase < 0.5 else 0
}

// A light's colour as the device shows it: an RGB LED's palette colour, a
// white LED's white (black when off).
@(private)
push2_light :: proc(pw: ^Push_Window, label: string, st: abi.Layout_State, rgb_led: bool) -> (c: u32, level: f32) {
	i := int(st.value & 0x7F)
	k := push2_anim(st.channel, pw.bpm)
	if rgb_led {
		c = pw.palette.rgb[i]
		r, g, b := f32((c >> 16) & 0xFF) * k, f32((c >> 8) & 0xFF) * k, f32(c & 0xFF) * k
		c = u32(r) << 16 | u32(g) << 8 | u32(b)
		level = max(r, g, b) / 255
		return
	}
	level = f32(pw.palette.white[i]) / 127 * k
	w := u32(255 * math.pow(level, 0.6))
	return w << 16 | w << 8 | w, level
}

// A name or icon's ink: lit, the light's colour, never so dim it can't be
// read (a dim LED behind printed text still shows it); off, barely there.
@(private)
push2_ink :: proc(c: u32, level: f32) -> u32 {
	if level < 0.02 do return PUSH2_UNLIT
	r, g, b := f32((c >> 16) & 0xFF), f32((c >> 8) & 0xFF), f32(c & 0xFF)
	top := max(r, g, b, 1)
	k := (0.42 + 0.58 * math.pow(clamp(level, 0, 1), 0.7)) * 255 / top
	return u32(min(r * k, 255)) << 16 | u32(min(g * k, 255)) << 8 | u32(min(b * k, 255))
}

// A rubber button: its body, lighter while held.
@(private)
push2_button :: proc(dl: ^im.DrawList, r: Virtual_Rect, mm: f32, down: bool) {
	round := min(0.9 * mm, (r.y1 - r.y0) / 3)
	im.DrawList_AddRectFilled(dl, {r.x0, r.y0 + 0.25 * mm}, {r.x1, r.y1 + 0.25 * mm}, rgba(0x070708), round) // (its shadow)
	im.DrawList_AddRectFilled(dl, {r.x0, r.y0}, {r.x1, r.y1}, rgba(0x26262a if down else PUSH2_RUBBER), round)
	im.DrawList_AddLine(dl, {r.x0 + round, r.y0 + 0.5}, {r.x1 - round, r.y0 + 0.5}, rgba(0x2e2e33), 1) // (light on its top edge)
}

// Text with a glow when lit.
@(private)
push2_text :: proc(dl: ^im.DrawList, at: im.Vec2, size: f32, ink: u32, level: f32, text: string, room: f32 = 0) {
	font := im.GetFont()
	size := size
	y := at.y
	lines := strings.split_lines(text, context.temp_allocator)
	if room > 0 { // (smaller where the widest line wouldn't fit)
		widest: f32
		for line in lines do widest = max(widest, im.CalcTextSize(fmt.ctprintf("%s", line)).x * size / im.GetFontSize())
		if widest > room do size = size * room / widest
	}
	for line in lines {
		ct := fmt.ctprintf("%s", line)
		if level > 0.15 {
			g := rgba(ink, 0.22 * clamp(level, 0, 1))
			for d in ([4]im.Vec2{{-0.7, 0}, {0.7, 0}, {0, -0.7}, {0, 0.7}}) do im.DrawList_AddTextFontPtr(dl, font, size, {at.x + d.x, y + d.y}, g, ct)
		}
		im.DrawList_AddTextFontPtr(dl, font, size, {at.x, y}, rgba(ink), ct)
		y += size * 1.05
	}
}

// The body: the device's slab, its edge catching the light.
@(private)
push2_body :: proc(dl: ^im.DrawList, v: ^fsurf.Virtual, r: Virtual_Rect, mm: f32) {
	round := 3.5 * mm
	im.DrawList_AddRectFilled(dl, {r.x0 + 1.5 * mm, r.y0 + 2.5 * mm}, {r.x1 + 1.5 * mm, r.y1 + 2.5 * mm}, rgba(0x000000, 0.45), round) // (its shadow)
	im.DrawList_AddRectFilled(dl, {r.x0, r.y0}, {r.x1, r.y1}, rgba(PUSH2_BODY), round)
	im.DrawList_AddRect(dl, {r.x0, r.y0}, {r.x1, r.y1}, rgba(0x2a2a2e), round, 1.2)
	im.DrawList_AddRect(dl, {r.x0 + 1.5, r.y0 + 1.5}, {r.x1 - 1.5, r.y1 - 1.5}, rgba(0x1b1b1e), round, 1)
}

// A diamond of four buttons (the arrows; Octave and Page): its square,
// split corner to corner, each quarter one button with its mark.
@(private)
push2_quarter :: proc(dl: ^im.DrawList, v: ^fsurf.Virtual, pl: ^Virtual_Play, k: int, r: Virtual_Rect, mm: f32, ink: u32, level: f32, down: bool, label: string) -> bool {
	// The square: the four's rectangles together.
	group := [4]string{"Up", "Down", "Left", "Right"}
	if strings.has_prefix(label, "Octave") || strings.has_prefix(label, "Page") do group = {"Octave Up", "Octave Down", "Page <", "Page >"}
	x0, y0, x1, y1 := r.x0, r.y0, r.x1, r.y1
	scale := mm
	ox, oy := r.x0 - v.controls[k].x * scale, r.y0 - v.controls[k].y * scale
	for c in v.controls do for g in group do if c.label == g {
		x0, y0 = min(x0, ox + c.x * scale), min(y0, oy + c.y * scale)
		x1, y1 = max(x1, ox + (c.x + c.w) * scale), max(y1, oy + (c.y + c.h) * scale)
	}
	cx, cy := (x0 + x1) / 2, (y0 + y1) / 2
	// Drawn once, with the first: the square and its cross.
	if label == group[0] {
		im.DrawList_AddRectFilled(dl, {x0, y0 + 0.25 * mm}, {x1, y1 + 0.25 * mm}, rgba(0x070708), 0.9 * mm)
		im.DrawList_AddRectFilled(dl, {x0, y0}, {x1, y1}, rgba(PUSH2_RUBBER), 0.9 * mm)
	}
	// This quarter.
	tri: [3]im.Vec2
	switch label {
	case group[0]: tri = {{x0, y0}, {x1, y0}, {cx, cy}}
	case group[1]: tri = {{x0, y1}, {x1, y1}, {cx, cy}}
	case group[2]: tri = {{x0, y0}, {x0, y1}, {cx, cy}}
	case:          tri = {{x1, y0}, {x1, y1}, {cx, cy}}
	}
	if down do im.DrawList_AddTriangleFilled(dl, tri[0], tri[1], tri[2], rgba(0x2a2a2f))
	im.DrawList_AddLine(dl, tri[0], tri[2], rgba(0x08080a), 0.35 * mm)
	im.DrawList_AddLine(dl, tri[1], tri[2], rgba(0x08080a), 0.35 * mm)
	// Its mark: a chevron (and Octave's and Page's names).
	s := (x1 - x0) * 0.07
	th := max(0.35 * mm, 1.2)
	inner := (x1 - x0) * 0.3
	fs := clamp(3.0 * mm, 7, 44)
	switch label {
	case group[0]:
		at := im.Vec2{cx, y0 + inner * 0.95}
		im.DrawList_AddLine(dl, {at.x - s, at.y + s * 0.6}, at, rgba(ink), th)
		im.DrawList_AddLine(dl, at, {at.x + s, at.y + s * 0.6}, rgba(ink), th)
		if group[0] == "Octave Up" do push2_text(dl, {cx - im.CalcTextSize("Octave").x * fs / im.GetFontSize() / 2, at.y - fs * 1.25}, fs, ink, level, "Octave")
	case group[1]:
		at := im.Vec2{cx, y1 - inner * 0.95}
		im.DrawList_AddLine(dl, {at.x - s, at.y - s * 0.6}, at, rgba(ink), th)
		im.DrawList_AddLine(dl, at, {at.x + s, at.y - s * 0.6}, rgba(ink), th)
		if group[0] == "Octave Up" do push2_text(dl, {cx - im.CalcTextSize("Octave").x * fs / im.GetFontSize() / 2, at.y + fs * 0.35}, fs, ink, level, "Octave")
	case group[2]:
		at := im.Vec2{x0 + inner * 0.95, cy}
		im.DrawList_AddLine(dl, {at.x + s * 0.6, at.y - s}, at, rgba(ink), th)
		im.DrawList_AddLine(dl, at, {at.x + s * 0.6, at.y + s}, rgba(ink), th)
		if group[0] == "Octave Up" do push2_text(dl, {x0 + (x1 - x0) * 0.04, cy - fs * 0.4}, fs * 0.75, ink, level, "Page")
	case:
		at := im.Vec2{x1 - inner * 0.95, cy}
		im.DrawList_AddLine(dl, {at.x - s * 0.6, at.y - s}, at, rgba(ink), th)
		im.DrawList_AddLine(dl, at, {at.x - s * 0.6, at.y + s}, rgba(ink), th)
		if group[0] == "Octave Up" do push2_text(dl, {x1 - (x1 - x0) * 0.04 - im.CalcTextSize("Page").x * fs * 0.75 / im.GetFontSize(), cy - fs * 0.4}, fs * 0.75, ink, level, "Page")
	}
	return true
}

// Each control as on the device.
@(private)
push2_paint :: proc(dl: ^im.DrawList, v: ^fsurf.Virtual, pl: ^Virtual_Play, k: int, r: Virtual_Rect, mm: f32, st: abi.Layout_State, down: bool) -> bool {
	a := (^App)(pl.hooks.user)
	pw := &a.push_window
	c := v.controls[k]
	label := c.label
	w, h := r.x1 - r.x0, r.y1 - r.y0
	fs := clamp(3.8 * mm, 7, 56) // (the printed names' size)
	#partial switch c.kind {
	case .Encoder:
		cx, cy := (r.x0 + r.x1) / 2, (r.y0 + r.y1) / 2
		R := min(w, h) / 2
		im.DrawList_AddCircleFilled(dl, {cx + 0.3 * mm, cy + 0.6 * mm}, R * 1.04, rgba(0x000000, 0.6), 48) // (its shadow)
		im.DrawList_AddCircleFilled(dl, {cx, cy}, R, rgba(0x232326), 48)
		for t in 0 ..< 48 { // (its knurled edge)
			ang := f32(t) / 48 * 2 * math.PI
			dx, dy := math.cos(ang), math.sin(ang)
			im.DrawList_AddLine(dl, {cx + dx * R * 0.84, cy + dy * R * 0.84}, {cx + dx * R * 0.99, cy + dy * R * 0.99}, rgba(0x34343a if t % 2 == 0 else 0x18181b), max(0.3 * mm, 1))
		}
		im.DrawList_AddCircleFilled(dl, {cx, cy}, R * 0.8, rgba(0x1e1e21), 48)
		im.DrawList_AddCircleFilled(dl, {cx - R * 0.18, cy - R * 0.22}, R * 0.42, rgba(0xffffff, 0.035), 32) // (the light on its top)
		if down do im.DrawList_AddCircle(dl, {cx, cy}, R * 1.02, rgba(0xffffff, 0.55), 48, max(0.3 * mm, 1))
		return true
	case .Pad:
		col, level := push2_light(pw, label, st, true)
		round := 1.1 * mm
		if level > 0.02 {
			face := push2_ink(col, level * 0.8) // (a dim colour still its colour, as the rubber shows it)
			face = mix_rgb(0x202023, face, 0.35 + 0.6 * clamp(level * 1.4, 0, 1))
			if level > 0.3 do im.DrawList_AddRectFilled(dl, {r.x0 - 0.8 * mm, r.y0 - 0.8 * mm}, {r.x1 + 0.8 * mm, r.y1 + 0.8 * mm}, rgba(face, 0.18 * level), round + 0.8 * mm) // (its glow)
			im.DrawList_AddRectFilled(dl, {r.x0, r.y0}, {r.x1, r.y1}, rgba(face), round)
			im.DrawList_AddRectFilled(dl, {r.x0 + w * 0.12, r.y0 + h * 0.12}, {r.x1 - w * 0.12, r.y1 - h * 0.12}, rgba(mix_rgb(face, 0xffffff, 0.35), 0.35 * level), round * 2) // (brighter in the middle: frosted)
		} else {
			im.DrawList_AddRectFilled(dl, {r.x0, r.y0}, {r.x1, r.y1}, rgba(0x202023), round)
			im.DrawList_AddRect(dl, {r.x0, r.y0}, {r.x1, r.y1}, rgba(0x2b2b30), round, 1)
		}
		if down do im.DrawList_AddRectFilled(dl, {r.x0, r.y0}, {r.x1, r.y1}, rgba(0x000000, 0.28), round)
		return true
	case .Button:
		if label == "Touch Strip" {
			im.DrawList_AddRectFilled(dl, {r.x0, r.y0}, {r.x1, r.y1}, rgba(0x18181b), 1 * mm)
			im.DrawList_AddRect(dl, {r.x0, r.y0}, {r.x1, r.y1}, rgba(0x26262a), 1 * mm, 1)
			// Its 31 lights down its left: where the pitch is.
			pos: f32 = 0.5 // (let go: the middle)
			if down do pos = clamp(1 - (im.GetMousePos().y - r.y0) / max(h, 1), 0, 1)
			n := 31
			lx := r.x0 + w * 0.17
			lit := int(math.round(pos * f32(n - 1)))
			for i in 0 ..< n {
				y := r.y1 - h * 0.04 - f32(i) * (h * 0.92) / f32(n - 1)
				on := i == lit
				if on do im.DrawList_AddCircleFilled(dl, {lx, y}, 1.2 * mm, rgba(0xffffff, 0.18), 16)
				im.DrawList_AddCircleFilled(dl, {lx, y}, max(0.45 * mm, 1.2), rgba(0xf4f4f6 if on else 0x232327), 12)
			}
			return true
		}
		rgb_led := push2_rgb(label)
		col, level := push2_light(pw, label, st, rgb_led)
		if label == "Up" || label == "Down" || label == "Left" || label == "Right" || strings.has_prefix(label, "Octave") || strings.has_prefix(label, "Page") {
			return push2_quarter(dl, v, pl, k, r, mm, push2_ink(col, level), level, down, label)
		}
		push2_button(dl, r, mm, down)
		ink := push2_ink(col, level)
		switch {
		case label == "Upper" || label == "Lower":
			// A thin strip of light across it (the upper row's low, the lower's high).
			sy := r.y0 + h * (0.62 if label == "Upper" else 0.3)
			sw, sh := w * 0.72, max(0.55 * mm, 1.5)
			sx := r.x0 + (w - sw) / 2
			lit := level > 0.02
			if lit do im.DrawList_AddRectFilled(dl, {sx - 0.6 * mm, sy - 0.8 * mm}, {sx + sw + 0.6 * mm, sy + sh + 0.8 * mm}, rgba(col, 0.22 * level), 1.2 * mm)
			im.DrawList_AddRectFilled(dl, {sx, sy}, {sx + sw, sy + sh}, rgba(push2_ink(col, level) if lit else PUSH2_STRIP_OFF), sh / 2)
		case label == "Record":
			R := min(w, h) * 0.3
			im.DrawList_AddCircle(dl, {(r.x0 + r.x1) / 2, (r.y0 + r.y1) / 2}, R, rgba(ink), 40, max(0.4 * mm, 1.2))
		case label == "Play":
			cx, cy := (r.x0 + r.x1) / 2, (r.y0 + r.y1) / 2
			R := min(w, h) * 0.28
			p0, p1, p2 := im.Vec2{cx - R * 0.75, cy - R}, im.Vec2{cx - R * 0.75, cy + R}, im.Vec2{cx + R, cy}
			th := max(0.4 * mm, 1.2)
			im.DrawList_AddLine(dl, p0, p1, rgba(ink), th)
			im.DrawList_AddLine(dl, p1, p2, rgba(ink), th)
			im.DrawList_AddLine(dl, p2, p0, rgba(ink), th)
		case strings.contains(label, "/"):
			// A scene button: its name small, a chevron.
			small := fs * 0.85
			push2_text(dl, {r.x0 + 1 * mm, r.y0 + 0.8 * mm}, small, ink, level, label, w - 5 * mm)
			s := h * 0.12
			at := im.Vec2{r.x1 - 2.2 * mm, r.y1 - h * 0.32}
			th := max(0.3 * mm, 1)
			im.DrawList_AddLine(dl, {at.x - s * 0.6, at.y - s}, at, rgba(ink), th)
			im.DrawList_AddLine(dl, at, {at.x - s * 0.6, at.y + s}, rgba(ink), th)
		case:
			push2_text(dl, {r.x0 + 1.1 * mm, r.y0 + 0.9 * mm}, fs, ink, level, push2_print(label), w - 2.2 * mm)
		}
		return true
	case .Display:
		pad := 1.6 * mm
		im.DrawList_AddRectFilled(dl, {r.x0 - pad, r.y0 - pad}, {r.x1 + pad, r.y1 + pad}, rgba(0x0b0b0c), 0.8 * mm)
		im.DrawList_AddRect(dl, {r.x0 - pad, r.y0 - pad}, {r.x1 + pad, r.y1 + pad}, rgba(0x232326), 0.8 * mm, 1)
		return false // (the picture itself: drawn the plain way)
	}
	return false
}

// ── The window ────────────────────────────────────────────────────────

// The window, once a frame (when open).
draw_push_window :: proc(a: ^App) {
	pw := &a.push_window
	if pw.open != pw.shown {
		pw.shown = pw.open
		if pw.open do push_window_start(a)
		else do push_window_stop(a)
	}
	if !pw.open do return
	pw.play.hooks = {touch = push_touch, bend = push_bend, body = push2_body, paint = push2_paint, user = a}
	pw.play.prefix = "Push2"
	if ts, r := pa.transport_state(&a.api); r == .Ok do pw.bpm = ts.bpm
	// Esc: back to a window.
	if pw.mode != .Window && im.IsKeyPressed(.Escape) do push_window_set_mode(a, .Window)
	flags: im.WindowFlags = {.NoScrollbar, .NoScrollWithMouse, .NoCollapse, .NoDocking}
	if pw.mode == .Window {
		vp := im.GetMainViewport()
		im.SetNextWindowSize({min(1000, vp.Size.x * 0.9), min(900, vp.Size.y * 0.9)}, .FirstUseEver)
		im.SetNextWindowSizeConstraints({420, 380}, {8000, 8000})
	} else {
		vp := im.GetMainViewport()
		im.SetNextWindowPos(vp.Pos)
		im.SetNextWindowSize(vp.Size)
		flags += {.NoTitleBar, .NoResize, .NoMove, .NoSavedSettings}
		im.SetNextWindowFocus()
	}
	im.PushStyleColorVec4(.WindowBg, {0.045, 0.045, 0.05, 1})
	defer im.PopStyleColor()
	defer im.End()
	if !im.Begin("Push 2 on Screen###push_window", &pw.open, flags) do return
	k, virtual, ok := push_window_find(a)
	v := pa.surface_virtual(&a.api, k) if ok else nil
	// The bar: what this is, how to play it, and the window's size.
	ui.text_push(.Caption)
	im.AlignTextToFramePadding()
	if v == nil do im.TextDisabled("%s", fmt.ctprintf("%s", pw.why if pw.why != "" else "No Push 2 is running."))
	else do im.TextDisabled("%s", "Pads' own Push 2 (none plugged in)" if virtual else "Your Push 2 (the window plays it too)")
	im.SameLine()
	im.TextDisabled("(?)")
	if im.IsItemHovered() do im.SetTooltip("%s", "Click to press; hold for a long press; a pad lower down plays softer.\nRight-click a button to hold it (Shift, Select, Delete, Mute...) until you click it again.\nShift on the keyboard holds Push 2's.\nDrag an encoder up or down, or scroll on it; drag along the touch strip.\nEsc leaves Fill and Full Screen.")
	bw: f32 = 100
	im.SameLine()
	im.SetCursorPosX(max(im.GetCursorPosX(), im.GetWindowWidth() - bw * 2 - im.GetStyle().WindowPadding.x - im.GetStyle().ItemSpacing.x))
	if im.Button("Window###push_fill" if pw.mode == .Fill else "Fill###push_fill", {bw, 0}) do push_window_set_mode(a, .Window if pw.mode == .Fill else .Fill)
	ui.name("push window fill")
	im.SameLine()
	if im.Button("Exit Full Screen###push_full" if pw.mode == .Full_Screen else "Full Screen###push_full", {bw, 0}) do push_window_set_mode(a, .Window if pw.mode == .Full_Screen else .Full_Screen)
	ui.name("push window full screen")
	ui.text_pop()
	if v == nil {
		if im.Button("Start Push 2 on Screen###push_start") do push_window_start(a)
		ui.name("push window start")
		return
	}
	// The keyboard's Shift is Push 2's while the window has the keys.
	shift := im.IsWindowFocused({.RootWindow, .ChildWindows}) && im.GetIO().KeyShift
	if shift != pw.shift do push_window_shift(a, k, shift)
	im.Spacing()
	avail := im.GetContentRegionAvail()
	draw_virtual(a, v, &pw.play, {avail.x, avail.y - 4})
}
