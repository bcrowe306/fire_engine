package pads

import "core:fmt"
import "core:math"

import app "app:core"
import "app:ui"
import pm "model"
import im "deps:imgui"

// The transport toolbar's state: the tap tempo, and how wide its controls
// were last frame (to centre them).
Transport_State :: struct {
	taps:  pm.Tap_Tempo,
	clock: f64, // seconds of frames (what taps are timed by: frames, so a script's are steady)
	tapped: f64, // when Tap was last pressed (for its flash)
	width: f32,
}

// Height of the transport toolbar.
TOOLBAR_H :: 46

// The transport toolbar, under the menus whatever shows below: play, stop,
// record, loop and count-in; where the playhead is; the sequence; the
// tempo, tap tempo and time signature; the metronome; input quantize.
// Centred; its buttons are icons whose colour shows their state.
draw_toolbar :: proc(user: rawptr) {
	a := (^App)(user)
	m := &a.m
	e := &m.engine
	p := &m.project
	tr := p.transport
	t := ui.theme()
	st := &a.transport
	gap: f32 = 18
	st.clock += f64(im.GetIO().DeltaTime)

	avail := im.GetContentRegionAvail().x
	start := im.GetCursorPosX()
	if st.width > 0 do im.SetCursorPosX(start + max((avail - st.width) / 2, 0))
	x0 := im.GetCursorScreenPos().x
	im.SetCursorPosY((TOOLBAR_H - im.GetFrameHeight()) / 2)
	big := im.GetFrameHeight() + 4

	// Transport.
	beat, playing := pm.timeline_beat(e)
	if ui.icon_button(ui.ICON_PLAY, "Play (Space)", on = playing, color = t.ok, size = big) {
		if !playing do pm.play(e)
	}
	im.SameLine(0, 2)
	if ui.icon_button(ui.ICON_SQUARE, "Stop (Space)", size = big) {
		pm.stop(e)
		pm.capture_arm(m, &a.capture, false)
	}
	im.SameLine(0, 2)
	if ui.icon_button(ui.ICON_CIRCLE_DOT, "Record (Cmd+R)", on = a.capture.armed, color = t.danger, size = big) do toggle_record(a)
	im.SameLine(0, 2)
	if ui.icon_button(ui.ICON_REPEAT, "Loop: on (it goes round)" if tr.loop else "Loop: off (it plays once and stops)", on = tr.loop, size = big) {
		n := tr
		n.loop = !n.loop
		pm.set_transport(m, .Loop, "Loop", n)
		app.seal(&m.history)
	}
	im.SameLine(0, 2)
	ci_tip := fmt.ctprintf("Count-in: %s (click to change)", "off" if tr.count_in == 0 else fmt.tprintf("%d bar%s", tr.count_in, "" if tr.count_in == 1 else "s"))
	if ui.icon_button(ui.ICON_TIMER if tr.count_in > 0 else ui.ICON_TIMER_OFF, ci_tip, on = tr.count_in > 0, size = big) {
		n := tr
		n.count_in = (n.count_in + 1) % 3
		pm.set_transport(m, .Count_In, "Count-in", n)
		app.seal(&m.history)
	}
	if tr.count_in > 0 {
		im.SameLine(0, 0)
		im.AlignTextToFramePadding()
		im.TextColored(transmute(im.Vec4)t.accent, "%s", fmt.ctprintf("%d", tr.count_in))
	}

	// Where the playhead is.
	im.SameLine(0, gap)
	rel, _ := pm.position(e)
	shown := beat if beat < 0 else rel
	bar, bt, six := pm.position_of(p, shown)
	seq := pm.current_sequence(m)
	pos_text := fmt.ctprintf("%d.%d.%d", bar, bt, six) if playing else fmt.ctprintf("1.1.1")
	im.PushFontFloat(a.platform.fonts.semibold, 17)
	ps := im.CalcTextSize("88.8.8")
	at := im.GetCursorScreenPos()
	im.Dummy({ps.x + 8, big})
	ui.name("position")
	cur := im.CalcTextSize(pos_text)
	pc := t.warn if beat < 0 && playing else t.text
	im.DrawList_AddText(im.GetWindowDrawList(), {at.x + (ps.x + 8 - cur.x) / 2, at.y + (big - cur.y) / 2}, ui.col(pc), pos_text)
	im.PopFont()
	if im.IsItemHovered() do im.SetTooltip("%s", fmt.ctprintf("Bar . beat . sixteenth%s; the sequence is %d bar%s", " (counting in)" if beat < 0 && playing else "", seq.bars, "" if seq.bars == 1 else "s"))

	// The sequence.
	im.SameLine(0, gap)
	if ui.icon_button(ui.ICON_CHEVRON_LEFT, "Previous sequence", disabled = p.slot == 0) do pm.select_slot(m, p.slot - 1)
	im.SameLine(0, 0)
	im.SetNextItemWidth(118)
	if ui.combo("##slot", fmt.ctprintf("%s", pm.sequence_name(p, p.slot))) {
		for k in 0 ..< pm.SLOTS {
			label := fmt.ctprintf("%s %s###s%d", ui.ICON_CIRCLE_DOT if pm.slot_used(m, k) else "   ", pm.sequence_name(p, k), k)
			if im.Selectable(label, k == p.slot) do pm.select_slot(m, k)
			if im.BeginPopupContextItem() {
				sequence_menu_items(a, k)
				im.EndPopup()
			}
		}
		im.EndCombo()
	}
	if im.BeginPopupContextItem("##slotmenu") {
		sequence_menu_items(a, p.slot)
		im.EndPopup()
	}
	im.SameLine(0, 0)
	if ui.icon_button(ui.ICON_CHEVRON_RIGHT, "Next sequence", disabled = p.slot >= pm.SLOTS - 1) do pm.select_slot(m, p.slot + 1)

	// Tempo: drag by 1 (Shift: 0.1), tap, and the time signature.
	im.SameLine(0, gap)
	bpm := p.bpm
	te := ui.number_drag("tempo", &bpm, 40, 300, 1, 0.1, "%.1f BPM", 104)
	if te.changed do pm.set_bpm(m, bpm)
	if te.ended do app.seal(&m.history)
	im.SameLine(0, 4)
	// Tap: it flashes with each tap (and while a start is coming, on each
	// beat of the new tempo); the fourth tap starts playback where a fifth
	// would land.
	if pm.tap_start_due(&st.taps, st.clock) && !playing do pm.play(e)
	since := st.clock - st.tapped if st.tapped > 0 else 1e9 // never tapped: dark
	lit := since < 0.12
	if st.taps.start_at > 0 {
		beat_s := 60 / p.bpm
		lit = lit || math.mod(st.clock - (st.taps.start_at - beat_s), beat_s) < 0.12
	}
	glow := f32(clamp(1 - since / 0.35, 0, 1))
	if lit || glow > 0 {
		c := ui.mix(t.raised, t.accent, glow if !lit else 1)
		im.PushStyleColorVec4(.Button, transmute(im.Vec4)c)
		im.PushStyleColorVec4(.ButtonHovered, transmute(im.Vec4)ui.lighten(c, 0.08))
		im.PushStyleColorVec4(.Text, transmute(im.Vec4)(t.bg if lit else t.text))
	}
	pressed := im.Button("Tap")
	if lit || glow > 0 do im.PopStyleColor(3)
	if pressed {
		st.tapped = max(st.clock, 1e-6)
		if b := pm.tap(&st.taps, st.clock); b > 0 {
			pm.set_bpm(m, f64(int(b * 10 + 0.5)) / 10)
			app.seal(&m.history)
		}
		if playing do st.taps.start_at = 0 // playing: only the tempo
	}
	if im.IsItemHovered() do im.SetTooltip("Tap tempo: tap in time; the fourth tap starts playback a beat later (a pause of 2 s starts again)")
	im.SameLine(0, 8)
	ts := tr.time_sig
	im.SetNextItemWidth(64)
	if ui.combo("##timesig", fmt.ctprintf("%d/%d", ts.num, ts.den)) {
		common := [?]pm.Time_Sig{{4, 4}, {3, 4}, {2, 4}, {5, 4}, {6, 8}, {7, 8}, {12, 8}}
		for c in common do if im.Selectable(fmt.ctprintf("%d/%d", c.num, c.den), c == ts) {
			n := tr
			n.time_sig = c
			pm.set_transport(m, .Time_Sig, "Time Signature", n)
			app.seal(&m.history)
		}
		im.Separator()
		num := i32(ts.num)
		im.SetNextItemWidth(120)
		if im.SliderInt("##num", &num, 1, 16, "%d beats") {
			n := tr
			n.time_sig.num = int(num)
			pm.set_transport(m, .Time_Sig, "Time Signature", n)
		}
		if im.IsItemDeactivatedAfterEdit() do app.seal(&m.history)
		dens := [4]int{2, 4, 8, 16}
		den := 0
		for d, k in dens do if d == ts.den do den = k
		if ui.segmented("den", {"/2", "/4", "/8", "/16"}, &den) {
			n := tr
			n.time_sig.den = dens[den]
			pm.set_transport(m, .Time_Sig, "Time Signature", n)
			app.seal(&m.history)
		}
		im.EndCombo()
	}
	if im.IsItemHovered() do im.SetTooltip("Time signature")

	// The metronome: on/off, and its settings.
	im.SameLine(0, gap)
	if ui.icon_button(ui.ICON_METRONOME, "Metronome" if !tr.metro_rec_only else "Metronome (only while recording)", on = e.metronome, size = big) do e.metronome = !e.metronome
	im.SameLine(0, 0)
	if ui.icon_button(ui.ICON_CHEVRON_DOWN, "Metronome settings") do im.OpenPopup("##metro")
	if im.BeginPopup("##metro") {
		im.TextDisabled("Metronome")
		lvl := tr.metro_db
		im.SetNextItemWidth(180)
		if im.SliderFloat("##metro_db", &lvl, -48, 6, "Level %.0f dB") {
			n := tr
			n.metro_db = lvl
			pm.set_transport(m, .Metro_Level, "Metronome Level", n)
		}
		if im.IsItemDeactivatedAfterEdit() do app.seal(&m.history)
		ro := tr.metro_rec_only
		if ui.toggle("Only while recording", &ro) {
			n := tr
			n.metro_rec_only = ro
			pm.set_transport(m, .Metro_Rec_Only, "Metronome Mode", n)
			app.seal(&m.history)
		}
		im.Spacing()
		im.TextDisabled("Count-in before recording")
		ci := tr.count_in
		if ui.segmented("count_in", {"Off", "1 bar", "2 bars"}, &ci) {
			n := tr
			n.count_in = ci
			pm.set_transport(m, .Count_In, "Count-in", n)
			app.seal(&m.history)
		}
		im.EndPopup()
	}

	// Input quantize: on/off, and its grid, strength and swing.
	im.SameLine(0, gap)
	q := tr.quantize
	if ui.icon_button(ui.ICON_MAGNET, "Input quantize: on (recorded notes move toward the grid)" if q.on else "Input quantize: off", on = q.on, size = big) {
		n := tr
		n.quantize.on = !q.on
		pm.set_transport(m, .Quantize, "Input Quantize", n)
		app.seal(&m.history)
	}
	im.SameLine(0, 0)
	im.AlignTextToFramePadding()
	im.TextColored(transmute(im.Vec4)(t.text if q.on else t.text_dim), "%s", pm.GRID_NAMES[q.grid])
	im.SameLine(0, 0)
	if ui.icon_button(ui.ICON_CHEVRON_DOWN, "Input quantize settings") do im.OpenPopup("##quant")
	if im.BeginPopup("##quant") {
		im.TextDisabled("Input quantize")
		im.SetNextItemWidth(180)
		if ui.combo("##qgrid", pm.GRID_NAMES[q.grid]) {
			for g in pm.Grid do if im.Selectable(pm.GRID_NAMES[g], g == q.grid) {
				n := tr
				n.quantize.grid = g
				pm.set_transport(m, .Quantize, "Quantize Grid", n)
				app.seal(&m.history)
			}
			im.EndCombo()
		}
		str := q.strength * 100
		im.SetNextItemWidth(180)
		if im.SliderFloat("##strength", &str, 0, 100, "Strength %.0f%%") {
			n := tr
			n.quantize.strength = str / 100
			pm.set_transport(m, .Quantize_Strength, "Quantize Strength", n)
		}
		if im.IsItemDeactivatedAfterEdit() do app.seal(&m.history)
		sw := q.swing * 100
		im.SetNextItemWidth(180)
		if im.SliderFloat("##qswing", &sw, 0, 100, "Swing %.0f%%") {
			n := tr
			n.quantize.swing = sw / 100
			pm.set_transport(m, .Quantize_Swing, "Quantize Swing", n)
		}
		if im.IsItemDeactivatedAfterEdit() do app.seal(&m.history)
		im.EndPopup()
	}

	// How the pads play (also in the Perform panel).
	im.SameLine(0, gap)
	modes := [3]struct { mode: pm.Play_Mode, icon: string, tip: cstring }{
		{.Pads, ui.ICON_LAYOUT_GRID, "Play the pads as pads (each its sound)"},
		{.Keyboard, ui.ICON_KEYBOARD_MUSIC, "Play the pads as a keyboard of the selected pad"},
		{.Velocity, ui.ICON_SIGNAL_HIGH, "Play the pads as the selected pad at 16 velocities"},
	}
	for md, k in modes {
		if k > 0 do im.SameLine(0, 0)
		if ui.icon_button(md.icon, md.tip, on = a.play_mode == md.mode, size = big) do set_play_mode(a, md.mode)
	}

	st.width = im.GetItemRectMax().x - x0
	// A line under the bar.
	vp := im.GetWindowPos()
	sz := im.GetWindowSize()
	im.DrawList_AddLine(im.GetWindowDrawList(), {vp.x, vp.y + sz.y - 1}, {vp.x + sz.x, vp.y + sz.y - 1}, ui.col(t.border), 1)
}
