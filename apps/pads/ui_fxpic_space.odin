// Space's pictures (Delay, Reverb, Comb): what each does to the sound,
// drawn at the cursor into a size they're given from plain values (the
// effect's settings, the tempo, the spectrum of what it puts out now), so
// any panel can use them: Push 2's display now (ui_ctl_fx_space.odin),
// Pads' window later.
package pads

import "core:fmt"
import "core:math"

import "app:ui"
import im "deps:imgui"
import "fire:fx"

// An echo on the delay's time line: when (seconds after the hit), how
// loud (its sign: the feedback's polarity), which side (0 left, 1 right).
@(private)
Sp_Echo :: struct {
	t, g: f32,
	side: int,
}

// The most echoes the delay's picture draws.
@(private) SP_ECHOES :: 48

// The echoes delay `d` makes of one hit, quietest last dropped (below
// -30 dB, or past `longest` seconds), as its algorithm routes them
// (fx.delay_run): Mono and Stereo a line each side fed back on itself;
// Ping-pong the input summed into the right, the right into the left, the
// left back into the right; Mid ping-pong each side into the other.
@(private)
sp_delay_echoes :: proc(d: fx.Delay_Params, longest: f32, out: ^[SP_ECHOES]Sp_Echo) -> int {
	n := 0
	add :: proc(out: ^[SP_ECHOES]Sp_Echo, n: ^int, t, g: f32, side: int, longest: f32) -> bool {
		if n^ >= SP_ECHOES || t > longest || abs(g) < 0.03 do return false
		out[n^] = {t, g, side}
		n^ += 1
		return true
	}
	period := [2]f32{1 / max(d.hz[0], 0.05), 1 / max(d.hz[1], 0.05)}
	if d.style == .Mono do period[1] = period[0]
	fb := clamp(d.feedback, -1, 1)
	wet, _ := fx.equal_power(d.wet)
	switch d.style {
	case .Mono, .Stereo:
		for side in 0 ..< 2 {
			g := wet
			for k := 1; add(out, &n, f32(k) * period[side], g, side, longest); k += 1 do g *= fb
		}
	case .Ping_Pong:
		// Right (the input's first echo), then left (the right's, as loud),
		// then right again through the feedback.
		t, g := period[1], wet
		for k := 0; ; k += 1 {
			side := 1 if k % 2 == 0 else 0
			if !add(out, &n, t, g, side, longest) do break
			if side == 0 do g *= fb
			t += period[0] if side == 1 else period[1]
		}
	case .Mid_Ping_Pong:
		// Each side's input: first echo on the other side, then back and forth.
		for from in 0 ..< 2 {
			side := 1 - from
			t, g := period[side], wet
			for add(out, &n, t, g, side, longest) {
				side = 1 - side
				t += period[side]
				g *= fb
			}
		}
	}
	return n
}

// The gain (linear) of the delay's band (its feedback's filter: a
// low-pass above, a high-pass below, `fx.delay_shared`) at `f` Hz.
@(private)
sp_delay_band :: proc(d: fx.Delay_Params, f, sr: f32) -> f32 {
	radius := max(d.spread * 8 * 12, 0)
	fu := clamp(fx.key_to_hz(d.cutoff + radius), 1, sr * 0.45)
	fl := clamp(fx.key_to_hz(d.cutoff - radius), 1, sr * 0.45)
	gain := fl / fu + 1
	su, sl := f / fu, f / fl
	return gain / math.sqrt(1 + su * su) * sl / math.sqrt(1 + sl * sl)
}

// A picture's background and its inner rect (`pad` in from its edges).
@(private)
sp_frame :: proc(dl: ^im.DrawList, p0, p1: im.Vec2, pad: f32 = 6) -> (x0, y0, x1, y1: f32) {
	im.DrawList_AddRectFilled(dl, p0, p1, ui.col(ui.PLOT_BG), ui.theme().radius)
	return p0.x + pad, p0.y + pad, p1.x - pad, p1.y - pad
}

