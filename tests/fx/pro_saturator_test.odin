package test_fx

import "core:math"
import "core:testing"

import "fire:core"
import "fire:fx"
import kit "fire:testkit"

// Renders `input` through a fresh ProSaturator with `events`.
ps_render :: proc(t: ^testing.T, input: kit.Audio_Buffer, events: []kit.Timed_Event, quality := fx.Pro_Saturator_Quality.Off, block := 512, written: ^u64 = nil, readout: ^fx.Pro_Saturator_Readout = nil) -> kit.Audio_Buffer {
	node, ps, err := fx.pro_saturator_create({quality = quality})
	testing.expect_value(t, err, core.Error.None)
	defer core.node_destroy(&node)
	cfg := kit.default_render_config()
	cfg.events = events
	cfg.blocks = kit.Fixed_Blocks{block}
	out, r := kit.render(&node, input, cfg, context.temp_allocator)
	defer kit.render_report_destroy(&r)
	kit.expect_clean_render(t, r)
	if written != nil do written^ = fx.pro_saturator_signal(ps, nil)
	if readout != nil do readout^ = fx.pro_saturator_readout(ps)
	return out
}

// The level (dB, against `amp`) of `hz` in `out`'s second half.
ps_level :: proc(out: kit.Audio_Buffer, hz: f64, amp: f64) -> f64 {
	n := len(out.channels[0])
	return 20 * math.log10(max(kit.tone_amplitude(out.channels[0][n / 2:], SR, hz), 1e-12) / amp)
}

// Every type at every quality, Color on and off, driven hard, on loud
// noise: a clean render (finite, no allocations on the audio thread).
@(test)
every_pro_saturator_is_clean :: proc(t: ^testing.T) {
	x := noise(9600)
	for &v in x do v *= 2
	for q in fx.Pro_Saturator_Quality do for typ in fx.Pro_Saturator_Type do for color in 0 ..< 2 {
		ev := sf_set(P(fx.PS_PARAM_TYPE, f64(typ)), P(fx.PS_PARAM_DRIVE_DB, 36), P(fx.PS_PARAM_COLOR, f64(color)), P(fx.PS_PARAM_BASE, 1), P(fx.PS_PARAM_DEPTH, -1),
			P(fx.PS_PARAM_WS_CURVE, 1), P(fx.PS_PARAM_WS_DEPTH, 1), P(fx.PS_PARAM_WS_PERIOD, 1), P(fx.PS_PARAM_WS_DAMP, 1), P(fx.PS_PARAM_OUTPUT_DB, 12))
		out := ps_render(t, sf_stereo(x), ev, q)
		bad, _ := kit.count_non_finite(out.channels[0])
		testing.expectf(t, bad == 0 && kit.peak(out.channels[0]) < 100, "%v %v color %d: finite", q, typ, color)
	}
}

// The same output in any block size, with changes on the way, at every
// quality.
@(test)
the_pro_saturator_is_block_size_invariant :: proc(t: ^testing.T) {
	input := kit.buffer_make(2, 48_000, SR, context.temp_allocator)
	for ch in 0 ..< 2 do kit.white_noise(input.channels[ch], u64(ch + 31), 0.5)
	for q in fx.Pro_Saturator_Quality {
		cfg := kit.default_render_config()
		ev := make([dynamic]kit.Timed_Event, context.temp_allocator)
		append(&ev, ..sf_set(P(fx.PS_PARAM_DRIVE_DB, 12), P(fx.PS_PARAM_COLOR, 1), P(fx.PS_PARAM_DEPTH, 0.5)))
		append(&ev, kit.Timed_Event{9_001, core.Param_Value{fx.PS_PARAM_TYPE, f64(fx.Pro_Saturator_Type.Tape)}})
		append(&ev, kit.Timed_Event{17_123, core.Param_Value{fx.PS_PARAM_DRIVE_DB, 24}})
		append(&ev, kit.Timed_Event{20_000, core.Param_Value{fx.PS_PARAM_TYPE, f64(fx.Pro_Saturator_Type.Waveshaper)}})
		append(&ev, kit.Timed_Event{25_555, core.Param_Value{fx.PS_PARAM_WS_DEPTH, 0.7}})
		append(&ev, kit.Timed_Event{30_001, core.Param_Value{fx.PS_PARAM_MIX, 0.4}})
		append(&ev, kit.Timed_Event{36_000, core.Param_Value{fx.PS_PARAM_FREQ_HZ, 5000}})
		append(&ev, kit.Timed_Event{40_000, core.Param_Value{fx.PS_PARAM_SOFT_CLIP, 1}})
		cfg.events = ev[:]
		patterns := kit.standard_block_patterns(cfg.max_block)
		factory := kit.Node_Factory{user = rawptr(uintptr(q)), create = proc(u: rawptr) -> core.Node {
			n, _, _ := fx.pro_saturator_create({quality = fx.Pro_Saturator_Quality(uintptr(u))})
			return n
		}}
		kit.expect_block_invariant(t, factory, input, cfg, patterns[:], 1e-6, "pro_saturator")
	}
}

