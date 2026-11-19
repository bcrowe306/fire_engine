// The MIDI effects' and plug-ins' pictures: each draws into a size it's
// given at the cursor, from plain values, so a controller's display and
// Pads' window can both use them.
//
// - MIDI effects: one bar of the notes the effect shown makes, on the beat
//   grid with the playhead: note repeat's hits (one a step of its Rate,
//   Gate long); the arpeggiator's notes as a roll (its pattern up, down,
//   both ways, random or as played, over its octaves) from the notes the
//   pad last heard, or a demo chord before any.
// - Plug-ins: the plug-in's name and vendor (an instrument: its pad's
//   letter and name first, in its colour), a map of its banks (the one
//   shown lit, each with a tick a parameter), and the parameter whose
//   encoder is touched (or was last) large, with its value as the plug-in
//   reads it and where it is in its range.
package pads

import "core:fmt"
import "core:math"
import "core:strings"

import "app:ui"
import im "deps:imgui"

// The grids note repeat and the arpeggiator step by (pa.Grid's first
// seven), and their names.
@(private)
MP_RATE_BEATS := [?]f64{1, 0.5, 1.0 / 3, 0.25, 1.0 / 6, 0.125, 1.0 / 12}
@(private)
MP_RATE_NAMES := [?]string{"1/4", "1/8", "1/8 T", "1/16", "1/16 T", "1/32", "1/32 T"}
// How the arpeggiator walks the notes (pa.Arp_Mode).
@(private)
MP_ARP_MODES := [?]string{"Up", "Down", "Up & Down", "Random", "As played"}

// --- the parts ---------------------------------------------------------------------------------

// A picture's frame at the cursor, `size` big (an item named `id`).
@(private = "file")
mp_frame :: proc(id: string, size: im.Vec2) -> (dl: ^im.DrawList, r0, r1: im.Vec2) {
	dl = im.GetWindowDrawList()
	r0 = im.GetCursorScreenPos()
	im.Dummy(size)
	ui.name(id)
	r1 = {r0.x + size.x, r0.y + size.y}
	im.DrawList_AddRectFilled(dl, r0, r1, ui.col(ui.PLOT_BG), ui.theme().radius)
	return
}

// Words on a picture at `at` (`right`: ending there), on a backing so they
// read over what's drawn: `name` bright, `rest` dimmer. Its width.
@(private = "file")
mp_caption :: proc(dl: ^im.DrawList, at: im.Vec2, name, rest: string, right := false) -> f32 {
	th := ui.theme()
	ui.text_push(.Label)
	defer ui.text_pop()
	cn := fmt.ctprintf("%s", name)
	cr := fmt.ctprintf("%s", rest)
	wn := im.CalcTextSize(cn).x if name != "" else 0
	wr := im.CalcTextSize(cr).x if rest != "" else 0
	gap: f32 = 8 if name != "" && rest != "" else 0
	w := wn + gap + wr
	x := at.x - w if right else at.x
	lh := im.GetTextLineHeight()
	im.DrawList_AddRectFilled(dl, {x - 4, at.y - 1}, {x + w + 4, at.y + lh + 1}, ui.col(ui.with_alpha(ui.PLOT_BG, 0.8)), 3)
	if name != "" do im.DrawList_AddText(dl, {x, at.y}, ui.col(ui.with_alpha(th.text, 0.92)), cn)
	if rest != "" do im.DrawList_AddText(dl, {x + wn + gap, at.y}, ui.col(ui.with_alpha(th.text, 0.62)), cr)
	return w
}

// Text at `at` in `size` (and `font`: nil, the current one), `color`,
// clipped at `x1`. Its width.
@(private = "file")
mp_text :: proc(dl: ^im.DrawList, at: im.Vec2, text: string, color: ui.Color, size: ui.Text_Size, x1: f32, font: ^im.Font = nil) -> f32 {
	im.PushFontFloat(font, ui.TEXT_SIZE[size])
	defer im.PopFont()
	c := fmt.ctprintf("%s", text)
	ts := im.CalcTextSize(c)
	im.DrawList_PushClipRect(dl, {at.x, at.y - 2}, {x1, at.y + ts.y + 2}, true)
	im.DrawList_AddText(dl, at, ui.col(color), c)
	im.DrawList_PopClipRect(dl)
	return ts.x
}

