// The Library's browser and the Performance view's launcher on a
// controller's display (Push 2's Browse and Clip), as the window has them:
// the same state, so each follows the other (ui_ctl.odin's layout).
package pads

import "core:fmt"
import "core:math"

import app "app:core"
import "app:ui"
import pa "api"
import pc "core"
import pm "model"
import im "deps:imgui"

// A row's step: two of Push 2's detents.
CTL_ROW_STEP :: 2.0 / 160
// A browser list's row: this much of an encoder's turn (five of Push 2's
// ticks: a list read item by item).
CTL_LIST_STEP :: 5.0 / 160

// The browser's rows shown at once on the display.
CTL_BROWSER_ROWS :: 6

// Encoder `col`'s rows in a list (`CTL_LIST_STEP` each): one a frame at
// most, a faster turn's rest let go (the encoder's speed never skips an
// item).
@(private)
ctl_list_steps :: proc(col: int) -> int {
	n := ctl_steps(col, CTL_LIST_STEP)
	if n != 0 && ui.knob_input != nil do ui.knob_input.turn[col] = 0
	return clamp(n, -1, 1)
}

// The whole steps in `x` steps of turn, toward zero (ticks that add up
// to a step in floating point, 0.9999..., are one).
@(private)
ctl_whole :: proc(x: f64) -> int {
	return int(x + (1e-6 if x > 0 else -1e-6))
}

// Encoder `col`'s whole steps since the last drawing (`step` of travel
// each; what's left over waits).
@(private)
ctl_steps :: proc(col: int, step: f64) -> int {
	ki := ui.knob_input
	if ki == nil do return 0
	n := ctl_whole(ki.turn[col] / step)
	ki.turn[col] -= f64(n) * step
	ki.ended[col] = false
	ki.drawn = max(ki.drawn, col + 1)
	return n
}

// --- Browse -------------------------------------------------------------------------------------

