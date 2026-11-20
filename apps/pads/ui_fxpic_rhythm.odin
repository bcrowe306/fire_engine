// The rhythm and pitch effects' pictures (Cutter, Stutter, Pitch shift):
// each draws into a size it's given at the cursor, from plain values (the
// effect's settings as they play, the tempo grid now), so a controller's
// display and Pads' window can both use them.
//
// - Cutter: one bar on the beat grid, its gate open and closed cut by cut
//   (open for Duty of each cycle of Rate, down to Depth's floor; counted
//   from bar 1 of what plays, as the effect counts them), the cut
//   under the playhead lit, the ones it has played brighter than those to
//   come. In Perform, its own Rate a faint outline behind.
// - Stutter: one bar of the signal (a picture of one: what goes in isn't
//   kept), the slice it takes (Length, ending at the playhead) bracketed;
//   repeating, the slice it took and its copies from where it started,
//   counted.
// - Pitch shift: a keyboard four octaves wide, the interval an arc from the
//   played key to the one it sounds as (dry and wet as bright as Mix makes
//   them), and the two read heads' windows (Window long) crossing over.
package pads

import "core:fmt"
import "core:math"

import "app:ui"
import im "deps:imgui"

// The tempo grid a rhythm picture runs on.
@(private)
Rhy_Grid :: struct {
	bar:     f64,  // beats (quarter notes) in a bar
	now:     f64,  // the playhead: beats into the bar shown (0 ..< bar)
	grid:    f64,  // the clock's grid beat now (what the stutter follows)
	count:   f64,  // the beat the cutter counts its cycles from now: the sequence's position while it plays, else the grid's
	playing: bool, // the transport plays (else the clock's own bar)
	bar_no:  int,  // the bar shown, from 1 (playing)
	bpm:     f64,
}

// Tempo divisions the cutter's Rate and the stutter's Length are set to (in
// beats, longest first) and their names.
@(private)
RHY_DIVISIONS := [?]f32{1, 0.75, 2.0 / 3, 0.5, 0.375, 1.0 / 3, 0.25, 0.1875, 1.0 / 6, 0.125, 1.0 / 12, 1.0 / 16, 1.0 / 32}
@(private)
RHY_DIVISION_NAMES := [?]string{"1/4", "1/8 D", "1/4 T", "1/8", "1/16 D", "1/8 T", "1/16", "1/32 D", "1/16 T", "1/32", "1/32 T", "1/64", "1/128"}

// The division nearest `beats` (its index in RHY_DIVISIONS).
@(private)
rhy_division :: proc(beats: f32) -> int {
	best, dist := 0, max(f32)
	for d, k in RHY_DIVISIONS {
		x := abs(math.ln(max(beats, 1e-4) / d))
		if x < dist do best, dist = k, x
	}
	return best
}

// A length in beats as read: its division's name ("1/16", "1/8 T"), or
// beats when it is none (automation between them).
@(private)
rhy_beats_text :: proc(beats: f32) -> string {
	k := rhy_division(beats)
	if abs(beats / RHY_DIVISIONS[k] - 1) < 0.01 do return RHY_DIVISION_NAMES[k]
	return fmt.tprintf("%.3f beat", beats)
}

