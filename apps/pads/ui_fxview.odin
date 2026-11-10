package pads

import "core:fmt"
import "core:math"

import app "app:core"
import "app:ui"
import pm "model"
import im "deps:imgui"
import fc "fire:core"
import "fire:dsp"

// Each effect device's picture of what it does to the sound, over its
// knobs: a filter's response (drag it), a compressor's curve with its gain
// reduction now, saturation's curve, a bit-crusher's steps, a delay's
// echoes, a reverb's decay, a comb's teeth, a modulation's sweep, a
// cutter's or stutter's slices against the beat. What plays now moves on
// it: the playhead, the LFOs, how hard a performance effect is held.

// The height of an effect's picture.
@(private) FX_VIEW_H :: 150

// A setting of the slot (its default when it has none); percentages as
// fractions (40% is 0.4).
@(private)
fxv :: proc(a: ^App, t: pm.Fx_Target, s: pm.Effect_Slot, id: fc.Param_Id) -> f32 {
	for p in pm.target_params(&a.m.engine, t) do if p.id == id {
		v := pm.slot_value(s, id, f32(p.default))
		return v / 100 if p.unit == .Percent else v
	}
	return pm.slot_value(s, id, 0)
}

// Draws effect slot `t`'s picture (nothing for one that has none).
draw_effect_view :: proc(a: ^App, t: pm.Fx_Target, s: pm.Effect_Slot) {
	m := &a.m
	th := ui.theme()
	w := im.GetContentRegionAvail().x
	size := im.Vec2{w, FX_VIEW_H}
	color := th.accent
	sr := a.host.graph.settings.sample_rate if a.host.graph.settings.sample_rate > 0 else 48_000
	// A held performance effect: as hard as it is pressed.
	held := s
	if t.kind == .Perf && s.on do held, _ = pm.perf_effective(&m.project, t.index, m.engine.perf_live[t.index])

	#partial switch s.kind {
	case .Low_Pass, .High_Pass, .Band_Pass:
		mode := dsp.Filter_Mode.Lowpass
		if s.kind == .High_Pass do mode = .Highpass
		if s.kind == .Band_Pass do mode = .Bandpass
		curve :: proc(mode: dsp.Filter_Mode, hz, q, sr: f64) -> []f32 {
			c := dsp.svf_design(mode, hz, q, 0, sr)
			out := make([]f32, 160, context.temp_allocator)
			for &v, k in out {
				g, _ := dsp.svf_response(&c, f64(ui.x_freq(f32(k) / 159)), sr)
				v = f32(20 * math.log10(max(g, 1e-6)))
			}
			return out
		}
		hz, q := f64(fxv(a, t, s, dsp.FILTER_PARAM_CUTOFF_HZ)), f64(fxv(a, t, s, dsp.FILTER_PARAM_Q))
		curves := make([dynamic]ui.Plot_Curve, context.temp_allocator)
		if spec := spectrum(a); spec != nil do append(&curves, ui.Plot_Curve{db = spec, color = ui.with_alpha(th.text, 0.28), width = 1.2})
		if t.kind == .Perf && s.on {
			append(&curves, ui.Plot_Curve{db = curve(mode, hz, q, sr), color = ui.mix(ui.PLOT_BG, color, 0.5), width = 1.5})
			append(&curves, ui.Plot_Curve{db = curve(mode, f64(fxv(a, t, held, dsp.FILTER_PARAM_CUTOFF_HZ)), q, sr), color = color, fill = true, width = 2.5})
		} else {
			append(&curves, ui.Plot_Curve{db = curve(mode, hz, q, sr), color = color, fill = true, width = 2.5})
		}
		handle := [2]f32{ui.freq_x(f32(hz)), f32(20 * math.log10(max(q, 0.1) / 0.707))}
		e := ui.response_plot("effect response", curves[:], &handle, size)
		if e.changed {
			pm.set_target_param(m, t, dsp.FILTER_PARAM_CUTOFF_HZ, ui.x_freq(handle[0]))
			pm.set_target_param(m, t, dsp.FILTER_PARAM_Q, clamp(0.707 * math.pow(10, handle[1] / 20), 0.1, 20))
		}
		if e.ended do app_seal(a)
		if im.IsItemHovered() do im.SetTooltip("%s", fmt.ctprintf("%.0f Hz, Q %.2f: drag sideways for the cutoff, up for resonance", hz, q))

	case .Compressor, .Gate, .Limiter:
		// Its curve: what comes out for what goes in (-60..0 dB), and how
		// much it turns down now, as a bar beside it.
		ys := make([]f32, 121, context.temp_allocator)
		for &y, k in ys {
			x := -60 + f32(k) * 0.5
			#partial switch s.kind {
			case .Compressor:
				th_, r, knee := fxv(a, t, s, dsp.COMPRESSOR_PARAM_THRESHOLD_DB), max(fxv(a, t, s, dsp.COMPRESSOR_PARAM_RATIO), 1), fxv(a, t, s, dsp.COMPRESSOR_PARAM_KNEE_DB)
				d := x - th_
				if 2 * d < -knee do y = x
				else if 2 * abs(d) <= knee && knee > 0 do y = x + (1 / r - 1) * (d + knee / 2) * (d + knee / 2) / (2 * knee)
				else do y = th_ + d / r
				y += fxv(a, t, s, dsp.COMPRESSOR_PARAM_MAKEUP_DB)
			case .Gate:
				th_, rng := fxv(a, t, s, dsp.GATE_PARAM_THRESHOLD_DB), fxv(a, t, s, dsp.GATE_PARAM_RANGE_DB)
				y = x if x >= th_ else x - abs(rng)
			case .Limiter:
				y = min(x + fxv(a, t, s, dsp.LIMITER_PARAM_INPUT_DB), fxv(a, t, s, dsp.LIMITER_PARAM_CEILING_DB))
			}
		}
		diag := make([]f32, 2, context.temp_allocator)
		diag[0], diag[1] = -60, 0
		bar_w: f32 = 54
		ui.line_plot("effect curve", {{ys = diag, color = ui.with_alpha(th.text, 0.2), width = 1}, {ys = ys, color = color, fill = true, width = 2.5}}, {w - bar_w - 8, FX_VIEW_H}, -60, 6, {0.25, 0.5, 0.75}, {-48, -36, -24, -12, 0})
		im.SameLine(0, 8)
		gr, ok := pm.slot_reduction(&m.engine, t)
		reduction_meter(a, abs(f32(gr)) if ok else 0, {bar_w, FX_VIEW_H})

	case .Saturation:
		drive := math.pow(10, fxv(a, t, s, dsp.SATURATION_PARAM_DRIVE_DB) / 20)
		shape := dsp.Saturation_Shape(clamp(int(fxv(a, t, s, dsp.SATURATION_PARAM_SHAPE)), 0, int(max(dsp.Saturation_Shape))))
		ys := make([]f32, 121, context.temp_allocator)
		for &y, k in ys do y = f32(dsp.saturate(shape, f64(-1 + f32(k) / 60) * f64(drive)))
		lin := make([]f32, 2, context.temp_allocator)
		lin[0], lin[1] = -1, 1
		ui.line_plot("effect curve", {{ys = lin, color = ui.with_alpha(th.text, 0.2), width = 1}, {ys = ys, color = color, width = 2.5}}, size, -1.2, 1.2, {0.5}, {0})

	case .Bitcrush:
		bits := clamp(fxv(a, t, s, dsp.BITCRUSH_PARAM_BITS), 1, 24)
		hold := max(int(fxv(a, t, s, dsp.BITCRUSH_PARAM_DOWNSAMPLE)), 1)
		levels := math.pow(2, bits - 1)
		n := 256
		clean := make([]f32, n, context.temp_allocator)
		crushed := make([]f32, n, context.temp_allocator)
		for k in 0 ..< n {
			clean[k] = math.sin(math.TAU * 2 * f32(k) / f32(n))
			src := (k / hold) * hold
			v := math.sin(math.TAU * 2 * f32(src) / f32(n))
			crushed[k] = math.round(v * levels) / levels
		}
		ui.line_plot("effect curve", {{ys = clean, color = ui.with_alpha(th.text, 0.25), width = 1}, {ys = crushed, color = color, width = 2}}, size, -1.1, 1.1, nil, {0})

	case .Delay, .Reverb, .Comb, .Chorus, .Flanger, .Phaser, .Ring_Mod, .Pitch, .Cutter, .Stutter:
		draw_time_view(a, t, s, held, size)
	}
	im.Spacing()
}