// The spectrum `spec` (dB along the log axis, as `spectrum` gives it) as
// a faint line across `x0..x1` at frequency `xf(k)`, `lo..hi` dB bottom to top.
@(private)
sp_spectrum :: proc(dl: ^im.DrawList, spec: []f32, x0, y0, x1, y1, lo, hi: f32) {
	n := len(spec)
	if n < 2 do return
	pts := make([]im.Vec2, n, context.temp_allocator)
	for v, k in spec do pts[k] = {x0 + (x1 - x0) * f32(k) / f32(n - 1), y1 - (clamp(v, lo, hi) - lo) / (hi - lo) * (y1 - y0)}
	im.DrawList_AddPolyline(dl, &pts[0], i32(n), ui.col(ui.with_alpha(ui.theme().text, 0.28)), 1.2)
}

// The area under the line through `pts` down to `y1`, shaded (no
// anti-aliased seams between its pieces where the line is steep).
@(private)
sp_fill :: proc(dl: ^im.DrawList, pts: []im.Vec2, y1: f32, color: ui.Color) {
	flags := dl.Flags
	dl.Flags -= {.AntiAliasedFill}
	defer dl.Flags = flags
	c := ui.col(color)
	for k in 1 ..< len(pts) do im.DrawList_AddQuadFilled(dl, {pts[k - 1].x, y1}, pts[k - 1], pts[k], {pts[k].x, y1}, c)
}

// A log frequency axis's 100, 1k and 10k (the first `n` of them) across
// `x0..x1`, at height `y`.
@(private)
sp_freqs :: proc(dl: ^im.DrawList, x0, x1, y: f32, n := 3) {
	labels := [3]string{"100", "1k", "10k"}
	for f, k in ([3]f32{100, 1000, 10_000}) do if k < n do sp_label(dl, {x0 + (x1 - x0) * ui.freq_x(f) + 3, y}, labels[k])
}

// Text in the picture's label colour.
@(private)
sp_label :: proc(dl: ^im.DrawList, at: im.Vec2, text: string, bright := false) {
	t := ui.theme()
	c := t.text if bright else ui.mix(ui.PLOT_BG, t.text, 0.5)
	im.DrawList_AddText(dl, at, ui.col(c), fmt.ctprintf("%s", text))
}

// How a time reads (ms, or seconds past one).
@(private)
sp_secs :: proc(s: f32) -> string {
	if s < 1 do return fmt.tprintf("%.0f ms", s * 1000)
	return fmt.tprintf("%.2f s", s)
}

