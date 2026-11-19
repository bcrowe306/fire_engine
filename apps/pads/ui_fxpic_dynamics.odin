// The dynamics' pictures (Compressor, Gate, Limiter): what each does to
// the level, drawn from plain values into a rect they're given, so a
// controller's display draws them now and Pads' window can later. Each
// takes its settings (as plain values), what the engine says it is doing
// now (levels, reduction; none when it says nothing) and draws into the
// window's draw list without items of its own.
package pads

import "core:fmt"
import "core:math"

import "app:ui"
import im "deps:imgui"
import "fire:dsp"
import "fire:fx"

// A level below this (dB) is no level: nothing is heard, or nothing said.
DYN_NONE :: f32(-200)

// What the Compressor picture shows: the synth's three-band compressor
// (each band pressed down above its upper threshold, lifted below its
// lower one, then its gain), what each band's level is now, which band is
// being set.
Dyn_Comp_Picture :: struct {
	params: fx.Compressor_Params,
	levels: [3][2]f32, // each band's level now, in and out (dB; DYN_NONE: none)
	focus:  int,       // the band being set (its bank's), bright; -1 none
	on:     bool,
	key:    string,    // what it listens to ("" none shown)
}

// What the Gate picture shows: its settings (plain values, as the
// parameters have them), its level and reduction now.
Dyn_Gate_Picture :: struct {
	threshold, range_db, ratio, hysteresis: f32, // dB, dB, 1..100, dB
	attack, hold, release:                  f32, // ms
	level_db:  f32, // its input's level now (DYN_NONE: none)
	reduction: f32, // dB it turns down now (0: open)
	live:      bool, // the engine says what it does (else the reduction is none)
	on:        bool,
	key:       string,
}

// What the Limiter picture shows: its settings, its level and reduction
// now, and the reduction over the last few seconds (oldest first).
Dyn_Limiter_Picture :: struct {
	ceiling, input, release: f32, // dB, dB, ms
	level_db:  f32, // its input's level now, before its Input gain (DYN_NONE: none)
	reduction: f32, // dB
	live:      bool,
	on:        bool,
	history:   []f32, // reduction (dB), oldest first, evenly in time
	outs:      []f32, // the output's level (dB) at the same moments
}

// The crossovers' names for each band under a band setting.
@(private)
dyn_band_range :: proc(bands: fx.Compressor_Bands, b: int) -> string {
	@(static, rodata) names := [fx.Compressor_Bands][3]string {
		.Three     = {"< 120 Hz", "120 Hz - 2.5 kHz", "> 2.5 kHz"},
		.Low_Band  = {"< 120 Hz", "> 120 Hz", "(with Band)"},
		.Band_High = {"(with Band)", "< 2.5 kHz", "> 2.5 kHz"},
		.One       = {"(with Band)", "all", "(with Band)"},
	}
	return names[bands][clamp(b, 0, 2)]
}

// Whether band `b` is split off under `bands` (else it goes with the band).
@(private)
dyn_band_used :: proc(bands: fx.Compressor_Bands, b: int) -> bool {
	switch bands {
	case .Three:     return true
	case .Low_Band:  return b != 2
	case .Band_High: return b != 0
	case .One:       return b == 1
	}
	return true
}

// A compressor band's output for a steady input `x` (dB): pressed down
// above its upper threshold by its upper ratio, lifted (or pushed down)
// below its lower one (nothing under -60 dB lifted further), at most 30 dB
// up all told, then its gain. As fx.compressor_render's envelopes settle.
dyn_comp_band_out :: proc "contextless" (b: fx.Compressor_Band, x: f32) -> f32 {
	g: f32 = 0
	if x > b.upper_db do g += clamp(b.upper_ratio, 0, 1) * (b.upper_db - x)
	if x < b.lower_db do g += clamp(b.lower_ratio, -1, 1) * (b.lower_db - max(x, -60))
	return x + min(g, 30.1) + clamp(b.gain_db, -30, 30)
}

// A level on a scale from `lo` to `hi` dB as a place from `a` to `b`.
@(private)
dyn_at :: proc "contextless" (db, lo, hi, a, b: f32) -> f32 {
	return a + (b - a) * clamp((db - lo) / (hi - lo), 0, 1)
}

// Text at `p` in colour `c` (the caption's size: the caller pushes it).
@(private)
dyn_text :: proc(dl: ^im.DrawList, p: im.Vec2, c: ui.Color, text: string) -> f32 {
	ct := fmt.ctprintf("%s", text)
	im.DrawList_AddText(dl, p, ui.col(c), ct)
	return im.CalcTextSize(ct).x
}

