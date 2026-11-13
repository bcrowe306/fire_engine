package pads

import "core:fmt"
import "core:math"

import app "app:core"
import "app:ui"
import pm "model"
import im "deps:imgui"
import pf "fire:perform"

// The Perform tab: the whole height (the pads area folds while it shows),
// three grids side by side — the sequence launcher (its columns are lanes,
// playing together), the 16 pads to play, and the performance effects —
// and the main and cue levels at the right.

// The Perform tab's state.
Perf_State :: struct {
	learning:   bool, // the next MIDI note learns the selected pad
	learn_seen: int,  // capture.midi_count when learning began
	sent, received: u64, // MIDI counts last frame
	in_lit, out_lit: f32, // seconds the activity lights stay on
	menu_fx: int, // the performance effect whose menu is open
	win_lane, win_row: int, // the launcher's window: its first lane and row (see `draw_launcher`)
	lane_menu: int,    // the lane whose header menu is open
	lane_naming: bool, // ... renaming it
	lane_name: [16]u8,
	holds:     [dynamic]Seq_Hold, // the sequence pads held in Hold (and let go, until their launch has come)
	hold_from: [pm.MAX_LANES]int, // what each lane played before its first held pad (-1: nothing; to go back to)
	hold_order: u64, // counts presses (the latest held pad of a lane is the one it plays)
	key_slot:  [16]int, // the sequence each pad key pressed (+1; 0: none), for its release wherever the window is
	seq_keys: bool, // the pad keys play the sequence pads shown (the Keys switch)
	shown_frame: i32, // the frame it last showed (it folds the pads area)
	folded_it:   bool,
}

// Step lengths, as the UI shows them.
RATE_NAMES := [pf.Rate]cstring{
	.Quarter = "1/4", .Eighth = "1/8", .Eighth_Triplet = "1/8T", .Sixteenth = "1/16",
	.Sixteenth_Triplet = "1/16T", .Thirty_Second = "1/32", .Thirty_Second_Triplet = "1/32T",
}

// Arpeggio orders, as the UI shows them.
ARP_NAMES := [pf.Arp_Mode]cstring{.Up = "Up", .Down = "Down", .Up_Down = "Up-down", .Random = "Random", .As_Played = "As played"}

// Note names of the roots.
ROOT_NAMES := [12]cstring{"C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"}

draw_perform :: proc(user: rawptr) {
	a := (^App)(user)
	st := &a.perf
	fold_pads_while_shown(a, &st.shown_frame, &st.folded_it)
	draw_perform_bar(a)
	im.Spacing()
	avail := im.GetContentRegionAvail()
	levels_w := inner_w() + 44 // (main's fader and meter as in the mixer, and the cue's fader)
	gap: f32 = 14
	col_w := max((avail.x - levels_w - 3 * gap) / 3, 160)
	h := avail.y
	if im.BeginChild("##perflaunch", {col_w, h}) do draw_launcher(a)
	im.EndChild()
	im.SameLine(0, gap)
	if im.BeginChild("##perfpads", {col_w, h}) {
		perf_title("Pads")
		draw_pads(a)
	}
	im.EndChild()
	im.SameLine(0, gap)
	if im.BeginChild("##perffx", {col_w, h}) do draw_perf_fx(a)
	im.EndChild()
	im.SameLine(0, gap)
	if im.BeginChild("##perflevels", {levels_w, h}) do draw_perf_levels(a)
	im.EndChild()
}

// A grid's title.
@(private)
perf_title :: proc(title: cstring) {
	im.TextDisabled("%s", title)
	im.Spacing()
}