// The Library on a controller's display, as the window's (one state): its
// categories at the left (encoder 1; above them Back and Up, below
// Forward and a favourite of the folder shown), the category's list in
// the middle (encoder 3 a row, encoder 4 eight; the selected item's
// actions on the buttons above and below it: as a sampler, a slicer,
// slices onto pads, a synth's oscillator, the next empty pad; a folder
// opened or as the bank's kit; a device loaded; a project opened), the
// preview at the right (Play and Auto-play above, Sync below, encoder 7
// its volume; a device's or project's words instead).
ctl_browser :: proc(ctx: ^View_Ctx, full: im.Vec2) {
	a := ctx.a
	b := &a.browser
	v := &a.bview
	e := &a.m.engine
	pv := &e.preview
	t := ui.theme()
	dl := im.GetWindowDrawList()
	o := im.GetWindowPos()
	pm.browser_set_project(b, a.m.project.dir)
	inp := ctx.input
	pressed :: proc(inp: ^pa.View_Input, b: pa.View_Button) -> bool { return inp != nil && inp.pressed[int(b)] }
	top := o.y + CTL_PLOT_Y
	bottom := o.y + full.y - CTL_BUTTONS_H - 2
	// Shift held (the controller's): a load goes onto the next empty pad.
	if inp != nil {
		if inp.pressed[int(pa.View_Button.Shift)] do a.lib.shift = true
		if inp.released[int(pa.View_Button.Shift)] do a.lib.shift = false
	}
	ui.text_push(.Label)
	defer ui.text_pop()
	// The categories (encoder 1).
	cats := lib_categories(a)
	c := lib_cat(a)
	if d := ctl_list_steps(0); d != 0 do lib_show(a, clamp(a.lib.cat + d, 0, len(cats) - 1))
	// The arrows: ▲ ▼ the part in focus's rows (the categories, or the
	// list); ▶ into the list, a folder or a device's presets opened; ◀ one
	// closed again, or back to the categories.
	part := &a.ctl.browse_part
	arrow_items := lib_items(a)
	arrow_sel := lib_selected(a, arrow_items)
	step := (1 if pressed(inp, .Down) else 0) - (1 if pressed(inp, .Up) else 0)
	if part^ == 0 && step != 0 do lib_show(a, clamp(a.lib.cat + step, 0, len(cats) - 1))
	if part^ == 1 && step != 0 && len(arrow_items) > 0 do lib_select(a, arrow_items, clamp(arrow_sel + step if arrow_sel >= 0 else 0, 0, len(arrow_items) - 1))
	if pressed(inp, .Page_Right) {
		if part^ == 0 do part^ = 1
		else if arrow_sel >= 0 {
			it := arrow_items[arrow_sel]
			if it.kind == .Folder && !b.expanded[it.path] do pa.browser_expand(&a.api, it.path, true)
			else if it.fold == 1 do lib_run(a, .Presets, it)
		}
	}
	if pressed(inp, .Page_Left) && part^ == 1 {
		it: Lib_Item
		if arrow_sel >= 0 do it = arrow_items[arrow_sel]
		switch {
		case arrow_sel >= 0 && it.kind == .Folder && b.expanded[it.path]: pa.browser_expand(&a.api, it.path, false)
		case arrow_sel >= 0 && it.fold == 2: lib_run(a, .Presets, it)
		case: part^ = 0
		}
	}
	ctx.pages, ctx.page = 2, part^
	ctx.buttons |= 1 << uint(pa.View_Button.Up) | 1 << uint(pa.View_Button.Down)
	c = lib_cat(a)
	folders := lib_folders(c)
	cats_list: {
		x0, x1 := o.x + 3, o.x + f32(2 * CTL_COL) - 3
		rows := 6
		rh := (bottom - top) / f32(rows)
		first := clamp(a.lib.cat - rows / 2, 0, max(len(cats) - rows, 0))
		im.DrawList_AddRectFilled(dl, {x0, top}, {x1, bottom}, ui.col(ui.mix(t.surface, t.raised, 0.4)), t.radius)
		if a.ctl.browse_part == 0 do im.DrawList_AddRect(dl, {x0, top}, {x1, bottom}, ui.col(t.accent), t.radius, 1.5) // (the arrows' part)
		for k in first ..< min(first + rows, len(cats)) {
			y := top + f32(k - first) * rh
			if k == a.lib.cat do im.DrawList_AddRectFilled(dl, {x0 + 2, y + 1}, {x1 - 2, y + rh - 1}, ui.col(t.accent), 4)
			ty := y + (rh - im.GetTextLineHeight()) / 2
			im.DrawList_PushClipRect(dl, {x0, y}, {x1 - 4, y + rh}, true)
			im.DrawList_AddText(dl, {x0 + 8, ty}, ui.col(t.bg if k == a.lib.cat else t.text_dim), fmt.ctprintf("%s  %s", cats[k].icon, cats[k].name))
			im.DrawList_PopClipRect(dl)
		}
	}
	if folders {
		if p, _ := ctl_button(ctx, 0, ui.ICON_ARROW_RIGHT + "  Forward", false, full); p && len(b.forward) > 0 do pa.browser_forward(&a.api)
		fav := pm.is_favorite(b, b.root)
		if p, _ := ctl_button(ctx, 1, ui.ICON_STAR + "  Favourite", fav, full); p && b.root != "" && !fav do pa.browser_add_favorite(&a.api, b.root, "")
		ctl_upper(ctx, 0, ui.ICON_ARROW_LEFT + "  Back", false)
		ctl_upper(ctx, 1, ui.ICON_ARROW_UP + "  Up", false)
		if pressed(inp, .Upper_1) && len(b.back) > 0 do pa.browser_back(&a.api)
		if pressed(inp, .Upper_2) && pm.parent_of(b.root) != "" do pa.browser_up(&a.api)
	}
	// The list (encoders 3 and 4).
	items := lib_items(a)
	sel := lib_selected(a, items)
	if d := ctl_list_steps(2) + 8 * ctl_list_steps(3); d != 0 && len(items) > 0 {
		to := clamp(sel + d if sel >= 0 else 0, 0, len(items) - 1)
		if to != sel {
			lib_select(a, items, to)
			sel = to
		}
	}
	the_list: {
		x0, x1 := o.x + f32(2 * CTL_COL) + 3, o.x + f32(6 * CTL_COL) - 3
		rows := CTL_BROWSER_ROWS
		rh := (bottom - top) / f32(rows)
		first := clamp(sel - rows / 2, 0, max(len(items) - rows, 0))
		im.DrawList_AddRectFilled(dl, {x0, top}, {x1, bottom}, ui.col(ui.PLOT_BG), t.radius)
		if a.ctl.browse_part == 1 do im.DrawList_AddRect(dl, {x0, top}, {x1, bottom}, ui.col(t.accent), t.radius, 1.5)
		budget := LENGTHS_A_FRAME
		if v.lengths == nil do v.lengths = make(map[string]f64)
		for k in first ..< min(first + rows, len(items)) {
			it := items[k]
			y := top + f32(k - first) * rh
			if k == sel do im.DrawList_AddRectFilled(dl, {x0 + 2, y + 1}, {x1 - 2, y + rh - 1}, ui.col(ui.with_alpha(t.accent, 0.45)), 4)
			x := x0 + 8 + f32(it.depth) * 14
			ty := y + (rh - im.GetTextLineHeight()) / 2
			icon := ui.ICON_FILE_AUDIO
			ic := t.accent
			switch it.kind {
			case .Folder:     icon, ic = ui.ICON_FOLDER_OPEN if b.expanded[it.path] else ui.ICON_FOLDER, t.warn
			case .Midi:       icon = ui.ICON_MUSIC
			case .Instrument: icon = ui.ICON_BLOCKS
			case .Effect:     icon = ui.ICON_WAND_SPARKLES
			case .Project, .Template: icon = ui.ICON_FILE_PLUS
			case .Command: icon = ui.ICON_SAVE
			case .Audio, .Other:
			}
			im.DrawList_AddText(dl, {x, ty}, ui.col(ic), fmt.ctprintf("%s", icon))
			right := x1 - 8
			if it.kind == .Audio {
				if text := row_length(v, it.path, &budget); text != "" {
					ct := fmt.ctprintf("%s", text)
					ls := im.CalcTextSize(ct)
					right -= ls.x
					im.DrawList_AddText(dl, {right, ty}, ui.col(t.text_dim), ct)
					right -= 8
				}
			} else if it.info != "" && it.kind != .Project {
				ct := fmt.ctprintf("%s", it.info)
				ls := im.CalcTextSize(ct)
				if ls.x < (x1 - x0) * 0.4 {
					right -= ls.x
					im.DrawList_AddText(dl, {right, ty}, ui.col(t.text_dim), ct)
					right -= 8
				}
			}
			im.DrawList_PushClipRect(dl, {x, y}, {right, y + rh}, true)
			name := it.name
			if it.fold > 0 do name = fmt.tprintf("%s  %s", it.name, ui.ICON_CHEVRON_DOWN if it.fold == 2 else ui.ICON_CHEVRON_RIGHT) // (its presets: Presets on the upper row)
			im.DrawList_AddText(dl, {x + 22, ty}, ui.col(t.text), fmt.ctprintf("%s", name))
			im.DrawList_PopClipRect(dl)
		}
		// Where it is: a bar at the right, the place.
		if len(items) > rows {
			h := (bottom - top) * f32(rows) / f32(len(items))
			y := top + (bottom - top - h) * f32(first) / f32(len(items) - rows)
			im.DrawList_AddRectFilled(dl, {x1 - 3, y}, {x1 - 1, y + h}, ui.col(t.text_dim), 1)
		}
		if len(items) == 0 {
			why: cstring = "Nothing here yet"
			if folders do why = "Save the project to give it a folder" if b.root == "" else "No audio files or folders here"
			ts := im.CalcTextSize(why)
			im.DrawList_AddText(dl, {(x0 + x1 - ts.x) / 2, top + (bottom - top - ts.y) / 2}, ui.col(t.text_dim), why)
		}
	}
	// The selected item's actions, around the list.
	if sel >= 0 {
		it := items[sel]
		up, low := lib_actions(it)
		for act, k in up {
			if act == .None do continue
			ok := lib_can(a, act, it)
			ctl_upper(ctx, 2 + k, lib_shift_label(a, act, it), act == a.lib.last && ok)
			if !ok do ctx.buttons &~= 1 << uint(int(pa.View_Button.Upper_1) + 2 + k)
			if ok && pressed(inp, pa.View_Button(int(pa.View_Button.Upper_1) + 2 + k)) do lib_run(a, act, it, shift = a.lib.shift)
		}
		for act, k in low {
			if act == .None do continue
			ok := lib_can(a, act, it)
			if p, _ := ctl_button(ctx, 2 + k, fmt.ctprintf("%s", lib_shift_label(a, act, it)), false, full); p && ok do lib_run(a, act, it, shift = a.lib.shift)
			if !ok do ctx.buttons &~= 1 << uint(2 + k)
		}
	}
	// The preview, at the right.
	preview: {
		px := o.x + f32(6 * CTL_COL) + 3
		pw := f32(2 * CTL_COL) - 6
		ph: f32 = 44
		py := top
		im.DrawList_AddRectFilled(dl, {px, py}, {px + pw, py + ph}, ui.col(ui.PLOT_BG), t.radius)
		it: Lib_Item
		if sel >= 0 do it = items[sel]
		audio := it.kind == .Audio
		if audio && pv.frames > 0 && pv.path == it.path {
			mid := py + ph / 2
			half := ph / 2 - 3
			cols := int(pw - 4)
			for x in 0 ..< cols {
				cc := pv.wave[x * pm.PREVIEW_WAVE / max(cols, 1)]
				xx := px + 2 + f32(x)
				im.DrawList_AddLine(dl, {xx, mid - cc[1] * half}, {xx, mid - cc[0] * half + 1}, ui.col(ui.with_alpha(t.accent, 0.8)), 1)
			}
			if p := pm.preview_progress(e); p >= 0 {
				xx := px + 2 + f32(p) * (pw - 4)
				im.DrawList_AddLine(dl, {xx, py + 2}, {xx, py + ph - 2}, ui.col(t.text), 1.5)
			}
		} else {
			label: cstring = "Press Play to hear it" if audio else (fmt.ctprintf("%s", it.info) if it.info != "" else "")
			if pv.loading != nil && audio do label = "Loading…"
			im.DrawList_PushClipRect(dl, {px + 4, py}, {px + pw - 4, py + ph}, true)
			ts := im.CalcTextSize(label)
			im.DrawList_AddText(dl, {px + max((pw - ts.x) / 2, 4), py + (ph - ts.y) / 2}, ui.col(t.text_dim), label)
			im.DrawList_PopClipRect(dl)
		}
		if sel >= 0 {
			im.DrawList_PushClipRect(dl, {px, py}, {px + f32(CTL_COL) - 6, bottom}, true) // (the knob at the right)
			im.DrawList_AddText(dl, {px + 4, py + ph + 4}, ui.col(t.text), fmt.ctprintf("%s", it.name))
			if audio && pv.beats > 0 && pv.path == it.path do im.DrawList_AddText(dl, {px + 4, py + ph + 20}, ui.col(t.text_dim), fmt.ctprintf("%d beats", int(pv.beats)))
			im.DrawList_PopClipRect(dl)
		}
		// Encoder 7: its volume.
		w := ui.knob_width("Volume", CTL_KNOB)
		im.SetCursorPos({f32(7 * CTL_COL) + (CTL_COL - w) / 2, CTL_PLOT_Y + ph + 2})
		ui.knob_input.drawn = 6
		vol := pv.volume
		if ke := ui.knob("Volume", &vol, -48, 6, 0, "%.0f dB"); ke.changed {
			pa.browser_set_preview_settings(&a.api, {auto_play = pv.auto_play, sync = pv.sync, volume_db = clamp(vol, -60, 6)})
		}
		playing := pm.preview_playing(e)
		ctl_upper(ctx, 6, ui.ICON_SQUARE + "  Stop" if playing else ui.ICON_PLAY + "  Play", playing)
		ctl_upper(ctx, 7, "Auto-play", pv.auto_play)
		if pressed(inp, .Upper_7) {
			if playing do pa.browser_preview_stop(&a.api)
			else if audio do pa.browser_preview(&a.api, it.path)
		}
		if pressed(inp, .Upper_8) {
			pa.browser_set_preview_settings(&a.api, {auto_play = !pv.auto_play, sync = pv.sync, volume_db = pv.volume})
			if pv.auto_play do pa.browser_preview_stop(&a.api)
		}
		if p, _ := ctl_button(ctx, 6, "Sync", pv.sync, full); p do pa.browser_set_preview_settings(&a.api, {auto_play = pv.auto_play, sync = !pv.sync, volume_db = pv.volume})
	}
	ui.knob_input.drawn = 8
}

