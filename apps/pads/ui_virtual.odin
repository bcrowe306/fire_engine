// A surface's virtual controller: its controls drawn where it placed them
// (fsurf.layout), lit as it lights them, its displays mirrored, played with
// the mouse as its controller would send it. Settings > Control Surfaces
// shows any surface's; the Push 2 window (ui_push_window.odin) Push 2's.
package pads

import "core:fmt"
import "core:math"

import "app:ui"
import abi "fsurf:abi"
import fsurf "fsurf:host"
import pa "api"
import im "deps:imgui"

// The mouse on a virtual controller, and its displays' pictures.
Virtual_Play :: struct {
	held:    int, // the control held with the left button, +1 (0: none)
	unlatch: bool, // the left button let a held one go (nothing pressed)
	drag:    f32, // an encoder's drag not yet turned
	latched: [dynamic]int, // buttons held by a right-click, until clicked again
	images:  [4]ui.Image, // the displays' (the newest frame each has)
	frames:  [4]int,
	hooks:   Virtual_Hooks,
	prefix:  string, // its controls' test names start with it ("Virtual")
}

// What a surface does that its layout doesn't say (Push 2's touches).
Virtual_Hooks :: struct {
	// An encoder touched or let go: its message (none: count 0).
	touch: proc(v: ^fsurf.Virtual, k: int, on: bool) -> fsurf.Virtual_Messages,
	// Whether dragging control `k` bends the pitch (a touch strip).
	bend:  proc(v: ^fsurf.Virtual, k: int) -> bool,
	// Draws the device's body (`r`: its rectangle; `mm`: pixels a
	// millimetre). Nil: a plain dark one.
	body:  proc(dl: ^im.DrawList, v: ^fsurf.Virtual, r: Virtual_Rect, mm: f32),
	// Draws control `k` in `r` as it is now (`down`: held by the mouse or a
	// right-click); false: drawn the plain way.
	paint: proc(dl: ^im.DrawList, v: ^fsurf.Virtual, pl: ^Virtual_Play, k: int, r: Virtual_Rect, mm: f32, st: abi.Layout_State, down: bool) -> bool,
	user:  rawptr, // (for paint)
}

// A control's rectangle on the page (pixels).
Virtual_Rect :: struct { x0, y0, x1, y1: f32 }

// Lets a virtual controller's pictures and latches go.
virtual_play_destroy :: proc(pl: ^Virtual_Play) {
	for &img in pl.images do ui.image_destroy(&img)
	delete(pl.latched)
	pl^ = {}
}

// Lets everything a virtual controller holds go (its latches, the button
// held), as their releases.
virtual_play_release :: proc(a: ^App, v: ^fsurf.Virtual, pl: ^Virtual_Play) {
	if v != nil {
		for k in pl.latched do pa.surface_play(&a.api, fsurf.virtual_release(v, k))
		if pl.held > 0 do pa.surface_play(&a.api, fsurf.virtual_release(v, pl.held - 1))
	}
	clear(&pl.latched)
	pl.held = 0
}

// The ordinal of control `k` among those named as it is (1, 2...), and
// how many there are.
@(private)
virtual_ordinal :: proc(v: ^fsurf.Virtual, k: int) -> (nth, of: int) {
	for c, i in v.controls do if c.label == v.controls[k].label {
		of += 1
		if i <= k do nth = of
	}
	return
}

// Control `k`'s test name: the prefix, its name, its ordinal when others
// share it ("Virtual Upper 3").
@(private)
virtual_name :: proc(v: ^fsurf.Virtual, pl: ^Virtual_Play, k: int) -> string {
	nth, of := virtual_ordinal(v, k)
	prefix := pl.prefix if pl.prefix != "" else "Virtual"
	if of > 1 do return fmt.tprintf("%s %s %d", prefix, v.controls[k].label, nth)
	return fmt.tprintf("%s %s", prefix, v.controls[k].label)
}

// Whether button `k` is held by a right-click.
@(private)
virtual_latched :: proc(pl: ^Virtual_Play, k: int) -> (int, bool) {
	for x, i in pl.latched do if x == k do return i, true
	return -1, false
}

// A pitch bend on control `k`'s port (0..1, ½ the middle).
@(private)
virtual_bend :: proc(v: ^fsurf.Virtual, k: int, x: f32) -> fsurf.Virtual_Messages {
	c := v.controls[k]
	n := u16(math.round(clamp(x, 0, 1) * 16383))
	port := v.s.ports[c.port].input if int(c.port) < len(v.s.ports) else 0xFFFF_FFFF
	return {port = port, bytes = {{0xE0, u8(n & 0x7F), u8(n >> 7)}, {}}, sizes = {3, 0}, count = 1}
}