// The bar on top: the sequence bank (and Keys), Launch or Hold and when a
// launch happens, Record to Song; the effects' Hold.
@(private)
draw_perform_bar :: proc(a: ^App) {
	m := &a.m
	p := &m.project
	st := &a.perf
	// The window over the lanes: a lane or a row at a time.
	nav :: proc(icon: string, tip: cstring, name: string) -> bool {
		hit := ui.icon_button(icon, tip)
		ui.name(name)
		im.SameLine(0, 2)
		return hit
	}
	G := LAUNCH_GRID
	if nav(ui.ICON_CHEVRON_LEFT, "The lanes before", "window left") do st.win_lane -= 1
	if nav(ui.ICON_CHEVRON_RIGHT, "The lanes after", "window right") do st.win_lane += 1
	if nav(ui.ICON_CHEVRON_DOWN, "The rows below", "window down") do st.win_row -= 1
	if nav(ui.ICON_CHEVRON_UP, "The rows above", "window up") do st.win_row += 1
	clamp_window(a)
	im.AlignTextToFramePadding()
	im.TextDisabled("%s", fmt.ctprintf("Lanes %d–%d · rows %d–%d", st.win_lane + 1, min(st.win_lane + G, p.lanes.count), st.win_row + 1, st.win_row + G))
	ui.name("launcher window")
	im.SameLine(0, 4)
	if ui.icon_button(ui.ICON_PLUS, "Add a lane (up to 16)", disabled = p.lanes.count >= pm.MAX_LANES) {
		if pm.add_lane(m) do st.win_lane = p.lanes.count - LAUNCH_GRID // (shown)
	}
	ui.name("add a lane")
	im.SameLine(0, 10)
	if ui.icon_button(ui.ICON_KEYBOARD, "Keys: the computer's pad keys play these sequence pads (not the pads)", on = st.seq_keys) do st.seq_keys = !st.seq_keys
	ui.name("sequence keys")
	im.SameLine(0, 14)
	hold := 1 if p.launch_hold else 0
	if ui.segmented("launch_mode", {"Launch", "Hold"}, &hold) do pm.set_launch_hold(m, hold == 1)
	ui.name("launch mode")
	if im.IsItemHovered() do im.SetTooltip("Launch: a press starts it in its column; Hold: it plays while held, then what was there")
	im.SameLine(0, 10)
	im.AlignTextToFramePadding()
	im.TextDisabled("at")
	im.SameLine()
	at := int(p.switch_at)
	if ui.segmented("launch_quantize", {"End", "Bar", "Beat", "Now"}, &at) do p.switch_at = pm.Switch_At(at)
	if im.IsItemHovered() do im.SetTooltip("When a launch happens: when its column's sequence comes round, the next bar or beat, or now")
	ui.name("launch quantize")
	im.SameLine(0, 10)
	cont := p.launch_continue
	if ui.toggle("Continue", &cont) do pm.set_launch_continue(m, cont)
	ui.name("launch continue")
	if im.IsItemHovered() do im.SetTooltip("Continue: a launched sequence carries on where the playhead is in what played (that pass so far, modulo its length), for seamless changes; off, it starts from its top")
	im.SameLine(0, 14)
	rec := pm.launch_recording(m)
	if ui.icon_button(ui.ICON_CIRCLE_DOT, "Record to Song: what you launch is written into the Song (launcher lane 1 into song lane 1...)", on = rec, color = ui.theme().danger) do pm.set_launch_record(m, !rec)
	ui.name("record to song")
	im.SameLine(0, 2)
	im.AlignTextToFramePadding()
	if rec do im.TextColored(transmute(im.Vec4)ui.theme().danger, "Recording to Song")
	else do im.TextDisabled("Record to Song")
	// The effects' Hold, at the right.
	w := im.CalcTextSize("Hold effects").x + 40
	im.SameLine(max(im.GetCursorPosX() + 10, im.GetCursorPosX() + im.GetContentRegionAvail().x - w))
	ui.toggle("Hold effects", &a.perf_hold)
	if im.IsItemHovered() do im.SetTooltip("A press turns an effect on until the next press")
	if !a.perf_hold {
		for i in 0 ..< pm.PERF_FX do if a.perf_latched[i] {
			a.perf_latched[i] = false
			if !a.perf_held[i] do pm.hold_perf_fx(m, i, false)
		}
	}
}

// Cells the launcher's window is across and up (a pad controller's 4 × 4).
LAUNCH_GRID :: 4

// Keeps the launcher's window over the lanes and rows there are (one row
// past the longest lane: its +).
clamp_window :: proc(a: ^App) {
	p := &a.m.project
	st := &a.perf
	st.win_lane = clamp(st.win_lane, 0, max(p.lanes.count - LAUNCH_GRID, 0))
	st.win_row = clamp(st.win_row, 0, max(pm.max_rows(p) + 1 - LAUNCH_GRID, 0))
}

// The sequence in the window's cell `col`, `row` (from the bottom left),
// and its lane and row; slot -1: none there (`plus`: the lane's +, after
// its last).
window_cell :: proc(a: ^App, col, row: int) -> (slot, lane, lrow: int, plus: bool) {
	p := &a.m.project
	lane, lrow = a.perf.win_lane + col, a.perf.win_row + row
	if lane >= p.lanes.count do return -1, lane, lrow, false
	slot = pm.lane_slot(p, lane, lrow)
	plus = slot < 0 && lrow == pm.lane_rows(p, lane)
	return
}

