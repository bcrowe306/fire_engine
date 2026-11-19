// Tone's pictures (the EQ, the Filter, the pad's EQ): what each does to
// the sound, a response on a log frequency axis in dB, drawn at the cursor
// into a size they're given from plain values (the responses, the bands'
// places, the spectrum of what comes out now), so any panel can use them:
// Push 2's display now (ui_ctl_fx_tone.odin), Pads' window later.
package pads

import "core:fmt"
import "core:math"

import "app:ui"
import im "deps:imgui"
import "fire:dsp"
import "fire:fx"

// The bands' colours (low, band, high): ProEq's first, third and fifth.
@(private) TONE_BAND_COLORS := [3]u32{0xff9f43, 0x7bd88f, 0x58a6ff}

// A band's mark on a tone picture: a ring at its frequency, on the curve.
@(private)
Tone_Mark :: struct {
	hz:    f32,      // where it sits
	label: string,   // in its ring
	color: ui.Color,
	own:   []f32,    // its own response (RESPONSE_POINTS dB along the axis), nil: none
	dim:   bool,     // drawn faint (not in use)
}

// The responses measured lately (an impulse through the real filter),
// kept until their settings change: a few, for an EQ's bands and a filter.
@(private = "file") tone_curves: [6]Filter_Curve
@(private = "file") tone_next: int

// The impulse's length: long enough for the lowest decade's bins (6 Hz
// apart at 48 kHz) and a low resonance's ring.
@(private = "file") TONE_IMPULSE :: 8192

// [control] The response of a filter with `p` into `c` (an impulse
// through it, its spectrum read between bins at the plot's points: no
// steps in the lowest octaves).
@(private = "file")
tone_measure :: proc(c: ^Filter_Curve, p: fx.Filter_Params, sr: f64) {
	c.params, c.sr, c.set = p, sr, true
	N :: TONE_IMPULSE
	f := new(fx.Filter_State, context.temp_allocator)
	x := make([]f32, N, context.temp_allocator)
	y := make([]f32, N, context.temp_allocator)
	r := make([]f32, N, context.temp_allocator)
	keys := make([]f32, 64, context.temp_allocator)
	for &k in keys do k = p.cutoff
	x[0] = 0.25 // (small: the nonlinear models stay near their linear selves)
	pp := p
	for at := 0; at < N; at += 64 {
		in_ := [2][]f32{x[at:at + 64], x[at:at + 64]}
		out := [2][]f32{y[at:at + 64], r[at:at + 64]}
		fx.filter_render(f, &pp, keys, &in_, &out, sr)
	}
	fft: dsp.Real_Fft
	dsp.real_fft_init(&fft, N, allocator = context.temp_allocator)
	spec := make([]complex64, N / 2, context.temp_allocator)
	dsp.real_fft_forward(&fft, y, spec)
	for &v, k in c.db {
		at := clamp(f64(ui.x_freq(f32(k) / (RESPONSE_POINTS - 1))) / sr * N, 1, N / 2 - 2)
		b := int(at)
		g := f64(abs(spec[b])) + (f64(abs(spec[b + 1])) - f64(abs(spec[b]))) * (at - f64(b))
		v = f32(20 * math.log10(max(g / 0.25, 1e-6)))
	}
}

// [control] The response (dB at RESPONSE_POINTS along the log axis) of a
// filter with `p` at rate `sr`: measured once for each settings (a copy,
// in the temp allocator).
@(private)
tone_filter_db :: proc(p: fx.Filter_Params, sr: f64) -> []f32 {
	out := make([]f32, RESPONSE_POINTS, context.temp_allocator)
	for &c in tone_curves do if c.set && c.params == p && c.sr == sr {
		copy(out, c.db[:])
		return out
	}
	c := &tone_curves[tone_next]
	tone_next = (tone_next + 1) % len(tone_curves)
	tone_measure(c, p, sr)
	copy(out, c.db[:])
	return out
}

// An EQ's bands' responses (each band's own, dB along the axis), and
// their sum: the whole EQ (its bands in series).
@(private)
tone_eq_db :: proc(p: fx.Eq_Params, sr: f64) -> (total: []f32, own: [3][]f32) {
	total = make([]f32, RESPONSE_POINTS, context.temp_allocator)
	for b in 0 ..< 3 {
		own[b] = tone_filter_db(fx.eq_filter(b, p.bands[b]), sr)
		for v, k in own[b] do total[k] += v
	}
	return
}

// The frequencies of the pad's EQ's bands: a low shelf, a bell and a
// high shelf, 100 Hz to 8 kHz evenly in octaves (dsp.eq_create(3)'s).
@(private)
tone_pad_eq_hz :: proc(b: int) -> f32 {
	return 100 * math.pow(80, f32(b) / 2)
}

