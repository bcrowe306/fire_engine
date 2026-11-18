package test_fx

import "core:math"
import "core:testing"

import "fire:core"
import "fire:fx"
import kit "fire:testkit"

// Parameter changes at frame 0.
sf_set :: proc(pairs: ..[2]f64) -> []kit.Timed_Event {
	ev := make([]kit.Timed_Event, len(pairs), context.temp_allocator)
	for p, i in pairs do ev[i] = {0, core.Param_Value{core.Param_Id(p[0]), p[1]}}
	return ev
}

P :: proc(id: core.Param_Id, v: f64) -> [2]f64 { return {f64(id), v} }

// Renders `input` through a fresh SuperFilter with `events` (and the
// readouts after each block, when `readouts` is given).
sf_render :: proc(t: ^testing.T, input: kit.Audio_Buffer, events: []kit.Timed_Event, block := 512, readouts: ^[dynamic]fx.Super_Filter_Readout = nil) -> kit.Audio_Buffer {
	node, sf := fx.super_filter_create({})
	defer core.node_destroy(&node)
	cfg := kit.default_render_config()
	cfg.events = events
	cfg.blocks = kit.Fixed_Blocks{block}
	Hook :: struct {sf: ^fx.Super_Filter, out: ^[dynamic]fx.Super_Filter_Readout}
	h := Hook{sf, readouts}
	if readouts != nil {
		cfg.user = &h
		cfg.after_block = proc(user: rawptr, _: int, _: ^core.Process_Context) {
			h := (^Hook)(user)
			append(h.out, fx.super_filter_readout(h.sf))
		}
	}
	out, r := kit.render(&node, input, cfg, context.temp_allocator)
	defer kit.render_report_destroy(&r)
	kit.expect_clean_render(t, r)
	return out
}

sf_stereo :: proc(x: []f32) -> kit.Audio_Buffer {
	b := kit.buffer_make(2, len(x), SR, context.temp_allocator)
	copy(b.channels[0], x)
	copy(b.channels[1], x)
	return b
}

// The level (dB) a sine at `hz` comes out at through `events`' settings.
sf_gain_db :: proc(t: ^testing.T, hz: f64, events: []kit.Timed_Event) -> f64 {
	out := sf_render(t, sf_stereo(sine(hz, 24_000, 0.1)), events)
	return 20 * math.log10(kit.tone_amplitude(out.channels[0][12_000:], SR, hz) / 0.1)
}

// Every type on every circuit at both slopes, everything turned up and
// swinging, on loud noise: a clean render (finite, no allocations on the
// audio thread), and Clip keeps it at full scale.
@(test)
every_super_filter_is_clean_and_clipped :: proc(t: ^testing.T) {
	x := noise(12_000)
	for &v in x do v *= 4
	for typ in fx.Sf_Type do for circuit in fx.Sf_Circuit do for slope in 0 ..< 2 {
		ev := sf_set(P(fx.SF_PARAM_TYPE, f64(typ)), P(fx.SF_PARAM_CIRCUIT, f64(circuit)), P(fx.SF_PARAM_SLOPE, f64(slope)),
			P(fx.SF_PARAM_RESONANCE, 1), P(fx.SF_PARAM_DRIVE_DB, 24), P(fx.SF_PARAM_MORPH, 0.8),
			P(fx.SF_PARAM_LFO_AMOUNT, 1), P(fx.SF_PARAM_LFO_DIVISION, 12), P(fx.SF_PARAM_ENV_AMOUNT, -1), P(fx.SF_PARAM_LFO_STEREO, 1), P(fx.SF_PARAM_LFO_SPIN_HZ, 2))
		out := sf_render(t, sf_stereo(x), ev)
		pk := max(kit.peak(out.channels[0]), kit.peak(out.channels[1]))
		testing.expectf(t, pk <= 1.0001, "%v on %v, slope %d: at most full scale (%v)", typ, circuit, slope, pk)
	}
}

