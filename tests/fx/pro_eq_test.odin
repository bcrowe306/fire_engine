package test_fx

import "core:math"
import "core:testing"

import "fire:core"
import "fire:fx"
import kit "fire:testkit"

// Set A's band `b`'s `f`, as an event pair for `sf_set`.
B :: proc(b: int, f: fx.Pro_Eq_Field, v: f64, set := 0) -> [2]f64 { return {f64(fx.pro_eq_band_param(set, b, f)), v} }

// Renders `input` through a fresh ProEq with `events`.
pe_render :: proc(t: ^testing.T, input: kit.Audio_Buffer, events: []kit.Timed_Event, oversample := false, block := 512, hook: kit.Block_Hook = nil, user: rawptr = nil) -> kit.Audio_Buffer {
	node, _, err := fx.pro_eq_create({oversample = oversample})
	testing.expect_value(t, err, core.Error.None)
	defer core.node_destroy(&node)
	cfg := kit.default_render_config()
	cfg.events = events
	cfg.blocks = kit.Fixed_Blocks{block}
	cfg.after_block, cfg.user = hook, user
	out, r := kit.render(&node, input, cfg, context.temp_allocator)
	defer kit.render_report_destroy(&r)
	kit.expect_clean_render(t, r)
	return out
}

// The response (dB) at each of `hz` through `events`' settings, from an
// impulse, on the left (`ch` 1: the right).
pe_response :: proc(t: ^testing.T, hz: []f64, events: []kit.Timed_Event, oversample := false, ch := 0, mono := true) -> []f64 {
	n := 32_768
	x := make([]f32, n, context.temp_allocator)
	x[4096] = 1 // (after the settings have arrived)
	in_ := sf_stereo(x)
	if !mono do for &v in in_.channels[1] do v = 0
	out := pe_render(t, in_, events, oversample)
	res := make([]f64, len(hz), context.temp_allocator)
	for h, i in hz do res[i] = kit.response_db(out.channels[ch][4096:], SR, h)
	return res
}

pe_at :: proc(t: ^testing.T, hz: f64, events: []kit.Timed_Event, oversample := false) -> f64 {
	return pe_response(t, {hz}, events, oversample)[0]
}

// Every band type at every slope, in every mode, turned up, on loud
// noise, plain and oversampled: a clean render (finite, no allocations on
// the audio thread).
@(test)
every_pro_eq_band_is_clean :: proc(t: ^testing.T) {
	x := noise(9600)
	for &v in x do v *= 2
	for os in ([]bool{false, true}) do for typ in fx.Pro_Eq_Type do for slope in fx.Pro_Eq_Slope do for mode in fx.Pro_Eq_Mode {
		ev := make([dynamic]kit.Timed_Event, context.temp_allocator)
		append(&ev, ..sf_set(P(fx.PE_PARAM_MODE, f64(mode))))
		for b in 0 ..< fx.PE_BANDS do for set in 0 ..< 2 {
			append(&ev, ..sf_set(B(b, .On, 1, set), B(b, .Type, f64(typ), set), B(b, .Slope, f64(slope), set),
				B(b, .Freq_Hz, 30 * math.pow(2, f64(b) * 1.3), set), B(b, .Gain_Db, 15 if b % 2 == 0 else -15, set), B(b, .Q, 18 if b % 3 == 0 else 0.1, set)))
		}
		out := pe_render(t, sf_stereo(x), ev[:], os)
		bad, _ := kit.count_non_finite(out.channels[0])
		bad2, _ := kit.count_non_finite(out.channels[1])
		testing.expectf(t, bad + bad2 == 0 && kit.peak(out.channels[0]) < 1e4, "%v %v %v (oversampled %v): finite", typ, slope, mode, os)
	}
}

