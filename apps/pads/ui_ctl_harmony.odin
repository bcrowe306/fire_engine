// The note modes on a controller's display (Push 2's Note: View_Kind
// .Harmony), the window's state (one key, one play mode, one progression):
//
// - the upper row: the play modes (Scale, Chords, Progressions; the one
//   playing lit), and in Scale the grid's layouts (Fourths, Thirds,
//   Sequential, Chromatic);
// - the picture: the key and what plays it (the layout, or the voicing),
//   the chord playing (its name large, its numeral) with its notes on a
//   keyboard over the key's own, and in Progressions the progression's
//   chords along the top, the one playing lit;
// - the knobs: Root, Scale, Octave, then Layout (Scale); voice leading,
//   spread and strum (Chords); the bank's style and progression, then
//   the voicing (Progressions).
package pads

import "core:fmt"
import "core:strings"
import "core:time"

import "app:ui"
import pa "api"
import pm "model"
import im "deps:imgui"

// The play modes on the upper row, in order.
@(private = "file")
HARMONY_MODES := [3]pa.Play_Mode{.Scale, .Chords, .Progressions}

// Long scale names, shorter in a knob's box (beside its label; "": the
// name itself).
@(private = "file")
HARMONY_SCALE_SHORT := [pa.Scale]string{
	.Harmonic_Minor = "Harm min", .Major_Pentatonic = "Maj pent", .Minor_Pentatonic = "Min pent", .Melodic_Minor = "Mel min",
	.Phrygian_Dominant = "Phryg dom", .Hungarian_Minor = "Hung min", .Whole_Tone = "Whole", .Diminished_Half_Whole = "Dim H-W",
	.Diminished_Whole_Half = "Dim W-H", .In_Sen = "In-sen", .Mixolydian = "Mixolyd.",
	.Chromatic = "", .Major = "", .Minor = "", .Dorian = "", .Blues = "", .Phrygian = "", .Lydian = "", .Locrian = "", .Hirajoshi = "",
}

// The view: its parts, then the knobs. Its drawing time is kept for the
// probe (`Ctl_State.harmony_draw_us`).
@(private)
ctl_harmony :: proc(ctx: ^View_Ctx, full: im.Vec2) {
	start := time.tick_now()
	a := ctx.a
	ps, _ := pa.perform_state(&a.api)
	ks, _ := pa.key_state(&a.api)
	mode := ps.play_mode
	if mode != .Chords && mode != .Progressions do mode = .Scale // (Pads, Velocity: as Scale)
	// The upper row: the modes, and Scale's layouts.
	for m, k in HARMONY_MODES {
		ctl_upper(ctx, k, string(pm.PLAY_MODE_NAMES[pm.Play_Mode(m)]), mode == m)
		if harmony_pressed(ctx, k) && ps.play_mode != m do pa.perform_set_play_mode(&a.api, m)
	}
	if mode == .Scale do for l, k in pa.Grid_Layout {
		name, _ := pa.key_layout_name(&a.api, l)
		ctl_upper(ctx, 4 + k, name, ks.layout == l)
		if harmony_pressed(ctx, 4 + k) && ks.layout != l do pa.key_set_layout(&a.api, l)
	}
	// The picture over the knobs (no buttons under them: the room is the picture's).
	plot := im.Vec2{full.x, full.y - CTL_PLOT_Y - CTL_KNOBS_H - 4}
	top := f32(CTL_PLOT_Y)
	if mode == .Progressions do top = harmony_progression(ctx, full, top) + 6
	harmony_key(ctx, ks, mode, top, f32(CTL_PLOT_Y) + plot.y)
	harmony_chord(ctx, ks, mode, top, f32(CTL_PLOT_Y) + plot.y)
	harmony_knobs(ctx, ks, mode, plot)
	ui.knob_input.drawn = 8
	im.SetCursorPos({0, 0})
	im.Dummy({1, 1})
	us := f64(time.tick_since(start)) / 1e3
	a.ctl.harmony_draw_us = us
	a.ctl.harmony_draw_max_us = max(a.ctl.harmony_draw_max_us, us)
}

