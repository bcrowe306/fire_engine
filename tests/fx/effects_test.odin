package test_fx

import "core:math"
import "core:testing"

import "fire:fx"
import kit "fire:testkit"

// A stereo buffer of `n` samples (temporary allocator).
stereo :: proc(n: int) -> (l, r: []f32) {
	return make([]f32, n, context.temp_allocator), make([]f32, n, context.temp_allocator)
}

// An effect of each kind (made, rendered in blocks of `block`) over `l`, `r`.
Kind :: enum {Distortion, Delay, Chorus, Flanger, Phaser, Eq, Filter, Compressor, Reverb}

Rig :: struct {
	dist: fx.Distortion,
	delay: fx.Delay,
	chorus: fx.Chorus,
	flanger: fx.Flanger,
	phaser: fx.Phaser,
	eq: fx.Eq,
	filter: fx.Filter_Fx,
	comp: fx.Compressor,
	reverb: fx.Reverb,
	dp: fx.Distortion_Params,
	lp: fx.Delay_Params,
	cp: fx.Chorus_Params,
	fp: fx.Flanger_Params,
	pp: fx.Phaser_Params,
	ep: fx.Eq_Params,
	xp: fx.Filter_Fx_Params,
	op: fx.Compressor_Params,
	rp: fx.Reverb_Params,
}

rig :: proc() -> ^Rig {
	r := new(Rig)
	fx.delay_make(&r.delay, SR)
	fx.chorus_make(&r.chorus, SR)
	fx.flanger_make(&r.flanger, SR)
	fx.reverb_make(&r.reverb, SR)
	r.dp, r.lp, r.cp, r.fp, r.pp, r.ep, r.op, r.rp = fx.DISTORTION_DEFAULTS, fx.DELAY_DEFAULTS, fx.CHORUS_DEFAULTS, fx.FLANGER_DEFAULTS, fx.PHASER_DEFAULTS, fx.EQ_DEFAULTS, fx.COMPRESSOR_DEFAULTS, fx.REVERB_DEFAULTS
	r.xp = {filter = fx.FILTER_DEFAULTS}
	return r
}

rig_free :: proc(r: ^Rig) {
	fx.delay_destroy(&r.delay)
	fx.chorus_destroy(&r.chorus)
	fx.flanger_destroy(&r.flanger)
	fx.reverb_destroy(&r.reverb)
	free(r)
}

run :: proc(r: ^Rig, k: Kind, l, rr: []f32, block := 128) {
	for at := 0; at < len(l); at += block {
		n := min(block, len(l) - at)
		a, b := l[at:at + n], rr[at:at + n]
		switch k {
		case .Distortion: fx.distortion_render(&r.dist, &r.dp, a, b, SR)
		case .Delay:      fx.delay_render(&r.delay, &r.lp, a, b, SR)
		case .Chorus:     fx.chorus_render(&r.chorus, &r.cp, a, b, SR)
		case .Flanger:    fx.flanger_render(&r.flanger, &r.fp, a, b, SR)
		case .Phaser:     fx.phaser_render(&r.phaser, &r.pp, a, b, SR)
		case .Eq:         fx.eq_render(&r.eq, &r.ep, a, b, SR)
		case .Filter:     fx.filter_fx_render(&r.filter, &r.xp, a, b, SR)
		case .Compressor: fx.compressor_render(&r.comp, &r.op, a, b, SR)
		case .Reverb:     fx.reverb_render(&r.reverb, &r.rp, a, b, SR)
		}
	}
}

// Every effect, loud noise in, extreme settings: finite and bounded;
// and the same whatever the block size.
@(test)
every_effect_is_sound :: proc(t: ^testing.T) {
	for k in Kind {
		r := rig()
		r.dp.drive_db = 30
		r.lp.feedback = 1
		r.cp.feedback = 0.95
		r.fp.feedback = 1
		r.pp.feedback = 1
		r.rp.decay = 100
		r.rp.size = 1
		x := noise(24_000)
		l, rr := stereo(len(x))
		for v, i in x do l[i], rr[i] = v * 2, -v * 2
		run(r, k, l, rr)
		n1, _ := kit.count_non_finite(l)
		n2, _ := kit.count_non_finite(rr)
		testing.expectf(t, n1 == 0 && n2 == 0 && kit.peak(l) < 64 && kit.peak(rr) < 64, "%v: finite, bounded (%v)", k, kit.peak(l))
		rig_free(r)
		// Block invariance (default settings).
		a, b := rig(), rig()
		y := noise(9_000)
		l1, r1 := stereo(len(y))
		l2, r2 := stereo(len(y))
		copy(l1, y); copy(r1, y); copy(l2, y); copy(r2, y)
		run(a, k, l1, r1, 256)
		run(b, k, l2, r2, 256)
		same := 0.0
		for i in 0 ..< len(y) do same = max(same, f64(abs(l1[i] - l2[i])))
		testing.expectf(t, same == 0, "%v: twice alike (%v)", k, same)
		rig_free(a)
		rig_free(b)
	}
}

