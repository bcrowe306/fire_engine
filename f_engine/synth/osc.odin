package synth

import "base:intrinsics"
import "core:math"
import "core:simd"

import "fire:dsp"

// The most unison voices an oscillator stacks.
OSC_MAX_UNISON :: 16

// Unison voices come in pairs, one heard left and one right (the
// stereo spread folds them together).
@(private)
OSC_PAIRS :: OSC_MAX_UNISON / 2

// How unison voices are tuned against each other: all around the note
// (Normal), or some an interval away.
Unison_Stack :: enum u8 {
	Normal,
	Center_Drop_Octave,   // the centre an octave down
	Center_Drop_Octave_2, // the centre two octaves down
	Octave,               // pairs alternate the note and an octave up
	Octave_2,             // the note, an octave and two up
	Power_Chord,          // the note, a fifth and an octave
	Power_Chord_2,        // ... up to two octaves
	Major_Chord,
	Minor_Chord,
	Harmonic_Series,      // pair n on harmonic n
	Odd_Harmonic_Series,  // pair n on odd harmonic 2n-1
}

// The pitch ratio each unison pair has under a stack.
@(private)
STACK_RATIOS := [Unison_Stack][OSC_PAIRS]f32 {
	.Normal               = {1, 1, 1, 1, 1, 1, 1, 1},
	.Center_Drop_Octave   = {0.5, 1, 1, 1, 1, 1, 1, 1},
	.Center_Drop_Octave_2 = {0.25, 1, 1, 1, 1, 1, 1, 1},
	.Octave               = {1, 2, 1, 2, 1, 2, 1, 2},
	.Octave_2             = {1, 2, 3, 1, 2, 3, 1, 2},
	.Power_Chord          = {1, FIFTH, 2, 1, FIFTH, 2, 1, FIFTH},
	.Power_Chord_2        = {1, FIFTH, 2, 2 * FIFTH, 4, 1, FIFTH, 2},
	.Major_Chord          = {1, MAJOR_THIRD, FIFTH, 2, 1, MAJOR_THIRD, FIFTH, 2},
	.Minor_Chord          = {1, MINOR_THIRD, FIFTH, 2, 1, MINOR_THIRD, FIFTH, 2},
	.Harmonic_Series      = {1, 2, 3, 4, 5, 6, 7, 8},
	.Odd_Harmonic_Series  = {1, 3, 5, 7, 9, 11, 13, 15},
}

@(private) FIFTH :: 1.49830707688       // 2^(7/12)
@(private) MAJOR_THIRD :: 1.25992104989 // 2^(4/12)
@(private) MINOR_THIRD :: 1.189207115   // 2^(3/12)

// How an oscillator bends its phase (or its output) before reading the
// wave: the warp. FM and RM take another oscillator's output (A and B:
// the first and second other oscillators) or the sample oscillator's.
Osc_Warp :: enum u8 {
	None,
	Sync,        // hard sync: the wave played 1/16 to 16 times a cycle
	Formant,     // sync, windowed by a half sine: a formant that moves
	Quantize,    // the phase stepped
	Bend,        // the phase bent by a cubic: the wave leans
	Squeeze,     // the first half squeezed, the second stretched
	Pulse_Width, // the cycle played faster, then silent: a pulse of it
	Fm_A, Fm_B, Fm_Sample, // phase modulated
	Rm_A, Rm_B, Rm_Sample, // ring modulated
}

