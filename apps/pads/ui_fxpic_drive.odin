// The drive effects' pictures (Distortion, Ring mod; the old projects'
// Saturation and Bit-crusher are distortions now): each draws into a size
// it's given at the cursor, from plain values (the effect's settings, the
// output's spectrum when there is one), so a controller's display and
// Pads' window can both use them.
//
// - Distortion: three panes. Its transfer curve (what each input level
//   comes out as, the dry signal's diagonal behind; a bit-crusher's steps,
//   a down-sampler's 1:1 line, since it holds in time, not in level); a
//   sine through the real distortion (fx.distortion_render, filter and mix
//   included) over the clean sine; its filter's response (measured, before
//   or after the curve), the output's spectrum behind it when the slot is
//   heard.
// - Ring mod: two panes. A tone times the carrier in time (the carrier
//   faint, the tone fainter); and in frequency: the tone, the two
//   sidebands it becomes (its frequency plus and minus the carrier's), the
//   carrier marked, the output's spectrum behind when heard.
package pads

import "core:fmt"
import "core:math"

import "app:ui"
import im "deps:imgui"
import "fire:dsp"
import "fire:fx"

// --- shared -------------------------------------------------------------------------------------

// A pane of a picture: its background from `r0` to `r1`.
@(private = "file")
drv_pane :: proc(dl: ^im.DrawList, r0, r1: im.Vec2) {
	im.DrawList_AddRectFilled(dl, r0, r1, ui.col(ui.PLOT_BG), ui.theme().radius)
	im.DrawList_AddRect(dl, r0, r1, ui.col(ui.mix(ui.PLOT_BG, ui.theme().text, 0.1)), ui.theme().radius)
}

// What a pane shows, at its top left: `name` bright, `rest` dimmer, on a
// backing so lines under it don't cross it.
@(private = "file")
drv_caption :: proc(dl: ^im.DrawList, at: im.Vec2, name, rest: string) {
	th := ui.theme()
	ui.text_push(.Caption)
	defer ui.text_pop()
	cn := fmt.ctprintf("%s", name)
	cr := fmt.ctprintf("%s", rest)
	wn := im.CalcTextSize(cn).x
	wr := im.CalcTextSize(cr).x if rest != "" else 0
	lh := im.GetTextLineHeight()
	gap: f32 = 8 if rest != "" else 0
	im.DrawList_AddRectFilled(dl, {at.x - 3, at.y - 1}, {at.x + wn + gap + wr + 3, at.y + lh + 1}, ui.col(ui.with_alpha(ui.PLOT_BG, 0.8)), 3)
	im.DrawList_AddText(dl, at, ui.col(ui.with_alpha(th.text, 0.92)), cn)
	if rest != "" do im.DrawList_AddText(dl, {at.x + wn + gap, at.y}, ui.col(ui.with_alpha(th.text, 0.6)), cr)
}

// A frequency as read: "2.50 Hz", "440 Hz", "1.20 kHz".
@(private)
drv_hz_text :: proc(hz: f32) -> string {
	switch {
	case hz < 10:    return fmt.tprintf("%.2f Hz", hz)
	case hz < 1000:  return fmt.tprintf("%.0f Hz", hz)
	case hz < 10000: return fmt.tprintf("%.2f kHz", hz / 1000)
	}
	return fmt.tprintf("%.1f kHz", hz / 1000)
}

// The x of `hz` on a log axis (20 Hz..20 kHz) from `x0` to `x1`.
@(private = "file")
drv_fx :: proc(x0, x1, hz: f32) -> f32 { return x0 + (x1 - x0) * ui.freq_x(hz) }

// A log frequency axis's decades (100, 1k, 10k) from `x0` to `x1`, top to
// bottom, labelled at the bottom left of each line.
@(private = "file")
drv_decades :: proc(dl: ^im.DrawList, x0, x1, top, bottom: f32) {
	th := ui.theme()
	ui.text_push(.Caption)
	defer ui.text_pop()
	lh := im.GetTextLineHeight()
	for d in ([3]f32{100, 1000, 10000}) {
		x := drv_fx(x0, x1, d)
		im.DrawList_AddLine(dl, {x, top}, {x, bottom}, ui.col(ui.mix(ui.PLOT_BG, th.text, 0.08)), 1)
		im.DrawList_AddText(dl, {x + 3, bottom - lh}, ui.col(ui.mix(ui.PLOT_BG, th.text, 0.32)), "100" if d == 100 else ("1k" if d == 1000 else "10k"))
	}
}

