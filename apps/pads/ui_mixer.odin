package pads

import "core:fmt"
import "core:math"

import app "app:core"
import "app:ui"
import pm "model"
import im "deps:imgui"

// A meter's display: what it shows, held peaks falling back.
Meter_View :: struct {
	peak, rms, hold: f32,
	hold_left:       f32, // seconds the held peak stays
}

// The meters of the 64 pads, the buses and main.
Mixer_State :: struct {
	pads:  [pm.PADS][2]Meter_View,
	buses: [pm.BUSES + 1][2]Meter_View,
	pad_rows, bus_rows: int, // slot rows each group of strips shows
}

// Reads a meter into its display: the level falls at about 24 dB a second,
// a peak is held a second.
@(private)
meter_update :: proc(v: ^[2]Meter_View, peak, rms: [2]f32, dt: f32) {
	fall := f32(math.pow(10, -24 * f64(dt) / 20))
	for c in 0 ..< 2 {
		m := &v[c]
		m.peak = max(peak[c], m.peak * fall)
		m.rms = max(rms[c], m.rms * fall)
		if peak[c] >= m.hold {
			m.hold, m.hold_left = peak[c], 1
		} else {
			m.hold_left -= dt
			if m.hold_left <= 0 do m.hold *= fall
		}
	}
}

// Reads every meter once a frame (whether the mixer shows or not).
update_meters :: proc(a: ^App) {
	e := &a.m.engine
	dt := im.GetIO().DeltaTime
	for i in 0 ..< pm.PADS {
		pk, rms := pm.pad_level(e, i)
		meter_update(&a.mixer.pads[i], pk, rms, dt)
	}
	for b in 0 ..= pm.BUSES {
		pk, rms := pm.bus_level(e, b)
		meter_update(&a.mixer.buses[b], pk, rms, dt)
	}
}

STRIP_W :: 78

// The mixer: the current bank's pads, the buses, main.
draw_mixer :: proc(user: rawptr) {
	a := (^App)(user)
	// The pads scroll; the buses and main stay at the right.
	m := &a.m
	lists := make([dynamic][]pm.Effect_Slot, context.temp_allocator)
	for k in 0 ..< pm.PADS_PER_BANK do append(&lists, m.project.pads[a.bank * pm.PADS_PER_BANK + k].inserts[:])
	a.mixer.pad_rows = slot_rows(lists[:])
	clear(&lists)
	for b in 0 ..= pm.BUSES do append(&lists, pm.bus_of(m, b).slots[:])
	a.mixer.bus_rows = slot_rows(lists[:])
	avail := im.GetContentRegionAvail()
	buses_w := f32(pm.BUSES + 1) * (STRIP_W + 6) + 8
	if im.BeginChild("##pads", {max(avail.x - buses_w, STRIP_W), avail.y}, {}, {.HorizontalScrollbar}) {
		for k in 0 ..< pm.PADS_PER_BANK {
			i := a.bank * pm.PADS_PER_BANK + k
			if k > 0 do im.SameLine(0, 6)
			pad_strip(a, i)
		}
	}
	im.EndChild()
	im.SameLine(0, 8)
	if im.BeginChild("##buses", {buses_w - 8, avail.y}) {
		for b in 0 ..= pm.BUSES {
			if b > 0 do im.SameLine(0, 6)
			bus_strip(a, b)
		}
	}
	im.EndChild()
}

// The top of a strip: its name in its colour.
@(private)
strip_head :: proc(name: string, color: ui.Color, selected: bool) -> bool {
	t := ui.theme()
	dl := im.GetWindowDrawList()
	pos := im.GetCursorScreenPos()
	h := im.GetFrameHeight()
	clicked := im.InvisibleButton("##head", {STRIP_W, h})
	bg := color if selected else ui.mix(t.raised, color, 0.35)
	im.DrawList_AddRectFilled(dl, pos, {pos.x + STRIP_W, pos.y + h}, ui.col(bg), t.radius)
	label := fmt.ctprintf("%s", name)
	ts := im.CalcTextSize(label)
	im.DrawList_PushClipRect(dl, pos, {pos.x + STRIP_W - 4, pos.y + h}, true)
	im.DrawList_AddText(dl, {pos.x + max((STRIP_W - ts.x) / 2, 6), pos.y + (h - ts.y) / 2}, ui.col(t.accent_text if selected else t.text), label)
	im.DrawList_PopClipRect(dl)
	return clicked
}

