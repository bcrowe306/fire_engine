// The modulation effects' pictures (Chorus, Flanger, Phaser): each draws
// into a size it's given at the cursor, from plain values (the effect's
// settings, its sweep's phase now), so a controller's display and Pads'
// window can both use them.
//
// - Chorus: its delays on a time line, the left side's above and the
//   right's below, each voice's sweep a faint bar and where it is now a
//   dot (Delay 1's filled, Delay 2's a ring; its echo, by the feedback, a
//   fainter one at twice the time); the dry signal at 0.
// - Flanger: its comb's response along a linear axis to 10 kHz (the left
//   side filled, the right a line): its teeth spread and close as the
//   sweep moves the delay, sharper with more feedback.
// - Phaser: its response the same way, the notches swept around the
//   centre, the sweep's reach a band along the top.
// Each has its LFO's cycle at the top right, the sides' places on it now.
package pads

import "core:fmt"
import "core:math"

import "app:ui"
import im "deps:imgui"
import "fire:fx"

// A rate as read: "0.13 Hz", "4.0 Hz", "12 Hz".
@(private)
mod_hz_text :: proc(hz: f32) -> string {
	switch {
	case hz < 1:  return fmt.tprintf("%.2f Hz", hz)
	case hz < 10: return fmt.tprintf("%.1f Hz", hz)
	}
	return fmt.tprintf("%.0f Hz", hz)
}

// A picture's frame at the cursor, `size` big (an item named `id`): its
// background, its corners.
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

// What a picture shows, at its top left: `name` bright, `rest` dimmer.
@(private = "file")
pic_caption :: proc(dl: ^im.DrawList, at: im.Vec2, name, rest: string) {
	th := ui.theme()
	ui.text_push(.Label)
	defer ui.text_pop()
	cn := fmt.ctprintf("%s", name)
	cr := fmt.ctprintf("%s", rest)
	wn := im.CalcTextSize(cn).x
	wr := im.CalcTextSize(cr).x
	lh := im.GetTextLineHeight()
	im.DrawList_AddRectFilled(dl, {at.x - 4, at.y - 1}, {at.x + wn + 10 + wr + 4, at.y + lh + 1}, ui.col(ui.with_alpha(ui.PLOT_BG, 0.75)), 3)
	im.DrawList_AddText(dl, at, ui.col(ui.with_alpha(th.text, 0.9)), cn)
	im.DrawList_AddText(dl, {at.x + wn + 10, at.y}, ui.col(ui.with_alpha(th.text, 0.6)), cr)
}

// The left side's colour and the right's, from the picture's.
@(private = "file")
pic_sides :: proc(color: ui.Color) -> (left, right: ui.Color) {
	return color, ui.mix(color, ui.rgb(0x60b8ff), 0.55)
}

// One cycle of an LFO (a sine, else a triangle) in a box at `pos`,
// `size` big, with the left side's places on it (`left`, phases 0..1) and
// the right's.
@(private = "file")
pic_lfo :: proc(dl: ^im.DrawList, pos, size: im.Vec2, sine: bool, left, right: []f32, color: ui.Color) {
	th := ui.theme()
	shape :: proc(sine: bool, x: f32) -> f32 {
		f := x - math.floor(x)
		if sine do return math.sin(f * math.TAU)
		return 1 - abs(f * 2 - 1) * 2 // (the triangle: -1 at 0, 1 at a half)
	}
	im.DrawList_AddRectFilled(dl, pos, {pos.x + size.x, pos.y + size.y}, ui.col(ui.with_alpha(ui.PLOT_BG, 0.85)), 3)
	im.DrawList_AddRect(dl, pos, {pos.x + size.x, pos.y + size.y}, ui.col(ui.mix(ui.PLOT_BG, th.text, 0.2)), 3)
	N :: 48
	pts: [N]im.Vec2
	px := proc(pos, size: im.Vec2, x: f32) -> f32 { return pos.x + 4 + (size.x - 8) * x }
	py := proc(pos, size: im.Vec2, y: f32) -> f32 { return pos.y + size.y / 2 - y * (size.y / 2 - 4) }
	for k in 0 ..< N {
		x := f32(k) / (N - 1)
		pts[k] = {px(pos, size, x), py(pos, size, shape(sine, x))}
	}
	im.DrawList_AddPolyline(dl, &pts[0], N, ui.col(ui.mix(ui.PLOT_BG, color, 0.7)), 1.5)
	lc, rc := pic_sides(color)
	for ph in right {
		f := ph - math.floor(ph)
		im.DrawList_AddCircleFilled(dl, {px(pos, size, f), py(pos, size, shape(sine, f))}, 2.8, ui.col(ui.lighten(rc, 0.2)), 10)
	}
	for ph in left {
		f := ph - math.floor(ph)
		im.DrawList_AddCircleFilled(dl, {px(pos, size, f), py(pos, size, shape(sine, f))}, 2.8, ui.col(ui.lighten(lc, 0.35)), 10)
	}
}