// The same output in any block size, modulated, keyed, with changes on
// the way.
@(test)
the_super_filter_is_block_size_invariant :: proc(t: ^testing.T) {
	Case :: struct {typ: fx.Sf_Type, circuit: fx.Sf_Circuit}
	cases := []Case{{.Low, .Clean}, {.Morph, .Ladder}, {.Band, .Dirty}, {.Comb, .Clean}, {.Vowel, .Clean}, {.DJ, .Analog}, {.Phaser, .Clean}}
	input := kit.buffer_make(4, 48_000, SR, context.temp_allocator)
	for ch in 0 ..< 4 do kit.white_noise(input.channels[ch], u64(ch + 7), 0.4)
	for c in cases {
		cfg := kit.default_render_config()
		ev := make([dynamic]kit.Timed_Event, context.temp_allocator)
		append(&ev, ..sf_set(P(fx.SF_PARAM_TYPE, f64(c.typ)), P(fx.SF_PARAM_CIRCUIT, f64(c.circuit)), P(fx.SF_PARAM_RESONANCE, 0.6),
			P(fx.SF_PARAM_LFO_AMOUNT, 0.5), P(fx.SF_PARAM_LFO_DIVISION, 10), P(fx.SF_PARAM_ENV_AMOUNT, 0.4), P(fx.SF_PARAM_ENV_SH, 1)))
		append(&ev, kit.Timed_Event{17_123, core.Param_Value{fx.SF_PARAM_FREQ_HZ, 300}})
		append(&ev, kit.Timed_Event{30_001, core.Param_Value{fx.SF_PARAM_MIX, 0.5}})
		cfg.events = ev[:]
		patterns := kit.standard_block_patterns(cfg.max_block)
		factory := kit.Node_Factory{create = proc(_: rawptr) -> core.Node {
			n, _ := fx.super_filter_create({})
			return n
		}}
		kit.expect_block_invariant(t, factory, input, cfg, patterns[:], 1e-4, "super_filter")
	}
}

// Low, High, Band and Notch at 1 kHz with no resonance do what they say,
// on every circuit; 24 dB cuts more than 12.
@(test)
the_super_filter_types_filter :: proc(t: ^testing.T) {
	for circuit in fx.Sf_Circuit {
		at :: proc(t: ^testing.T, circuit: fx.Sf_Circuit, typ: fx.Sf_Type, slope: int, hz: f64) -> f64 {
			return sf_gain_db(t, hz, sf_set(P(fx.SF_PARAM_TYPE, f64(typ)), P(fx.SF_PARAM_CIRCUIT, f64(circuit)), P(fx.SF_PARAM_SLOPE, f64(slope)), P(fx.SF_PARAM_RESONANCE, 0), P(fx.SF_PARAM_CLIP, 0)))
		}
		lo12, lo24, lo_pass := at(t, circuit, .Low, 0, 4000), at(t, circuit, .Low, 1, 4000), at(t, circuit, .Low, 0, 150)
		steeper := lo24 < lo12 - 8 if fx.super_filter_has_slope(circuit, .Low) else true
		testing.expectf(t, lo12 < -12 && steeper && abs(lo_pass) < 4, "%v Low: 4 kHz %.1f dB (24 dB: %.1f), 150 Hz %.1f dB", circuit, lo12, lo24, lo_pass)
		// (Diode makes only Low: the others play on Analog, checked there.)
		hi12, hi_pass := at(t, circuit, .High, 0, 250), at(t, circuit, .High, 0, 8000)
		testing.expectf(t, hi12 < -12 && abs(hi_pass) < 4, "%v High: 250 Hz %.1f dB, 8 kHz %.1f dB", circuit, hi12, hi_pass)
		b_mid, b_lo, b_hi := at(t, circuit, .Band, 0, 1000), at(t, circuit, .Band, 0, 100), at(t, circuit, .Band, 0, 10_000)
		testing.expectf(t, b_lo < b_mid - 10 && b_hi < b_mid - 10, "%v Band: %.1f at 1 kHz, %.1f at 100 Hz, %.1f at 10 kHz", circuit, b_mid, b_lo, b_hi)
		n_mid, n_lo, n_hi := at(t, circuit, .Notch, 0, 1000), at(t, circuit, .Notch, 0, 100), at(t, circuit, .Notch, 0, 10_000)
		testing.expectf(t, n_mid < n_lo - 12 && n_mid < n_hi - 12, "%v Notch: %.1f at 1 kHz, %.1f at 100 Hz, %.1f at 10 kHz", circuit, n_mid, n_lo, n_hi)
	}
}