// What an oscillator plays for one render, with modulation applied and
// in its working units (see each).
Osc_Params :: struct {
	table:         ^Wavetable,
	frame:         f32,          // 0..1 across the table
	level:         f32,          // the output's amplitude, already squared from the level control
	pan:           f32,          // -1 (left) .. 1 (right)
	unison:        int,          // 1 ..= OSC_MAX_UNISON
	detune_cents:  f32,          // the outermost voices' detune (range × detune)
	detune_power:  f32,          // -5..5: how the voices between are spread (0 evenly)
	blend:         f32,          // 0..1: the centre's level against the detuned voices'
	stereo_spread: f32,          // 0 (mono) .. 1 (pairs fully left and right)
	stack:         Unison_Stack,
	phase:         f32,          // 0..1: a read offset
	random_phase:  f32,          // 0..1: how much each voice starts at a random phase
	warp:          Osc_Warp,
	warp_amount:   f32,          // 0..1
	warp_spread:   f32,          // -0.5..0.5: the warp's amount across the unison voices
	warp_phase:    f32,          // 0..1 (0.5: none): where in the cycle the warp centres
	morph:         Spectral_Morph,
	morph_amount:  f32,          // 0..1 (see `Spectral_Morph`)
}

// Default oscillator settings (as a new patch has them).
OSC_DEFAULTS :: Osc_Params {
	frame = 0, level = 0.5, unison = 1, detune_cents = 40, detune_power = 1.5, blend = 0.8,
	stereo_spread = 1, phase = 0.5, random_phase = 1, warp_amount = 0.5, warp_phase = 0.5,
}

// What every oscillator of a synth shares: an FFT and its scratch (used
// one oscillator at a time, on the audio thread). Set up with
// `osc_shared_init`.
Osc_Shared :: struct {
	fft:      dsp.Real_Fft,
	spectrum: [WAVE_BINS]complex64,
}

// Control thread. Sets up what oscillators share.
osc_shared_init :: proc(sh: ^Osc_Shared, allocator := context.allocator) -> bool {
	return dsp.real_fft_init(&sh.fft, WAVE_SIZE, allocator = allocator) == .None
}

// Control thread. Frees what `osc_shared_init` made.
osc_shared_destroy :: proc(sh: ^Osc_Shared, allocator := context.allocator) {
	dsp.real_fft_destroy(&sh.fft, allocator)
}

// Seconds a wave buffer lasts before it is built again, crossfading
// from the one before (so a frame or pitch change is smooth).
OSC_FADE_SECONDS :: 0.007

// One oscillator of one voice: its unison phases, its two wave buffers
// (the one it fades from and the one it fades to), and the values it
// glides from between renders. Plain data: zero it, then `osc_start`.
Osc_State :: struct {
	phases:      [OSC_PAIRS][2]u32,
	inc_mult:    [OSC_PAIRS][2]f32, // each voice's pitch ratio (detune × stack)
	last_mult:   [OSC_PAIRS][2]f32,
	warp:        [OSC_PAIRS]f32,    // each pair's warp value (see `warp_value`)
	last_warp:   [OSC_PAIRS]f32,
	warp_phase, last_warp_phase: f32,
	center, detuned, last_center, last_detuned: f32,
	stereo, mono_mix, last_stereo, last_mono_mix: f32,
	pan:         [2]f32,
	last_pan:    [2]f32,
	bufs:        [2][WAVE_SIZE + WAVE_PAD]f32,
	from, to:    int,   // which of `bufs` it fades from and to (equal: no fade)
	fade, fade_len: int, // samples into the fade, and its length
	built_table: ^Wavetable,
	built_frame, built_harmonics: int,
	built_morph: Spectral_Morph,
	built_amount: f32,
	rng:         u32,
	started:     bool,
}

// [rt] A note starts: the unison phases set (each at `p.phase`, moved
// by up to `p.random_phase` of a cycle at random), the glides reset.
// `seed` makes the random phases differ between voices.
osc_start :: proc "contextless" (s: ^Osc_State, p: ^Osc_Params, seed: u32) {
	s.rng = seed * 747796405 + 2891336453
	for &pair in s.phases do for &ph in pair {
		r := f32(next_random(&s.rng)) / 4294967296.0
		ph = u32(r * clamp(p.random_phase, 0, 1) * 4294967295.0)
	}
	if p.unison % 2 == 1 do s.phases[0][1] = s.phases[0][0] // the centre voice heard on both sides
	s.started = false
	s.built_table = nil
	s.fade = 0
	s.fade_len = 0
}