// A slow ramp from −1 to 1 comes out on each curve as drawn
// (`pro_saturator_curve`), at two drives.
@(test)
the_pro_saturator_follows_its_curves :: proc(t: ^testing.T) {
	N :: 24_000
	x := make([]f32, N, context.temp_allocator)
	for &v, i in x do v = -1 + 2 * f32(i) / (N - 1)
	for typ in fx.Pro_Saturator_Type do for drive in ([]f64{0, 9}) {
		ev := sf_set(P(fx.PS_PARAM_TYPE, f64(typ)), P(fx.PS_PARAM_DRIVE_DB, drive), P(fx.PS_PARAM_DC, 0))
		out := ps_render(t, sf_stereo(x), ev)
		v := fx.pro_saturator_defaults()
		v[fx.PS_PARAM_TYPE], v[fx.PS_PARAM_DRIVE_DB] = f32(typ), f32(drive)
		worst: f32 = 0
		for i := 100; i < N; i += 97 do worst = max(worst, abs(out.channels[0][i] - fx.pro_saturator_curve(&v, x[i])))
		testing.expectf(t, worst < 0.01, "%v at %v dB: off the curve by %v", typ, drive, worst)
	}
}

// Quiet, every curve but the Waveshaper passes at about its level; Tube
// adds a second harmonic a symmetric curve doesn't; Digital Clip makes odd
// ones.
@(test)
pro_saturator_unity_and_harmonics :: proc(t: ^testing.T) {
	for typ in fx.Pro_Saturator_Type {
		if typ == .Waveshaper do continue
		out := ps_render(t, sf_stereo(sine(1000, 24_000, 0.01)), sf_set(P(fx.PS_PARAM_TYPE, f64(typ))))
		g := ps_level(out, 1000, 0.01)
		testing.expectf(t, abs(g) < 0.5, "%v: quiet at %.2f dB", typ, g)
	}
	at :: proc(t: ^testing.T, typ: fx.Pro_Saturator_Type, hz: f64) -> f64 {
		out := ps_render(t, sf_stereo(sine(200, 24_000, 0.5)), sf_set(P(fx.PS_PARAM_TYPE, f64(typ)), P(fx.PS_PARAM_DRIVE_DB, 12), P(fx.PS_PARAM_DC, 0)))
		return ps_level(out, hz, 0.5)
	}
	tube2, medium2, clip3 := at(t, .Tube, 400), at(t, .Medium_Curve, 400), at(t, .Digital_Clip, 600)
	testing.expectf(t, tube2 > -40 && medium2 < -80 && clip3 > -30, "2nd: Tube %.1f, Medium %.1f; 3rd: Digital Clip %.1f", tube2, medium2, clip3)
}

// Oversampled 4×, a hard-clipped 10 kHz tone aliases far less (at 2 kHz:
// its fifth harmonic folded) than at Off; each quality is as late as it
// says.
@(test)
pro_saturator_oversampling :: proc(t: ^testing.T) {
	alias :: proc(t: ^testing.T, q: fx.Pro_Saturator_Quality) -> f64 {
		out := ps_render(t, sf_stereo(sine(10_000, 24_000, 0.5)), sf_set(P(fx.PS_PARAM_TYPE, f64(fx.Pro_Saturator_Type.Digital_Clip)), P(fx.PS_PARAM_DRIVE_DB, 24)), q)
		return ps_level(out, 2000, 0.5)
	}
	off, x4 := alias(t, .Off), alias(t, .X4)
	testing.expectf(t, x4 < off - 20, "the alias at 2 kHz: %.1f dB off, %.1f dB at 4×", off, x4)
	for q in fx.Pro_Saturator_Quality {
		node, _, _ := fx.pro_saturator_create({quality = q})
		late := core.node_latency(&node)
		core.node_destroy(&node)
		x := noise(24_000)
		for &v in x do v *= 0.001
		out := ps_render(t, sf_stereo(x), sf_set(P(fx.PS_PARAM_TYPE, f64(fx.Pro_Saturator_Type.Medium_Curve)), P(fx.PS_PARAM_DC, 0)), q)
		got := kit.estimate_latency(x, out.channels[0], 400)
		testing.expectf(t, got == late && (late > 0) == (q != .Off), "%v: reports %d, is %d", q, late, got)
	}
}

