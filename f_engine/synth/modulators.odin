package synth

import "fire:fx"

import "core:math"

// The synth's modulators: envelopes and LFOs (each voice has its own),
// and the shapes LFOs draw.

// --- Envelopes -----------------------------------------------------------------------------------

// An envelope's settings: times in seconds, sustain 0..1, and each
// curved segment's power (0 straight). A negative decay or release power
// drops fast, then slows (as a natural decay does); a positive attack
// power rises fast, then slows.
Env_Params :: struct {
	delay, attack, hold, decay, release: f32,
	sustain:                             f32,
	attack_power, decay_power, release_power: f32,
}

// Default envelope settings (an amp envelope's).
ENV_DEFAULTS :: Env_Params{attack = 0.0005, decay = 1, sustain = 1, release = 0.09, decay_power = -2, release_power = -2}

// Where an envelope is.
Env_Stage :: enum u8 {Done, Delay, Attack, Hold, Decay, Release, Kill}

// Seconds a killed envelope (a stolen voice) takes to fall to nothing.
ENV_KILL_SECONDS :: 0.05

// An envelope of one voice. Zero is done (silent).
Env_State :: struct {
	stage: Env_Stage,
	pos:   f32, // 0..1 through the stage
	value: f32,
	start: f32, // the level the stage began from (attack, release, kill)
}

// [rt] A note starts it: from where it is (so a retrigger doesn't click),
// through the delay if it has one.
env_gate_on :: proc "contextless" (e: ^Env_State, p: ^Env_Params) {
	e.start = e.value
	e.pos = 0
	e.stage = .Delay if p.delay > 0 else .Attack
}

// [rt] The note ends: it releases from where it is.
env_gate_off :: proc "contextless" (e: ^Env_State) {
	if e.stage == .Done || e.stage == .Release || e.stage == .Kill do return
	e.start = e.value
	e.pos = 0
	e.stage = .Release
}

// [rt] The voice is stolen: a quick fall to nothing.
env_kill :: proc "contextless" (e: ^Env_State) {
	if e.stage == .Done do return
	e.start = e.value
	e.pos = 0
	e.stage = .Kill
}

// [rt] Moves it on by `dt` seconds and returns its value then.
env_step :: proc "contextless" (e: ^Env_State, p: ^Env_Params, dt: f32) -> f32 {
	left := dt
	for left > 0 && e.stage != .Done {
		length: f32
		switch e.stage {
		case .Done:    return 0
		case .Delay:   length = p.delay
		case .Attack:  length = p.attack
		case .Hold:    length = p.hold
		case .Decay:   length = p.decay
		case .Release: length = p.release
		case .Kill:    length = ENV_KILL_SECONDS
		}
		if e.stage == .Decay && e.pos >= 1 do break // sustaining
		need := (1 - e.pos) * max(length, 1e-9)
		if left < need {
			e.pos += left / max(length, 1e-9)
			left = 0
		} else {
			left -= need
			e.pos = 1
			env_value(e, p)
			// On to the next stage.
			#partial switch e.stage {
			case .Delay:
				e.start = 0
				e.stage, e.pos = .Attack, 0
			case .Attack:
				e.stage, e.pos = .Hold if p.hold > 0 else .Decay, 0
			case .Hold:
				e.stage, e.pos = .Decay, 0
			case .Decay:
				e.pos = 1
				left = 0 // holds at the sustain
			case .Release, .Kill:
				e.stage, e.pos, e.value = .Done, 0, 0
				return 0
			}
		}
	}
	env_value(e, p)
	return e.value
}

// [rt] Sets `e.value` from its stage and position.
@(private)
env_value :: proc "contextless" (e: ^Env_State, p: ^Env_Params) {
	switch e.stage {
	case .Done, .Delay: e.value = 0 if e.stage == .Done else e.start
	case .Attack:       e.value = e.start + (1 - e.start) * power_scale(e.pos, -p.attack_power)
	case .Hold:         e.value = 1
	case .Decay:        e.value = 1 - (1 - clamp(p.sustain, 0, 1)) * power_scale(e.pos, p.decay_power)
	case .Release:      e.value = e.start * (1 - power_scale(e.pos, p.release_power))
	case .Kill:         e.value = e.start * (1 - e.pos)
	}
	e.value = clamp(e.value, 0, 1)
}

// [rt] Renders it a sample at a time into `out` (for an amp envelope).
env_render :: proc "contextless" (e: ^Env_State, p: ^Env_Params, out: []f32, sample_rate: f64) {
	dt := f32(1 / sample_rate)
	for &v in out do v = env_step(e, p, dt)
}

// [rt] Whether it has finished (released to nothing).
env_done :: #force_inline proc "contextless" (e: ^Env_State) -> bool {
	return e.stage == .Done
}

// --- LFO shapes ----------------------------------------------------------------------------------