// The effects whose picture is about time: echoes, decays, sweeps, slices.
@(private)
draw_time_view :: proc(a: ^App, t: pm.Fx_Target, s, held: pm.Effect_Slot, size: im.Vec2) {
	m := &a.m
	th := ui.theme()
	color := th.accent
	bpm := m.project.bpm
	beat, playing := pm.timeline_beat(&m.engine)
	clock := a.transport.clock
	#partial switch s.kind {
	case .Delay:
		// Left, two seconds after a hit: the hit (grey), then each echo a bar
		// as loud as the mix and feedback make it (ping-pong: alternating
		// sides, two colours), on the beat grid. Right, its tone: the cuts in
		// its feedback (each echo through them once more, fainter), over the
		// spectrum of what it puts out now.
		secs := fxv(a, t, s, dsp.DELAY_PARAM_TIME_MS) / 1000
		if fxv(a, t, s, dsp.DELAY_PARAM_SYNC) >= 0.5 do secs = fxv(a, t, s, dsp.DELAY_PARAM_BEATS) * f32(60 / bpm)
		fb := clamp(fxv(a, t, s, dsp.DELAY_PARAM_FEEDBACK), 0, 0.99)
		mix := clamp(fxv(a, t, s, dsp.DELAY_PARAM_MIX), 0, 1)
		pp := fxv(a, t, s, dsp.DELAY_PARAM_PING_PONG) >= 0.5
		echo_w := size.x * 0.52
		pos := im.GetCursorScreenPos()
		im.Dummy({echo_w, size.y})
		ui.name("effect echoes")
		if im.IsItemHovered() do im.SetTooltip("%s", fmt.ctprintf("Echoes every %.0f ms, each %.0f%% of the last%s", secs * 1000, fb * 100, " (ping-pong: left, right)" if pp else ""))
		dl := im.GetWindowDrawList()
		im.DrawList_AddRectFilled(dl, pos, {pos.x + echo_w, pos.y + size.y}, ui.col(ui.PLOT_BG), th.radius)
		x0, x1 := pos.x + 12, pos.x + echo_w - 12
		base, top := pos.y + size.y - 10, pos.y + 12
		for b := f32(0); b * f32(60 / bpm) < 2; b += 1 {
			x := x0 + (x1 - x0) * b * f32(60 / bpm) / 2
			im.DrawList_AddLine(dl, {x, top}, {x, base}, ui.col(ui.mix(ui.PLOT_BG, th.text, 0.1)), 1)
		}
		bar :: proc(dl: ^im.DrawList, x, base, top, lv: f32, c: ui.Color) {
			im.DrawList_AddRectFilled(dl, {x - 3, base - (base - top) * lv}, {x + 3, base}, ui.col(c), 2)
		}
		bar(dl, x0, base, top, 1, ui.with_alpha(th.text, 0.35))
		if secs > 0.005 do for k := 1; f32(k) * secs < 2; k += 1 {
			lv := mix * math.pow(fb, f32(k - 1))
			if lv < 0.01 do break
			bar(dl, x0 + (x1 - x0) * f32(k) * secs / 2, base, top, lv, th.warn if pp && k % 2 == 0 else color)
		}
		im.SameLine(0, 8)
		lo_cut, hi_cut := f64(fxv(a, t, s, dsp.DELAY_PARAM_LOW_CUT_HZ)), f64(fxv(a, t, s, dsp.DELAY_PARAM_HIGH_CUT_HZ))
		sr := a.host.graph.settings.sample_rate if a.host.graph.settings.sample_rate > 0 else 48_000
		hp, lp := dsp.svf_design(.Highpass, lo_cut, 0.707, 0, sr), dsp.svf_design(.Lowpass, hi_cut, 0.707, 0, sr)
		curves := make([dynamic]ui.Plot_Curve, context.temp_allocator)
		if spec := spectrum(a); spec != nil do append(&curves, ui.Plot_Curve{db = spec, color = ui.with_alpha(th.text, 0.28), width = 1.2})
		for n := 4; n >= 1; n -= 1 { // echo n has been through the cuts n times
			db := make([]f32, 160, context.temp_allocator)
			for &v, k in db {
				f := f64(ui.x_freq(f32(k) / 159))
				g1, _ := dsp.svf_response(&hp, f, sr)
				g2, _ := dsp.svf_response(&lp, f, sr)
				v = f32(f64(n) * 20 * math.log10(max(g1 * g2, 1e-6)))
			}
			append(&curves, ui.Plot_Curve{db = db, color = ui.with_alpha(color, 1 if n == 1 else 0.6 / f32(n)), fill = n == 1, width = 2.5 if n == 1 else 1.2})
		}
		ui.response_plot("delay tone", curves[:], nil, {size.x - echo_w - 8, size.y})
		if im.IsItemHovered() do im.SetTooltip("%s", fmt.ctprintf("Its cuts: %.0f Hz to %.0f Hz (each echo through them again: the fainter lines); behind, what it puts out now", lo_cut, hi_cut))
	case .Reverb:
		decay := max(fxv(a, t, s, dsp.REVERB_PARAM_DECAY_S), 0.05)
		pre := fxv(a, t, s, dsp.REVERB_PARAM_PREDELAY_MS) / 1000
		hf := clamp(fxv(a, t, s, dsp.REVERB_PARAM_HF_DECAY), 0.05, 1)
		span := pre + decay * 1.2
		n := 160
		lows := make([]f32, n, context.temp_allocator)
		highs := make([]f32, n, context.temp_allocator)
		for k in 0 ..< n {
			tt := span * f32(k) / f32(n - 1)
			if tt < pre {
				lows[k], highs[k] = -60, -60
				continue
			}
			lows[k] = -60 * (tt - pre) / decay
			highs[k] = -60 * (tt - pre) / (decay * hf)
		}
		ui.line_plot("effect decay", {{ys = highs, color = th.warn, width = 1.5}, {ys = lows, color = color, fill = true, width = 2.5}}, size, -60, 0, nil, {-48, -36, -24, -12})
		if im.IsItemHovered() do im.SetTooltip("%s", fmt.ctprintf("%.2f s to fall 60 dB (highs: the dimmer line), after %.0f ms", decay, pre * 1000))
	case .Comb:
		hz := max(f64(fxv(a, t, s, dsp.COMB_PARAM_HZ)), 20)
		fb := f64(clamp(fxv(a, t, s, dsp.COMB_PARAM_FEEDBACK), -0.99, 0.99))
		db := make([]f32, 600, context.temp_allocator)
		for &v, k in db {
			f := f64(ui.x_freq(f32(k) / 599))
			wt := math.TAU * f / hz
			re, im_ := 1 - fb * math.cos(wt), fb * math.sin(wt)
			v = f32(-20 * math.log10(max(math.sqrt(re * re + im_ * im_), 1e-6)))
		}
		spec := spectrum(a)
		curves := make([dynamic]ui.Plot_Curve, context.temp_allocator)
		if spec != nil do append(&curves, ui.Plot_Curve{db = spec, color = ui.with_alpha(th.text, 0.28), width = 1.2})
		append(&curves, ui.Plot_Curve{db = db, color = color, fill = true, width = 2})
		ui.response_plot("effect response", curves[:], nil, size, -24, 24)
	case .Chorus, .Flanger, .Phaser:
		// The sweep over two seconds, and where it is now.
		rate := max(fxv(a, t, s, dsp.MOD_PARAM_RATE_HZ), 0.01)
		depth := fxv(a, t, s, dsp.MOD_PARAM_DEPTH)
		if s.kind != .Phaser do depth /= 10 // chorus and flanger: milliseconds of 10
		depth = clamp(depth, 0.05, 1)
		n := 160
		ys := make([]f32, n, context.temp_allocator)
		for &y, k in ys do y = depth * math.sin(math.TAU * rate * 2 * f32(k) / f32(n - 1))
		ph := f32(math.mod(clock * f64(rate), 1))
		now := depth * math.sin(math.TAU * ph)
		ui.line_plot("effect sweep", {{ys = ys, color = color, width = 2.5}}, size, -1.1, 1.1, {0.25, 0.5, 0.75}, {0}, {ph / (rate * 2) if rate * 2 >= 1 else ph, now}, th.warn)
	case .Ring_Mod:
		hz := max(fxv(a, t, s, dsp.RING_PARAM_HZ), 1)
		n := 200
		ys := make([]f32, n, context.temp_allocator)
		for &y, k in ys do y = math.sin(math.TAU * hz * 0.02 * f32(k) / f32(n - 1)) // 20 ms of the carrier
		ui.line_plot("effect carrier", {{ys = ys, color = color, width = 2}}, size, -1.1, 1.1, nil, {0})
		if im.IsItemHovered() do im.SetTooltip("%s", fmt.ctprintf("The carrier: %.0f Hz (20 ms shown)", hz))
	case .Pitch:
		st := fxv(a, t, held, dsp.PITCH_PARAM_SEMITONES)
		pos := im.GetCursorScreenPos()
		im.Dummy(size)
		ui.name("effect pitch")
		dl := im.GetWindowDrawList()
		im.DrawList_AddRectFilled(dl, pos, {pos.x + size.x, pos.y + size.y}, ui.col(ui.PLOT_BG), th.radius)
		im.PushFontFloat(a.platform.fonts.semibold, 34)
		txt := fmt.ctprintf("%+.1f st", st)
		ts := im.CalcTextSize(txt)
		im.DrawList_AddText(dl, {pos.x + (size.x - ts.x) / 2, pos.y + size.y / 2 - ts.y / 2 - 8}, ui.col(color), txt)
		im.PopFont()
		sub := fmt.ctprintf("× %.3f the speed", math.pow(2, st / 12))
		ss := im.CalcTextSize(sub)
		im.DrawList_AddText(dl, {pos.x + (size.x - ss.x) / 2, pos.y + size.y / 2 + ts.y / 2}, ui.col(th.text_dim), sub)
	case .Cutter, .Stutter:
		// A bar of slices against the beat, the playhead running over it.
		b := fxv(a, t, held, dsp.CUTTER_PARAM_BEATS if s.kind == .Cutter else dsp.STUTTER_PARAM_BEATS)
		duty := fxv(a, t, s, dsp.CUTTER_PARAM_DUTY) if s.kind == .Cutter else 1
		bar := f32(pm.bar_beats(&m.project))
		n := 400
		ys := make([]f32, n, context.temp_allocator)
		for &y, k in ys {
			x := bar * f32(k) / f32(n - 1)
			f := math.mod(x, max(b, 1.0 / 64)) / max(b, 1.0 / 64)
			y = 1 if s.kind == .Stutter && f < 0.92 else (1 if f < duty else 0)
			if s.kind == .Stutter do y *= 1 - f * 0.6 // the slice repeats, fading as it goes
		}
		x := f32(math.mod(beat, f64(bar)) / f64(bar)) if playing else -1
		ui.line_plot("effect slices", {{ys = ys, color = color, fill = true, width = 2}}, size, -0.1, 1.2, {0.25, 0.5, 0.75}, nil, {x, 1.1}, th.warn)
	}
}

