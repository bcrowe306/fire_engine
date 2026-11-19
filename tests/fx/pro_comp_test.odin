package test_fx

import "core:math"
import "core:testing"

import "fire:core"
import "fire:fx"
import kit "fire:testkit"

// Renders `input` (2 channels, or 4: the last two the key) through a fresh
// ProComp with `events`; its readout after the last block into `last`.
pc_render :: proc(t: ^testing.T, input: kit.Audio_Buffer, events: []kit.Timed_Event, lookahead := fx.Pro_Comp_Lookahead.Off, block := 512, last: ^fx.Pro_Comp_Readout = nil, written: ^u64 = nil) -> kit.Audio_Buffer {
	node, pc := fx.pro_comp_create({lookahead = lookahead})
	defer core.node_destroy(&node)
	cfg := kit.default_render_config()
	cfg.events = events
	cfg.blocks = kit.Fixed_Blocks{block}
	out, r := kit.render(&node, input, cfg, context.temp_allocator)
	defer kit.render_report_destroy(&r)
	kit.expect_clean_render(t, r)
	if last != nil do last^ = fx.pro_comp_readout(pc)
	if written != nil do written^ = fx.pro_comp_history(pc, nil)
	return out
}

// A constant level `a` for `frames`, then `b` from `at` (on both sides).
pc_step :: proc(frames, at: int, a, b: f32) -> kit.Audio_Buffer {
	x := make([]f32, frames, context.temp_allocator)
	for &v, i in x do v = a if i < at else b
	return sf_stereo(x)
}

pc_db :: proc(x: f32) -> f64 { return 20 * math.log10(max(f64(abs(x)), 1e-9)) }

// Every mode at every lookahead, keyed and not, the key EQ on, everything
// turned up, on loud noise: a clean render (finite, no allocations on the
// audio thread).
@(test)
every_pro_comp_is_clean :: proc(t: ^testing.T) {
	in4 := kit.buffer_make(4, 9600, SR, context.temp_allocator)
	for ch in 0 ..< 4 do kit.white_noise(in4.channels[ch], u64(ch + 11), 2)
	for la in fx.Pro_Comp_Lookahead do for mode in fx.Pro_Comp_Mode do for keyed in 0 ..< 2 do for env in 0 ..< 2 {
		ev := sf_set(P(fx.PC_PARAM_MODE, f64(mode)), P(fx.PC_PARAM_KEYED, f64(keyed)), P(fx.PC_PARAM_ENV_LOG, f64(env)), P(fx.PC_PARAM_RATIO, 100),
			P(fx.PC_PARAM_ATTACK_MS, 0.01), P(fx.PC_PARAM_AUTO, 1), P(fx.PC_PARAM_EQ_ON, 1), P(fx.PC_PARAM_EQ_TYPE, 4), P(fx.PC_PARAM_EQ_GAIN_DB, 15),
			P(fx.PC_PARAM_MAKEUP, 1), P(fx.PC_PARAM_OUTPUT_DB, 12), P(fx.PC_PARAM_KEY_GAIN_DB, 24), P(fx.PC_PARAM_KNEE_DB, 18))
		out := pc_render(t, in4, ev, la)
		bad, _ := kit.count_non_finite(out.channels[0])
		testing.expectf(t, bad == 0, "%v %v keyed %d env %d: finite", la, mode, keyed, env)
	}
}

// The same output in any block size, with changes on the way, keyed and
// looking ahead.
@(test)
the_pro_comp_is_block_size_invariant :: proc(t: ^testing.T) {
	input := kit.buffer_make(4, 48_000, SR, context.temp_allocator)
	for ch in 0 ..< 4 do kit.white_noise(input.channels[ch], u64(ch + 21), 0.5)
	for la in fx.Pro_Comp_Lookahead {
		cfg := kit.default_render_config()
		ev := make([dynamic]kit.Timed_Event, context.temp_allocator)
		append(&ev, ..sf_set(P(fx.PC_PARAM_THRESHOLD_DB, -24), P(fx.PC_PARAM_RATIO, 6), P(fx.PC_PARAM_KEYED, 1), P(fx.PC_PARAM_KEY_MIX, 0.5), P(fx.PC_PARAM_EQ_ON, 1)))
		append(&ev, kit.Timed_Event{9_001, core.Param_Value{fx.PC_PARAM_MODE, 1}})
		append(&ev, kit.Timed_Event{17_123, core.Param_Value{fx.PC_PARAM_ATTACK_MS, 0.3}})
		append(&ev, kit.Timed_Event{20_000, core.Param_Value{fx.PC_PARAM_ENV_LOG, 0}})
		append(&ev, kit.Timed_Event{25_555, core.Param_Value{fx.PC_PARAM_AUTO, 1}})
		append(&ev, kit.Timed_Event{30_001, core.Param_Value{fx.PC_PARAM_MIX, 0.4}})
		append(&ev, kit.Timed_Event{36_000, core.Param_Value{fx.PC_PARAM_EQ_HZ, 5000}})
		cfg.events = ev[:]
		patterns := kit.standard_block_patterns(cfg.max_block)
		factory := kit.Node_Factory{user = rawptr(uintptr(la)), create = proc(u: rawptr) -> core.Node {
			n, _ := fx.pro_comp_create({lookahead = fx.Pro_Comp_Lookahead(uintptr(u))})
			return n
		}}
		kit.expect_block_invariant(t, factory, input, cfg, patterns[:], 1e-6, "pro_comp")
	}
}

