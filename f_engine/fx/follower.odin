package fx

import "core:math"

// What an envelope follower does.
Follower_Params :: struct {
	attack_ms:   f32,  // how fast it rises (0.1..100)
	release_ms:  f32,  // how fast it falls (1..3000)
	hold:        bool, // it stays at its peak while the level is above half of it (a drum's whole body, not just its click)
	sample_hold: bool, // its value is taken at each `division` and held (steps, in time)
	division:    int,  // the sample-and-hold's rate: an index into `TEMPO_RATIOS` (1..12; 10 is 1/16)
}

// A follower with the defaults: 1 ms attack, 250 ms release, no hold, no
// sample-and-hold (at 1/16 when turned on).
FOLLOWER_DEFAULTS :: Follower_Params{attack_ms = 1, release_ms = 250, division = 10}

// The range a follower's output spans: a level this far under full scale
// is 0, full scale is 1 (in dB, evenly: a quiet key still moves it).
FOLLOWER_RANGE_DB :: 48

// An envelope follower's state. Zero is ready to run. Fields are internal.
Follower :: struct {
	env:     f64, // the envelope (linear)
	fast:    f64, // the level, quick to fall (what Hold compares)
	held:    f32, // the sample-and-hold's value
	unit:    i64, // the division the last frame was in
	unit_ok: bool,
	phase:   f64, // the sample-and-hold's cycles while stopped
}

// [rt] Follows `key` (its sides together: the louder) into `out`
// (0..1: `FOLLOWER_RANGE_DB` under full scale to full scale; the frames
// as `key`'s), for clock `clk`. Allocates nothing.
follower_render :: proc "contextless" (f: ^Follower, p: ^Follower_Params, clk: Beat_Clock, key: [2][]f32, out: []f32, sample_rate: f64) #no_bounds_check {
	n := len(out)
	if n == 0 do return
	att := coefficient(f64(clamp(p.attack_ms, 0.01, 1000)), sample_rate)
	rel := coefficient(f64(clamp(p.release_ms, 0.1, 10_000)), sample_rate)
	fast := coefficient(10, sample_rate)
	ratios := TEMPO_RATIOS
	per_beat := f64(ratios[clamp(p.division, 1, 12)])
	if clk.started do f.unit_ok = false
	for k in 0 ..< n {
		x := f64(abs(key[0][k]))
		if len(key[1]) > k do x = max(x, f64(abs(key[1][k])))
		f.fast = x if x > f.fast else f.fast * fast
		if x > f.env {
			f.env = x + (f.env - x) * att
		} else if !(p.hold && f.fast >= 0.5 * f.env) {
			f.env = x + (f.env - x) * rel
		}
		if f.env < 1e-12 do f.env = 0 // (no denormals on the way down)
		v := follower_level(f.env)
		if p.sample_hold {
			// A new value at each division: on the timeline while playing, counted while stopped.
			u: i64
			if clk.playing {
				u = i64(math.floor((clk.beat + f64(k) * clk.beats_per_frame) * per_beat + 1e-9))
			} else {
				u = i64(math.floor(f.phase))
				f.phase += per_beat * clk.beats_per_frame
			}
			if !f.unit_ok || u != f.unit do f.held = v
			f.unit, f.unit_ok = u, true
			v = f.held
		}
		out[k] = v
	}
}

// [rt] A follower's output (0..1) for a linear level.
follower_level :: proc "contextless" (level: f64) -> f32 {
	if level <= 0 do return 0
	db := 20 * math.log10(level)
	return f32(clamp((db + FOLLOWER_RANGE_DB) / FOLLOWER_RANGE_DB, 0, 1))
}

// The one-pole coefficient that gets about 63 % of the way in `ms`.
@(private = "file")
coefficient :: #force_inline proc "contextless" (ms, sample_rate: f64) -> f64 {
	return math.exp(-1000 / (ms * sample_rate))
}
