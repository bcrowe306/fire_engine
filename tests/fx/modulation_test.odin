package test_fx

import "core:math"
import "core:testing"

import "fire:fx"
import kit "fire:testkit"

// 120 BPM at 48 kHz: a beat is 24 000 frames.
BPF :: 2.0 / SR

// The clock for frames [at, at + n) of a transport playing from `from`.
clock_at :: proc(at: int, playing := true, from := 0.0, started := false) -> fx.Beat_Clock {
	return {playing = playing, beat = from + f64(at) * BPF, beats_per_frame = BPF, bar_beats = 4, started = started}
}

// Renders `frames` of LFO `p` in blocks of `block` (both sides).
run_lfo :: proc(p: fx.Lfo_Params, frames: int, block := 128, playing := true, from := 0.0) -> [2][]f32 {
	l := new(fx.Lfo, context.temp_allocator)
	pp := p
	out := [2][]f32{make([]f32, frames, context.temp_allocator), make([]f32, frames, context.temp_allocator)}
	for at := 0; at < frames; at += block {
		n := min(block, frames - at)
		fx.lfo_render(l, &pp, clock_at(at, playing, from, started = at == 0 && playing), {out[0][at:at + n], out[1][at:at + n]}, SR)
	}
	return out
}

// Renders follower `p` over `key` (both sides) in blocks of `block`.
run_follower :: proc(p: fx.Follower_Params, key: []f32, block := 128, playing := true) -> []f32 {
	f := new(fx.Follower, context.temp_allocator)
	pp := p
	out := make([]f32, len(key), context.temp_allocator)
	for at := 0; at < len(key); at += block {
		n := min(block, len(key) - at)
		fx.follower_render(f, &pp, clock_at(at, playing), {key[at:at + n], key[at:at + n]}, out[at:at + n], SR)
	}
	return out
}

max_diff :: proc(a, b: []f32) -> f32 {
	d: f32
	for v, i in a do d = max(d, abs(v - b[i]))
	return d
}

// Every wave, mode, stereo way and retrigger, morphed and smoothed: finite,
// in -1..1, and the same in any block size.
@(test)
the_lfo_is_finite_bounded_and_block_size_invariant :: proc(t: ^testing.T) {
	for wave in fx.Lfo_Wave do for mode in fx.Lfo_Mode do for rt in fx.Lfo_Retrigger {
		p := fx.LFO_DEFAULTS
		p.wave, p.mode, p.retrigger = wave, mode, rt
		p.hz, p.morph, p.smooth = 3.7, 0.3, 0.2
		p.stereo, p.spin_hz, p.offset_deg = .Spin, 0.7, 45
		ref := run_lfo(p, 60_000, block = 1)
		for side in 0 ..< 2 {
			n, _ := kit.count_non_finite(ref[side])
			testing.expectf(t, n == 0 && kit.peak(ref[side]) <= 1.0001, "%v %v %v: finite, in -1..1 (peak %v)", wave, mode, rt, kit.peak(ref[side]))
		}
		for block in ([]int{37, 128, 509}) {
			got := run_lfo(p, 60_000, block = block)
			d := max(max_diff(ref[0], got[0]), max_diff(ref[1], got[1]))
			testing.expectf(t, d < 1e-4, "%v %v %v in blocks of %d: as in blocks of 1 (off by %v)", wave, mode, rt, block, d)
		}
	}
}

// Rising zero crossings in `x`, as frames.
rises :: proc(x: []f32) -> [dynamic]int {
	r := make([dynamic]int, context.temp_allocator)
	for i in 1 ..< len(x) do if x[i - 1] < 0 && x[i] >= 0 do append(&r, i)
	return r
}

// In Hz a 2 Hz sine comes round every 24 000 frames; synced at 1/4 and
// 120 BPM, every beat (24 000); dotted, half as long again; in
// Sixteenths, 6 sixteenths are a beat and a half.
@(test)
the_lfo_runs_at_its_rate :: proc(t: ^testing.T) {
	period :: proc(p: fx.Lfo_Params) -> f64 {
		r := rises(run_lfo(p, 48_000 * 4)[0])
		if len(r) < 3 do return 0
		return f64(r[len(r) - 1] - r[0]) / f64(len(r) - 1)
	}
	p := fx.LFO_DEFAULTS
	p.mode, p.hz = .Hz, 2
	testing.expectf(t, abs(period(p) - 24_000) < 2, "2 Hz (%v)", period(p))
	p = fx.LFO_DEFAULTS // 1/4, synced
	testing.expectf(t, abs(period(p) - 24_000) < 2, "a beat (%v)", period(p))
	p.mode = .Dotted
	testing.expectf(t, abs(period(p) - 36_000) < 2, "a dotted beat (%v)", period(p))
	p.mode = .Triplet
	testing.expectf(t, abs(period(p) - 16_000) < 2, "a triplet beat (%v)", period(p))
	p.mode, p.sixteenths = .Sixteenths, 6
	testing.expectf(t, abs(period(p) - 36_000) < 2, "six sixteenths (%v)", period(p))
}