// Soft clipping holds a loud sine under 1 and adds odd harmonics; the
// bit crusher steps it.
@(test)
distortion_shapes :: proc(t: ^testing.T) {
	r := rig()
	defer rig_free(r)
	r.dp.drive_db = 12
	l, rr := stereo(24_000)
	for i in 0 ..< len(l) do l[i] = f32(0.8 * math.sin(math.TAU * 200 * f64(i) / SR))
	copy(rr, l)
	run(r, .Distortion, l, rr)
	testing.expectf(t, kit.peak(l) <= 1.0001, "under 1 (%v)", kit.peak(l))
	testing.expectf(t, kit.tone_amplitude(l[4800:], SR, 600) > 0.05, "a third harmonic (%v)", kit.tone_amplitude(l[4800:], SR, 600))
}

// A delay: an impulse comes back after its period, each time scaled by
// its feedback; ping-pong, it comes back on the other side.
@(test)
delay_echoes :: proc(t: ^testing.T) {
	r := rig()
	defer rig_free(r)
	r.lp = {style = .Stereo, wet = 1, feedback = 0.5, hz = {10, 10}, cutoff = 60, spread = 1} // every 100 ms
	l, rr := stereo(48_000)
	l[0], rr[0] = 1, 1
	run(r, .Delay, l, rr)
	e1, e2 := kit.peak(l[4700:4900]), kit.peak(l[9500:9700])
	testing.expectf(t, e1 > 0.3, "an echo at 100 ms (%v)", e1)
	testing.expectf(t, abs(e2 / e1 - 0.5) < 0.15, "the next at half (%v)", e2 / e1)
	p := rig()
	defer rig_free(p)
	p.lp = {style = .Ping_Pong, wet = 1, feedback = 0.6, hz = {10, 10}, cutoff = 60, spread = 1}
	l2, r2 := stereo(48_000)
	l2[0], r2[0] = 1, 1
	run(p, .Delay, l2, r2)
	testing.expectf(t, kit.peak(r2[4700:4900]) > 2 * kit.peak(l2[4700:4900]), "ping-pong: the first echo right (%v vs %v)", kit.peak(r2[4700:4900]), kit.peak(l2[4700:4900]))
	testing.expectf(t, kit.peak(l2[9500:9700]) > 2 * kit.peak(r2[9500:9700]), "then left")
}

// The EQ's low shelf lifts the lows by its gain; the compressor brings a
// loud signal down and a quiet one up.
@(test)
eq_and_compressor :: proc(t: ^testing.T) {
	r := rig()
	defer rig_free(r)
	r.ep.bands[0] = {mode = .Shelf, cutoff = 60, gain_db = 9, resonance = 0.3}
	l, rr := stereo(24_000)
	for i in 0 ..< len(l) do l[i] = f32(0.25 * math.sin(math.TAU * 60 * f64(i) / SR))
	copy(rr, l)
	run(r, .Eq, l, rr)
	db := 20 * math.log10(kit.tone_amplitude(l[12_000:], SR, 60) / 0.25)
	testing.expectf(t, abs(db - 9) < 2, "a 9 dB low shelf at 60 Hz (%v dB)", db)

	for level in ([]f32{0.9, 0.003}) {
		c := rig()
		c.op.band = {{upper_db = -20, lower_db = -40, upper_ratio = 1, lower_ratio = 1, gain_db = 0}, {upper_db = -20, lower_db = -40, upper_ratio = 1, lower_ratio = 1, gain_db = 0}, {upper_db = -20, lower_db = -40, upper_ratio = 1, lower_ratio = 1, gain_db = 0}}
		a, b := stereo(48_000)
		for i in 0 ..< len(a) do a[i] = level * f32(math.sin(math.TAU * 500 * f64(i) / SR))
		copy(b, a)
		run(c, .Compressor, a, b)
		out := kit.tone_amplitude(a[24_000:], SR, 500)
		if level > 0.5 do testing.expectf(t, out < f64(level) * 0.5, "loud: brought down (%v from %v)", out, level)
		else do testing.expectf(t, out > f64(level) * 2, "quiet: brought up (%v from %v)", out, level)
		rig_free(c)
	}
}

// The reverb's tail falls about 60 dB in its decay time, and its sides
// differ.
@(test)
reverb_decays :: proc(t: ^testing.T) {
	r := rig()
	defer rig_free(r)
	r.rp = fx.REVERB_DEFAULTS
	r.rp.wet = 1
	r.rp.decay = 1
	r.rp.high_gain_db = 0
	l, rr := stereo(96_000)
	for i in 0 ..< 480 do l[i], rr[i] = 0.5, 0.5 // a 10 ms burst
	run(r, .Reverb, l, rr)
	early := kit.rms(l[19_200:28_800]) // 0.4 .. 0.6 s, the tail built up
	late := kit.rms(l[67_200:76_800]) // a second later
	db := 20 * math.log10(late / early)
	testing.expectf(t, db < -40 && db > -80, "a second on: about 60 dB down (%v dB)", db)
	diff := 0.0
	for i in 4800 ..< 14_400 do diff += f64(abs(l[i] - rr[i]))
	testing.expectf(t, diff > 1, "its sides differ (%v)", diff)
}