// The sequence launcher: a window of 4 lanes by 4 rows over all of them
// (moved by the bar's arrows, or the overview below), each column a lane
// playing one sequence at a time (all together), its header its name;
// Shift-click launches one alone (the other lanes stop then;
// Option-click only goes to it, to edit it; Option-drag moves it to
// another lane or row); the row's arrow launches the scene (that row of
// every lane), the lane's square stops it. A sequence pad shows its
// notes, a bar filling across while it plays (a queued one counts down),
// a mark when it shares a pad with another lane's; an empty one is nearly
// invisible (click it to make a new sequence there), a lane's + after its
// last.
draw_launcher :: proc(a: ^App) {
	m := &a.m
	p := &m.project
	st := &a.perf
	t := ui.theme()
	clamp_window(a)
	perf_title("Sequences · each column a lane")
	G :: LAUNCH_GRID
	tl, playing := pm.timeline_beat(&m.engine)
	avail := im.GetContentRegionAvail()
	gap: f32 = 6
	arrow: f32 = 22
	head := im.GetFrameHeight()
	map_h: f32 = 64
	size := clamp(min((avail.x - arrow - f32(G) * gap) / f32(G), (avail.y - 2 * head - map_h - f32(G + 3) * gap) / f32(G)), 40, 140)
	origin := im.GetCursorScreenPos()
	dl := im.GetWindowDrawList()
	pads := pm.all_seq_pads(p)
	// The lanes' headers: each its name (its menu), and a + for a new lane.
	open_menu := false
	for col in 0 ..< G {
		lane := st.win_lane + col
		if lane >= p.lanes.count {
			if lane == p.lanes.count && p.lanes.count < pm.MAX_LANES {
				im.SetCursorScreenPos({origin.x + f32(col) * (size + gap), origin.y})
				if im.Button(ui.ICON_PLUS + "  Lane", {size, 0}) do pm.add_lane(m)
				ui.name("add lane")
				if im.IsItemHovered() do im.SetTooltip("A new lane (up to 16)")
			}
			continue
		}
		im.SetCursorScreenPos({origin.x + f32(col) * (size + gap), origin.y})
		im.PushIDInt(i32(9700 + lane))
		lc := p.lanes.lanes[lane].color
		c := ui.rgb(lc) if lc != 0 else t.text_dim
		pos := im.GetCursorScreenPos()
		if im.InvisibleButton("##lanehead", {size, head}, {.MouseButtonLeft, .MouseButtonRight}) {
			st.lane_menu = lane
			open_menu = true
		}
		ui.name(fmt.tprintf("lane %d", lane + 1))
		hot := im.IsItemHovered()
		im.DrawList_AddRectFilled(dl, pos, {pos.x + size, pos.y + head}, ui.col(t.raised if hot else ui.mix(t.surface, t.raised, 0.5)), t.radius)
		im.DrawList_AddRectFilled(dl, {pos.x, pos.y + head - 3}, {pos.x + size, pos.y + head}, ui.col(c), 1)
		name := pm.launch_lane_name(p, lane)
		im.DrawList_AddText(dl, {pos.x + 6, pos.y + (head - im.GetFontSize()) / 2 - 1}, ui.col(t.text if hot else t.text_dim), ui.fit_text(name, size - 12))
		if hot do im.SetTooltip("%s", fmt.ctprintf("%s · %d sequence%s · click: rename, colour, delete", name, pm.lane_rows(p, lane), "" if pm.lane_rows(p, lane) == 1 else "s"))
		im.PopID()
	}
	if open_menu do im.OpenPopup("##lanemenu") // (outside the headers' ids: where the menu is drawn)
	launch_lane_menu(a)
	grid := im.Vec2{origin.x, origin.y + head + gap}
	for k in 0 ..< G * G {
		col, r := k % G, k / G
		row := G - 1 - r // (1 at the bottom left, as the pad grid)
		pos := im.Vec2{grid.x + f32(col) * (size + gap), grid.y + f32(row) * (size + gap)}
		im.SetCursorScreenPos(pos)
		slot, lane, lrow, plus := window_cell(a, col, r)
		im.PushIDInt(i32(9000 + k))
		defer im.PopID()
		if lane >= p.lanes.count do continue
		if slot < 0 {
			if !plus do continue
			// The lane's +: a new sequence at its end.
			clicked := im.InvisibleButton("##plus", {size, size})
			ui.name(fmt.tprintf("lane %d plus", lane + 1))
			hot := im.IsItemHovered()
			im.DrawList_AddRect(dl, pos, {pos.x + size, pos.y + size}, ui.col(ui.with_alpha(t.text, 0.16 if hot else 0.06)), t.radius, 1)
			ts := im.CalcTextSize("+")
			im.DrawList_AddText(dl, {pos.x + (size - ts.x) / 2, pos.y + (size - ts.y) / 2}, ui.col(t.text_dim if hot else ui.with_alpha(t.text_dim, 0.4)), "+")
			if hot do im.SetTooltip("%s", fmt.ctprintf("A new sequence at the end of %s", pm.launch_lane_name(p, lane)))
			if clicked {
				if n := pm.new_sequence_in(m, lane); n >= 0 do pm.select_slot(m, n)
				else do ui.toast(&a.ws.toasts, .Warning, "Every sequence is in use (64)")
			}
			seq_drop(a, lane, lrow)
			continue
		}
		used := pm.slot_used(m, slot)
		cs, frac, next, in_beats, queued := pm.column_state(&m.engine, lane)
		playing_here := playing && cs == slot
		queued_here := queued && next == slot
		s := p.sequences[slot]
		if !used && slot != p.slot {
			// Empty: nearly invisible; a + when the mouse is over it.
			clicked := im.InvisibleButton("##empty", {size, size})
			ui.name(fmt.tprintf("launch %d", slot + 1))
			hot := im.IsItemHovered()
			im.DrawList_AddRect(dl, pos, {pos.x + size, pos.y + size}, ui.col(ui.with_alpha(t.text, 0.12 if hot else 0.05)), t.radius, 1)
			if hot {
				ts := im.CalcTextSize("+")
				im.DrawList_AddText(dl, {pos.x + (size - ts.x) / 2, pos.y + (size - ts.y) / 2}, ui.col(t.text_dim), "+")
				im.SetTooltip("%s", fmt.ctprintf("%s (empty): click to make a new sequence here", pm.sequence_name(p, slot)))
			}
			if clicked do pm.select_slot(m, slot)
			seq_drop(a, lane, lrow)
			item_menu(a, seq_target(slot), "##cellmenu")
			continue
		}
		middle := ""
		if queued_here do middle = fmt.tprintf("in %.1f", max(in_beats, 0))
		else if queued && cs == slot && next < 0 do middle = "stops"
		pulse := f32(0.5 + 0.5 * math.cos(math.TAU * tl))
		face := ui.Pad_Face{
			label     = fmt.tprintf("launch %d", slot + 1),
			name      = pm.sequence_name(p, slot),
			middle    = middle,
			tint      = ui.rgb(pm.sequence_color(p, slot)),
			has_sound = true,
			lit       = playing_here || (queued_here && pulse > 0.5),
			selected  = slot == p.slot,
			notes     = seq_minis(a, slot), // (its notes, small, behind)
		}
		hit := ui.pad("##seqpad", face, {size, size})
		shared := pm.shared_lane(p, &pads, slot)
		if im.IsItemHovered() {
			also := fmt.tprintf("\nShares a pad with %s: both play it", pm.launch_lane_name(p, shared)) if shared >= 0 else ""
			im.SetTooltip("%s", fmt.ctprintf("%s · %d bar%s%s · %s%s\nClick: launch it in its lane · Shift-click: launch it alone · Option-click: edit it · Option-drag: move it", pm.sequence_name(p, slot), s.bars, "" if s.bars == 1 else "s", fmt.tprintf(" · %.0f BPM", s.bpm) if s.bpm > 0 else "", pm.launch_lane_name(p, lane), also))
		}
		// Option-drag: to another lane or row.
		if im.GetIO().KeyAlt && im.BeginDragDropSource({.SourceAllowNullID}) {
			x := slot
			im.SetDragDropPayload("PADS_SEQ", &x, size_of(int))
			im.Text("%s", fmt.ctprintf("%s", pm.sequence_name(p, slot)))
			im.EndDragDropSource()
		}
		seq_drop(a, lane, lrow)
		if hit.menu do im.OpenPopup("##cellmenu")
		item_menu(a, seq_target(slot), "##cellmenu")
		if hit.pressed do seq_pad_press(a, slot, false)
		if hit.selected && !hit.menu && im.GetIO().KeyShift do pm.launch_slot(m, slot, alone = true) // (Shift-click: alone)
		if hit.released do seq_pad_release(a, slot)
		// Playing: a bar filling across as it goes round.
		if playing_here do im.DrawList_AddRectFilled(dl, {pos.x + 6, pos.y + size - 7}, {pos.x + 6 + (size - 12) * f32(clamp(frac, 0, 1)), pos.y + size - 4}, ui.col(t.text), 2)
		// A pad another lane plays too: a ring at the top right.
		if shared >= 0 do im.DrawList_AddCircle(dl, {pos.x + size - 9, pos.y + 9}, 4, ui.col(t.warn), 12, 1.5)
	}
	// Each row's scene arrow.
	for row in 0 ..< G {
		r := G - 1 - row // (the bottom row first)
		pos := im.Vec2{grid.x + f32(G) * (size + gap), grid.y + f32(row) * (size + gap) + (size - arrow) / 2}
		im.SetCursorScreenPos(pos)
		im.PushIDInt(i32(9500 + r))
		scene := st.win_row + r
		if ui.icon_button(ui.ICON_PLAY, fmt.ctprintf("Launch scene %d: row %d of every lane together", scene + 1, scene + 1), size = arrow) do pm.launch_scene(m, scene)
		ui.name(fmt.tprintf("scene %d", scene + 1))
		im.PopID()
	}
	// Each lane's stop, and Stop All.
	y := grid.y + f32(G) * (size + gap)
	for col in 0 ..< G {
		lane := st.win_lane + col
		if lane >= p.lanes.count do continue
		cs, _, next, _, queued := pm.column_state(&m.engine, lane)
		im.SetCursorScreenPos({grid.x + f32(col) * (size + gap), y})
		im.PushIDInt(i32(9600 + lane))
		on := cs >= 0 && playing
		stopping := queued && next < 0
		if im.Button(ui.ICON_SQUARE, {size, 0}) do pm.stop_column(&m.engine, lane)
		ui.name(fmt.tprintf("stop lane %d", lane + 1))
		if im.IsItemHovered() do im.SetTooltip("%s", fmt.ctprintf("Stop %s%s", pm.launch_lane_name(p, lane), fmt.tprintf(" (%s)", pm.sequence_name(p, cs)) if on else ""))
		if on || stopping {
			lo, hi := im.GetItemRectMin(), im.GetItemRectMax()
			im.DrawList_AddRect(dl, lo, hi, ui.col(ui.with_alpha(t.warn if stopping else t.accent, 0.7)), t.radius, 1.5)
		}
		im.PopID()
	}
	im.SetCursorScreenPos({grid.x + f32(G) * (size + gap), y})
	if ui.icon_button(ui.ICON_SQUARE_X, "Stop every lane", size = arrow) do pm.stop_all_columns(&m.engine)
	ui.name("stop all")
	// The overview: every lane, its sequences, the window outlined (click
	// to move it there).
	draw_lane_map(a, {grid.x, y + head + gap}, {f32(G) * (size + gap) - gap, map_h})
	im.SetCursorScreenPos({origin.x, y + head + gap + map_h + 4})
	im.Dummy({1, 1})
}