// Synced and playing, the LFO follows the timeline: started at beat 2.5,
// it is where one playing from the top is at beat 2.5.
@(test)
a_synced_lfo_is_on_the_timeline :: proc(t: ^testing.T) {
	p := fx.LFO_DEFAULTS
	p.division = 7 // 1/2: two beats a cycle
	from_top := run_lfo(p, 24_000 * 3)[0]
	jumped := run_lfo(p, 4800, from = 2.5)[0]
	d := max_diff(from_top[60_000:60_000 + 4800], jumped)
	testing.expectf(t, d < 1e-4, "the same place in its cycle (off by %v)", d)
}

// Phase 180°: the right side is the left upside down. Spin 2 Hz: they part
// and meet again every half second.
@(test)
the_lfo_sides_differ_by_phase_or_spin :: proc(t: ^testing.T) {
	p := fx.LFO_DEFAULTS
	p.stereo, p.phase_deg = .Phase, 180
	o := run_lfo(p, 48_000)
	worst: f32
	for v, i in o[0] do worst = max(worst, abs(v + o[1][i]))
	testing.expectf(t, worst < 1e-4, "opposite (off by %v)", worst)
	p.stereo, p.phase_deg, p.spin_hz = .Spin, 0, 2
	p.mode, p.hz = .Hz, 0.5
	o = run_lfo(p, 48_000)
	apart := abs(o[0][6000] - o[1][6000]) // a quarter second in: half a cycle apart
	met := abs(o[0][24_000] - o[1][24_000])  // half a second: together again
	testing.expectf(t, apart > 0.5 && met < 1e-3, "spinning (apart %v, met %v)", apart, met)
}

// In Hz, Retrigger Bar starts the cycle again at each bar (a sine from 0,
// rising); Play, at play.
@(test)
the_lfo_retriggers :: proc(t: ^testing.T) {
	p := fx.LFO_DEFAULTS
	p.mode, p.hz, p.retrigger = .Hz, 0.3, .Bar // (not a whole number of cycles a bar)
	o := run_lfo(p, 96_000 * 3)[0]
	for bar in 1 ..< 3 {
		at := 96_000 * bar
		testing.expectf(t, abs(o[at]) < 1e-3 && o[at + 2000] > 0, "bar %d: from the top (%v, then %v)", bar + 1, o[at], o[at + 2000])
	}
	p.retrigger = .Off
	o = run_lfo(p, 96_000 * 2)[0]
	testing.expectf(t, abs(o[96_000]) > 0.1, "off: it runs on through the bar (%v)", o[96_000])
}

// Square's morph is its pulse width; Random_Steps holds one value a cycle,
// and the cycles differ; smoothing rounds the square's edges.
@(test)
the_lfo_waves_take_their_morph :: proc(t: ^testing.T) {
	p := fx.LFO_DEFAULTS
	p.wave, p.morph = .Square, 0.25
	o := run_lfo(p, 96_000)[0]
	up := 0
	for v in o do if v > 0 do up += 1
	testing.expectf(t, abs(f64(up) / 96_000 - 0.25) < 0.01, "a quarter up (%v)", f64(up) / 96_000)
	p.wave, p.morph = .Random_Steps, 0
	o = run_lfo(p, 96_000)[0]
	steady := true
	for i in 1 ..< 24_000 do if o[i] != o[0] do steady = false
	testing.expectf(t, steady && o[24_000] != o[0] && o[48_000] != o[24_000], "a value a beat (%v %v %v)", o[0], o[24_000], o[48_000])
	p.wave, p.morph, p.smooth = .Square, 0.5, 0.5
	o = run_lfo(p, 96_000)[0]
	jump: f32
	for i in 1 ..< len(o) do jump = max(jump, abs(o[i] - o[i - 1]))
	testing.expectf(t, jump < 0.01, "no edges (largest step %v)", jump)
}

