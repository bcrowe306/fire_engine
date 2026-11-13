package pads

import "core:fmt"
import "core:math"

import app "app:core"
import "app:ui"
import pm "model"
import "fire:dsp"
import im "deps:imgui"

// The transport toolbar's state: the tap tempo, and how wide its controls
// were last frame (to centre them).
Transport_State :: struct {
	taps:  pm.Tap_Tempo,
	clock: f64, // seconds of frames (what taps are timed by: frames, so a script's are steady)
	tapped: f64, // when Tap was last pressed (for its flash)
	stopped_at: f64, // when Stop was last pressed (a second press soon after silences everything)
	silences: int,   // times Stop silenced everything (for tests)
	left, center, right: ui.Flex, // the toolbar's rows: what plays and where, the transport (centred on the window), tempo and click
}

// Height of the transport toolbar.
TOOLBAR_H :: 46

// Below this window width the toolbar's toggles show only their icons.
TOOLBAR_COMPACT_W :: 1280

// This frame's toolbar is narrow (see TOOLBAR_COMPACT_W).
@(private = "file") tool_compact: bool

// Height of the toolbar's controls (a little under the panels' own, so
// the bar stays slim; at the Touch size, still big enough for a finger).
TOOL_H :: 30
TOOL_H_TOUCH :: 40

