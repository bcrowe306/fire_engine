package ui

import "core:fmt"
import "core:math"
import "core:strings"

import im "deps:imgui"

// What the user did to a control this frame. Turn `changed` into a command
// (`app.set_value`); `ended` is the moment to `app.seal` the history, so a
// whole drag undoes as one step.
Edit :: struct {
	changed: bool, // the value moved
	started: bool, // a gesture began (pressed)
	ended:   bool, // it ended (released), or a one-shot change (double-click reset, typed value)
	active:  bool, // a gesture is under way
}

// The theme the widgets draw with: set by `set_theme`.
@(private) current: Theme

// Sizes widgets use by default, in logical points.
KNOB_SIZE :: 44
// Default fader size (width × height for a vertical one).
FADER_SIZE :: im.Vec2{28, 140}
// Default pad size.
PAD_SIZE :: im.Vec2{88, 88}

@(private)
col :: proc "contextless" (c: Color) -> u32 {
	return im.GetColorU32Vec4(transmute(im.Vec4)c)
}

// A rotary knob: drag up and down (Shift for fine), scroll, double-click
// to reset to `default`. Shows `format` of the value under it, and the
// label above.
knob :: proc(label: cstring, value: ^f32, min_v, max_v: f32, default: f32, format: cstring = "%.2f", size: f32 = KNOB_SIZE) -> (e: Edit) {
	im.PushID(label)
	defer im.PopID()
	t := current
	dl := im.GetWindowDrawList()
	pos := im.GetCursorScreenPos()
	label_h := im.GetTextLineHeight()
	w := max(size, im.CalcTextSize(label).x)
	center := im.Vec2{pos.x + w / 2, pos.y + label_h + 4 + size / 2}

	// Label.
	ls := im.CalcTextSize(label)
	im.DrawList_AddText(dl, {pos.x + (w - ls.x) / 2, pos.y}, col(t.text_dim), label)

	im.SetCursorScreenPos({pos.x + (w - size) / 2, pos.y + label_h + 4})
	im.InvisibleButton("##knob", {size, size})
	e = drag_value(value, min_v, max_v, default, size * 3)

	// Arc from 7:30 to 4:30 (270°): track, then the value.
	r := size / 2 - 3
	a0, a1 := f32(math.PI) * 0.75, f32(math.PI) * 2.25
	frac := (value^ - min_v) / (max_v - min_v) if max_v > min_v else 0
	thickness: f32 = 4
	im.DrawList_PathArcTo(dl, center, r, a0, a1, 32)
	im.DrawList_PathStroke(dl, col(t.raised), thickness)
	if frac > 0.001 {
		im.DrawList_PathArcTo(dl, center, r, a0, a0 + (a1 - a0) * frac, 32)
		im.DrawList_PathStroke(dl, col(t.accent), thickness)
	}
	hovered := im.IsItemHovered() || im.IsItemActive()
	im.DrawList_AddCircleFilled(dl, center, r - 7, col(t.hover if hovered else t.raised), 32)
	a := a0 + (a1 - a0) * frac
	im.DrawList_AddLine(dl, {center.x + math.cos(a) * (r - 14), center.y + math.sin(a) * (r - 14)},
		{center.x + math.cos(a) * (r - 7), center.y + math.sin(a) * (r - 7)}, col(t.text), 2)

	// Value.
	buf: [32]u8
	text := fmt.bprintf(buf[:], string(format), value^)
	ctext := strings.clone_to_cstring(text, context.temp_allocator)
	vs := im.CalcTextSize(ctext)
	im.DrawList_AddText(dl, {pos.x + (w - vs.x) / 2, pos.y + label_h + 4 + size + 2}, col(t.text if hovered else t.text_dim), ctext)
	im.SetCursorScreenPos(pos)
	im.Dummy({w, label_h + 4 + size + 2 + label_h})
	return
}

// Vertical drag and scroll over the last item, mapped onto value: the
// behaviour knobs and faders share. `range_px` is the drag distance from
// minimum to maximum.
@(private)
drag_value :: proc(value: ^f32, min_v, max_v, default: f32, range_px: f32, vertical := true) -> (e: Edit) {
	io := im.GetIO()
	span := max_v - min_v
	if im.IsItemActivated() do e.started = true
	if im.IsItemActive() {
		e.active = true
		d := -io.MouseDelta.y if vertical else io.MouseDelta.x
		if d != 0 {
			speed := span / range_px
			if io.KeyShift do speed *= 0.1
			v := clamp(value^ + d * speed, min_v, max_v)
			if v != value^ {
				value^ = v
				e.changed = true
			}
		}
	}
	if im.IsItemDeactivated() do e.ended = true
	if im.IsItemHovered() && io.MouseWheel != 0 && !e.active {
		v := clamp(value^ + io.MouseWheel * span * 0.02, min_v, max_v)
		if v != value^ {
			value^ = v
			e.changed, e.ended = true, true
		}
	}
	if im.IsItemHovered() && im.IsMouseDoubleClicked(.Left) {
		value^ = default
		e.changed, e.ended = true, true
	}
	return
}