// The delay's picture, `size` big: at the left its echoes of one hit on a
// time line (the beats at `bpm` behind them; the left side above the line,
// the right below; a ring for an echo the feedback turned upside down),
// `caption` over them; at the right its tone, the band its feedback goes
// through (each echo through it once more: the fainter lines), over the
// spectrum of what it puts out now (`spec`, nil: none).
@(private)
sp_delay_picture :: proc(d: fx.Delay_Params, bpm, sr: f64, spec: []f32, caption: string, size: im.Vec2, color: ui.Color) {
	t := ui.theme()
	pos := im.GetCursorScreenPos()
	dl := im.GetWindowDrawList()
	ui.text_push(.Label)
	defer ui.text_pop()
	lh := im.GetTextLineHeight()
	gap: f32 = 6
	split := pos.x + size.x * 0.6
	// The echoes.
	{
		x0, y0, x1, y1 := sp_frame(dl, pos, {split - gap / 2, pos.y + size.y})
		echoes: [SP_ECHOES]Sp_Echo
		n := sp_delay_echoes(d, fx.DELAY_MAX_SECONDS, &echoes)
		last: f32 = 0
		for e in echoes[:n] do last = max(last, e.t)
		period := max(1 / max(d.hz[0], 0.05), 1 / max(d.hz[1], 0.05) if d.style != .Mono else 0)
		span := clamp(max(last, period * 2) * 1.08, 0.05, fx.DELAY_MAX_SECONDS)
		lx0 := x0 + 14 // (room for L and R)
		xt :: proc(s, span, x0, x1: f32) -> f32 { return x0 + (x1 - x0) * clamp(s / span, 0, 1) }
		// The beats (a bar's lines where beats would crowd), the line.
		beat := f32(60 / max(bpm, 1))
		step := beat
		for (x1 - lx0) * step / span < 8 && step < 3600 do step *= 4
		grid := ui.mix(ui.PLOT_BG, t.text, 0.09)
		for b := step; b < span; b += step {
			x := xt(b, span, lx0, x1)
			im.DrawList_AddLine(dl, {x, y0 + lh}, {x, y1}, ui.col(grid), 1)
		}
		mid := (y0 + lh + y1) / 2
		half := (y1 - y0 - lh) / 2 - 2
		im.DrawList_AddLine(dl, {lx0, mid}, {x1, mid}, ui.col(ui.mix(ui.PLOT_BG, t.text, 0.2)), 1)
		// The hit (as loud as the dry), then each echo.
		_, dry := fx.equal_power(d.wet)
		im.DrawList_AddLine(dl, {lx0, mid - half * dry}, {lx0, mid + half * dry}, ui.col(ui.mix(ui.PLOT_BG, t.text, 0.45)), 3)
		for e in echoes[:n] {
			x := xt(e.t, span, lx0, x1)
			h := half * min(abs(e.g), 1)
			y := mid - h if e.side == 0 else mid + h
			c := color if e.side == 0 else ui.mix(color, t.text, 0.35)
			im.DrawList_AddLine(dl, {x, mid}, {x, y}, ui.col(c), 2.5)
			if e.g >= 0 do im.DrawList_AddCircleFilled(dl, {x, y}, 3, ui.col(c))
			else do im.DrawList_AddCircle(dl, {x, y}, 3, ui.col(c), 12, 1.5)
		}
		sp_label(dl, {x0, mid - lh - 1}, "L")
		sp_label(dl, {x0, mid + 1}, "R")
		sp_label(dl, {x0, y0 - 3}, caption, true)
		sc := fmt.ctprintf("%s", sp_secs(span))
		im.DrawList_AddText(dl, {x1 - im.CalcTextSize(sc).x, y0 - 3}, ui.col(ui.mix(ui.PLOT_BG, t.text, 0.5)), sc)
	}
	// The tone.
	{
		x0, y0, x1, y1 := sp_frame(dl, {split + gap / 2, pos.y}, {pos.x + size.x, pos.y + size.y})
		LO, HI :: -36, 6
		yd :: proc(db, y0, y1: f32) -> f32 { return y1 - (clamp(db, LO, HI) - LO) / (HI - LO) * (y1 - y0) }
		for f in ([3]f32{100, 1000, 10_000}) {
			x := x0 + (x1 - x0) * ui.freq_x(f)
			im.DrawList_AddLine(dl, {x, y0}, {x, y1}, ui.col(ui.mix(ui.PLOT_BG, t.text, 0.12)), 1)
		}
		im.DrawList_AddLine(dl, {x0, yd(0, y0, y1)}, {x1, yd(0, y0, y1)}, ui.col(ui.mix(ui.PLOT_BG, t.text, 0.18)), 1)
		if spec != nil do sp_spectrum(dl, spec, x0, y0, x1, y1, LO, HI)
		N :: 96
		one: [N]f32
		for k in 0 ..< N do one[k] = 20 * math.log10(max(sp_delay_band(d, ui.x_freq(f32(k) / (N - 1)), f32(sr)), 1e-6))
		for pass := 4; pass >= 1; pass -= 1 {
			pts: [N]im.Vec2
			for k in 0 ..< N do pts[k] = {x0 + (x1 - x0) * f32(k) / (N - 1), yd(one[k] * f32(pass), y0, y1)}
			if pass == 1 {
				sp_fill(dl, pts[:], y1, ui.with_alpha(color, 0.16))
			}
			im.DrawList_AddPolyline(dl, &pts[0], N, ui.col(ui.with_alpha(color, 1 if pass == 1 else 0.55 / f32(pass))), 2 if pass == 1 else 1.2)
		}
		sp_label(dl, {x0, y0 - 3}, "Tone")
		sp_freqs(dl, x0, x1, y0 - 3)
	}
	im.Dummy(size)
}

