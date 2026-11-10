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

// A label as shown: up to "##" (what follows only makes the id unique,
// as in ImGui).
shown_label :: proc(label: cstring) -> cstring {
	text := string(label)
	i := strings.index(text, "##")
	if i < 0 do return label
	return strings.clone_to_cstring(text[:i], context.temp_allocator)
}

// A colour as ImGui packs it, for draw lists.
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
	shown := shown_label(label)
	w := max(size, im.CalcTextSize(shown).x)
	center := im.Vec2{pos.x + w / 2, pos.y + label_h + 4 + size / 2}

	// Label.
	ls := im.CalcTextSize(shown)
	im.DrawList_AddText(dl, {pos.x + (w - ls.x) / 2, pos.y}, col(t.text_dim), shown)

	im.SetCursorScreenPos({pos.x + (w - size) / 2, pos.y + label_h + 4})
	im.InvisibleButton("##knob", {size, size})
	name(string(shown))
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
	if im.IsItemActive() && !e.started { // the press frame's delta is how the mouse got there
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
	name(widget_name(label, "fader"))
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
	if shown := shown_label(label); shown != "" {
		ls := im.CalcTextSize(shown)
		label_h = ls.y + 4
		im.DrawList_AddText(dl, {pos.x + (size.x - ls.x) / 2, pos.y + size.y + 4}, col(t.text_dim), shown)
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
	menu:     bool, // right-clicked (for a menu: its colour)
	mute:     bool, // its Mute button was clicked
	solo:     bool, // its Solo button was clicked
	dropped:  string, // a drag-and-drop payload of `Pad_Face.drop_type` let go on it (temporary allocator)
}

// What a pad shows: its name centred at the top (clipped to the pad), a
// line in the middle (its note), Mute and Solo at the bottom corners, and
// optionally its sound's waveform behind.
Pad_Face :: struct {
	label:     string, // what a test finds it by ("pad A1"; its buttons "pad A1 mute", "pad A1 solo")
	name:      string,
	middle:    string,
	tint:      Color,
	has_sound: bool,
	lit:       bool, // playing
	selected:  bool,
	peaks:     []Peak, // the waveform behind (nil: none)
	mute:      bool,
	solo:      bool,
	buttons:   bool, // show Mute and Solo
	drop_type: cstring, // the drag-and-drop payload it takes (nil: none)
}

// A sampler pad (see Pad_Face): hit it to play it (higher is harder);
// Shift- or Cmd-click, or right-click, to select it without playing.
pad :: proc(id: cstring, face: Pad_Face, size := PAD_SIZE) -> (hit: Pad_Hit) {
	im.PushID(id)
	defer im.PopID()
	t := current
	dl := im.GetWindowDrawList()
	pos := im.GetCursorScreenPos()
	// AllowOverlap: its Mute and Solo buttons sit on it.
	im.InvisibleButton("##pad", size, {.MouseButtonLeft, .MouseButtonRight, .AllowOverlap})
	if face.label != "" do name(face.label)
	if face.drop_type != nil && im.BeginDragDropTarget() {
		if payload := im.AcceptDragDropPayload(face.drop_type); payload != nil {
			hit.dropped = strings.clone(strings.string_from_ptr((^u8)(payload.Data), int(payload.DataSize)), context.temp_allocator)
		}
		im.EndDragDropTarget()
	}
	io := im.GetIO()
	if im.IsItemActivated() {
		if im.IsMouseClicked(.Right) || io.KeyShift || io.KeySuper {
			hit.selected = true
			hit.menu = im.IsMouseClicked(.Right)
		} else {
			hit.pressed = true
			hit.velocity = clamp(1 - (io.MousePos.y - pos.y) / size.y * 0.6, 0.2, 1)
		}
	}
	hit.held = im.IsItemActive()
	if im.IsItemDeactivated() do hit.released = true
	hovered := im.IsItemHovered()
	max_ := im.Vec2{pos.x + size.x, pos.y + size.y}

	// The body, and the waveform behind.
	fill := t.raised
	if face.has_sound do fill = mix(t.raised, face.tint, 0.35)
	if hovered do fill = lighten(fill, 0.06)
	if face.lit || hit.held do fill = mix(fill, face.tint if face.has_sound else t.accent, 0.7)
	r := t.radius + 2
	im.DrawList_AddRectFilled(dl, pos, max_, col(fill), r)
	if len(face.peaks) > 0 {
		inset: f32 = 6
		w := size.x - 2 * inset
		mid := pos.y + size.y / 2
		half := size.y * 0.34
		// Plainly visible, a lighter shade of the pad's colour.
		wc := col(with_alpha(mix(face.tint, t.text, 0.45), 0.8))
		// A filled bar per column: the loudest and quietest of the peaks it covers.
		cols := max(int(w), 1)
		n := len(face.peaks)
		for x in 0 ..< cols {
			i0 := x * n / cols
			i1 := max((x + 1) * n / cols, i0 + 1)
			lo, hi: f32 = 0, 0
			for pk in face.peaks[i0:min(i1, n)] do lo, hi = min(lo, pk.lo), max(hi, pk.hi)
			px := pos.x + inset + f32(x)
			im.DrawList_AddRectFilled(dl, {px, mid - hi * half}, {px + 1, mid - lo * half + 1}, wc)
		}
	}
	if face.selected do im.DrawList_AddRect(dl, {pos.x - 1, pos.y - 1}, {max_.x + 1, max_.y + 1}, col(t.accent), r + 1, 2)

	// The name, centred at the top and clipped to the pad.
	text_c := t.text if face.has_sound else t.text_dim
	pad_x, pad_y: f32 = 6, 6
	im.DrawList_PushClipRect(dl, {pos.x + pad_x, pos.y}, {max_.x - pad_x, max_.y}, true)
	if face.name != "" {
		nc := strings.clone_to_cstring(face.name, context.temp_allocator)
		ns := im.CalcTextSize(nc)
		x := pos.x + max((size.x - ns.x) / 2, pad_x) // too long: from the left, cut at the right
		im.DrawList_AddText(dl, {math.round(x), pos.y + pad_y}, col(text_c), nc)
	}
	// The middle line (the note).
	if face.middle != "" {
		mc := strings.clone_to_cstring(face.middle, context.temp_allocator)
		ms := im.CalcTextSize(mc)
		at := im.Vec2{math.round(pos.x + max((size.x - ms.x) / 2, pad_x)), math.round(pos.y + (size.y - ms.y) / 2)}
		if len(face.peaks) > 0 { // readable over the waveform: a faint backing just its size
			im.DrawList_AddRectFilled(dl, {at.x - 3, at.y}, {at.x + ms.x + 3, at.y + ms.y}, col(with_alpha(fill, 0.55)), 3)
		}
		im.DrawList_AddText(dl, at, col(with_alpha(t.text, 0.85) if face.lit || hit.held || face.has_sound else t.text_dim), mc)
	}
	im.DrawList_PopClipRect(dl)

	// Mute and Solo, bottom left and right.
	if face.buttons && size.x >= 56 && size.y >= 48 {
		bs := im.Vec2{min(size.x * 0.28, 22), min(size.y * 0.24, 18)}
		at := [2]im.Vec2{{pos.x + 5, max_.y - bs.y - 5}, {max_.x - bs.x - 5, max_.y - bs.y - 5}}
		for which in 0 ..< 2 {
			im.SetCursorScreenPos(at[which])
			pressed := im.InvisibleButton("##m" if which == 0 else "##s", bs)
			if face.label != "" do name(strings.concatenate({face.label, " mute" if which == 0 else " solo"}, context.temp_allocator))
			bh := im.IsItemHovered()
			on := face.mute if which == 0 else face.solo
			if pressed {
				if which == 0 do hit.mute = true
				else do hit.solo = true
			}
			c := rgb(0x3d9cf5) if which == 0 else t.warn
			bg := c if on else (with_alpha(t.bg, 0.55) if bh else with_alpha(t.bg, 0.3))
			im.DrawList_AddRectFilled(dl, at[which], {at[which].x + bs.x, at[which].y + bs.y}, col(bg), 3)
			lc: cstring = "M" if which == 0 else "S"
			ls := im.CalcTextSize(lc)
			im.DrawList_AddText(dl, {math.round(at[which].x + (bs.x - ls.x) / 2), math.round(at[which].y + (bs.y - ls.y) / 2)}, col(t.bg if on else (t.text if bh else t.text_dim)), lc)
			if bh do im.SetTooltip("%s", cstring("Mute" if which == 0 else "Solo"))
		}
		im.SetCursorScreenPos(pos)
		im.Dummy(size)
	}
	return
}

// A number in a field `width` wide: drag up/right to raise it by `step`
// every few points (Shift: by `fine`), scroll for a step, double-click to
// type it. Shows `format` of it ("%.1f BPM"). The value is
// kept on a `fine` grid.
number_drag :: proc(id: cstring, value: ^f64, lo, hi, step, fine: f64, format: cstring, width: f32) -> (e: Edit) {
	im.PushID(id)
	defer im.PopID()
	t := current
	dl := im.GetWindowDrawList()
	pos := im.GetCursorScreenPos()
	h := im.GetFrameHeight()
	@(static) typing: im.ID
	@(static) typed: f64
	@(static) acc: f32
	wid := im.GetID("##num")
	if typing == wid {
		im.SetNextItemWidth(width)
		if im.IsWindowAppearing() || !im.IsAnyItemActive() do im.SetKeyboardFocusHere()
		if im.InputDouble("##type", &typed, 0, 0, "%.2f", {.EnterReturnsTrue, .AutoSelectAll}) {
			value^ = clamp(math.round(typed / fine) * fine, lo, hi)
			e.changed, e.ended = true, true
			typing = 0
		} else if im.IsItemDeactivated() {
			typing = 0
		}
		return
	}
	im.InvisibleButton("##num", {width, h})
	name(widget_name(id, "number"))
	io := im.GetIO()
	if im.IsItemActivated() {
		e.started = true
		acc = 0
	}
	if im.IsItemActive() && !e.started {
		e.active = true
		acc += io.MouseDelta.x - io.MouseDelta.y
		px: f32 = 4 // points a step
		steps := math.trunc(acc / px)
		if steps != 0 {
			acc -= steps * px
			d := f64(steps) * (fine if io.KeyShift else step)
			v := clamp(math.round((value^ + d) / fine) * fine, lo, hi)
			if v != value^ {
				value^ = v
				e.changed = true
			}
		}
	}
	if im.IsItemDeactivated() do e.ended = true
	if im.IsItemHovered() && io.MouseWheel != 0 && !im.IsItemActive() {
		v := clamp(math.round((value^ + f64(io.MouseWheel) * (fine if io.KeyShift else step)) / fine) * fine, lo, hi)
		if v != value^ {
			value^ = v
			e.changed, e.ended = true, true
		}
	}
	if im.IsItemHovered() && im.IsMouseDoubleClicked(.Left) {
		typing, typed = wid, value^
	}
	hovered := im.IsItemHovered() || im.IsItemActive()
	im.DrawList_AddRectFilled(dl, pos, {pos.x + width, pos.y + h}, col(t.hover if hovered else t.raised), t.radius)
	label := fmt.ctprintf(string(format), value^) // (Odin's fmt reads C-style verbs: "%.1f")
	ts := im.CalcTextSize(label)
	im.DrawList_AddText(dl, {math.round(pos.x + (width - ts.x) / 2), math.round(pos.y + (h - ts.y) / 2)}, col(t.text), label)
	if hovered && !im.IsItemActive() do im.SetTooltip("Drag (Shift: finer), scroll, or double-click to type")
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
	name(widget_name(label, "toggle"))
	if clicked do on^ = !on^
	hovered := im.IsItemHovered()
	bg := t.accent if on^ else (t.hover if hovered else t.raised)
	im.DrawList_AddRectFilled(dl, {pos.x, y}, {pos.x + w, y + h}, col(bg), h / 2)
	knob_x := pos.x + h / 2 + (w - h) * (1 if on^ else 0)
	im.DrawList_AddCircleFilled(dl, {knob_x, y + h / 2}, h / 2 - 3, col(t.accent_text if on^ else t.text), 24)
	// The label up to "##" (what follows only makes the id unique, as in ImGui).
	text := string(label)
	if i := strings.index(text, "##"); i >= 0 do text = text[:i]
	if text != "" {
		im.SameLine(0, t.gap.x)
		im.AlignTextToFramePadding()
		im.Text("%s", strings.clone_to_cstring(text, context.temp_allocator))
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
		// (named below, once its block is done)
			choice^ = i
			changed = true
		}
		hovered := im.IsItemHovered()
		name(o)
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

// A button that is only an icon (an ICON_ constant): no frame, the glyph
// centred in a square of `size` (default: the frame height), with a
// tooltip. Its colour shows its state: dimmed at rest, full text under the
// mouse, `color` (default: the accent) when `on`; faint and inert when
// `disabled`. Pressing dims it a little.
icon_button :: proc(icon: string, tooltip: cstring, on := false, size: f32 = 0, color: Color = {}, disabled := false) -> bool {
	s := size if size > 0 else im.GetFrameHeight()
	ic := strings.clone_to_cstring(icon, context.temp_allocator)
	im.PushID(tooltip)
	im.PushID(ic)
	defer im.PopID()
	defer im.PopID()
	pos := im.GetCursorScreenPos()
	clicked := im.InvisibleButton("##icon", {s, s}) && !disabled
	name(string(tooltip))
	hovered := im.IsItemHovered() && !disabled
	held := im.IsItemActive() && !disabled
	c := icon_color(on, hovered, held, color, disabled)
	ts := im.CalcTextSize(ic)
	dl := im.GetWindowDrawList()
	im.DrawList_AddText(dl, {math.round(pos.x + (s - ts.x) / 2), math.round(pos.y + (s - ts.y) / 2)}, col(c), ic)
	if tooltip != "" && im.IsItemHovered({.DelayNormal, .AllowWhenDisabled}) do im.SetTooltip("%s", tooltip)
	return clicked
}

// The colour an icon button draws its glyph in, for its state.
icon_color :: proc(on, hovered, held: bool, color: Color = {}, disabled := false) -> Color {
	t := current
	if disabled do return with_alpha(t.text_dim, 0.4)
	c := t.text_dim
	if on do c = color if color != {} else t.accent
	else if hovered || held do c = t.text
	if on && hovered do c = lighten(c, 0.15)
	if held do c = with_alpha(c, 0.7)
	return c
}

// A two-dimensional control: both values 0..1, x to the right and y up.
xy_pad :: proc(id: cstring, x, y: ^f32, size := im.Vec2{160, 160}) -> (e: Edit) {
	im.PushID(id)
	defer im.PopID()
	t := current
	dl := im.GetWindowDrawList()
	pos := im.GetCursorScreenPos()
	im.InvisibleButton("##xy", size)
	name(widget_name(id, "xy pad"))
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

// Keeps the next item, `width` wide, on the current line when it fits
// (after `spacing`, or the style's item spacing), or starts a new line:
// a toolbar that wraps when its panel is narrow. Call it between items.
flow :: proc(width: f32, spacing: f32 = -1) {
	gap := spacing if spacing >= 0 else im.GetStyle().ItemSpacing.x
	last := im.GetItemRectMax().x
	right := im.GetCursorScreenPos().x + im.GetContentRegionAvail().x // the next line starts at the left edge
	if last + gap + width <= right do im.SameLine(0, gap)
}

// The width of a button labelled `label` (for flow).
button_width :: proc(label: cstring) -> f32 {
	return im.CalcTextSize(label).x + im.GetStyle().FramePadding.x * 2
}

// The name a widget gets for the probe: its label as shown, or `kind`.
@(private)
widget_name :: proc(label: cstring, kind: string) -> string {
	s := string(shown_label(label))
	return s if s != "" else kind
}

// The theme in use (the last one given to set_theme).
theme :: proc() -> Theme { return current }