// A fader: vertical (default) or horizontal, drag or scroll, double-click
// for `default`. The label goes under it.
fader :: proc(label: cstring, value: ^f32, min_v, max_v, default: f32, size := FADER_SIZE, vertical := true) -> (e: Edit) {
	im.PushID(label)
	defer im.PopID()
	t := current
	dl := im.GetWindowDrawList()
	pos := im.GetCursorScreenPos()
	im.InvisibleButton("##fader", size)
	e = drag_value(value, min_v, max_v, default, (size.y if vertical else size.x) - 12, vertical)
	frac := (value^ - min_v) / (max_v - min_v) if max_v > min_v else 0
	hovered := im.IsItemHovered() || im.IsItemActive()
	track: f32 = 6
	if vertical {
		x := pos.x + size.x / 2
		im.DrawList_AddRectFilled(dl, {x - track / 2, pos.y + 6}, {x + track / 2, pos.y + size.y - 6}, col(t.raised), track / 2)
		y := pos.y + size.y - 6 - (size.y - 12) * frac
		im.DrawList_AddRectFilled(dl, {x - track / 2, y}, {x + track / 2, pos.y + size.y - 6}, col(t.accent), track / 2)
		im.DrawList_AddRectFilled(dl, {pos.x + 2, y - 6}, {pos.x + size.x - 2, y + 6}, col(t.hover if hovered else t.pressed), 4)
		im.DrawList_AddLine(dl, {pos.x + 6, y}, {pos.x + size.x - 6, y}, col(t.text), 1.5)
	} else {
		y := pos.y + size.y / 2
		im.DrawList_AddRectFilled(dl, {pos.x + 6, y - track / 2}, {pos.x + size.x - 6, y + track / 2}, col(t.raised), track / 2)
		x := pos.x + 6 + (size.x - 12) * frac
		im.DrawList_AddRectFilled(dl, {pos.x + 6, y - track / 2}, {x, y + track / 2}, col(t.accent), track / 2)
		im.DrawList_AddRectFilled(dl, {x - 6, pos.y + 2}, {x + 6, pos.y + size.y - 2}, col(t.hover if hovered else t.pressed), 4)
	}
	// The label under it, inside one box with the fader (so SameLine works).
	label_h: f32 = 0
	if label != "" {
		ls := im.CalcTextSize(label)
		label_h = ls.y + 4
		im.DrawList_AddText(dl, {pos.x + (size.x - ls.x) / 2, pos.y + size.y + 4}, col(t.text_dim), label)
	}
	im.SetCursorScreenPos(pos)
	im.Dummy({size.x, size.y + label_h})
	return
}

// A level meter: `peak` and `rms` as linear amplitudes (1 = 0 dBFS), drawn
// on a dB scale from -60; `hold` is a held peak (linear, 0 = none). Green,
// then amber above -12 dB, red above -3.
meter :: proc(id: cstring, peak, rms: f32, hold: f32 = 0, size := im.Vec2{8, 140}) {
	t := current
	dl := im.GetWindowDrawList()
	pos := im.GetCursorScreenPos()
	im.Dummy(size)
	to_frac :: proc(x: f32) -> f32 {
		if x <= 0 do return 0
		db := 20 * math.log10(x)
		return clamp((db + 60) / 60, 0, 1)
	}
	im.DrawList_AddRectFilled(dl, pos, {pos.x + size.x, pos.y + size.y}, col(t.raised), 2)
	level := to_frac(peak)
	top := pos.y + size.y * (1 - level)
	color := t.ok
	if peak > 0.25 do color = t.warn   // -12 dB
	if peak > 0.708 do color = t.danger // -3 dB
	im.DrawList_AddRectFilled(dl, {pos.x, top}, {pos.x + size.x, pos.y + size.y}, col(with_alpha(color, 0.55)), 2)
	r := pos.y + size.y * (1 - to_frac(rms))
	im.DrawList_AddRectFilled(dl, {pos.x, r}, {pos.x + size.x, pos.y + size.y}, col(color), 2)
	if hold > 0 {
		h := pos.y + size.y * (1 - to_frac(hold))
		im.DrawList_AddLine(dl, {pos.x, h}, {pos.x + size.x, h}, col(t.text), 2)
	}
}