// The same output in any block size, with changes on the way (a sweep,
// a type, the mode), plain and oversampled.
@(test)
the_pro_eq_is_block_size_invariant :: proc(t: ^testing.T) {
	input := kit.buffer_make(2, 48_000, SR, context.temp_allocator)
	for ch in 0 ..< 2 do kit.white_noise(input.channels[ch], u64(ch + 3), 0.4)
	for os in ([]bool{false, true}) {
		cfg := kit.default_render_config()
		ev := make([dynamic]kit.Timed_Event, context.temp_allocator)
		append(&ev, ..sf_set(B(2, .Gain_Db, 9), B(2, .Q, 3), B(0, .On, 1), B(0, .Slope, 3), B(0, .Freq_Hz, 120), B(6, .Gain_Db, -6)))
		append(&ev, kit.Timed_Event{9_001, core.Param_Value{fx.pro_eq_band_param(0, 2, .Freq_Hz), 5000}})
		append(&ev, kit.Timed_Event{17_123, core.Param_Value{fx.pro_eq_band_param(0, 3, .Type), f64(fx.Pro_Eq_Type.Notch)}})
		append(&ev, kit.Timed_Event{25_555, core.Param_Value{fx.PE_PARAM_MODE, f64(fx.Pro_Eq_Mode.Mid_Side)}})
		append(&ev, kit.Timed_Event{25_555, core.Param_Value{fx.pro_eq_band_param(1, 4, .Gain_Db), 12}})
		append(&ev, kit.Timed_Event{30_001, core.Param_Value{fx.PE_PARAM_GAIN_DB, -9}})
		append(&ev, kit.Timed_Event{36_000, core.Param_Value{fx.PE_PARAM_SCALE, -1}})
		cfg.events = ev[:]
		patterns := kit.standard_block_patterns(cfg.max_block)
		factory := kit.Node_Factory{create = proc(_: rawptr) -> core.Node {
			n, _, _ := fx.pro_eq_create({})
			return n
		}}
		if os do factory.create = proc(_: rawptr) -> core.Node {
			n, _, _ := fx.pro_eq_create({oversample = true})
			return n
		}
		kit.expect_block_invariant(t, factory, input, cfg, patterns[:], 1e-5, "pro_eq_os" if os else "pro_eq")
	}
}

// At its defaults (every gain at 0 dB, the cuts off) it is the input, bit
// for bit; with the cuts on but every gain shape flat too.
@(test)
a_flat_pro_eq_is_the_input :: proc(t: ^testing.T) {
	in_ := sf_stereo(noise(24_000))
	out := pe_render(t, in_, nil)
	testing.expect(t, kit.compare_buffers(in_, out).max_abs_error == 0, "the defaults: the input")
	out = pe_render(t, in_, sf_set(P(fx.PE_PARAM_SCALE, 2), P(fx.PE_PARAM_MODE, 2)))
	testing.expectf(t, kit.compare_buffers(in_, out).max_abs_error < 1e-6, "M/S, scaled, flat: the input (%v)", kit.compare_buffers(in_, out).max_abs_error)
}

// A bell of +12 dB is +12 at its frequency, at 1 kHz and at 16 kHz (no
// cramping), and as wide as its Q says (half its gain an octave either
// side at Q 0.7, about); a cut at −12 too.
@(test)
a_pro_eq_bell_is_what_it_says :: proc(t: ^testing.T) {
	for hz in ([]f64{1000, 16_000}) {
		ev := sf_set(B(2, .Freq_Hz, hz), B(2, .Gain_Db, 12), B(2, .Q, 1), P(fx.PE_PARAM_ADAPTIVE_Q, 0))
		g := pe_at(t, hz, ev)
		testing.expectf(t, abs(g - 12) < (0.2 if hz < 10_000 else 0.5), "%v Hz: +12 dB (%.2f)", hz, g)
		cut := pe_at(t, hz, sf_set(B(2, .Freq_Hz, hz), B(2, .Gain_Db, -12), B(2, .Q, 1), P(fx.PE_PARAM_ADAPTIVE_Q, 0)))
		testing.expectf(t, abs(cut + 12) < (0.2 if hz < 10_000 else 0.5), "%v Hz: −12 dB (%.2f)", hz, cut)
	}
	// Narrower at a higher Q.
	wide := pe_at(t, 2000, sf_set(B(2, .Freq_Hz, 1000), B(2, .Gain_Db, 12), B(2, .Q, 0.7), P(fx.PE_PARAM_ADAPTIVE_Q, 0)))
	narrow := pe_at(t, 2000, sf_set(B(2, .Freq_Hz, 1000), B(2, .Gain_Db, 12), B(2, .Q, 4), P(fx.PE_PARAM_ADAPTIVE_Q, 0)))
	testing.expectf(t, wide > 5 && narrow < 2, "an octave up: %.1f dB at Q 0.7, %.1f at Q 4", wide, narrow)
}