// DJ with its knob in the middle (632 Hz) lets everything through, within
// half a dB; either side, it filters.
@(test)
dj_is_flat_in_the_middle :: proc(t: ^testing.T) {
	mid := 20 * math.sqrt(f64(1000))
	for hz in ([]f64{60, 500, 2000, 9000}) {
		g := sf_gain_db(t, hz, sf_set(P(fx.SF_PARAM_TYPE, f64(fx.Sf_Type.DJ)), P(fx.SF_PARAM_FREQ_HZ, mid), P(fx.SF_PARAM_CLIP, 0)))
		testing.expectf(t, abs(g) < 0.5, "%v Hz: flat (%.2f dB)", hz, g)
	}
	low := sf_gain_db(t, 9000, sf_set(P(fx.SF_PARAM_TYPE, f64(fx.Sf_Type.DJ)), P(fx.SF_PARAM_FREQ_HZ, 100), P(fx.SF_PARAM_CLIP, 0)))
	high := sf_gain_db(t, 60, sf_set(P(fx.SF_PARAM_TYPE, f64(fx.Sf_Type.DJ)), P(fx.SF_PARAM_FREQ_HZ, 8000), P(fx.SF_PARAM_CLIP, 0)))
	testing.expectf(t, low < -12 && high < -12, "low side cuts highs (%.1f), high side lows (%.1f)", low, high)
}

// Dry/Wet at 0 is the input, bit for bit (a piece late, as the node says
// it is), whatever else is turned up.
@(test)
dry_is_the_input :: proc(t: ^testing.T) {
	x := noise(24_000)
	node, _ := fx.super_filter_create({})
	late := core.node_latency(&node)
	core.node_destroy(&node)
	testing.expect_value(t, late, 32)
	out := sf_render(t, sf_stereo(x), sf_set(P(fx.SF_PARAM_MIX, 0), P(fx.SF_PARAM_RESONANCE, 1), P(fx.SF_PARAM_DRIVE_DB, 24), P(fx.SF_PARAM_LFO_AMOUNT, 1)))
	same := true
	for i in late ..< len(x) do if out.channels[0][i] != x[i - late] || out.channels[1][i] != x[i - late] do same = false
	for i in 0 ..< late do if out.channels[0][i] != 0 do same = false
	testing.expect(t, same, "the input, exactly, 32 frames late")
}

// The LFO moves the cutoff: synced at 1/4 and 120 BPM, round once a beat
// (50 blocks of 480); Phase 180°: the sides opposite, in octaves about
// Freq.
@(test)
the_lfo_moves_the_cutoff :: proc(t: ^testing.T) {
	r := make([dynamic]fx.Super_Filter_Readout, context.temp_allocator)
	sf_render(t, sf_stereo(noise(96_000)), sf_set(P(fx.SF_PARAM_LFO_AMOUNT, 0.2), P(fx.SF_PARAM_LFO_STEREO, 0), P(fx.SF_PARAM_LFO_PHASE_DEG, 180)), block = 480, readouts = &r)
	oct :: proc(hz: f32) -> f64 { return math.log2(f64(hz) / 1000) }
	ups := make([dynamic]int, context.temp_allocator)
	worst: f64
	for x, i in r {
		worst = max(worst, abs(oct(x.cutoff_hz[0]) + oct(x.cutoff_hz[1])))
		if i > 0 && oct(r[i - 1].cutoff_hz[0]) < 0 && oct(x.cutoff_hz[0]) >= 0 do append(&ups, i)
	}
	testing.expectf(t, len(ups) >= 3 && abs(f64(ups[len(ups) - 1] - ups[0]) / f64(len(ups) - 1) - 50) < 1, "a beat a cycle (%v)", ups)
	testing.expectf(t, worst < 0.02, "the sides opposite (off by %v octaves)", worst)
	peak: f64
	for x in r do peak = max(peak, oct(x.cutoff_hz[0]))
	testing.expectf(t, abs(peak - 1) < 0.05, "Amount 0.2: an octave up at most (%v)", peak)
}

