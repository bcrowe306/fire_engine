package test_fx

import "core:mem/virtual"
import "core:strings"
import "core:testing"

import "fire:core"
import "fire:fx"
import kit "fire:testkit"

// Renders `input` through a fresh ProVerb with `events`.
pv_render :: proc(t: ^testing.T, input: kit.Audio_Buffer, events: []kit.Timed_Event, quality := fx.Proverb_Quality.Normal, block := 512) -> kit.Audio_Buffer {
	node, _, err := fx.proverb_create({quality = quality})
	testing.expect_value(t, err, core.Error.None)
	defer core.node_destroy(&node)
	cfg := kit.default_render_config()
	cfg.events = events
	cfg.blocks = kit.Fixed_Blocks{block}
	out, r := kit.render(&node, input, cfg, context.temp_allocator)
	defer kit.render_report_destroy(&r)
	kit.expect_clean_render(t, r)
	return out
}

// Every mode at every quality, everything turned up, on loud noise: a
// clean render (finite, no allocations on the audio thread); at a decay of
// 100 s with the modulation at its deepest, the tail stays bounded.
@(test)
every_proverb_is_clean_and_bounded :: proc(t: ^testing.T) {
	x := noise(9600)
	for &v in x do v *= 2
	for q in fx.Proverb_Quality do for mode in 0 ..< 12 {
		ev := sf_set(P(fx.PV_PARAM_MODE, f64(mode)), P(fx.PV_PARAM_MIX, 1), P(fx.PV_PARAM_EARLY_SIZE, 1), P(fx.PV_PARAM_EARLY_MOD_DEPTH, 1), P(fx.PV_PARAM_EARLY_SEND, 1),
			P(fx.PV_PARAM_LATE_MOD_DEPTH, 1), P(fx.PV_PARAM_LATE_MOD_RATE, 5), P(fx.PV_PARAM_BASS_MULT, 2), P(fx.PV_PARAM_HIGH_MULT, 1), P(fx.PV_PARAM_DECAY_S, 20))
		out := pv_render(t, sf_stereo(x), ev, q)
		bad, _ := kit.count_non_finite(out.channels[0])
		testing.expectf(t, bad == 0 && kit.peak(out.channels[0]) < 20, "%v mode %d: finite (peak %v)", q, mode, kit.peak(out.channels[0]))
	}
	burst := make([]f32, 48_000 * 12, context.temp_allocator)
	kit.white_noise(burst[:4800], 5, 0.5)
	long := pv_render(t, sf_stereo(burst), sf_set(P(fx.PV_PARAM_DECAY_S, 100), P(fx.PV_PARAM_BASS_MULT, 2), P(fx.PV_PARAM_HIGH_MULT, 1), P(fx.PV_PARAM_LATE_MOD_DEPTH, 1), P(fx.PV_PARAM_MIX, 1)))
	late := long.channels[0][48_000 * 10:]
	testing.expectf(t, kit.peak(late) < 2 && kit.peak(late) > 1e-4, "100 s: still ringing, bounded (%v)", kit.peak(late))
}

// The same output in any block size, with changes on the way, at every
// quality.
@(test)
the_proverb_is_block_size_invariant :: proc(t: ^testing.T) {
	input := kit.buffer_make(2, 48_000, SR, context.temp_allocator)
	for ch in 0 ..< 2 do kit.white_noise(input.channels[ch], u64(ch + 41), 0.5)
	for q in fx.Proverb_Quality {
		cfg := kit.default_render_config()
		ev := make([dynamic]kit.Timed_Event, context.temp_allocator)
		append(&ev, ..sf_set(P(fx.PV_PARAM_MIX, 0.5), P(fx.PV_PARAM_EARLY_MOD_DEPTH, 0.5), P(fx.PV_PARAM_EARLY_SEND, 0.3)))
		append(&ev, kit.Timed_Event{9_001, core.Param_Value{fx.PV_PARAM_LATE_SIZE, 0.9}})
		append(&ev, kit.Timed_Event{17_123, core.Param_Value{fx.PV_PARAM_MODE, 6}})
		append(&ev, kit.Timed_Event{25_555, core.Param_Value{fx.PV_PARAM_DECAY_S, 6}})
		append(&ev, kit.Timed_Event{30_001, core.Param_Value{fx.PV_PARAM_PREDELAY_MS, 80}})
		append(&ev, kit.Timed_Event{36_000, core.Param_Value{fx.PV_PARAM_HIGH_CUT_HZ, 3000}})
		cfg.events = ev[:]
		patterns := kit.standard_block_patterns(cfg.max_block)
		factory := kit.Node_Factory{user = rawptr(uintptr(q)), create = proc(u: rawptr) -> core.Node {
			n, _, _ := fx.proverb_create({quality = fx.Proverb_Quality(uintptr(u))})
			return n
		}}
		kit.expect_block_invariant(t, factory, input, cfg, patterns[:], 1e-5, "proverb")
	}
}

// Mix 0 is the input, bit for bit; Mix 1 has none of it (silence until
// the predelay is past); Predelay holds the first sound back as long as it
// says.
@(test)
proverb_mix_and_predelay :: proc(t: ^testing.T) {
	x := noise(24_000)
	dry := pv_render(t, sf_stereo(x), sf_set(P(fx.PV_PARAM_MIX, 0)))
	same := true
	for v, i in x do if dry.channels[0][i] != v do same = false
	testing.expect(t, same, "Mix 0: the input")
	imp := make([]f32, 24_000, context.temp_allocator)
	imp[0] = 1
	wet := pv_render(t, sf_stereo(imp), sf_set(P(fx.PV_PARAM_MIX, 1), P(fx.PV_PARAM_PREDELAY_MS, 100)))
	first := -1
	for v, i in wet.channels[0] do if abs(v) > 1e-6 {
		first = i
		break
	}
	testing.expectf(t, first >= 4800 && first < 4800 + 480, "the first sound at %d frames (predelay 4800)", first)
}