// The most points an LFO shape has.
LFO_MAX_POINTS :: 64

// Values in a rendered LFO shape (one cycle).
LFO_RESOLUTION :: 2048

// An LFO's shape: points (x 0..1 across the cycle, y 0..1 its value)
// joined by segments, each with a power (its curve), smoothed with an
// S-curve if `smooth`. Render it with `lfo_shape_render` into a table.
Lfo_Shape :: struct {
	points: [LFO_MAX_POINTS][2]f32,
	powers: [LFO_MAX_POINTS]f32, // the segment after each point
	count:  int,
	smooth: bool,
}

// Shapes an LFO can start from.
Lfo_Preset :: enum u8 {Triangle, Sine, Saw_Up, Saw_Down, Square, Ramp_Envelope}

// The shape of preset `which`.
lfo_preset :: proc "contextless" (which: Lfo_Preset) -> (s: Lfo_Shape) {
	set :: proc "contextless" (s: ^Lfo_Shape, pts: [][2]f32) {
		for pt, i in pts do s.points[i] = pt
		s.count = len(pts)
	}
	switch which {
	case .Triangle: set(&s, {{0, 0}, {0.5, 1}, {1, 0}})
	case .Sine:     set(&s, {{0, 0.5}, {0.25, 1}, {0.75, 0}, {1, 0.5}}); s.smooth = true
	case .Saw_Up:   set(&s, {{0, 0}, {1, 1}})
	case .Saw_Down: set(&s, {{0, 1}, {1, 0}})
	case .Square:   set(&s, {{0, 1}, {0.5, 1}, {0.5, 0}, {1, 0}})
	case .Ramp_Envelope: set(&s, {{0, 1}, {1, 0}}); s.powers[0] = -4 // (falls fast, then slowly)
	}
	return
}

// [rt] Renders `s` into `table` (`LFO_RESOLUTION` values, one cycle).
lfo_shape_render :: proc "contextless" (s: ^Lfo_Shape, table: []f32) #no_bounds_check {
	n := len(table)
	if s.count == 0 {
		for &v in table do v = 0
		return
	}
	k := 0
	for i in 0 ..< n {
		x := f32(i) / f32(n - 1)
		for k + 1 < s.count && s.points[k + 1][0] < x do k += 1
		if k + 1 >= s.count {
			table[i] = s.points[s.count - 1][1]
			continue
		}
		a, b := s.points[k], s.points[k + 1]
		t: f32 = 1
		if b[0] > a[0] do t = (x - a[0]) / (b[0] - a[0])
		if s.smooth do t = 0.5 * math.sin((t - 0.5) * math.PI) + 0.5
		t = clamp(power_scale(t, s.powers[k]), 0, 1)
		table[i] = a[1] + (b[1] - a[1]) * t
	}
}

// [rt] The value of a rendered shape at `phase` (0..1), interpolated.
lfo_table_at :: #force_inline proc "contextless" (table: []f32, phase: f32) -> f32 #no_bounds_check {
	n := len(table)
	x := clamp(phase, 0, 1) * f32(n - 1)
	i := min(int(x), n - 2)
	return table[i] + (table[i + 1] - table[i]) * (x - f32(i))
}

// --- LFOs ----------------------------------------------------------------------------------------

// How an LFO runs against its note.
Lfo_Mode :: enum u8 {
	Trigger,          // restarts with each note, loops
	Sync,             // loops in step with the song (the transport's position), whatever the note
	Envelope,         // runs once from each note, then holds
	Sustain_Envelope, // runs to its phase point while the note is held, then on to the end
	Loop_Point,       // once through, then loops from its phase point
	Loop_Hold,        // loops up to its phase point while held, then on to the end
}

// What sets an LFO's rate.
Lfo_Rate :: enum u8 {Seconds, Tempo, Dotted, Triplet, Keytrack}

// Tempo divisions (the `Lfo_Params.tempo` index): cycles a beat.
LFO_TEMPO_RATIOS :: [13]f32{0, 1.0 / 128, 1.0 / 64, 1.0 / 32, 1.0 / 16, 1.0 / 8, 1.0 / 4, 1.0 / 2, 1, 2, 4, 8, 16}

// Their names (as bars and notes).
LFO_TEMPO_NAMES :: [13]string{"Freeze", "32/1", "16/1", "8/1", "4/1", "2/1", "1/1", "1/2", "1/4", "1/8", "1/16", "1/32", "1/64"}