// Text ending at `x` (right-aligned).
@(private)
dyn_text_r :: proc(dl: ^im.DrawList, x, y: f32, c: ui.Color, text: string) {
	ct := fmt.ctprintf("%s", text)
	im.DrawList_AddText(dl, {x - im.CalcTextSize(ct).x, y}, ui.col(c), ct)
}

// A transfer curve's frame from `c0` to `c1`: input across, output up,
// both `lo`..`hi` dB; its grid every `step`, the unity line.
@(private)
dyn_curve_frame :: proc(dl: ^im.DrawList, c0, c1: im.Vec2, lo, hi, step: f32) {
	th := ui.theme()
	grid := ui.col(ui.mix(ui.PLOT_BG, th.text, 0.07))
	for db := hi - step; db > lo; db -= step {
		x := dyn_at(db, lo, hi, c0.x, c1.x)
		y := dyn_at(db, lo, hi, c1.y, c0.y)
		im.DrawList_AddLine(dl, {x, c0.y}, {x, c1.y}, grid, 1)
		im.DrawList_AddLine(dl, {c0.x, y}, {c1.x, y}, grid, 1)
	}
	im.DrawList_AddRect(dl, c0, c1, ui.col(ui.mix(ui.PLOT_BG, th.text, 0.14)), 0)
	im.DrawList_AddLine(dl, {c0.x, c1.y}, {c1.x, c0.y}, ui.col(ui.mix(ui.PLOT_BG, th.text, 0.12)), 1)
}

// A reduction meter from `p0` to `p1`, filled down from the top by
// `db` of `scale`; its number under-right of it is the caller's.
@(private)
dyn_reduction_bar :: proc(dl: ^im.DrawList, p0, p1: im.Vec2, db, scale: f32, on: bool) {
	th := ui.theme()
	im.DrawList_AddRectFilled(dl, p0, p1, ui.col(ui.mix(ui.PLOT_BG, th.text, 0.07)), 2)
	f := clamp(db / max(scale, 1), 0, 1)
	if f > 0 do im.DrawList_AddRectFilled(dl, p0, {p1.x, p0.y + (p1.y - p0.y) * f}, ui.col(th.accent if on else ui.mix(ui.PLOT_BG, th.accent, 0.4)), 2)
}