// A sequence Option-dragged here goes to row `row` of lane `lane`.
@(private)
seq_drop :: proc(a: ^App, lane, row: int) {
	if !im.BeginDragDropTarget() do return
	defer im.EndDragDropTarget()
	if pl := im.AcceptDragDropPayload("PADS_SEQ"); pl != nil && pl.DataSize == size_of(int) {
		slot := (^int)(pl.Data)^
		pm.move_sequence(&a.m, slot, lane, row)
	}
}

// The launcher's overview: a column a lane, a cell a sequence (its colour
// if it has anything, bright while it plays), the window outlined; a click
// moves the window there.
@(private)
draw_lane_map :: proc(a: ^App, pos, size: im.Vec2) {
	m := &a.m
	p := &m.project
	st := &a.perf
	t := ui.theme()
	dl := im.GetWindowDrawList()
	rows := max(pm.max_rows(p) + 1, LAUNCH_GRID)
	cw := min(size.x / f32(p.lanes.count), 24)
	ch := min(size.y / f32(rows), 10)
	w, h := cw * f32(p.lanes.count), ch * f32(rows)
	im.SetCursorScreenPos(pos)
	if im.InvisibleButton("##lanemap", {max(w, 1), max(h, 1)}) || (im.IsItemActive() && im.IsMouseDragging(.Left)) {
		mp := im.GetIO().MousePos
		st.win_lane = int((mp.x - pos.x) / cw) - LAUNCH_GRID / 2
		st.win_row = int((pos.y + h - mp.y) / ch) - LAUNCH_GRID / 2
		clamp_window(a)
	}
	ui.name("lane map")
	if im.IsItemHovered() do im.SetTooltip("Every lane: click or drag to move the window there")
	im.DrawList_AddRectFilled(dl, pos, {pos.x + w, pos.y + h}, ui.col(ui.mix(t.inset, t.text, 0.06)), 2)
	im.DrawList_AddRect(dl, pos, {pos.x + w, pos.y + h}, ui.col(ui.with_alpha(t.text, 0.15)), 2)
	_, playing := pm.timeline_beat(&m.engine)
	for lane in 0 ..< p.lanes.count {
		cs, _, _, _, _ := pm.column_state(&m.engine, lane)
		for r in 0 ..< pm.lane_rows(p, lane) {
			slot := pm.lane_slot(p, lane, r)
			if slot < 0 || !pm.slot_used(m, slot) do continue
			x := pos.x + f32(lane) * cw
			y := pos.y + h - f32(r + 1) * ch
			c := ui.rgb(pm.sequence_color(p, slot))
			lit := playing && cs == slot
			im.DrawList_AddRectFilled(dl, {x + 1, y + 1}, {x + cw - 1, y + ch - 1}, ui.col(c if lit else ui.with_alpha(c, 0.5)))
		}
	}
	wx := pos.x + f32(st.win_lane) * cw
	wy := pos.y + h - f32(st.win_row + LAUNCH_GRID) * ch
	im.DrawList_AddRect(dl, {wx, max(wy, pos.y)}, {wx + f32(min(LAUNCH_GRID, p.lanes.count)) * cw, pos.y + h - f32(st.win_row) * ch}, ui.col(t.accent), 2, 1.5)
}