// The transport toolbar, under the menus whatever shows below: what is
// needed while playing. Play and stop; record, loop and count-in; where
// the playhead is; the sequence; pattern or song; the tempo, tap tempo
// and time signature; the metronome. Centred. (Input quantize is in the
// Sequence view, how the pads play in the bottom area's header, when a
// sequence takes over in Perform.)
draw_toolbar :: proc(user: rawptr) {
	a := (^App)(user)
	m := &a.m
	e := &m.engine
	p := &m.project
	tr := p.transport
	t := ui.theme()
	st := &a.transport
	st.clock += f64(im.GetIO().DeltaTime)

	// Every control the same height, flat (a shade off the bar rather than
	// raised from it), in a row of groups centred both ways.
	tool_h: f32 = TOOL_H_TOUCH if a.platform.density == .Touch else TOOL_H
	im.PushStyleVarVec2(.FramePadding, {t.pad.x, (tool_h - ui.FONT_SIZE) / 2})
	flat := ui.mix(t.surface, t.raised, 0.4)
	im.PushStyleColorVec4(.FrameBg, transmute(im.Vec4)flat)
	im.PushStyleColorVec4(.Button, transmute(im.Vec4)flat)
	im.PushStyleColorVec4(.FrameBgHovered, transmute(im.Vec4)t.raised)
	im.PushStyleColorVec4(.ButtonHovered, transmute(im.Vec4)t.raised)
	big := im.GetFrameHeight()
	win := im.GetWindowPos()
	// A narrow window: the toggles show their icons alone (their tooltips
	// say what they are), the groups closer.
	tool_compact = im.GetWindowSize().x < TOOLBAR_COMPACT_W
	group_gap: f32 = 8 if tool_compact else 16
	st.left.justify, st.left.gap = .Start, group_gap
	st.center.justify, st.center.gap = .Start, 2
	st.right.justify, st.right.gap = .Start, group_gap
	// Three rows: the transport (play, stop, record, loop) centred on the
	// window, what plays and where to its left (packed against it), and
	// the tempo, count-in and click to its right.
	beat, playing := pm.timeline_beat(e)
	pad_x := im.GetStyle().WindowPadding.x
	x0, width := win.x + pad_x, im.GetWindowSize().x - 2 * pad_x
	side_gap: f32 = 14 if tool_compact else 28
	// One row from the left: the tempo and click, what plays and where,
	// then the transport (centred on the window when there is room).
	cw := ui.flex_width(&st.center)
	tw := ui.flex_width(&st.right)
	lw := ui.flex_width(&st.left)
	lx := x0 + tw + side_gap
	cx := max(x0 + (width - cw) / 2, lx + lw + side_gap)

	im.SetCursorScreenPos({lx, win.y})
	ui.flex_begin(&st.left, {max(cx - side_gap - lx, 1), TOOLBAR_H})
	ui.flex_next(&st.left)
	// The sequence.
	if ui.icon_button(ui.ICON_CHEVRON_LEFT, "Previous sequence", disabled = p.slot == 0) do pm.select_slot(m, p.slot - 1)
	im.SameLine(0, 0)
	im.SetNextItemWidth(118)
	bar_dl, combo_at := im.GetWindowDrawList(), im.GetCursorScreenPos()
	open := ui.combo("##slot", fmt.ctprintf("   %s", pm.sequence_name(p, p.slot)))
	im.DrawList_AddCircleFilled(bar_dl, {combo_at.x + 12, combo_at.y + im.GetFrameHeight() / 2}, 5, ui.col(ui.rgb(pm.sequence_color(p, p.slot))))
	if open {
		for k in 0 ..< pm.SLOTS {
			label := fmt.ctprintf("     %s###s%d", pm.sequence_name(p, k), k)
			if im.Selectable(label, k == p.slot) do pm.select_slot(m, k)
			{ // its colour: a filled dot when it has notes, a ring when empty
				mn, mx := im.GetItemRectMin(), im.GetItemRectMax()
				cc := ui.rgb(pm.sequence_color(p, k))
				ctr := im.Vec2{mn.x + 9, (mn.y + mx.y) / 2}
				if pm.slot_used(m, k) do im.DrawList_AddCircleFilled(im.GetWindowDrawList(), ctr, 5, ui.col(cc))
				else do im.DrawList_AddCircle(im.GetWindowDrawList(), ctr, 5, ui.col(ui.with_alpha(cc, 0.5)), 0, 1.5)
			}
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
	ui.flex_next(&st.left)
	// What plays (the sequence, or the song), and when a sequence picked
	// while playing takes over.
	mode := 1 if p.song_mode else 0
	if ui.segmented("play_mode", {"Pattern", "Song"}, &mode) {
		p.song_mode = mode == 1
		e.seq_dirty = true
	}
	if im.IsItemHovered() do im.SetTooltip("Play the sequence shown (Pattern) or the song's steps one after another (Song)")
	// (When a sequence picked while playing takes over is in Perform.)
	ui.flex_next(&st.left)
	// Where the playhead is.
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
	ui.flex_end(&st.left)

	im.SetCursorScreenPos({cx, win.y})
	ui.flex_begin(&st.center, {width, TOOLBAR_H})
	ui.flex_next(&st.center)
	// Transport.
	if ui.icon_button(ui.ICON_PLAY, "Play (Space)", on = playing, color = t.ok, size = big) {
		if !playing do pm.play(e)
	}
	im.SameLine(0, 2)
	if ui.icon_button(ui.ICON_SQUARE, "Stop (Space); press twice to silence every sound", size = big) {
		// Pressed again soon after (or while stopped): every voice stops too.
		if !playing || st.clock - st.stopped_at < 0.6 {
			pm.silence_all(e)
			st.silences += 1
		}
		pm.stop(e)
		pm.capture_arm(m, &a.capture, false)
		st.stopped_at = st.clock
	}
	im.SameLine(0, 2)
	// Record: red whatever the accent, and blinking while it records.
	if tool_toggle(ui.ICON_CIRCLE_DOT, "Rec", "Record (Cmd+R)", a.capture.armed, t.danger, big, blink = a.capture.armed && playing, time = st.clock) do toggle_record(a)
	im.SameLine(0, 2)
	if tool_toggle(ui.ICON_REPEAT, "Loop", "Loop: on (it goes round)" if tr.loop else "Loop: off (it plays once and stops)", tr.loop, t.accent, big) {
		n := tr
		n.loop = !n.loop
		pm.set_transport(m, .Loop, "Loop", n)
		app.seal(&m.history)
	}
	im.SameLine(0, 2)
	// Recording knob moves: only when this is on (off by default).
	if tool_toggle(ui.ICON_SPLINE, "Auto", "Record automation: on (knobs and faders moved while recording are written into the sequence)" if a.auto_rec.armed else "Record automation: off (knobs only change the sound)", a.auto_rec.armed, t.danger, big) {
		a.auto_rec.armed = !a.auto_rec.armed
		if !a.auto_rec.armed do record_release(a)
	}
	im.SameLine(0, 2)
	draw_sample_control(a, big)
	im.SameLine(0, 2)
	draw_play_mode(a)
	im.SameLine(0, 2)
	draw_repeat_control(a, big)

	ui.flex_end(&st.center)

	// The tempo and click, at the far left.
	im.SetCursorScreenPos({x0, win.y})
	ui.flex_begin(&st.right, {max(tw, 1) if tw > 0 else max(lx - x0, 1), TOOLBAR_H})
	ui.flex_next(&st.right)
	// Tempo: drag by 1 (Shift: 0.1), tap, and the time signature.
	bpm := p.bpm
	te := ui.number_drag("tempo", &bpm, 40, 300, 1, 0.1, "%.1f BPM", 104, fill = false)
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
	ui.flex_next(&st.right)
	ci_tip := fmt.ctprintf("Count-in: %s (click to change)", "off" if tr.count_in == 0 else fmt.tprintf("%d bar%s", tr.count_in, "" if tr.count_in == 1 else "s"))
	if tool_toggle(ui.ICON_TIMER if tr.count_in > 0 else ui.ICON_TIMER_OFF, fmt.tprintf("Count-in %d", tr.count_in) if tr.count_in > 0 else "Count-in", ci_tip, tr.count_in > 0, t.accent, big) {
		n := tr
		n.count_in = (n.count_in + 1) % 3
		pm.set_transport(m, .Count_In, "Count-in", n)
		app.seal(&m.history)
	}
	ui.flex_next(&st.right)
	// The metronome: on/off, and its settings.
	if tool_toggle(ui.ICON_METRONOME, "Click", "Metronome" if !tr.metro_rec_only else "Metronome (only while recording)", e.metronome, t.accent, big) do e.metronome = !e.metronome
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
		snd := int(tr.click)
		if ui.segmented("metro_sound", {"Beep", "Wood", "Stick", "Cowbell"}, &snd) {
			n := tr
			n.click = dsp.Click_Sound(snd)
			pm.set_transport(m, .Metro_Sound, "Metronome Sound", n)
			app.seal(&m.history)
		}
		ui.name("metronome sound")
		acc := !tr.no_accent
		if ui.toggle("Accent the bar", &acc) {
			n := tr
			n.no_accent = !acc
			pm.set_transport(m, .Metro_Accent, "Metronome Accent", n)
			app.seal(&m.history)
		}
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
	ui.flex_end(&st.right)
	im.PopStyleColor(4)
	im.PopStyleVar()
	// A line under the bar.
	vp := im.GetWindowPos()
	sz := im.GetWindowSize()
	im.DrawList_AddLine(im.GetWindowDrawList(), {vp.x, vp.y + sz.y - 1}, {vp.x + sz.x, vp.y + sz.y - 1}, ui.col(t.border), 1)
}

// Input quantize (by the Sequence view's grid): on/off, its grid, and in
// its menu the grid, strength and swing.
draw_input_quantize :: proc(a: ^App) {
	m := &a.m
	tr := m.project.transport
	t := ui.theme()
	// Input quantize: on/off, and its grid, strength and swing.
	q := tr.quantize
	if ui.icon_button(ui.ICON_MAGNET, "Input quantize: on (recorded notes move toward the grid)" if q.on else "Input quantize: off", on = q.on) {
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

}

// How the pads play: as pads, as a keyboard of the selected pad, or as it
// at 16 velocities (also in the Perform panel).
draw_play_modes :: proc(a: ^App) {
	// How the pads play (also in the Perform panel).
	modes := [3]struct { mode: pm.Play_Mode, icon: string, tip: cstring }{
		{.Pads, ui.ICON_LAYOUT_GRID, "Play the pads as pads (each its sound)"},
		{.Keyboard, ui.ICON_KEYBOARD_MUSIC, "Play the pads as a keyboard of the selected pad"},
		{.Velocity, ui.ICON_SIGNAL_HIGH, "Play the pads as the selected pad at 16 velocities"},
	}
	for md, k in modes {
		if k > 0 do im.SameLine(0, 0)
		if ui.icon_button(md.icon, md.tip, on = a.play_mode == md.mode) do set_play_mode(a, md.mode)
	}

}

// The Sample control: recording a sample into a pad. On (armed), the next
// pad pressed records by its method (Arm, Threshold, Bars); lit and
// blinking while one records (pressing it then stops it). In Hold, Option-
// or Alt-press a pad instead. Its arrow: the method, Threshold's level,
// Bars' count.
@(private = "file")
draw_sample_control :: proc(a: ^App, h: f32) {
	t := ui.theme()
	s := &a.settings
	recording := a.rec.active
	tips := [pm.Sampling]cstring{
		.Hold      = "Sample: Option-press (Alt) a pad to record into it while held",
		.Arm       = "Sample: on, the next pad you press records while you hold it",
		.Threshold = "Sample: on, the next pad you press records while held, starting where the sound passes the level",
		.Bars      = "Sample: on, the next pad you press records the next bars in time",
	}
	tip := tips[s.sample_method]
	if recording do tip = "Sample: recording (click to stop)"
	io := im.GetIO()
	label := "Sample · latched" if a.sample_latched && !tool_compact else "Sample"
	if tool_toggle(ui.ICON_MIC, label, tip, a.sample_armed || recording, t.danger, h, blink = recording, time = a.transport.clock) {
		latch := io.KeyCtrl || io.KeySuper // (Ctrl- or Cmd-click)
		switch {
		case recording && !a.sample_latched:
			pm.record_stop(&a.rec)
			a.sample_holding = -1
		case s.sample_method == .Hold:
			ui.toast(&a.ws.toasts, .Info, "Option-press (Alt) a pad to record into it while you hold it")
		case latch:
			// Latched: on after each take, until a click turns it off.
			a.sample_latched = !a.sample_latched
			a.sample_armed = a.sample_latched
		case:
			if recording {
				pm.record_stop(&a.rec)
				a.sample_holding = -1
			}
			a.sample_armed = !a.sample_armed && !a.sample_latched
			a.sample_latched = false
		}
	}
	// Ctrl-click on a Mac is a right-click: that latches too.
	if im.IsItemClicked(.Right) && s.sample_method != .Hold && !recording {
		a.sample_latched = !a.sample_latched
		a.sample_armed = a.sample_latched
	}
	if im.IsItemHovered() && s.sample_method != .Hold do im.SetTooltip("%s", fmt.ctprintf("%s\n%s", tip, "Latched: it stays on after each take (click: off)" if a.sample_latched else "Ctrl-click (or right-click, Cmd-click): latch it on, to stay on after each take"))
	im.SameLine(0, 0)
	if ui.icon_button(ui.ICON_CHEVRON_DOWN, "Sample settings") do im.OpenPopup("##samplemenu")
	if im.BeginPopup("##samplemenu") {
		im.TextDisabled("Record a sample into a pad")
		method := int(s.sample_method)
		if ui.segmented("sample method", {"Hold", "Arm", "Threshold", "Bars"}, &method) {
			s.sample_method = pm.Sampling(method)
			a.sample_armed = false
			settings_save(a)
		}
		HINTS := [pm.Sampling]cstring{
			.Hold      = "Option-press (Alt) a pad: it records while you hold it.",
			.Arm       = "Turn Sample on; the next pad you press (or play from MIDI)\nrecords while you hold it.",
			.Threshold = "Turn Sample on; the next pad you press records while you hold it,\nthe sample starting where the sound first passes the level.",
			.Bars      = "Turn Sample on; the next pad you press records the next bars,\nfrom the next bar's start (playing starts if stopped).",
		}
		im.TextDisabled("%s", HINTS[s.sample_method])
		if s.sample_method != .Hold {
			if ui.toggle("Latch##samplelatch", &a.sample_latched) do a.sample_armed = a.sample_latched
			ui.name("sample latch")
			if im.IsItemHovered() do im.SetTooltip("On after each take, for the next pad (Ctrl- or Cmd-click the button)")
		}
		#partial switch s.sample_method {
		case .Threshold:
			db := f64(s.sample_threshold_db)
			e := ui.number_drag("sample threshold", &db, -80, 0, 1, 0.1, "Starts at %.0f dB", 200)
			if e.changed do s.sample_threshold_db = f32(db)
			if e.ended do settings_save(a)
		case .Bars:
			n := f64(s.sample_bars)
			e := ui.number_drag("sample bars", &n, 1, 16, 1, 1, "%.0f bars" if s.sample_bars != 1 else "%.0f bar", 200)
			if e.changed do s.sample_bars = int(n)
			if e.ended do settings_save(a)
		}
		im.EndPopup()
	}
}

// How the pads play (as the bottom area's header has it): each its own
// sound, the selected one as a keyboard, or at 16 velocities.
@(private = "file")
draw_play_mode :: proc(a: ^App) {
	NAMES := [pm.Play_Mode]cstring{.Pads = "Pads", .Keyboard = "Keyboard", .Velocity = "Vel"}
	im.SetNextItemWidth(96)
	if ui.combo("##toolplaymode", NAMES[a.play_mode]) {
		for mode in pm.Play_Mode do if im.Selectable(NAMES[mode], mode == a.play_mode) do set_play_mode(a, mode)
		im.EndCombo()
	}
	ui.name("toolbar play mode")
	if im.IsItemHovered() do im.SetTooltip("How the pads play: each its own sound (Pads), the selected pad as a keyboard, or the selected pad at 16 velocities (Vel)")
}

// Note Repeat, MPC-style: on, whatever pad you hold repeats at its rate
// and gate (a pad's own repeat works while it is off). Its arrow: the rate
// and the gate. While it is on, input quantize and Quantize use its rate.
@(private = "file")
draw_repeat_control :: proc(a: ^App, h: f32) {
	t := ui.theme()
	s := &a.settings
	e := &a.m.engine
	tip: cstring = "Note Repeat: on (held pads repeat at its rate; recorded on that grid)" if e.repeat_all else "Note Repeat: off (hold a pad to repeat it when on)"
	if tool_toggle(ui.ICON_REPEAT_1, "Repeat", tip, e.repeat_all, t.accent, h) do e.repeat_all = !e.repeat_all
	im.SameLine(0, 0)
	if ui.icon_button(ui.ICON_CHEVRON_DOWN, "Note repeat settings") do im.OpenPopup("##repeatmenu")
	if im.BeginPopup("##repeatmenu") {
		im.TextDisabled("Note repeat for every pad held")
		on := e.repeat_all
		if ui.toggle("On##repeaton", &on) do e.repeat_all = on
		ui.name("repeat on")
		im.SetNextItemWidth(90)
		if rate_combo("##repeatrate", &s.repeat_rate) do settings_save(a)
		ui.name("repeat rate")
		im.SameLine(0, 8)
		g := f64(s.repeat_gate * 100)
		ge := ui.number_drag("repeat gate", &g, 5, 100, 5, 1, "Gate %.0f%%", 120)
		if ge.changed do s.repeat_gate = f32(g / 100)
		if ge.ended do settings_save(a)
		im.TextDisabled("Recorded as played, on its grid; input quantize\nand Quantize use its rate while it is on.")
		im.EndPopup()
	}
	e.repeat_all_settings = {rate = s.repeat_rate, gate = s.repeat_gate}
}

// A toolbar button that turns something on and off, an icon and a label:
// lit in `color` (a tint and an outline) when on, pulsing with `blink`.
// Named for tests by `tip`, its tooltip.
@(private = "file")
tool_toggle :: proc(icon, label: string, tip: cstring, on: bool, color: ui.Color, h: f32, blink := false, time: f64 = 0) -> bool {
	t := ui.theme()
	ui.text_push(.Label)
	defer ui.text_pop()
	text := fmt.ctprintf("%s", icon) if tool_compact else fmt.ctprintf("%s  %s", icon, label)
	ts := im.CalcTextSize(text)
	w := ts.x + 2 * t.pad.x
	pos := im.GetCursorScreenPos()
	clicked := im.InvisibleButton(tip, {w, h})
	ui.name(string(tip))
	hovered := im.IsItemHovered()
	bg := t.pressed if im.IsItemActive() else (t.raised if hovered else ui.mix(t.surface, t.raised, 0.4))
	if on {
		f: f32 = 0.3
		if blink do f = 0.15 + 0.4 * f32(0.5 + 0.5 * math.sin(time * 6))
		bg = ui.mix(bg, color, f)
	}
	dl := im.GetWindowDrawList()
	im.DrawList_AddRectFilled(dl, pos, {pos.x + w, pos.y + h}, ui.col(bg), t.radius)
	if on do im.DrawList_AddRect(dl, pos, {pos.x + w, pos.y + h}, ui.col(color), t.radius, 1)
	im.DrawList_AddText(dl, {pos.x + t.pad.x, pos.y + (h - ts.y) / 2}, ui.col(t.text if on else t.text_dim), text)
	if hovered do im.SetTooltip("%s", tip)
	return clicked
}

// The launch settings, in the toolbar's order, and their short names.
@(private)
LAUNCH_ORDER := [4]pm.Switch_At{.Now, .Beat, .Bar, .End}
@(private)
LAUNCH_NAMES := [pm.Switch_At]cstring{.Now = "At once", .Beat = "Next beat", .Bar = "Next bar", .End = "Sequence end"}