// An output spectrum (dB at RESPONSE_POINTS log-spaced points, as
// `spectrum_of` gives it: -36 the floor) filled faintly from `bottom`, on
// a scale from `lo` to `hi` dB.
@(private = "file")
drv_spectrum_fill :: proc(dl: ^im.DrawList, spec: []f32, x0, x1, top, bottom, lo, hi: f32, color: ui.Color) {
	n := len(spec)
	if n < 2 do return
	prev: im.Vec2
	for v, k in spec {
		x := x0 + (x1 - x0) * f32(k) / f32(n - 1)
		y := bottom - clamp((v - lo) / (hi - lo), 0, 1) * (bottom - top)
		if k > 0 {
			im.DrawList_AddQuadFilled(dl, prev, {x, y}, {x, bottom}, {prev.x, bottom}, ui.col(ui.with_alpha(color, 0.16)))
			im.DrawList_AddLine(dl, prev, {x, y}, ui.col(ui.with_alpha(color, 0.35)), 1)
		}
		prev = {x, y}
	}
}

// --- Distortion ---------------------------------------------------------------------------------

// The types as their dropdown names them (DISTORTION_NAMES), capitalised for a caption.
@(private = "file")
DRV_TYPE_CAPTION := [fx.Distortion_Type]string {
	.Soft_Clip = "Soft clip", .Hard_Clip = "Hard clip", .Linear_Fold = "Linear fold",
	.Sine_Fold = "Sine fold", .Bit_Crush = "Bit crush", .Down_Sample = "Down sample",
}

// What a distortion's Drive means for the two types that don't take it as
// a gain (as fx's distortion_drive works it out, private there): the bit
// crusher's step (full scale is ±1), the down-sampler's hold in seconds.
@(private)
drv_crush_step :: proc(drive_db: f32) -> f32 {
	x := max(clamp(drive_db, -30, 30) + 30, 0) / 60
	return clamp(x * x, 32.0 / 2147483647, 1)
}

// The down-sampler's hold (seconds) at `drive_db`.
@(private)
drv_hold_seconds :: proc(drive_db: f32) -> f32 {
	return max(1 / drv_crush_step(drive_db) * 0.99, 1) / 88200
}

// How Drive reads for type `t`: "+6.0 dB", "4.3 bits", "held 12 samples
// (4.00 kHz)"; `short`, as a knob has room for: the rate it's held at.
@(private)
drv_drive_text :: proc(t: fx.Distortion_Type, drive_db: f32, sr: f64, short := false) -> string {
	#partial switch t {
	case .Bit_Crush:
		bits := math.log2(2 / drv_crush_step(drive_db))
		return fmt.tprintf("%.1f bits", bits)
	case .Down_Sample:
		n := f64(drv_hold_seconds(drive_db)) * sr
		if n > 1e5 do return "frozen" if short else "held (frozen)"
		rate := drv_hz_text(f32(sr / max(n, 1)))
		if short do return rate
		return fmt.tprintf("held %.0f samples (%s)", max(n, 1), rate)
	}
	return fmt.tprintf("%+.1f dB", drive_db)
}

// How the filter's Blend reads: "Low", "Band", "High", or between two
// ("Low 70% · Band").
@(private)
drv_blend_text :: proc(blend: f32) -> string {
	b := clamp(blend, 0, 2)
	names := [3]string{"Low-pass", "Band-pass", "High-pass"}
	short := [3]string{"Low", "Band", "High"}
	k := int(math.round(b))
	if abs(b - f32(k)) < 0.05 do return names[k]
	lo := min(int(b), 1)
	f := b - f32(lo)
	return fmt.tprintf("%s %.0f%% · %s", short[lo], (1 - f) * 100, short[lo + 1])
}

// The distortion's filter's response, measured, kept until it changes.
@(private = "file")
drv_filter_curve: Filter_Curve