// [rt] A step of a PCG-style generator.
@(private)
next_random :: #force_inline proc "contextless" (state: ^u32) -> u32 {
	x := state^
	state^ = x * 747796405 + 2891336453
	w := ((x >> ((x >> 28) + 4)) ~ x) * 277803737
	return (w >> 22) ~ w
}

// [rt] Renders `len(out_l)` samples of oscillator `s` playing `p`,
// writing (not adding) its stereo output (`raw`: before level and pan,
// for other oscillators' FM and RM; may be nil). `inc` is the note's
// pitch per sample in cycles (one value a sample: glide and pitch
// modulation are in it). `mod` is the FM or RM source, a channel each
// (nil without). Settings that changed since the last render glide to
// their new values across this one.
osc_render :: proc "contextless" (sh: ^Osc_Shared, s: ^Osc_State, p: ^Osc_Params, inc: []f32, mod: ^[2][]f32, out_l, out_r: []f32, raw: ^[2][]f32, sample_rate: f64) #no_bounds_check {
	n := len(out_l)
	unison := clamp(p.unison, 1, OSC_MAX_UNISON)
	pairs := (unison + 1) / 2
	osc_set_targets(s, p, unison, pairs)
	if !s.started { // first render: no glide in from nothing
		s.last_mult, s.last_warp, s.last_warp_phase = s.inc_mult, s.warp, s.warp_phase
		s.last_center, s.last_detuned, s.last_stereo, s.last_mono_mix, s.last_pan = s.center, s.detuned, s.stereo, s.mono_mix, s.pan
	}
	fade_len := max(int(OSC_FADE_SECONDS * sample_rate), 1)
	if s.fade_len != fade_len {
		s.fade_len = fade_len
		s.fade = fade_len // build at once
	}
	end_inc := inc[n - 1] if n > 0 else 0
	if !s.started {
		osc_build(sh, s, p, end_inc, sample_rate)
		s.from = s.to // the first buffer plays at once, not faded in
		s.fade = 0
		s.started = true
	}
	for &v in out_l do v = 0
	for &v in out_r do v = 0
	w := p.warp
	// The render in chunks, each ending where a fade does.
	at := 0
	for at < n {
		if s.fade >= s.fade_len {
			osc_build(sh, s, p, end_inc, sample_rate)
			s.fade = 0
		}
		m := min(n - at, s.fade_len - s.fade)
		osc_chunk(s, p, w, pairs, unison, inc, mod, out_l, out_r, at, at + m, n)
		s.fade += m
		at += m
	}
	if raw != nil {
		copy(raw[0][:n], out_l[:n])
		copy(raw[1][:n], out_r[:n])
	}
	// Level and pan, gliding.
	inv := 1 / f32(max(n, 1))
	for i in 0 ..< n {
		u := f32(i + 1) * inv
		gl := s.last_pan[0] + (s.pan[0] - s.last_pan[0]) * u
		gr := s.last_pan[1] + (s.pan[1] - s.last_pan[1]) * u
		out_l[i] *= gl * p.level
		out_r[i] *= gr * p.level
	}
	s.last_mult, s.last_warp, s.last_warp_phase = s.inc_mult, s.warp, s.warp_phase
	s.last_center, s.last_detuned, s.last_stereo, s.last_mono_mix, s.last_pan = s.center, s.detuned, s.stereo, s.mono_mix, s.pan
}