// A steady level comes out where the curve says, at several thresholds,
// ratios and knees (the peak detector, a slow release: little ripple).
@(test)
the_pro_comp_follows_its_curve :: proc(t: ^testing.T) {
	Case :: struct {th, ratio, knee: f64}
	for c in ([]Case{{-20, 4, 6}, {-30, 2, 0}, {-12, 10, 12}, {-24, 100, 0}}) {
		for level := -40.0; level <= 0; level += 8 {
			a := f32(math.pow(10, level / 20))
			ev := sf_set(P(fx.PC_PARAM_THRESHOLD_DB, c.th), P(fx.PC_PARAM_RATIO, c.ratio), P(fx.PC_PARAM_KNEE_DB, c.knee), P(fx.PC_PARAM_ATTACK_MS, 1), P(fx.PC_PARAM_RELEASE_MS, 300))
			out := pc_render(t, pc_step(24_000, 0, a, a), ev)
			v := fx.pro_comp_defaults()
			v[fx.PC_PARAM_THRESHOLD_DB], v[fx.PC_PARAM_RATIO], v[fx.PC_PARAM_KNEE_DB] = f32(c.th), f32(c.ratio), f32(c.knee)
			want := f64(fx.pro_comp_curve(&v, f32(level)))
			got := pc_db(out.channels[0][23_999])
			testing.expectf(t, abs(got - want) < 0.3, "%v at %v dB: %.2f dB out, the curve %.2f", c, level, got, want)
		}
	}
}

// Expand turns a level under its threshold down by its ratio; at ∞, to the
// floor (a gate). Above, it leaves it.
@(test)
pro_comp_expands :: proc(t: ^testing.T) {
	at :: proc(t: ^testing.T, level, ratio: f64) -> f64 {
		a := f32(math.pow(10, level / 20))
		ev := sf_set(P(fx.PC_PARAM_MODE, 2), P(fx.PC_PARAM_THRESHOLD_DB, -20), P(fx.PC_PARAM_RATIO, ratio), P(fx.PC_PARAM_KNEE_DB, 0), P(fx.PC_PARAM_ATTACK_MS, 1))
		return pc_db(pc_render(t, pc_step(24_000, 0, a, a), ev).channels[0][23_999])
	}
	below, above, gate := at(t, -30, 2), at(t, -10, 2), at(t, -30, 100)
	testing.expectf(t, abs(below + 40) < 0.3 && abs(above + 10) < 0.1 && gate < -100, "−30 → %.1f (−40), −10 → %.1f, gated → %.1f", below, above, gate)
}