// The LFO's box's place and size in a picture from `r0` to `r1`.
@(private = "file")
pic_lfo_box :: proc(r0, r1: im.Vec2) -> (pos, size: im.Vec2) {
	size = {min(f32(72), (r1.x - r0.x) * 0.12), min(f32(28), (r1.y - r0.y) * 0.42)}
	return {r1.x - 10 - size.x, r0.y + 6}, size
}

// "L" and "R" in the sides' colours at `at`.
@(private = "file")
pic_lr :: proc(dl: ^im.DrawList, at: im.Vec2, color: ui.Color) {
	lc, rc := pic_sides(color)
	ui.text_push(.Caption)
	defer ui.text_pop()
	im.DrawList_AddText(dl, at, ui.col(ui.lighten(lc, 0.3)), "L")
	im.DrawList_AddText(dl, {at.x + 12, at.y}, ui.col(ui.lighten(rc, 0.2)), "R")
}

// --- Chorus --------------------------------------------------------------------------------------

// The chorus's sweep at its widest (`fx` sweeps a delay up to 30 ms).
@(private = "file")
CHORUS_SWEEP :: 0.03

// The chorus with settings `p`, its sweep at `phase` (0..1), `size` big at
// the cursor: its delays on a time line (left above, right below), each
// voice's sweep and where it is now, the dry signal at 0, the echoes the
// feedback makes; `rate`: its rate as read.
@(private)
mod_chorus_picture :: proc(p: fx.Chorus_Params, phase: f32, rate: string, on: bool, size: im.Vec2, color: ui.Color) {
	th := ui.theme()
	dl, r0, r1 := pic_frame("chorus picture", size)
	x0, x1 := r0.x + 36, r1.x - 14
	top, bottom := r0.y + 22, r1.y - 6
	mid := (top + bottom) / 2
	half := (bottom - top) / 2
	pairs := clamp(p.voices, 1, 4)
	sweep := clamp(p.depth, 0, 1) * CHORUS_SWEEP
	avg := (p.delay[0] + p.delay[1]) * 0.5
	// The time line: as long as the longest delay needs (20, 40 or 80 ms:
	// steps, so turning a knob moves the voices, not the scale).
	longest := max(p.delay[0], p.delay[1]) + 1.5 * sweep
	span: f32 = 0.02
	for span < longest * 1.08 && span < 0.08 do span *= 2
	xt :: proc(x0, x1, span, s: f32) -> f32 { return x0 + (x1 - x0) * clamp(s / span, 0, 1) }
	step: f32 = 0.005 if span <= 0.02 else 0.01
	ui.text_push(.Caption)
	lh := im.GetTextLineHeight()
	for s := step; s < span - step * 0.5; s += step {
		x := xt(x0, x1, span, s)
		im.DrawList_AddLine(dl, {x, top}, {x, bottom}, ui.col(ui.mix(ui.PLOT_BG, th.text, 0.08)), 1)
		im.DrawList_AddText(dl, {x + 3, r0.y + 5}, ui.col(ui.mix(ui.PLOT_BG, th.text, 0.38)), fmt.ctprintf("%.0f ms", s * 1000))
	}
	ui.text_pop()
	im.DrawList_AddLine(dl, {x0, mid}, {x1, mid}, ui.col(ui.mix(ui.PLOT_BG, th.text, 0.18)), 1)
	wet, dry := fx.equal_power(p.wet)
	// The dry signal: a bar at 0, as tall as it is loud.
	im.DrawList_AddLine(dl, {x0, mid - half * dry}, {x0, mid + half * dry}, ui.col(ui.mix(ui.PLOT_BG, th.text, 0.5)), 3)
	fb := abs(clamp(p.feedback, -0.95, 0.95))
	lc, rc := pic_sides(color)
	lfo_l := make([]f32, pairs * 2, context.temp_allocator)
	lfo_r := make([]f32, pairs * 2, context.temp_allocator)
	row := half / f32(pairs)
	for k in 0 ..< pairs {
		offset := f32(k) * 0.25 / f32(pairs)
		t: f32 = f32(k) / f32(pairs - 1) if pairs > 1 else 0
		for side in 0 ..< 2 { // (the pair's two delays: Delay 1's time and Delay 2's)
			base := p.delay[side] + (avg - p.delay[side]) * t
			for ch in 0 ..< 2 {
				ph := phase + offset + (0.25 if ch == 1 else 0) + (0.5 if side == 1 else 0)
				if ch == 0 do lfo_l[k * 2 + side] = ph
				else do lfo_r[k * 2 + side] = ph
				m := math.sin(ph * math.TAU) * 0.5 + 1
				d := m * sweep + base
				y := mid - (f32(k) + 0.5) * row if ch == 0 else mid + (f32(k) + 0.5) * row
				c := lc if ch == 0 else rc
				if side == 1 do c = ui.mix(c, th.text, 0.3)
				// Its sweep, faint; where it is now; its echo.
				im.DrawList_AddLine(dl, {xt(x0, x1, span, base + 0.5 * sweep), y}, {xt(x0, x1, span, base + 1.5 * sweep) + 1, y}, ui.col(ui.with_alpha(c, 0.28)), 2)
				if fb > 0.05 && 2 * d < span do im.DrawList_AddCircleFilled(dl, {xt(x0, x1, span, 2 * d), y}, 2.2, ui.col(ui.with_alpha(c, 0.15 + 0.6 * fb)), 8)
				dc := ui.col(ui.with_alpha(c, 0.35 + 0.65 * min(wet * 1.4, 1)))
				if side == 0 do im.DrawList_AddCircleFilled(dl, {xt(x0, x1, span, d), y}, 3.4, dc, 10)
				else do im.DrawList_AddCircle(dl, {xt(x0, x1, span, d), y}, 3.2, dc, 10, 1.6) // (Delay 2's: rings)
			}
		}
	}
	ui.text_push(.Caption)
	im.DrawList_AddText(dl, {r0.x + 10, mid - lh}, ui.col(ui.lighten(lc, 0.3)), "L")
	im.DrawList_AddText(dl, {r0.x + 10, mid}, ui.col(ui.lighten(rc, 0.2)), "R")
	ui.text_pop()
	pic_caption(dl, {r0.x + 10, r0.y + 4}, "Chorus" if on else "Chorus (off)", fmt.tprintf("%d %s · %s · %.0f%% feedback", pairs, "voice" if pairs == 1 else "voices", rate, p.feedback * 100))
	bp, bs := pic_lfo_box(r0, r1)
	pic_lfo(dl, bp, bs, true, lfo_l[:], lfo_r[:], color)
}