// [rt] The values this render glides to: each pair's pitch ratio, warp
// value, the centre and detuned levels, the stereo fold, the pan.
@(private)
osc_set_targets :: proc "contextless" (s: ^Osc_State, p: ^Osc_Params, unison, pairs: int) {
	// Detune: pair i at t = (2i + bump) / (unison - 1) of the way out
	// (bump 1 when even, so no pair sits on the note), shaped by the
	// power; one side sharp, the other flat, alternating by pair.
	divisor := f32(max(unison - 1, 1))
	bump := 1 if unison % 2 == 0 else 0
	stack := &STACK_RATIOS[p.stack]
	sharp_left := true
	for i in 0 ..< OSC_PAIRS {
		t := f32(2 * i + bump) / divisor
		cents := power_scale(t, p.detune_power) * p.detune_cents
		up := f32(math.pow(2, f64(cents) / 1200))
		r := stack[i]
		s.inc_mult[i] = {up * r, r / up} if sharp_left else {r / up, up * r}
		sharp_left = !sharp_left
	}
	// The warp, spread across the pairs, in the units the warp works in.
	for i in 0 ..< OSC_PAIRS {
		t := f32(i) / f32(max(pairs - 1, 1)) * 2
		s.warp[i] = warp_value(p.warp, clamp(p.warp_amount + t * p.warp_spread, 0, 1))
	}
	if p.warp == .Quantize do for &v in s.last_warp do v = max(v, 1.5)
	s.warp_phase = p.warp_phase - 0.5
	// Levels: two voices or fewer, all the centre's; more, the blend
	// shares it out, and the sum is kept at the same power.
	if unison <= 2 {
		s.center, s.detuned = 1, 0
	} else {
		center := 1 + (0.4 - 1) * p.blend
		db := (1 - p.blend) * (1 - p.blend)
		detuned := 0.6 * (1 - db)
		norm := 1 / math.sqrt(center * center + detuned * detuned * f32(pairs - 1))
		s.center, s.detuned = center * norm, detuned * norm
	}
	x := clamp(p.stereo_spread, 0, 1) * 0.5 + 0.5
	s.stereo = math.sin(x * math.PI / 2)
	s.mono_mix = math.cos(x * math.PI / 2)
	pan := clamp(p.pan, -1, 1)
	s.pan = {math.sin((1 - pan) * math.PI / 4) * math.SQRT_TWO, math.sin((1 + pan) * math.PI / 4) * math.SQRT_TWO}
}

// The exponential curve `power` puts on t (0..1); near 0 power, t itself.
power_scale :: proc "contextless" (t, power: f32) -> f32 {
	if abs(power) < 0.01 do return t
	return (math.exp(power * t) - 1) / (math.exp(power) - 1)
}

// A warp's amount (0..1) as the value its phase function uses.
@(private)
warp_value :: proc "contextless" (w: Osc_Warp, a: f32) -> f32 {
	#partial switch w {
	case .Fm_A, .Fm_B, .Fm_Sample:
		return a * a
	case .Sync, .Formant:
		return math.pow(2, (a - 0.5) * 2 * 4) // 1/16 .. 16 cycles of the wave a cycle
	case .Quantize:
		d := 1 - a
		d = d * d * d * 0.85
		return math.pow(2, d * 32 + 1) // steps a cycle: 2 at full, too many to hear at none
	case .Squeeze:
		return a * 2 * 0.95 + 0.05
	case .Pulse_Width:
		return 1 / max(1 - a, 1.0 / 4294967295.0)
	}
	return a
}

// [rt] Builds the wave buffer it will fade to, from the frame now at the
// pitch now (the centre pair's, and for sync and formant the warp's
// rate as well), unless it would be the same as the one it has: then it
// stays, and no fade happens.
@(private)
osc_build :: proc "contextless" (sh: ^Osc_Shared, s: ^Osc_State, p: ^Osc_Params, inc: f32, sample_rate: f64) {
	pitch := f64(inc) * f64(s.inc_mult[0][0])
	if p.warp == .Sync || p.warp == .Formant do pitch *= f64(s.warp[0])
	h := wave_harmonics(pitch, sample_rate)
	frame := wave_frame_at(p.table, p.frame)
	amount := math.round(clamp(p.morph_amount, 0, 1) * 1024) / 1024 // (steps too small to hear make no new buffer)
	if p.morph == .None do amount = 0
	if s.started && p.table == s.built_table && frame == s.built_frame && h == s.built_harmonics && p.morph == s.built_morph && amount == s.built_amount {
		s.from = s.to
		return
	}
	next := 1 - s.to
	wave_build(&sh.fft, p.table, frame, h, sh.spectrum[:], s.bufs[next][:], p.morph, amount)
	s.from, s.to = s.to, next
	s.built_table, s.built_frame, s.built_harmonics = p.table, frame, h
	s.built_morph, s.built_amount = p.morph, amount
}