// The follower: finite, in 0..1, the same in any block size, with hold and
// sample-and-hold too.
@(test)
the_follower_is_finite_bounded_and_block_size_invariant :: proc(t: ^testing.T) {
	x := noise(60_000)
	for &v, i in x do v *= 4 * f32(math.abs(math.sin(f64(i) / 3000)))
	for hold in ([]bool{false, true}) do for sh in ([]bool{false, true}) {
		p := fx.FOLLOWER_DEFAULTS
		p.hold, p.sample_hold = hold, sh
		ref := run_follower(p, x, block = 1)
		n, _ := kit.count_non_finite(ref)
		lo, hi := f32(1), f32(0)
		for v in ref do lo, hi = min(lo, v), max(hi, v)
		testing.expectf(t, n == 0 && lo >= 0 && hi <= 1, "hold %v s&h %v: finite, in 0..1 (%v..%v)", hold, sh, lo, hi)
		for block in ([]int{37, 509}) {
			d := max_diff(ref, run_follower(p, x, block = block))
			testing.expectf(t, d < 1e-5, "hold %v s&h %v in blocks of %d (off by %v)", hold, sh, block, d)
		}
	}
}

// Silence is 0, full scale 1, 24 dB under it a half; the attack takes
// about its time to get most of the way; the release lets it fall.
@(test)
the_follower_follows_the_level :: proc(t: ^testing.T) {
	p := fx.FOLLOWER_DEFAULTS
	testing.expect_value(t, run_follower(p, make([]f32, 4800, context.temp_allocator))[4799], 0)
	full := sine(1000, 24_000, 1)
	testing.expectf(t, run_follower(p, full)[23_999] > 0.97, "full scale (%v)", run_follower(p, full)[23_999])
	quiet := sine(1000, 24_000, f32(math.pow(10, -24.0 / 20)))
	q := run_follower(p, quiet)[23_999]
	testing.expectf(t, abs(q - 0.5) < 0.03, "-24 dB: a half (%v)", q)
	// A step to DC 0.5 with a 10 ms attack: about 63 % of the way at 10 ms.
	p.attack_ms = 10
	step := make([]f32, 9600, context.temp_allocator)
	for &v in step do v = 0.5
	e := run_follower(p, step)[480]
	want := fx.follower_level(0.5 * (1 - math.exp(-1.0)))
	testing.expectf(t, abs(e - want) < 0.02, "the attack (%v, want %v)", e, want)
	// Then silence: it falls.
	p.attack_ms, p.release_ms = 1, 50
	tail := make([]f32, 24_000, context.temp_allocator)
	for i in 0 ..< 4800 do tail[i] = 0.5
	o := run_follower(p, tail)
	testing.expectf(t, o[4800 + 9600] < o[4799] - 0.2, "the release (%v from %v)", o[4800 + 9600], o[4799])
}

// A hit dying away: with Hold the envelope stays at its peak while the
// level is above half of it; without, it follows it down.
@(test)
the_follower_holds_a_hit :: proc(t: ^testing.T) {
	hit := make([]f32, 48_000, context.temp_allocator)
	for &v, i in hit do v = f32(math.exp(-f64(i) / 24_000)) // -6 dB at about 0.35 s
	p := fx.FOLLOWER_DEFAULTS
	p.release_ms = 20
	p.hold = true
	held := run_follower(p, hit)
	p.hold = false
	free := run_follower(p, hit)
	at := 12_000 // a quarter second: the level at 0.61 of its peak
	testing.expectf(t, held[at] > 0.99 && free[at] < held[at] - 0.05, "held at the peak (%v), else following (%v)", held[at], free[at])
	late := 30_000 // past half: Hold lets go
	testing.expectf(t, held[late] < 0.95, "let go under half (%v)", held[late])
}

// Sample-and-hold at 1/16 and 120 BPM: a rising key gives steps, one each
// 6000 frames, on the sixteenths.
@(test)
the_follower_samples_and_holds_in_time :: proc(t: ^testing.T) {
	ramp := make([]f32, 48_000, context.temp_allocator)
	for &v, i in ramp do v = f32(i) / 48_000
	p := fx.FOLLOWER_DEFAULTS
	p.sample_hold, p.attack_ms = true, 0.1
	o := run_follower(p, ramp)
	for k in 1 ..< 7 {
		at := 6000 * k
		testing.expectf(t, o[at - 1] == o[at - 6000 + 1] && o[at] > o[at - 1], "step %d: held, then a new value on the sixteenth", k)
	}
}