// --- Flanger -------------------------------------------------------------------------------------

// The flanger's delay (seconds) on side `ch` (0 left, 1 right) at `phase`,
// as `fx.flanger_render` sweeps it.
@(private)
mod_flanger_delay :: proc(p: fx.Flanger_Params, phase: f32, ch: int) -> f32 {
	BUFFER :: 0.0005
	ph := phase - p.offset / 2 + (p.offset if ch == 1 else 0)
	ph -= math.floor(ph)
	tri := 1 - abs(ph * 2 - 1)
	mod := p.depth * (tri * 2 - 1) + 1
	return (1 / fx.key_to_hz(p.center) - BUFFER) * mod + BUFFER
}

// The top of the flanger's picture's frequency axis (linear: its comb's
// teeth evenly spaced, as a comb's are).
@(private = "file")
FLANGER_TOP_HZ :: 10_000

// The flanger's response at `n` points from 0 to `FLANGER_TOP_HZ` (dB)
// with its delay at `d` seconds: the dry signal and the comb (the delay
// fed back), mixed; each point the mean of its stretch's (where the teeth
// are closer than the points, their average).
@(private)
mod_flanger_response :: proc(p: fx.Flanger_Params, d: f32, n: int) -> []f32 {
	out := make([]f32, n, context.temp_allocator)
	wet, dry := fx.equal_power(p.wet)
	fb := clamp(p.feedback, -0.99, 0.99)
	SUB :: 4
	df := f32(FLANGER_TOP_HZ) / f32(n - 1) / SUB // (between sub-points)
	// A delay of d at each sub-point, a turn of the one before (from half a
	// point under 0 Hz: each point's stretch centred on it).
	w0 := -math.TAU * d * df * (SUB / 2 - 0.5)
	z := complex(math.cos(w0), -math.sin(w0))
	turn := complex(math.cos(math.TAU * d * df), -math.sin(math.TAU * d * df))
	for &v in out {
		power: f32 = 0
		for _ in 0 ..< SUB {
			h := complex(dry, 0) + complex(wet, 0) * z / (1 - complex(fb, 0) * z)
			power += real(h) * real(h) + imag(h) * imag(h)
			z *= turn
		}
		z /= complex(abs(z), 0) // (kept on the unit circle)
		v = 10 * math.log10(max(power / SUB, 1e-10))
	}
	return out
}