// [rt] Samples `a ..< b` of a render of `n`: every unison voice's phase
// warped and its wave read (faded between the buffers), the centre pair
// at the centre's level and the others at the detuned level, then the
// pairs folded toward the middle by the stereo spread.
@(private)
osc_chunk :: proc "contextless" (s: ^Osc_State, p: ^Osc_Params, w: Osc_Warp, pairs, unison: int, inc: []f32, mod: ^[2][]f32, out_l, out_r: []f32, a, b, n: int) #no_bounds_check {
	// One copy of the voice loop a warp, so none of them asks which a sample.
	if unison == 1 {
		switch w {
		case .None:        osc_voice1(s, p, .None, inc, mod, out_l, out_r, a, b, n)
		case .Sync:        osc_voice1(s, p, .Sync, inc, mod, out_l, out_r, a, b, n)
		case .Formant:     osc_voice1(s, p, .Formant, inc, mod, out_l, out_r, a, b, n)
		case .Quantize:    osc_voice1(s, p, .Quantize, inc, mod, out_l, out_r, a, b, n)
		case .Bend:        osc_voice1(s, p, .Bend, inc, mod, out_l, out_r, a, b, n)
		case .Squeeze:     osc_voice1(s, p, .Squeeze, inc, mod, out_l, out_r, a, b, n)
		case .Pulse_Width: osc_voice1(s, p, .Pulse_Width, inc, mod, out_l, out_r, a, b, n)
		case .Fm_A, .Fm_B, .Fm_Sample: osc_voice1(s, p, .Fm_A, inc, mod, out_l, out_r, a, b, n)
		case .Rm_A, .Rm_B, .Rm_Sample: osc_voice1(s, p, .Rm_A, inc, mod, out_l, out_r, a, b, n)
		}
	} else do switch w {
	case .None:        osc_voices(s, p, .None, pairs, unison, inc, mod, out_l, out_r, a, b, n)
	case .Sync:        osc_voices(s, p, .Sync, pairs, unison, inc, mod, out_l, out_r, a, b, n)
	case .Formant:     osc_voices(s, p, .Formant, pairs, unison, inc, mod, out_l, out_r, a, b, n)
	case .Quantize:    osc_voices(s, p, .Quantize, pairs, unison, inc, mod, out_l, out_r, a, b, n)
	case .Bend:        osc_voices(s, p, .Bend, pairs, unison, inc, mod, out_l, out_r, a, b, n)
	case .Squeeze:     osc_voices(s, p, .Squeeze, pairs, unison, inc, mod, out_l, out_r, a, b, n)
	case .Pulse_Width: osc_voices(s, p, .Pulse_Width, pairs, unison, inc, mod, out_l, out_r, a, b, n)
	case .Fm_A, .Fm_B, .Fm_Sample: osc_voices(s, p, .Fm_A, pairs, unison, inc, mod, out_l, out_r, a, b, n)
	case .Rm_A, .Rm_B, .Rm_Sample: osc_voices(s, p, .Rm_A, pairs, unison, inc, mod, out_l, out_r, a, b, n)
	}
	// The stereo fold: each side keeps `stereo` of itself and takes
	// `mono_mix` of the other.
	inv_n := 1 / f32(max(n, 1))
	for i in a ..< b {
		u := f32(i + 1) * inv_n
		st := s.last_stereo + (s.stereo - s.last_stereo) * u
		mm := s.last_mono_mix + (s.mono_mix - s.last_mono_mix) * u
		l, r := out_l[i], out_r[i]
		out_l[i] = l * st + r * mm
		out_r[i] = r * st + l * mm
	}
}

