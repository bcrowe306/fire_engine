package ui

import im "deps:imgui"

// How a flex row places its items along its width, as CSS's
// justify-content: packed at the start, centred, packed at the end, or
// spread with the space shared between them.
Flex_Justify :: enum u8 {
	Start,
	Center,
	End,
	Between,
}

// The most items a flex row lays out (more are drawn after the last, not
// placed).
FLEX_MAX :: 32

// A row laid out like a CSS flex row: its items one after another with a
// gap, each centred in the row's height, the whole justified across the
// row's width. An item is whatever is drawn between two `flex_next` calls
// (a button, or a group of them on one line). Immediate mode can't know a
// size before drawing, so each item is placed by its size last frame:
// keep the struct between frames (the first frame is placed from the
// start, then everything settles).
Flex :: struct {
	justify: Flex_Justify,
	gap:     f32, // between items (an item's own `flex_next(gap)` overrides the one before it)
	sizes:   [FLEX_MAX]im.Vec2, // each item's size last frame
	gaps:    [FLEX_MAX]f32,     // the gap before each item last frame
	count:   int,               // items last frame
	// This frame:
	origin:  im.Vec2,
	size:    im.Vec2,
	at:      int,  // the item being drawn (-1: none yet)
	x:       f32,  // where the next item starts
	open:    bool, // an item's group is open
	spare:   f32,  // the room Between shares out, per gap
}

// Starts a flex row at the cursor, `size` across and tall (a size of 0
// takes the room left there).
flex_begin :: proc(f: ^Flex, size: im.Vec2 = {}) {
	f.origin = im.GetCursorScreenPos()
	avail := im.GetContentRegionAvail()
	f.size = {size.x if size.x > 0 else avail.x, size.y if size.y > 0 else im.GetFrameHeight()}
	total: f32 = 0
	for k in 0 ..< f.count do total += f.sizes[k].x + (f.gaps[k] if k > 0 else 0)
	f.spare = 0
	switch f.justify {
	case .Start:   f.x = 0
	case .Center:  f.x = max((f.size.x - total) / 2, 0)
	case .End:     f.x = max(f.size.x - total, 0)
	case .Between:
		f.x = 0
		if f.count > 1 do f.spare = max(f.size.x - total, 0) / f32(f.count - 1)
	}
	f.at, f.open = -1, false
}

// Ends the item being drawn (if any) and starts the next, `gap` after it
// (< 0: the row's gap): the cursor goes where it belongs, centred in the
// row's height by its size last frame.
flex_next :: proc(f: ^Flex, gap: f32 = -1) {
	flex_close(f)
	f.at += 1
	if f.at >= FLEX_MAX do return
	g := f.gap if gap < 0 else gap
	f.gaps[f.at] = g
	if f.at > 0 do f.x += g + f.spare
	h := f.sizes[f.at].y if f.at < f.count else 0
	im.SetCursorScreenPos({f.origin.x + f.x, f.origin.y + max((f.size.y - h) / 2, 0)})
	im.BeginGroup()
	f.open = true
}

// Ends the row: the last item measured, the cursor under the row.
flex_end :: proc(f: ^Flex) {
	flex_close(f)
	f.count = min(f.at + 1, FLEX_MAX)
	im.SetCursorScreenPos({f.origin.x, f.origin.y + f.size.y})
	im.Dummy({0, 0})
}

// How wide the row's items came out last frame, gaps included.
flex_width :: proc(f: ^Flex) -> f32 {
	total: f32 = 0
	for k in 0 ..< f.count do total += f.sizes[k].x + (f.gaps[k] if k > 0 else 0)
	return total
}

@(private)
flex_close :: proc(f: ^Flex) {
	if !f.open do return
	im.EndGroup()
	f.open = false
	if f.at < FLEX_MAX {
		mn, mx := im.GetItemRectMin(), im.GetItemRectMax()
		f.sizes[f.at] = {mx.x - mn.x, mx.y - mn.y}
		f.x += f.sizes[f.at].x
	}
}