// A strip's effect slots: the ones in use, then one "+" for the next (so
// strips stay short); the rest of the room is left for the fader.
@(private)
slot_list :: proc(a: ^App, kind: pm.Fx_Target_Kind, index: int, slots: []pm.Effect_Slot, rows: int) {
	shown := 0
	defer for _ in shown ..< rows do im.Dummy({STRIP_W, im.GetFrameHeight()}) // line up with the other strips
	empty := -1
	for s, k in slots {
		if s.kind != .None {
			failed := pm.slot_failed(&a.m.engine, index if kind == .Pad else -1, index if kind == .Bus else -1, k)
			slot_button(a, {kind, index, k}, s, failed)
			shown += 1
		} else if empty < 0 {
			empty = k
		}
	}
	if empty >= 0 {
		slot_button(a, {kind, index, empty}, {}, false)
		shown += 1
	}
}

// Rows a group of strips needs for its slots: the most any uses, plus one.
@(private)
slot_rows :: proc(lists: [][]pm.Effect_Slot) -> int {
	rows := 1
	for l in lists {
		used := 0
		for s in l do if s.kind != .None do used += 1
		rows = max(rows, min(used + 1, len(l)))
	}
	return rows
}

// An effect slot's button: its effect's name; click to edit it.
@(private)
slot_button :: proc(a: ^App, target: pm.Fx_Target, s: pm.Effect_Slot, failed: bool) {
	t := ui.theme()
	editing := a.fx == target
	name := pm.slot_name(s) if s.kind != .None else "+"
	if failed do name = fmt.tprintf("%s (missing)", name)
	label := fmt.ctprintf("%s##slot%d", name, target.slot)
	colors := 0
	if editing {
		im.PushStyleColorVec4(.Button, transmute(im.Vec4)t.accent)
		im.PushStyleColorVec4(.Text, transmute(im.Vec4)t.accent_text)
		colors = 2
	} else if s.kind != .None && !s.on {
		im.PushStyleColorVec4(.Text, transmute(im.Vec4)t.text_dim)
		colors = 1
	}
	if im.Button(label, {STRIP_W, 0}) {
		a.fx = target
		show_detail(a, .Effects)
	}
	if colors > 0 do im.PopStyleColor(i32(colors))
	if s.kind != .None && im.IsItemHovered() do im.SetTooltip("%s", fmt.ctprintf("%s%s", pm.slot_name(s), "" if s.on else " (off)"))
}

// A pan control on one row: drag sideways; double-click centres it.
@(private)
pan_field :: proc(pan: ^f32) -> bool {
	im.SetNextItemWidth(STRIP_W)
	v := pan^
	text: cstring = "C"
	if v < -0.005 do text = fmt.ctprintf("L %.0f", -v * 100)
	if v > 0.005 do text = fmt.ctprintf("R %.0f", v * 100)
	changed := im.DragFloat("##pan", &v, 0.01, -1, 1, text, {.ClampOnInput})
	if im.IsItemHovered() && im.IsMouseDoubleClicked(.Left) {
		v = 0
		changed = true
	}
	if changed do pan^ = v
	return changed
}

// Mute and solo buttons (mute alone, full width, without `solo`).
@(private)
mute_solo :: proc(mute, solo: ^bool) -> (changed: bool) {
	t := ui.theme()
	w := f32(STRIP_W - 4) / 2 if solo != nil else f32(STRIP_W)
	for which in 0 ..< (2 if solo != nil else 1) {
		on := mute if which == 0 else solo
		if which == 1 do im.SameLine(0, 4)
		c := t.warn if which == 0 else t.ok
		if on^ {
			im.PushStyleColorVec4(.Button, transmute(im.Vec4)c)
			im.PushStyleColorVec4(.Text, transmute(im.Vec4)t.bg)
		}
		if im.Button("M" if which == 0 else "S", {w, 0}) {
			on^ = !on^
			changed = true
		}
		if on^ do im.PopStyleColor(2)
	}
	return
}

