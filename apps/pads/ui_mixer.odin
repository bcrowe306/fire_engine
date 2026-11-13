package pads

import "core:fmt"
import "core:math"
import "core:strings"

import app "app:core"
import "app:ui"
import pm "model"
import im "deps:imgui"

// A meter's display: what it shows, held peaks falling back, and the
// loudest peak since it was last reset (its readout).
Meter_View :: struct {
	peak, rms, hold: f32,
	hold_left:       f32, // seconds the held peak stays
	max:             f32, // the loudest since reset (click the readout to reset)
}

// The meters of the 64 pads, the buses and main.
Mixer_State :: struct {
	pads:  [pm.PADS][2]Meter_View,
	buses: [pm.BUSES + 1][2]Meter_View,
	inputs: [pm.MAX_INPUTS / 2][2]Meter_View, // the device's input channels, a pair each
	cue:    [2]Meter_View, // the cue mix
	multi: bool, // an edit of several strips at once is open (one undo step)
	rename_bus: int, // the bus being renamed (1..BUSES; 0: none)
	rename_buf: [16]u8,
}

// Reads a meter into its display: the level falls as Settings says (about
// 24 dB a second), a peak is held as long as it says (2 s).
@(private)
meter_update :: proc(v: ^[2]Meter_View, peak, rms: [2]f32, dt: f32, ms: Meter_Settings) {
	fall := f32(math.pow(10, -f64(ms.fall_dbs) * f64(dt) / 20))
	for c in 0 ..< 2 {
		m := &v[c]
		m.peak = max(peak[c], m.peak * fall)
		m.rms = max(rms[c], m.rms * fall)
		m.max = max(m.max, peak[c])
		if peak[c] >= m.hold {
			m.hold, m.hold_left = peak[c], ms.hold_s
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
		meter_update(&a.mixer.pads[i], pk, rms, dt, a.settings.meters)
	}
	for b in 0 ..= pm.BUSES {
		pk, rms := pm.bus_level(e, b)
		meter_update(&a.mixer.buses[b], pk, rms, dt, a.settings.meters)
	}
	{
		pk, rms := pm.cue_level(e)
		meter_update(&a.mixer.cue, pk, rms, dt, a.settings.meters)
	}
	for k in 0 ..< pm.MAX_INPUTS / 2 {
		pk, rms := pm.input_level(e, k)
		meter_update(&a.mixer.inputs[k], pk, rms, dt, a.settings.meters)
	}
}

// Input channel `c`'s meter (0: input 1).
input_view :: proc(a: ^App, c: int) -> Meter_View {
	if c < 0 || c >= pm.MAX_INPUTS do return {}
	return a.mixer.inputs[c / 2][c % 2]
}

// The strip being drawn's name ("A1", "Bus A", "Main"): its parts are
// named after it for the probe ("A1 fader", "Bus A mute").
@(private) strip_name: string

// Names the item just drawn as part `part` of the strip being drawn.
@(private)
part :: proc(name: string) {
	ui.name(fmt.tprintf("%s %s", strip_name, name))
}

// Sizes of a channel strip, in points.
STRIP_W :: 86 // the bottom area's strip (and the least a strip is not narrow)
@(private) STRIP_WIDE_W :: 112 // the Mixer's wide strips
@(private) STRIP_NARROW_W :: 56 // a narrow strip (the Mixer's bar switches)
@(private) STRIP_GAP :: 4

// The strips being drawn: their width and which sections show (the
// Mixer's settings while it draws; else wide, everything).
@(private) strip_w_cur: f32 = STRIP_W
@(private) strip_view := Mixer_View{inserts = true, eq = true, sends = true, io = true}
@(private) STRIP_PAD :: 5 // inside the strip, each side
@(private) ROW_H :: 18 // a slot, a send, the output
@(private) EQ_H :: 40
@(private) PAN_H :: 30
@(private) PAN_H_BIG :: 46 // the bottom area folded: room for a bigger pan knob
@(private) IO_H :: 24 // the Mixer's audio and MIDI in and out dropdowns
@(private) MS_H_WIDE :: 24 // Mute, Solo and Arm on a wide strip
@(private) SEND_KNOB_H :: 44 // a send as a knob (the bottom area folded)

// The strips are the Mixer's (not the bottom area's one), and the bottom
// area is folded (the room goes to bigger knobs, sends as knobs).
@(private) strip_in_mixer: bool
@(private) bus_added: int // frames until the buses scroll to the one just added (0: none)
@(private) strip_big_knobs: bool
@(private) strip_roomy: bool // the Mixer tall enough for the bigger rows (else they are a row's size)

// Heights that depend on where the strips are: the I/O rows, Mute and
// Solo, the pan knob.
@(private) io_h :: proc() -> f32 { return IO_H if strip_in_mixer && strip_roomy else ROW_H }
@(private) ms_h :: proc() -> f32 { return MS_H_WIDE if strip_in_mixer && strip_roomy && !narrow() else ROW_H }
@(private) pan_h :: proc() -> f32 { return PAN_H_BIG if strip_big_knobs else PAN_H }
@(private) SLOT_ROWS :: 6 // pads: 2 inserts and SEND_ROWS sends; buses: 5 slots and a gap
@(private) SEND_ROWS :: 4 // sends shown at once (more buses: they scroll)
@(private) FADER_LO :: -60 // the bottom of the fader (off)
@(private) FADER_HI :: 6

// The mixer, as Logic's: its bar (which sections the strips show, narrow
// or wide), then a channel strip for every pad with a sound (in all banks,
// scrolling sideways), the buses right after them, and main pinned on the
// right with its loudness, correlation and stereo view beside it.
draw_mixer :: proc(user: rawptr) {
	a := (^App)(user)
	m := &a.m
	// The toggles: a column of icons at the left, in the middle of its height.
	full := im.GetContentRegionAvail()
	if im.BeginChild("##mixertoggles", {TOGGLES_W, full.y}, {}, {.NoScrollbar}) do draw_mixer_toggles(a)
	im.EndChild()
	im.SameLine(0, 6)
	v := a.settings.mixer_view
	strip_view = v
	strip_w_cur = STRIP_NARROW_W if v.narrow else STRIP_WIDE_W
	strip_in_mixer, strip_roomy = true, true
	strip_big_knobs = a.ws.bottom_folded
	defer {
		strip_w_cur = STRIP_W
		strip_view = {inserts = true, eq = true, sends = true, io = true}
		strip_in_mixer, strip_big_knobs, strip_roomy = false, false, false
	}
	avail := im.GetContentRegionAvail()
	// A short mixer (a small window, the bottom area open): the bigger
	// rows (I/O, Mute and Solo) go back to a row's size, then the EQ
	// curves, then the I/O rows, give way, so every strip shows whole down
	// to its name (the fader keeps 50 points and a row of inserts or sends
	// stays; with sends and EQ shown, 3 rows).
	{
		room_h := avail.y - im.GetStyle().ScrollbarSize - 8
		need :: proc() -> f32 { return strip_fixed_h() + ROW_H + 2 + 4 + 50 }
		roomy_need := strip_fixed_h() + 3 * (ROW_H + 2) + 4 + 70
		if roomy_need > room_h do strip_roomy = false
		if strip_view.eq && need() > room_h do strip_view.eq = false
		if strip_view.io && need() > room_h do strip_view.io = false
	}
	p := &m.project
	n_buses := p.bus_count
	add_w: f32 = 26 if n_buses < pm.BUSES else 0 // the + that adds a bus
	meters_w: f32 = MAIN_METERS_W if !v.meters_folded else METERS_FOLDED_W
	main_w := strip_w_cur + 6 + meters_w // main, pinned at the right, and its meters (or their fold)
	// The pads' strips as wide as they are (no gap after them), the buses
	// right after; past the room, each scrolls.
	n_strips, n_tabs := 0, 0
	for _, i in p.pads do if pm.pad_used(p, i) && !in_group(p, i) do n_strips += 1
	for b in 1 ..= p.bus_count do if p.buses[b - 1].group {
		n_tabs += 1
		if !p.buses[b - 1].folded do n_strips += len(pm.group_members(p, b))
	}
	pads_need := max(f32(n_strips) * (strip_w_cur + STRIP_GAP) + f32(n_tabs) * (GROUP_TAB_W + STRIP_GAP), 240 if n_strips == 0 else 0) + 2 * im.GetStyle().WindowPadding.x
	buses_need := f32(n_buses) * (strip_w_cur + STRIP_GAP) + 2 * im.GetStyle().WindowPadding.x
	room := max(avail.x - main_w - add_w - 24, 2 * strip_w_cur)
	pads_w := pads_need
	buses_w := buses_need
	if pads_w + buses_w > room {
		// Share what there is: the buses at most half.
		buses_w = min(buses_need, max(room * 0.45, strip_w_cur + STRIP_GAP))
		pads_w = max(room - buses_w, strip_w_cur + STRIP_GAP)
	}
	im.PushStyleVarVec2(.ItemSpacing, {STRIP_GAP, 0})
	defer im.PopStyleVar()
	// Back in sight (from the Sequence view, say): the selected pad's or
	// bus's strip scrolled into view.
	@(static) drawn: i32
	frame := im.GetFrameCount()
	back := frame - drawn > 1
	drawn = frame
	@(static) want_x: f32 // (the selected strip's place, found while drawing)
	reveal :: proc(x: f32) {
		w := im.GetWindowWidth() - 2 * im.GetStyle().WindowPadding.x
		sx := im.GetScrollX()
		if x < sx do im.SetScrollX(max(x - STRIP_GAP, 0))
		else if x + strip_w_cur > sx + w do im.SetScrollX(x + strip_w_cur - w + STRIP_GAP)
	}
	sel_pad := a.selected if a.detail.track.kind == .Pad else -1
	sel_bus := a.detail.track.index if a.detail.track.kind == .Bus else -1
	if im.BeginChild("##pads", {pads_w, avail.y}, {}, {.HorizontalScrollbar} if pads_need > pads_w else {.NoScrollbar}) {
		h := im.GetContentRegionAvail().y
		any := false
		want_x = -1
		@(static) target: int
		target = sel_pad
		strip :: proc(a: ^App, i: int, h: f32, any: ^bool) {
			if any^ do im.SameLine()
			any^ = true
			if i == target do want_x = im.GetCursorPosX()
			// Off to the side (scrolled away): only its room.
			if !im.IsRectVisibleBySize({strip_w_cur, h}) {
				im.Dummy({strip_w_cur, h})
				return
			}
			pad_strip(a, i, h)
		}
		// The pads in no group, then each group: its tab, and its pads
		// (unless it is folded).
		for _, i in p.pads do if pm.pad_used(p, i) && !in_group(p, i) do strip(a, i, h, &any)
		for b in 1 ..= p.bus_count do if p.buses[b - 1].group {
			if any do im.SameLine()
			any = true
			group_tab(a, b, h)
			if !p.buses[b - 1].folded do for i in pm.group_members(p, b) do strip(a, i, h, &any)
		}
		if !any {
			im.SetCursorPos({12, 12})
			im.TextDisabled("Pads with a sound get a channel strip here.")
		}
		if back && want_x >= 0 do reveal(want_x)
	}
	im.EndChild()
	im.SameLine(0, 8)
	// The buses at the right, against main (whatever room the pads leave).
	{
		main_left := im.GetWindowPos().x + im.GetWindowWidth() - main_w - im.GetStyle().WindowPadding.x
		cur := im.GetCursorScreenPos()
		want := main_left - 4 - add_w - buses_w
		if want > cur.x do im.SetCursorScreenPos({want, cur.y})
	}
	// The line between the pads and the buses.
	pos := im.GetCursorScreenPos()
	im.DrawList_AddLine(im.GetWindowDrawList(), {pos.x - 5, pos.y + 4}, {pos.x - 5, pos.y + avail.y - 4}, ui.col(ui.theme().border), 1)
	if im.BeginChild("##buses", {buses_w, avail.y}, {}, {.HorizontalScrollbar} if buses_need > buses_w else {.NoScrollbar}) {
		h := im.GetContentRegionAvail().y
		bus_x: f32 = -1
		for b in 0 ..< n_buses {
			if b > 0 do im.SameLine()
			if b == sel_bus do bus_x = im.GetCursorPosX()
			bus_strip(a, b, h)
		}
		if back && bus_x >= 0 do reveal(bus_x)
		// A bus just added: scrolled into sight (its room known a frame later).
		if bus_added > 0 {
			bus_added -= 1
			if bus_added == 0 do im.SetScrollX(im.GetScrollMaxX())
		}
	}
	im.EndChild()
	// The + that adds a bus, after them (outside their scrolling: always
	// in sight).
	if n_buses < pm.BUSES {
		im.SameLine(0, 2)
		if ui.icon_button(ui.ICON_PLUS, "Add a bus", size = 22) {
			pm.add_bus(m)
			bus_added = 2
		}
		ui.name("add bus")
	}
	// Main, at the right edge.
	im.SameLine(0, 4)
	main_x := im.GetWindowPos().x + im.GetWindowWidth() - main_w - im.GetStyle().WindowPadding.x
	cur := im.GetCursorScreenPos()
	if main_x > cur.x do im.SetCursorScreenPos({main_x, cur.y})
	// As tall as the bus strips (above their scrollbar, when they scroll).
	main_h := avail.y - (im.GetStyle().ScrollbarSize if buses_need > buses_w else 0)
	if im.BeginChild("##main", {main_w, avail.y}, {}, {.NoScrollbar}) {
		bus_strip(a, pm.BUSES, main_h)
		im.SameLine(0, 6)
		if v.meters_folded {
			// Folded: a button to open it again, down the side.
			bp := im.GetCursorScreenPos()
			if im.InvisibleButton("##metersopen", {METERS_FOLDED_W - 2, main_h}) {
				a.settings.mixer_view.meters_folded = false
				settings_save(a)
			}
			ui.name("show loudness")
			t := ui.theme()
			hot := im.IsItemHovered()
			dl := im.GetWindowDrawList()
			im.DrawList_AddRectFilled(dl, bp, {bp.x + METERS_FOLDED_W - 2, bp.y + main_h}, ui.col(ui.mix(t.surface, t.raised, 0.8 if hot else 0.4)), t.radius)
			ic := fmt.ctprintf("%s", ui.ICON_CHEVRON_LEFT)
			ts := im.CalcTextSize(ic)
			im.DrawList_AddText(dl, {bp.x + (METERS_FOLDED_W - 2 - ts.x) / 2, bp.y + main_h / 2 - ts.y / 2}, ui.col(t.text if hot else t.text_dim), ic)
			if hot do im.SetTooltip("Show main's loudness, correlation and stereo view")
		} else {
			draw_main_meters(a, main_h)
		}
	}
	im.EndChild()
	draw_rename_bus(a)
}

// The width of main's meters column (loudness, correlation, stereo), and
// of it folded away.
@(private)
MAIN_METERS_W :: 128
@(private)
METERS_FOLDED_W :: 18

// The width of a group's tab.
@(private)
GROUP_TAB_W :: 26

// The width of the Mixer's column of toggles.
@(private)
TOGGLES_W :: 30

// The Mixer's toggles, icons down its left side (in the middle of its
// height): the strips' sections (lit when shown, grey when not; each says
// what it is on hover), and narrow or wide strips.
@(private)
draw_mixer_toggles :: proc(a: ^App) {
	v := &a.settings.mixer_view
	changed := false
	n: f32 = 5
	b := im.GetFrameHeight()
	gap: f32 = 6
	h := im.GetContentRegionAvail().y
	im.SetCursorPosY(im.GetCursorPosY() + max((h - n * b - (n - 1) * gap) / 2, 0))
	toggle :: proc(on: ^bool, icon: string, tip: cstring) -> bool {
		x := im.GetCursorPosX()
		if ui.icon_button(icon, tip, on = on^) {
			on^ = !on^
			return true
		}
		im.SetCursorPosX(x)
		return false
	}
	step :: proc(gap: f32) { im.Dummy({1, gap}) }
	if toggle(&v.inserts, ui.ICON_WAND_SPARKLES, "Inserts: each strip's effects (click one to edit it below, drag to reorder)") do changed = true
	step(gap)
	if toggle(&v.eq, ui.ICON_CHART_SPLINE, "EQ: each strip's EQ curve (click it to edit below)") do changed = true
	step(gap)
	if toggle(&v.sends, ui.ICON_ARROW_UP_RIGHT, "Sends: each strip's level to each bus in use") do changed = true
	step(gap)
	if toggle(&v.io, ui.ICON_ARROW_LEFT_RIGHT, "I/O: each strip's audio and MIDI in and out") do changed = true
	step(gap)
	if ui.icon_button(ui.ICON_FOLD_HORIZONTAL if !v.narrow else ui.ICON_UNFOLD_HORIZONTAL, "Narrow strips (more at once)" if !v.narrow else "Wide strips", on = v.narrow) {
		v.narrow = !v.narrow
		changed = true
	}
	ui.name("strip width")
	if changed do settings_save(a)
}

// Whether pad `i` goes to a group.
@(private)
in_group :: proc(p: ^pm.Project, i: int) -> bool {
	b := int(p.pads[i].bus)
	return b >= 1 && b <= p.bus_count && p.buses[b - 1].group
}

// A group's tab in front of its pads: its name down it; click to fold or
// unfold it, right-click for its menu (rename, ungroup).
@(private)
group_tab :: proc(a: ^App, b: int, h: f32) {
	m := &a.m
	p := &m.project
	t := ui.theme()
	g := &p.buses[b - 1]
	w: f32 = 26
	pos := im.GetCursorScreenPos()
	im.PushIDInt(i32(5000 + b))
	defer im.PopID()
	if im.InvisibleButton("##group", {w, h}) do pm.set_group_folded(m, b, !g.folded)
	ui.name(fmt.tprintf("group %s", pm.bus_name(p, b)))
	hot := im.IsItemHovered()
	if hot do im.SetTooltip("%s", fmt.ctprintf("%s: %d pads · click to %s · right-click: rename, ungroup", pm.bus_name(p, b), len(pm.group_members(p, b)), "unfold" if g.folded else "fold"))
	if im.BeginPopupContextItem("##groupmenu") {
		if im.MenuItem("Fold", nil, g.folded) do pm.set_group_folded(m, b, !g.folded)
		if im.MenuItem("Rename…") do begin_rename_bus(a, b)
		if im.MenuItem("Ungroup") do pm.ungroup(m, b)
		im.EndPopup()
	}
	dl := im.GetWindowDrawList()
	bg := ui.mix(t.raised, t.accent, 0.35 if hot else 0.22)
	im.DrawList_AddRectFilled(dl, pos, {pos.x + w, pos.y + h}, ui.col(bg), t.radius)
	icon := ui.ICON_CHEVRON_RIGHT if g.folded else ui.ICON_CHEVRON_DOWN
	im.DrawList_AddText(dl, {pos.x + 6, pos.y + 6}, ui.col(t.text), fmt.ctprintf("%s", icon))
	// Its name, a letter a line.
	y := pos.y + 30
	lh := im.GetTextLineHeight()
	for r in pm.bus_name(p, b) {
		if y + lh > pos.y + h - 6 do break
		im.DrawList_AddText(dl, {pos.x + 8, y}, ui.col(t.text), fmt.ctprintf("%r", r))
		y += lh
	}
}

// Groups the selected pads (or pad `i`, if it isn't among them) under a
// new group bus, and opens its name to type.
group_selected :: proc(a: ^App, i: int) {
	sel := selected_pads(a)
	if i not_in sel do sel = {i}
	pads := make([dynamic]int, context.temp_allocator)
	for k in 0 ..< pm.PADS do if k in sel && pm.pad_used(&a.m.project, k) do append(&pads, k)
	if len(pads) == 0 do return
	b := pm.group_pads(&a.m, pads[:])
	if b == 0 {
		ui.toast(&a.ws.toasts, .Error, "No bus left for a group")
		return
	}
	begin_rename_bus(a, b)
}

// Renames bus `b` (1..BUSES): its dialog opens.
begin_rename_bus :: proc(a: ^App, b: int) {
	a.mixer.rename_bus = b
	a.mixer.rename_buf = {}
	copy(a.mixer.rename_buf[:len(a.mixer.rename_buf) - 1], pm.bus_name(&a.m.project, b))
}

// The Rename Bus dialog.
@(private)
draw_rename_bus :: proc(a: ^App) {
	st := &a.mixer
	if st.rename_bus == 0 do return
	im.OpenPopup("Rename Bus")
	open := true
	if im.BeginPopupModal("Rename Bus", &open, {.AlwaysAutoResize}) {
		if im.IsWindowAppearing() do im.SetKeyboardFocusHere()
		im.SetNextItemWidth(200)
		enter := im.InputText("##busname", cstring(&st.rename_buf[0]), len(st.rename_buf), {.EnterReturnsTrue, .AutoSelectAll})
		if im.Button("Rename") || enter {
			pm.rename_bus(&a.m, st.rename_bus, strings.truncate_to_byte(string(st.rename_buf[:]), 0))
			st.rename_bus = 0
			im.CloseCurrentPopup()
		}
		im.SameLine()
		if im.Button("Cancel") || im.IsKeyPressed(.Escape) {
			st.rename_bus = 0
			im.CloseCurrentPopup()
		}
		im.EndPopup()
	}
	if !open do st.rename_bus = 0
}

// The strips an edit of pad `i`'s strip changes: the selected ones, when
// it is one of several selected; else it alone.
@(private)
strip_targets :: proc(a: ^App, i: int) -> Pad_Set {
	sel := selected_pads(a)
	return sel if i in sel && card(sel) > 1 else {i}
}

// Opens (or, with `ended`, closes) the undo step an edit of several strips
// makes, so a drag of them all is one step.
@(private)
multi_edit :: proc(a: ^App, n: int, changed, ended: bool) {
	if n > 1 && changed && !a.mixer.multi {
		app.begin(&a.m.history, "Edit Channels")
		a.mixer.multi = true
	}
	if ended && a.mixer.multi {
		app.end(&a.m.history)
		a.mixer.multi = false
		app.seal(&a.m.history)
	}
}

// --- the parts of a strip ------------------------------------------------------------------

// Small text, for slots, sends and readouts.
@(private)
small :: proc(a: ^App) { im.PushFontFloat(a.platform.fonts.regular, 12) }

// Text `s` in `color`, centred in [lo, hi] (clipped to it).
@(private)
text_in :: proc(dl: ^im.DrawList, lo, hi: im.Vec2, s: string, color: ui.Color, left := false) {
	c := fmt.ctprintf("%s", s)
	ts := im.CalcTextSize(c)
	x := lo.x + 5 if left else lo.x + max((hi.x - lo.x - ts.x) / 2, 4)
	im.DrawList_PushClipRect(dl, lo, {hi.x - 3, hi.y}, true)
	im.DrawList_AddText(dl, {math.round(x), math.round(lo.y + (hi.y - lo.y - ts.y) / 2)}, ui.col(color), c)
	im.DrawList_PopClipRect(dl)
}

// The colour of the wells in a strip (slots, readouts, meters): darker
// than the strip in either theme.
@(private)
well :: proc(t: ui.Theme) -> ui.Color {
	dark := 0.3 * t.bg.r + 0.59 * t.bg.g + 0.11 * t.bg.b < 0.5
	return t.bg if dark else ui.mix(t.raised, t.text, 0.1)
}

// The width inside a strip.
@(private)
inner_w :: proc() -> f32 { return strip_w_cur - 2 * STRIP_PAD }

// Whether the strips are narrow.
@(private)
narrow :: proc() -> bool { return strip_w_cur < STRIP_W }

// A strip's background, `h` tall from the cursor; the cursor moves inside
// its padding.
@(private)
strip_begin :: proc(h: f32, selected: bool) {
	t := ui.theme()
	dl := im.GetWindowDrawList()
	pos := im.GetCursorScreenPos()
	bg := ui.mix(t.surface, t.raised, 0.55)
	im.DrawList_AddRectFilled(dl, pos, {pos.x + strip_w_cur, pos.y + h}, ui.col(bg), t.radius)
	if selected do im.DrawList_AddRect(dl, pos, {pos.x + strip_w_cur, pos.y + h}, ui.col(t.accent), t.radius, 1.5)
	im.SetCursorScreenPos({pos.x + STRIP_PAD, pos.y + STRIP_PAD})
	im.BeginGroup() // lines start inside the padding
}

@(private)
strip_end :: proc(top: im.Vec2, h: f32) {
	im.EndGroup()
	im.SetCursorScreenPos(top)
	im.Dummy({strip_w_cur, h})
}

// Space between a strip's sections.
@(private)
gap :: proc(h: f32 = 4) {
	im.Dummy({inner_w(), h})
}

// The pad EQ's curve, as a thumbnail (Logic's EQ display); nil `eq` draws
// a flat, dim one. True when clicked.
@(private)
eq_thumb :: proc(eq: ^[3]f32, color: ui.Color, on := true, width: f32 = 0) -> bool {
	t := ui.theme()
	dl := im.GetWindowDrawList()
	pos := im.GetCursorScreenPos()
	w := width if width > 0 else inner_w()
	clicked := im.InvisibleButton("##eq", {w, EQ_H})
	part("eq")
	hovered := im.IsItemHovered()
	im.DrawList_AddRectFilled(dl, pos, {pos.x + w, pos.y + EQ_H}, ui.col(well(t)), t.radius - 2)
	mid := pos.y + EQ_H / 2
	if eq == nil { // (a bus: no EQ, only its place in line)
		im.DrawList_AddLine(dl, {pos.x + 2, mid}, {pos.x + w - 2, mid}, ui.col(t.border), 1)
		return false
	}
	// A faint grid for context: 100 Hz, 1 kHz and 10 kHz across (20 Hz to
	// 20 kHz, log), ±6 and ±12 dB up and down (±15 the height).
	grid := ui.col(ui.with_alpha(t.text, 0.07))
	for hz in ([3]f32{100, 1000, 10_000}) {
		x := pos.x + 2 + (w - 4) * math.log10(hz / 20) / 3
		im.DrawList_AddLine(dl, {x, pos.y + 2}, {x, pos.y + EQ_H - 2}, grid, 1)
	}
	for db in ([4]f32{-12, -6, 6, 12}) {
		y := mid - db / 15 * (EQ_H / 2 - 3)
		im.DrawList_AddLine(dl, {pos.x + 2, y}, {pos.x + w - 2, y}, grid, 1)
	}
	im.DrawList_AddLine(dl, {pos.x + 2, mid}, {pos.x + w - 2, mid}, ui.col(t.border), 1)
	if eq == nil do return false
	// Low shelf at 100 Hz, a bell near 900 Hz, high shelf at 8 kHz, on a
	// log axis from 20 Hz to 20 kHz; ±15 dB fills the height.
	gain_at :: proc(eq: ^[3]f32, x: f32) -> f32 {
		lf := x * 3 // decades above 20 Hz
		shelf :: proc(at, edge: f32) -> f32 { return 1 / (1 + math.exp(-(at - edge) * 5)) }
		low := 1 - shelf(lf, math.log10(f32(100) / 20))
		high := shelf(lf, math.log10(f32(8000) / 20))
		d := (lf - math.log10(f32(894) / 20)) * 2.2
		bell := math.exp(-d * d)
		return eq[0] * low + eq[1] * bell + eq[2] * high
	}
	flat := eq[0] == 0 && eq[1] == 0 && eq[2] == 0
	c := t.text_dim if flat || !on else color
	if !on do c = ui.with_alpha(c, 0.45)
	if hovered do c = ui.lighten(c, 0.2)
	N :: 40
	pts: [N + 1]im.Vec2
	for k in 0 ..= N {
		x := f32(k) / N
		g := clamp(gain_at(eq, x), -15, 15)
		pts[k] = {pos.x + 2 + x * (w - 4), mid - g / 15 * (EQ_H / 2 - 3)}
	}
	if !flat do for k in 0 ..< N {
		a, b := pts[k], pts[k + 1]
		im.DrawList_AddQuadFilled(dl, a, b, {b.x, mid}, {a.x, mid}, ui.col(ui.with_alpha(c, 0.18)))
	}
	im.DrawList_AddPolyline(dl, &pts[0], N + 1, ui.col(c), 1.5)
	if hovered do im.SetTooltip("%s", fmt.ctprintf("EQ %s: low %+.1f, mid %+.1f, high %+.1f dB · click to edit it", "on" if on else "off", eq[0], eq[1], eq[2]))
	return clicked
}

// One row of a strip: a dark well with `label` (an effect, a send, the
// output). Returns the row's corners and whether it was clicked.
@(private)
row :: proc(a: ^App, id: cstring, label: string, color: ui.Color, highlight := false, h: f32 = ROW_H) -> (lo, hi: im.Vec2, clicked: bool) {
	t := ui.theme()
	dl := im.GetWindowDrawList()
	lo = im.GetCursorScreenPos()
	hi = {lo.x + inner_w(), lo.y + h}
	clicked = im.InvisibleButton(id, {inner_w(), h})
	part(string(id)[2:]) // "##send B" → "A1 send B", "##slot 1" → "A1 slot 1"
	hovered := im.IsItemHovered()
	bg := t.accent if highlight else (t.hover if hovered else well(t))
	im.DrawList_AddRectFilled(dl, lo, hi, ui.col(bg), 3)
	// A taller row (the Mixer's I/O) in the label size on a wide strip.
	if h > ROW_H && !narrow() do im.PushFontFloat(a.platform.fonts.regular, 14)
	else do small(a)
	text_in(dl, lo, hi, label, t.accent_text if highlight else color)
	im.PopFont()
	// The gap below it without an item: callers read the row's own state
	// (hovered, dragged, right-clicked) as the last item's.
	im.SetCursorPosY(im.GetCursorPosY() + 2)
	return
}

// An effect slot: its effect's name (dim when off); click to edit it in
// the Effects tab. An empty slot shows "+" under the mouse.
@(private)
slot_row :: proc(a: ^App, target: pm.Fx_Target, s: pm.Effect_Slot, failed: bool) {
	t := ui.theme()
	name := pm.slot_name(s) if s.kind != .None else ""
	if failed do name = fmt.tprintf("%s (missing)", name)
	color := t.text if s.on else t.text_dim
	if failed do color = t.danger
	_, _, clicked := row(a, fmt.ctprintf("##slot %d", target.slot + 1), name, color, a.fx == target)
	if s.kind == .None { // empty: a faint +, clear on hover (click: add an effect)
		lo, hi := im.GetItemRectMin(), im.GetItemRectMax()
		small(a)
		text_in(im.GetWindowDrawList(), lo, hi, "+", t.text_dim if im.IsItemHovered() else ui.with_alpha(t.text_dim, 0.35))
		im.PopFont()
	}
	if clicked do show_device(a, target)
	// Dragged onto another slot of its chain: they swap.
	if s.kind != .None && im.BeginDragDropSource() {
		tg := target
		im.SetDragDropPayload("FX_SLOT", &tg, size_of(tg))
		im.Text("%s", fmt.ctprintf("%s", pm.slot_name(s)))
		im.EndDragDropSource()
	}
	if im.BeginDragDropTarget() {
		if pl := im.AcceptDragDropPayload("FX_SLOT"); pl != nil {
			from := (^pm.Fx_Target)(pl.Data)^
			pm.swap_slots(&a.m, from, target)
		}
		im.EndDragDropTarget()
	}
	item_menu(a, {kind = .Slot, fx = target}, "##slotmenu")
	if s.kind != .None && im.IsItemHovered({.DelayShort}) do im.SetTooltip("%s", fmt.ctprintf("%s%s", pm.slot_name(s), "" if s.on else " (off)"))
}

// Pad `pad`'s send to bus `bus` (1..BUSES): the bus's name over a bar of
// its level. Drag it across for its level (Shift: finer), double-click to
// turn it on at 0 dB or off, right-click for pre- or post-fader.
@(private)
send_row :: proc(a: ^App, pad, bus: int) {
	m := &a.m
	t := ui.theme()
	s := m.project.pads[pad].sends[bus - 1]
	on := s.level > 0
	letters := "ABCDEFGHIJKLMNOP"
	letter := letters[bus - 1:][:1]
	short := pm.bus_name(&m.project, bus)
	if short == fmt.tprintf("Bus %s", letter) do short = letter // unnamed: its letter
	if narrow() do short = letter
	name := fmt.tprintf("%s %s", short, "pre" if s.pre else "")
	lo, hi, _ := row(a, fmt.ctprintf("##send %s", letter), "", t.text)
	dl := im.GetWindowDrawList()
	// Its level as a bar across the row (0 dB at its 90%).
	db := pm.send_db(s)
	frac := (db - pm.SEND_MIN_DB) / (6 - pm.SEND_MIN_DB)
	if on do im.DrawList_AddRectFilled(dl, {lo.x + 1, lo.y + 1}, {lo.x + 1 + (hi.x - lo.x - 2) * clamp(frac, 0, 1), hi.y - 1}, ui.col(ui.with_alpha(t.warn if s.pre else t.accent, 0.45)), 2)
	small(a)
	text_in(dl, lo, hi, name, t.text if on else t.text_dim, left = true)
	if on && !narrow() do text_in(dl, {hi.x - 34, lo.y}, hi, fmt.tprintf("%.0f", db), t.text_dim)
	im.PopFont()
	// Input: on the row's button (the last item before the knob drawing).
	send_input(a, pad, bus, max(hi.x - lo.x, 40) * 1.5, horizontal = true) // (a bar: dragged across)
}

// A send's editing, on the last item (its row or its knob): dragged
// (across a row, up and down a knob; Shift finer), the wheel,
// double-click to turn it on at 0 dB or off, right-click for pre- or
// post-fader, its tooltip. With several strips selected, each one's send
// moves by as much.
@(private)
send_input :: proc(a: ^App, pad, bus: int, range: f32, horizontal: bool) {
	m := &a.m
	s := m.project.pads[pad].sends[bus - 1]
	on := s.level > 0
	db := pm.send_db(s)
	v := db
	e := ui_drag(&v, pm.SEND_MIN_DB, 6, 0, range, horizontal = horizontal)
	if horizontal && (im.IsItemHovered() || im.IsItemActive()) do im.SetMouseCursor(.ResizeEW)
	if im.IsItemHovered() && im.IsMouseDoubleClicked(.Left) {
		v = pm.SEND_MIN_DB if on else 0
		e.changed, e.ended = true, true
	}
	knob_target(a, fixed_target(.Pad, pad, .Send, bus - 1))
	defer knob_target(a, {})
	ui.knob_report(e, v)
	targets := strip_targets(a, pad)
	multi_edit(a, card(targets), e.changed, false)
	if e.changed do for j in 0 ..< pm.PADS do if j in targets {
		cur := pm.send_db(m.project.pads[j].sends[bus - 1])
		pm.set_send_db(m, j, bus, clamp(v if j == pad else cur + (v - db), pm.SEND_MIN_DB, 6))
	}
	multi_edit(a, card(targets), false, e.ended)
	if e.ended do app.seal(&m.history)
	if im.BeginPopupContextItem(fmt.ctprintf("##sendmenu%d", bus)) {
		knob_menu_items(a)
		if im.MenuItem("Pre-fader", nil, s.pre) do pm.set_send_pre(m, pad, bus, !s.pre)
		if im.MenuItem("Off", nil, false, on) {
			pm.set_send_db(m, pad, bus, pm.SEND_MIN_DB)
			app.seal(&m.history)
		}
		im.EndPopup()
	}
	if im.IsItemHovered({.DelayShort}) && !im.IsItemActive() {
		im.SetTooltip("%s", fmt.ctprintf("Send to %s: %s, %s-fader", pm.bus_name(&m.project, bus), "off" if !on else fmt.tprintf("%+.1f dB", db), "pre" if s.pre else "post"))
	}
}

// Pad `pad`'s sends as knobs, a few to a row (the bottom area folded: the
// room the bar would leave goes to them): each a ring of its level (0 dB
// at the top, orange when pre-fader) over its bus's letter or name.
@(private)
send_knobs :: proc(a: ^App, pad: int) {
	m := &a.m
	t := ui.theme()
	n := m.project.bus_count
	per := send_knobs_a_row()
	cell_w := inner_w() / f32(per)
	letters := "ABCDEFGHIJKLMNOP"
	dl := im.GetWindowDrawList()
	x0 := im.GetCursorScreenPos().x
	for b in 1 ..= n {
		col := (b - 1) % per
		if col > 0 do im.SameLine(0, 0)
		else do im.SetCursorScreenPos({x0, im.GetCursorScreenPos().y})
		s := m.project.pads[pad].sends[b - 1]
		on := s.level > 0
		letter := letters[b - 1:][:1]
		pos := im.GetCursorScreenPos()
		im.InvisibleButton(fmt.ctprintf("##send %s", letter), {cell_w, SEND_KNOB_H})
		part(fmt.tprintf("send %s", letter))
		hovered := im.IsItemHovered() || im.IsItemActive()
		// The ring.
		r := min(cell_w / 2 - 4, 13)
		c := im.Vec2{pos.x + cell_w / 2, pos.y + r + 3}
		a0, sweep := f32(math.PI) * 0.75, f32(math.PI) * 1.5
		db := pm.send_db(s)
		frac := clamp((db - pm.SEND_MIN_DB) / (6 - pm.SEND_MIN_DB), 0, 1)
		im.DrawList_AddCircleFilled(dl, c, r - 3, ui.col(t.hover if hovered else t.raised), 24)
		im.DrawList_PathArcTo(dl, c, r, a0, a0 + sweep, 24)
		im.DrawList_PathStroke(dl, ui.col(well(t)), 3)
		if on {
			im.DrawList_PathArcTo(dl, c, r, a0, a0 + sweep * frac, 24)
			im.DrawList_PathStroke(dl, ui.col(t.warn if s.pre else t.accent), 3)
			at := a0 + sweep * frac
			im.DrawList_AddLine(dl, c, {c.x + math.cos(at) * (r - 2), c.y + math.sin(at) * (r - 2)}, ui.col(t.text), 1.5)
		}
		// Its bus under it: the letter, or its name when it has one and fits.
		label := pm.bus_name(&m.project, b)
		if label == fmt.tprintf("Bus %s", letter) do label = letter
		small(a)
		if im.CalcTextSize(fmt.ctprintf("%s", label)).x > cell_w - 2 do label = letter
		text_in(dl, {pos.x, c.y + r}, {pos.x + cell_w, pos.y + SEND_KNOB_H}, label, t.text if on else t.text_dim)
		im.PopFont()
		send_input(a, pad, b, 120, horizontal = false)
	}
	if n > 0 do im.Dummy({0, 0})
}

// Dragging the last item changes `value` (as ui's knobs do; the press
// itself doesn't move it), and double-click is left to the caller.
@(private)
ui_drag :: proc(value: ^f32, lo, hi, default, range_px: f32, horizontal := false) -> (e: ui.Edit) {
	io := im.GetIO()
	if im.IsItemActivated() do e.started = true
	if im.IsItemActive() && !e.started {
		e.active = true
		d := io.MouseDelta.x if horizontal else -io.MouseDelta.y
		if d != 0 {
			speed := (hi - lo) / range_px
			if io.KeyShift do speed *= 0.1
			v := clamp(value^ + d * speed, lo, hi)
			if v != value^ {
				value^ = v
				e.changed = true
			}
		}
	}
	if im.IsItemDeactivated() do e.ended = true
	if im.IsItemHovered() && io.MouseWheel != 0 && !im.IsItemActive() {
		v := clamp(value^ + io.MouseWheel * (hi - lo) * 0.02, lo, hi)
		if v != value^ {
			value^ = v
			e.changed, e.ended = true, true
		}
	}
	return
}

// Where a strip's sound goes: Main or a bus in use; click to pick (for
// every selected strip, when it is one of them).
@(private)
output_row :: proc(a: ^App, pad: int) {
	m := &a.m
	t := ui.theme()
	cur := int(m.project.pads[pad].bus)
	_, _, clicked := row(a, "##output", fmt.tprintf("%s %s", ui.ICON_ARROW_RIGHT, route_name(a, cur)), t.warn if route_missing(a, cur) else t.text, h = io_h())
	if clicked do im.OpenPopup("##outmenu")
	if im.IsItemHovered() && !clicked do im.SetTooltip("%s", fmt.ctprintf("Output: %s (click to route it)", route_name(a, cur, true)))
	if im.BeginPopup("##outmenu") {
		pick := -1
		for b in 0 ..= m.project.bus_count do if im.MenuItem(fmt.ctprintf("%s###out%d", pm.bus_name(&m.project, b), b), nil, b == cur) do pick = b
		if d, ok := out_pairs_menu(a, cur); ok do pick = d
		if pick >= 0 {
			targets := strip_targets(a, pad)
			app.begin(&m.history, "Route")
			for j in 0 ..< pm.PADS do if j in targets do pm.set_pad_bus(m, j, pick)
			app.end(&m.history)
			app.seal(&m.history)
		}
		im.EndPopup()
	}
}

// Track `pad`'s audio input (a channel or pair of the interface, with its
// level along the row); click to choose.
@(private)
audio_in_row :: proc(a: ^App, pad: int, h: f32 = -1) {
	m := &a.m
	t := ui.theme()
	text := audio_in_text(a, pad)
	lo, hi, clicked := row(a, "##audio in", fmt.tprintf("%s %s", ui.ICON_MIC, text), t.text_dim, h = io_h() if h < 0 else h)
	dl := im.GetWindowDrawList()
	in_ := m.project.pads[pad].input
	lvl := input_view(a, app.host_input_channel(&a.host, int(in_.channel))).peak
	if in_.stereo do lvl = max(lvl, input_view(a, app.host_input_channel(&a.host, int(in_.channel) + 1)).peak)
	db := 20 * math.log10(max(lvl, 1e-6))
	f := clamp((db + 60) / 60, 0, 1)
	if f > 0 do im.DrawList_AddRectFilled(dl, {lo.x + 2, hi.y - 3}, {lo.x + 2 + (hi.x - lo.x - 4) * f, hi.y - 1}, ui.col(t.ok if db < -12 else (t.warn if db < -1 else t.danger)), 1)
	if im.IsItemHovered() && !clicked do im.SetTooltip("%s", fmt.ctprintf("Audio in: %s (what it records; click to choose)", text))
	if clicked do im.OpenPopup("##audioinmenu")
	if im.BeginPopup("##audioinmenu") {
		audio_in_items(a, pad)
		im.EndPopup()
	}
}

// A pad's monitoring, a menu as Live's: Auto (an audio track: its input
// heard while armed; any other pad: while a sample is recorded into it),
// In (always), Off (never; it still records).
@(private)
monitor_row :: proc(a: ^App, pad: int, h: f32) {
	m := &a.m
	t := ui.theme()
	p := m.project.pads[pad]
	internal := p.input.from != .Interface // (resampling, or no input: nothing to monitor)
	NAMES := [pm.Monitor]string{.Auto = "Auto", .In = "In", .Off = "Off"}
	text := "—" if internal else (NAMES[p.monitor] if narrow() || h <= ROW_H else fmt.tprintf("Monitor: %s", NAMES[p.monitor]))
	_, _, clicked := row(a, "##monitor", fmt.tprintf("%s %s", ui.ICON_HEADPHONES, text), t.text_dim if !internal else ui.with_alpha(t.text_dim, 0.5), highlight = !internal && p.monitor == .In, h = h)
	if im.IsItemHovered() && !clicked {
		tip := "No input: nothing to monitor" if p.input.from == .None else "Resampling: its source is heard already, so it isn't monitored" if internal else ("Monitoring: Auto (its input heard while it is armed), In (always), Off (never; it still records). Use headphones." if p.kind == .Audio else "Monitoring its input: Auto (while you sample into it), In (always), Off (never; it still records). Use headphones.")
		im.SetTooltip("%s", fmt.ctprintf("%s", tip))
	}
	if clicked && !internal do im.OpenPopup("##monitormenu")
	if im.BeginPopup("##monitormenu") {
		for mo in pm.Monitor {
			if im.MenuItem(fmt.ctprintf("%s###mon%d", NAMES[mo], int(mo)), nil, p.monitor == mo) {
				x := m.project.pads[pad]
				x.monitor = mo
				pm.set_pad(m, pad, .Monitor, "Monitor", x)
				app.seal(&m.history)
			}
			ui.name(fmt.tprintf("monitor %s", NAMES[mo]))
		}
		im.EndPopup()
	}
}

// Track `pad`'s MIDI input (with its activity light); click to choose.
@(private)
midi_in_row :: proc(a: ^App, pad: int, h: f32 = -1) {
	t := ui.theme()
	text := midi_in_text(a, pad)
	lo, hi, clicked := row(a, "##midi in", fmt.tprintf("%s %s", ui.ICON_KEYBOARD_MUSIC, text), t.text_dim, h = io_h() if h < 0 else h)
	midi_light(im.GetWindowDrawList(), {hi.x - 10, lo.y + (hi.y - lo.y - 7) / 2}, 7, a.io.in_lit[pad], a.io.out_lit[pad])
	if im.IsItemHovered() && !clicked do im.SetTooltip("%s", fmt.ctprintf("MIDI in: %s (click to choose)", text))
	if clicked do im.OpenPopup("##midiinmenu")
	if im.BeginPopup("##midiinmenu") {
		midi_in_items(a, pad)
		im.EndPopup()
	}
}

// Track `pad`'s MIDI out: off, or a port and channel its hits go out on;
// click to choose.
@(private)
midi_out_row :: proc(a: ^App, pad: int) {
	m := &a.m
	t := ui.theme()
	out := m.project.pads[pad].midi_out
	port := "Default" if out.port == "" else port_name(a, out.port, false)
	text := fmt.tprintf("%s %s", ui.ICON_KEYBOARD_MUSIC, fmt.tprintf("%s · %d", port, out.channel + 1) if out.on else "No MIDI out")
	_, _, clicked := row(a, "##midi out", text, t.text if out.on else t.text_dim, h = io_h())
	if im.IsItemHovered() && !clicked do im.SetTooltip("%s", fmt.ctprintf("MIDI out: %s (its hits also go out as a note; click to choose)", fmt.tprintf("%s, channel %d", port, out.channel + 1) if out.on else "off"))
	if clicked do im.OpenPopup("##midioutmenu")
	if im.BeginPopup("##midioutmenu") {
		set :: proc(m: ^pm.Model, i: int, o: pm.Midi_Out) {
			p := m.project.pads[i]
			p.midi_out = o
			pm.set_pad(m, i, .Midi_Out, "MIDI Out", p)
			app.seal(&m.history)
		}
		if im.Selectable("Off", !out.on) {
			o := out
			o.on = false
			set(m, pad, o)
		}
		turn_on :: proc(o: pm.Midi_Out, pad: int, port: string) -> pm.Midi_Out {
			x := o
			x.on, x.port = true, port
			if x.key == 0 do x.key = u8(pm.pad_key(pad))
			return x
		}
		if im.Selectable("Default output (Settings)", out.on && out.port == "") do set(m, pad, turn_on(out, pad, ""))
		for p in app.host_midi_ports(&a.host, context.temp_allocator) do if p.direction == .Output {
			if im.Selectable(fmt.ctprintf("%s###mo%s", p.name, p.id), out.on && p.id == out.port) do set(m, pad, turn_on(out, pad, pm.intern(&m.project, p.id)))
		}
		if out.on && im.BeginMenu("Channel") {
			for ch in 0 ..< 16 do if im.MenuItem(fmt.ctprintf("%d", ch + 1), nil, int(out.channel) == ch) {
				o := out
				o.channel = u8(ch)
				set(m, pad, o)
			}
			im.EndMenu()
		}
		im.EndPopup()
	}
}

// Where bus `b` (0..BUSES-1) goes: Main or another bus (not one that would
// bring it round to itself); click to pick. Main's: the output.
@(private)
bus_output_row :: proc(a: ^App, b: int) {
	m := &a.m
	t := ui.theme()
	if b >= pm.BUSES {
		row(a, "##output", "Output", t.text_dim, h = io_h())
		return
	}
	cur := int(m.project.buses[b].dest)
	_, _, clicked := row(a, "##output", fmt.tprintf("%s %s", ui.ICON_ARROW_RIGHT, route_name(a, cur)), t.warn if route_missing(a, cur) else t.text, h = io_h())
	if clicked do im.OpenPopup("##busout")
	if im.IsItemHovered() && !clicked do im.SetTooltip("%s", fmt.ctprintf("Output: %s (click to route it)", route_name(a, cur, true)))
	if im.BeginPopup("##busout") {
		for d in 0 ..= m.project.bus_count do if d != b + 1 {
			ok := pm.bus_dest_ok(&m.project, b + 1, d)
			if im.MenuItem(fmt.ctprintf("%s###bo%d", pm.bus_name(&m.project, d), d), nil, d == cur, ok) do pm.set_bus_dest(m, b + 1, d)
		}
		if d, ok := out_pairs_menu(a, cur); ok do pm.set_bus_dest(m, b + 1, d)
		im.EndPopup()
	}
}

// A small pan knob, centred in the strip: drag up and down, double-click
// to centre.
@(private)
pan_knob :: proc(a: ^App, pan: ^f32) -> ui.Edit {
	t := ui.theme()
	dl := im.GetWindowDrawList()
	pos := im.GetCursorScreenPos()
	w := inner_w()
	ph := pan_h()
	im.InvisibleButton("##pan", {w, ph})
	part("pan")
	e := ui_drag(pan, -1, 1, 0, 120)
	if im.IsItemHovered() && im.IsMouseDoubleClicked(.Left) {
		pan^ = 0
		e.changed, e.ended = true, true
	}
	automation_menu(a, "##panauto")
	ui.knob_report(e, pan^)
	r: f32 = 16 if strip_big_knobs else 10
	c := im.Vec2{pos.x + w / 2, pos.y + r + 1}
	a0 := f32(math.PI) * 0.75
	sweep := f32(math.PI) * 1.5
	top := a0 + sweep / 2
	im.DrawList_AddCircleFilled(dl, c, r - 3, ui.col(t.raised), 24)
	im.DrawList_PathArcTo(dl, c, r, a0, a0 + sweep, 24)
	stroke: f32 = 4 if strip_big_knobs else 3
	im.DrawList_PathStroke(dl, ui.col(well(t)), stroke)
	at := top + pan^ * sweep / 2
	if abs(pan^) > 0.005 {
		im.DrawList_PathArcTo(dl, c, r, min(top, at), max(top, at), 16)
		im.DrawList_PathStroke(dl, ui.col(t.accent), stroke)
	}
	im.DrawList_AddLine(dl, c, {c.x + math.cos(at) * (r - 2), c.y + math.sin(at) * (r - 2)}, ui.col(t.text), 1.5)
	text := "C"
	if pan^ < -0.005 do text = fmt.tprintf("L%.0f", -pan^ * 100)
	if pan^ > 0.005 do text = fmt.tprintf("R%.0f", pan^ * 100)
	small(a)
	text_in(dl, {pos.x, c.y + r - 1}, {pos.x + w, pos.y + ph + 2}, text, t.text_dim)
	im.PopFont()
	return e
}

// Where `db` sits on a fader (0 at the bottom, 1 at the top): Logic's
// taper, wider near 0 dB.
@(private)
fader_frac :: proc(db: f32) -> f32 {
	if db <= FADER_LO do return 0
	return math.pow(clamp((db - FADER_LO) / (FADER_HI - FADER_LO), 0, 1), 1.5)
}

@(private)
fader_db :: proc(frac: f32) -> f32 {
	return FADER_LO + math.pow(clamp(frac, 0, 1), 1 / 1.5) * (FADER_HI - FADER_LO)
}

// The fader's value and the loudest peak since reset, as Logic shows them
// above the fader (click the peak to reset it).
@(private)
readouts :: proc(a: ^App, db: f32, view: ^[2]Meter_View) {
	t := ui.theme()
	dl := im.GetWindowDrawList()
	pos := im.GetCursorScreenPos()
	two := !narrow() // (narrow: the peak only; the fader's level in its tooltip)
	w := (inner_w() - 3) / 2 if two else inner_w()
	h: f32 = 17
	peak := max(view[0].max, view[1].max)
	pk_db := 20 * math.log10(peak) if peak > 0 else -math.F32_MAX
	small(a)
	for k in (0 if two else 1) ..< 2 {
		lo := im.Vec2{pos.x + f32(k) * (w + 3), pos.y} if two else pos
		hi := im.Vec2{lo.x + w, lo.y + h}
		im.DrawList_AddRectFilled(dl, lo, hi, ui.col(well(t)), 3)
		if k == 0 {
			text_in(dl, lo, hi, "-inf" if db <= FADER_LO else fmt.tprintf("%.1f", db), t.text)
		} else {
			hot := pk_db > 0
			if hot do im.DrawList_AddRectFilled(dl, lo, hi, ui.col(t.danger), 3)
			text_in(dl, lo, hi, "-inf" if pk_db < -60 else fmt.tprintf("%.1f", pk_db), t.bg if hot else t.text_dim)
		}
	}
	im.PopFont()
	im.SetCursorScreenPos({pos.x + w + 3, pos.y} if two else pos)
	if im.InvisibleButton("##peak", {w, h}) do for &v in view do v.max = 0
	part("peak")
	if im.IsItemHovered({.DelayShort}) do im.SetTooltip("%s", fmt.ctprintf("Peak since reset%s: click to reset", "" if two else fmt.tprintf(" (the fader at %.1f dB)", db)))
	im.SetCursorScreenPos({pos.x, pos.y + h + 4})
}

// The fader, a dB scale, and the stereo meter, `h` tall; with `gr_db` ≥ 0
// (a compressor, gate or limiter on it), its gain reduction as a bar down
// from the top beside the meter.
@(private)
fader_meter :: proc(a: ^App, value: ^f32, view: ^[2]Meter_View, h: f32, gr_db: f32 = -1) -> (e: ui.Edit) {
	t := ui.theme()
	dl := im.GetWindowDrawList()
	pos := im.GetCursorScreenPos()
	w := inner_w()
	fader_w: f32 = 24 if !narrow() else 18
	meter_w: f32 = 5
	scale_w: f32 = 20 if !narrow() else 0
	gr_w: f32 = 4 if gr_db >= 0 else 0
	total := fader_w + scale_w + 2 * meter_w + 2 + (gr_w + 2 if gr_w > 0 else 0)
	x0 := pos.x + (w - total) / 2
	top, bottom := pos.y + 6, pos.y + h - 6
	y_of :: proc(frac, top, bottom: f32) -> f32 { return bottom - (bottom - top) * frac }

	// The fader.
	im.SetCursorScreenPos({x0, pos.y})
	im.InvisibleButton("##fader", {fader_w, h})
	part("fader")
	frac := fader_frac(value^)
	f := frac
	e = ui_drag(&f, 0, 1, 0, bottom - top)
	if e.changed do value^ = fader_db(f)
	if im.IsItemHovered() && im.IsMouseDoubleClicked(.Left) {
		value^ = 0
		e.changed, e.ended = true, true
	}
	automation_menu(a, "##faderauto")
	ui.knob_report(e, value^)
	hovered := im.IsItemHovered() || im.IsItemActive()
	cx := x0 + fader_w / 2
	im.DrawList_AddRectFilled(dl, {cx - 2, top}, {cx + 2, bottom}, ui.col(well(t)), 2)
	y := y_of(fader_frac(value^), top, bottom)
	cap := t.hover if hovered else t.pressed
	im.DrawList_AddRectFilled(dl, {x0 + 1, y - 9}, {x0 + fader_w - 1, y + 9}, ui.col(cap), 3)
	im.DrawList_AddLine(dl, {x0 + 4, y}, {x0 + fader_w - 4, y}, ui.col(t.text), 1.5)
	if im.IsItemActive() do im.SetTooltip("%s", fmt.ctprintf("%+.1f dB", value^))

	// The scale: marks between the fader and the meter.
	sx := x0 + fader_w + 1
	small(a)
	last := -max(f32)
	if scale_w > 0 do for db in ([]f32{6, 0, -6, -12, -24, -40}) {
		yy := y_of(fader_frac(db), top, bottom)
		label := fmt.ctprintf("+%d" if db > 0 else "%d", int(abs(db)))
		ts := im.CalcTextSize(label)
		if yy - last < ts.y do continue // too close to the one above on a short fader
		last = yy
		im.DrawList_AddText(dl, {sx + scale_w - ts.x - 2, yy - ts.y / 2}, ui.col(ui.with_alpha(t.text_dim, 0.8)), label)
		im.DrawList_AddLine(dl, {sx + scale_w - 1, yy}, {sx + scale_w + 2 * meter_w + 2, yy}, ui.col(ui.with_alpha(t.border, 0.6)), 1)
	}
	im.PopFont()

	// The meter, on the fader's scale: green, then amber, then red (dBFS:
	// above -12 and 0; a K scale: above its 0 and its +4); the peak bar with
	// the RMS (the average) inside it, the bright one as Settings says; the
	// held peak a line.
	ms := a.settings.meters
	warn_db, hot_db: f32 = -12, 0
	switch ms.scale {
	case .Dbfs:
	case .K12: warn_db, hot_db = -12, -8
	case .K14: warn_db, hot_db = -14, -10
	case .K20: warn_db, hot_db = -20, -16
	}
	mx := sx + scale_w
	for c in 0 ..< 2 {
		x := mx + f32(c) * (meter_w + 2)
		im.DrawList_AddRectFilled(dl, {x, top}, {x + meter_w, bottom}, ui.col(well(t)), 1)
		v := view[c]
		bar :: proc(dl: ^im.DrawList, x0, x1, top, bottom: f32, level: f32, warn_db, hot_db: f32, alpha: f32) {
			t := ui.theme()
			lvl := fader_frac(20 * math.log10(level)) if level > 0 else 0
			if lvl <= 0 do return
			yy := bottom - (bottom - top) * lvl
			yw := bottom - (bottom - top) * fader_frac(warn_db)
			yh := bottom - (bottom - top) * fader_frac(hot_db)
			im.DrawList_AddRectFilled(dl, {x0, max(yy, yw)}, {x1, bottom}, ui.col(ui.with_alpha(t.ok, alpha)), 1)
			if yy < yw do im.DrawList_AddRectFilled(dl, {x0, max(yy, yh)}, {x1, yw}, ui.col(ui.with_alpha(t.warn, alpha)), 1)
			if yy < yh do im.DrawList_AddRectFilled(dl, {x0, yy}, {x1, yh}, ui.col(ui.with_alpha(t.danger, alpha)), 1)
		}
		bar(dl, x, x + meter_w, top, bottom, v.peak, warn_db, hot_db, 0.45 if ms.rms else 1)
		bar(dl, x + 1, x + meter_w - 1, top, bottom, v.rms, warn_db, hot_db, 1 if ms.rms else 0.55)
		if v.hold > 0 && ms.hold_s > 0 {
			hy := y_of(fader_frac(20 * math.log10(v.hold)), top, bottom)
			im.DrawList_AddLine(dl, {x, hy}, {x + meter_w, hy}, ui.col(t.text), 1.5)
		}
	}
	// The gain reduction: down from the top, 0 to 24 dB.
	if gr_w > 0 {
		x := mx + 2 * (meter_w + 2)
		im.DrawList_AddRectFilled(dl, {x, top}, {x + gr_w, bottom}, ui.col(well(t)), 1)
		gf := clamp(gr_db / 24, 0, 1)
		if gf > 0.002 do im.DrawList_AddRectFilled(dl, {x, top}, {x + gr_w, top + (bottom - top) * gf}, ui.col(ui.rgb(0xd98a2b)), 1)
		if im.IsMouseHoveringRect({x - 1, top}, {x + gr_w + 1, bottom}) do im.SetTooltip("%s", fmt.ctprintf("Gain reduction: %.1f dB", gr_db))
	}
	im.SetCursorScreenPos({pos.x, pos.y + h})
	im.Dummy({w, 0})
	return
}

// Mute and Solo (Mute alone without `solo`), as Logic colours them, and
// for an audio pad its record arm.
@(private)
mute_solo :: proc(a: ^App, mute, solo: ^bool, arm: ^bool = nil) -> (changed: bool) {
	t := ui.theme()
	parts := [3]^bool{mute, solo, arm}
	names := [3]cstring{"M##m", "S##s", "R##r"}
	probes := [3]string{"mute", "solo", "arm"}
	letters := [3]string{"M", "S", "R"}
	tips := [3]cstring{"Mute", "Solo", "Arm: it records while you record"}
	colors := [3]ui.Color{ui.rgb(0x3d9cf5), t.warn, t.danger}
	n := 0
	for x in parts do if x != nil do n += 1
	w := (inner_w() - 4 * f32(n - 1)) / f32(n)
	dl := im.GetWindowDrawList()
	first := true
	for on, which in parts {
		if on == nil do continue
		if !first do im.SameLine(0, 4)
		first = false
		pos := im.GetCursorScreenPos()
		bh := ms_h()
		pressed := im.InvisibleButton(names[which], {w, bh})
		part(probes[which])
		if pressed {
			on^ = !on^
			changed = true
		}
		hovered := im.IsItemHovered()
		bg := colors[which] if on^ else (t.hover if hovered else well(t))
		im.DrawList_AddRectFilled(dl, pos, {pos.x + w, pos.y + bh}, ui.col(bg), 3)
		im.PushFontFloat(a.platform.fonts.semibold, 14 if bh > ROW_H else 12)
		text_in(dl, pos, {pos.x + w, pos.y + bh}, letters[which], t.bg if on^ else t.text_dim)
		im.PopFont()
		if hovered do im.SetTooltip("%s", tips[which])
	}
	return
}

// The strip's name on its colour, at the bottom. True when clicked.
@(private)
name_plate :: proc(name: string, color: ui.Color) -> bool {
	t := ui.theme()
	dl := im.GetWindowDrawList()
	pos := im.GetCursorScreenPos()
	h: f32 = 21
	clicked := im.InvisibleButton("##name", {inner_w(), h})
	part("name")
	im.DrawList_AddRectFilled(dl, pos, {pos.x + inner_w(), pos.y + h}, ui.col(color), 3)
	// Dark or light text, for the colour.
	lum := 0.3 * color.r + 0.59 * color.g + 0.11 * color.b
	text_in(dl, pos, {pos.x + inner_w(), pos.y + h}, name, ui.rgb(0x111214) if lum > 0.55 else ui.rgb(0xffffff))
	_ = t
	return clicked
}

// The height a strip's fader gets: what is left of `h` after the rest (a
// compact strip has no EQ display, inserts or sends).
@(private)
fader_h :: proc(h: f32, compact := false, block: f32 = 0) -> f32 {
	fixed := strip_fixed_h(compact)
	if !compact && block > 0 do fixed += block + 4
	return max(h - fixed, 40)
}

// A strip's height without its fader and its block of insert and send
// rows.
@(private)
strip_fixed_h :: proc(compact := false) -> f32 {
	fixed: f32 = 2 * STRIP_PAD + 4 + pan_h() + 4 + 21 + 4 + ms_h() + 4 + 21
	if compact do fixed += 4 * (ROW_H + 2) + 4 // (audio in, its monitoring, MIDI in, out)
	else if strip_view.io do fixed += 5 * (io_h() + 2) + 8 // (two in and the monitoring above the pan, two out at the foot)
	if !compact && strip_view.eq do fixed += EQ_H + 4
	return fixed
}

// The height of the block of inserts and sends (on a bus: slots) every
// strip shows: all they have (the most of any strip), or what fits,
// leaving the fader at least 70 points (the rest scroll; a row at the
// least). Sends are rows, or (the bottom area folded) knobs, a few a row.
@(private)
block_h :: proc(a: ^App, h: f32) -> f32 {
	p := &a.m.project
	cue := 1 if cue_on(a) else 0
	want: f32 = f32(pm.BUS_SLOTS) * (ROW_H + 2) if strip_view.inserts else 0
	pad_want: f32 = f32(pm.PAD_INSERTS) * (ROW_H + 2) if strip_view.inserts else 0
	if strip_view.sends {
		if strip_big_knobs {
			pad_want += f32((p.bus_count + send_knobs_a_row() - 1) / send_knobs_a_row()) * SEND_KNOB_H + f32(cue) * (ROW_H + 2)
		} else {
			pad_want += f32(p.bus_count + cue) * (ROW_H + 2)
		}
	}
	want = max(want, pad_want)
	if want <= 0 do return 0
	fit := h - strip_fixed_h() - 70 - 4
	return clamp(want, 0, max(fit, ROW_H + 2))
}

// Sends as knobs: how many to a row.
@(private)
send_knobs_a_row :: proc() -> int { return 2 if narrow() else 3 }

// --- strips --------------------------------------------------------------------------------

// Pad `i`'s strip, `h` tall; `compact` (the bottom panel's): its output,
// pan, readouts, fader, mute and solo, and name.
@(private)
pad_strip :: proc(a: ^App, i: int, h: f32, compact := false) {
	m := &a.m
	pad := m.project.pads[i]
	im.PushIDInt(i32(i))
	defer im.PopID()
	strip_name = pm.pad_label(i)
	top := im.GetCursorScreenPos()
	strip_begin(h, i in selected_pads(a) && !compact)
	defer strip_end(top, h)
	t := ui.theme()
	color := ui.rgb(pad.color)

	if !compact {
		eq := pad.eq
		if strip_view.eq {
			// Its EQ's switch at the left (off to start with), its curve beside.
			bw: f32 = 16
			row_pos := im.GetCursorScreenPos()
			if ui.icon_button(ui.ICON_POWER, fmt.ctprintf("%s's EQ: %s (click to turn it %s)", pm.pad_label(i), "on" if pad.eq_on else "off", "off" if pad.eq_on else "on"), on = pad.eq_on, size = bw) {
				np := pad
				np.eq_on = !pad.eq_on
				pm.set_pad(m, i, .Eq_Low, "EQ On" if np.eq_on else "EQ Off", np)
				app.seal(&m.history)
			}
			part("eq switch")
			im.SetCursorScreenPos({row_pos.x + bw + 2, row_pos.y})
			if eq_thumb(&eq, color, pad.eq_on, inner_w() - bw - 2) {
				a.selected = i
				show_eq(a)
			}
			gap()
		}
		// Its inserts and a send to each bus in use: as many rows as the
		// room has (the same for every strip); more scroll.
		if bh := block_h(a, h); bh > 0 {
			im.PushStyleVar(.ScrollbarSize, 4)
			if im.BeginChild("##block", {inner_w() + 6, bh}, {}, {}) {
				if strip_view.inserts do for s, k in pad.inserts {
					failed := pm.slot_failed(&m.engine, i, -1, k)
					slot_row(a, {.Pad, i, k}, s, failed)
				}
				if strip_view.sends && strip_big_knobs do send_knobs(a, i)
				else if strip_view.sends do for b in 1 ..= m.project.bus_count do send_row(a, i, b)
				if strip_view.sends && cue_on(a) do cue_row(a, i, -1)
				im.Dummy({0, 0}) // (the rows end on a cursor move)
			}
			im.EndChild()
			im.PopStyleVar()
			// What its inserts delay it by (the others are delayed to match).
			if lat := pm.track_latency(&m.engine, i); lat > 0 {
				rate := a.host.format.sample_rate if a.host.format.sample_rate > 0 else 48_000
				if im.IsItemHovered() do im.SetTooltip("%s", fmt.ctprintf("Its effects add %d frames (%.1f ms); the other tracks are delayed to match", lat, f64(lat) * 1000 / rate))
			}
			gap()
		}
	}
	// What comes in: its audio input and its MIDI input, above its pan.
	if strip_view.io && !compact {
		audio_in_row(a, i)
		monitor_row(a, i, io_h())
		midi_in_row(a, i)
		gap()
	}
	// With several strips selected (Shift- or Cmd-click their names), an
	// edit of one changes them all: level and pan by as much, mute and
	// solo to the same.
	targets := strip_targets(a, i)
	pan := pad.pan
	knob_target(a, pad_field_target(a, i, .Pan))
	pe := pan_knob(a, &pan)
	knob_target(a, {})
	multi_edit(a, card(targets), pe.changed, false)
	if pe.changed do for j in 0 ..< pm.PADS do if j in targets {
		p := m.project.pads[j]
		p.pan = pan if j == i else clamp(p.pan + (pan - pad.pan), -1, 1)
		pm.set_pad(m, j, .Pan, "Set Pan", p)
	}
	multi_edit(a, card(targets), false, pe.ended)
	if pe.ended do app.seal(&m.history)
	gap()
	vol := pad.volume
	readouts(a, vol, &a.mixer.pads[i])
	knob_target(a, fixed_target(.Pad, i, .Volume))
	fe := fader_meter(a, &vol, &a.mixer.pads[i], fader_h(h, compact, 0 if compact else block_h(a, h)), strip_reduction(a, .Pad, i, pm.PAD_INSERTS))
	knob_target(a, {})
	multi_edit(a, card(targets), fe.changed, false)
	if fe.changed do for j in 0 ..< pm.PADS do if j in targets {
		p := m.project.pads[j]
		p.volume = vol if j == i else clamp(p.volume + (vol - pad.volume), FADER_LO, FADER_HI)
		pm.set_pad(m, j, .Volume, "Set Volume", p)
	}
	multi_edit(a, card(targets), false, fe.ended)
	if fe.ended do app.seal(&m.history)
	gap()
	mute, solo := pad.mute, pad.solo
	armed := pm.track_armed(m, i)
	if mute_solo(a, &mute, &solo, &armed) {
		if armed != pm.track_armed(m, i) {
			arm_click(a, i)
		} else {
			field: pm.Pad_Field = .Mute if mute != pad.mute else .Solo
			name := "Mute" if mute != pad.mute else "Solo"
			app.begin(&m.history, name)
			for j in 0 ..< pm.PADS do if j in targets {
				p := m.project.pads[j]
				if field == .Mute do p.mute = mute
				else do p.solo = solo
				pm.set_pad(m, j, field, name, p)
			}
			app.end(&m.history)
			app.seal(&m.history)
		}
	}
	gap()
	if compact {
		// What comes in (every pad: sampling into one records its audio
		// input) and its monitoring, its MIDI, and where it goes.
		audio_in_row(a, i, ROW_H)
		monitor_row(a, i, ROW_H)
		midi_in_row(a, i, ROW_H)
		output_row(a, i) // right above its name
		gap()
	} else if strip_view.io {
		midi_out_row(a, i) // where its MIDI goes
		output_row(a, i) // where its sound goes, right above its name
		gap()
	}
	plate := pm.pad_label(i) if narrow() else fmt.tprintf("%s %s", pm.pad_label(i), pm.pad_name(&m.project.pads[i]))
	if name_plate(plate, color) {
		io := im.GetIO()
		if io.KeyShift || io.KeyCtrl || io.KeySuper do select_pad(a, i, false)
		else do a.selected, a.pad_sel, a.pad_anchor = i, {i}, i
	}
	// Its menu: its commands, and its colour (all the selected strips'
	// when it is one of them).
	if im.BeginPopupContextItem("##stripmenu") {
		command_items(a, pad_target(i))
		im.Separator()
		if im.BeginMenu(ui.ICON_PALETTE + "  Colour") {
			pad_color_menu(a, i)
			im.EndMenu()
		}
		ui.name("Colour")
		im.EndPopup()
	}
	_ = t
}

// Bus `b`'s strip (BUSES: main), `h` tall.
@(private)
bus_strip :: proc(a: ^App, b: int, h: f32) {
	m := &a.m
	bus := pm.bus_of(m, b)^
	im.PushIDInt(i32(1000 + b))
	defer im.PopID()
	strip_name = pm.bus_index_name(&m.project, b)
	top := im.GetCursorScreenPos()
	strip_begin(h, false)
	defer strip_end(top, h)
	t := ui.theme()
	is_main := b == pm.BUSES

	if strip_view.eq {
		eq_thumb(nil, t.text_dim) // buses have no EQ: a flat, dim display keeps the rows in line
		gap()
	}
	// Its slots (and its cue send): as many rows as the pads' strips have.
	if bh := block_h(a, h); bh > 0 {
		im.PushStyleVar(.ScrollbarSize, 4)
		if im.BeginChild("##block", {inner_w() + 6, bh}, {}, {}) {
			if strip_view.inserts do for s, k in bus.slots do slot_row(a, {.Bus, b, k}, s, pm.slot_failed(&m.engine, -1, b, k))
			if strip_view.sends && cue_on(a) && !is_main do cue_row(a, -1, b)
			im.Dummy({0, 0})
		}
		im.EndChild()
		im.PopStyleVar()
		gap()
	}
	if strip_view.io { // (in line with the tracks' inputs)
		im.Dummy({inner_w(), 2 * (io_h() + 2)})
		gap()
	}
	pan := bus.pan
	knob_target(a, fixed_target(.Main if is_main else .Bus, 0 if is_main else b, .Pan))
	pe := pan_knob(a, &pan)
	knob_target(a, {})
	if pe.changed {
		nb := bus
		nb.pan = pan
		pm.set_bus(m, b, 2, "Set Pan", nb)
	}
	if pe.ended do app.seal(&m.history)
	gap()
	vol := bus.volume
	readouts(a, vol, &a.mixer.buses[b])
	knob_target(a, fixed_target(.Main if is_main else .Bus, 0 if is_main else b, .Volume))
	fe := fader_meter(a, &vol, &a.mixer.buses[b], fader_h(h, false, block_h(a, h)), strip_reduction(a, .Bus, b, pm.BUS_SLOTS))
	knob_target(a, {})
	if fe.changed {
		nb := bus
		nb.volume = vol
		pm.set_bus(m, b, 0, "Set Volume", nb)
	}
	if fe.ended do app.seal(&m.history)
	gap()
	mute, solo := bus.mute, bus.solo
	if mute_solo(a, &mute, nil if is_main else &solo) {
		nb := bus
		nb.mute, nb.solo = mute, solo
		pm.set_bus(m, b, 1, "Mute" if mute != bus.mute else "Solo", nb)
		app.seal(&m.history)
	}
	gap()
	if strip_view.io {
		im.Dummy({inner_w(), io_h() + 2}) // (in line with the tracks' MIDI outs)
		bus_output_row(a, b) // where it goes, right above its name
		gap()
	}
	if name_plate(pm.bus_index_name(&m.project, b), t.accent if is_main else ui.mix(t.accent, t.text_dim, 0.55)) && !is_main && im.IsMouseDoubleClicked(.Left) do begin_rename_bus(a, b + 1)
	item_menu(a, {kind = .Bus, index = b}, "##busmenu")
}

// Whether the output interface has a cue pair (the strips show cue sends).
cue_on :: proc(a: ^App) -> bool {
	f := interface_find(&a.settings.audio, a.settings.audio.output)
	return f != nil && f.cue >= 0
}

// A strip's cue send (pad `pad`, or bus `bus` when pad < 0): a knob like
// a send's; double-click turns it on at 0 dB or off; right-click for
// pre-fader.
@(private)
cue_row :: proc(a: ^App, pad, bus: int) {
	m := &a.m
	t := ui.theme()
	s := m.project.pads[pad].cue if pad >= 0 else m.project.buses[bus].cue
	set :: proc(m: ^pm.Model, pad, bus: int, s: pm.Send) {
		if pad >= 0 do pm.set_pad_cue(m, pad, s)
		else do pm.set_bus_cue(m, bus, s)
	}
	on := s.level > 0
	lo, hi, _ := row(a, "##cue", "", t.text)
	dl := im.GetWindowDrawList()
	small(a)
	text_in(dl, lo, {hi.x - 18, hi.y}, fmt.tprintf("Cue %s", "pre" if s.pre else ""), t.text if on else t.text_dim, left = true)
	im.PopFont()
	db := pm.send_db(s)
	frac := (db - pm.SEND_MIN_DB) / (6 - pm.SEND_MIN_DB)
	c := im.Vec2{hi.x - 10, (lo.y + hi.y) / 2}
	a0, sweep := f32(math.PI) * 0.75, f32(math.PI) * 1.5
	im.DrawList_PathArcTo(dl, c, 6.5, a0, a0 + sweep, 20)
	im.DrawList_PathStroke(dl, ui.col(t.raised), 2.5)
	if on {
		im.DrawList_PathArcTo(dl, c, 6.5, a0, a0 + sweep * frac, 20)
		im.DrawList_PathStroke(dl, ui.col(t.warn if s.pre else t.accent), 2.5)
	}
	v := db
	e := ui_drag(&v, pm.SEND_MIN_DB, 6, 0, 140)
	part("cue")
	if im.IsItemHovered() && im.IsMouseDoubleClicked(.Left) {
		v = pm.SEND_MIN_DB if on else 0
		e.changed, e.ended = true, true
	}
	if e.changed {
		ns := s
		ns.level = pm.send_level(v)
		set(m, pad, bus, ns)
	}
	if e.ended do app.seal(&m.history)
	if im.BeginPopupContextItem("##cuemenu") {
		if im.MenuItem("Pre-fader", nil, s.pre) {
			ns := s
			ns.pre = !s.pre
			set(m, pad, bus, ns)
			app.seal(&m.history)
		}
		im.EndPopup()
	}
	if im.IsItemHovered({.DelayShort}) && !im.IsItemActive() {
		im.SetTooltip("%s", fmt.ctprintf("To the cue (headphones): %s, %s-fader", "off" if !on else fmt.tprintf("%+.1f dB", db), "pre" if s.pre else "post"))
	}
}

// The gain reduction of the first compressor, gate or limiter in a strip's
// chain (pad `index`'s inserts, or bus `index`'s slots), in dB; -1 when it
// has none.
@(private)
strip_reduction :: proc(a: ^App, kind: pm.Fx_Target_Kind, index, slots: int) -> f32 {
	for k in 0 ..< slots {
		// (The synth's compressor reports it as out against in: under 0.)
		if db, ok := pm.slot_reduction(&a.m.engine, {kind, index, k}); ok do return f32(abs(db))
	}
	return -1
}

// Main's loudness (EBU R128: short-term large, momentary, integrated and
// the true peak; click integrated or true peak to start them again), its
// phase correlation (-1 to +1), and a stereo view (the goniometer: mono
// straight up, wide spread sideways, out of phase flat).
@(private)
draw_main_meters :: proc(a: ^App, h: f32) {
	m := &a.m
	t := ui.theme()
	im.BeginGroup()
	defer im.EndGroup()
	w := f32(MAIN_METERS_W - 6)
	dl := im.GetWindowDrawList()
	mom, short, integ, tp := pm.main_loudness(&m.engine)
	lufs :: proc(x: f32) -> string { return "-inf" if x <= -100 else fmt.tprintf("%.1f", x) }
	col_x := im.GetCursorScreenPos().x
	small(a)
	im.AlignTextToFramePadding()
	im.TextDisabled("Loudness")
	im.PopFont()
	im.SameLine()
	im.SetCursorScreenPos({col_x + w - 16, im.GetCursorScreenPos().y})
	if ui.icon_button(ui.ICON_CHEVRON_RIGHT, "Fold away main's loudness, correlation and stereo view", size = 16) {
		a.settings.mixer_view.meters_folded = true
		settings_save(a)
	}
	ui.name("fold loudness")
	im.PushFontFloat(a.platform.fonts.semibold, 22)
	im.Text("%s", fmt.ctprintf("%s", lufs(short)))
	im.PopFont()
	ui.name("main short-term")
	small(a)
	im.SameLine(0, 4)
	im.AlignTextToFramePadding()
	im.TextDisabled("LUFS-S")
	im.Text("%s", fmt.ctprintf("M  %s", lufs(mom)))
	ui.name("main momentary")
	if im.Selectable(fmt.ctprintf("I  %s  %s###integrated", lufs(integ), ui.ICON_ROTATE_CCW), false, {}, {w, 0}) do pm.main_loudness_reset(&m.engine)
	ui.name("main integrated")
	if im.IsItemHovered() do im.SetTooltip("Integrated loudness since the last reset (gated, EBU R128): click to start again")
	tp_db := 20 * math.log10(max(tp, 1e-9))
	hot := tp_db > -1
	im.PushStyleColorVec4(.Text, transmute(im.Vec4)(t.danger if hot else t.text))
	if im.Selectable(fmt.ctprintf("TP %s dB###truepeak", "-inf" if tp <= 0 else fmt.tprintf("%+.1f", tp_db)), false, {}, {w, 0}) do pm.main_loudness_reset(&m.engine)
	im.PopStyleColor()
	ui.name("main true peak")
	if im.IsItemHovered() do im.SetTooltip("True peak since the last reset (between the samples too); over -1 dBTP it may clip after encoding. Click to start again")
	im.Spacing()
	im.TextDisabled("Correlation")
	im.PopFont()
	pts: [256][2]f32
	corr, n := pm.main_stereo(&m.engine, pts[:])
	pos := im.GetCursorScreenPos()
	bh: f32 = 10
	im.Dummy({w, bh})
	ui.name("main correlation")
	im.DrawList_AddRectFilled(dl, pos, {pos.x + w, pos.y + bh}, ui.col(well(t)), 3)
	mid := pos.x + w / 2
	cx := mid + corr * (w / 2 - 2)
	cc := t.ok if corr >= 0.2 else (t.warn if corr >= -0.2 else t.danger)
	im.DrawList_AddRectFilled(dl, {min(mid, cx), pos.y + 2}, {max(mid, cx), pos.y + bh - 2}, ui.col(cc), 2)
	im.DrawList_AddLine(dl, {mid, pos.y}, {mid, pos.y + bh}, ui.col(t.text_dim), 1)
	if im.IsItemHovered() do im.SetTooltip("%s", fmt.ctprintf("Phase correlation %+.2f: +1 the same in both sides (mono), 0 unrelated, under 0 out of phase (it thins or cancels in mono)", corr))
	small(a)
	im.TextDisabled("%s", fmt.ctprintf("-1        %+.2f        +1", corr))
	im.Spacing()
	im.TextDisabled("Stereo")
	im.PopFont()
	// The goniometer: each point's mid up, its side across (45° turned).
	side := clamp(min(w, h - (im.GetCursorScreenPos().y - pos.y) - 60), 60, w)
	gp := im.GetCursorScreenPos()
	im.Dummy({w, side})
	ui.name("main stereo")
	im.DrawList_AddRectFilled(dl, gp, {gp.x + w, gp.y + side}, ui.col(ui.PLOT_BG), 6)
	gc := im.Vec2{gp.x + w / 2, gp.y + side / 2}
	r := side / 2 - 4
	im.DrawList_AddLine(dl, {gc.x, gp.y + 4}, {gc.x, gp.y + side - 4}, ui.col(ui.with_alpha(t.text, 0.12)), 1)
	im.DrawList_AddLine(dl, {gp.x + 4, gc.y}, {gp.x + w - 4, gc.y}, ui.col(ui.with_alpha(t.text, 0.08)), 1)
	dot := ui.with_alpha(t.ok, 0.55)
	for pt in pts[:n] {
		l, rr := pt[0], pt[1]
		x := (rr - l) * 0.7071 // side
		y := (l + rr) * 0.7071 // mid
		im.DrawList_AddRectFilled(dl, {gc.x + clamp(x, -1, 1) * r, gc.y - clamp(y, -1, 1) * r}, {gc.x + clamp(x, -1, 1) * r + 1.5, gc.y - clamp(y, -1, 1) * r + 1.5}, ui.col(dot))
	}
	if im.IsItemHovered() do im.SetTooltip("The stereo image: mono straight up and down, wide sideways, out of phase flat across")
}