// Keyed, the envelope follows the key, not the input: steady noise in,
// bursts in the key: the cutoff opens with each burst and closes between.
@(test)
the_envelope_follows_the_key :: proc(t: ^testing.T) {
	input := kit.buffer_make(4, 96_000, SR, context.temp_allocator)
	kit.white_noise(input.channels[0], 3, 0.5)
	kit.white_noise(input.channels[1], 4, 0.5)
	burst := noise(96_000)
	for &v, i in burst do v = v if (i / 12_000) % 2 == 0 else 0
	copy(input.channels[2], burst)
	copy(input.channels[3], burst)
	r := make([dynamic]fx.Super_Filter_Readout, context.temp_allocator)
	sf_render(t, input, sf_set(P(fx.SF_PARAM_ENV_AMOUNT, 0.4), P(fx.SF_PARAM_ENV_RELEASE_MS, 20)), block = 480, readouts = &r)
	on := r[(6000 / 480)].cutoff_hz[0]   // in the first burst
	off := r[(21_000 / 480)].cutoff_hz[0] // the gap after it
	testing.expectf(t, on > 2000 && off < 1100, "open in the burst (%v Hz), closed after (%v Hz)", on, off)
}

// The response the display draws: a low-pass's impulse passes the lows and
// cuts the highs, at its cutoff or at one asked for (its anchor that one);
// Vowel's anchor is its own (its formants follow no cutoff).
@(test)
the_super_filter_impulse_is_its_response :: proc(t: ^testing.T) {
	gain_db :: proc(x: []f32, hz: f64) -> f64 {
		re, im: f64
		for v, n in x {
			w := math.TAU * hz * f64(n) / 48_000
			re += f64(v) * math.cos(w)
			im -= f64(v) * math.sin(w)
		}
		return 20 * math.log10(max(math.sqrt(re * re + im * im) / 0.25, 1e-9))
	}
	v := fx.super_filter_defaults()
	v[fx.SF_PARAM_FREQ_HZ] = 1000
	v[fx.SF_PARAM_RESONANCE] = 0
	x := make([]f32, 4096, context.temp_allocator)
	base, anchor := fx.super_filter_impulse(&v, x, 48_000)
	testing.expect(t, base == 1000 && anchor == 1000, "at its own cutoff")
	testing.expectf(t, abs(gain_db(x, 100)) < 1 && gain_db(x, 8000) < -24, "low-pass (%.1f, %.1f dB)", gain_db(x, 100), gain_db(x, 8000))
	base, anchor = fx.super_filter_impulse(&v, x, 48_000, 250)
	testing.expect(t, base == 1000 && anchor == 250, "at the one asked for")
	testing.expectf(t, gain_db(x, 2000) < -24, "cut two octaves sooner (%.1f dB)", gain_db(x, 2000))
	// Dry/Wet at 0: the impulse as it came.
	v[fx.SF_PARAM_MIX] = 0
	fx.super_filter_impulse(&v, x, 48_000)
	testing.expectf(t, abs(gain_db(x, 8000)) < 0.01, "dry (%.2f dB)", gain_db(x, 8000))
	v[fx.SF_PARAM_MIX] = 1
	v[fx.SF_PARAM_TYPE] = f32(fx.Sf_Type.Vowel)
	_, anchor = fx.super_filter_impulse(&v, x, 48_000, 300)
	testing.expect_value(t, anchor, 1000)
}