// Whether the controller pressed upper button `k`.
@(private = "file")
harmony_pressed :: proc(ctx: ^View_Ctx, k: int) -> bool {
	return ctx.input != nil && ctx.input.pressed[int(pa.View_Button.Upper_1) + k]
}

// The knobs: the key's, then the mode's.
@(private = "file")
harmony_knobs :: proc(ctx: ^View_Ctx, ks: pa.Key_Info, mode: pa.Play_Mode, plot: im.Vec2) {
	a := ctx.a
	api := &a.api
	// Root (wrapping), Scale (the Key dialog's order), Octave.
	if n, _ := ctl_value_box(ctx, 0, "Root", pm.note_in_key(pm.Keys{root = int(ks.root), scale = pm.Scale(ks.scale)}, int(ks.root)), CTL_STEP, plot); n != 0 {
		pa.key_set(api, i64(((int(ks.root) + n) % 12 + 12) % 12), ks.scale)
	}
	at := 0
	for x, k in pm.SCALE_ORDER do if int(x) == int(ks.scale) do at = k
	sn := HARMONY_SCALE_SHORT[ks.scale]
	if sn == "" do sn, _ = pa.key_scale_name(api, ks.scale)
	if n, _ := ctl_value_box(ctx, 1, "Scale", sn, CTL_STEP, plot); n != 0 {
		pa.key_set(api, ks.root, pa.Scale(pm.SCALE_ORDER[clamp(at + n, 0, len(pm.SCALE_ORDER) - 1)]))
	}
	if n, _ := ctl_value_box(ctx, 2, "Octave", fmt.tprintf("%+d", ks.octave), CTL_STEP, plot); n != 0 do pa.key_set_octave(api, clamp(ks.octave + i64(n), -3, 3))
	voicing := 3
	switch mode {
	case .Scale:
		name, _ := pa.key_layout_name(api, ks.layout)
		if n, _ := ctl_value_box(ctx, 3, "Layout", name, CTL_STEP, plot); n != 0 do pa.key_set_layout(api, pa.Grid_Layout(clamp(int(ks.layout) + n, 0, len(pa.Grid_Layout) - 1)))
		return
	case .Progressions:
		harmony_bank_knobs(ctx, plot)
		voicing = 5
	case .Pads, .Velocity, .Chords:
	}
	// The voicing: voice leading, spread, strum (a millisecond a detent).
	if n, _ := ctl_value_box(ctx, voicing, "Voice lead", "On" if ks.voice_leading else "Off", CTL_STEP, plot); n != 0 do pa.key_set_voicing(api, n > 0, ks.spread, ks.strum_ms)
	if n, _ := ctl_value_box(ctx, voicing + 1, "Spread", string(pm.SPREAD_NAMES[pm.Spread(ks.spread)]), CTL_STEP, plot); n != 0 {
		pa.key_set_voicing(api, ks.voice_leading, pa.Spread(clamp(int(ks.spread) + n, 0, len(pa.Spread) - 1)), ks.strum_ms)
	}
	if n, _ := ctl_value_box(ctx, voicing + 2, "Strum", fmt.tprintf("%.0f ms", ks.strum_ms), CTL_DETENT, plot); n != 0 {
		pa.key_set_voicing(api, ks.voice_leading, ks.spread, clamp(ks.strum_ms + f64(n), 0, pm.MAX_STRUM_MS))
	}
}