// Each cut falls by its slope an octave at a time, well past its corner,
// and passes (within 0.5 dB) well before it.
@(test)
pro_eq_cuts_fall_by_their_slope :: proc(t: ^testing.T) {
	SLOPES := [fx.Pro_Eq_Slope]f64{.S12 = 12, .S24 = 24, .S36 = 36, .S48 = 48, .S96 = 96}
	for slope in fx.Pro_Eq_Slope {
		if slope == .S96 { // (two octaves down a 96 dB slope is under float's floor: an octave and a half from the corner)
			r := pe_response(t, {350, 500, 8000}, sf_set(B(0, .On, 1), B(0, .Slope, f64(slope)), B(0, .Freq_Hz, 1000)))
			testing.expectf(t, r[1] < -80 && r[0] < r[1] - 40 && abs(r[2]) < 0.5, "low cut 96: %v", r)
			continue
		}
		lo := pe_response(t, {125, 250, 8000}, sf_set(B(0, .On, 1), B(0, .Slope, f64(slope)), B(0, .Freq_Hz, 1000)))
		drop := lo[1] - lo[0]
		testing.expectf(t, abs(drop - SLOPES[slope]) < 1.5 && abs(lo[2]) < 0.5, "low cut %v: %.1f dB an octave, %.2f dB at 8 kHz", slope, drop, lo[2])
		hi := pe_response(t, {4000, 8000, 125}, sf_set(B(7, .On, 1), B(7, .Slope, f64(slope)), B(7, .Freq_Hz, 1000)))
		hdrop := hi[0] - hi[1]
		testing.expectf(t, abs(hdrop - SLOPES[slope]) < 1.5 && abs(hi[2]) < 0.5, "high cut %v: %.1f dB an octave, %.2f dB at 125 Hz", slope, hdrop, hi[2])
	}
	// The corner: −3 dB at 12 dB and Q 0.71.
	c := pe_at(t, 1000, sf_set(B(0, .On, 1), B(0, .Freq_Hz, 1000)))
	testing.expectf(t, abs(c + 3) < 0.3, "the corner (%.2f dB)", c)
}

// Shelves reach their gain far from Freq and nothing far the other way; a
// notch takes Freq out; a band-pass peaks at 0 dB; a tilt is half its gain
// each way.
@(test)
pro_eq_shelves_notch_band_and_tilt :: proc(t: ^testing.T) {
	ls := pe_response(t, {30, 500, 12_000}, sf_set(B(1, .Freq_Hz, 500), B(1, .Gain_Db, 9)))
	testing.expectf(t, abs(ls[0] - 9) < 0.5 && abs(ls[1] - 4.5) < 0.5 && abs(ls[2]) < 0.3, "low shelf: %v", ls)
	hs := pe_response(t, {30, 2000, 18_000}, sf_set(B(6, .Freq_Hz, 2000), B(6, .Gain_Db, -9)))
	testing.expectf(t, abs(hs[0]) < 0.3 && abs(hs[1] + 4.5) < 0.5 && abs(hs[2] + 9) < 0.5, "high shelf: %v", hs)
	nt := pe_response(t, {1000, 100, 10_000}, sf_set(B(3, .Type, f64(fx.Pro_Eq_Type.Notch)), B(3, .Freq_Hz, 1000), B(3, .Q, 2)))
	testing.expectf(t, nt[0] < -40 && abs(nt[1]) < 0.5 && abs(nt[2]) < 0.5, "notch: %v", nt)
	bp := pe_response(t, {1000, 100, 10_000}, sf_set(B(3, .Type, f64(fx.Pro_Eq_Type.Band_Pass)), B(3, .Freq_Hz, 1000), B(3, .Q, 2)))
	testing.expectf(t, abs(bp[0]) < 0.2 && bp[1] < -15 && bp[2] < -15, "band-pass: %v", bp)
	tl := pe_response(t, {20, 1000, 20_000}, sf_set(B(3, .Type, f64(fx.Pro_Eq_Type.Tilt)), B(3, .Freq_Hz, 1000), B(3, .Gain_Db, 12)))
	testing.expectf(t, abs(tl[0] + 6) < 1 && abs(tl[1]) < 0.5 && abs(tl[2] - 6) < 1, "tilt: %v", tl)
}