// [control] The response of a filter with `p` into `c` (an impulse through
// it, as `measure_filter`, but longer and read between the bins: the low
// end of a log axis without steps); kept while `p` and `sr` stay.
@(private = "file")
drv_measure_filter :: proc(c: ^Filter_Curve, p: fx.Filter_Params, sr: f64) {
	if c.set && c.params == p && c.sr == sr do return
	c.params, c.sr, c.set = p, sr, true
	N :: 8192
	f := new(fx.Filter_State, context.temp_allocator)
	x := make([]f32, N, context.temp_allocator)
	y := make([]f32, N, context.temp_allocator)
	r := make([]f32, N, context.temp_allocator)
	keys := make([]f32, 64, context.temp_allocator)
	for &k in keys do k = p.cutoff
	x[0] = 0.25
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
		hz := f64(ui.x_freq(f32(k) / (RESPONSE_POINTS - 1)))
		b := clamp(hz / sr * N, 1, N / 2 - 2)
		i := int(b)
		t := f32(b - f64(i))
		g := (abs(spec[i]) * (1 - t) + abs(spec[i + 1]) * t) / 0.25
		v = 20 * math.log10(max(g, 1e-6))
	}
}

// What the distortion's picture is given: its settings as they play now,
// a Perform effect's intensity (its mix scaled by it; -1: none), whether
// it's on, the rate, the output's spectrum (nil: not heard here), its
// colour.
Drv_Distortion_Picture :: struct {
	p:         fx.Distortion_Params,
	intensity: f32,
	on:        bool,
	sr:        f64,
	spectrum:  []f32,
	color:     ui.Color,
}

// "Mix 80%", or a Perform effect's "Mix 80% × Intensity 50%".
@(private = "file")
drv_mix_text :: proc(mix, intensity: f32) -> string {
	if intensity < 0 do return fmt.tprintf("Mix %.0f%%", mix * 100)
	return fmt.tprintf("Mix %.0f%% × Intensity %.0f%%", mix * 100, intensity * 100)
}