// A fader and its meter, side by side, filling the height left.
@(private)
fader_meter :: proc(value: ^f32, view: ^[2]Meter_View, id: cstring) -> ui.Edit {
	h := max(im.GetContentRegionAvail().y - im.GetTextLineHeightWithSpacing() - 4, 80)
	e := ui.fader(id, value, -60, 12, 0, {28, h})
	im.SameLine(0, 8)
	for c in 0 ..< 2 {
		if c > 0 do im.SameLine(0, 3)
		ui.meter(fmt.ctprintf("%s_m%d", id, c), view[c].peak, view[c].rms, view[c].hold, {8, h})
	}
	im.TextDisabled("%s", fmt.ctprintf("%+.1f dB", value^))
	return e
}

// Pad `i`'s strip.
@(private)
pad_strip :: proc(a: ^App, i: int) {
	m := &a.m
	pad := m.project.pads[i]
	im.PushIDInt(i32(i))
	defer im.PopID()
	im.BeginGroup()
	defer im.EndGroup()
	has := pad.sample != 0
	label := fmt.tprintf("%s %s", pm.pad_label(i), pm.pad_name(&m.project.pads[i]) if has else "")
	if strip_head(label, ui.rgb(pad.color), a.selected == i) do a.selected = i
	if !has do im.BeginDisabled()
	defer if !has do im.EndDisabled()
	slot_list(a, .Pad, i, pad.inserts[:], a.mixer.pad_rows)
	im.SetNextItemWidth(STRIP_W)
	out := i32(pad.bus)
	names := [?]cstring{"Main", "Bus A", "Bus B", "Bus C", "Bus D"}
	if im.ComboChar("##out", &out, &names[0], len(names)) do pm.set_pad_bus(m, i, int(out))
	pan := pad.pan
	if pan_field(&pan) {
		p := pad
		p.pan = pan
		pm.set_pad(m, i, .Pan, "Set Pan", p)
	}
	if im.IsItemDeactivatedAfterEdit() do app.seal(&m.history)
	mute, solo := pad.mute, pad.solo
	if mute_solo(&mute, &solo) {
		p := pad
		p.mute, p.solo = mute, solo
		pm.set_pad(m, i, .Mute, "Mute" if mute != pad.mute else "Solo", p)
		app.seal(&m.history)
	}
	vol := pad.volume
	fe := fader_meter(&vol, &a.mixer.pads[i], "##vol")
	if fe.changed {
		p := pad
		p.volume = vol
		pm.set_pad(m, i, .Volume, "Set Volume", p)
	}
	if fe.ended do app.seal(&m.history)
}

// Bus `b`'s strip (BUSES: main).
@(private)
bus_strip :: proc(a: ^App, b: int) {
	m := &a.m
	bus := pm.bus_of(m, b)^
	im.PushIDInt(i32(1000 + b))
	defer im.PopID()
	im.BeginGroup()
	defer im.EndGroup()
	t := ui.theme()
	strip_head(pm.bus_name(b + 1 if b < pm.BUSES else 0), t.accent if b == pm.BUSES else ui.mix(t.accent, t.text_dim, 0.5), false)
	bus_slots := bus.slots
	slot_list(a, .Bus, b, bus_slots[:], a.mixer.bus_rows)
	if b < pm.BUSES {
		pan := bus.pan
		if pan_field(&pan) {
			nb := bus
			nb.pan = pan
			pm.set_bus(m, b, 2, "Set Pan", nb)
		}
		if im.IsItemDeactivatedAfterEdit() do app.seal(&m.history)
		mute, solo := bus.mute, bus.solo
		if mute_solo(&mute, &solo) {
			nb := bus
			nb.mute, nb.solo = mute, solo
			pm.set_bus(m, b, 1, "Mute" if mute != bus.mute else "Solo", nb)
			app.seal(&m.history)
		}
	} else {
		// Main has no pan or solo; it lines up with the buses anyway.
		im.Dummy({STRIP_W, im.GetFrameHeight()})
		mute := bus.mute
		if mute_solo(&mute, nil) {
			nb := bus
			nb.mute = mute
			pm.set_bus(m, b, 1, "Mute", nb)
			app.seal(&m.history)
		}
	}
	vol := bus.volume
	fe := fader_meter(&vol, &a.mixer.buses[b], "##vol")
	if fe.changed {
		nb := bus
		nb.volume = vol
		pm.set_bus(m, b, 0, "Set Volume", nb)
	}
	if fe.ended do app.seal(&m.history)
}