@(private) V4 :: #simd[4]f32
@(private) U4 :: #simd[4]u32
@(private) I4 :: #simd[4]i32

@(private)
splat :: #force_inline proc "contextless" (x: f32) -> V4 { return V4{x, x, x, x} }

// [rt] The unison voices of `osc_chunk`, four at a time: each vector holds
// two pairs, their left and right voices (lanes 0 and 2 heard left, 1 and
// 3 right). A lane past the last pair plays at no level and keeps no phase.
@(private)
osc_voices :: proc "contextless" (s: ^Osc_State, p: ^Osc_Params, $W: Osc_Warp, pairs, unison: int, inc: []f32, mod: ^[2][]f32, out_l, out_r: []f32, a, b, n: int) #no_bounds_check {
	from, to := s.bufs[s.from][:], s.bufs[s.to][:]
	fading := s.from != s.to
	inv_n := 1 / f32(max(n, 1))
	inv_fade := 1 / f32(s.fade_len)
	offset := splat(p.phase - 0.5)
	d0, d1 := s.last_warp_phase, s.warp_phase
	when W == .Fm_A || W == .Rm_A {
		src_l, src_r: []f32
		if mod != nil do src_l, src_r = mod[0], mod[1]
	}
	for g in 0 ..< (pairs + 1) / 2 {
		q0, q1 := 2 * g, 2 * g + 1 // (q1 < OSC_PAIRS: pairs is at most OSC_PAIRS)
		ph := U4{s.phases[q0][0], s.phases[q0][1], s.phases[q1][0], s.phases[q1][1]}
		m0 := V4{s.last_mult[q0][0], s.last_mult[q0][1], s.last_mult[q1][0], s.last_mult[q1][1]}
		m1 := V4{s.inc_mult[q0][0], s.inc_mult[q0][1], s.inc_mult[q1][0], s.inc_mult[q1][1]}
		w0 := V4{s.last_warp[q0], s.last_warp[q0], s.last_warp[q1], s.last_warp[q1]}
		w1 := V4{s.warp[q0], s.warp[q0], s.warp[q1], s.warp[q1]}
		// Levels: the centre pair's, the detuned ones', none past the last.
		c0, c1 := s.last_detuned, s.detuned
		if g == 0 do c0, c1 = s.last_center, s.center
		amp0 := V4{c0, c0, s.last_detuned, s.last_detuned}
		amp1 := V4{c1, c1, s.detuned, s.detuned}
		if q1 >= pairs {
			amp0 = V4{c0, c0, 0, 0}
			amp1 = V4{c1, c1, 0, 0}
		}
		if unison == 1 { // one voice: its right is its left (below)
			amp0 = V4{c0, 0, 0, 0}
			amp1 = V4{c1, 0, 0, 0}
		}
		damp := amp1 - amp0
		dm := m1 - m0
		dw := w1 - w0
		for i in a ..< b {
			u := f32(i + 1) * inv_n
			uv := splat(u)
			// The phase step, in cycles; its whole cycles change nothing.
			x := splat(inc[i]) * (m0 + dm * uv)
			ph += cast(U4)((x - simd.floor(x)) * 4294967296.0)
			at := cast(V4)ph * (1.0 / 4294967296.0) + offset
			m: V4
			when W == .Fm_A || W == .Rm_A {
				if src_l != nil do m = V4{src_l[i], src_r[i], src_l[i], src_r[i]}
			}
			y, win := warp_phase4(W, at, w0 + dw * uv, splat(d0 + (d1 - d0) * u), m)
			v := wave_read4(to, y)
			if fading {
				f := wave_read4(from, y)
				v = f + (v - f) * splat(f32(s.fade + (i - a) + 1) * inv_fade)
			}
			o := simd.to_array(win * v * (amp0 + damp * uv))
			out_l[i] += o[0] + o[2]
			out_r[i] += o[1] + o[3]
		}
		phs := simd.to_array(ph)
		s.phases[q0] = {phs[0], phs[1]}
		if q1 < pairs do s.phases[q1] = {phs[2], phs[3]}
	}
	if unison == 1 {
		for i in a ..< b do out_r[i] += out_l[i]
		s.phases[0][1] = s.phases[0][0]
	}
}