// The controls where they are on the device, the whole of it fitted in
// `area` (centred across it), lit as the surface lit them, played with the
// mouse: buttons and pads pressed (lower on a pad: softer), a button
// right-clicked held until clicked again, encoders dragged up and down or
// scrolled (touched while dragged), faders moved, a touch strip dragged.
// Its size on the page.
draw_virtual :: proc(a: ^App, v: ^fsurf.Virtual, pl: ^Virtual_Play, area: im.Vec2) -> im.Vec2 {
	dl := im.GetWindowDrawList()
	scale := min(area.x / max(v.width, 1), area.y / max(v.height, 1), 6)
	size := im.Vec2{v.width * scale, v.height * scale}
	o := im.GetCursorScreenPos()
	ox, oy := o.x + max((area.x - size.x) / 2, 0), o.y + max((area.y - size.y) / 2, 0)
	t := ui.theme()
	col :: proc(rgb: u32, alpha: f32 = 1) -> u32 {
		return im.ColorConvertFloat4ToU32({f32((rgb >> 16) & 0xFF) / 255, f32((rgb >> 8) & 0xFF) / 255, f32(rgb & 0xFF) / 255, alpha})
	}
	if pl.hooks.body != nil do pl.hooks.body(dl, v, {ox, oy, ox + size.x, oy + size.y}, scale)
	else do im.DrawList_AddRectFilled(dl, {ox, oy}, {ox + size.x, oy + size.y}, col(0x1b1c20), 6 * scale / 2.5)
	font, base := im.GetFont(), im.GetFontSize()
	for c, k in v.controls {
		if c.w <= 0 || c.h <= 0 do continue
		x0, y0 := ox + c.x * scale, oy + c.y * scale
		x1, y1 := x0 + c.w * scale, y0 + c.h * scale
		st := fsurf.virtual_state(v, k)
		_, latched := virtual_latched(pl, k)
		lit := u32(0x2a2b30)
		if st.has_rgb do lit = st.rgb
		else if st.value > 0 do lit = mix_rgb(0x2a2b30, 0xffb030, f32(st.value) / 127)
		down := st.pressed || pl.held == k + 1 || latched
		edge := col(0xffffff) if down else col(0x4a4b52)
		round := min(3 * scale / 2.5, (y1 - y0) / 3)
		painted := pl.hooks.paint != nil && pl.hooks.paint(dl, v, pl, k, {x0, y0, x1, y1}, scale, st, down)
		if !painted do switch c.kind {
		case .Button, .Pad, .Other:
			im.DrawList_AddRectFilled(dl, {x0, y0}, {x1, y1}, col(lit), round)
			im.DrawList_AddRect(dl, {x0, y0}, {x1, y1}, edge, round)
			if latched do im.DrawList_AddRect(dl, {x0 - 2, y0 - 2}, {x1 + 2, y1 + 2}, ui.col(t.accent), round + 2, 2)
		case .Encoder:
			r := min(x1 - x0, y1 - y0) / 2
			cx, cy := (x0 + x1) / 2, (y0 + y1) / 2
			im.DrawList_AddCircleFilled(dl, {cx, cy}, r, col(0x2c2d33))
			im.DrawList_AddCircle(dl, {cx, cy}, r, edge, 0, 2 if down else 1)
			ang := (-135 + 270 * f64(clamp(st.position, 0, 1)) - 90) * math.PI / 180
			im.DrawList_AddLine(dl, {cx, cy}, {cx + f32(math.cos(ang)) * r * 0.85, cy + f32(math.sin(ang)) * r * 0.85}, col(0x9a9ba3) if lit == 0x2a2b30 else col(lit), 2)
		case .Fader:
			im.DrawList_AddRectFilled(dl, {x0, y0}, {x1, y1}, col(0x141418), 2)
			im.DrawList_AddRect(dl, {x0, y0}, {x1, y1}, edge, 2)
			pos := clamp(st.position, 0, 1)
			if c.h >= c.w {
				th := min((y1 - y0) * 0.15, x1 - x0)
				y := y0 + (y1 - y0 - th) * (1 - pos)
				im.DrawList_AddRectFilled(dl, {x0, y}, {x1, y + th}, col(0xc9cad1), 2)
			} else {
				tw := min((x1 - x0) * 0.15, y1 - y0)
				x := x0 + (x1 - x0 - tw) * pos
				im.DrawList_AddRectFilled(dl, {x, y0}, {x + tw, y1}, col(0xc9cad1), 2)
			}
		case .Display:
			im.DrawList_AddRectFilled(dl, {x0, y0}, {x1, y1}, col(0x000000))
			n := int(c.number)
			if m := fsurf.virtual_display(v, k); m != nil && n < len(pl.images) {
				img := &pl.images[n]
				if m.frames != pl.frames[n] || !ui.image_ready(img) {
					if ui.image_set(img, &a.platform, m.rgba[:], m.width, m.height) do pl.frames[n] = m.frames
				}
				if ui.image_ready(img) do im.ImDrawList_AddImage(dl, ui.image_ref(img), {x0, y0}, {x1, y1})
			}
		}
		// Its name, inside a button, under a knob or fader, smaller to fit;
		// none on a pad or on controls that share it (a row's: the display
		// names them).
		if !painted && c.kind != .Display && c.kind != .Other && c.kind != .Pad {
			if _, of := virtual_ordinal(v, k); of == 1 {
				name := fmt.ctprintf("%s", c.label)
				room := x1 - x0 - 4 if c.kind == .Button else (x1 - x0) * 1.6
				fs := base
				if tw := im.CalcTextSize(name).x; tw > room do fs = base * room / tw
				if fs >= 7 {
					tw := im.CalcTextSize(name).x * fs / base
					inside := c.kind == .Button
					ty := (y0 + y1) / 2 - fs / 2 if inside else y1 + 2
					ink := col(0x1b1c20) if inside && light(lit) else col(0x9a9ba3)
					im.DrawList_AddTextFontPtr(dl, font, fs, {(x0 + x1) / 2 - tw / 2, ty}, ink, name)
				}
			}
		}
		// The mouse.
		if c.kind == .Display || c.kind == .Other do continue
		im.SetCursorScreenPos({x0, y0})
		im.PushIDInt(i32(k))
		im.InvisibleButton("##ctl", {max(x1 - x0, 1), max(y1 - y0, 1)})
		ui.name(virtual_name(v, pl, k))
		if im.IsItemHovered() do im.SetTooltip("%s", fmt.ctprintf("%s", c.label))
		bend := pl.hooks.bend != nil && pl.hooks.bend(v, k)
		#partial switch c.kind {
		case .Button, .Pad:
			if c.kind == .Button && im.IsItemClicked(.Right) {
				if i, on := virtual_latched(pl, k); on {
					unordered_remove(&pl.latched, i)
					pa.surface_play(&a.api, fsurf.virtual_release(v, k))
				} else {
					append(&pl.latched, k)
					pa.surface_play(&a.api, fsurf.virtual_press(v, k))
				}
			}
			if im.IsItemActivated() {
				pl.held = k + 1
				if i, on := virtual_latched(pl, k); on { // (a held one let go)
					unordered_remove(&pl.latched, i)
					pa.surface_play(&a.api, fsurf.virtual_release(v, k))
					pl.unlatch = true
				} else {
					pl.unlatch = false
					vel := clamp(1 - (im.GetMousePos().y - y0) / max(y1 - y0, 1), 0.2, 1) if c.kind == .Pad else 1
					pa.surface_play(&a.api, fsurf.virtual_press(v, k, u8(vel * 127)))
				}
			}
			if bend && im.IsItemActive() && !pl.unlatch do pa.surface_play(&a.api, virtual_bend(v, k, 1 - (im.GetMousePos().y - y0) / max(y1 - y0, 1)))
			if im.IsItemDeactivated() {
				pl.held = 0
				if !pl.unlatch {
					if bend do pa.surface_play(&a.api, virtual_bend(v, k, 0.5))
					pa.surface_play(&a.api, fsurf.virtual_release(v, k))
				}
				pl.unlatch = false
			}
		case .Encoder:
			if im.IsItemActivated() {
				pl.held, pl.drag = k + 1, 0
				if pl.hooks.touch != nil do pa.surface_play(&a.api, pl.hooks.touch(v, k, true))
			}
			if im.IsItemActive() {
				pl.drag -= im.GetIO().MouseDelta.y
				if steps := int(pl.drag / 4); steps != 0 {
					pa.surface_play(&a.api, fsurf.virtual_turn(v, k, steps))
					pl.drag -= f32(steps) * 4
				}
			}
			if im.IsItemDeactivated() {
				pl.held = 0
				if pl.hooks.touch != nil do pa.surface_play(&a.api, pl.hooks.touch(v, k, false))
			}
			if im.IsItemHovered() && !im.IsItemActive() {
				if w := im.GetIO().MouseWheel; w != 0 do pa.surface_play(&a.api, fsurf.virtual_turn(v, k, int(math.round(w * 2))))
			}
		case .Fader:
			if im.IsItemActive() {
				mp := im.GetMousePos()
				x := 1 - (mp.y - y0) / max(y1 - y0, 1) if c.h >= c.w else (mp.x - x0) / max(x1 - x0, 1)
				pa.surface_play(&a.api, fsurf.virtual_move(v, k, clamp(x, 0, 1)))
			}
		}
		im.PopID()
	}
	im.SetCursorScreenPos(o)
	im.Dummy({max(area.x, size.x), max(area.y, size.y)})
	return size
}

// Whether a colour is light (dark text on it).
@(private)
light :: proc(rgb: u32) -> bool {
	return 0.2126 * f32((rgb >> 16) & 0xFF) + 0.7152 * f32((rgb >> 8) & 0xFF) + 0.0722 * f32(rgb & 0xFF) > 128
}