// What `pro_eq_curve` draws is what the node does, at every third of an
// octave, for a busy setting (plain and oversampled), and for one band
// alone.
@(test)
the_pro_eq_curve_is_its_response :: proc(t: ^testing.T) {
	ev := sf_set(B(0, .On, 1), B(0, .Slope, 1), B(0, .Freq_Hz, 60), B(1, .Gain_Db, 4), B(2, .Freq_Hz, 300), B(2, .Gain_Db, -8), B(2, .Q, 3),
		B(4, .Type, f64(fx.Pro_Eq_Type.Notch)), B(4, .Freq_Hz, 3000), B(5, .Gain_Db, 6), B(5, .Freq_Hz, 9000), B(6, .Gain_Db, -5), B(7, .On, 1), B(7, .Freq_Hz, 16_000),
		P(fx.PE_PARAM_SCALE, 1.5))
	hz := make([dynamic]f64, context.temp_allocator)
	hz32 := make([dynamic]f32, context.temp_allocator)
	for k in 0 ..< 29 {
		h := 31.5 * math.pow(2, f64(k) / 3)
		if h > 18_000 do break
		append(&hz, h)
		append(&hz32, f32(h))
	}
	for os in ([]bool{false, true}) {
		v := fx.pro_eq_defaults()
		for e in ev do if p, ok := e.payload.(core.Param_Value); ok do v[p.param] = f32(p.value)
		v[fx.PE_PARAM_OVERSAMPLE] = 1 if os else 0
		want := make([]f32, len(hz32), context.temp_allocator)
		fx.pro_eq_curve(&v, 0, SR, hz32[:], want)
		got := pe_response(t, hz[:], ev, os)
		for h, i in hz {
			if abs(h - 3000) / 3000 < 0.15 do continue // (at the notch: −∞ both)
			tol := 0.5 if !os || h < 15_000 else 1.0 // (the oversampler's own edge)
			testing.expectf(t, abs(got[i] - f64(want[i])) < tol, "%.0f Hz (oversampled %v): drawn %.2f dB, heard %.2f", h, os, want[i], got[i])
		}
	}
	// One band alone: band 2's bell.
	v := fx.pro_eq_defaults()
	v[fx.pro_eq_band_param(0, 2, .Gain_Db)] = 6
	v[fx.pro_eq_band_param(0, 1, .Gain_Db)] = -9
	one: [1]f32
	fx.pro_eq_curve(&v, 0, SR, {240}, one[:], band = 2)
	testing.expectf(t, abs(one[0] - 6) < 0.1, "band 2 alone at 240 Hz (%.2f)", one[0])
}

// In L/R, set A touches only the left; in M/S, set B (the side) leaves a
// mono input alone.
@(test)
pro_eq_sides :: proc(t: ^testing.T) {
	lr := sf_set(P(fx.PE_PARAM_MODE, 1), B(2, .Freq_Hz, 1000), B(2, .Gain_Db, 12))
	l := pe_response(t, {1000}, lr, ch = 0)[0]
	r := pe_response(t, {1000}, lr, ch = 1)[0]
	testing.expectf(t, abs(l - 12) < 0.3 && abs(r) < 0.05, "L/R: left %.2f, right %.2f", l, r)
	ms := sf_set(P(fx.PE_PARAM_MODE, 2), B(2, .Freq_Hz, 1000, 1), B(2, .Gain_Db, 12, 1))
	m := pe_response(t, {1000}, ms)[0]
	testing.expectf(t, abs(m) < 0.05, "M/S: the side's bell on a mono input (%.2f)", m)
	// On a left-only input, the side is half of it: the bell shows on both.
	side := pe_response(t, {1000}, ms, ch = 1, mono = false)[0]
	testing.expectf(t, side > 0, "M/S: the side's bell on the left alone (%.2f)", side)
}