// [rt] One unison voice (heard both sides), four samples at a time: the
// phase steps summed along the four, then each sample warped and read on
// its own lane. The last few samples of a chunk go one at a time.
@(private)
osc_voice1 :: proc "contextless" (s: ^Osc_State, p: ^Osc_Params, $W: Osc_Warp, inc: []f32, mod: ^[2][]f32, out_l, out_r: []f32, a, b, n: int) #no_bounds_check {
	from, to := s.bufs[s.from][:], s.bufs[s.to][:]
	fading := s.from != s.to
	inv_n := 1 / f32(max(n, 1))
	inv_fade := 1 / f32(s.fade_len)
	offset := splat(p.phase - 0.5)
	m0, dm := s.last_mult[0][0], s.inc_mult[0][0] - s.last_mult[0][0]
	w0, dw := s.last_warp[0], s.warp[0] - s.last_warp[0]
	d0, dd := s.last_warp_phase, s.warp_phase - s.last_warp_phase
	c0, dc := s.last_center, s.center - s.last_center
	when W == .Fm_A || W == .Rm_A {
		src: []f32
		if mod != nil do src = mod[0]
	}
	STEPS :: V4{0, 1, 2, 3}
	ph := s.phases[0][0]
	i := a
	for ; i < b; i += 4 {
		k := min(b - i, 4) // (fewer at the end: the lanes past it are not kept)
		uv := (splat(f32(i + 1)) + STEPS) * inv_n
		iv: V4
		if k == 4 {
			iv = intrinsics.unaligned_load((^V4)(&inc[i]))
		} else {
			for j in 0 ..< k do (^[4]f32)(&iv)[j] = inc[i + j]
		}
		x := iv * (m0 + dm * uv)
		step := cast(U4)((x - simd.floor(x)) * 4294967296.0)
		// The phase after each: the steps summed along the lanes.
		sum := step + simd.shuffle(U4(0), step, 0, 4, 5, 6)
		sum += simd.shuffle(U4(0), sum, 0, 1, 4, 5)
		phs := U4{ph, ph, ph, ph} + sum
		at := cast(V4)phs * (1.0 / 4294967296.0) + offset
		m: V4
		when W == .Fm_A || W == .Rm_A {
			if src != nil {
				if k == 4 {
					m = intrinsics.unaligned_load((^V4)(&src[i]))
				} else {
					for j in 0 ..< k do (^[4]f32)(&m)[j] = src[i + j]
				}
			}
		}
		y, win := warp_phase4(W, at, w0 + dw * uv, d0 + dd * uv, m)
		v := wave_read4(to, y)
		if fading {
			f := wave_read4(from, y)
			v = f + (v - f) * ((splat(f32(s.fade + (i - a) + 1)) + STEPS) * inv_fade)
		}
		o := simd.to_array(win * v * (c0 + dc * uv))
		all := simd.to_array(phs)
		for j in 0 ..< k {
			out_l[i + j] += o[j]
			out_r[i + j] += o[j]
		}
		ph = all[k - 1]
	}
	s.phases[0] = {ph, ph}
}