// The pad's EQ's response with gains `gains` (dB; low, mid, high): each
// band's own and the whole, exactly (the state-variable bands' design).
@(private)
tone_pad_eq_db :: proc(gains: [3]f32, sr: f64) -> (total: []f32, own: [3][]f32) {
	total = make([]f32, RESPONSE_POINTS, context.temp_allocator)
	modes := [3]dsp.Filter_Mode{.Low_Shelf, .Bell, .High_Shelf}
	for b in 0 ..< 3 {
		own[b] = make([]f32, RESPONSE_POINTS, context.temp_allocator)
		c := dsp.svf_design(modes[b], f64(tone_pad_eq_hz(b)), 0.707, f64(gains[b]), sr)
		for &v, k in own[b] {
			g, _ := dsp.svf_response(&c, f64(ui.x_freq(f32(k) / (RESPONSE_POINTS - 1))), sr)
			v = f32(20 * math.log10(max(g, 1e-6)))
			total[k] += v
		}
	}
	return
}

// Response `db` heard at `mix` (a Perform effect pressed that hard: the
// dry sound with it), in place: as if in phase, which it nearly is.
@(private)
tone_blend :: proc(db: []f32, mix: f32) {
	if mix >= 1 do return
	x := clamp(mix, 0, 1)
	for &v in db do v = 20 * math.log10(max((1 - x) + x * math.pow(10, v / 20), 1e-6))
}

// The dB range either side of 0 a band picture shows: 12, or 18 (24)
// while a gain, or the response's top, goes past 11 (17).
@(private)
tone_range :: proc(gains: []f32, total: []f32) -> f32 {
	most: f32 = 0
	for g in gains do most = max(most, abs(g))
	for v in total do most = max(most, v)
	return 24 if most > 17 else (18 if most > 11 else 12)
}

// Response `db` (along the axis) at `hz`, between its points.
@(private)
tone_at :: proc(db: []f32, hz: f32) -> f32 {
	n := len(db)
	if n == 0 do return 0
	at := clamp(ui.freq_x(hz) * f32(n - 1), 0, f32(n - 1))
	i := int(at)
	return db[i] + (db[min(i + 1, n - 1)] - db[i]) * (at - f32(i))
}

// A frequency as it reads (Hz, or kHz past one).
@(private)
tone_hz :: proc(hz: f32) -> string {
	if hz >= 10_000 do return fmt.tprintf("%.0f kHz", hz / 1000)
	if hz >= 1000 do return fmt.tprintf("%.1f kHz", hz / 1000)
	return fmt.tprintf("%.0f Hz", hz)
}