// The Compressor's picture at `pos`, `size` big: its three bands side by
// side, each its level in and out now (two bars), its transfer curve
// (input across, output up, -80..0 dB) with its upper threshold (where it
// starts pressing down) and its lower one (where it starts lifting), a dot
// where its level is now; a band that goes with the one beside it, dim.
draw_dyn_compressor :: proc(pos, size: im.Vec2, pic: Dyn_Comp_Picture) {
	th := ui.theme()
	dl := im.GetWindowDrawList()
	im.DrawList_AddRectFilled(dl, pos, {pos.x + size.x, pos.y + size.y}, ui.col(ui.PLOT_BG), th.radius)
	ui.text_push(.Caption)
	defer ui.text_pop()
	lh := im.GetTextLineHeight()
	LO, HI :: f32(-80), f32(0)
	gap: f32 = 8
	cw := (size.x - gap * 4) / 3
	names := [3]string{"Low", "Band", "High"}
	for b in 0 ..< 3 {
		x0 := pos.x + gap + f32(b) * (cw + gap)
		x1 := x0 + cw
		top, bottom := pos.y + 3, pos.y + size.y - 3
		used := dyn_band_used(pic.params.bands, b)
		focus := pic.focus == b
		base := th.accent if pic.on && used else ui.mix(ui.PLOT_BG, th.text_dim, 0.6)
		if focus do im.DrawList_AddRect(dl, {x0 - 4, pos.y + 1}, {x1 + 4, pos.y + size.y - 1}, ui.col(ui.with_alpha(th.accent, 0.7)), th.radius, 1.5)
		// Its level in and out (two bars, -80..0 dB).
		MW :: 5
		lv := pic.levels[b]
		for k in 0 ..< 2 {
			mx := x0 + f32(k) * (MW + 2)
			im.DrawList_AddRectFilled(dl, {mx, top}, {mx + MW, bottom}, ui.col(ui.mix(ui.PLOT_BG, th.text, 0.07)), 1)
			if used && lv[k] > LO {
				y := dyn_at(lv[k], LO, HI, bottom, top)
				c := ui.with_alpha(base, 0.45) if k == 0 else base
				im.DrawList_AddRectFilled(dl, {mx, y}, {mx + MW, bottom}, ui.col(c), 1)
			}
		}
		// Its curve.
		c0 := im.Vec2{x0 + 2 * MW + 8, top}
		c1 := im.Vec2{x1, bottom}
		dyn_curve_frame(dl, c0, c1, LO, HI, 20)
		band := pic.params.band[b]
		ux := dyn_at(band.upper_db, LO, HI, c0.x, c1.x)
		lx := dyn_at(band.lower_db, LO, HI, c0.x, c1.x)
		im.DrawList_AddLine(dl, {ux, c0.y}, {ux, c1.y}, ui.col(ui.with_alpha(base, 0.75)), 1.2)
		im.DrawList_AddLine(dl, {lx, c0.y}, {lx, c1.y}, ui.col(ui.with_alpha(base, 0.4)), 1)
		N :: 48
		pts: [N]im.Vec2
		for k in 0 ..< N {
			x := LO + (HI - LO) * f32(k) / (N - 1)
			pts[k] = {dyn_at(x, LO, HI, c0.x, c1.x), dyn_at(dyn_comp_band_out(band, x), LO, HI, c1.y, c0.y)}
		}
		curve_c := ui.mix(th.text, base, 0.35) if pic.on && used else ui.mix(ui.PLOT_BG, th.text_dim, 0.5)
		im.DrawList_AddPolyline(dl, &pts[0], N, ui.col(curve_c), 2 if focus else 1.6)
		if used && pic.on && lv[0] > LO {
			im.DrawList_AddCircleFilled(dl, {dyn_at(lv[0], LO, HI, c0.x, c1.x), dyn_at(lv[1], LO, HI, c1.y, c0.y)}, 3.5, ui.col(ui.lighten(th.accent, 0.3)), 12)
		}
		// Its name and range at the top left, what it does now under them
		// (where the curve, above the unity line, leaves room).
		tc := th.text if focus || pic.focus < 0 else th.text_dim
		if !used do tc = th.text_dim
		w := dyn_text(dl, {c0.x + 4, c0.y + 1}, tc, names[b])
		dyn_text(dl, {c0.x + 10 + w, c0.y + 1}, th.text_dim, dyn_band_range(pic.params.bands, b))
		if used && pic.on && lv[0] > LO && lv[1] > LO {
			d := lv[1] - lv[0]
			dyn_text(dl, {c0.x + 4, c0.y + 1 + lh}, th.text, fmt.tprintf("%s %.1f dB", "up" if d >= 0 else "down", abs(d)))
		}
	}
	if pic.key != "" do dyn_text_r(dl, pos.x + size.x - gap, pos.y + size.y - lh - 20, th.text_dim, pic.key)
}