// Attack and release: after a step up the reduction goes 63 % of its way in
// about the attack; after a step down it comes back as long as the
// release says (Log). Auto lets go faster after a click than after a held
// level.
@(test)
pro_comp_attack_release_and_auto :: proc(t: ^testing.T) {
	ev := sf_set(P(fx.PC_PARAM_THRESHOLD_DB, -20), P(fx.PC_PARAM_RATIO, 100), P(fx.PC_PARAM_KNEE_DB, 0), P(fx.PC_PARAM_ATTACK_MS, 10), P(fx.PC_PARAM_RELEASE_MS, 100))
	x := pc_step(48_000, 4800, 0.01, 1)
	for i in 28_800 ..< 48_000 do x.channels[0][i], x.channels[1][i] = 0.01, 0.01
	out := pc_render(t, x, ev)
	attack := pc_db(out.channels[0][4800 + 480]) // (−20 dB to go: 63 % of it at 10 ms)
	release := pc_db(out.channels[0][28_800 + 4800]) - pc_db(0.01) // (from −20: 37 % left at 100 ms)
	testing.expectf(t, abs(attack + 12.6) < 1.5 && abs(release + 7.4) < 1.5, "attack: %.1f dB at 10 ms (−12.6); release: %.1f dB at 100 ms (−7.4)", attack, release)
	// Auto: a 5 ms click and a held second, 300 ms after each ends.
	auto := sf_set(P(fx.PC_PARAM_THRESHOLD_DB, -20), P(fx.PC_PARAM_RATIO, 100), P(fx.PC_PARAM_ATTACK_MS, 0.5), P(fx.PC_PARAM_AUTO, 1))
	after :: proc(t: ^testing.T, ev: []kit.Timed_Event, held: int) -> f64 {
		x := pc_step(4800 + held + 24_000, 4800, 0.01, 1)
		for i in 4800 + held ..< len(x.channels[0]) do x.channels[0][i], x.channels[1][i] = 0.01, 0.01
		out := pc_render(t, x, ev)
		return pc_db(out.channels[0][4800 + held + 14_400]) - pc_db(0.01)
	}
	click, held := after(t, auto, 240), after(t, auto, 48_000)
	testing.expectf(t, click > held + 3, "300 ms after: a click %.1f dB, a held second %.1f dB", click, held)
}

// Looking ahead, the output is as late as it says, and a step is already
// turned down when it arrives.
@(test)
pro_comp_looks_ahead :: proc(t: ^testing.T) {
	LATE := [fx.Pro_Comp_Lookahead]int{.Off = 0, .Ms_1 = 48, .Ms_10 = 480}
	for la in fx.Pro_Comp_Lookahead {
		node, _ := fx.pro_comp_create({lookahead = la})
		kit_cfg := kit.default_render_config()
		_, r := kit.render(&node, sf_stereo(noise(256)), kit_cfg, context.temp_allocator) // (prepared: its latency known)
		kit.render_report_destroy(&r)
		late := core.node_latency(&node)
		core.node_destroy(&node)
		x := noise(24_000)
		for &v in x do v *= 0.01
		out := pc_render(t, sf_stereo(x), nil, la)
		got := kit.estimate_latency(x, out.channels[0], 1000)
		testing.expectf(t, late == LATE[la] && got == late, "%v: reports %d, is %d", la, late, got)
	}
	ev := sf_set(P(fx.PC_PARAM_THRESHOLD_DB, -20), P(fx.PC_PARAM_RATIO, 100), P(fx.PC_PARAM_KNEE_DB, 0), P(fx.PC_PARAM_ATTACK_MS, 1))
	out := pc_render(t, pc_step(9600, 4800, 0.01, 1), ev, .Ms_10)
	testing.expectf(t, pc_db(out.channels[0][4800 + 480]) < -12, "the step, as it comes out: %.1f dB", pc_db(out.channels[0][4800 + 480]))
}

// Makeup brings a full-scale level back to about where it went in; Dry/Wet
// 0 is the input (as late as the lookahead), bit for bit; the readout's
// reduction is the gain the output shows.
@(test)
pro_comp_makeup_dry_and_readout :: proc(t: ^testing.T) {
	ev := sf_set(P(fx.PC_PARAM_THRESHOLD_DB, -24), P(fx.PC_PARAM_RATIO, 4), P(fx.PC_PARAM_KNEE_DB, 0), P(fx.PC_PARAM_MAKEUP, 1))
	out := pc_render(t, pc_step(24_000, 0, 1, 1), ev)
	testing.expectf(t, abs(pc_db(out.channels[0][23_999])) < 0.3, "made up: %.2f dB", pc_db(out.channels[0][23_999]))
	x := noise(24_000)
	dry := pc_render(t, sf_stereo(x), sf_set(P(fx.PC_PARAM_MIX, 0), P(fx.PC_PARAM_RATIO, 100), P(fx.PC_PARAM_THRESHOLD_DB, -40)), .Ms_1)
	same := true
	for i in 48 ..< len(x) do if dry.channels[0][i] != x[i - 48] do same = false
	testing.expect(t, same, "dry: the input, 48 frames late")
	r: fx.Pro_Comp_Readout
	written: u64
	o := pc_render(t, pc_step(25_600, 0, 0.5, 0.5), sf_set(P(fx.PC_PARAM_THRESHOLD_DB, -20), P(fx.PC_PARAM_RATIO, 3)), last = &r, written = &written)
	shown := pc_db(o.channels[0][25_599]) - pc_db(0.5)
	testing.expectf(t, abs(f64(r.gr_db) - shown) < 0.05 && r.in_peak > 0.49 && r.gr_db < -5, "the readout's reduction %.2f dB, the output's %.2f", r.gr_db, shown)
	testing.expect_value(t, written, u64(100))
}

