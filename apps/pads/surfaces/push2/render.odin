package pads_push2

import "core:fmt"
import "core:os"
import "core:time"

import kit "fsurf:surface"

/*
The pads' lights, all from one place. A grid (grid.odin: Pads, Sequences,
Keys) never sends a light: it is a stack of layers, each drawing over a
frame what it shows now (the pads' colours, then the selected one, a pad
flashing as it sounds, a held one...). The renderer draws the shown grid's
frame every RENDER_MS and sends the Push 2 only what changed:

- **Colours** get palette slots by colour (SLOT_FIRST..SLOT_LAST), the
  least recently shown one reused; a slot is written (Set LED Color Palette
  Entry, then Reapply) a few a render, and a pad waits for its slot before
  it lights. A slot a pad still shows is never rewritten under it.
- **Lights** (a note-on: the pad's palette index) go out when they differ
  from what the Push was last sent.
- **Repair:** every light is sent again each REPAIR_LIGHTS_MS, every slot
  in use each REPAIR_SLOTS_MS (a message the Push dropped is mended).
- **Trace:** PADS_PUSH2_TRACE=1 logs every light and slot sent (Pads' log).

While no grid has the pads (Layout's drums: the kit lights them), nothing
is sent; a grid taking them again draws all 64.
*/

// What one pad shows.
Cell :: struct {
	kind:     Cell_Kind,
	colour:   u32, // .Colour: 0xRRGGBB
	index:    u8,  // .Index: a palette index of the hello's (WHITE, GREEN...)
	fallback: u8,  // .Colour with no slot free: this index instead
}

Cell_Kind :: enum u8 {
	Off,
	Colour,
	Index,
}

// The 64 pads' cells, 0 at the bottom left along each row (grid_index).
Frame :: [64]Cell

// A layer: draws what it shows now over the frame (the layers before it
// under it).
Layer :: proc(g: ^Grid, f: ^Frame)

// A pad in a colour (the renderer finds it a slot; none free: `fallback`).
cell_colour :: proc(rgb: u32, fallback: u8 = DIM_WHITE) -> Cell { return {kind = .Colour, colour = rgb & 0xFFFFFF, fallback = fallback} }

// A pad lit with a palette index of the hello's.
cell_index :: proc(index: u8) -> Cell { return {kind = .Index, index = index} }

// The palette slots the pads' colours get.
SLOT_FIRST :: 27
SLOT_LAST :: 99
SLOTS :: SLOT_LAST - SLOT_FIRST + 1

// How often the frame is drawn, and how often everything is sent again.
RENDER_MS :: 15
REPAIR_LIGHTS_MS :: 1000
REPAIR_SLOTS_MS :: 4000

// Slots written a render at most (the Push 2 drops a burst of SysEx).
PALETTE_BURST :: 8

Renderer :: struct {
	grid:        ^Grid, // the grid shown (nil: another has the pads)
	controls:    [64]^kit.Control,
	slot_rgb:    [SLOTS]u32,
	slot_known:  [SLOTS]bool, // the Push holds it (written since the hello)
	slot_seen:   [SLOTS]u64,  // the render it was last wanted in (the least recent reused first)
	shown:       [64]u8,      // each pad's palette index, as last sent
	shown_rgb:   [64]u32,     // ... and its colour (the virtual controller's)
	shown_known: [64]bool,
	renders:     u64,
	now:         time.Tick, // this render's time
	lights_at:   time.Tick, // when every light was last sent again
	slots_at:    time.Tick, // ... every slot
	trace:       bool,
}

@(private)
render_setup :: proc(cs: ^kit.Control_Surface, p: ^Push2, pads: ^kit.Matrix) -> ^kit.Component {
	r := &p.render
	for c in pads.controls do r.controls[grid_index(c)] = c
	r.trace = os.get_env("PADS_PUSH2_TRACE", context.temp_allocator) == "1"
	c := kit.component_make(cs, "Pad Renderer")
	c.on_activate = proc(c: ^kit.Component) {
		p := (^Push2)(c.cs.user)
		render_forget(&p.render, slots = true) // (the hello set the palette)
		kit.task_every(c.cs, RENDER_MS, proc(data: rawptr) { render((^Push2)(data)) }, p, c)
	}
	return c
}

// Forgets what the Push shows (its lights; `slots`: its palette too): the
// next render sends it all.
render_forget :: proc(r: ^Renderer, slots := false) {
	r.shown_known = {}
	if slots do r.slot_known = {}
}

// The grid `g` has the pads now (nil: none of them).
render_show :: proc(p: ^Push2, g: ^Grid) {
	r := &p.render
	if r.grid == g do return
	r.grid = g
	render_forget(r) // (another drew the pads meanwhile, or nothing yet)
	if g != nil do render(p)
}