// The Gate's picture at `pos`, `size` big. At the left its transfer curve
// (input across, output up, -90..0 dB): open above the threshold, closed
// below where it closes (the threshold less the hysteresis: the band
// between shaded), turned down by the ratio to at most the range; a dot
// where its level is now. Then its reduction now (a bar), and its
// envelope: a sound opening it (Attack), holding it open, falling under
// where it closes (Hold, then Release down to the range), each stage as
// long as it is set (on a log scale).
draw_dyn_gate :: proc(pos, size: im.Vec2, pic: Dyn_Gate_Picture) {
	th := ui.theme()
	dl := im.GetWindowDrawList()
	im.DrawList_AddRectFilled(dl, pos, {pos.x + size.x, pos.y + size.y}, ui.col(ui.PLOT_BG), th.radius)
	ui.text_push(.Caption)
	defer ui.text_pop()
	lh := im.GetTextLineHeight()
	LO, HI :: f32(-90), f32(0)
	top, bottom := pos.y + 3, pos.y + size.y - 3
	base := th.accent if pic.on else ui.mix(ui.PLOT_BG, th.text_dim, 0.6)
	close_db := pic.threshold - pic.hysteresis
	// The curve.
	c0 := im.Vec2{pos.x + 8, top}
	c1 := im.Vec2{pos.x + size.x * 0.36, bottom}
	tx := dyn_at(pic.threshold, LO, HI, c0.x, c1.x)
	cx := dyn_at(close_db, LO, HI, c0.x, c1.x)
	im.DrawList_AddRectFilled(dl, {cx, c0.y}, {tx, c1.y}, ui.col(ui.with_alpha(base, 0.12)))
	dyn_curve_frame(dl, c0, c1, LO, HI, 18)
	im.DrawList_AddLine(dl, {tx, c0.y}, {tx, c1.y}, ui.col(ui.with_alpha(base, 0.8)), 1.2)
	im.DrawList_AddLine(dl, {cx, c0.y}, {cx, c1.y}, ui.col(ui.with_alpha(base, 0.45)), 1)
	closed :: proc(pic: Dyn_Gate_Picture, x, close_db: f32) -> f32 {
		return x - f32(dsp.expander_curve(f64(x), f64(close_db), f64(pic.ratio), 0, f64(pic.range_db)))
	}
	N :: 64
	pts: [N]im.Vec2
	for k in 0 ..< N {
		x := LO + (HI - LO) * f32(k) / (N - 1)
		y := x if x >= close_db else closed(pic, x, close_db)
		pts[k] = {dyn_at(x, LO, HI, c0.x, c1.x), dyn_at(y, LO, HI, c1.y, c0.y)}
	}
	curve_c := ui.mix(th.text, base, 0.35) if pic.on else ui.mix(ui.PLOT_BG, th.text_dim, 0.5)
	// (Opening from closed: up the closed curve to the threshold, then open.)
	if pic.hysteresis > 0.05 {
		M :: 16
		up: [M + 1]im.Vec2
		for k in 0 ..< M {
			x := close_db + (pic.threshold - close_db) * f32(k) / (M - 1)
			up[k] = {dyn_at(x, LO, HI, c0.x, c1.x), dyn_at(closed(pic, x, close_db), LO, HI, c1.y, c0.y)}
		}
		up[M] = {tx, dyn_at(pic.threshold, LO, HI, c1.y, c0.y)}
		im.DrawList_AddPolyline(dl, &up[0], M + 1, ui.col(ui.with_alpha(curve_c, 0.45)), 1)
	}
	im.DrawList_AddPolyline(dl, &pts[0], N, ui.col(curve_c), 2)
	if pic.on && pic.level_db > LO {
		y := pic.level_db - (pic.reduction if pic.live else 0)
		im.DrawList_AddCircleFilled(dl, {dyn_at(pic.level_db, LO, HI, c0.x, c1.x), dyn_at(y, LO, HI, c1.y, c0.y)}, 3.5, ui.col(ui.lighten(th.accent, 0.3)), 12)
	}
	dyn_text(dl, {c0.x + 4, c0.y + 1}, th.text_dim, fmt.tprintf("opens %.0f dB", pic.threshold))
	dyn_text_r(dl, c1.x - 4, c1.y - lh - 1, th.text_dim, fmt.tprintf("closes %.0f dB", close_db))
	// Its reduction now.
	g0 := im.Vec2{c1.x + 16, top}
	g1 := im.Vec2{g0.x + 10, bottom}
	scale := max(pic.range_db, 1)
	dyn_reduction_bar(dl, g0, g1, pic.reduction if pic.live else 0, scale, pic.on)
	open := pic.live && pic.reduction < 1
	state := "Open" if open else ("Closed" if pic.live else "")
	if pic.live do dyn_text(dl, {g1.x + 6, top}, th.text if open else th.text_dim, state)
	if pic.live do dyn_text(dl, {g1.x + 6, top + lh}, th.text_dim, fmt.tprintf("-%.1f dB", pic.reduction))
	// The envelope: the gain over a sound that opens and leaves it.
	e0 := im.Vec2{g1.x + 70, top + lh + 2}
	e1 := im.Vec2{pos.x + size.x - 150, bottom - lh - 2}
	span := e1.x - e0.x
	dur :: proc "contextless" (ms: f32) -> f32 { return math.log10(1 + max(ms, 0)) } // (0.05 ms..3 s: a log scale)
	seg := [3]f32{dur(pic.attack), dur(pic.hold), dur(pic.release)}
	MIN :: 14 // (a stage at its shortest still shows)
	rest := span - 4 * MIN - 2 * 30 // (closed before, open, closed after)
	total := seg[0] + seg[1] + seg[2]
	ws: [3]f32
	for k in 0 ..< 3 do ws[k] = MIN + (rest * seg[k] / total if total > 0 else 0)
	floor_y := dyn_at(-pic.range_db, -max(pic.range_db, 24), 0, e1.y, e0.y)
	x := e0.x
	open_w: f32 = MIN + 30
	grid := ui.col(ui.mix(ui.PLOT_BG, th.text, 0.1))
	im.DrawList_AddLine(dl, {e0.x, e0.y}, {e1.x, e0.y}, grid, 1)
	im.DrawList_AddLine(dl, {e0.x, floor_y}, {e1.x, floor_y}, grid, 1)
	env: [128]im.Vec2
	n := 0
	put :: proc(env: ^[128]im.Vec2, n: ^int, p: im.Vec2) {
		if n^ < len(env) {
			env[n^] = p
			n^ += 1
		}
	}
	put(&env, &n, {x, floor_y})
	x += 30
	put(&env, &n, {x, floor_y})
	// Attack: up (a smoother's rise: most of it in its time).
	sx := x
	for k in 1 ..= 20 {
		u := f32(k) / 20
		put(&env, &n, {sx + ws[0] * u, floor_y + (e0.y - floor_y) * (1 - math.exp(-3 * u)) / (1 - math.exp(f32(-3)))})
	}
	x = sx + ws[0]
	stages := [3]f32{x, 0, 0}
	x += open_w
	put(&env, &n, {x, e0.y})
	stages[1] = x // (the sound falls under where it closes: Hold)
	x += ws[1]
	put(&env, &n, {x, e0.y})
	stages[2] = x
	sx = x
	for k in 1 ..= 20 {
		u := f32(k) / 20
		put(&env, &n, {sx + ws[2] * u, e0.y + (floor_y - e0.y) * (1 - math.exp(-3 * u)) / (1 - math.exp(f32(-3)))})
	}
	x = sx + ws[2]
	put(&env, &n, {e1.x, floor_y})
	// The sound that keys it, faint behind: in from where it opens, out after the open stretch.
	snd := ui.with_alpha(th.text, 0.1)
	im.DrawList_AddRectFilled(dl, {e0.x + 30, e0.y + 2}, {stages[1], floor_y}, ui.col(snd))
	im.DrawList_AddPolyline(dl, &env[0], i32(n), ui.col(curve_c), 2)
	// The stages' names and times under them.
	label :: proc(dl: ^im.DrawList, x0, x1, y: f32, text: string, c: ui.Color) {
		ct := fmt.ctprintf("%s", text)
		ts := im.CalcTextSize(ct)
		im.DrawList_AddText(dl, {max((x0 + x1 - ts.x) / 2, x0 - 10), y}, ui.col(c), ct)
	}
	ly := e1.y + 1
	label(dl, e0.x + 30, stages[0], ly, fmt.tprintf("A %s", dyn_ms(pic.attack)), th.text_dim)
	label(dl, stages[1], stages[2], ly, fmt.tprintf("H %s", dyn_ms(pic.hold)), th.text_dim)
	label(dl, stages[2], x, ly, fmt.tprintf("R %s", dyn_ms(pic.release)), th.text_dim)
	dyn_text(dl, {e0.x, top}, th.text_dim, fmt.tprintf("Range -%.0f dB", pic.range_db))
	if pic.key != "" do dyn_text_r(dl, pos.x + size.x - 8, top, th.text_dim, pic.key)
}