// A vertical gain reduction meter: how far down, 0 to 24 dB.
@(private)
reduction_meter :: proc(a: ^App, db: f32, size: im.Vec2) {
	th := ui.theme()
	pos := im.GetCursorScreenPos()
	im.Dummy(size)
	ui.name("gain reduction")
	dl := im.GetWindowDrawList()
	im.DrawList_AddRectFilled(dl, pos, {pos.x + size.x, pos.y + size.y}, ui.col(ui.PLOT_BG), th.radius)
	f := clamp(db / 24, 0, 1)
	im.DrawList_AddRectFilled(dl, {pos.x + 14, pos.y + 22}, {pos.x + size.x - 14, pos.y + 22 + (size.y - 30) * f}, ui.col(th.warn), 3)
	txt := fmt.ctprintf("-%.1f", db)
	ts := im.CalcTextSize(txt)
	im.DrawList_AddText(dl, {pos.x + (size.x - ts.x) / 2, pos.y + 3}, ui.col(th.text if db > 0.1 else th.text_dim), txt)
	if im.IsItemHovered() do im.SetTooltip("How much it turns down now (dB)")
}

@(private)
app_seal :: proc(a: ^App) {
	app.seal(&a.m.history)
}

// Frames analysed for an effect's spectrum.
@(private) SPECTRUM_SIZE :: 2048