// [rt] `wave_read` for four phases at once.
@(private)
wave_read4 :: #force_inline proc "contextless" (buf: []f32, phase: V4) -> V4 #no_bounds_check {
	x := phase * WAVE_SIZE
	xi := cast(I4)x
	t := x - cast(V4)xi
	idx := simd.to_array(xi & (WAVE_SIZE - 1))
	base := raw_data(buf)
	// Each lane's four samples, then turned so each vector is one of them.
	r0 := intrinsics.unaligned_load((^V4)(&base[idx[0]]))
	r1 := intrinsics.unaligned_load((^V4)(&base[idx[1]]))
	r2 := intrinsics.unaligned_load((^V4)(&base[idx[2]]))
	r3 := intrinsics.unaligned_load((^V4)(&base[idx[3]]))
	t0 := simd.shuffle(r0, r1, 0, 4, 1, 5)
	t1 := simd.shuffle(r2, r3, 0, 4, 1, 5)
	t2 := simd.shuffle(r0, r1, 2, 6, 3, 7)
	t3 := simd.shuffle(r2, r3, 2, 6, 3, 7)
	p0 := simd.shuffle(t0, t1, 0, 1, 4, 5)
	p1 := simd.shuffle(t0, t1, 2, 3, 6, 7)
	p2 := simd.shuffle(t2, t3, 0, 1, 4, 5)
	p3 := simd.shuffle(t2, t3, 2, 3, 6, 7)
	return p1 + 0.5 * t * (p2 - p0 + t * (2 * p0 - 5 * p1 + 4 * p2 - p3 + t * (3 * (p1 - p2) + p3 - p0)))
}

// [rt] Four phases `x` (cycles, any value) warped by `W` at values `v`
// with their centres moved by `dp` (cycles), and the windows to multiply
// the reads by. `m` is the FM or RM source's samples now. Returns the
// phases to read at (0..1). The warp is chosen when it is compiled (FM and
// RM: `.Fm_A` and `.Rm_A` stand for their kinds).
@(private)
warp_phase4 :: #force_inline proc "contextless" ($W: Osc_Warp, x, v, dp, m: V4) -> (phase: V4, window: V4) {
	wrap :: #force_inline proc "contextless" (x: V4) -> V4 { return x - simd.floor(x) }
	signed :: #force_inline proc "contextless" (x: V4) -> V4 { return wrap(x + 0.5) - 0.5 }
	window = 1
	when W == .None {
		phase = wrap(x)
	} else when W == .Rm_A {
		phase = wrap(x)
		window = 1 + (m - 1) * v
	} else when W == .Fm_A { // (a full-scale source at full amount: ±6 cycles)
		phase = wrap(x + m * v * 6)
	} else when W == .Sync { // v cycles of the wave per cycle, centred on the middle of the cycle
		phase = wrap(signed(x + 0.5) * v + 0.5 + dp)
	} else when W == .Formant { // sync, windowed by a half sine across the cycle
		c := signed(x + 0.5)
		phase = wrap(c * v + 0.5 + dp)
		k := simd.to_array(c * math.PI)
		window = V4{math.cos(k[0]), math.cos(k[1]), math.cos(k[2]), math.cos(k[3])}
	} else when W == .Quantize { // v steps a cycle, their edges moved by dp
		q := (simd.trunc(signed(x) * v + dp) - dp) / v
		phase = wrap(q)
	} else when W == .Bend { // a cubic through the cycle: v 0.5 leaves it straight
		u := signed(x - dp) + 0.5
		off := (v - v * v) * 2
		sc := v * 3
		u2 := u * u
		u3 := u2 * u
		nu := u3 + (sc + off) * (u2 - u3) + (sc - off) * (u - 2 * u2 + u3)
		phase = wrap(nu - 0.5 + dp)
	} else when W == .Squeeze { // up to the pivot squeezed by v, the rest stretched (v 1: straight)
		c := signed(x - dp)
		a := simd.abs(c)
		y := simd.select(simd.lanes_le(a, v * 0.25), a / v, 0.5 - (0.5 - a) / (2 - v))
		phase = wrap(simd.select(simd.lanes_ge(c, 0), y, -y) + dp)
	} else when W == .Pulse_Width { // the cycle played v times as fast, silent once it has ended
		c := signed(x) * v
		window = simd.select(simd.lanes_le(c, -0.5), V4(0), V4(1))
		phase = wrap(simd.clamp(c, -0.5, 0.5) + dp)
	} else {
		#panic("a warp warp_phase4 has no case for")
	}
	return
}