// Progressions' knobs 4 and 5: the bank by style (a turn: the next
// style's first), and its progressions in order (across styles).
@(private = "file")
harmony_bank_knobs :: proc(ctx: ^View_Ctx, plot: im.Vec2) {
	api := &ctx.a.api
	n, _ := pa.progression_bank_count(api)
	name, _ := pa.progression_name(api)
	cur := -1 // (the bank's one in use, by name: none if it is yours, or edited)
	for i in 0 ..< int(n) do if bn, _ := pa.progression_bank_name(api, i64(i)); bn == name {
		cur = i
		break
	}
	style := "Yours"
	if cur >= 0 do style, _ = pa.progression_bank_style(api, i64(cur))
	if d, _ := ctl_value_box(ctx, 3, "Style", style, CTL_STEP, plot); d != 0 && n > 0 {
		styles := make([dynamic]string, context.temp_allocator)
		firsts := make([dynamic]int, context.temp_allocator)
		for i in 0 ..< int(n) {
			s, _ := pa.progression_bank_style(api, i64(i))
			if len(styles) == 0 || styles[len(styles) - 1] != s {
				append(&styles, strings.clone(s, context.temp_allocator))
				append(&firsts, i)
			}
		}
		at := -1
		for s, k in styles do if s == style do at = k
		to := clamp(at + d, 0, len(styles) - 1) if at >= 0 else (0 if d > 0 else len(styles) - 1)
		pa.progression_use_bank(api, i64(firsts[to]))
	}
	if d, _ := ctl_value_box(ctx, 4, "Name", name if name != "" else "—", CTL_STEP, plot); d != 0 && n > 0 {
		to := clamp(cur + d, 0, int(n) - 1) if cur >= 0 else 0
		pa.progression_use_bank(api, i64(to))
	}
}

// The key, and what plays it, at the picture's left (`y0` to `y1`).
@(private = "file")
harmony_key :: proc(ctx: ^View_Ctx, ks: pa.Key_Info, mode: pa.Play_Mode, y0, y1: f32) {
	a := ctx.a
	t := ui.theme()
	dl := im.GetWindowDrawList()
	o := im.GetWindowPos()
	x0 := o.x + 10
	y := o.y + y0 + 2
	name, _ := pa.key_name(&a.api)
	im.PushFontFloat(nil, 22)
	im.DrawList_AddText(dl, {x0, y}, ui.col(t.text), fmt.ctprintf("%s", name))
	y += im.GetTextLineHeight() + 2
	im.PopFont()
	ui.text_push(.Label)
	defer ui.text_pop()
	line: string
	switch mode {
	case .Scale:
		ln, _ := pa.key_layout_name(&a.api, ks.layout)
		line = fmt.tprintf("Scale · %s", ln)
	case .Chords:
		line = "Chords · degrees across, variations up"
	case .Progressions:
		pn, _ := pa.progression_name(&a.api)
		line = fmt.tprintf("Progression · %s", pn if pn != "" else "untitled")
	case .Pads, .Velocity:
	}
	clip := o.x + 2 * CTL_COL - 6
	im.DrawList_PushClipRect(dl, {x0, o.y + y0}, {clip, o.y + y1}, true)
	defer im.DrawList_PopClipRect(dl)
	im.DrawList_AddText(dl, {x0, y}, ui.col(t.text_dim), fmt.ctprintf("%s", line))
	y += im.GetTextLineHeight() + 2
	if mode == .Scale {
		line = fmt.tprintf("Octave %+d", ks.octave)
	} else {
		sp := "close" if ks.spread == .Close else ("open" if ks.spread == .Open else "wide")
		line = fmt.tprintf("%s · %s · strum %.0f ms", "Voice-led" if ks.voice_leading else "Root position", sp, ks.strum_ms)
	}
	if y + im.GetTextLineHeight() <= o.y + y1 do im.DrawList_AddText(dl, {x0, y}, ui.col(t.text_dim), fmt.ctprintf("%s", line))
}