// A time as it reads (ms, or s from a second).
@(private)
dyn_ms :: proc(ms: f32) -> string {
	if ms >= 1000 do return fmt.tprintf("%.2f s", ms / 1000)
	if ms >= 10 do return fmt.tprintf("%.0f ms", ms)
	return fmt.tprintf("%.2g ms" if ms < 1 else "%.1f ms", ms)
}

// The Limiter's picture at `pos`, `size` big: its transfer curve at the
// left (input across, output up, -48..0 dB: raised by Input, flat at the
// Ceiling; a dot where its level is now), its reduction now (a bar), and
// its reduction over the last seconds (from the top down, the output's
// level under it, the ceiling a line), its release written by it.
draw_dyn_limiter :: proc(pos, size: im.Vec2, pic: Dyn_Limiter_Picture) {
	th := ui.theme()
	dl := im.GetWindowDrawList()
	im.DrawList_AddRectFilled(dl, pos, {pos.x + size.x, pos.y + size.y}, ui.col(ui.PLOT_BG), th.radius)
	ui.text_push(.Caption)
	defer ui.text_pop()
	LO, HI :: f32(-48), f32(0)
	top, bottom := pos.y + 3, pos.y + size.y - 3
	base := th.accent if pic.on else ui.mix(ui.PLOT_BG, th.text_dim, 0.6)
	curve_c := ui.mix(th.text, base, 0.35) if pic.on else ui.mix(ui.PLOT_BG, th.text_dim, 0.5)
	c0 := im.Vec2{pos.x + 8, top}
	c1 := im.Vec2{pos.x + size.x * 0.30, bottom}
	dyn_curve_frame(dl, c0, c1, LO, HI, 12)
	cy := dyn_at(pic.ceiling, LO, HI, c1.y, c0.y)
	im.DrawList_AddLine(dl, {c0.x, cy}, {c1.x, cy}, ui.col(ui.with_alpha(base, 0.6)), 1)
	knee := pic.ceiling - pic.input // (the input level it starts limiting at)
	pts := [3]im.Vec2{
		{c0.x, dyn_at(LO + pic.input, LO, HI, c1.y, c0.y)},
		{dyn_at(knee, LO, HI, c0.x, c1.x), cy},
		{c1.x, cy},
	}
	if knee <= LO do pts[0], pts[1] = {c0.x, cy}, {c0.x, cy}
	im.DrawList_AddPolyline(dl, &pts[0], 3, ui.col(curve_c), 2)
	if pic.on && pic.level_db > LO {
		out := min(pic.level_db + pic.input, pic.ceiling)
		im.DrawList_AddCircleFilled(dl, {dyn_at(pic.level_db, LO, HI, c0.x, c1.x), dyn_at(out, LO, HI, c1.y, c0.y)}, 3.5, ui.col(ui.lighten(th.accent, 0.3)), 12)
	}
	dyn_text(dl, {c0.x + 4, c0.y + 1}, th.text_dim, fmt.tprintf("Ceiling %.1f dB", pic.ceiling))
	// Its reduction now.
	SCALE :: 24
	g0 := im.Vec2{c1.x + 16, top}
	g1 := im.Vec2{g0.x + 10, bottom}
	dyn_reduction_bar(dl, g0, g1, pic.reduction if pic.live else 0, SCALE, pic.on)
	if pic.live do dyn_text(dl, {g1.x + 6, top}, th.text if pic.reduction > 0.1 else th.text_dim, fmt.tprintf("-%.1f dB", pic.reduction))
	// The last seconds.
	h0 := im.Vec2{g1.x + 64, top}
	h1 := im.Vec2{pos.x + size.x - 8, bottom}
	grid := ui.col(ui.mix(ui.PLOT_BG, th.text, 0.07))
	for db := f32(6); db < SCALE; db += 6 {
		y := dyn_at(db, 0, SCALE, h0.y, h1.y)
		im.DrawList_AddLine(dl, {h0.x, y}, {h1.x, y}, grid, 1)
	}
	im.DrawList_AddRect(dl, h0, h1, ui.col(ui.mix(ui.PLOT_BG, th.text, 0.14)), 0)
	n := len(pic.history)
	if n >= 2 {
		xs := (h1.x - h0.x) / f32(n - 1)
		aa := dl.Flags
		dl.Flags -= {.AntiAliasedFill}
		out_c, gr_c := ui.col(ui.with_alpha(th.text, 0.12)), ui.col(ui.with_alpha(base, 0.55))
		for k in 1 ..< n {
			xa, xb := h0.x + f32(k - 1) * xs, h0.x + f32(k) * xs
			if k < len(pic.outs) {
				oa := dyn_at(pic.outs[k - 1], LO, HI, h1.y, h0.y)
				ob := dyn_at(pic.outs[k], LO, HI, h1.y, h0.y)
				im.DrawList_AddQuadFilled(dl, {xa, h1.y}, {xa, oa}, {xb, ob}, {xb, h1.y}, out_c)
			}
			ga := dyn_at(pic.history[k - 1], 0, SCALE, h0.y, h1.y)
			gb := dyn_at(pic.history[k], 0, SCALE, h0.y, h1.y)
			im.DrawList_AddQuadFilled(dl, {xa, h0.y}, {xa, ga}, {xb, gb}, {xb, h0.y}, gr_c)
		}
		dl.Flags = aa
	}
	hy := dyn_at(pic.ceiling, LO, HI, h1.y, h0.y)
	im.DrawList_AddLine(dl, {h0.x, hy}, {h1.x, hy}, ui.col(ui.with_alpha(base, 0.5)), 1)
	dyn_text(dl, {h0.x + 4, h0.y + 1}, th.text_dim, fmt.tprintf("Input +%.1f dB   Release %s", pic.input, dyn_ms(pic.release)))
}