// Draws the shown grid's frame and sends the Push what changed.
render :: proc(p: ^Push2) {
	r := &p.render
	g := r.grid
	if g == nil || !g.active do return
	cs := g.cs
	r.renders += 1
	r.now = time.tick_now()
	if time.tick_diff(r.lights_at, r.now) >= REPAIR_LIGHTS_MS * time.Millisecond {
		r.lights_at = r.now
		r.shown_known = {}
	}
	if time.tick_diff(r.slots_at, r.now) >= REPAIR_SLOTS_MS * time.Millisecond {
		r.slots_at = r.now
		r.slot_known = {}
	}
	frame: Frame
	for layer in g.layers do layer(g, &frame)
	// Each pad's palette index: a colour's slot (found, or one given it).
	want: [64]u8
	rgb: [64]u32
	ready: [64]bool
	held_by_shown: [SLOTS]bool // (a slot a pad shows now: not rewritten under it)
	for i in 0 ..< 64 do if r.shown_known[i] && slot_of(r.shown[i]) >= 0 do held_by_shown[slot_of(r.shown[i])] = true
	for cell, i in frame {
		ready[i] = true
		switch cell.kind {
		case .Off:
		case .Index:
			want[i] = cell.index
			rgb[i] = index_rgb(cell.index)
		case .Colour:
			s := slot_find(r, cell.colour, held_by_shown)
			if s < 0 {
				want[i] = cell.fallback
				rgb[i] = index_rgb(cell.fallback)
				continue
			}
			r.slot_seen[s] = r.renders
			want[i] = u8(SLOT_FIRST + s)
			rgb[i] = cell.colour
			ready[i] = r.slot_known[s]
		}
	}
	// The lights first (a pad waiting for its slot keeps what it shows).
	for i in 0 ..< 64 {
		if !ready[i] || (r.shown_known[i] && r.shown[i] == want[i] && r.shown_rgb[i] == rgb[i]) do continue
		c := r.controls[i]
		if c == nil do continue
		kit.light_reset(c)
		kit.light_value(c, want[i])
		c.has_rgb = true
		c.rgb = rgb[i]
		r.shown[i], r.shown_rgb[i], r.shown_known[i] = want[i], rgb[i], true
		if r.trace do kit.log(cs, fmt.tprintf("push2 pads: %d (note %d) light %d #%06x", i, 36 + i, want[i], rgb[i]))
	}
	// Then the slots wanted and not written, a few a render.
	sent := 0
	for s in 0 ..< SLOTS {
		if r.slot_known[s] || r.slot_seen[s] != r.renders do continue
		if sent == PALETTE_BURST do break
		e := palette_entry(u8(SLOT_FIRST + s), r.slot_rgb[s], 0)
		kit.send(cs, e[:])
		r.slot_known[s] = true
		sent += 1
		if r.trace do kit.log(cs, fmt.tprintf("push2 pads: slot %d = #%06x", SLOT_FIRST + s, r.slot_rgb[s]))
	}
	if sent > 0 do kit.send(cs, reapply[:])
}

// The slot holding `rgb` (written or to be), else the least recently
// wanted one not wanted this render and not shown now, given `rgb`; -1:
// none free.
@(private)
slot_find :: proc(r: ^Renderer, rgb: u32, held_by_shown: [SLOTS]bool) -> int {
	for s in 0 ..< SLOTS do if r.slot_rgb[s] == rgb && (r.slot_known[s] || r.slot_seen[s] != 0) do return s
	best := -1
	for s in 0 ..< SLOTS {
		if r.slot_seen[s] == r.renders || (held_by_shown[s] && r.slot_rgb[s] != rgb) do continue
		if best < 0 || r.slot_seen[s] < r.slot_seen[best] do best = s
	}
	if best >= 0 {
		r.slot_rgb[best] = rgb
		r.slot_known[best] = false
	}
	return best
}

// The slot a palette index is (-1: not one).
@(private)
slot_of :: proc(index: u8) -> int {
	return int(index) - SLOT_FIRST if index >= SLOT_FIRST && index <= SLOT_LAST else -1
}

// A hello palette index's colour (the virtual controller's).
@(private)
index_rgb :: proc(index: u8) -> u32 {
	for e in PALETTE do if e.index == index do return e.rgb
	return 0
}

// A colour `f` as bright (0..1).
scale :: proc(c: u32, f: f32) -> u32 {
	ch :: proc(x: u32, f: f32) -> u32 { return u32(clamp(f32(x) * f, 0, 255)) }
	return ch(c >> 16 & 0xFF, f) << 16 | ch(c >> 8 & 0xFF, f) << 8 | ch(c & 0xFF, f)
}