// A lane header's menu: rename, colour, stop, delete.
@(private)
launch_lane_menu :: proc(a: ^App) {
	m := &a.m
	p := &m.project
	st := &a.perf
	if !im.BeginPopup("##lanemenu") {
		st.lane_naming = false
		return
	}
	defer im.EndPopup()
	lane := st.lane_menu
	if lane < 0 || lane >= p.lanes.count {
		im.CloseCurrentPopup()
		return
	}
	im.TextDisabled("%s", fmt.ctprintf("%s", pm.launch_lane_name(p, lane)))
	if !st.lane_naming {
		st.lane_name = {}
		copy(st.lane_name[:len(st.lane_name) - 1], pm.launch_lane_name(p, lane))
		st.lane_naming = true
	}
	im.SetNextItemWidth(160)
	if im.InputText("##lanename", cstring(raw_data(st.lane_name[:])), len(st.lane_name), {.EnterReturnsTrue, .AutoSelectAll}) {
		pm.rename_lane(m, lane, string(cstring(raw_data(st.lane_name[:]))))
		im.CloseCurrentPopup()
	}
	ui.name("lane name")
	if im.IsItemDeactivatedAfterEdit() do pm.rename_lane(m, lane, string(cstring(raw_data(st.lane_name[:]))))
	// Colours: none (its sequences') and the palette.
	for c, i in pm.SEQ_PALETTE {
		if i > 0 do im.SameLine(0, 4)
		im.PushIDInt(i32(i))
		if im.ColorButton("##lanecol", transmute(im.Vec4)ui.rgb(c), {.NoTooltip}, {18, 18}) do pm.color_lane(m, lane, c)
		ui.name(fmt.tprintf("lane colour %d", i + 1))
		im.PopID()
	}
	im.Separator()
	if im.MenuItem(ui.ICON_SQUARE + "  Stop") do pm.stop_column(&m.engine, lane)
	if im.MenuItem(ui.ICON_PLUS + "  New Sequence Here") {
		if n := pm.new_sequence_in(m, lane); n >= 0 do pm.select_slot(m, n)
	}
	if im.MenuItem(ui.ICON_TRASH_2 + "  Delete Lane", nil, false, p.lanes.count > 1) {
		pm.delete_lane(m, lane)
		ui.toast(&a.ws.toasts, .Info, fmt.tprintf("Deleted; its sequences went to %s", pm.launch_lane_name(p, max(lane - 1, 0))))
	}
	ui.name("delete lane")
}

