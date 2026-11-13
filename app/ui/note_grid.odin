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
	row_drop:   int,    // a drag-and-drop payload of `drop_type` let go on a row (its name or its notes), or -1
	dropped:    string, // ... the payload (temporary allocator)
}

// A note editor `size` big: `rows` (their names at the left, clickable),
// `notes` on them (`Roll_Note.key` is the row), the view's rows and beats,
// positions snapped to `snap` beats, a playhead, the `tool` the mouse is.
// Names its parts for the probe: "<id>" (the grid) and "<id> row N". With
// a `drop_type`, a drag-and-drop payload of it over a row (its name or
// along it) lights the row, and let go comes back as `row_drop`.
note_grid :: proc(id: cstring, notes: []Roll_Note, rows: []Roll_Row, view: ^Roll_View, snap: f64, size: im.Vec2, tool: Grid_Tool, playhead: f64 = -1, bar: f64 = 4, drop_type: cstring = nil) -> (e: Grid_Edit) {
	im.PushID(id)
	defer im.PopID()
	e.row_click, e.row_menu, e.erase, e.select, e.menu, e.row_drop = -1, -1, -1, -1, -1, -1
	// A drop on a row: its name, or anywhere along it in the grid.
	drop_row := -1 // the row a drag is over (lit)
	take_drop :: proc(e: ^Grid_Edit, drop_type: cstring, row: int, drop_row: ^int) {
		if drop_type == nil || !im.BeginDragDropTarget() do return
		defer im.EndDragDropTarget()
		if pl := im.AcceptDragDropPayload(drop_type, {.AcceptBeforeDelivery, .AcceptNoDrawDefaultRect}); pl != nil {
			drop_row^ = row
			if pl.Delivery {
				e.row_drop = row
				e.dropped = strings.clone(strings.string_from_ptr((^u8)(pl.Data), int(pl.DataSize)), context.temp_allocator)
			}
		}
	}
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
		take_drop(&e, drop_type, row, &drop_row)
		r := rows[row]
		c := r.color if r.color != {} else t.accent
		bg := t.raised if k % 2 == 0 else mix(t.raised, t.bg, 0.3)
		if hovered do bg = mix(bg, t.text, 0.08)
		lit := clamp(r.lit, 0, 1)
		if lit > 0 do bg = mix(bg, r.lit_color if r.lit_color != {} else c, 0.55 * lit) // (played now: lit in its colour)
		im.DrawList_AddRectFilled(dl, {pos.x, y}, {pos.x + names_w - 2, y + row_h}, col(bg))
		im.DrawList_AddRectFilled(dl, {pos.x, y + 1}, {pos.x + 4, y + row_h - 1}, col(c), 2)
		nc := strings.clone_to_cstring(r.name, context.temp_allocator)
		fs := min(im.GetFontSize(), row_h * 0.78)
		if fs >= 9 do im.DrawList_AddTextFontPtr(dl, im.GetFont(), fs, {pos.x + 4 + t.pad.x, y + (row_h - fs * 1.2) / 2 + 1}, col(t.text if hovered || lit > 0.3 else t.text_dim), nc)
		im.PopID()
	}

	// The grid.
	im.SetCursorScreenPos(grid)
	im.InvisibleButton("##grid", {gw, size.y}, {.MouseButtonLeft, .MouseButtonRight})
	name(string(id))
	take_drop(&e, drop_type, to_row(im.GetIO().MousePos.y, grid, row_h, size, view), &drop_row)
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
		// Played now: its lane lit faintly in its colour.
		if row := view.key0 + k; row >= 0 && row < len(rows) && rows[row].lit > 0 {
			c := rows[row].lit_color if rows[row].lit_color != {} else (rows[row].color if rows[row].color != {} else t.accent)
			im.DrawList_AddRectFilled(dl, {grid.x, y}, {grid.x + gw, y + row_h}, col(with_alpha(c, 0.16 * clamp(rows[row].lit, 0, 1))))
		}
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
			if n.muted {
				// Hollow, with a faint fill: there, but silent.
				im.DrawList_AddRectFilled(dl, {x0 + 1, y0 + 1}, {x1 - 1, y0 + row_h - 1}, col(with_alpha(c, 0.12 * alpha)), 3)
				im.DrawList_AddRect(dl, {x0 + 1.5, y0 + 1.5}, {x1 - 1.5, y0 + row_h - 1.5}, col(with_alpha(c, 0.7 * alpha)), 3, 1.5)
			} else {
				c = with_alpha(c, (0.45 + 0.55 * n.velocity) * alpha)
				im.DrawList_AddRectFilled(dl, {x0 + 1, y0 + 1}, {x1 - 1, y0 + row_h - 1}, col(c), 3)
			}
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
	// A drag over a row: the whole row lit, where it will land.
	if drop_row >= view.key0 && drop_row < view.key0 + nk && drop_row < len(rows) {
		y := y_of(drop_row, grid, row_h, size, view)
		im.DrawList_AddRectFilled(dl, {pos.x, y}, {grid.x + gw, y + row_h}, col(with_alpha(t.accent, 0.18)), 3)
		im.DrawList_AddRect(dl, {pos.x, y}, {grid.x + gw, y + row_h}, col(t.accent), 3, 2)
	}
	im.SetCursorScreenPos({pos.x, pos.y + size.y})
	im.Dummy({size.x, 0})
	return
}