// Scale 0 flattens the gains (not the cuts); 2 doubles them. Adaptive Q
// narrows a big bell.
@(test)
pro_eq_scale_and_adaptive_q :: proc(t: ^testing.T) {
	zero := pe_response(t, {1000, 100}, sf_set(B(2, .Freq_Hz, 1000), B(2, .Gain_Db, 9), B(0, .On, 1), B(0, .Freq_Hz, 400), P(fx.PE_PARAM_SCALE, 0)))
	testing.expectf(t, abs(zero[0]) < 0.3 && zero[1] < -15, "scale 0: the bell gone (%.2f), the cut kept (%.1f)", zero[0], zero[1])
	twice := pe_at(t, 1000, sf_set(B(2, .Freq_Hz, 1000), B(2, .Gain_Db, 6), P(fx.PE_PARAM_SCALE, 2)))
	testing.expectf(t, abs(twice - 12) < 0.3, "scale 2: +12 (%.2f)", twice)
	off := pe_at(t, 2000, sf_set(B(2, .Freq_Hz, 1000), B(2, .Gain_Db, 15), P(fx.PE_PARAM_ADAPTIVE_Q, 0)))
	on := pe_at(t, 2000, sf_set(B(2, .Freq_Hz, 1000), B(2, .Gain_Db, 15), P(fx.PE_PARAM_ADAPTIVE_Q, 1)))
	testing.expectf(t, on < off - 1.5, "adaptive Q narrower an octave up (%.1f, off %.1f)", on, off)
}

// Oversampled, the node is as late as it says; plain, not at all.
@(test)
pro_eq_latency_is_what_it_reports :: proc(t: ^testing.T) {
	for os in ([]bool{false, true}) {
		node, _, _ := fx.pro_eq_create({oversample = os})
		late := core.node_latency(&node)
		core.node_destroy(&node)
		x := noise(24_000)
		out := pe_render(t, sf_stereo(x), sf_set(B(2, .Gain_Db, 0.5)), os)
		got := kit.estimate_latency(x, out.channels[0], 200)
		testing.expectf(t, got == late && (late > 0) == os, "oversampled %v: reports %d, is %d", os, late, got)
	}
}

// Auditioning a bell plays only around it: its frequency through, a tone
// far from it nearly gone; let go, the EQ as before.
@(test)
pro_eq_audition_plays_the_band :: proc(t: ^testing.T) {
	Hook :: struct {eq: ^fx.Pro_Eq, block: int}
	ev := sf_set(B(2, .Freq_Hz, 1000), B(2, .Gain_Db, 6), B(2, .Q, 2))
	level :: proc(t: ^testing.T, hz: f64, ev: []kit.Timed_Event, hear: bool) -> f64 {
		node, eq, _ := fx.pro_eq_create({})
		defer core.node_destroy(&node)
		if hear do fx.pro_eq_audition(eq, 0, 2)
		cfg := kit.default_render_config()
		cfg.events = ev
		out, r := kit.render(&node, sf_stereo(sine(hz, 24_000, 0.1)), cfg, context.temp_allocator)
		defer kit.render_report_destroy(&r)
		kit.expect_clean_render(t, r)
		return 20 * math.log10(kit.tone_amplitude(out.channels[0][12_000:], SR, hz) / 0.1)
	}
	at, far := level(t, 1000, ev, true), level(t, 100, ev, true)
	testing.expectf(t, abs(at) < 0.5 && far < -20, "auditioned: 1 kHz %.1f dB, 100 Hz %.1f dB", at, far)
	normal := level(t, 1000, ev, false)
	testing.expectf(t, abs(normal - 6) < 0.3, "not auditioned: the bell (%.1f)", normal)
}