// Keyed, the key's level drives it, not the input's (unless Key Mix is 0);
// the key's EQ makes it hear one band: a band-pass at 6 kHz presses a 6 kHz
// tone harder than a 100 Hz one as loud.
@(test)
pro_comp_keys_and_eq :: proc(t: ^testing.T) {
	in4 := kit.buffer_make(4, 24_000, SR, context.temp_allocator)
	for i in 0 ..< 24_000 {
		in4.channels[0][i], in4.channels[1][i] = 0.01, 0.01 // (quiet: under the threshold)
		in4.channels[2][i], in4.channels[3][i] = 1, 1 // (the key: loud)
	}
	base := sf_set(P(fx.PC_PARAM_THRESHOLD_DB, -20), P(fx.PC_PARAM_RATIO, 100), P(fx.PC_PARAM_KNEE_DB, 0))
	keyed := make([dynamic]kit.Timed_Event, context.temp_allocator)
	append(&keyed, ..base)
	append(&keyed, ..sf_set(P(fx.PC_PARAM_KEYED, 1)))
	pressed := pc_db(pc_render(t, in4, keyed[:]).channels[0][23_999]) - pc_db(0.01)
	plain := pc_db(pc_render(t, in4, base).channels[0][23_999]) - pc_db(0.01)
	append(&keyed, ..sf_set(P(fx.PC_PARAM_KEY_MIX, 0)))
	own := pc_db(pc_render(t, in4, keyed[:]).channels[0][23_999]) - pc_db(0.01)
	testing.expectf(t, pressed < -15 && abs(plain) < 0.1 && abs(own) < 0.1, "keyed: %.1f dB; not keyed: %.1f; key mix 0: %.1f", pressed, plain, own)
	// The EQ, on its own input.
	eq := sf_set(P(fx.PC_PARAM_THRESHOLD_DB, -30), P(fx.PC_PARAM_RATIO, 4), P(fx.PC_PARAM_EQ_ON, 1), P(fx.PC_PARAM_EQ_TYPE, 1), P(fx.PC_PARAM_EQ_HZ, 6000), P(fx.PC_PARAM_EQ_Q, 2), P(fx.PC_PARAM_RELEASE_MS, 300))
	at :: proc(t: ^testing.T, hz: f64, ev: []kit.Timed_Event) -> f64 {
		out := pc_render(t, sf_stereo(sine(hz, 24_000, 0.3)), ev)
		return 20 * math.log10(kit.tone_amplitude(out.channels[0][12_000:], SR, hz) / 0.3)
	}
	hi, lo := at(t, 6000, eq), at(t, 100, eq)
	testing.expectf(t, hi < lo - 6, "the key's EQ: 6 kHz %.1f dB, 100 Hz %.1f dB", hi, lo)
}

// Makeup raises only the compressed part: crushed and made up, a third wet,
// the dry under it stays as it was (no more than full scale). Expand opens
// by its attack: a tone above its threshold comes through whole, zero
// crossings and all.
@(test)
pro_comp_makeup_is_wet_and_expand_opens :: proc(t: ^testing.T) {
	ev := sf_set(P(fx.PC_PARAM_THRESHOLD_DB, -36), P(fx.PC_PARAM_RATIO, 100), P(fx.PC_PARAM_KNEE_DB, 0), P(fx.PC_PARAM_MAKEUP, 1), P(fx.PC_PARAM_MIX, 0.35))
	out := pc_render(t, pc_step(24_000, 0, 0.5, 0.5), ev)
	y := out.channels[0][23_999]
	testing.expectf(t, y > 0.3 && y < 0.7, "parallel, made up: %v (the dry 0.325, the wet about 0.35 more)", y)
	ex := sf_set(P(fx.PC_PARAM_MODE, 2), P(fx.PC_PARAM_THRESHOLD_DB, -28), P(fx.PC_PARAM_RATIO, 3), P(fx.PC_PARAM_ATTACK_MS, 0.5), P(fx.PC_PARAM_RELEASE_MS, 60))
	o := pc_render(t, sf_stereo(sine(200, 24_000, 0.5)), ex)
	g := 20 * math.log10(kit.tone_amplitude(o.channels[0][12_000:], SR, 200) / 0.5)
	testing.expectf(t, abs(g) < 1, "a tone above Expand's threshold: %.2f dB", g)
}