@(private)
any_selected :: proc(notes: []Roll_Note) -> bool {
	for n in notes do if n.selected do return true
	return false
}

// One breakpoint of an `auto_lane`: where, how high (0..1), and how the
// segment to the next one bends (0 a line, -1..1 as clip's Curve tension).
Auto_Lane_Point :: struct {
	beat:  f64,
	value: f32,
	curve: f32,
}

// The tools of a full automation view (`auto_lane`'s `tool`): Select
// clicks a point in where there is none and drags one; Draw draws
// freehand (Shift: a straight line); Line drags a straight line; Curve
// drags a segment up or down to bend it; Erase sweeps points away. Ctrl
// bends a segment with any of them.
Auto_Tool :: enum u8 {
	Select,
	Draw,
	Line,
	Curve,
	Erase,
}

// A note drawn grey under an automation's curve, for timing: from `beat`
// for `length`, between `y0` and `y1` (0 the top, 1 the bottom).
Ghost_Note :: struct {
	beat, length: f64,
	y0, y1:       f32,
}

// What the user did to an automation lane this frame.
Auto_Lane_Edit :: struct {
	add:      bool, // a point at `at` (Select: a click on empty space)
	at:       Auto_Lane_Point,
	moving:   int,  // a point dragged (index), or -1; to `to`
	to:       Auto_Lane_Point,
	released: bool, // a drag, a stroke or a bend ended
	stroke:   []Auto_Lane_Point, // drawn (Draw): replace the points from its first beat to its last with these
	bend:     int,  // the segment from point `bend` bent to `curve` (Ctrl-drag), or -1
	curve:    f32,
	erase:    int,  // a point to delete (a click with Erase), or -1
	swept:    bool, // Erase swept across beats `swept_lo`..`swept_hi` (done): delete the points there
	swept_lo, swept_hi: f64,
	menu:     int,  // a point right-clicked, or -1
	hover:    int,  // the point under the mouse, or -1
}

// The value an automation lane has at `beat`: as its points join (lines,
// or curves bent as the engine bends them).
auto_lane_value :: proc(points: []Auto_Lane_Point, beat: f64) -> f32 {
	if len(points) == 0 do return 0
	if beat <= points[0].beat do return points[0].value
	for k in 1 ..< len(points) {
		a, b := points[k - 1], points[k]
		if beat > b.beat do continue
		span := b.beat - a.beat
		if span <= 0 do return b.value
		x := (beat - a.beat) / span
		if abs(a.curve) > 1e-6 {
			kk := 8 * f64(a.curve)
			x = (math.exp(kk * x) - 1) / (math.exp(kk) - 1)
		}
		return a.value + (b.value - a.value) * f32(x)
	}
	return points[len(points) - 1].value
}