// The chord playing (its symbol large, its numeral; Scale: the key's
// notes) and the keyboard, its notes on it over the key's.
@(private = "file")
harmony_chord :: proc(ctx: ^View_Ctx, ks: pa.Key_Info, mode: pa.Play_Mode, y0, y1: f32) {
	a := ctx.a
	t := ui.theme()
	dl := im.GetWindowDrawList()
	o := im.GetWindowPos()
	x0 := o.x + 2 * CTL_COL + 6
	x1 := o.x + 4.6 * CTL_COL
	cp, _ := pa.perform_chord_playing(&a.api)
	a.ctl.harmony_shown_n = 0
	notes: [8]i64
	n := 0
	if mode != .Scale && cp.ok {
		for i in 0 ..< min(int(cp.count), len(notes)) {
			notes[i], _ = pa.perform_chord_playing_note(&a.api, i64(i))
			n += 1
		}
	}
	im.DrawList_PushClipRect(dl, {x0, o.y + y0}, {x1, o.y + y1}, true)
	if mode == .Scale {
		// The key's notes, in its spelling.
		b := strings.builder_make(context.temp_allocator)
		k := pm.Keys{root = int(ks.root), scale = pm.Scale(ks.scale)}
		for s, i in pm.scale_steps(k.scale) {
			if i > 0 do strings.write_string(&b, "  ")
			strings.write_string(&b, pm.note_in_key(k, k.root + s))
		}
		ui.text_push(.Label)
		im.DrawList_AddText(dl, {x0, o.y + y0 + 4}, ui.col(t.text_dim), "The key's notes")
		ui.text_pop()
		im.PushFontFloat(nil, 18)
		im.DrawList_AddText(dl, {x0, o.y + y0 + 22}, ui.col(t.text), fmt.ctprintf("%s", strings.to_string(b)))
		im.PopFont()
	} else if cp.ok {
		name, _ := pa.perform_chord_playing_name(&a.api)
		a.ctl.harmony_shown_n = copy(a.ctl.harmony_shown[:], name)
		numeral, symbol := name, ""
		if sp := strings.index_byte(name, ' '); sp > 0 do numeral, symbol = name[:sp], name[sp + 1:]
		big := min(f32(30), (y1 - y0) * 0.45)
		im.PushFontFloat(nil, big)
		sc := fmt.ctprintf("%s", symbol)
		ss := im.CalcTextSize(sc)
		if ss.x > x1 - x0 - 8 { // (a long symbol: smaller)
			im.PopFont()
			im.PushFontFloat(nil, max(big * (x1 - x0 - 8) / ss.x, 13))
			ss = im.CalcTextSize(sc)
		}
		im.DrawList_AddText(dl, {x0, o.y + y0 + 2}, ui.col(t.accent if cp.held else t.text), sc)
		im.PopFont()
		ui.text_push(.Label)
		im.DrawList_AddText(dl, {x0, o.y + y0 + 4 + ss.y}, ui.col(t.text_dim), fmt.ctprintf("%s%s", numeral, "" if cp.held else " · last played"))
		ui.text_pop()
	} else {
		ui.text_push(.Label)
		im.DrawList_AddText(dl, {x0, o.y + y0 + 4}, ui.col(t.text_dim), "Play a pad: its chord shows here")
		ui.text_pop()
	}
	im.DrawList_PopClipRect(dl)
	harmony_keyboard(a, ks, notes[:n], {o.x + 4.7 * CTL_COL, o.y + y0 + 2}, {o.x + 8 * CTL_COL - 8, o.y + y1 - 2})
}