// An LFO's settings.
Lfo_Params :: struct {
	mode:        Lfo_Mode,
	rate:        Lfo_Rate,
	hz:          f32,  // Seconds: cycles a second
	tempo:       int,  // Tempo, Dotted, Triplet: an index into LFO_TEMPO_RATIOS
	key_transpose, key_tune: f32, // Keytrack: semitones off the note
	phase:       f32,  // 0..1: where it starts (or its loop or hold point)
	fade:        f32,  // seconds to fade in, from the shape's start value
	delay:       f32,  // seconds before it starts
	smooth:      bool, // glide toward the shape (a half-life of `smooth_time` / 5)
	smooth_time: f32,  // seconds
	stereo:      f32,  // -0.5..0.5: the right side's phase offset from the left
}

// Default LFO settings: retriggered, a cycle every two beats.
LFO_DEFAULTS :: Lfo_Params{mode = .Trigger, rate = .Tempo, hz = 2, tempo = 7, key_transpose = -12, smooth_time = 0.0055}

// One LFO of one voice (or a free one): where it is, a side each.
Lfo_State :: struct {
	offset:  f64,     // cycles since it started (wrapped when looping)
	waited:  f32,     // seconds since the note (for the delay)
	fade:    f32,     // 0..1
	smooth:  [2]f32,
	held:    bool,
	value:   [2]f32,  // its value now, left and right (0..1)
	phase:   f32,     // the phase it read at (for drawing a dot)
}

// [rt] The rate an LFO runs at, in cycles a second.
lfo_hz :: proc "contextless" (p: ^Lfo_Params, bpm: f64, note: f32) -> f32 {
	ratios := LFO_TEMPO_RATIOS
	bps := f32(bpm / 60)
	switch p.rate {
	case .Seconds:  return p.hz
	case .Tempo:    return ratios[clamp(p.tempo, 0, 12)] * bps
	case .Dotted:   return ratios[clamp(p.tempo, 0, 12)] * bps * 2.0 / 3
	case .Triplet:  return ratios[clamp(p.tempo, 0, 12)] * bps * 1.5
	case .Keytrack: return fx.key_to_hz(note + p.key_transpose + p.key_tune)
	}
	return p.hz
}

// [rt] A note starts it. In Sync mode it starts where the song is
// (`song_seconds` into it at `hz`).
lfo_note_on :: proc "contextless" (l: ^Lfo_State, p: ^Lfo_Params, hz: f32, song_seconds: f64) {
	l.offset = math.mod(song_seconds * f64(hz), 1) if p.mode == .Sync else 0
	l.waited, l.fade, l.smooth, l.held = 0, 0, {}, true
}

// [rt] A Sync LFO put where the song is (`song_seconds` into it at `hz`),
// each block: it follows the song's position (a stop and play, a loop).
lfo_sync :: proc "contextless" (l: ^Lfo_State, hz: f32, song_seconds: f64) {
	x := song_seconds * f64(hz)
	l.offset = x - math.floor(x)
}

// [rt] The note is let go (the sustain and hold modes move on).
lfo_note_off :: proc "contextless" (l: ^Lfo_State) {
	l.held = false
}

// [rt] Moves it on by `dt` seconds at `hz` and returns its values (left,
// right; 0..1) from the rendered shape `table`.
lfo_step :: proc "contextless" (l: ^Lfo_State, p: ^Lfo_Params, table: []f32, hz, dt: f32) -> [2]f32 {
	l.waited += dt
	passed := clamp(l.waited - p.delay, 0, dt)
	ph := p.phase
	cur := l.offset
	l.offset += f64(hz) * f64(passed)
	read: f64
	switch p.mode {
	case .Envelope:
		l.offset = min(l.offset, 1)
		read = min(cur + f64(ph), 1)
	case .Sustain_Envelope:
		l.offset = min(l.offset, f64(ph) if l.held else 1)
		read = cur
	case .Trigger, .Sync:
		l.offset = l.offset - math.floor(l.offset)
		read = cur + f64(ph)
		read -= math.floor(read)
	case .Loop_Point:
		if l.offset >= 1 do l.offset = l.offset - 1 + f64(ph)
		read = min(cur, 1)
	case .Loop_Hold:
		if l.held && l.offset >= f64(ph) do l.offset -= f64(ph)
		l.offset = min(l.offset, 1)
		read = min(cur, f64(ph)) if l.held else cur
	}
	// Fade in from the shape's start value.
	if p.fade <= 0 do l.fade = 1
	else do l.fade = min(l.fade + passed / max(dt, p.fade), 1)
	l.phase = f32(read)
	for side in 0 ..< 2 {
		r := f32(read) + (p.stereo * 0.5 if side == 0 else -p.stereo * 0.5) // (left ahead, right behind)
		if p.mode == .Trigger || p.mode == .Sync do r -= math.floor(r)
		v := lfo_table_at(table, clamp(r, 0, 1))
		if p.smooth {
			half := p.smooth_time * 0.2
			k: f32 = 0
			if half > 0.0002 do k = math.pow(2, -passed / max(half, 0.0002))
			v = v + (l.smooth[side] - v) * k
			l.smooth[side] = v
		} else {
			start := lfo_table_at(table, clamp(ph, 0, 1))
			v = start + (v - start) * l.fade
		}
		l.value[side] = clamp(v, 0, 1)
	}
	return l.value
}