// The distortion as `pic` says, `size` big at the cursor: its curve, a
// sine through it, its filter.
drv_distortion_picture :: proc(pic: Drv_Distortion_Picture, size: im.Vec2) {
	th := ui.theme()
	dl := im.GetWindowDrawList()
	r0 := im.GetCursorScreenPos()
	im.Dummy(size)
	ui.name("distortion picture")
	p := pic.p
	mix := clamp(p.mix, 0, 1)
	p.mix = mix * (clamp(pic.intensity, 0, 1) if pic.intensity >= 0 else 1)
	color := pic.color if pic.on else ui.mix(ui.PLOT_BG, pic.color, 0.45)
	dim := ui.mix(ui.PLOT_BG, th.text, 0.3)
	GAP :: 6
	w := size.x
	cw := max(w * 0.26, 120)
	ww := max(w * 0.40, 160)
	a0, a1 := r0, im.Vec2{r0.x + cw, r0.y + size.y}
	b0, b1 := im.Vec2{a1.x + GAP, r0.y}, im.Vec2{a1.x + GAP + ww, r0.y + size.y}
	c0, c1 := im.Vec2{b1.x + GAP, r0.y}, im.Vec2{r0.x + w, r0.y + size.y}
	for q in ([3][2]im.Vec2{{a0, a1}, {b0, b1}, {c0, c1}}) do drv_pane(dl, q[0], q[1])
	ui.text_push(.Caption)
	lh := im.GetTextLineHeight()
	ui.text_pop()
	top := r0.y + lh + 6

	// The curve: input across (±1.25), output up, the diagonal the dry signal.
	{
		x0, x1 := a0.x + 8, a1.x - 8
		y0, y1 := top, a1.y - 4
		R :: 1.25
		at :: proc(x, y, x0, x1, y0, y1: f32) -> im.Vec2 {
			return {x0 + (x1 - x0) * (clamp(x, -R, R) + R) / (2 * R), y1 - (y1 - y0) * (clamp(y, -R, R) + R) / (2 * R)}
		}
		for q in ([5]f32{-1, -0.5, 0, 0.5, 1}) {
			g := ui.mix(ui.PLOT_BG, th.text, 0.16 if q == 0 else 0.07)
			im.DrawList_AddLine(dl, at(q, -R, x0, x1, y0, y1), at(q, R, x0, x1, y0, y1), ui.col(g), 1)
			im.DrawList_AddLine(dl, at(-R, q, x0, x1, y0, y1), at(R, q, x0, x1, y0, y1), ui.col(g), 1)
		}
		im.DrawList_AddLine(dl, at(-R, -R, x0, x1, y0, y1), at(R, R, x0, x1, y0, y1), ui.col(dim), 1)
		N :: 160
		ramp, other: [N]f32
		for k in 0 ..< N do ramp[k] = -R + 2 * R * f32(k) / (N - 1)
		other = ramp
		if p.type != .Down_Sample { // (it holds in time: its curve is the diagonal)
			cp := p
			cp.order = .None // (the filter is in time: its own pane)
			d := new(fx.Distortion, context.temp_allocator)
			fx.distortion_render(d, &cp, ramp[:], other[:], 48_000)
		}
		pts: [N]im.Vec2
		for k in 0 ..< N do pts[k] = at(-R + 2 * R * f32(k) / (N - 1), ramp[k], x0, x1, y0, y1)
		im.DrawList_AddPolyline(dl, &pts[0], N, ui.col(ui.mix(th.text, color, 0.25) if pic.on else color), 2)
		name := DRV_TYPE_CAPTION[p.type] if pic.on else fmt.tprintf("%s (off)", DRV_TYPE_CAPTION[p.type])
		drv_caption(dl, {a0.x + 8, a0.y + 3}, name, drv_drive_text(p.type, p.drive_db, pic.sr))
	}

	// A sine through it, over the clean one: three cycles of 200 Hz (at
	// 48 kHz) after one to settle the filter.
	{
		x0, x1 := b0.x + 8, b1.x - 8
		y0, y1 := top, b1.y - 4
		mid := (y0 + y1) / 2
		amp := (y1 - y0) / 2 / 1.15
		PERIOD :: 240
		N :: PERIOD * 4
		l := make([]f32, N, context.temp_allocator)
		r := make([]f32, N, context.temp_allocator)
		for &v, k in l do v = 0.8 * math.sin(math.TAU * f32(k) / PERIOD)
		copy(r, l)
		d := new(fx.Distortion, context.temp_allocator)
		pp := p
		fx.distortion_render(d, &pp, l, r, 48_000)
		im.DrawList_AddLine(dl, {x0, mid}, {x1, mid}, ui.col(ui.mix(ui.PLOT_BG, th.text, 0.12)), 1)
		P :: 300
		dry, wet: [P]im.Vec2
		for k in 0 ..< P {
			s := PERIOD + k * (N - PERIOD) / P
			x := x0 + (x1 - x0) * f32(k) / (P - 1)
			dry[k] = {x, mid - 0.8 * math.sin(math.TAU * f32(s) / PERIOD) * amp}
			wet[k] = {x, mid - clamp(l[s], -1.15, 1.15) * amp}
		}
		im.DrawList_AddPolyline(dl, &dry[0], P, ui.col(dim), 1.2)
		im.DrawList_AddPolyline(dl, &wet[0], P, ui.col(color), 2.2)
		drv_caption(dl, {b0.x + 8, b0.y + 3}, "A sine through it", drv_mix_text(mix, pic.intensity))
	}

	// The filter: its response before or after the curve (none: flat), the
	// output's spectrum behind.
	{
		x0, x1 := c0.x + 6, c1.x - 6
		y0, y1 := top, c1.y - 4
		LO, HI :: f32(-36), f32(24)
		drv_decades(dl, x0, x1, y0, y1)
		zero := y1 - (0 - LO) / (HI - LO) * (y1 - y0)
		im.DrawList_AddLine(dl, {x0, zero}, {x1, zero}, ui.col(ui.mix(ui.PLOT_BG, th.text, 0.14)), 1)
		if pic.spectrum != nil do drv_spectrum_fill(dl, pic.spectrum, x0, x1, y0, y1, LO, HI, th.text)
		hz := fx.key_to_hz(p.cutoff)
		if p.order != .None {
			fp := fx.Filter_Params{model = .Digital, style = .Db12, cutoff = p.cutoff, resonance = p.resonance, blend = p.blend, mix = 1}
			drv_measure_filter(&drv_filter_curve, fp, pic.sr)
			pts: [RESPONSE_POINTS]im.Vec2
			for v, k in drv_filter_curve.db {
				pts[k] = {x0 + (x1 - x0) * f32(k) / (RESPONSE_POINTS - 1), y1 - clamp((v - LO) / (HI - LO), 0, 1) * (y1 - y0)}
			}
			im.DrawList_AddPolyline(dl, &pts[0], RESPONSE_POINTS, ui.col(color), 2.2)
			cx := drv_fx(x0, x1, hz)
			k := clamp(int(ui.freq_x(hz) * (RESPONSE_POINTS - 1) + 0.5), 0, RESPONSE_POINTS - 1)
			im.DrawList_AddCircleFilled(dl, {cx, pts[k].y}, 4, ui.col(ui.lighten(color, 0.3)), 12)
			where_ := "before" if p.order == .Pre else "after"
			drv_caption(dl, {c0.x + 8, c0.y + 3}, fmt.tprintf("Filter %s", where_), fmt.tprintf("%s · %s · %.0f%%", drv_blend_text(p.blend), drv_hz_text(hz), p.resonance * 100))
		} else {
			im.DrawList_AddLine(dl, {x0, zero}, {x1, zero}, ui.col(ui.mix(ui.PLOT_BG, th.text, 0.35)), 1.5)
			drv_caption(dl, {c0.x + 8, c0.y + 3}, "No filter", "Output" if pic.spectrum != nil else "")
		}
	}
}