// What happened to a pad this frame.
Pad_Hit :: struct {
	pressed:  bool, // went down (play the sound)
	released: bool, // went up (for gate and hold modes)
	held:     bool,
	velocity: f32,  // 0..1, from where it was hit: higher is harder
	selected: bool, // clicked with Shift or Cmd, or right-clicked: select without playing
}

// A sampler pad: `name` and a small `detail` line, coloured with `tint`
// when it has a sound, lit while `lit` (playing), outlined when
// `selected`.
pad :: proc(id: cstring, name: string, detail: string, tint: Color, has_sound, lit, selected: bool, size := PAD_SIZE) -> (hit: Pad_Hit) {
	im.PushID(id)
	defer im.PopID()
	t := current
	dl := im.GetWindowDrawList()
	pos := im.GetCursorScreenPos()
	im.InvisibleButton("##pad", size, {.MouseButtonLeft, .MouseButtonRight})
	io := im.GetIO()
	if im.IsItemActivated() {
		if im.IsMouseClicked(.Right) || io.KeyShift || io.KeySuper {
			hit.selected = true
		} else {
			hit.pressed = true
			hit.velocity = clamp(1 - (io.MousePos.y - pos.y) / size.y * 0.6, 0.2, 1)
		}
	}
	hit.held = im.IsItemActive()
	if im.IsItemDeactivated() do hit.released = true
	hovered := im.IsItemHovered()

	fill := t.raised
	if has_sound do fill = mix(t.raised, tint, 0.35)
	if hovered do fill = lighten(fill, 0.06)
	if lit || hit.held do fill = mix(fill, tint if has_sound else t.accent, 0.7)
	r := t.radius + 2
	im.DrawList_AddRectFilled(dl, pos, {pos.x + size.x, pos.y + size.y}, col(fill), r)
	if has_sound do im.DrawList_AddRectFilled(dl, {pos.x + 10, pos.y + size.y - 8}, {pos.x + size.x - 10, pos.y + size.y - 5}, col(tint), 2)
	if selected do im.DrawList_AddRect(dl, {pos.x - 1, pos.y - 1}, {pos.x + size.x + 1, pos.y + size.y + 1}, col(t.accent), r + 1, 2)
	pad_x, pad_y: f32 = 10, 8
	name_c := strings.clone_to_cstring(name, context.temp_allocator)
	im.DrawList_AddText(dl, {pos.x + pad_x, pos.y + pad_y}, col(t.text if has_sound else t.text_dim), name_c)
	if detail != "" {
		dc := strings.clone_to_cstring(detail, context.temp_allocator)
		im.DrawList_AddText(dl, {pos.x + pad_x, pos.y + pad_y + im.GetTextLineHeight() + 1}, col(with_alpha(t.text, 0.75) if lit || hit.held else t.text_dim), dc)
	}
	return
}

// An on/off switch with a label to its right. Returns true when toggled.
toggle :: proc(label: cstring, on: ^bool) -> bool {
	im.PushID(label)
	defer im.PopID()
	t := current
	dl := im.GetWindowDrawList()
	h := im.GetFrameHeight() * 0.8
	w := h * 1.8
	pos := im.GetCursorScreenPos()
	y := pos.y + (im.GetFrameHeight() - h) / 2
	clicked := im.InvisibleButton("##toggle", {w, im.GetFrameHeight()})
	if clicked do on^ = !on^
	hovered := im.IsItemHovered()
	bg := t.accent if on^ else (t.hover if hovered else t.raised)
	im.DrawList_AddRectFilled(dl, {pos.x, y}, {pos.x + w, y + h}, col(bg), h / 2)
	knob_x := pos.x + h / 2 + (w - h) * (1 if on^ else 0)
	im.DrawList_AddCircleFilled(dl, {knob_x, y + h / 2}, h / 2 - 3, col(t.accent_text if on^ else t.text), 24)
	if label != "" {
		im.SameLine(0, t.gap.x)
		im.AlignTextToFramePadding()
		im.Text("%s", label)
	}
	return clicked
}