// The reverb tail's mean trip round its loop at 44.1 kHz, in samples:
// its lines' mean (`REVERB_FEEDBACK`, times the size's) and its
// diffusers' (`REVERB_ALLPASS`), as fx.reverb_render has them.
@(private) SP_REVERB_LINE :: 6453.4
@(private) SP_REVERB_DIFFUSER :: 849.0

// How long (seconds) reverb `r`'s tail takes to fall 60 dB at `f` Hz:
// its decay, and what its shelves take off on each trip round the loop.
@(private)
sp_reverb_rt60 :: proc(r: fx.Reverb_Params, f, sr: f32) -> f32 {
	size_mult := math.pow(f32(2), clamp(r.size, 0, 1) * 4 - 3)
	trips := 44_100 / (size_mult * SP_REVERB_LINE + SP_REVERB_DIFFUSER) // a second
	fh := clamp(fx.key_to_hz(clamp(r.high_cutoff, 0, 130)), 1, sr * 0.45)
	fl := clamp(fx.key_to_hz(clamp(r.low_cutoff, 0, 130)), 1, sr * 0.45)
	a := math.pow(10, clamp(r.high_gain_db, -24, 0) / 20) // (above the high shelf)
	b := math.pow(10, clamp(r.low_gain_db, -24, 0) / 20)  // (below the low one)
	sh, sl := f / fh, f / fl
	hi := (1 + a * a * sh * sh) / (1 + sh * sh)
	lo := (b * b + sl * sl) / (1 + sl * sl)
	per_trip := 10 * math.log10(max(hi * lo, 1e-9)) // dB, ≤ 0
	decay := clamp(r.decay, 0.1, 100)
	return 60 / (60 / decay - per_trip * trips)
}

// The reverb input's band (its low cut and high cut) at `f` Hz: linear.
@(private)
sp_reverb_input :: proc(r: fx.Reverb_Params, f, sr: f32) -> f32 {
	fl := clamp(fx.key_to_hz(clamp(r.pre_low, 0, 130)), 1, sr * 0.45)
	fh := clamp(fx.key_to_hz(clamp(r.pre_high, 0, 130)), 1, sr * 0.45)
	lp :: proc(f, fc: f32) -> complex64 { return 1 / complex(1, f / fc) }
	return abs(lp(f, fh) - lp(f, fl))
}