// The flanger with settings `p`, its sweep at `phase` (0..1), `size` big
// at the cursor: its comb's response as it is now along a linear axis to
// 10 kHz (the left side filled, the right a line), its teeth spreading and
// closing as the sweep moves the delay.
@(private)
mod_flanger_picture :: proc(p: fx.Flanger_Params, phase: f32, rate: string, on: bool, size: im.Vec2, color: ui.Color) {
	th := ui.theme()
	dl, r0, r1 := pic_frame("flanger picture", size)
	pad: f32 = 8
	x0, x1 := r0.x + pad, r1.x - pad
	top, bottom := r0.y + pad, r1.y - pad
	LO :: -30
	HI :: 18
	ydb :: proc(db, top, bottom: f32) -> f32 { return bottom - (clamp(db, LO, HI) - LO) / (HI - LO) * (bottom - top) }
	ui.text_push(.Caption)
	lh := im.GetTextLineHeight()
	for f := 1000; f < FLANGER_TOP_HZ; f += 1000 {
		x := x0 + (x1 - x0) * f32(f) / FLANGER_TOP_HZ
		im.DrawList_AddLine(dl, {x, top}, {x, bottom}, ui.col(ui.mix(ui.PLOT_BG, th.text, 0.16 if f % 5000 == 0 else 0.08)), 1)
		if f % 2000 == 0 do im.DrawList_AddText(dl, {x + 3, bottom - lh}, ui.col(ui.mix(ui.PLOT_BG, th.text, 0.4)), fmt.ctprintf("%dk", f / 1000))
	}
	ui.text_pop()
	for db := f32(LO); db <= HI; db += 12 do im.DrawList_AddLine(dl, {x0, ydb(db, top, bottom)}, {x1, ydb(db, top, bottom)}, ui.col(ui.mix(ui.PLOT_BG, th.text, 0.22 if db == 0 else 0.08)), 1)
	n := max(int((x1 - x0) / 2), 2)
	lc, rc := pic_sides(color)
	dly := mod_flanger_delay(p, phase, 0)
	dr := mod_flanger_delay(p, phase, 1)
	curve :: proc(dl: ^im.DrawList, db: []f32, x0, x1, top, bottom: f32, c: ui.Color, width: f32, fill: bool) {
		n := len(db)
		pts := make([]im.Vec2, n, context.temp_allocator)
		for v, k in db do pts[k] = {x0 + (x1 - x0) * f32(k) / f32(n - 1), ydb(v, top, bottom)}
		if fill do for k in 1 ..< n do im.DrawList_AddQuadFilled(dl, {pts[k - 1].x, bottom}, pts[k - 1], pts[k], {pts[k].x, bottom}, ui.col(ui.with_alpha(c, 0.2)))
		im.DrawList_AddPolyline(dl, &pts[0], i32(n), ui.col(c), width)
	}
	curve(dl, mod_flanger_response(p, dly, n), x0, x1, top, bottom, lc, 2, true)
	curve(dl, mod_flanger_response(p, dr, n), x0, x1, top, bottom, ui.with_alpha(ui.lighten(rc, 0.1), 0.85), 1.4, false)
	pic_caption(dl, {r0.x + 10, r0.y + 4}, "Flanger" if on else "Flanger (off)", fmt.tprintf("%.2f ms · %s · %+.0f%% feedback", dly * 1000, rate, p.feedback * 100))
	bp, bs := pic_lfo_box(r0, r1)
	pic_lfo(dl, bp, bs, false, {phase - p.offset / 2}, {phase + p.offset / 2}, color)
	pic_lr(dl, {bp.x - 32, bp.y + 1}, color)
}

// --- Phaser --------------------------------------------------------------------------------------

// The phaser's centre (a key) on side `ch` at `phase`, as
// `fx.phaser_render` sweeps it.
@(private)
mod_phaser_key :: proc(p: fx.Phaser_Params, phase: f32, ch: int) -> f32 {
	x := phase + (p.offset * 0.5 if ch == 0 else -p.offset * 0.5)
	x -= math.floor(x)
	tri := 1 - abs(x * 2 - 1)
	return p.center + (tri * 2 - 1) * p.depth
}

