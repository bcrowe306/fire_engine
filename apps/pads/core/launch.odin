package pads_core

import pm "../model"

// The Perform tab's live state, the window's and a controller's alike
// (one of each: what one shows or holds, the other does): the launcher's
// window, the sequence pads held in Hold, the effects held or latched.
Launch_Live :: struct {
	win_lane, win_row: int,  // the launcher's window: its first lane and row (LAUNCH_GRID of each)
	seq_keys:   bool,        // the computer's pad keys play the window's sequence pads (Keys)
	fx_latch:   bool,        // a press turns an effect on until the next (Hold effects)
	fx_held:    [pm.PERF_FX]bool,
	fx_latched: [pm.PERF_FX]bool,
	fx_last:    int,         // the effect pressed last (a controller's knob sets its strength)
	holds:      [dynamic]Seq_Hold, // the sequence pads held in Hold (and let go, until their launch has come)
	hold_from:  [pm.MAX_LANES]int, // what each lane played before its first held pad (-1: nothing; to go back to)
	hold_order: u64,         // counts presses (the latest held pad of a lane is the one it plays)
}

// A sequence pad held in Hold.
Seq_Hold :: struct {
	slot:     int,
	col:      int,
	order:    u64,
	released: bool,
}

// Cells the launcher's window is across and up (a pad controller's 4 x 4).
LAUNCH_GRID :: 4

// Keeps the launcher's window over the lanes and rows there are (one row
// past the longest lane: its +).
launch_window_clamp :: proc(c: ^Core) {
	p := &c.m.project
	l := &c.launch
	l.win_lane = clamp(l.win_lane, 0, max(p.lanes.count - LAUNCH_GRID, 0))
	l.win_row = clamp(l.win_row, 0, max(pm.max_rows(p) + 1 - LAUNCH_GRID, 0))
}

// A sequence pad pressed: launched in its lane (`alone`: the others stop),
// or (Hold) played while held, remembering what its lane played to come
// back to (several held: the latest plays; letting it go, the one before).
launch_press :: proc(c: ^Core, slot: int, alone := false) {
	m := &c.m
	l := &c.launch
	_, playing := pm.position(&m.engine)
	if m.project.launch_hold && !alone {
		col := pm.launch_col(&m.project, slot)
		first := true
		for h in l.holds do if h.col == col do first = false
		if first && col >= 0 && col < pm.MAX_LANES {
			cs, _, next, _, queued := pm.column_state(&m.engine, col)
			l.hold_from[col] = (next if queued else cs) if playing else -1
		}
		for h, k in l.holds do if h.slot == slot { // (pressed again before it went: held again)
			ordered_remove(&l.holds, k)
			break
		}
		l.hold_order += 1
		append(&l.holds, Seq_Hold{slot = slot, col = col, order = l.hold_order})
	}
	pm.launch_slot(m, slot, alone)
}

// A sequence pad let go: in Hold, it goes when its launch has come (see
// `launch_frame`).
launch_release :: proc(c: ^Core, slot: int) {
	for &h in c.launch.holds do if h.slot == slot do h.released = true
}

// Each frame, in Hold: a held pad let go goes once its lane plays it (or
// at once, stopped); its lane then plays the latest pad still held there,
// or, none, what it played before the first (or stops).
launch_frame :: proc(c: ^Core) {
	l := &c.launch
	m := &c.m
	if len(l.holds) == 0 do return
	_, playing := pm.position(&m.engine)
	for k := 0; k < len(l.holds); {
		h := l.holds[k]
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
		ordered_remove(&l.holds, k)
		if h.col < 0 || h.col >= pm.MAX_LANES do continue
		latest := -1
		at: u64
		for o in l.holds do if o.col == h.col && o.order > at do latest, at = o.slot, o.order
		if latest >= 0 {
			if latest != h.slot do pm.launch_slot(m, latest, false) // (back to the one held before it)
		} else if l.hold_from[h.col] >= 0 && l.hold_from[h.col] != h.slot {
			pm.launch_slot(m, l.hold_from[h.col], false)
		} else if l.hold_from[h.col] < 0 {
			pm.stop_column(&m.engine, h.col)
		}
	}
}

// Performance effect `i`'s pad pressed (`on`, at `intensity`: -1 its own)
// or let go: held while held, or (latching) on until the next press.
fx_press :: proc(c: ^Core, i: int, on: bool, intensity: f32 = -1) {
	if i < 0 || i >= pm.PERF_FX do return
	l := &c.launch
	if on {
		l.fx_held[i] = true
		l.fx_last = i
		if l.fx_latch {
			l.fx_latched[i] = !l.fx_latched[i]
			pm.hold_perf_fx(&c.m, i, l.fx_latched[i], intensity)
		} else {
			pm.hold_perf_fx(&c.m, i, true, intensity)
		}
		return
	}
	l.fx_held[i] = false
	if !l.fx_latch do pm.hold_perf_fx(&c.m, i, false)
}

// How hard effect `i` plays while its pad is held (0..1: where it's
// pressed, or how hard), as the press moves.
fx_pressure :: proc(c: ^Core, i: int, intensity: f32) {
	if i < 0 || i >= pm.PERF_FX || !(c.launch.fx_held[i] || c.launch.fx_latched[i]) do return
	pm.perf_intensity_live(&c.m, i, clamp(intensity, 0, 1))
}

// Effects latch (a press turns one on until the next) or not; off, the
// latched ones not held go off.
fx_set_latch :: proc(c: ^Core, on: bool) {
	l := &c.launch
	l.fx_latch = on
	if on do return
	for i in 0 ..< pm.PERF_FX do if l.fx_latched[i] {
		l.fx_latched[i] = false
		if !l.fx_held[i] do pm.hold_perf_fx(&c.m, i, false)
	}
}

// Lets the Perform tab's live state go.
launch_destroy :: proc(c: ^Core) {
	delete(c.launch.holds)
	c.launch.holds = nil
}