// The reverb's picture, `size` big: at the left its tail after one hit on
// a time line (the pre-delay a gap, the early reflections denser the
// larger it is, then the fall of 60 dB in the decay time, wavering with
// the chorus; the lows' and highs' own falls dimmer); at the right how
// long it rings at each frequency, the input's cuts shaded, over the
// spectrum of what it puts out now (`spec`, nil: none). `clock`: seconds,
// for the chorus's waver.
@(private)
sp_reverb_picture :: proc(r: fx.Reverb_Params, sr: f64, spec: []f32, clock: f64, size: im.Vec2, color: ui.Color) {
	t := ui.theme()
	pos := im.GetCursorScreenPos()
	dl := im.GetWindowDrawList()
	ui.text_push(.Label)
	defer ui.text_pop()
	lh := im.GetTextLineHeight()
	gap: f32 = 6
	split := pos.x + size.x * 0.6
	fs := f32(sr)
	decay := clamp(r.decay, 0.1, 100)
	rt_lo, rt_hi := sp_reverb_rt60(r, 60, fs), sp_reverb_rt60(r, 12_000, fs)
	// The tail.
	{
		x0, y0, x1, y1 := sp_frame(dl, pos, {split - gap / 2, pos.y + size.y})
		ty := y0 + lh // (under the words)
		pre := clamp(r.delay, 0, 0.3)
		span := clamp(pre + max(decay, rt_lo) * 1.1, 0.3, 120)
		xt :: proc(s, span, x0, x1: f32) -> f32 { return x0 + (x1 - x0) * clamp(s / span, 0, 1) }
		yd :: proc(db, y0, y1: f32) -> f32 { return y1 - (clamp(db, -60, 0) + 60) / 60 * (y1 - y0) }
		for db := f32(-48); db < 0; db += 12 do im.DrawList_AddLine(dl, {x0, yd(db, ty, y1)}, {x1, yd(db, ty, y1)}, ui.col(ui.mix(ui.PLOT_BG, t.text, 0.07)), 1)
		px := xt(pre, span, x0, x1)
		if pre > 0 do im.DrawList_AddRectFilled(dl, {x0, ty}, {px, y1}, ui.col(ui.mix(ui.PLOT_BG, t.text, 0.06)), 2)
		// The lows' and highs' falls, then the tail (filled, wavering).
		N :: 72
		fall :: proc(rt, pre, span, x0, x1, ty, y1: f32, out: ^[N]im.Vec2) {
			for k in 0 ..< N {
				s := pre + (span - pre) * f32(k) / (N - 1)
				out[k] = {xt(s, span, x0, x1), yd(-60 * (s - pre) / rt, ty, y1)}
			}
		}
		lows, highs, tail: [N]im.Vec2
		fall(rt_lo, pre, span, x0, x1, ty, y1, &lows)
		fall(rt_hi, pre, span, x0, x1, ty, y1, &highs)
		fall(decay, pre, span, x0, x1, ty, y1, &tail)
		waver := clamp(r.chorus, 0, 1) * 4
		if waver > 0 {
			ph := f32(clock) * clamp(r.chorus_hz, 0.05, 16) * math.TAU
			for &q, k in tail do q.y += waver * math.sin(ph + f32(k) * 0.9) * f32(k) / (N - 1)
		}
		sp_fill(dl, tail[:], y1, ui.with_alpha(color, 0.2))
		im.DrawList_AddPolyline(dl, &lows[0], N, ui.col(ui.with_alpha(t.warn, 0.55)), 1.2)
		im.DrawList_AddPolyline(dl, &highs[0], N, ui.col(ui.with_alpha(ui.mix(color, t.text, 0.5), 0.7)), 1.2)
		im.DrawList_AddPolyline(dl, &tail[0], N, ui.col(color), 2.2)
		// The early reflections: the first trip round the loop.
		size_mult := math.pow(f32(2), clamp(r.size, 0, 1) * 4 - 3)
		early := (size_mult * SP_REVERB_LINE + SP_REVERB_DIFFUSER) / 44_100
		count := 6 + int(clamp(r.size, 0, 1) * 18)
		for k in 0 ..< count {
			f := f32(k) / f32(count)
			s := pre + early * (f + 0.37 * math.sin(f32(k) * 2.4) / f32(count))
			x := xt(s, span, x0, x1)
			im.DrawList_AddLine(dl, {x, y1}, {x, yd(-4 - 14 * f, ty, y1)}, ui.col(ui.mix(color, t.text, 0.4)), 1.5)
		}
		sp_label(dl, {x0, y0 - 3}, fmt.tprintf("Decay %s", sp_secs(decay)), true)
		if pre >= 0.005 do sp_label(dl, {x0 + im.CalcTextSize(fmt.ctprintf("Decay %s", sp_secs(decay))).x + 12, y0 - 3}, fmt.tprintf("Pre %s", sp_secs(pre)))
		sc := fmt.ctprintf("%s", sp_secs(span))
		im.DrawList_AddText(dl, {x1 - im.CalcTextSize(sc).x, y0 - 3}, ui.col(ui.mix(ui.PLOT_BG, t.text, 0.5)), sc)
	}
	// How long it rings at each frequency.
	{
		x0, y0, x1, y1 := sp_frame(dl, {split + gap / 2, pos.y}, {pos.x + size.x, pos.y + size.y})
		ty := y0 + lh
		N :: 64
		rts: [N]f32
		top: f32 = 0.1
		for k in 0 ..< N {
			rts[k] = sp_reverb_rt60(r, ui.x_freq(f32(k) / (N - 1)), fs)
			top = max(top, rts[k])
		}
		top *= 1.15
		for f in ([3]f32{100, 1000, 10_000}) {
			x := x0 + (x1 - x0) * ui.freq_x(f)
			im.DrawList_AddLine(dl, {x, ty}, {x, y1}, ui.col(ui.mix(ui.PLOT_BG, t.text, 0.12)), 1)
		}
		if spec != nil do sp_spectrum(dl, spec, x0, ty, x1, y1, -60, 0)
		pts: [N]im.Vec2
		for k in 0 ..< N do pts[k] = {x0 + (x1 - x0) * f32(k) / (N - 1), y1 - (y1 - ty) * clamp(rts[k] / top, 0, 1)}
		sp_fill(dl, pts[:], y1, ui.with_alpha(color, 0.18))
		im.DrawList_AddPolyline(dl, &pts[0], N, ui.col(color), 2)
		// The input's cuts: what they take away shaded.
		C :: 48
		for k in 0 ..< C {
			f := ui.x_freq((f32(k) + 0.5) / C)
			cut := 1 - clamp(sp_reverb_input(r, f, fs), 0, 1)
			if cut < 0.05 do continue
			cx0, cx1 := x0 + (x1 - x0) * f32(k) / C, x0 + (x1 - x0) * f32(k + 1) / C
			im.DrawList_AddRectFilled(dl, {cx0, ty}, {cx1, y1}, ui.col(ui.with_alpha(t.danger, 0.16 * cut)))
		}
		sp_label(dl, {x0, y0 - 3}, "Ring time")
		sp_freqs(dl, x0, x1, y0 - 3, 2) // (10k's place: the longest time's)
		tc := fmt.ctprintf("%s", sp_secs(top / 1.15))
		im.DrawList_AddText(dl, {x1 - im.CalcTextSize(tc).x, y0 - 3}, ui.col(ui.mix(ui.PLOT_BG, t.text, 0.5)), tc)
	}
	im.Dummy(size)
}

