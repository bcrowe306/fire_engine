package ui

import "core:math"
import "core:strings"

import im "deps:imgui"

// A note editor with tools: rows (named, at the left) of notes over beats.
// It never changes the notes: it says what the user did (`Grid_Edit`) and
// the caller makes edits of it. Rows are counted from the bottom.

// What a drag on the grid does.
Grid_Tool :: enum u8 {
	Select, // click a note to select it (Shift adds), drag on empty space to box-select, drag a note to move the selection, its end to resize; double-click empty space to add
	Draw,   // click to add a note, drag along a row to paint one on each step; click a note to delete it
	Erase,  // click or sweep across notes to delete them
	Move,   // drag moves the selection (a note not in it is selected first); Alt copies
}

// What the user did this frame.
Grid_Edit :: struct {
	row_click:  int, // a row's name clicked (its row), or -1
	row_double: bool, // ... twice
	row_menu:   int, // a row's name right-clicked, or -1
	add:        bool, // add a note at `at_beat` (snapped, its start), row `at_row`
	at_beat:    f64,
	at_row:     int,
	erase:      int,  // a note to delete (its index), or -1
	select:     int,  // a note clicked (its index), or -1
	select_add: bool, // ... with Shift: add it to (or take it from) the selection
	select_none: bool, // empty space clicked: nothing selected
	box:        bool, // a box being dragged: select what it touches (`box_add`: add to the selection)
	box_add:    bool,
	box_beat0, box_beat1: f64,
	box_row0, box_row1:   int,
	moving:     bool, // the selection being dragged by `move_beats` and `move_rows`
	move_beats: f64,
	move_rows:  int,
	copy:       bool, // ... with Alt: a copy
	resizing:   bool, // the selection's ends being dragged by `resize_beats`
	resize_beats: f64,
	released:   bool, // a move or resize ended: commit it
	menu:       int,  // a note right-clicked (its index), or -1
	menu_empty: bool, // empty space right-clicked (at `at_beat`, `at_row`)
}