// The colour a performance effect's kind gives its pad: filters violet,
// rhythm (stutters, cutters, gates) teal, pitch and ring mod pink, space
// (delay, reverb, modulation) blue, drive (crush, saturation, distortion)
// coral.
@(private)
fx_kind_color :: proc(k: pm.Effect_Kind) -> ui.Color {
	#partial switch k {
	case .Low_Pass, .High_Pass, .Band_Pass, .Comb, .Filter, .Eq: return ui.rgb(0x7f77dd)
	case .Stutter, .Cutter, .Gate:                                return ui.rgb(0x1d9e75)
	case .Pitch, .Ring_Mod:                                       return ui.rgb(0xd4537e)
	case .Delay, .Reverb, .Chorus, .Flanger, .Phaser:             return ui.rgb(0x378add)
	case .Bitcrush, .Saturation, .Distortion, .Compressor, .Limiter: return ui.rgb(0xd85a30)
	}
	return ui.theme().accent
}

// The performance effects: 16 pads on main, each coloured by its kind,
// on while held (with Hold effects, until pressed again); where it is
// pressed is how hard it plays (the top: all of it), shown as a fill.
// Right-click (or Shift-click) one to edit it.
@(private)
draw_perf_fx :: proc(a: ^App) {
	m := &a.m
	perf_title("Effects")
	avail := im.GetContentRegionAvail()
	gap: f32 = 6
	side := clamp(min((avail.x - 3 * gap) / 4, (avail.y - 3 * gap) / 4), 40, 140)
	origin := im.GetCursorScreenPos()
	for i in 0 ..< pm.PERF_FX {
		row, col := i / 4, i % 4
		im.SetCursorScreenPos({origin.x + f32(col) * (side + gap), origin.y + f32(row) * (side + gap)})
		fx := m.project.perf_fx[i]
		im.PushIDInt(i32(5000 + i))
		hit := ui.pad("fx", {label = fmt.tprintf("fx %d", i + 1), name = pm.perf_label(fx), middle = fmt.tprintf("FX %d", i + 1), tint = fx_kind_color(fx.kind), has_sound = true, lit = fx.on, selected = a.fx == pm.Fx_Target{.Perf, i, 0}}, {side, side})
		im.PopID()
		// Where it is pressed is how hard it plays: the top, all of it.
		lo, hi := im.GetItemRectMin(), im.GetItemRectMax()
		press := 1 - clamp((im.GetIO().MousePos.y - lo.y) / max(hi.y - lo.y, 1), 0, 1)
		press = clamp((press - 0.08) / 0.84, 0, 1) // a margin at each end reaches 0 and 1
		if hit.pressed {
			a.perf_held[i] = true
			if a.perf_hold {
				a.perf_latched[i] = !a.perf_latched[i]
				pm.hold_perf_fx(m, i, a.perf_latched[i], press)
			} else {
				pm.hold_perf_fx(m, i, true, press)
			}
		}
		if hit.held do pm.perf_intensity_live(m, i, press)
		intensity_fill(a, i, lo, hi)
		if hit.released {
			a.perf_held[i] = false
			if !a.perf_hold do pm.hold_perf_fx(m, i, false)
		}
		if hit.selected && !hit.menu do show_device(a, {.Perf, i, 0}) // Shift- or Cmd-click: edit it
		if hit.menu {
			a.perf.menu_fx = i
			im.OpenPopup("##fxmenu")
		}
	}
	if im.BeginPopup("##fxmenu") {
		command_items(a, {kind = .Slot, fx = {.Perf, a.perf.menu_fx, 0}})
		im.EndPopup()
	}
	im.SetCursorScreenPos({origin.x, origin.y + 4 * (side + gap)})
	im.Dummy({1, 1})
}