// An automation lane `size` big across `beats` beats from `beat0`, edited
// with `tool`: Select (click adds a point, drag moves one), Draw (drag
// draws freehand, Shift-drag a straight line, each replacing what was
// under it), Erase (click or sweep removes points); with any, Ctrl-drag a
// segment to bend it. `now` (a beat, or -1) marks where it plays, with a
// dot at its value.
auto_lane :: proc(id: cstring, points: []Auto_Lane_Point, beat0, beats: f64, snap: f64, size: im.Vec2, tool: Auto_Tool, tint: Color = {}, now: f64 = -1, ghosts: []Ghost_Note = nil) -> (e: Auto_Lane_Edit) {
	im.PushID(id)
	defer im.PopID()
	e.moving, e.bend, e.erase, e.menu, e.hover = -1, -1, -1, -1, -1
	t := current
	color := tint if tint != {} else t.accent
	dl := im.GetWindowDrawList()
	pos := im.GetCursorScreenPos()
	io := im.GetIO()
	im.InvisibleButton("##lane", size, {.MouseButtonLeft, .MouseButtonRight})
	name(widget_name(id, "lane"))
	hovered := im.IsItemHovered()
	bw := size.x / f32(max(beats, 1e-6))
	sx :: proc(b: f64, pos: im.Vec2, beat0: f64, bw: f32) -> f32 { return pos.x + f32(b - beat0) * bw }
	sy :: proc(v: f32, pos, size: im.Vec2) -> f32 { return pos.y + 4 + (1 - v) * (size.y - 8) }
	m := io.MousePos
	mb := beat0 + f64((m.x - pos.x) / bw)
	mv := clamp(1 - (m.y - pos.y - 4) / (size.y - 8), 0, 1)
	snapped :: proc(b, snap: f64) -> f64 { return math.round(b / snap) * snap if snap > 0 else b }
	hit := -1
	for p, i in points {
		dx, dy := m.x - sx(p.beat, pos, beat0, bw), m.y - sy(p.value, pos, size)
		if dx * dx + dy * dy < 64 do hit = i
	}
	seg := -1 // the segment under the mouse
	for k in 1 ..< len(points) do if mb >= points[k - 1].beat && mb < points[k].beat do seg = k - 1
	if hovered && im.IsMouseClicked(.Right) && hit >= 0 do e.menu = hit
	if hovered do e.hover = hit

	Gesture :: enum u8 { None, Move, Draw, Line, Bend, Sweep }
	@(static) g: Gesture
	@(static) drag, bend_seg: int
	@(static) start: [2]f32 // where it started: beat, value
	@(static) bend0: f32
	@(static) sweep: [2]f64 // the beats Erase has crossed
	@(static) stroke: [dynamic]Auto_Lane_Point
	// Ctrl-drag bends: macOS makes Ctrl+click a right click, so a right
	// button pressed with Ctrl starts one too.
	right_bend := im.IsMouseClicked(.Right) && ctrl_down() && seg >= 0 && hit < 0
	if im.IsItemActivated() && (im.IsMouseClicked(.Left) || right_bend) {
		g = .None
		start = {f32(mb), mv}
		clear(&stroke)
		if (ctrl_down() || tool == .Curve) && seg >= 0 && hit < 0 {
			g, bend_seg, bend0 = .Bend, seg, points[seg].curve
		} else {
			switch tool {
			case .Select, .Curve:
				if hit >= 0 {
					g, drag = .Move, hit
				} else if tool == .Select {
					e.add, e.at = true, {max(snapped(mb, snap), 0), mv, 0}
				}
			case .Draw, .Line:
				g = .Line if io.KeyShift || tool == .Line else .Draw
				append(&stroke, Auto_Lane_Point{max(snapped(mb, snap), 0), mv, 0})
			case .Erase:
				g = .Sweep
				sweep = {mb, mb}
				if hit >= 0 do sweep = {points[hit].beat, points[hit].beat}
			}
		}
	}
	if im.IsItemActive() || im.IsItemDeactivated() do switch g {
	case .None:
	case .Move:
		e.moving, e.to = drag, {max(snapped(mb, snap), 0), mv, points[drag].curve if drag < len(points) else 0}
	case .Draw: // a point each grid step (or 1/32 free), the latest kept
		step := snap if snap > 0 else 0.125
		b := max(math.round(mb / step) * step, 0)
		last := &stroke[len(stroke) - 1]
		if abs(b - last.beat) < 1e-9 do last.value = mv
		else if b > last.beat do append(&stroke, Auto_Lane_Point{b, mv, 0})
	case .Line:
		if len(stroke) == 1 do append(&stroke, Auto_Lane_Point{})
		stroke[1] = {max(snapped(mb, snap), 0), mv, 0}
	case .Bend:
		// Up bends it in: Ctrl-drag sets the tension by how far.
		dir: f32 = 1 if bend_seg + 1 < len(points) && points[bend_seg + 1].value >= points[bend_seg].value else -1
		e.bend, e.curve = bend_seg, clamp(bend0 + dir * (start[1] - mv) * 2.5, -1, 1)
	case .Sweep: // every point in the columns crossed, whatever its value
		sweep = {min(sweep[0], mb), max(sweep[1], mb)}
	}
	if im.IsItemDeactivated() {
		e.released = true
		if g == .Draw || g == .Line {
			s := stroke[:]
			if g == .Line && len(s) == 2 && s[1].beat < s[0].beat do s[0], s[1] = s[1], s[0]
			e.stroke = s
		}
		if g == .Sweep {
			tol := f64(6 / bw)
			e.swept, e.swept_lo, e.swept_hi = true, sweep[0] - tol, sweep[1] + tol
		}
		g = .None
	}

	// The lane: its line (curved as it plays), the points, a stroke being
	// drawn, and now: a line and a dot at its value.
	im.DrawList_AddRectFilled(dl, pos, {pos.x + size.x, pos.y + size.y}, col(PLOT_BG), t.radius)
	for k in 1 ..< 4 do im.DrawList_AddLine(dl, {pos.x, pos.y + size.y * f32(k) / 4}, {pos.x + size.x, pos.y + size.y * f32(k) / 4}, col(mix(PLOT_BG, t.text, 0.07)), 1)
	// The notes underneath, grey, for timing only.
	ghost := col(mix(PLOT_BG, t.text, 0.13))
	for n in ghosts {
		x0, x1 := sx(n.beat, pos, beat0, bw), sx(n.beat + n.length, pos, beat0, bw)
		if x1 < pos.x || x0 > pos.x + size.x do continue
		y0, y1 := pos.y + n.y0 * size.y, pos.y + n.y1 * size.y
		im.DrawList_AddRectFilled(dl, {max(x0, pos.x) + 1, y0}, {min(x1, pos.x + size.x) - 1, max(y1, y0 + 2)}, ghost, 2)
	}
	shown := make([dynamic]Auto_Lane_Point, 0, len(points), context.temp_allocator)
	append(&shown, ..points)
	if e.moving >= 0 && e.moving < len(shown) do shown[e.moving] = e.to
	if e.bend >= 0 && e.bend < len(shown) do shown[e.bend].curve = e.curve
	if g == .Sweep { // the swept points already gone
		tol := f64(6 / bw)
		n := 0
		for x in shown do if x.beat < sweep[0] - tol || x.beat > sweep[1] + tol { shown[n] = x; n += 1 }
		resize(&shown, n)
		lo, hi := sx(sweep[0], pos, beat0, bw) - 6, sx(sweep[1], pos, beat0, bw) + 6
		im.DrawList_AddRectFilled(dl, {lo, pos.y}, {hi, pos.y + size.y}, col(with_alpha(t.danger, 0.12)))
	}
	if len(shown) > 0 {
		pts := make([dynamic]im.Vec2, 0, 256, context.temp_allocator)
		append(&pts, im.Vec2{pos.x, sy(shown[0].value, pos, size)})
		N :: 160
		for k in 0 ..= N {
			b := beat0 + beats * f64(k) / N
			append(&pts, im.Vec2{sx(b, pos, beat0, bw), sy(auto_lane_value(shown[:], b), pos, size)})
		}
		fill := color
		fill.a = 0.16
		for k in 1 ..< len(pts) do im.DrawList_AddQuadFilled(dl, {pts[k - 1].x, pos.y + size.y}, pts[k - 1], pts[k], {pts[k].x, pos.y + size.y}, col(fill))
		im.DrawList_AddPolyline(dl, &pts[0], i32(len(pts)), col(color), 2)
		for p, i in shown {
			c := im.Vec2{sx(p.beat, pos, beat0, bw), sy(p.value, pos, size)}
			on := i == hit || i == e.moving
			im.DrawList_AddCircleFilled(dl, c, 5 if on else 3.5, col(t.text if on else lighten(color, 0.3)), 12)
		}
		if seg >= 0 && ctrl_down() && hovered do im.SetMouseCursor(.ResizeNS)
	}
	if len(stroke) > 1 && (g == .Draw || g == .Line) {
		sp := make([]im.Vec2, len(stroke), context.temp_allocator)
		for p, k in stroke do sp[k] = {sx(p.beat, pos, beat0, bw), sy(p.value, pos, size)}
		im.DrawList_AddPolyline(dl, &sp[0], i32(len(sp)), col(t.warn), 2)
	}
	if now >= beat0 && now <= beat0 + beats && len(shown) > 0 {
		x := sx(now, pos, beat0, bw)
		v := auto_lane_value(shown[:], now)
		im.DrawList_AddLine(dl, {x, pos.y}, {x, pos.y + size.y}, col(with_alpha(t.warn, 0.7)), 1.5)
		im.DrawList_AddCircleFilled(dl, {x, sy(v, pos, size)}, 7, col(Color{color.r, color.g, color.b, 0.3}), 16)
		im.DrawList_AddCircleFilled(dl, {x, sy(v, pos, size)}, 4, col(lighten(color, 0.5)), 16)
	}
	return
}

// Whether the Control key itself is held (ImGui reports Cmd as Ctrl on
// macOS, where it swaps them).
ctrl_down :: proc() -> bool {
	io := im.GetIO()
	return io.KeySuper if io.ConfigMacOSXBehaviors else io.KeyCtrl
}

// Whether the key that places notes and points off the grid is held: Cmd
// on macOS, Alt elsewhere (Ctrl bends automation).
free_down :: proc() -> bool {
	io := im.GetIO()
	return io.KeyCtrl if io.ConfigMacOSXBehaviors else io.KeyAlt
}

// The name of the key `free_down` reads: "Cmd" or "Alt".
FREE_KEY :: "Cmd" when ODIN_OS == .Darwin else "Alt"