// Three octaves of a keyboard in `lo`..`hi`: the key's notes marked (its
// root brighter), `notes` (semitones from a pad's own note, a C) filled in
// the accent; from the C at or under the lowest of them (none: the pad's
// own octave).
@(private = "file")
harmony_keyboard :: proc(a: ^App, ks: pa.Key_Info, notes: []i64, lo, hi: im.Vec2) {
	t := ui.theme()
	dl := im.GetWindowDrawList()
	low: i64 = 0
	if len(notes) > 0 {
		low = notes[0]
		for p in notes do low = min(low, p)
	}
	c0 := (low if low >= 0 else low - 11) / 12 * 12
	OCTAVES :: 3
	whites := 7 * OCTAVES
	w := (hi.x - lo.x) / f32(whites)
	sounding :: proc(notes: []i64, p: i64) -> bool {
		for x in notes do if x == p do return true
		return false
	}
	k := pm.Keys{root = int(ks.root), scale = pm.Scale(ks.scale)}
	WHITE_SEMIS := [7]i64{0, 2, 4, 5, 7, 9, 11}
	// A key's note: a dot (its root bigger, in the accent).
	mark :: proc(dl: ^im.DrawList, k: pm.Keys, p: i64, cx, y: f32, accent, dot: ui.Color) {
		if !pm.in_key(k, int(p)) do return
		root := ((int(p) - k.root) % 12 + 12) % 12 == 0
		im.DrawList_AddCircleFilled(dl, {cx, y}, 3 if root else 2, ui.col(accent if root else dot))
	}
	for i in 0 ..< whites {
		p := c0 + i64(i / 7) * 12 + WHITE_SEMIS[i % 7]
		x := lo.x + f32(i) * w
		on := sounding(notes, p)
		im.DrawList_AddRectFilled(dl, {x + 0.5, lo.y}, {x + w - 0.5, hi.y}, ui.col(t.accent if on else ui.mix(t.text, VIEW_BG, 0.25)), 2)
		if !on do mark(dl, k, p, x + w / 2, hi.y - 6, t.accent, ui.mix(t.text_dim, VIEW_BG, 0.3))
		if i % 7 == 0 {
			ui.text_push(.Caption)
			im.DrawList_AddText(dl, {x + 2, hi.y - 30}, ui.col(VIEW_BG), fmt.ctprintf("C%d", int(c0 + i64(i / 7) * 12) / 12 + 3))
			ui.text_pop()
		}
	}
	BLACK_AFTER := [5]int{0, 1, 3, 4, 5} // (the white keys a black key follows)
	BLACK_SEMIS := [5]i64{1, 3, 6, 8, 10}
	for o in 0 ..< OCTAVES do for b, j in BLACK_AFTER {
		p := c0 + i64(o) * 12 + BLACK_SEMIS[j]
		x := lo.x + f32(o * 7 + b + 1) * w - w * 0.32
		bh := (hi.y - lo.y) * 0.6
		on := sounding(notes, p)
		im.DrawList_AddRectFilled(dl, {x, lo.y}, {x + w * 0.64, lo.y + bh}, ui.col(t.accent if on else ui.mix(VIEW_BG, t.surface, 0.5)), 2)
		if !on do mark(dl, k, p, x + w * 0.32, lo.y + bh - 6, t.accent, t.text_dim)
	}
	_ = a
}

// Progressions: the progression's chords along the picture's top from
// `y0`, the one playing filled (the last played outlined). Where it ends.
@(private = "file")
harmony_progression :: proc(ctx: ^View_Ctx, full: im.Vec2, y0: f32) -> f32 {
	a := ctx.a
	t := ui.theme()
	dl := im.GetWindowDrawList()
	o := im.GetWindowPos()
	st, _ := pa.progression_state(&a.api)
	cp, _ := pa.perform_chord_playing(&a.api)
	h: f32 = 22
	if st.count == 0 {
		ui.text_push(.Label)
		im.DrawList_AddText(dl, {o.x + 10, o.y + y0 + 4}, ui.col(t.text_dim), "No progression: choose one (Style, Name)")
		ui.text_pop()
		return y0 + h
	}
	w := min((full.x - 16) / f32(st.count), f32(CTL_COL) - 4)
	ui.text_push(.Label)
	defer ui.text_pop()
	for i in 0 ..< int(st.count) {
		x := o.x + 8 + f32(i) * w
		lo, hi := im.Vec2{x + 1, o.y + y0}, im.Vec2{x + w - 2, o.y + y0 + h}
		playing := cp.ok && cp.index == i64(i)
		fill := t.accent if playing && cp.held else ui.mix(VIEW_BG, t.surface, 0.7)
		im.DrawList_AddRectFilled(dl, lo, hi, ui.col(fill), 3)
		if playing && !cp.held do im.DrawList_AddRect(dl, lo, hi, ui.col(t.accent), 3, 1.5)
		name, _ := pa.progression_chord_name(&a.api, i64(i))
		if sp := strings.index_byte(name, ' '); sp > 0 do name = name[sp + 1:] // (its symbol: the numeral is under the chord playing)
		text_in(dl, lo, hi, name, t.bg if playing && cp.held else t.text)
	}
	return y0 + h
}