// --- Perform: the Perform tab ------------------------------------------------------------------

// The Perform tab on a controller's display, its window and state the
// window's own: the launcher's 4 lanes (their names on the upper row: a
// lane's sequence shown; their sequences, a playing one with a bar across,
// a queued one counting down; Stop on the lower row), the 16 effects (each
// its name, how hard it plays, lit while on; the last pressed outlined),
// Main and Cue (their faders and meters). The upper row's last four:
// Launch or Hold, when a launch happens, Continue, Rec; the lower's:
// Stop All, FX Latch, + Lane, Keys. Encoders: 1 the lanes, 2 the rows, 5
// the last effect's own strength, 7 Main, 8 Cue.
ctl_perform :: proc(ctx: ^View_Ctx, full: im.Vec2) {
	a := ctx.a
	m := &a.m
	p := &m.project
	t := ui.theme()
	dl := im.GetWindowDrawList()
	o := im.GetWindowPos()
	inp := ctx.input
	pressed := proc(inp: ^pa.View_Input, b: int) -> bool { return inp != nil && inp.pressed[b] }
	G :: pc.LAUNCH_GRID
	v, _ := pa.launcher_view(&a.api)
	ls, _ := pa.launcher_state(&a.api)
	// Moving the window: encoders 1 and 2, Page < > (four lanes).
	dl_lanes := ctl_steps(0, CTL_ROW_STEP)
	dl_rows := ctl_steps(1, CTL_ROW_STEP)
	if pressed(inp, int(pa.View_Button.Page_Left)) do dl_lanes -= G
	if pressed(inp, int(pa.View_Button.Page_Right)) do dl_lanes += G
	if dl_lanes != 0 || dl_rows != 0 {
		pa.launcher_set_view(&a.api, max(v.lane + i64(dl_lanes), 0), max(v.row + i64(dl_rows), 0))
		v, _ = pa.launcher_view(&a.api)
	}
	ctx.pages = max((p.lanes.count + G - 1) / G, 1)
	ctx.page = int(v.lane) / G
	tl, playing := pm.timeline_beat(&m.engine)
	pulse := 0.5 + 0.5 * f32(fmt_cos(tl))
	top := o.y + CTL_PLOT_Y
	bottom := o.y + full.y - CTL_BUTTONS_H - 2
	ui.text_push(.Label)
	defer ui.text_pop()
	// The lanes: their names above (a press: the lane's sequence shown),
	// their sequences, Stop below.
	cell_h := (bottom - top) / G
	for col in 0 ..< G {
		lane := int(v.lane) + col
		if lane >= p.lanes.count do continue
		cs, frac, next, in_beats, queued := pm.column_state(&m.engine, lane)
		lc := p.lanes.lanes[lane].color
		ctl_upper(ctx, col, pm.launch_lane_name(p, lane), false, ui.rgb(lc) if lc != 0 else {})
		if lc != 0 do im.DrawList_AddLine(dl, {o.x + f32(col * CTL_COL) + 10, o.y + CTL_TABS_H - 2}, {o.x + f32(col * CTL_COL) + CTL_COL - 10, o.y + CTL_TABS_H - 2}, ui.col(ui.rgb(lc)), 2)
		if pressed(inp, int(pa.View_Button.Upper_1) + col) {
			slot := cs if cs >= 0 else pm.lane_slot(p, lane, 0)
			if slot >= 0 do pa.sequence_select(&a.api, i64(slot))
		}
		for r in 0 ..< G {
			lrow := int(v.row) + r
			x0 := o.x + f32(col * CTL_COL) + 3
			x1 := x0 + CTL_COL - 6
			y1 := top + f32(G - r) * cell_h - 2 // (the first row at the bottom)
			y0 := y1 - cell_h + 4
			slot := pm.lane_slot(p, lane, lrow)
			if slot < 0 {
				if lrow == pm.lane_rows(p, lane) do im.DrawList_AddRect(dl, {x0, y0}, {x1, y1}, ui.col(ui.with_alpha(t.text, 0.08)), t.radius)
				continue
			}
			used := pm.slot_used(m, slot)
			c := ui.rgb(pm.sequence_color(p, slot))
			here := playing && cs == slot
			waiting := queued && next == slot
			if !used {
				im.DrawList_AddRect(dl, {x0, y0}, {x1, y1}, ui.col(ui.with_alpha(t.text, 0.12)), t.radius)
			} else {
				bright := here || (waiting && pulse > 0.5)
				im.DrawList_AddRectFilled(dl, {x0, y0}, {x1, y1}, ui.col(c if bright else ui.mix(ui.PLOT_BG, c, 0.35)), t.radius)
				if here do im.DrawList_AddRectFilled(dl, {x0, y1 - 3}, {x0 + (x1 - x0) * f32(frac), y1}, ui.col(t.text), 2)
			}
			if slot == p.slot do im.DrawList_AddRect(dl, {x0, y0}, {x1, y1}, ui.col(t.text), t.radius, 1.5)
			label := pm.sequence_name(p, slot)
			if waiting do label = fmt.tprintf("in %.1f", max(in_beats, 0))
			else if queued && cs == slot && next < 0 do label = "stops"
			im.DrawList_PushClipRect(dl, {x0 + 4, y0}, {x1 - 4, y1}, true)
			im.DrawList_AddText(dl, {x0 + 6, y0 + (y1 - y0 - im.GetTextLineHeight()) / 2}, ui.col(t.bg if used && (here || waiting) else (t.text if used else t.text_dim)), fmt.ctprintf("%s", label))
			im.DrawList_PopClipRect(dl)
		}
		if b, _ := ctl_button(ctx, col, ui.ICON_SQUARE + "  Stop", playing && cs >= 0, full); b do pa.launcher_stop_lane(&a.api, i64(lane))
	}
	if p.lanes.count == 0 do ctl_message("No lanes yet: + Lane makes one", {f32(G * CTL_COL), bottom - top})
	// The effects' legend: the grid's top right, each its name, how hard
	// it plays, lit while on; the last pressed outlined (encoder 5).
	{
		x := o.x + f32(4 * CTL_COL) + 3
		w := f32(2 * CTL_COL) - 6
		cw := (w - 6) / 4
		ch := (bottom - top - 6) / 4
		for i in 0 ..< pm.PERF_FX {
			r, c := i / 4, i % 4
			x0 := x + f32(c) * (cw + 2)
			y0 := top + f32(r) * (ch + 2)
			x1, y1 := x0 + cw, y0 + ch
			fx := p.perf_fx[i]
			col := fx_kind_color(fx.kind)
			own := p.perf_intensity[i]
			now := m.engine.perf_live[i] if fx.on && m.engine.perf_live[i] >= 0 else own
			im.DrawList_AddRectFilled(dl, {x0, y0}, {x1, y1}, ui.col(ui.mix(ui.PLOT_BG, col, 0.75 if fx.on else 0.22)), 3)
			im.DrawList_AddRectFilled(dl, {x0, y1 - 3}, {x0 + (x1 - x0) * now, y1}, ui.col(t.text if fx.on else ui.with_alpha(col, 0.8)), 2)
			if i64(i) == v.fx_last do im.DrawList_AddRect(dl, {x0, y0}, {x1, y1}, ui.col(t.text), 3, 1.5)
			ui.text_push(.Caption)
			im.DrawList_PushClipRect(dl, {x0 + 2, y0}, {x1 - 2, y1}, true)
			text_in(dl, {x0, y0}, {x1, y1 - 2}, pm.perf_label(fx), t.bg if fx.on else t.text)
			im.DrawList_PopClipRect(dl)
			ui.text_pop()
		}
		// Encoder 5: the last pressed one's own strength (a percent a detent).
		if n := ctl_steps(4, 1.0 / 160); n != 0 && v.fx_last >= 0 {
			pa.effect_set_intensity(&a.api, v.fx_last, clamp(p.perf_intensity[v.fx_last] + f32(n) / 100, 0, 1))
		}
		if ki := ui.knob_input; ki != nil && ki.ended[4] {
			ki.ended[4] = false
			app.seal(&m.history)
		}
	}
	// Main and Cue: their faders and meters (encoders 7 and 8).
	for k in 0 ..< 2 {
		col := 6 + k
		x0 := o.x + f32(col * CTL_COL) + 3
		x1 := x0 + CTL_COL - 6
		im.DrawList_AddRectFilled(dl, {x0, top}, {x1, bottom}, ui.col(ui.mix(t.surface, t.raised, 0.55)), t.radius)
		db := p.main.volume if k == 0 else a.settings.audio.cue_db
		view := &a.mixer.buses[pm.BUSES] if k == 0 else &a.mixer.cue
		ft, fb := top + 22, bottom - 6
		cx := x0 + 30
		y := fb - (fb - ft) * fader_frac(db)
		im.DrawList_AddRectFilled(dl, {cx - 2, ft}, {cx + 2, fb}, ui.col(well(t)), 2)
		im.DrawList_AddRectFilled(dl, {cx - 2, y}, {cx + 2, fb}, ui.col(t.accent), 2)
		im.DrawList_AddRectFilled(dl, {cx - 8, y - 6}, {cx + 8, y + 6}, ui.col(t.accent), 3)
		meter_bars(a, dl, view, cx + 16, ft, fb, 5)
		text_in(dl, {x0, top + 2}, {x1, top + 20}, fmt.tprintf("%s %s", "Main" if k == 0 else "Cue", "-inf" if db <= FADER_LO else fmt.tprintf("%.1f", db)), t.text)
		if n := ctl_steps(col, 1.0 / 160); n != 0 {
			to := fader_db(fader_frac(db) + f32(n) / 160)
			if k == 0 {
				pa.history_gesture_begin(&a.api)
				pa.mixer_set_bus_volume(&a.api, pa.MAIN, clamp(to, FADER_LO, FADER_HI))
			} else {
				a.settings.audio.cue_db = clamp(to, FADER_LO, FADER_HI)
				outputs_apply(a)
			}
		}
		if ki := ui.knob_input; ki != nil && ki.ended[col] {
			ki.ended[col] = false
			if k == 0 do pa.history_gesture_end(&a.api)
			else do settings_save(a)
		}
	}
	// The upper row's last four: the Perform bar's settings, as the window's.
	{
		segs :: proc(ctx: ^View_Ctx, k: int, names: []string, on: int, lit: ui.Color) {
			t := ui.theme()
			dl := im.GetWindowDrawList()
			o := im.GetWindowPos()
			x0 := o.x + f32(k * CTL_COL) + 4
			w := (f32(CTL_COL) - 8) / f32(len(names))
			for n, i in names {
				lo := im.Vec2{x0 + f32(i) * w, o.y + 3}
				hi := im.Vec2{lo.x + w - 1, o.y + CTL_TABS_H - 3}
				if i == on do im.DrawList_AddRectFilled(dl, lo, hi, ui.col(lit), 3)
				ui.text_push(.Caption if len(names) > 2 else .Label)
				text_in(dl, lo, hi, n, t.bg if i == on else t.text_dim)
				ui.text_pop()
			}
			b := int(pa.View_Button.Upper_1) + k
			ctx.buttons |= 1 << uint(b)
			if on >= 0 do ctx.lit |= 1 << uint(b)
		}
		segs(ctx, 4, {"Launch", "Hold"}, 1 if ls.hold else 0, t.accent)
		segs(ctx, 5, {"End", "Bar", "Beat", "Now"}, int(ls.quantize), t.accent)
		ctl_upper(ctx, 6, "Continue", ls.continue_)
		ctl_upper(ctx, 7, ui.ICON_CIRCLE_DOT + "  Rec", ls.recording, t.danger)
		if pressed(inp, int(pa.View_Button.Upper_5)) do pa.launcher_set_hold(&a.api, !ls.hold)
		if pressed(inp, int(pa.View_Button.Upper_6)) do pa.launcher_set_quantize(&a.api, pa.Launch_Quantize((int(ls.quantize) + 1) % 4))
		if pressed(inp, int(pa.View_Button.Upper_7)) do pa.launcher_set_continue(&a.api, !ls.continue_)
		if pressed(inp, int(pa.View_Button.Upper_8)) do pa.launcher_set_recording(&a.api, !ls.recording)
	}
	// The lower row's last four.
	any := false
	for l in 0 ..< p.lanes.count do if cs, _, _, _, _ := pm.column_state(&m.engine, l); playing && cs >= 0 do any = true
	if b, _ := ctl_button(ctx, 4, ui.ICON_SQUARE_X + "  Stop All", any, full); b do pa.launcher_stop_all(&a.api)
	if b, _ := ctl_button(ctx, 5, "FX Latch", v.fx_latch, full); b do pa.effect_set_latch(&a.api, !v.fx_latch)
	if p.lanes.count < pm.MAX_LANES {
		if b, _ := ctl_button(ctx, 6, ui.ICON_PLUS + "  Lane", false, full); b {
			if _, r := pa.launcher_add_lane(&a.api); r == .Ok do pa.launcher_set_view(&a.api, i64(p.lanes.count - G), v.row)
		}
	}
	if b, _ := ctl_button(ctx, 7, ui.ICON_KEYBOARD + "  Keys", v.keys, full); b do pa.launcher_set_keys(&a.api, !v.keys)
	ui.knob_input.drawn = 8
}