// The comb's response at `f` Hz (dB): at `hz`, fed back by `fb`, `mix`
// of it (dsp.Comb: the wet scaled so a strong resonance stays as loud).
@(private)
sp_comb_db :: proc(hz, fb, mix, f: f32) -> f32 {
	w := math.TAU * f / max(hz, 1)
	wet := complex(2 * (1 - abs(fb)), 0) / (1 - complex(fb * math.cos(w), -fb * math.sin(w)))
	return 20 * math.log10(max(abs(complex(1 - mix, 0) + complex(mix, 0) * wet), 1e-6))
}

// The comb's picture, `size` big: its response on a straight frequency
// axis (its teeth evenly spaced: at the frequency and each multiple, or,
// fed back upside down, halfway between: an octave down, odd harmonics
// only), `mix` of it as it is now (a held performance effect: as hard as
// it's pressed), the first tooth named, over the spectrum of what it puts
// out now (`spec`, along the log axis; nil: none).
@(private)
sp_comb_picture :: proc(freq, fb, mix: f32, spec: []f32, size: im.Vec2, color: ui.Color) {
	t := ui.theme()
	pos := im.GetCursorScreenPos()
	dl := im.GetWindowDrawList()
	ui.text_push(.Label)
	defer ui.text_pop()
	lh := im.GetTextLineHeight()
	x0, y0, x1, y1 := sp_frame(dl, pos, {pos.x + size.x, pos.y + size.y})
	ty := y0 + lh
	hz := clamp(freq, 20, 5000)
	first := hz if fb >= 0 else hz / 2 // (the lowest tooth)
	top_hz := clamp(hz * 12.5, 400, 20_000)
	LO, HI :: -36, 12
	yd :: proc(db, ty, y1: f32) -> f32 { return y1 - (clamp(db, LO, HI) - LO) / (HI - LO) * (y1 - ty) }
	// kHz (or hundreds of Hz) across.
	step: f32 = 1000 if top_hz > 4000 else (500 if top_hz > 2000 else 100)
	if top_hz > 12_000 do step = 2000
	for f := step; f < top_hz; f += step {
		x := x0 + (x1 - x0) * f / top_hz
		im.DrawList_AddLine(dl, {x, ty}, {x, y1}, ui.col(ui.mix(ui.PLOT_BG, t.text, 0.09)), 1)
	}
	im.DrawList_AddLine(dl, {x0, yd(0, ty, y1)}, {x1, yd(0, ty, y1)}, ui.col(ui.mix(ui.PLOT_BG, t.text, 0.2)), 1)
	// The spectrum, its log axis read along this one.
	if n := len(spec); n >= 2 {
		P :: 160
		pts: [P]im.Vec2
		for k in 0 ..< P {
			f := top_hz * f32(k) / (P - 1)
			at := clamp(ui.freq_x(max(f, 20)) * f32(n - 1), 0, f32(n - 1))
			i := int(at)
			v := spec[i] + (spec[min(i + 1, n - 1)] - spec[i]) * (at - f32(i))
			pts[k] = {x0 + (x1 - x0) * f32(k) / (P - 1), yd(v, ty, y1)}
		}
		im.DrawList_AddPolyline(dl, &pts[0], P, ui.col(ui.with_alpha(t.text, 0.28)), 1.2)
	}
	// The response: a point a pixel, the loudest in it (a tooth in it: the
	// tooth's own top, so none falls between two points).
	n := clamp(int(x1 - x0), 2, 2400)
	pts := make([]im.Vec2, n, context.temp_allocator)
	px := top_hz / f32(n - 1) // (Hz a point)
	for k in 0 ..< n {
		f := px * f32(k)
		db := sp_comb_db(hz, fb, mix, f)
		// The nearest tooth (first + j × hz) within half a point of it.
		j := math.round((f - first) / hz)
		if tooth := first + j * hz; j >= 0 && abs(tooth - f) <= px / 2 do db = max(db, sp_comb_db(hz, fb, mix, tooth))
		pts[k] = {x0 + (x1 - x0) * f32(k) / f32(n - 1), yd(db, ty, y1)}
	}
	fill := ui.with_alpha(color, 0.18)
	sp_fill(dl, pts, y1, fill)
	im.DrawList_AddPolyline(dl, &pts[0], i32(n), ui.col(color), 1.8)
	// The teeth: a dot on each (the first bright).
	tooth := first
	for k := 0; tooth < top_hz; k += 1 {
		x := x0 + (x1 - x0) * tooth / top_hz
		im.DrawList_AddCircleFilled(dl, {x, yd(sp_comb_db(hz, fb, mix, tooth), ty, y1)}, 3.5 if k == 0 else 2, ui.col(t.text if k == 0 else ui.mix(color, t.text, 0.4)))
		tooth += hz
	}
	key := int(math.round(69 + 12 * math.log2(first / 440)))
	name := fmt.tprintf("%s %s%s", sf_hz(first), ui.note_name(clamp(key, 0, 127)), "  (odd harmonics)" if fb < 0 else "")
	sp_label(dl, {x0, y0 - 3}, name, true)
	ac := fmt.ctprintf("0 – %s", sf_hz(top_hz))
	im.DrawList_AddText(dl, {x1 - im.CalcTextSize(ac).x, y0 - 3}, ui.col(ui.mix(ui.PLOT_BG, t.text, 0.5)), ac)
	im.Dummy(size)
}