// Main's level and the cue's (the headphones': Settings sets where it
// plays), each a fader with its meter as in the mixer, their names and
// levels under them on one line.
@(private)
draw_perf_levels :: proc(a: ^App) {
	m := &a.m
	perf_title("Levels")
	avail := im.GetContentRegionAvail()
	line := im.GetTextLineHeightWithSpacing()
	total := max(avail.y - 4, 100)
	h := total - 2 * STRIP_PAD - line - 6
	// Narrow strips, as the mixer's: the two side by side in the column.
	was := strip_w_cur
	strip_w_cur = STRIP_NARROW_W
	defer strip_w_cur = was
	b := m.project.main
	vol := b.volume
	label :: proc(text: cstring) {
		w := inner_w()
		at := im.GetCursorPosX()
		im.SetCursorPosX(at + max((w - im.CalcTextSize(text).x) / 2, 0))
		im.TextDisabled("%s", text)
	}
	top := im.GetCursorScreenPos()
	strip_begin(total, false)
	strip_name = "Main" // (its fader: "Main fader", as in the mixer)
	if e := fader_meter(a, &vol, &a.mixer.buses[pm.BUSES], h); e.changed || e.ended {
		b.volume = vol
		if e.changed do pm.set_bus(m, pm.BUSES, 0, "Main Volume", b)
		if e.ended do app.seal(&m.history)
	}
	label(fmt.ctprintf("Main %.1f", vol))
	strip_end(top, total)
	im.SameLine(0, STRIP_GAP)
	top = im.GetCursorScreenPos()
	strip_begin(total, false)
	cue := a.settings.audio.cue_db
	has_cue := m.engine.outputs.cue >= 0
	strip_name = "Cue"
	if e := fader_meter(a, &cue, &a.mixer.cue, h); e.changed || e.ended {
		if e.changed {
			a.settings.audio.cue_db = clamp(cue, -60, 6)
			outputs_apply(a)
		}
		if e.ended do settings_save(a) // (an app setting, kept with the others)
	}
	if im.IsItemHovered() do im.SetTooltip("%s", fmt.ctprintf("The cue (headphones) level%s", "" if has_cue else ": set a cue output in Settings to hear it"))
	label(fmt.ctprintf("Cue %.1f", cue) if has_cue else "Cue (off)")
	strip_end(top, total)
}

// A combo of step lengths.
@(private)
rate_combo :: proc(id: cstring, rate: ^pf.Rate) -> (changed: bool) {
	if ui.combo(id, RATE_NAMES[rate^]) {
		for r in pf.Rate do if im.Selectable(RATE_NAMES[r], r == rate^) {
			rate^ = r
			changed = true
		}
		im.EndCombo()
	}
	return
}

// A bar of steps at `rate`, the one the playhead is in lit: what note
// repeat or the arpeggiator plays on (bright when it is on).
@(private)
step_strip :: proc(m: ^pm.Model, rate: pf.Rate, on: bool) {
	t := ui.theme()
	step := f64(pf.rate_beats(rate))
	bar := pm.bar_beats(&m.project)
	n := clamp(int(bar / step + 0.5), 1, 48)
	beat, playing := pm.position(&m.engine)
	now := int(math.mod(beat, bar) / step) if playing else -1
	frac := f32(math.mod(beat, step) / step) if playing else 1
	dl := im.GetWindowDrawList()
	pos := im.GetCursorScreenPos()
	w := im.GetContentRegionAvail().x
	h: f32 = 14
	gap: f32 = 2
	cw := (w - gap * f32(n - 1)) / f32(n)
	im.Dummy({w, h})
	ui.name("steps")
	base := t.accent if on else ui.mix(t.raised, t.text, 0.25)
	for k in 0 ..< n {
		x := pos.x + f32(k) * (cw + gap)
		beat_start := math.mod(f64(k) * step, 1) < 1e-6
		c := ui.mix(t.raised, base, 0.35 if beat_start else 0.18)
		if k == now do c = ui.mix(base, ui.rgb(0xffffff), (1 - frac) * 0.5 if on else 0) // a flash that fades through the step
		im.DrawList_AddRectFilled(dl, {x, pos.y}, {x + cw, pos.y + h}, ui.col(c), 2)
	}
}