@(private)
fmt_cos :: proc(beat: f64) -> f64 {
	x := beat - f64(int(beat))
	return 1 - 4 * abs(x - 0.5) // (a triangle: bright on the beat)
}

// --- Clip: the sequencer ------------------------------------------------------------------------

// The sequencer's notes on a controller's display, as the window's
// Sequence panel has them (the same rows, the same selection and grid): its
// tabs the upper row's first three, the rows under them, the notes in their
// pads' colours, the selection outlined, the selected pad's row outlined
// red, the playhead. The encoders: the rows shown, the note selected (in
// time; Select held: added to the selection), its velocity, length,
// position and row, its chance, the grid. The lower row: Piano (the
// selected pad's keys), Fold, then Mute, Duplicate and Delete for the
// selection (Delete: the next note selected). A controller's Select
// tapped: the selected pad's notes; its Delete tapped: the selection gone.
ctl_sequencer :: proc(ctx: ^View_Ctx, full: im.Vec2) {
	a := ctx.a
	m := &a.m
	st := &a.seq
	t := ui.theme()
	slot := m.project.slot
	s := pm.current_sequence(m)
	modes := []string{"Notes", "Automation", "Audio"}
	if k := ctl_tabs(ctx, modes, int(st.mode)); k >= 0 && k < len(modes) do st.mode = pm.Seq_Mode(k)
	// (the knob row slim: values in boxes, the notes the room)
	plot := im.Vec2{full.x - CTL_METER_W - 6, full.y - CTL_PLOT_Y - CTL_KNOBS_H - CTL_BUTTONS_H - 4} // (the knobs: a row of value bars)
	if st.mode == .Automation {
		ctl_automation(ctx, full, plot)
		return
	}
	if st.mode == .Audio {
		ctl_audio(ctx, full, plot)
		return
	}
	row_pad, row_pitch, rows, slicer := seq_rows(a, s)
	// Piano and Fold: the window's too.
	if p, _ := ctl_button(ctx, 0, "Piano", st.piano, full); p {
		st.piano = !st.piano
		st.piano_pad = a.selected
		st.view.key0 = -1
		a.ctl.seq_pad = 0
	}
	if p, _ := ctl_button(ctx, 2, "Copy Bars", false, full); p do begin_copy_bars(a, slot)
	if p, _ := ctl_button(ctx, 1, "Fold", st.fold, full); p {
		st.fold = !st.fold
		st.view.key0 = -1
		a.ctl.seq_pad = 0
	}
	if len(rows) == 0 {
		ctl_message("No notes to fold to: draw some, or turn Fold off", plot)
		return
	}
	notes := make([dynamic]ui.Roll_Note, context.temp_allocator)
	which := make([dynamic]int, context.temp_allocator)
	for n, i in s.notes {
		k := row_of_note(row_pad[:], row_pitch[:], st.piano, n)
		if k < 0 do continue
		append(&notes, ui.Roll_Note{start = n.start, length = n.length, key = k, velocity = n.velocity, selected = is_selected(st, n), color = ui.rgb(m.project.pads[n.pad].color), muted = n.muted})
		append(&which, i)
	}
	// The rows shown: as many as fit, the selected pad's (or the pad's own
	// pitch in the piano roll) brought into view when it changes.
	v := &a.ctl.seq_view
	cx := &a.ctl
	keys := clamp(int(plot.y / 14), 1, len(rows))
	v.keys = keys
	length := pm.seq_beats(&m.project, s)
	snap := pm.grid_beats(st.grid)
	// The cursor: on the selected pad's row (brought into view) when the
	// pad is picked elsewhere.
	if cx.seq_pad != a.selected + 1 {
		cx.seq_pad = a.selected + 1
		v.key0 = 0
		for r, k in row_pad do if r == a.selected && (!st.piano || row_pitch[k] == 0 || slicer) {
			v.key0 = k - keys / 2
			cx.seq_row = k
			break
		}
	}
	cx.seq_row = clamp(cx.seq_row, 0, len(rows) - 1)
	cx.seq_beat = clamp(cx.seq_beat, 0, max(length - snap, 0))
	// The note on the cursor's step (its row, starting within the step).
	cursor_note :: proc(s: pm.Sequence, notes: []ui.Roll_Note, which: []int, row: int, beat, snap: f64) -> (pm.Seq_Note, bool) {
		for rn, k in notes do if rn.key == row && rn.start >= beat - 1e-9 && rn.start < beat + snap - 1e-9 do return s.notes[which[k]], true
		return {}, false
	}
	// (the window may have changed the selection: the cursor's note no longer its last)
	if cx.seq_transient {
		n, ok := cursor_note(s, notes[:], which[:], cx.seq_row, cx.seq_beat, snap)
		if !ok || len(st.sel) == 0 || st.sel[len(st.sel) - 1] != n do cx.seq_transient = false
	}
	// The notes (under the knobs' lists, opened over them while touched).
	v.key0 = clamp(v.key0, 0, max(len(rows) - keys, 0))
	v.beat0, v.beats = 0, length
	beat, playing := pm.position(&m.engine)
	im.SetCursorPos({0, CTL_PLOT_Y})
	grid_at := im.GetCursorScreenPos()
	ui.note_grid("ctl seq", notes[:], rows, v, snap, plot, st.tool, beat if playing else -1, pm.bar_beats(&m.project))
	// The cursor moved: the note it left let go (unless Select kept it),
	// the one it's on selected.
	land :: proc(a: ^App, s: pm.Sequence, notes: []ui.Roll_Note, which: []int, snap: f64) {
		st := &a.seq
		cx := &a.ctl
		if cx.seq_transient && len(st.sel) > 0 do pop(&st.sel)
		cx.seq_transient = false
		st.selected = -1
		if n, ok := cursor_note(s, notes, which, cx.seq_row, cx.seq_beat, snap); ok && !is_selected(st, n) {
			append(&st.sel, n)
			cx.seq_transient = true
			for x, i in s.notes do if x == n {
				st.selected = i
				break
			}
		}
	}
	moved, row_moved := false, false
	// The arrows: ▲ ▼ a row (its pad selected), ◀ ▶ a grid step.
	inp := ctx.input
	if inp != nil {
		if inp.pressed[int(pa.View_Button.Up)] && cx.seq_row < len(rows) - 1 do cx.seq_row, moved, row_moved = cx.seq_row + 1, true, true
		if inp.pressed[int(pa.View_Button.Down)] && cx.seq_row > 0 do cx.seq_row, moved, row_moved = cx.seq_row - 1, true, true
		if inp.pressed[int(pa.View_Button.Page_Left)] && cx.seq_beat > 1e-9 do cx.seq_beat, moved = max(math.ceil(cx.seq_beat / snap - 1e-9) * snap - snap, 0), true
		if inp.pressed[int(pa.View_Button.Page_Right)] {
			if nb := math.floor(cx.seq_beat / snap + 1e-9) * snap + snap; nb < length - 1e-9 do cx.seq_beat, moved = nb, true
		}
	}
	// Encoder 1: the cursor's row (its pad selected).
	{
		names := make([]string, len(rows), context.temp_allocator)
		for &nm, k in names do nm = rows[k].name
		if k, _ := ctl_choice(ctx, 0, 8, "Pad" if !st.piano else "Key", names, cx.seq_row, plot); k >= 0 do cx.seq_row, moved, row_moved = k, true, true
	}
	if row_moved {
		if !st.piano && row_pad[cx.seq_row] != a.selected {
			pa.perform_select_pad(&a.api, i64(row_pad[cx.seq_row]))
			cx.seq_pad = row_pad[cx.seq_row] + 1 // (the cursor already there)
		}
		if cx.seq_row < v.key0 do v.key0 = cx.seq_row
		if cx.seq_row >= v.key0 + keys do v.key0 = cx.seq_row - keys + 1
	}
	v.key0 = clamp(v.key0, 0, max(len(rows) - keys, 0))
	// Encoder 2: the notes on the cursor's row, in time (the cursor goes
	// to the one chosen).
	{
		on_row := make([dynamic]int, context.temp_allocator) // (into `notes`, by start)
		for rn, k in notes do if rn.key == cx.seq_row {
			j := len(on_row)
			append(&on_row, k)
			for j > 0 && notes[on_row[j - 1]].start > rn.start + 1e-9 {
				on_row[j - 1], on_row[j] = on_row[j], on_row[j - 1]
				j -= 1
			}
		}
		names := make([dynamic]string, context.temp_allocator)
		cur := 0
		for k, i in on_row {
			append(&names, fmt.tprintf("%s", ctl_beat_name(&m.project, notes[k].start)))
			if notes[k].start < cx.seq_beat + snap - 1e-9 do cur = i // (on it, or the last before it)
		}
		if len(names) == 0 do append(&names, "None")
		if k, _ := ctl_choice(ctx, 1, 8, "Note", names[:], cur, plot); k >= 0 && k < len(on_row) do cx.seq_beat, moved = notes[on_row[k]].start, true
	}
	if moved do land(a, s, notes[:], which[:], snap)
	// Select: the cursor's note kept in the selection (again: let go);
	// Shift + Select: every note of the pad (again: none).
	if inp != nil && inp.pressed[int(pa.View_Button.Select)] {
		if a.ctl.shift {
			pad := row_pad[cx.seq_row] if !st.piano else a.selected
			all, total := true, 0
			for n in s.notes do if int(n.pad) == pad {
				total += 1
				if !is_selected(st, n) do all = false
			}
			clear(&st.sel)
			st.selected = -1
			cx.seq_transient = false
			if !(all && total > 0) do for n, i in s.notes do if int(n.pad) == pad {
				append(&st.sel, n)
				if st.selected < 0 do st.selected = i
			}
		} else if n, ok := cursor_note(s, notes[:], which[:], cx.seq_row, cx.seq_beat, snap); ok {
			switch {
			case cx.seq_transient && st.sel[len(st.sel) - 1] == n: cx.seq_transient = false // (kept)
			case is_selected(st, n):
				for x, i in st.sel do if x == n {
					ordered_remove(&st.sel, i)
					break
				}
			case: append(&st.sel, n)
			}
		}
	}
	// Delete: the selection gone, the cursor on the next note along its row
	// (none after: the one before), that note selected.
	delete_and_go_on :: proc(a: ^App, s: pm.Sequence, notes: []ui.Roll_Note, which: []int, snap: f64) {
		st := &a.seq
		cx := &a.ctl
		after, before: pm.Seq_Note
		has_after, has_before := false, false
		for rn, k in notes do if rn.key == cx.seq_row {
			n := s.notes[which[k]]
			if is_selected(st, n) do continue
			if rn.start >= cx.seq_beat + snap - 1e-9 {
				if !has_after || n.start < after.start do after, has_after = n, true
			} else if rn.start < cx.seq_beat - 1e-9 {
				if !has_before || n.start > before.start do before, has_before = n, true
			}
		}
		delete_selection(a)
		st.selected = -1
		cx.seq_transient = false
		to, ok := (after if has_after else before), has_after || has_before
		if !ok do return
		cx.seq_beat = to.start
		now := pm.current_sequence(&a.m)
		for n, i in now.notes do if n == to {
			append(&st.sel, n)
			st.selected = i
			cx.seq_transient = true
			break
		}
	}
	if inp != nil && inp.pressed[int(pa.View_Button.Delete)] && len(st.sel) > 0 do delete_and_go_on(a, s, notes[:], which[:], snap)
	// The arrows lit where the cursor can go.
	if cx.seq_row < len(rows) - 1 do ctx.buttons |= 1 << uint(pa.View_Button.Up)
	if cx.seq_row > 0 do ctx.buttons |= 1 << uint(pa.View_Button.Down)
	if cx.seq_beat > 1e-9 do ctx.buttons |= 1 << uint(pa.View_Button.Page_Left)
	if cx.seq_beat + snap < length - 1e-9 do ctx.buttons |= 1 << uint(pa.View_Button.Page_Right)

	// Over them: the selected pad's row and the cursor (as they are now).
	{
		dl := im.GetWindowDrawList()
		row_h := plot.y / f32(max(v.keys, 1))
		names_w := ui.roll_rows_width(rows)
		gw := plot.x - names_w
		// The selected pad's row outlined red (the piano roll's rows are all its).
		if !st.piano do for r, k in row_pad do if r == a.selected && k >= v.key0 && k < v.key0 + v.keys {
			y := grid_at.y + plot.y - f32(k - v.key0 + 1) * row_h
			im.DrawList_AddRect(dl, {grid_at.x + 1, y + 1}, {grid_at.x + plot.x - 1, y + row_h - 1}, ui.col(t.danger), 3, 1.5)
		}
		// The cursor's step: lit, and boxed in the accent (white boxes are
		// the selection's).
		if cx.seq_row >= v.key0 && cx.seq_row < v.key0 + v.keys && length > 0 {
			y := grid_at.y + plot.y - f32(cx.seq_row - v.key0 + 1) * row_h
			x0 := grid_at.x + names_w + f32(cx.seq_beat / length) * gw
			x1 := x0 + max(f32(snap / length) * gw, 3)
			im.DrawList_AddRectFilled(dl, {x0, y + 2}, {x1, y + row_h - 2}, ui.col(ui.with_alpha(t.text, 0.22)), 2)
			im.DrawList_AddRect(dl, {x0 - 1, y + 1}, {x1 + 1, y + row_h - 1}, ui.col(t.warn), 2, 2)
		}
	}
	has := len(st.sel) > 0
	first: pm.Seq_Note
	if has do first = st.sel[0]
	// Encoders 3 and 7: velocity and chance (a percent a detent), the
	// selection's all set to the first's.
	ctl_note_value(ctx, 2, "Velocity", has, &first.velocity, .Velocity, "Set Velocity", plot)
	ctl_note_value(ctx, 6, "Chance", has, &first.probability, .Probability, "Set Chance", plot)
	// Encoders 4-6: length, position and row, a grid step at a time.
	if n, ended := ctl_value_box(ctx, 3, "Length", fmt.tprintf("%.3g beats", first.length) if has else "—", CTL_STEP, plot); has && n != 0 {
		moved := make([]pm.Seq_Note, len(st.sel), context.temp_allocator)
		for x, i in st.sel {
			moved[i] = x
			moved[i].length = max(math.round((x.length + f64(n) * snap) / snap) * snap, snap)
		}
		landed := pm.replace_notes(m, slot, st.sel[:], moved, false, .Note_Drag, "Resize Notes")
		clear(&st.sel)
		append(&st.sel, ..landed)
		if ended do app.seal(&m.history)
	} else if ended do app.seal(&m.history)
	if n, _ := ctl_value_box(ctx, 4, "Position", ctl_beat_name(&m.project, first.start) if has else "—", CTL_STEP, plot); has && n != 0 do nudge_selection(a, f64(n) * snap, 0, row_pad[:], row_pitch[:])
	row_name := rows[row_of_note(row_pad[:], row_pitch[:], st.piano, first)].name if has && row_of_note(row_pad[:], row_pitch[:], st.piano, first) >= 0 else "—"
	if n, _ := ctl_value_box(ctx, 5, "Row", row_name, CTL_STEP, plot); has && n != 0 do nudge_selection(a, 0, n, row_pad[:], row_pitch[:])
	// Encoder 8: the grid (the window's snap and quantize).
	{
		grids := make([]string, len(pm.Grid), context.temp_allocator)
		for g in pm.Grid do grids[int(g)] = string(pm.GRID_NAMES[g])
		if k, _ := ctl_choice(ctx, 7, 8, "Grid", grids, int(st.grid), plot); k >= 0 do st.grid = pm.Grid(k)
	}
	// The selection's: Mute, Duplicate, Delete.
	if p, _ := ctl_button(ctx, 4, "Unmute" if has && first.muted else "Mute", false, full); p && has do mute_selection(a)
	if p, _ := ctl_button(ctx, 5, "Duplicate", false, full); p && has do duplicate_selection(a)
	if p, _ := ctl_button(ctx, 6, "Delete", false, full); p && has do delete_and_go_on(a, s, notes[:], which[:], snap)
	_ = t
	ui.knob_input.drawn = 8
}