// --- Random modulators ---------------------------------------------------------------------------

// How a random modulator wanders.
Random_Style :: enum u8 {
	Perlin,           // smooth noise: a slope at each step, eased between
	Sample_Hold,      // a new value each step, held
	Sine_Interpolate, // a new value each step, glided to along half a cosine
	Lorenz,           // the Lorenz attractor's x: never repeats, never jumps
}

// A random modulator's settings (its rate as an LFO's: `lfo_hz`).
Random_Params :: struct {
	style:     Random_Style,
	timing:    Lfo_Params, // only its rate, hz, tempo and key fields
	stereo:    bool,       // the right side wanders on its own
	retrigger: bool,       // each note starts the same wander (else its own)
}

// One random modulator of one voice.
Random_State :: struct {
	phase:  f32,       // 0..1 through the step
	from:   [2]f32,    // the step's start value (or gradient: Perlin), a side
	to:     [2]f32,    // and its end
	lorenz: [2][3]f32, // x, y, z
	rng:    u32,
	value:  [2]f32,    // now (0..1)
}

// [rt] A random number 0 ..< 1 (xorshift).
@(private)
random_next :: #force_inline proc "contextless" (r: ^u32) -> f32 {
	x := r^
	x ~= x << 13
	x ~= x >> 17
	x ~= x << 5
	r^ = x
	return f32(x >> 8) / 16_777_216
}

// [rt] A note starts it: from `seed` (the same each note when it
// retriggers).
random_start :: proc "contextless" (r: ^Random_State, p: ^Random_Params, seed: u32) {
	r^ = {}
	r.rng = seed | 1
	for side in 0 ..< 2 {
		r.from[side], r.to[side] = random_next(&r.rng), random_next(&r.rng)
		r.lorenz[side] = {random_next(&r.rng) * 2 - 1, random_next(&r.rng) * 2 - 1, 20 + random_next(&r.rng) * 10}
	}
	if !p.stereo {
		r.from[1], r.to[1], r.lorenz[1] = r.from[0], r.to[0], r.lorenz[0]
	}
	r.value = random_value(r, p)
}

// [rt] Moves it on by `dt` seconds at `hz` steps a second and returns its
// values (left, right; 0..1).
random_step :: proc "contextless" (r: ^Random_State, p: ^Random_Params, hz, dt: f32) -> [2]f32 {
	adv := max(hz, 0) * dt
	if p.style == .Lorenz {
		// σ 10, ρ 28, β 8/3; a step of the rate is about a loop of it.
		SIGMA :: 10.0
		RHO :: 28.0
		BETA :: 8.0 / 3.0
		total := min(adv * 0.75, 4)
		steps := clamp(int(total / 0.005) + 1, 1, 800)
		h := total / f32(steps)
		for side in 0 ..< (2 if p.stereo else 1) {
			q := &r.lorenz[side]
			for _ in 0 ..< steps {
				dx := SIGMA * (q[1] - q[0])
				dy := q[0] * (RHO - q[2]) - q[1]
				dz := q[0] * q[1] - BETA * q[2]
				q[0] += dx * h
				q[1] += dy * h
				q[2] += dz * h
			}
		}
		if !p.stereo do r.lorenz[1] = r.lorenz[0]
	} else {
		r.phase += adv
		for r.phase >= 1 {
			r.phase -= 1
			for side in 0 ..< 2 {
				r.from[side] = r.to[side]
				r.to[side] = random_next(&r.rng)
			}
			if !p.stereo do r.from[1], r.to[1] = r.from[0], r.to[0]
		}
	}
	r.value = random_value(r, p)
	return r.value
}

// [rt] Its values where it is now.
@(private)
random_value :: proc "contextless" (r: ^Random_State, p: ^Random_Params) -> (v: [2]f32) {
	t := clamp(r.phase, 0, 1)
	for side in 0 ..< 2 {
		a, b := r.from[side], r.to[side]
		switch p.style {
		case .Sample_Hold:      v[side] = b
		case .Sine_Interpolate: v[side] = a + (b - a) * (0.5 - 0.5 * math.cos(t * math.PI))
		case .Perlin:
			// The step's two slopes (-1..1), eased between: about -0.5..0.5.
			g0, g1 := a * 2 - 1, b * 2 - 1
			f := t * t * t * (t * (t * 6 - 15) + 10)
			n := g0 * t + (g1 * (t - 1) - g0 * t) * f
			v[side] = clamp(0.5 + n, 0, 1)
		case .Lorenz:
			v[side] = clamp((r.lorenz[side][0] + 20) / 40, 0, 1)
		}
	}
	return
}