// The spectrum of what the watched effect puts out now, in dB at the
// response plots' 160 log-spaced frequencies (shifted so -60 dBFS is the
// plots' floor), falling slowly from peaks; nil before anything is heard.
spectrum :: proc(a: ^App) -> []f32 {
	st := &a.spectrum
	if !st.ready {
		if dsp.fft_init(&st.fft, SPECTRUM_SIZE) != .None do return nil
		st.ready = true
		for &v in st.smooth do v = -36
	}
	x: [SPECTRUM_SIZE]f32
	if !pm.watch_read(&a.m.engine, x[:]) do return nil
	sr := a.host.graph.settings.sample_rate if a.host.graph.settings.sample_rate > 0 else 48_000
	buf := make([]complex64, SPECTRUM_SIZE, context.temp_allocator)
	out := make([]complex64, SPECTRUM_SIZE, context.temp_allocator)
	for v, i in x {
		w := 0.5 - 0.5 * math.cos(math.TAU * f32(i) / f32(SPECTRUM_SIZE - 1)) // Hann
		buf[i] = complex(v * w, 0)
	}
	dsp.fft_forward(&st.fft, buf, out)
	res := make([]f32, len(st.smooth), context.temp_allocator)
	n := len(st.smooth)
	for k in 0 ..< n {
		f0, f1 := ui.x_freq(f32(k) / f32(n - 1)), ui.x_freq(f32(k + 1) / f32(n - 1))
		b0 := clamp(int(f64(f0) / sr * SPECTRUM_SIZE), 1, SPECTRUM_SIZE / 2 - 1)
		b1 := clamp(int(f64(f1) / sr * SPECTRUM_SIZE), b0, SPECTRUM_SIZE / 2 - 1)
		peak: f32 = 0
		for b in b0 ..= b1 do peak = max(peak, abs(out[b]))
		db := 20 * math.log10(max(peak * 4 / SPECTRUM_SIZE, 1e-7)) + 24 // dBFS (Hann's loss made up), -60 at the floor
		st.smooth[k] = max(db, st.smooth[k] - 1.2) // falls 1.2 dB a frame
		res[k] = st.smooth[k]
	}
	return res
}

// What the spectrum keeps between frames.
Spectrum_State :: struct {
	fft:    dsp.Fft,
	ready:  bool,
	smooth: [160]f32,
}