// The phaser's response at `n` points along the plot (dB) at centre `key`:
// its twelve all-passes (the blend taking four, eight or twelve), fed back
// through their band (`fx`'s phaser filter, as a linear filter: no
// saturation), mixed with the dry signal.
@(private)
mod_phaser_response :: proc(p: fx.Phaser_Params, key: f32, sr: f32, n: int) -> []f32 {
	out := make([]f32, n, context.temp_allocator)
	nyq := sr * 0.45
	fc := clamp(fx.key_to_hz(key), 1, nyq)
	g := math.tan(math.PI * fc / sr)
	g_lo := min(g * 20, 0.9) // (the feedback's band: `phaser_filter_render`'s CLEAR)
	g_hi := g / 20
	res := clamp(p.feedback, 0, 1)
	drv := res * 0.5 + 1
	p1 := clamp(1 - p.blend, 0, 1)
	p5 := clamp(p.blend - 1, 0, 1)
	p3 := 1 - p1 - p5
	mix := clamp(p.wet, 0, 1)
	for &v, k in out {
		f := min(ui.x_freq(f32(k) / f32(n - 1)), nyq)
		t := math.tan(math.PI * f / sr)
		ap := complex(-1, t / g) / complex(1, t / g) // (one all-pass: 1 - 2 × its low-pass)
		a4 := ap * ap
		a4 *= a4
		a8 := a4 * a4
		fwd := complex(p1, 0) * a4 + complex(p3, 0) * a8 + complex(p5, 0) * a8 * a4
		lo := 1 / complex(1, t / g_lo)
		band := lo * (1 - 1 / complex(1, t / g_hi))
		w := math.TAU * f / sr
		z := complex(math.cos(w), -math.sin(w)) // (the feedback's sample behind)
		x := complex(drv, 0) / (1 - complex(res, 0) * band * z * fwd)
		h := (1 + fwd * x) * 0.5
		h = 1 + (h - 1) * complex(mix, 0)
		v = 20 * math.log10(max(abs(h), 1e-5))
	}
	return out
}

// The phaser with settings `p`, its sweep at `phase` (0..1), `size` big at
// the cursor at sample rate `sr`: its response now (the left side filled,
// the right a line), the sweep's reach a band along the top with the
// centre marked and where each side is now.
@(private)
mod_phaser_picture :: proc(p: fx.Phaser_Params, phase: f32, rate: string, on: bool, sr: f32, size: im.Vec2, color: ui.Color) {
	N :: 200
	th := ui.theme()
	lc, rc := pic_sides(color)
	kl := mod_phaser_key(p, phase, 0)
	kr := mod_phaser_key(p, phase, 1)
	curves := [2]ui.Plot_Curve{
		{db = mod_phaser_response(p, kr, sr, N), color = ui.with_alpha(ui.lighten(rc, 0.1), 0.85), width = 1.4},
		{db = mod_phaser_response(p, kl, sr, N), color = lc, fill = true, width = 2},
	}
	ui.response_plot("phaser picture", curves[:], nil, size, -30, 18)
	r0, r1 := im.GetItemRectMin(), im.GetItemRectMax()
	dl := im.GetWindowDrawList()
	pad: f32 = 8
	x0, x1 := r0.x + pad, r1.x - pad
	xk :: proc(x0, x1, key: f32) -> f32 { return x0 + (x1 - x0) * ui.freq_x(fx.key_to_hz(key)) }
	// The sweep's reach, along the top; the centre; each side now.
	yb := r0.y + 6
	lo, hi := xk(x0, x1, p.center - p.depth), xk(x0, x1, p.center + p.depth)
	im.DrawList_AddRectFilled(dl, {lo, yb - 2}, {hi, yb + 2}, ui.col(ui.with_alpha(color, 0.3)), 2)
	xc := xk(x0, x1, p.center)
	im.DrawList_AddLine(dl, {xc, yb - 5}, {xc, yb + 5}, ui.col(ui.mix(ui.PLOT_BG, th.text, 0.6)), 1.5)
	im.DrawList_AddCircleFilled(dl, {xk(x0, x1, kr), yb}, 3.5, ui.col(ui.lighten(rc, 0.2)), 10)
	im.DrawList_AddCircleFilled(dl, {xk(x0, x1, kl), yb}, 3.5, ui.col(ui.lighten(lc, 0.35)), 10)
	pic_caption(dl, {r0.x + 10, r0.y + 4}, "Phaser" if on else "Phaser (off)", fmt.tprintf("%s · ±%.0f st · %s · %+.0f%% feedback", sf_hz(fx.key_to_hz(kl)), p.depth, rate, p.feedback * 100))
	bp, bs := pic_lfo_box(r0, r1)
	pic_lfo(dl, bp, bs, false, {phase + p.offset * 0.5}, {phase - p.offset * 0.5}, color)
	pic_lr(dl, {bp.x - 32, bp.y + 1}, color)
}