// A note editor `size` big: `rows` (their names at the left, clickable),
// `notes` on them (`Roll_Note.key` is the row), the view's rows and beats,
// positions snapped to `snap` beats, a playhead, the `tool` the mouse is.
// Names its parts for the probe: "<id>" (the grid) and "<id> row N".
note_grid :: proc(id: cstring, notes: []Roll_Note, rows: []Roll_Row, view: ^Roll_View, snap: f64, size: im.Vec2, tool: Grid_Tool, playhead: f64 = -1, bar: f64 = 4) -> (e: Grid_Edit) {
	im.PushID(id)
	defer im.PopID()
	e.row_click, e.row_menu, e.erase, e.select, e.menu = -1, -1, -1, -1, -1
	t := current
	dl := im.GetWindowDrawList()
	pos := im.GetCursorScreenPos()
	io := im.GetIO()
	names_w := roll_rows_width(rows)
	grid := im.Vec2{pos.x + names_w, pos.y}
	gw := size.x - names_w
	nk := max(view.keys, 1)
	row_h := size.y / f32(nk)
	beat_w := gw / f32(max(view.beats, 1e-6))
	to_beat :: proc(x: f32, grid: im.Vec2, beat_w: f32, view: ^Roll_View) -> f64 { return view.beat0 + f64((x - grid.x) / beat_w) }
	to_row :: proc(y: f32, grid: im.Vec2, row_h: f32, size: im.Vec2, view: ^Roll_View) -> int { return view.key0 + int(math.floor((grid.y + size.y - y) / row_h)) }
	snap_down :: proc(b, snap: f64) -> f64 { return math.floor(b / snap + 1e-9) * snap if snap > 0 else b }
	snap_near :: proc(b, snap: f64) -> f64 { return math.round(b / snap) * snap if snap > 0 else b }
	y_of :: proc(row: int, grid: im.Vec2, row_h: f32, size: im.Vec2, view: ^Roll_View) -> f32 { return grid.y + size.y - f32(row - view.key0 + 1) * row_h }

	// The row names: click, double-click, right-click.
	for k in 0 ..< nk {
		row := view.key0 + k
		if row < 0 || row >= len(rows) do continue
		y := y_of(row, grid, row_h, size, view)
		im.SetCursorScreenPos({pos.x, y})
		im.PushIDInt(i32(row))
		clicked := im.InvisibleButton("##row", {names_w, max(row_h, 1)}, {.MouseButtonLeft, .MouseButtonRight})
		name(strings.concatenate({string(id), " row ", itoa(row)}, context.temp_allocator))
		hovered := im.IsItemHovered()
		if clicked && !im.IsMouseReleased(.Right) do e.row_click = row
		if hovered && im.IsMouseDoubleClicked(.Left) do e.row_click, e.row_double = row, true
		if hovered && im.IsMouseClicked(.Right) do e.row_menu = row
		r := rows[row]
		c := r.color if r.color != {} else t.accent
		bg := t.raised if k % 2 == 0 else mix(t.raised, t.bg, 0.3)
		if hovered do bg = mix(bg, t.text, 0.08)
		im.DrawList_AddRectFilled(dl, {pos.x, y}, {pos.x + names_w - 2, y + row_h}, col(bg))
		im.DrawList_AddRectFilled(dl, {pos.x, y + 1}, {pos.x + 4, y + row_h - 1}, col(c), 2)
		nc := strings.clone_to_cstring(r.name, context.temp_allocator)
		fs := min(im.GetFontSize(), row_h * 0.78)
		if fs >= 9 do im.DrawList_AddTextFontPtr(dl, im.GetFont(), fs, {pos.x + 4 + t.pad.x, y + (row_h - fs * 1.2) / 2 + 1}, col(t.text if hovered else t.text_dim), nc)
		im.PopID()
	}

	// The grid.
	im.SetCursorScreenPos(grid)
	im.InvisibleButton("##grid", {gw, size.y}, {.MouseButtonLeft, .MouseButtonRight})
	name(string(id))
	hovered := im.IsItemHovered()
	m := io.MousePos
	hit, edge := -1, false
	for n, i in notes {
		x0 := grid.x + f32(n.start - view.beat0) * beat_w
		x1 := max(x0 + f32(n.length) * beat_w, x0 + 6)
		y0 := y_of(n.key, grid, row_h, size, view)
		if m.x >= x0 && m.x <= x1 && m.y >= y0 && m.y < y0 + row_h {
			hit = i
			edge = m.x > x1 - 6 && (tool == .Select || tool == .Move)
		}
	}
	at_beat := to_beat(m.x, grid, beat_w, view)
	at_row := to_row(m.y, grid, row_h, size, view)
	if hovered {
		switch tool {
		case .Select: if edge do im.SetMouseCursor(.ResizeEW)
		case .Draw:   im.SetMouseCursor(.Hand)
		case .Erase:  im.SetMouseCursor(.NotAllowed)
		case .Move:   im.SetMouseCursor(.ResizeAll)
		}
	}
	if hovered && im.IsMouseClicked(.Right) {
		if hit >= 0 do e.menu = hit
		else do e.menu_empty, e.at_beat, e.at_row = true, snap_down(at_beat, snap), at_row
	}

	// One gesture at a time, from the press to the release.
	Gesture :: enum u8 { None, Box, Move, Resize, Paint, Sweep }
	@(static) g: Gesture
	@(static) from: [2]f64 // where it started (beat, row)
	@(static) last_cell: [2]f64 // painting: the last cell added
	if im.IsItemActivated() && im.IsMouseClicked(.Left) {
		from = {at_beat, f64(at_row)}
		g = .None
		switch tool {
		case .Select:
			if hit >= 0 {
				if !notes[hit].selected || io.KeyShift do e.select, e.select_add = hit, io.KeyShift
				g = .Resize if edge else .Move
			} else if im.IsMouseDoubleClicked(.Left) {
				e.add, e.at_beat, e.at_row = true, max(snap_down(at_beat, snap), 0), at_row
			} else {
				g = .Box
				if !io.KeyShift do e.select_none = true
			}
		case .Draw:
			if hit >= 0 {
				e.erase = hit
			} else {
				e.add, e.at_beat, e.at_row = true, max(snap_down(at_beat, snap), 0), at_row
				g, last_cell = .Paint, {e.at_beat, f64(at_row)}
			}
		case .Erase:
			g = .Sweep
			if hit >= 0 do e.erase = hit
		case .Move:
			if hit >= 0 && !notes[hit].selected do e.select = hit
			g = .Move if hit >= 0 || any_selected(notes) else .None
		}
	}
	box_rect: [4]f32 // a box being dragged, drawn over the notes
	active := im.IsItemActive() || im.IsItemDeactivated()
	if active do switch g {
	case .None:
	case .Box:
		lo, hi := min(from[0], at_beat), max(from[0], at_beat)
		r0, r1 := min(int(from[1]), at_row), max(int(from[1]), at_row)
		e.box, e.box_add = true, io.KeyShift
		e.box_beat0, e.box_beat1, e.box_row0, e.box_row1 = lo, hi, r0, r1
		x0 := grid.x + f32(lo - view.beat0) * beat_w
		x1 := grid.x + f32(hi - view.beat0) * beat_w
		y0 := y_of(r1, grid, row_h, size, view)
		y1 := y_of(r0, grid, row_h, size, view) + row_h
		box_rect = {x0, y0, x1, y1}
	case .Move:
		e.moving = true
		e.move_beats = snap_near(at_beat - from[0], snap)
		e.move_rows = at_row - int(from[1])
		e.copy = io.KeyAlt
	case .Resize:
		e.resizing = true
		e.resize_beats = snap_near(at_beat - from[0], snap)
	case .Paint:
		cell := [2]f64{max(snap_down(at_beat, snap), 0), f64(int(from[1]))} // along the row it started on
		if cell != last_cell && at_beat >= 0 {
			free := true
			for n in notes do if n.key == int(cell[1]) && cell[0] >= n.start - 1e-9 && cell[0] < n.start + n.length - 1e-9 do free = false
			if free do e.add, e.at_beat, e.at_row = true, cell[0], int(cell[1])
			last_cell = cell
		}
	case .Sweep:
		if hit >= 0 do e.erase = hit
	}
	if im.IsItemDeactivated() {
		e.released = g == .Move || g == .Resize
		g = .None
	}
	if hovered && io.MouseWheel != 0 {
		if io.KeyShift do view.beat0 = max(view.beat0 - f64(io.MouseWheel) * view.beats * 0.1, 0)
		else do view.key0 = clamp(view.key0 + int(io.MouseWheel * 2), 0, max(len(rows) - view.keys, 0))
	}

	// Draw: rows, grid lines, notes (the selection where it is going),
	// the playhead.
	for k in 0 ..< nk {
		y := grid.y + size.y - f32(k + 1) * row_h
		im.DrawList_AddRectFilled(dl, {grid.x, y}, {grid.x + gw, y + row_h}, col(t.raised if k % 2 == 0 else mix(t.raised, t.bg, 0.3)))
	}
	if snap > 0 && f32(snap) * beat_w >= 10 {
		for b := math.floor(view.beat0 / snap) * snap; b <= view.beat0 + view.beats; b += snap {
			x := grid.x + f32(b - view.beat0) * beat_w
			im.DrawList_AddLine(dl, {x, grid.y}, {x, grid.y + size.y}, col(with_alpha(t.text, 0.035)), 1)
		}
	}
	for b := math.floor(view.beat0); b <= view.beat0 + view.beats; b += 1 {
		x := grid.x + f32(b - view.beat0) * beat_w
		strong := bar > 0 && math.mod(b, bar) < 1e-6
		im.DrawList_AddLine(dl, {x, grid.y}, {x, grid.y + size.y}, col(with_alpha(t.text, 0.18 if strong else 0.07)), 1)
	}
	im.DrawList_PushClipRect(dl, grid, {grid.x + gw, grid.y + size.y}, true)
	for n, i in notes {
		start, row, length := n.start, n.key, n.length
		ghost := false
		if n.selected && e.moving {
			if e.copy do ghost = true // the original stays where it is
			else do start, row = start + e.move_beats, row + e.move_rows
		}
		if n.selected && e.resizing do length = max(length + e.resize_beats, snap if snap > 0 else 1.0 / 64)
		draw_note :: proc(dl: ^im.DrawList, n: Roll_Note, start, length: f64, row: int, grid: im.Vec2, beat_w, row_h: f32, size: im.Vec2, view: ^Roll_View, hot: bool, t: Theme, alpha: f32 = 1) {
			x0 := grid.x + f32(start - view.beat0) * beat_w
			x1 := max(x0 + f32(length) * beat_w, x0 + 6)
			y0 := grid.y + size.y - f32(row - view.key0 + 1) * row_h
			base := n.color if n.color != {} else t.accent
			c := mix(base, t.text, 0.15) if n.selected || hot else base
			c = with_alpha(c, (0.45 + 0.55 * n.velocity) * alpha)
			im.DrawList_AddRectFilled(dl, {x0 + 1, y0 + 1}, {x1 - 1, y0 + row_h - 1}, col(c), 3)
			if n.selected do im.DrawList_AddRect(dl, {x0 + 1, y0 + 1}, {x1 - 1, y0 + row_h - 1}, col(with_alpha(t.text, alpha)), 3, 1.5)
		}
		draw_note(dl, n, n.start if ghost else start, length, n.key if ghost else row, grid, beat_w, row_h, size, view, i == hit, t)
		if ghost do draw_note(dl, n, start + e.move_beats, length, row + e.move_rows, grid, beat_w, row_h, size, view, false, t, 0.6)
	}
	if box_rect != {} {
		im.DrawList_AddRectFilled(dl, {box_rect[0], box_rect[1]}, {box_rect[2], box_rect[3]}, col(with_alpha(t.accent, 0.14)), 3)
		im.DrawList_AddRect(dl, {box_rect[0], box_rect[1]}, {box_rect[2], box_rect[3]}, col(with_alpha(t.accent, 0.8)), 3, 1.5)
	}
	// Erasing: the note under the mouse, crossed.
	if tool == .Erase && hovered && hit >= 0 {
		n := notes[hit]
		x0 := grid.x + f32(n.start - view.beat0) * beat_w
		x1 := max(x0 + f32(n.length) * beat_w, x0 + 6)
		y0 := y_of(n.key, grid, row_h, size, view)
		im.DrawList_AddLine(dl, {x0 + 2, y0 + 2}, {x1 - 2, y0 + row_h - 2}, col(t.danger), 2)
	}
	if playhead >= view.beat0 {
		x := grid.x + f32(playhead - view.beat0) * beat_w
		im.DrawList_AddLine(dl, {x, grid.y}, {x, grid.y + size.y}, col(t.warn), 2)
	}
	im.DrawList_PopClipRect(dl)
	im.SetCursorScreenPos({pos.x, pos.y + size.y})
	im.Dummy({size.x, 0})
	return
}

@(private)
any_selected :: proc(notes: []Roll_Note) -> bool {
	for n in notes do if n.selected do return true
	return false
}