// The beat grid of a bar from `x0` to `x1` (`top` to `bottom`): sixteenths
// faint, beats brighter, each beat's number at `ny` where no caption is
// (`free0` .. `free1`).
@(private = "file")
mp_beats :: proc(dl: ^im.DrawList, bar: f64, x0, x1, top, bottom, ny, free0, free1: f32) {
	th := ui.theme()
	ui.text_push(.Caption)
	defer ui.text_pop()
	n := int(math.ceil(bar * 4))
	for k in 0 ..= n {
		b := f64(k) / 4
		if b > bar + 1e-6 do break
		x := x0 + (x1 - x0) * f32(b / bar)
		whole := k % 4 == 0
		im.DrawList_AddLine(dl, {x, top}, {x, bottom}, ui.col(ui.mix(ui.PLOT_BG, th.text, 0.22 if whole else 0.07)), 1)
		if whole && b < bar - 1e-6 && x + 3 > free0 && x + 12 < free1 {
			im.DrawList_AddText(dl, {x + 3, ny}, ui.col(ui.mix(ui.PLOT_BG, th.text, 0.5)), fmt.ctprintf("%d", k / 4 + 1))
		}
	}
}

// The playhead at `x`, `top` to `bottom`: a line with a cap.
@(private = "file")
mp_playhead :: proc(dl: ^im.DrawList, x, top, bottom: f32, playing: bool) {
	th := ui.theme()
	c := ui.col(th.text if playing else ui.with_alpha(th.text, 0.45))
	im.DrawList_AddLine(dl, {x, top}, {x, bottom}, c, 1.5)
	im.DrawList_AddTriangleFilled(dl, {x - 4, top - 1}, {x + 4, top - 1}, {x, top + 4}, c)
}

// Where the transport is, as read at the top right.
@(private = "file")
mp_where :: proc(g: Rhy_Grid) -> string {
	if g.playing do return fmt.tprintf("Bar %d · beat %d  ·  %.0f BPM", g.bar_no, int(g.now) + 1, g.bpm)
	return fmt.tprintf("Stopped  ·  %.0f BPM", g.bpm)
}

// --- MIDI effects ------------------------------------------------------------------------------

// What the MIDI effects' picture shows: the effect on the bank shown.
@(private)
Mp_Midi_Picture :: struct {
	arp:     bool,   // the arpeggiator's notes (else note repeat's hits)
	on:      bool,   // the effect shown is on
	instead: string, // why another plays in its place ("": it plays)
	rate:    int,    // its rate (MP_RATE_BEATS)
	gate:    f32,    // 0.05..1 of a step
	mode:    int,    // the arpeggiator's (MP_ARP_MODES)
	octaves: int,    // 1..4
	latch:   bool,
	notes:   []int,  // the notes it walks (semitones from the pad's own), as played
	source:  string, // where they come from ("held", "last played", "a demo chord")
	grid:    Rhy_Grid,
	color:   ui.Color, // the pad's
}

// The arpeggiator's notes over `steps` steps, as it walks `notes` (as
// played) in `mode` over `octaves` (as fire:perform's Arp does: sorted
// low to high but As played; Up & Down plays its ends once; Random from
// its default seed).
@(private)
mp_arp_pattern :: proc(notes: []int, mode, octaves, steps: int) -> []int {
	out := make([]int, max(steps, 0), context.temp_allocator)
	n := len(notes)
	if n == 0 do return out[:0]
	sorted := make([]int, n, context.temp_allocator)
	copy(sorted, notes)
	if mode != 4 do for i in 1 ..< n do for j := i; j > 0 && sorted[j - 1] > sorted[j]; j -= 1 do sorted[j - 1], sorted[j] = sorted[j], sorted[j - 1]
	span := n * clamp(octaves, 1, 4)
	rng: u64 = 0x2545F4914F6CDD1D
	for s in 0 ..< steps {
		index: int
		switch mode {
		case 1: index = span - 1 - s % span
		case 2:
			cycle := max(2 * span - 2, 1)
			k := s % cycle
			index = k if k < span else cycle - k
		case 3:
			x := rng
			x ~= x >> 12
			x ~= x << 25
			x ~= x >> 27
			rng = x
			index = int((x * 0x2545F4914F6CDD1D) >> 33) % span
		case: index = s % span
		}
		out[s] = sorted[index % n] + 12 * (index / n)
	}
	return out
}