// --- Ring mod -----------------------------------------------------------------------------------

// The tone the ring mod's picture puts through it.
@(private = "file")
DRV_RING_TONE :: f32(200)

// What the ring mod's picture is given: its carrier (Hz) and mix as they
// play now, a Perform effect's intensity (its mix scaled by it; -1:
// none), whether it's on, the output's spectrum (nil: not heard here), its
// colour.
Drv_Ring_Picture :: struct {
	hz, mix:   f32,
	intensity: f32,
	on:        bool,
	spectrum:  []f32,
	color:     ui.Color,
}

// The ring mod as `pic` says, `size` big at the cursor: a tone times the
// carrier in time, and the sidebands that makes.
drv_ring_picture :: proc(pic: Drv_Ring_Picture, size: im.Vec2) {
	th := ui.theme()
	dl := im.GetWindowDrawList()
	r0 := im.GetCursorScreenPos()
	im.Dummy(size)
	ui.name("ring mod picture")
	hz := clamp(pic.hz, 1, 5000)
	set_mix := clamp(pic.mix, 0, 1)
	m := set_mix * (clamp(pic.intensity, 0, 1) if pic.intensity >= 0 else 1)
	color := pic.color if pic.on else ui.mix(ui.PLOT_BG, pic.color, 0.45)
	dim := ui.mix(ui.PLOT_BG, th.text, 0.28)
	carrier_c := ui.mix(ui.PLOT_BG, th.warn, 0.7)
	GAP :: 6
	tw := max(size.x * 0.44, 160)
	a0, a1 := r0, im.Vec2{r0.x + tw, r0.y + size.y}
	b0, b1 := im.Vec2{a1.x + GAP, r0.y}, im.Vec2{r0.x + size.x, r0.y + size.y}
	drv_pane(dl, a0, a1)
	drv_pane(dl, b0, b1)
	ui.text_push(.Caption)
	lh := im.GetTextLineHeight()
	ui.text_pop()
	top := r0.y + lh + 6

	// In time: the output (the tone × the carrier, mixed) as each column's
	// reach, so a slow carrier reads as the tone's swell and fall; the
	// carrier and the tone faint behind.
	span := clamp(2 / hz, 0.01, 0.5) // (two of the carrier's cycles; 10 ms at least, half a second at most)
	{
		x0, x1 := a0.x + 8, a1.x - 8
		y0, y1 := top, a1.y - 4
		mid := (y0 + y1) / 2
		amp := (y1 - y0) / 2 / 1.1
		im.DrawList_AddLine(dl, {x0, mid}, {x1, mid}, ui.col(ui.mix(ui.PLOT_BG, th.text, 0.12)), 1)
		cols := max(int(x1 - x0), 2)
		SUB :: 12
		tone :: proc(t: f32) -> f32 { return 0.8 * math.sin(math.TAU * DRV_RING_TONE * t) }
		carrier := make([]im.Vec2, cols, context.temp_allocator)
		dry := make([]im.Vec2, cols, context.temp_allocator)
		last := f32(0)
		for c in 0 ..< cols {
			lo, hi := max(f32), -max(f32)
			for s in 0 ..= SUB {
				t := span * (f32(c) + f32(s) / SUB) / f32(cols)
				x := tone(t)
				y := x * (1 - m) + x * math.sin(math.TAU * hz * t) * m
				lo, hi = min(lo, y), max(hi, y)
			}
			if c > 0 do lo, hi = min(lo, last), max(hi, last) // (joined to the column before)
			t := span * f32(c + 1) / f32(cols)
			last = tone(t) * (1 - m) + tone(t) * math.sin(math.TAU * hz * t) * m
			x := x0 + f32(c)
			im.DrawList_AddLine(dl, {x, mid - hi * amp}, {x, mid - lo * amp + 1}, ui.col(color), 1.6)
			tc := span * (f32(c) + 0.5) / f32(cols)
			carrier[c] = {x, mid - math.sin(math.TAU * hz * tc) * amp * 0.95}
			dry[c] = {x, mid - tone(tc) * amp}
		}
		if hz * span * f32(cols) < 4000 do im.DrawList_AddPolyline(dl, &carrier[0], i32(cols), ui.col(ui.with_alpha(carrier_c, 0.55)), 1)
		if DRV_RING_TONE * span < f32(cols) / 3 do im.DrawList_AddPolyline(dl, &dry[0], i32(cols), ui.col(ui.with_alpha(dim, 0.8)), 1)
		ms := span * 1000
		name := "Ring mod" if pic.on else "Ring mod (off)"
		rest := fmt.tprintf("a %s tone × %s · %s shown", drv_hz_text(DRV_RING_TONE), drv_hz_text(hz), fmt.tprintf("%.0f ms", ms) if ms < 1000 else "1 s")
		drv_caption(dl, {a0.x + 8, a0.y + 3}, name, rest)
	}

	// In frequency: the tone (as loud as the dry part of the mix), its two
	// sidebands (half the wet part each), the carrier marked.
	{
		x0, x1 := b0.x + 6, b1.x - 6
		y0, y1 := top, b1.y - 4
		LO, HI :: f32(-36), f32(24)
		drv_decades(dl, x0, x1, y0, y1)
		if pic.spectrum != nil do drv_spectrum_fill(dl, pic.spectrum, x0, x1, y0, y1, LO, HI, th.text)
		// The carrier: a dashed line.
		cx := drv_fx(x0, x1, hz)
		for y := y0; y < y1; y += 6 do im.DrawList_AddLine(dl, {cx, y}, {cx, min(y + 3, y1)}, ui.col(carrier_c), 1)
		bar :: proc(dl: ^im.DrawList, x, level, y0, y1: f32, c: ui.Color) {
			h := (y1 - y0) * clamp(level, 0, 1)
			im.DrawList_AddRectFilled(dl, {x - 2.5, y1 - h}, {x + 2.5, y1}, ui.col(c), 2)
		}
		up := DRV_RING_TONE + hz
		down := abs(DRV_RING_TONE - hz)
		bar(dl, drv_fx(x0, x1, DRV_RING_TONE), 1 - m, y0, y1, dim)
		// (The tone's place, marked on the axis even when the mix leaves none of it.)
		tx := drv_fx(x0, x1, DRV_RING_TONE)
		im.DrawList_AddTriangleFilled(dl, {tx - 4, y1 + 3}, {tx + 4, y1 + 3}, {tx, y1 - 3}, ui.col(ui.mix(ui.PLOT_BG, th.text, 0.55)))
		bar(dl, drv_fx(x0, x1, up), m * 0.5 * 1.6, y0, y1, color) // (half each, drawn a little taller to read)
		if down >= 20 do bar(dl, drv_fx(x0, x1, down), m * 0.5 * 1.6, y0, y1, color)
		ui.text_push(.Caption)
		lbl :: proc(dl: ^im.DrawList, x, y: f32, s: string, c: ui.Color) {
			t := fmt.ctprintf("%s", s)
			w := im.CalcTextSize(t).x
			im.DrawList_AddText(dl, {x - w / 2, y}, ui.col(c), t)
		}
		ly := y1 - (y1 - y0) * min(m * 0.8, 1) - im.GetTextLineHeight() - 1
		if m > 0.02 {
			lbl(dl, drv_fx(x0, x1, up), max(ly, y0), drv_hz_text(up), ui.lighten(color, 0.3))
			if down >= 20 do lbl(dl, drv_fx(x0, x1, down), max(ly, y0), drv_hz_text(down), ui.lighten(color, 0.3))
		}
		cw := im.CalcTextSize("carrier").x
		cxl := cx + 4 if cx + 4 + cw < x1 else cx - 4 - cw
		im.DrawList_AddText(dl, {cxl, y1 - im.GetTextLineHeight() * 2 - 2}, ui.col(carrier_c), "carrier")
		ui.text_pop()
		rest := fmt.tprintf("%s ± %s · %s", drv_hz_text(DRV_RING_TONE), drv_hz_text(hz), drv_mix_text(set_mix, pic.intensity))
		if down < 20 && m > 0.02 do rest = fmt.tprintf("%s · the lower one below hearing", rest)
		drv_caption(dl, {b0.x + 8, b0.y + 3}, "Sidebands", rest)
	}
}