// DC on takes Tube's offset away; Soft Clip keeps the output under full
// scale; Color's pre-emphasis and its inverse cancel on a quiet signal;
// Tape loses treble as it is driven.
@(test)
pro_saturator_dc_soft_clip_color_tape :: proc(t: ^testing.T) {
	mean :: proc(x: []f32) -> f64 {
		s: f64
		for v in x[len(x) / 2:] do s += f64(v)
		return s / f64(len(x) / 2)
	}
	tube :: proc(t: ^testing.T, dc: f64) -> f64 {
		out := ps_render(t, sf_stereo(sine(200, 48_000, 0.7)), sf_set(P(fx.PS_PARAM_TYPE, f64(fx.Pro_Saturator_Type.Tube)), P(fx.PS_PARAM_DRIVE_DB, 18), P(fx.PS_PARAM_DC, dc)))
		return mean(out.channels[0])
	}
	with, without := tube(t, 1), tube(t, 0)
	testing.expectf(t, abs(with) < 0.002 && abs(without) > 0.02, "Tube's offset: %.4f with DC, %.4f without", with, without)
	x := noise(24_000)
	for &v in x do v *= 4
	clipped := ps_render(t, sf_stereo(x), sf_set(P(fx.PS_PARAM_TYPE, f64(fx.Pro_Saturator_Type.Sinoid_Fold)), P(fx.PS_PARAM_OUTPUT_DB, 12), P(fx.PS_PARAM_SOFT_CLIP, 1)))
	testing.expectf(t, kit.peak(clipped.channels[0]) <= 1.0001, "soft clipped: %v", kit.peak(clipped.channels[0]))
	q := noise(24_000)
	for &v in q do v *= 0.001
	in_ := sf_stereo(q)
	colored := ps_render(t, in_, sf_set(P(fx.PS_PARAM_TYPE, f64(fx.Pro_Saturator_Type.Medium_Curve)), P(fx.PS_PARAM_COLOR, 1), P(fx.PS_PARAM_BASE, 1), P(fx.PS_PARAM_DEPTH, 1), P(fx.PS_PARAM_DC, 0)))
	r := kit.compare_buffers(in_, colored)
	testing.expectf(t, r.error_db < -40, "Color, quiet: the input back (%.1f dB off)", r.error_db)
	tape :: proc(t: ^testing.T, drive: f64) -> f64 {
		a := 0.01
		out := ps_render(t, sf_stereo(sine(10_000, 24_000, f32(a))), sf_set(P(fx.PS_PARAM_TYPE, f64(fx.Pro_Saturator_Type.Tape)), P(fx.PS_PARAM_DRIVE_DB, drive)))
		return ps_level(out, 10_000, a) - drive
	}
	clean, driven := tape(t, 0), tape(t, 24)
	testing.expectf(t, driven < clean - 5, "Tape at 10 kHz: %.1f dB at 0 dB of drive, %.1f at 24", clean, driven)
}

// Dry/Wet 0 is the input (as late as its quality), bit for bit; the
// signal ring takes a point every 8 frames; the peak in is after Drive.
@(test)
pro_saturator_dry_and_readouts :: proc(t: ^testing.T) {
	node, _, _ := fx.pro_saturator_create({quality = .X2})
	late := core.node_latency(&node)
	core.node_destroy(&node)
	x := noise(24_000)
	dry := ps_render(t, sf_stereo(x), sf_set(P(fx.PS_PARAM_MIX, 0), P(fx.PS_PARAM_DRIVE_DB, 24)), .X2)
	same := true
	for i in late ..< len(x) do if dry.channels[0][i] != x[i - late] do same = false
	testing.expect(t, same, "dry: the input, as late as it says")
	written: u64
	r: fx.Pro_Saturator_Readout
	ps_render(t, sf_stereo(sine(100, 24_000, 0.25)), sf_set(P(fx.PS_PARAM_DRIVE_DB, 6)), written = &written, readout = &r)
	testing.expect_value(t, written, u64(3000))
	testing.expectf(t, abs(r.in_peak - 0.5) < 0.01, "the peak in, after Drive (%v)", r.in_peak)
}