// A position in the sequence as bar.beat.sixteenth (from 1).
@(private)
ctl_beat_name :: proc(p: ^pm.Project, b: f64) -> string {
	bar := pm.bar_beats(p)
	whole := int(math.floor(b / bar + 1e-9))
	in_bar := b - f64(whole) * bar
	beat := int(math.floor(in_bar + 1e-9))
	six := int(math.floor((in_bar - f64(beat)) * 4 + 1e-6))
	return fmt.tprintf("%d.%d.%d", whole + 1, beat + 1, six + 1)
}

// Knob column `col` as a box showing `text` under `label`: the whole steps
// (`step` of travel each) its encoder turned since the last drawing, and
// whether it was let go.
@(private)
ctl_value_box :: proc(ctx: ^View_Ctx, col: int, label: cstring, text: string, step: f64, plot: im.Vec2) -> (steps: int, ended: bool) {
	ki := ui.knob_input
	held := ki != nil && ki.held[col]
	if ki != nil do ended = ki.ended[col]
	steps = ctl_steps(col, step)
	ctl_box(col, label, text, held, plot)
	return
}

// The selection's velocity or chance (`value`, the first's) in column
// `col`: a turn sets it for all of them, a percent a detent.
@(private)
ctl_note_value :: proc(ctx: ^View_Ctx, col: int, label: cstring, has: bool, value: ^f32, field: pm.Seq_Field, name: string, plot: im.Vec2) {
	a := ctx.a
	st := &a.seq
	n, ended := ctl_value_box(ctx, col, label, fmt.tprintf("%.0f%%", value^ * 100) if has else "—", 1.0 / 160, plot)
	if has && n != 0 {
		to := clamp(value^ + f32(n) / 100, 0.01, 1)
		moved := make([]pm.Seq_Note, len(st.sel), context.temp_allocator)
		for x, i in st.sel {
			moved[i] = x
			if field == .Velocity do moved[i].velocity = to
			else do moved[i].probability = to
		}
		landed := pm.replace_notes(&a.m, a.m.project.slot, st.sel[:], moved, false, field, name)
		clear(&st.sel)
		append(&st.sel, ..landed)
	}
	if ended do app.seal(&a.m.history)
}


// Action `act`'s label on a controller: with Shift held, a load onto a pad
// says it goes onto the next empty one.
@(private)
lib_shift_label :: proc(a: ^App, act: Lib_Act, it: Lib_Item) -> string {
	label := lib_act_label(act, it)
	#partial switch act {
	case .Sampler, .Slicer, .Slices, .Synth_Osc, .Notes, .Load:
		if a.lib.shift || a.ctl.shift do return fmt.tprintf("%s → Next Pad", label)
	}
	return label
}