// The MIDI effects, `size` big at the cursor.
@(private)
mp_midi_picture :: proc(pic: Mp_Midi_Picture, size: im.Vec2) {
	th := ui.theme()
	dl, r0, r1 := mp_frame("midi fx picture", size)
	g := pic.grid
	bar := max(g.bar, 0.25)
	x0, x1 := r0.x + 8, r1.x - 8
	top, bottom := r0.y + 20, r1.y - 5
	lit := pic.on && pic.instead == ""
	color := pic.color if lit else ui.mix(ui.PLOT_BG, pic.color, 0.45)
	rate := clamp(pic.rate, 0, len(MP_RATE_BEATS) - 1)
	step := MP_RATE_BEATS[rate]
	gate := f64(clamp(pic.gate, 0.05, 1))
	xb :: proc(x0, x1: f32, bar, b: f64) -> f32 { return x0 + (x1 - x0) * f32(clamp(b / bar, 0, 1)) }
	// The caption, the transport, the grid under them.
	name := "Arpeggiator" if pic.arp else "Note repeat"
	if !pic.on do name = fmt.tprintf("%s (off)", name)
	rest: string
	if pic.arp {
		rest = fmt.tprintf("%s · %d octave%s · %s · gate %.0f %%%s · %d note%s %s", MP_ARP_MODES[clamp(pic.mode, 0, len(MP_ARP_MODES) - 1)], pic.octaves, "" if pic.octaves == 1 else "s",
			MP_RATE_NAMES[rate], gate * 100, " · latch" if pic.latch else "", len(pic.notes), "" if len(pic.notes) == 1 else "s", pic.source)
	} else {
		rest = fmt.tprintf("%s · gate %.0f %% · while a pad is held", MP_RATE_NAMES[rate], gate * 100)
	}
	if pic.instead != "" do rest = fmt.tprintf("%s  ·  %s", rest, pic.instead)
	cw := mp_caption(dl, {r0.x + 10, r0.y + 3}, name, rest)
	ww := mp_caption(dl, {r1.x - 10, r0.y + 3}, "", mp_where(g), right = true)
	mp_beats(dl, bar, x0, x1, top, bottom, r0.y + 5, r0.x + 10 + cw + 8, r1.x - 10 - ww - 8)
	steps := min(int(math.ceil(bar / step - 1e-6)), 256)
	now_step := int(g.now / step)
	if !pic.arp {
		// Note repeat: a hit a step, Gate long, as tall as the lane.
		for k in 0 ..< steps {
			b0 := f64(k) * step
			ha, hb := xb(x0, x1, bar, b0), xb(x0, x1, bar, b0 + step * gate)
			c := color
			switch {
			case k == now_step && g.playing && lit: c = ui.mix(color, th.text, 0.5)
			case b0 > g.now:                        c = ui.mix(ui.PLOT_BG, color, 0.7)
			}
			im.DrawList_AddRectFilled(dl, {ha, top + 4}, {max(hb - 1, ha + 2), bottom}, ui.col(c), 2)
		}
	} else {
		// The arpeggiator: its notes as a roll, the octaves it climbs marked.
		pattern := mp_arp_pattern(pic.notes, pic.mode, pic.octaves, steps)
		lo, hi := max(int), min(int)
		for x in pattern do lo, hi = min(lo, x), max(hi, x)
		if len(pattern) > 0 {
			rows := f32(hi - lo + 1)
			h := bottom - top - 6
			nh := clamp(h / rows, 3, 7)
			yp :: proc(top, h, rows: f32, lo, x: int) -> f32 { return top + 3 + h - (f32(x - lo) + 0.5) / rows * h }
			// The octaves above the lowest note (where the pattern climbs).
			for o in 1 ..< clamp(pic.octaves, 1, 4) {
				y := yp(top, h, rows, lo, lo + 12 * o) + nh / 2 + 1
				if y < top + 2 do break
				im.DrawList_AddLine(dl, {x0, y}, {x1, y}, ui.col(ui.with_alpha(color, 0.25)), 1)
			}
			for x, k in pattern {
				b0 := f64(k) * step
				ha, hb := xb(x0, x1, bar, b0), xb(x0, x1, bar, b0 + step * gate)
				y := yp(top, h, rows, lo, x)
				c := color
				switch {
				case k == now_step && g.playing && lit: c = ui.mix(color, th.text, 0.5)
				case b0 > g.now:                        c = ui.mix(ui.PLOT_BG, color, 0.7)
				}
				im.DrawList_AddRectFilled(dl, {ha, y - nh / 2}, {max(hb - 1, ha + 2), y + nh / 2}, ui.col(c), 1.5)
			}
		}
	}
	mp_playhead(dl, xb(x0, x1, bar, g.now), top, bottom, g.playing)
}