// A row of mutually exclusive options (Grid / Keys / Repeat). Returns true
// when the choice changed.
segmented :: proc(id: cstring, options: []string, choice: ^int) -> bool {
	im.PushID(id)
	defer im.PopID()
	t := current
	dl := im.GetWindowDrawList()
	pos := im.GetCursorScreenPos()
	h := im.GetFrameHeight()
	widths := make([]f32, len(options), context.temp_allocator)
	total: f32 = 0
	for o, i in options {
		widths[i] = im.CalcTextSize(strings.clone_to_cstring(o, context.temp_allocator)).x + 2 * t.pad.x
		total += widths[i]
	}
	im.DrawList_AddRectFilled(dl, pos, {pos.x + total + 4, pos.y + h}, col(t.raised), t.radius)
	changed := false
	x := pos.x + 2
	for o, i in options {
		im.SetCursorScreenPos({x, pos.y})
		im.PushIDInt(i32(i))
		if im.InvisibleButton("##seg", {widths[i], h}) && choice^ != i {
			choice^ = i
			changed = true
		}
		hovered := im.IsItemHovered()
		im.PopID()
		if choice^ == i {
			im.DrawList_AddRectFilled(dl, {x, pos.y + 2}, {x + widths[i], pos.y + h - 2}, col(t.surface), t.radius - 1)
		} else if hovered {
			im.DrawList_AddRectFilled(dl, {x, pos.y + 2}, {x + widths[i], pos.y + h - 2}, col(t.hover), t.radius - 1)
		}
		oc := strings.clone_to_cstring(o, context.temp_allocator)
		ts := im.CalcTextSize(oc)
		im.DrawList_AddText(dl, {x + (widths[i] - ts.x) / 2, pos.y + (h - ts.y) / 2}, col(t.text if choice^ == i else t.text_dim), oc)
		x += widths[i]
	}
	im.SetCursorScreenPos(pos)
	im.Dummy({total + 4, h})
	return changed
}

// A square button showing one icon (an ICON_ constant), with a tooltip.
// `on` draws it in the accent colour (a toggled tool, recording).
icon_button :: proc(icon: string, tooltip: cstring, on := false, size: f32 = 0, color: Color = {}) -> bool {
	t := current
	s := size if size > 0 else im.GetFrameHeight()
	ic := strings.clone_to_cstring(icon, context.temp_allocator)
	im.PushID(tooltip)
	defer im.PopID()
	if on {
		im.PushStyleColorVec4(.Button, transmute(im.Vec4)(color if color != {} else t.accent))
		im.PushStyleColorVec4(.ButtonHovered, transmute(im.Vec4)lighten(color if color != {} else t.accent, 0.1))
		im.PushStyleColorVec4(.Text, transmute(im.Vec4)t.accent_text)
	}
	clicked := im.Button(ic, {s, s})
	if on do im.PopStyleColor(3)
	if tooltip != "" && im.IsItemHovered({.DelayNormal}) do im.SetTooltip("%s", tooltip)
	return clicked
}

// A two-dimensional control: both values 0..1, x to the right and y up.
xy_pad :: proc(id: cstring, x, y: ^f32, size := im.Vec2{160, 160}) -> (e: Edit) {
	im.PushID(id)
	defer im.PopID()
	t := current
	dl := im.GetWindowDrawList()
	pos := im.GetCursorScreenPos()
	im.InvisibleButton("##xy", size)
	if im.IsItemActivated() do e.started = true
	if im.IsItemActive() {
		e.active = true
		m := im.GetIO().MousePos
		nx := clamp((m.x - pos.x) / size.x, 0, 1)
		ny := clamp(1 - (m.y - pos.y) / size.y, 0, 1)
		if nx != x^ || ny != y^ {
			x^, y^ = nx, ny
			e.changed = true
		}
	}
	if im.IsItemDeactivated() do e.ended = true
	im.DrawList_AddRectFilled(dl, pos, {pos.x + size.x, pos.y + size.y}, col(t.raised), t.radius)
	px, py := pos.x + x^ * size.x, pos.y + (1 - y^) * size.y
	im.DrawList_AddLine(dl, {px, pos.y + 4}, {px, pos.y + size.y - 4}, col(t.border), 1)
	im.DrawList_AddLine(dl, {pos.x + 4, py}, {pos.x + size.x - 4, py}, col(t.border), 1)
	im.DrawList_AddCircleFilled(dl, {px, py}, 8, col(t.accent), 24)
	return
}

// `a` moved towards `b` by `f` (0..1).
mix :: proc "contextless" (a, b: Color, f: f32) -> Color {
	return {a.r + (b.r - a.r) * f, a.g + (b.g - a.g) * f, a.b + (b.b - a.b) * f, a.a + (b.a - a.a) * f}
}