// A tone picture, `size` big: response `total` (dB along the log axis,
// `lo..hi` bottom to top) over a grid and the spectrum of what comes out
// now (`spec`, dB as `spectrum` gives it; nil: none), shaded to 0 dB
// (`to_zero`: an EQ's boosts and cuts) or to the floor (a filter's pass
// band); each mark a ring on it, the `focus` one (-1: none) bright with
// its own response filled; `caption` at the top left, `right` at the top
// right. `color` is the curve's (dim it for an effect that's off).
@(private)
tone_picture :: proc(total: []f32, marks: []Tone_Mark, focus: int, spec: []f32, caption, right: string, lo, hi: f32, to_zero: bool, size: im.Vec2, color: ui.Color) {
	th := ui.theme()
	pos := im.GetCursorScreenPos()
	dl := im.GetWindowDrawList()
	ui.text_push(.Label)
	defer ui.text_pop()
	lh := im.GetTextLineHeight()
	im.DrawList_AddRectFilled(dl, pos, {pos.x + size.x, pos.y + size.y}, ui.col(ui.PLOT_BG), th.radius)
	x0, x1 := pos.x + 8, pos.x + size.x - 8
	top, bottom := pos.y + 4, pos.y + size.y - 4
	yd :: proc(db, lo, hi, top, bottom: f32) -> f32 { return bottom - (clamp(db, lo, hi) - lo) / (hi - lo) * (bottom - top) }
	xk :: proc(k, n: int, x0, x1: f32) -> f32 { return x0 + (x1 - x0) * f32(k) / f32(n - 1) }
	// The grid: decades a little stronger, every 6 dB faint, 0 dB stronger.
	faint, decade := ui.mix(ui.PLOT_BG, th.text, 0.05), ui.mix(ui.PLOT_BG, th.text, 0.12)
	for dec := f32(10); dec < 20_000; dec *= 10 do for k in 1 ..< 10 {
		hz := dec * f32(k)
		if hz < 20 || hz > 20_000 do continue
		x := x0 + (x1 - x0) * ui.freq_x(hz)
		im.DrawList_AddLine(dl, {x, top}, {x, bottom}, ui.col(decade if k == 1 else faint), 1)
	}
	for db := math.ceil(lo / 6) * 6; db <= hi; db += 6 {
		y := yd(db, lo, hi, top, bottom)
		im.DrawList_AddLine(dl, {x0, y}, {x1, y}, ui.col(ui.mix(ui.PLOT_BG, th.text, 0.22) if abs(db) < 0.01 else faint), 1)
	}
	label_c := ui.col(ui.mix(ui.PLOT_BG, th.text, 0.38))
	names := [3]cstring{"100", "1k", "10k"}
	for f, k in ([3]f32{100, 1000, 10_000}) do im.DrawList_AddText(dl, {x0 + (x1 - x0) * ui.freq_x(f) + 3, bottom - lh}, label_c, names[k])
	// The spectrum, on its own scale (its floor at the bottom).
	flags := dl.Flags
	dl.Flags -= {.AntiAliasedFill} // (side by side, anti-aliased quads leave seams)
	if n := len(spec); n >= 2 {
		pts := make([]im.Vec2, n, context.temp_allocator)
		for d, k in spec do pts[k] = {xk(k, n, x0, x1), bottom - clamp((d + 36) / 60, 0, 1) * (bottom - top)}
		fill := ui.col(ui.with_alpha(th.text, 0.10))
		for k in 1 ..< n do im.DrawList_AddQuadFilled(dl, {pts[k - 1].x, bottom}, pts[k - 1], pts[k], {pts[k].x, bottom}, fill)
		im.DrawList_AddPolyline(dl, &pts[0], i32(n), ui.col(ui.with_alpha(th.text, 0.30)), 1)
	}
	// The whole response, shaded.
	n := len(total)
	if n < 2 {
		dl.Flags = flags
		im.Dummy(size)
		return
	}
	base := yd(0, lo, hi, top, bottom) if to_zero else bottom
	pts := make([]im.Vec2, n, context.temp_allocator)
	for d, k in total do pts[k] = {xk(k, n, x0, x1), yd(d, lo, hi, top, bottom)}
	shade := ui.col(ui.with_alpha(color, 0.16))
	for k in 1 ..< n do im.DrawList_AddQuadFilled(dl, {pts[k - 1].x, base}, pts[k - 1], pts[k], {pts[k].x, base}, shade)
	// The focused band's own, filled in its colour.
	if focus >= 0 && focus < len(marks) && len(marks[focus].own) == n {
		mk := marks[focus]
		own := make([]im.Vec2, n, context.temp_allocator)
		for d, k in mk.own do own[k] = {xk(k, n, x0, x1), yd(d, lo, hi, top, bottom)}
		zero := yd(0, lo, hi, top, bottom)
		bc := ui.col(ui.with_alpha(mk.color, 0.22))
		for k in 1 ..< n do im.DrawList_AddQuadFilled(dl, {own[k - 1].x, zero}, own[k - 1], own[k], {own[k].x, zero}, bc)
		im.DrawList_AddPolyline(dl, &own[0], i32(n), ui.col(ui.with_alpha(mk.color, 0.8)), 1.5)
	}
	dl.Flags = flags
	im.DrawList_AddPolyline(dl, &pts[0], i32(n), ui.col(color), 2)
	// The marks, the focused one last (on top).
	for i in 0 ..= len(marks) {
		b := i if i < len(marks) else focus
		if b < 0 || b >= len(marks) || (i < len(marks) && b == focus) do continue
		mk := marks[b]
		p := im.Vec2{x0 + (x1 - x0) * ui.freq_x(mk.hz), yd(tone_at(total, mk.hz), lo, hi, top, bottom)}
		p.y = clamp(p.y, top + 7, bottom - 7)
		c := mk.color if !mk.dim else ui.mix(ui.PLOT_BG, th.text, 0.4)
		label := fmt.ctprintf("%s", mk.label)
		ts := im.CalcTextSize(label)
		if b == focus {
			im.DrawList_AddCircleFilled(dl, p, 7.5, ui.col(c), 20)
			im.DrawList_AddText(dl, {p.x - ts.x / 2, p.y - ts.y / 2}, ui.col(ui.PLOT_BG), label)
		} else {
			im.DrawList_AddCircleFilled(dl, p, 7, ui.col(ui.with_alpha(ui.PLOT_BG, 0.85)), 20)
			im.DrawList_AddCircle(dl, p, 7, ui.col(c), 20, 1.5)
			im.DrawList_AddText(dl, {p.x - ts.x / 2, p.y - ts.y / 2}, ui.col(c), label)
		}
	}
	// The captions.
	if caption != "" do im.DrawList_AddText(dl, {x0 + 2, top}, ui.col(th.text), fmt.ctprintf("%s", caption))
	if right != "" {
		r := fmt.ctprintf("%s", right)
		im.DrawList_AddText(dl, {x1 - im.CalcTextSize(r).x - 2, top}, label_c, r)
	}
	im.Dummy(size)
}