// A performance effect's pad's intensity: a fill from the bottom to how
// hard it plays now (bright while on), and a mark at its own intensity.
@(private)
intensity_fill :: proc(a: ^App, i: int, lo, hi: im.Vec2) {
	t := ui.theme()
	m := &a.m
	on := m.project.perf_fx[i].on
	own := m.project.perf_intensity[i]
	now := m.engine.perf_live[i] if on && m.engine.perf_live[i] >= 0 else own
	dl := im.GetWindowDrawList()
	h := hi.y - lo.y
	y := hi.y - h * (0.08 + 0.84 * now)
	c := ui.with_alpha(ui.rgb(0xffffff), 0.28 if on else 0.1)
	im.DrawList_AddRectFilled(dl, {lo.x + 2, y}, {hi.x - 2, hi.y - 2}, ui.col(c), 4)
	oy := hi.y - h * (0.08 + 0.84 * own)
	im.DrawList_AddLine(dl, {lo.x + 6, oy}, {lo.x + 18, oy}, ui.col(ui.with_alpha(t.text, 0.6)), 2)
}

// A sequence pad held in Hold: its lane, when it was pressed, and
// whether it has been let go (it goes once its launch has come: a press
// shorter than the launch quantize still plays).
Seq_Hold :: struct {
	slot:     int,
	col:      int,
	order:    u64,
	released: bool,
}

// A sequence pad pressed (or its key): launched in its column (a
// Shift-click launches it alone: see `draw_launcher`), or (Hold) played while held,
// remembering what its column played to come back to (several held: the
// latest plays, and letting go of it goes back to the one before).
// Option-click only goes to a sequence (to edit it), stopped.
seq_pad_press :: proc(a: ^App, slot: int, from_key: bool) {
	m := &a.m
	st := &a.perf
	_, playing := pm.position(&m.engine)
	io := im.GetIO()
	if !from_key && io.KeyAlt {
		if !playing do pm.select_slot(m, slot) // (Option: go to it, not start it)
		return
	}
	if m.project.launch_hold {
		col := pm.launch_col(&m.project, slot)
		first := true
		for h in st.holds do if h.col == col do first = false
		if first && col >= 0 && col < pm.MAX_LANES {
			cs, _, next, _, queued := pm.column_state(&m.engine, col)
			st.hold_from[col] = (next if queued else cs) if playing else -1
		}
		for h, k in st.holds do if h.slot == slot { // (pressed again before it went: held again)
			ordered_remove(&st.holds, k)
			break
		}
		st.hold_order += 1
		append(&st.holds, Seq_Hold{slot = slot, col = col, order = st.hold_order})
	}
	pm.launch_slot(m, slot)
}

// A sequence pad let go: in Hold, it goes when its launch has come (see
// `hold_frame`).
seq_pad_release :: proc(a: ^App, slot: int) {
	for &h in a.perf.holds do if h.slot == slot do h.released = true
}

// Each frame, in Hold: a held pad let go goes once its lane plays it (or
// at once, stopped); its lane then plays the latest pad still held there,
// or, none, what it played before the first (or stops).
hold_frame :: proc(a: ^App) {
	st := &a.perf
	m := &a.m
	if len(st.holds) == 0 do return
	_, playing := pm.position(&m.engine)
	for k := 0; k < len(st.holds); {
		h := st.holds[k]
		if !h.released {
			k += 1
			continue
		}
		if playing && h.col >= 0 {
			cs, _, next, _, queued := pm.column_state(&m.engine, h.col)
			if queued && next == h.slot && cs != h.slot { // (its launch hasn't come yet: it plays first)
				k += 1
				continue
			}
		}
		ordered_remove(&st.holds, k)
		if h.col < 0 || h.col >= pm.MAX_LANES do continue
		latest := -1
		at: u64
		for o in st.holds do if o.col == h.col && o.order > at do latest, at = o.slot, o.order
		if latest >= 0 {
			if latest != h.slot do pm.launch_slot(m, latest) // (back to the one held before it)
		} else if st.hold_from[h.col] >= 0 && st.hold_from[h.col] != h.slot {
			pm.launch_slot(m, st.hold_from[h.col])
		} else if st.hold_from[h.col] < 0 {
			pm.stop_column(&m.engine, h.col)
		}
	}
}

// How the pads play: each its sound, a keyboard of the selected one, or
// it at 16 velocities. Held pads let go first.
set_play_mode :: proc(a: ^App, mode: pm.Play_Mode) {
	if a.play_mode == mode do return
	for k in 0 ..< pm.PADS_PER_BANK do release(a, a.bank * pm.PADS_PER_BANK + k)
	// Keyboard mode's banks run up the scale from the lowest note: it opens
	// on the one holding the pad's own; leaving it, the pads' bank again.
	if mode == .Keyboard {
		a.pads_bank = a.bank
		a.play_mode = mode
		a.bank = keyboard_home_bank(a)
		return
	}
	if a.play_mode == .Keyboard do a.bank = a.pads_bank
	a.play_mode = mode
}