// What `proverb_rt60` says is what the node does: at 125 Hz, 1 kHz and
// 8 kHz, for a few settings.
@(test)
the_proverb_rt60_is_its_decay :: proc(t: ^testing.T) {
	Case :: struct {decay, bass, high: f64}
	for c in ([]Case{{2, 1, 0.5}, {4, 2, 0.3}, {1, 0.5, 1}}) {
		v := fx.proverb_defaults()
		v[fx.PV_PARAM_DECAY_S], v[fx.PV_PARAM_BASS_MULT], v[fx.PV_PARAM_HIGH_MULT] = f32(c.decay), f32(c.bass), f32(c.high)
		v[fx.PV_PARAM_MIX], v[fx.PV_PARAM_DEPTH] = 1, 1
		m, _ := pv_measure(v, "impulse", c.decay * 3 + 1)
		bands := [3]int{0, 3, 5}
		for hz, k in ([3]f64{125, 1000, 4000}) {
			want := fx.proverb_rt60(&v, hz, 48_000)
			got := m.rt60[bands[k]]
			testing.expectf(t, abs(got - want) / want < 0.15, "%v at %v Hz: says %.2f s, does %.2f", c, hz, want, got)
		}
	}
}

// ProVerb against the reference's measurements (`tests/proverb/
// reference.json`), for the same settings, measured the same way: the
// decay in each band, the late tail's first arrival and level, the sides'
// correlation, the modulation's spread.
@(test)
proverb_matches_the_reference :: proc(t: ^testing.T) {
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	ref := pv_reference(&arena)
	testing.expect(t, len(ref) > 50, "the reference, read")
	skip :: proc(name: string) -> bool {
		return strings.has_suffix(name, "_early") || strings.has_prefix(name, "early") || name == "burst" || name == "mix_0.5"
	}
	spreads := make([dynamic]f64, virtual.arena_allocator(&arena))
	ref_spreads := make([dynamic]f64, virtual.arena_allocator(&arena))
	for r in ref {
		if skip(r.name) do continue
		m, _ := pv_measure(pv_settings(r.params), r.signal, 8 if r.signal == "impulse" else 4)
		defer free_all(context.temp_allocator) // (its renders: megabytes a job)
		if r.signal != "impulse" {
			if strings.has_prefix(r.name, "moddepth") {
				append(&spreads, m.spread_hz)
				append(&ref_spreads, r.spread_hz)
			}
			continue
		}
		within :: proc(a, b, tol: f64) -> bool { return abs(a - b) <= tol * b }
		testing.expectf(t, within(m.rt60_wide, r.rt60_wide, 0.12), "%s: RT60 %.2f s, the reference %.2f", r.name, m.rt60_wide, r.rt60_wide)
		testing.expectf(t, within(m.rt60[0], r.rt60[0], 0.2) && within(m.rt60[3], r.rt60[3], 0.12) && within(m.rt60[6], r.rt60[6], 0.25),
			"%s: 125 Hz %.2f/%.2f, 1 kHz %.2f/%.2f, 8 kHz %.2f/%.2f", r.name, m.rt60[0], r.rt60[0], m.rt60[3], r.rt60[3], m.rt60[6], r.rt60[6])
		if r.first_ms > 10 && !(strings.has_prefix(r.name, "mode") && !strings.has_suffix(r.name, "_late")) do testing.expectf(t, abs(m.first_ms - r.first_ms) <= 0.15 * r.first_ms + 3, "%s: first at %.1f ms, the reference %.1f", r.name, m.first_ms, r.first_ms)
		if strings.has_suffix(r.name, "_late") do testing.expectf(t, abs(m.level_db - r.level_db) < 3.5, "%s: %.1f dB, the reference %.1f", r.name, m.level_db, r.level_db)
		if abs(r.correlation) < 0.1 do testing.expectf(t, abs(m.correlation) < 0.25, "%s: correlation %.2f, the reference %.2f", r.name, m.correlation, r.correlation)
	}
	// Full modulation spreads a tone more than less does, as far as the
	// reference's (within ×2.5). (Unmodulated, its tail is a little wider
	// than the reference's already.)
	if len(spreads) == 3 {
		testing.expectf(t, spreads[2] > spreads[0] && spreads[2] > spreads[1] && spreads[2] < 2.5 * ref_spreads[2] && spreads[2] > ref_spreads[2] / 2.5,
			"the spread at depth 0, 0.5, 1: %v (the reference %v)", spreads[:], ref_spreads[:])
	}
}

// Eco and High against the reference's modes: the decay within 15 %.
@(test)
proverb_qualities_match_the_reference :: proc(t: ^testing.T) {
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	ref := pv_reference(&arena)
	for r in ref {
		if !strings.has_prefix(r.name, "mode") || !strings.has_suffix(r.name, "_late") do continue
		for q in ([]fx.Proverb_Quality{.Eco, .High}) {
			m, _ := pv_measure(pv_settings(r.params), r.signal, 8, q)
			defer free_all(context.temp_allocator)
			testing.expectf(t, abs(m.rt60_wide - r.rt60_wide) <= 0.15 * r.rt60_wide, "%s %v: RT60 %.2f s, the reference %.2f", r.name, q, m.rt60_wide, r.rt60_wide)
		}
	}
}