// A picture's frame at the cursor, `size` big (an item named `id`).
@(private = "file")
pic_frame :: proc(id: string, size: im.Vec2) -> (dl: ^im.DrawList, r0, r1: im.Vec2) {
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
pic_caption :: proc(dl: ^im.DrawList, at: im.Vec2, name, rest: string, right := false) -> f32 {
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

// The beat grid of a bar from `x0` to `x1` (`top` to `bottom`): sixteenths
// faint, beats brighter, each beat's number in the header at `ny` where no
// caption is (`free0` .. `free1`).
@(private = "file")
pic_beats :: proc(dl: ^im.DrawList, g: Rhy_Grid, x0, x1, top, bottom, ny, free0, free1: f32) {
	th := ui.theme()
	bar := max(g.bar, 0.25)
	ui.text_push(.Caption)
	defer ui.text_pop()
	n := int(math.ceil(bar * 4))
	for k in 0 ..= n {
		b := f64(k) / 4
		if b > bar + 1e-6 do break
		x := x0 + (x1 - x0) * f32(b / bar)
		whole := k % 4 == 0
		im.DrawList_AddLine(dl, {x, top}, {x, bottom}, ui.col(ui.mix(ui.PLOT_BG, th.text, 0.22 if whole else 0.07)), 1)
		if whole && b < bar - 1e-6 {
			label := fmt.ctprintf("%d", k / 4 + 1)
			if x + 3 > free0 && x + 12 < free1 do im.DrawList_AddText(dl, {x + 3, ny}, ui.col(ui.mix(ui.PLOT_BG, th.text, 0.5)), label)
		}
	}
}

// The playhead at `x`, `top` to `bottom`: a line with a cap.
@(private = "file")
pic_playhead :: proc(dl: ^im.DrawList, x, top, bottom: f32, playing: bool) {
	th := ui.theme()
	c := ui.col(th.text if playing else ui.with_alpha(th.text, 0.45))
	im.DrawList_AddLine(dl, {x, top}, {x, bottom}, c, 1.5)
	im.DrawList_AddTriangleFilled(dl, {x - 4, top - 1}, {x + 4, top - 1}, {x, top + 4}, c)
}

// Where the transport is, as read at the top right: "Bar 3 · beat 2" (playing)
// or the tempo (stopped).
@(private = "file")
pic_where :: proc(g: Rhy_Grid) -> string {
	if g.playing do return fmt.tprintf("Bar %d · beat %d  ·  %.0f BPM", g.bar_no, int(g.now) + 1, g.bpm)
	return fmt.tprintf("Stopped  ·  %.0f BPM", g.bpm)
}

// --- Cutter ------------------------------------------------------------------------------------

// What the cutter's picture shows.
@(private)
Rhy_Cutter_Picture :: struct {
	beats, duty, depth: f32, // as it plays (Perform: at its intensity)
	own_beats:  f32,         // Perform: its own Rate (0: not Perform)
	intensity:  f32,         // Perform: the intensity it plays at
	on:         bool,        // it plays (a slot on; Perform: held)
	perform:    bool,
	grid:       Rhy_Grid,
	color:      ui.Color,
}

// The cutter, `size` big at the cursor.
@(private)
rhy_cutter_picture :: proc(pic: Rhy_Cutter_Picture, size: im.Vec2) {
	th := ui.theme()
	dl, r0, r1 := pic_frame("cutter picture", size)
	g := pic.grid
	bar := max(g.bar, 0.25)
	x0, x1 := r0.x + 8, r1.x - 8
	top, bottom := r0.y + 20, r1.y - 5
	color := pic.color if pic.on else ui.mix(ui.PLOT_BG, pic.color, 0.5)
	xb :: proc(x0, x1: f32, bar, b: f64) -> f32 { return x0 + (x1 - x0) * f32(clamp(b / bar, 0, 1)) }
	yg :: proc(top, bottom, gain: f32) -> f32 { return bottom - (bottom - top) * clamp(gain, 0, 1) }
	floor_gain := 1 - clamp(pic.depth, 0, 1)
	// The caption, the transport, the grid under them.
	open := fmt.tprintf("%s · %.0f%% open · ", rhy_beats_text(pic.beats), pic.duty * 100)
	closes := "closes fully" if floor_gain < 0.001 else fmt.tprintf("down %.1f dB", -20 * math.log10(floor_gain))
	rest := fmt.tprintf("%s%s", open, closes)
	if pic.perform do rest = fmt.tprintf("%s  ·  Intensity %.2f (its own %s)", rest, pic.intensity, rhy_beats_text(pic.own_beats))
	cw := pic_caption(dl, {r0.x + 10, r0.y + 3}, "Cutter" if pic.on else ("Cutter (not held)" if pic.perform else "Cutter (off)"), rest)
	ww := pic_caption(dl, {r1.x - 10, r0.y + 3}, "", pic_where(g), right = true)
	pic_beats(dl, g, x0, x1, top, bottom, r0.y + 5, r0.x + 10 + cw + 8, r1.x - 10 - ww - 8)
	// The floor it closes to.
	fy := yg(top, bottom, floor_gain)
	if floor_gain > 0.001 do im.DrawList_AddLine(dl, {x0, fy}, {x1, fy}, ui.col(ui.with_alpha(color, 0.35)), 1)
	// Its own Rate, faint (Perform: the intensity changes it).
	win0 := g.count - g.now // (the bar's first beat, as the cutter counts)
	if pic.perform && pic.own_beats > 0 && abs(pic.own_beats - pic.beats) > 1e-4 {
		cutter_cycles(dl, win0, bar, f64(pic.own_beats), f64(pic.duty), x0, x1, top, bottom, floor_gain, ui.with_alpha(th.text, 0.2), -1, false)
	}
	cutter_cycles(dl, win0, bar, f64(pic.beats), f64(pic.duty), x0, x1, top, bottom, floor_gain, color, g.now, true)
	pic_playhead(dl, xb(x0, x1, bar, g.now), top, bottom, g.playing)
}

// The cutter's cycles of `beats` over the bar starting at beat `win0` (of
// the sequence playing, else of the grid):
// each open for `duty` of it (filled, the one at `now` lit, those before it
// brighter than those after; `fill` false: an outline only).
@(private = "file")
cutter_cycles :: proc(dl: ^im.DrawList, win0, bar, cycle, duty: f64, x0, x1, top, bottom, floor_gain: f32, color: ui.Color, now: f64, fill: bool) {
	beats := max(cycle, 1.0 / 64)
	xb :: proc(x0, x1: f32, bar, b: f64) -> f32 { return x0 + (x1 - x0) * f32(clamp(b / bar, 0, 1)) }
	fy := bottom - (bottom - top) * floor_gain
	// The cycles, as the effect counts them: from the sequence's beat 0
	// (bar 1) while it plays, else from the grid's.
	first := math.floor(win0 / beats)
	n := int(math.ceil(bar / beats)) + 2
	if n > 400 do n = 400 // (a bar of 1/128s at most)
	pts := make([dynamic]im.Vec2, 0, 4 * n + 2, context.temp_allocator)
	for k in 0 ..< n {
		c0 := (first + f64(k)) * beats - win0 // (into the bar)
		c1 := c0 + beats * duty
		if c0 >= bar do break
		if c1 + beats * (1 - duty) <= 0 do continue
		a, b := xb(x0, x1, bar, c0), xb(x0, x1, bar, c1)
		e := xb(x0, x1, bar, c0 + beats)
		append(&pts, im.Vec2{a, fy}, im.Vec2{a, top}, im.Vec2{b, top}, im.Vec2{b, fy})
		if !fill || b <= a do continue
		alpha: f32 = 0.42
		if now >= 0 {
			switch {
			case now >= c0 && now < c0 + beats: alpha = 1
			case c0 + beats <= now:             alpha = 0.62
			}
		}
		im.DrawList_AddRectFilled(dl, {a, top}, {b, bottom}, ui.col(ui.with_alpha(color, alpha * 0.85)), 2)
		// The closed part: its floor's level, if it lets anything through.
		if floor_gain > 0.001 && e > b do im.DrawList_AddRectFilled(dl, {b, fy}, {e, bottom}, ui.col(ui.with_alpha(color, alpha * 0.3)), 0)
	}
	if len(pts) >= 2 do im.DrawList_AddPolyline(dl, &pts[0], i32(len(pts)), ui.col(ui.with_alpha(color, 0.9 if fill else 1)), 1.5 if fill else 1)
}

// --- Stutter -----------------------------------------------------------------------------------

// What the stutter's picture shows.
@(private)
Rhy_Stutter_Picture :: struct {
	beats:     f32,  // the slice's length as it plays (Perform: at its intensity)
	own_beats: f32,  // Perform: its own Length (0: not Perform)
	intensity: f32,  // Perform: the intensity it plays at
	active:    bool, // repeating
	since:     f64,  // repeating: the grid beat it started at
	perform:   bool,
	grid:      Rhy_Grid,
	color:     ui.Color,
}

// A picture of a signal at grid beat `b` (0..1): a kick on each beat, a
// snare-ish hit between, hats on the sixteenths, rippled. (The input isn't
// kept: this shows where it goes, not what it is.)
@(private = "file")
stutter_level :: proc(b: f64) -> f32 {
	frac :: proc(x: f64) -> f64 { return x - math.floor(x) }
	kick := math.exp(-frac(b) * 9)
	snare := 0.7 * math.exp(-frac(b + 0.5) * 12) if int(math.floor(b + 0.5)) % 2 == 1 else 0.0
	hat := (0.45 if int(math.floor(b * 4)) % 2 == 1 else 0.32) * math.exp(-frac(b * 4) * 8)
	ripple := 0.65 + 0.35 * abs(math.sin(b * 97.3))
	return f32(clamp((0.1 + max(kick, snare, hat)) * ripple, 0, 1))
}

// The stutter, `size` big at the cursor.
@(private)
rhy_stutter_picture :: proc(pic: Rhy_Stutter_Picture, size: im.Vec2) {
	th := ui.theme()
	dl, r0, r1 := pic_frame("stutter picture", size)
	g := pic.grid
	bar := max(g.bar, 0.25)
	L := max(f64(pic.beats), 1.0 / 64)
	x0, x1 := r0.x + 8, r1.x - 8
	top, bottom := r0.y + 20, r1.y - 5
	mid, half := (top + bottom) / 2, (bottom - top) / 2 - 1
	win0 := g.grid - g.now
	xb :: proc(x0, x1: f32, bar, b: f64) -> f32 { return x0 + (x1 - x0) * f32(clamp(b / bar, 0, 1)) }
	// The caption, the transport, the grid.
	name := "Stutter"
	state := ""
	if pic.active {
		reps := int(math.floor((g.grid - pic.since) / L)) + 1
		state = fmt.tprintf("repeating %s  ×%d", rhy_beats_text(pic.beats), max(reps, 1))
	} else {
		state = fmt.tprintf("slice %s, the last heard", rhy_beats_text(pic.beats))
		name = "Stutter (hold to repeat)" if pic.perform else "Stutter (off)"
	}
	if pic.perform do state = fmt.tprintf("%s  ·  Intensity %.2f (its own %s)", state, pic.intensity, rhy_beats_text(pic.own_beats))
	cw := pic_caption(dl, {r0.x + 10, r0.y + 3}, name, state)
	ww := pic_caption(dl, {r1.x - 10, r0.y + 3}, "", pic_where(g), right = true)
	// The slice: what it took (repeating) or would take now.
	s1 := pic.since if pic.active else g.grid
	s0 := s1 - L
	if s1 > win0 && s0 < win0 + bar {
		a, b := xb(x0, x1, bar, s0 - win0), xb(x0, x1, bar, s1 - win0)
		im.DrawList_AddRectFilled(dl, {a, top}, {b, bottom}, ui.col(ui.with_alpha(pic.color, 0.22)), 2)
		im.DrawList_AddRect(dl, {a, top}, {b, bottom}, ui.col(ui.with_alpha(pic.color, 0.8)), 2, 1.5)
	}
	pic_beats(dl, g, x0, x1, top, bottom, r0.y + 5, r0.x + 10 + cw + 8, r1.x - 10 - ww - 8)
	// The signal, column by column: what comes out at each beat of the bar.
	STEP :: 2
	cols := int((x1 - x0) / STEP)
	for k in 0 ..< cols {
		x := x0 + f32(k) * STEP
		t := win0 + bar * f64(k) / f64(cols) // (grid beat)
		src := t
		repeat := pic.active && t >= pic.since
		if repeat do src = pic.since - L + math.mod(t - pic.since, L)
		h := stutter_level(src) * half
		c: ui.Color
		switch {
		case t > g.grid && repeat: c = ui.with_alpha(pic.color, 0.4)  // (its repeats to come)
		case t > g.grid:          c = ui.with_alpha(th.text, 0.1)     // (not heard yet)
		case repeat:              c = ui.with_alpha(pic.color, 0.95)  // (repeated)
		case:                     c = ui.with_alpha(th.text, 0.42)    // (heard)
		}
		im.DrawList_AddLine(dl, {x, mid - h}, {x, mid + h}, ui.col(c), 1.4)
	}
	// Repeating: where each copy starts.
	if pic.active {
		n := 0
		for c := pic.since; c < win0 + bar && n < 256; c += L {
			n += 1
			if c < win0 do continue
			x := xb(x0, x1, bar, c - win0)
			im.DrawList_AddLine(dl, {x, top}, {x, bottom}, ui.col(ui.with_alpha(pic.color, 0.9 if c <= g.grid else 0.4)), 1)
		}
	}
	pic_playhead(dl, xb(x0, x1, bar, g.now), top, bottom, g.playing)
}

// --- Pitch shift -------------------------------------------------------------------------------

// What the pitch shift's picture shows.
@(private)
Rhy_Pitch_Picture :: struct {
	semitones: f32, // as it plays (Perform: at its intensity)
	own:       f32, // Perform: its own Pitch
	window_ms: f32,
	mix:       f32, // 0..1
	intensity: f32, // Perform: the intensity it plays at
	phase:     f32, // the read heads' place in their window (0..1)
	on:        bool,
	perform:   bool,
	color:     ui.Color,
}

// An interval's name ("an octave", "a fifth", "two octaves and a third"),
// and the cents off it ("a fifth +40 ct").
@(private = "file")
interval_name :: proc(st: f32) -> string {
	NAMES := [12]string{"unison", "minor second", "second", "minor third", "third", "fourth", "tritone", "fifth", "minor sixth", "sixth", "minor seventh", "seventh"}
	n := int(math.round(abs(st)))
	cents := int(math.round((abs(st) - f32(n)) * 100))
	oct, rest := n / 12, n % 12
	name: string
	switch {
	case n == 0:                name = "unison"
	case rest == 0 && oct == 1: name = "an octave"
	case rest == 0:             name = fmt.tprintf("%d octaves", oct)
	case oct == 0:              name = fmt.tprintf("a %s", NAMES[rest])
	case oct == 1:              name = fmt.tprintf("an octave and a %s", NAMES[rest])
	case:                       name = fmt.tprintf("%d octaves and a %s", oct, NAMES[rest])
	}
	if abs(cents) >= 2 do name = fmt.tprintf("%s %+d ct", name, cents)
	return name
}

// The pitch shift, `size` big at the cursor.
@(private)
rhy_pitch_picture :: proc(pic: Rhy_Pitch_Picture, size: im.Vec2) {
	th := ui.theme()
	dl, r0, r1 := pic_frame("pitch picture", size)
	color := pic.color if pic.on else ui.mix(ui.PLOT_BG, pic.color, 0.5)
	st := clamp(pic.semitones, -24, 24)
	// The caption.
	dir := "up" if st > 0.05 else ("down" if st < -0.05 else "")
	rest := fmt.tprintf("%+.1f st · %s %s · ×%.3f the speed", st, interval_name(st), dir, math.pow(2, st / 12))
	if pic.perform do rest = fmt.tprintf("%s  ·  Intensity %.2f (its own %+.0f st)", rest, pic.intensity, pic.own)
	pic_caption(dl, {r0.x + 10, r0.y + 3}, "Pitch shift" if pic.on else ("Pitch shift (not held)" if pic.perform else "Pitch shift (off)"), rest)
	// The keyboard: C two octaves down to C two up, the key played (C) in the middle.
	gw := min(f32(230), (r1.x - r0.x) * 0.26) // (the heads' box at the right)
	kx0, kx1 := r0.x + 10, r1.x - gw - 22
	ktop, kbot := r1.y - 26, r1.y - 5
	WHITE :: 29 // (C to C, four octaves)
	ww := (kx1 - kx0) / WHITE
	is_black :: proc(n: int) -> bool { m := ((n % 12) + 12) % 12; return m == 1 || m == 3 || m == 6 || m == 8 || m == 10 }
	// Semitone `n` (-24..24)'s centre and whether it's a black key.
	key_x :: proc(kx0, ww: f32, n: int) -> f32 {
		WHITE_OF := [12]f32{0, 0.5, 1, 1.5, 2, 3, 3.5, 4, 4.5, 5, 5.5, 6}
		o := int(math.floor(f32(n + 24) / 12))
		m := (n + 24) - o * 12
		return kx0 + (f32(o) * 7 + WHITE_OF[m] + 0.5) * ww
	}
	target := int(math.round(st))
	dry_a := 1 - clamp(pic.mix, 0, 1)
	wet_a := clamp(pic.mix, 0, 1)
	for pass in 0 ..< 2 { // (the white keys, then the black over them)
		for n in -24 ..= 24 {
			black := is_black(n + 24)
			if black != (pass == 1) do continue
			cx := key_x(kx0, ww, n)
			kw := ww * 0.62 if black else ww - 1.5
			kb := ktop + (kbot - ktop) * 0.6 if black else kbot
			fill := ui.mix(ui.PLOT_BG, th.text, 0.12 if black else 0.3)
			if n == 0 do fill = ui.mix(fill, th.text, 0.25 + 0.6 * dry_a)
			if n == target && target != 0 do fill = ui.mix(fill, color, 0.35 + 0.65 * wet_a)
			im.DrawList_AddRectFilled(dl, {cx - kw / 2, ktop}, {cx + kw / 2, kb}, ui.col(fill), 1.5)
			if !black && n % 12 == 0 {
				ui.text_push(.Caption)
				lbl := fmt.ctprintf("%+d", n) if n != 0 else "0"
				ls := im.CalcTextSize(lbl)
				im.DrawList_AddText(dl, {cx - ls.x / 2, kbot - ls.y}, ui.col(ui.with_alpha(ui.PLOT_BG, 0.9)), lbl)
				ui.text_pop()
			}
		}
	}
	// The interval: an arc from the key played to the one it sounds as
	// (fractions of a semitone between keys), its own faint in Perform.
	semis_x :: proc(kx0, ww: f32, s: f32) -> f32 {
		n := int(math.floor(s))
		f := s - f32(n)
		a := key_x(kx0, ww, clamp(n, -24, 24))
		b := key_x(kx0, ww, clamp(n + 1, -24, 24))
		return a + (b - a) * f
	}
	x_dry := key_x(kx0, ww, 0)
	arc :: proc(dl: ^im.DrawList, xa, xb, base, top: f32, c: u32, thick: f32) {
		h := clamp(abs(xb - xa) * 0.5, 6, base - top)
		im.DrawList_AddBezierCubic(dl, {xa, base}, {xa, base - h}, {xb, base - h}, {xb, base}, c, thick)
	}
	base := ktop - 2
	atop := r0.y + 20
	if pic.perform && abs(pic.own - st) > 0.05 {
		arc(dl, x_dry, semis_x(kx0, ww, clamp(pic.own, -24, 24)), base, atop, ui.col(ui.with_alpha(th.text, 0.3)), 1)
	}
	if abs(st) > 0.02 {
		xt := semis_x(kx0, ww, st)
		arc(dl, x_dry, xt, base, atop, ui.col(ui.with_alpha(color, 0.45 + 0.55 * wet_a)), 2.5)
		im.DrawList_AddTriangleFilled(dl, {xt - 5, base - 7}, {xt + 5, base - 7}, {xt, base}, ui.col(color))
	}
	im.DrawList_AddCircleFilled(dl, {x_dry, base - 2}, 3, ui.col(ui.with_alpha(th.text, 0.35 + 0.6 * dry_a)), 10)
	// The read heads: two windows half a window apart, each fading in and
	// out (so its jumps back aren't heard), where each is now.
	gx0, gx1 := r1.x - gw - 10, r1.x - 10
	gtop, gbot := r0.y + 34, r1.y - 6
	im.DrawList_AddRectFilled(dl, {gx0, gtop - 14}, {gx1, gbot + 2}, ui.col(ui.with_alpha(ui.PLOT_BG, 0.6)), 3)
	im.DrawList_AddRect(dl, {gx0, gtop - 14}, {gx1, gbot + 2}, ui.col(ui.mix(ui.PLOT_BG, th.text, 0.18)), 3)
	ui.text_push(.Caption)
	im.DrawList_AddText(dl, {gx0 + 5, gtop - 13}, ui.col(ui.with_alpha(th.text, 0.62)), fmt.ctprintf("%.0f ms window · mix %.0f%%", pic.window_ms, pic.mix * 100))
	ui.text_pop()
	// Two windows across the box (each head's, half a window apart), and
	// where they read now: a cursor through both, each head's gain on it.
	N :: 64
	cx0, cx1 := gx0 + 6, gx1 - 6
	ph := pic.phase - math.floor(pic.phase)
	for w in 0 ..< 2 {
		x := cx0 + (cx1 - cx0) * (ph + f32(w)) / 2
		im.DrawList_AddLine(dl, {x, gtop}, {x, gbot}, ui.col(ui.with_alpha(th.text, 0.3)), 1)
	}
	for head in 0 ..< 2 {
		pts: [N]im.Vec2
		off := f32(head) * 0.5
		gain :: proc(u, off: f32) -> f32 {
			x := u - off
			return math.sin(math.PI * (x - math.floor(x)))
		}
		for k in 0 ..< N {
			u := f32(k) / (N - 1) * 2 // (0..2 windows)
			pts[k] = {cx0 + (cx1 - cx0) * u / 2, gbot - (gbot - gtop) * gain(u, off)}
		}
		c := color if head == 0 else ui.mix(color, ui.rgb(0x60b8ff), 0.6)
		im.DrawList_AddPolyline(dl, &pts[0], N, ui.col(ui.with_alpha(c, 0.75)), 1.5)
		for w in 0 ..< 2 {
			u := ph + f32(w)
			im.DrawList_AddCircleFilled(dl, {cx0 + (cx1 - cx0) * u / 2, gbot - (gbot - gtop) * gain(u, off)}, 3, ui.col(ui.lighten(c, 0.3)), 10)
		}
	}
}