// --- plug-ins ----------------------------------------------------------------------------------

// A bank on a plug-in's map: its name and how many parameters it holds.
@(private)
Mp_Plugin_Bank :: struct {
	name:  string,
	count: int,
}

// What a plug-in's picture shows.
@(private)
Mp_Plugin_Picture :: struct {
	name, vendor, version: string,
	pad:       string,   // an instrument: its pad's letter and name ("": an effect)
	pad_color: ui.Color,
	off:       bool,     // an effect slot turned off
	params:    int,      // parameters shown
	banks:     []Mp_Plugin_Bank,
	bank:      int,      // the one shown
	knob:      string,   // the parameter turned ("": none yet)
	value:     string,   // as the plug-in reads it
	frac:      f32,      // where it is in its range, 0..1
	turning:   bool,     // its encoder touched now (else the last one turned)
	bold:      ^im.Font, // (nil: the current font)
	color:     ui.Color,
}

// A plug-in, `size` big at the cursor.
@(private)
mp_plugin_picture :: proc(pic: Mp_Plugin_Picture, size: im.Vec2) {
	th := ui.theme()
	dl, r0, r1 := mp_frame("plugin picture", size)
	dim := ui.with_alpha(th.text, 0.6)
	// Who it is (an instrument: its pad first).
	lx, lx1 := r0.x + 12, r0.x + 300
	y := r0.y + 5
	if pic.pad != "" {
		mp_text(dl, {lx, y}, pic.pad, pic.pad_color, .Heading, lx1, pic.bold)
		y += 24
		// (The plug-in's name, unless the pad is named for it.)
		w: f32 = -8
		if !strings.has_suffix(pic.pad, pic.name) do w = mp_text(dl, {lx, y}, pic.name, th.text, .Body, lx1)
		who := pic.vendor
		if pic.version != "" do who = fmt.tprintf("%s · %s", who, pic.version) if who != "" else pic.version
		mp_text(dl, {lx + w + 8, y + (2 if w > 0 else 0)}, who, dim, .Label if w > 0 else .Body, lx1)
		y += 19
	} else {
		name := pic.name if !pic.off else fmt.tprintf("%s (off)", pic.name)
		mp_text(dl, {lx, y}, name, th.text if !pic.off else dim, .Heading, lx1, pic.bold)
		y += 24
		who := pic.vendor
		if pic.version != "" do who = fmt.tprintf("%s · %s", who, pic.version) if who != "" else pic.version
		mp_text(dl, {lx, y}, who, dim, .Body, lx1)
		y += 19
	}
	mp_text(dl, {lx, y}, fmt.tprintf("%d parameter%s · %d bank%s", pic.params, "" if pic.params == 1 else "s", len(pic.banks), "" if len(pic.banks) == 1 else "s"), ui.with_alpha(th.text, 0.45), .Caption, lx1)
	// The banks' map: a cell each, its name and a tick a parameter, the
	// one shown lit.
	mx0, mx1 := r0.x + 312, r0.x + 640
	my0, my1 := r0.y + 6, r1.y - 6
	n := len(pic.banks)
	if n > 0 {
		// Five a row, up to three rows (more: narrower), each at most
		// 104 x 30.
		cols := n if n <= 5 else max(5, (n + 2) / 3)
		rows := (n + cols - 1) / cols
		gap: f32 = 4
		cw := min((mx1 - mx0 - gap * f32(cols - 1)) / f32(cols), 104)
		ch := min((my1 - my0 - gap * f32(rows - 1)) / f32(rows), 30)
		ui.text_push(.Caption)
		lh := im.GetTextLineHeight()
		for b, k in pic.banks {
			cx := mx0 + f32(k % cols) * (cw + gap)
			cy := my0 + f32(k / cols) * (ch + gap)
			cur := k == pic.bank
			fill := ui.mix(ui.PLOT_BG, pic.color, 0.3) if cur else ui.mix(ui.PLOT_BG, th.text, 0.07)
			im.DrawList_AddRectFilled(dl, {cx, cy}, {cx + cw, cy + ch}, ui.col(fill), 3)
			if cur do im.DrawList_AddRect(dl, {cx, cy}, {cx + cw, cy + ch}, ui.col(pic.color), 3, 1.5)
			if ch >= lh + 6 {
				im.DrawList_PushClipRect(dl, {cx + 3, cy}, {cx + cw - 3, cy + ch}, true)
				im.DrawList_AddText(dl, {cx + 5, cy + 2}, ui.col(th.text if cur else dim), fmt.ctprintf("%s", b.name))
				im.DrawList_PopClipRect(dl)
			}
			// Its parameters, a tick each (eight across).
			tw := (cw - 10) / 8
			ty := cy + ch - 5
			for q in 0 ..< min(b.count, 8) {
				tx := cx + 5 + f32(q) * tw
				im.DrawList_AddRectFilled(dl, {tx, ty - 2}, {tx + tw - 2, ty}, ui.col(th.text if cur else ui.with_alpha(th.text, 0.3)), 1)
			}
		}
		ui.text_pop()
	}
	// The parameter turned, large (the bottom right is the page strip's).
	kx0, kx1 := r0.x + 656, r1.x - 12
	if pic.knob == "" {
		mp_text(dl, {kx0, r0.y + 8}, "Turn an encoder", ui.with_alpha(th.text, 0.45), .Label, kx1)
		mp_text(dl, {kx0, r0.y + 24}, "its parameter shows here", ui.with_alpha(th.text, 0.35), .Caption, kx1)
		return
	}
	mp_text(dl, {kx0, r0.y + 4}, "Turning" if pic.turning else "Last turned", ui.with_alpha(th.text, 0.45), .Caption, kx1)
	nw := mp_text(dl, {kx0, r0.y + 17}, pic.knob, th.text if pic.turning else dim, .Body, kx1 - 90)
	_ = nw
	// The value at the right, large.
	im.PushFontFloat(pic.bold, 22)
	vc := fmt.ctprintf("%s", pic.value)
	vs := im.CalcTextSize(vc)
	vx := max(kx1 - vs.x, kx0 + 90)
	im.DrawList_PushClipRect(dl, {kx0, r0.y}, {kx1, r1.y}, true)
	im.DrawList_AddText(dl, {vx, r0.y + 10}, ui.col(pic.color if pic.turning else th.text), vc)
	im.DrawList_PopClipRect(dl)
	im.PopFont()
	by := r0.y + 40
	im.DrawList_AddRectFilled(dl, {kx0, by}, {kx1, by + 4}, ui.col(ui.mix(ui.PLOT_BG, th.text, 0.12)), 2)
	im.DrawList_AddRectFilled(dl, {kx0, by}, {kx0 + (kx1 - kx0) * clamp(pic.frac, 0, 1), by + 4}, ui.col(pic.color if pic.turning else ui.with_alpha(pic.color, 0.6)), 2)
}
