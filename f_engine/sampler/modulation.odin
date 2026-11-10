package sampler

import "base:intrinsics"
import "core:math"

import "fire:core"
import "fire:dsp"

// What shapes a voice besides its amp envelope: a filter with its own
// envelope, a pitch envelope, two LFOs, and modulation routes. Everything
// is a parameter (so it automates and saves); each voice evaluates it every
// MOD_CHUNK frames of its own life, so the result doesn't depend on block
// sizes.

// Frames between a voice's modulation updates (its filter's coefficients,
// its speed, its pan).
MOD_CHUNK :: 32

// The voice filter's types (SAMPLER_PARAM_FILTER_TYPE).
Voice_Filter :: enum u8 {
	Off,
	Lowpass,
	Highpass,
	Bandpass,
	Notch,
}

// LFO waveforms (SAMPLER_PARAM_LFO_SHAPE).
Lfo_Shape :: enum u8 {
	Sine,
	Triangle,
	Saw_Up,
	Saw_Down,
	Square,
	Sample_Hold, // a new random level each cycle
}

// How an LFO runs (SAMPLER_PARAM_LFO_MODE).
Lfo_Mode :: enum u8 {
	Auto,    // free-running, shared by every voice, at its rate in Hz
	Trigger, // each note starts it again, at its rate in Hz
	Sync,    // locked to the beat, at its synced rate (in beats)
}

// The synced rates' lengths in beats (SAMPLER_PARAM_LFO_SYNC_RATE indexes it).
LFO_SYNC_BEATS := [?]f64{16, 8, 4, 2, 1, 0.5, 0.25, 0.125, 2.0 / 3, 1.0 / 3, 1.0 / 6}
// Their names: "4 bars".."1/32", then triplets.
LFO_SYNC_NAMES := [?]string{"4 bars", "2 bars", "1 bar", "1/2", "1/4", "1/8", "1/16", "1/32", "1/4T", "1/8T", "1/16T"}

// A modulation route's source (SAMPLER_PARAM_ROUTE_SOURCE).
Mod_Source :: enum u8 {
	None,
	Lfo_1,
	Lfo_2,
}

// What a route modulates (SAMPLER_PARAM_ROUTE_DEST). At ±100%: volume ±100%
// (tremolo), pan ±1, pitch ±12 semitones, cutoff ±5 octaves, resonance ±1.
Mod_Dest :: enum u8 {
	None,
	Volume,
	Pan,
	Pitch,
	Cutoff,
	Resonance,
}

// LFOs, and modulation routes (a table: each route a source, a destination
// and an amount; today's sources are the LFOs).
LFOS :: 2
// Modulation routes.
MOD_ROUTES :: 6

// Parameter id of the voice filter's type (a `Voice_Filter`; default Off).
SAMPLER_PARAM_FILTER_TYPE :: core.Param_Id(8)
// Parameter id of its slope: 0 = 12 dB/octave, 1 = 24.
SAMPLER_PARAM_FILTER_SLOPE :: core.Param_Id(9)
// Parameter id of its cutoff, in Hz (20..20000, default 20000).
SAMPLER_PARAM_FILTER_CUTOFF :: core.Param_Id(10)
// Parameter id of its resonance, in percent (0..100).
SAMPLER_PARAM_FILTER_RESONANCE :: core.Param_Id(11)
// Parameter id of its key tracking, in percent: 100 = the cutoff follows the key (from C3).
SAMPLER_PARAM_FILTER_KEYTRACK :: core.Param_Id(12)
// Parameter id of velocity's hold on the cutoff, in percent (±100: softer notes up to 4 octaves darker, or brighter).
SAMPLER_PARAM_FILTER_VELOCITY :: core.Param_Id(13)
// Parameter id of the filter envelope's amount, in percent (±100 = ±6 octaves).
SAMPLER_PARAM_FILTER_ENV :: core.Param_Id(14)
// Parameter id of the filter envelope's attack, in seconds.
SAMPLER_PARAM_FILTER_ATTACK :: core.Param_Id(15)
// Parameter id of the filter envelope's decay, in seconds.
SAMPLER_PARAM_FILTER_DECAY :: core.Param_Id(16)
// Parameter id of the filter envelope's sustain, in percent.
SAMPLER_PARAM_FILTER_SUSTAIN :: core.Param_Id(17)
// Parameter id of the filter envelope's release, in seconds.
SAMPLER_PARAM_FILTER_RELEASE :: core.Param_Id(18)
// Parameter id of the pitch envelope's amount, in semitones (±48).
SAMPLER_PARAM_PITCH_ENV :: core.Param_Id(19)
// Parameter id of the pitch envelope's attack, in seconds.
SAMPLER_PARAM_PITCH_ATTACK :: core.Param_Id(20)
// Parameter id of the pitch envelope's decay, in seconds.
SAMPLER_PARAM_PITCH_DECAY :: core.Param_Id(21)
// Parameter id of the pitch envelope's sustain, in percent.
SAMPLER_PARAM_PITCH_SUSTAIN :: core.Param_Id(22)
// Parameter id of the pitch envelope's release, in seconds.
SAMPLER_PARAM_PITCH_RELEASE :: core.Param_Id(23)
// Parameter id of velocity's hold on pitch, in semitones at full velocity (±24).
SAMPLER_PARAM_PITCH_VELOCITY :: core.Param_Id(24)
// Parameter id of key tracking, in percent: 100 = each key a semitone, 0 = every key the root.
SAMPLER_PARAM_PITCH_KEYTRACK :: core.Param_Id(25)
// Parameter id of fine tuning, in cents (±100).
SAMPLER_PARAM_FINE_TUNE :: core.Param_Id(26)
// Parameter id of LFO 1's shape (an `Lfo_Shape`); LFO `k`'s parameters are
// `sampler_lfo_param(k, ...)`.
SAMPLER_PARAM_LFO_SHAPE :: core.Param_Id(27)
// Parameter id of LFO 1's mode (an `Lfo_Mode`).
SAMPLER_PARAM_LFO_MODE :: core.Param_Id(28)
// Parameter id of LFO 1's rate, in Hz (Auto and Trigger).
SAMPLER_PARAM_LFO_RATE :: core.Param_Id(29)
// Parameter id of LFO 1's synced rate (Sync): an index into `LFO_SYNC_BEATS`.
SAMPLER_PARAM_LFO_SYNC_RATE :: core.Param_Id(30)
// Parameter id of LFO 1's fade-in from each note's start, in seconds.
SAMPLER_PARAM_LFO_FADE :: core.Param_Id(31)
// Parameter id of LFO 1's start phase, in degrees (Trigger).
SAMPLER_PARAM_LFO_PHASE :: core.Param_Id(32)
// Parameters per LFO.
LFO_PARAMS :: 6
// Parameter id of route 1's source (a `Mod_Source`); route `r`'s parameters
// are `sampler_route_param(r, ...)`.
SAMPLER_PARAM_ROUTE_SOURCE :: core.Param_Id(27 + LFOS * LFO_PARAMS)
// Parameter id of route 1's destination (a `Mod_Dest`).
SAMPLER_PARAM_ROUTE_DEST :: SAMPLER_PARAM_ROUTE_SOURCE + 1
// Parameter id of route 1's amount, in percent (±100).
SAMPLER_PARAM_ROUTE_AMOUNT :: SAMPLER_PARAM_ROUTE_SOURCE + 2
// Parameters per route.
ROUTE_PARAMS :: 3

// LFO `k`'s parameter `first` is LFO 1's (SAMPLER_PARAM_LFO_SHAPE..PHASE).
sampler_lfo_param :: proc "contextless" (k: int, first: core.Param_Id) -> core.Param_Id {
	return first + core.Param_Id(k * LFO_PARAMS)
}

// Route `r`'s parameter `first` is route 1's (SAMPLER_PARAM_ROUTE_SOURCE..AMOUNT).
sampler_route_param :: proc "contextless" (r: int, first: core.Param_Id) -> core.Param_Id {
	return first + core.Param_Id(r * ROUTE_PARAMS)
}

// What a voice's modulation came to for one chunk.
@(private)
Voice_Mod :: struct {
	semis:  f64, // added to its pitch
	volume: f64, // × its level
	pan:    f64, // added to its pan (0..1 scale)
	filter: bool,
	coeffs: [2]dsp.Svf_Coeffs, // the two stages (24 dB uses both)
	stages: int,
	cutoff: f64, // Hz, modulated
	res:    f64, // 0..1, modulated
}

// [rt] One parameter's value.
@(private)
param :: #force_inline proc "contextless" (s: ^Sampler, id: core.Param_Id) -> f64 {
	return s.params[id - 1]
}

// [rt] Sets a voice's envelopes and LFOs going at its note-on.
@(private)
mod_note_on :: proc "contextless" (s: ^Sampler, v: ^Sampler_Voice) {
	sr := s.sample_rate
	dsp.adsr_set(&v.fenv, param(s, SAMPLER_PARAM_FILTER_ATTACK), param(s, SAMPLER_PARAM_FILTER_DECAY), param(s, SAMPLER_PARAM_FILTER_SUSTAIN) * 0.01, param(s, SAMPLER_PARAM_FILTER_RELEASE), sr)
	dsp.adsr_set(&v.penv, param(s, SAMPLER_PARAM_PITCH_ATTACK), param(s, SAMPLER_PARAM_PITCH_DECAY), param(s, SAMPLER_PARAM_PITCH_SUSTAIN) * 0.01, param(s, SAMPLER_PARAM_PITCH_RELEASE), sr)
	dsp.adsr_gate(&v.fenv, true)
	dsp.adsr_gate(&v.penv, true)
	for k in 0 ..< LFOS do v.lfo_phase[k] = param(s, sampler_lfo_param(k, SAMPLER_PARAM_LFO_PHASE)) / 360
	v.filt = {}
	v.age = 0
}

// [rt] The note is released: so are its envelopes.
@(private)
mod_note_off :: proc "contextless" (v: ^Sampler_Voice) {
	dsp.adsr_gate(&v.fenv, false)
	dsp.adsr_gate(&v.penv, false)
}

// [rt] A waveform at `phase` (cycles; any value), −1..1. Sample & hold is a
// hash of the cycle number: the same cycle, the same level.
@(private)
lfo_wave :: proc "contextless" (shape: Lfo_Shape, phase: f64, seed: u64) -> f64 {
	f := phase - math.floor(phase)
	switch shape {
	case .Sine:     return math.sin(math.TAU * f)
	case .Triangle: return 1 - 4 * abs(f - 0.5)
	case .Saw_Up:   return 2 * f - 1
	case .Saw_Down: return 1 - 2 * f
	case .Square:   return 1 if f < 0.5 else -1
	case .Sample_Hold:
		x := u64(i64(math.floor(phase))) * 0x9E3779B97F4A7C15 + seed * 0xBF58476D1CE4E5B9
		x ~= x >> 31
		x *= 0x94D049BB133111EB
		x ~= x >> 29
		return f64(x >> 11) / f64(1 << 53) * 2 - 1
	}
	return 0
}

// [rt] LFO `k`'s level for voice `v` at frame `at` of this render (−1..1,
// faded in from the note's start).
@(private)
lfo_value :: proc "contextless" (s: ^Sampler, v: ^Sampler_Voice, k: int, at: int, transport: ^core.Transport) -> f64 {
	shape := Lfo_Shape(clamp(int(param(s, sampler_lfo_param(k, SAMPLER_PARAM_LFO_SHAPE))), 0, int(max(Lfo_Shape))))
	mode := Lfo_Mode(clamp(int(param(s, sampler_lfo_param(k, SAMPLER_PARAM_LFO_MODE))), 0, int(max(Lfo_Mode))))
	rate := param(s, sampler_lfo_param(k, SAMPLER_PARAM_LFO_RATE))
	phase: f64
	switch mode {
	case .Auto:    phase = s.lfo_auto[k] + f64(at) * rate / s.sample_rate
	case .Trigger: phase = v.lfo_phase[k]
	case .Sync:
		idx := clamp(int(param(s, sampler_lfo_param(k, SAMPLER_PARAM_LFO_SYNC_RATE))), 0, len(LFO_SYNC_BEATS) - 1)
		if transport != nil && transport.sample_rate > 0 {
			phase = f64(core.transport_grid_at(transport, at)) / LFO_SYNC_BEATS[idx]
		} else {
			phase = s.lfo_auto[k] + f64(at) * 2 / s.sample_rate // no clock: as Auto at 2 Hz
		}
	}
	x := lfo_wave(shape, phase, u64(k + 1) * 7919 + (u64(v.started) if mode == .Trigger else 0))
	fade := param(s, sampler_lfo_param(k, SAMPLER_PARAM_LFO_FADE))
	if fade > 0 do x *= clamp(f64(v.age) / (fade * s.sample_rate), 0, 1)
	return x
}

// [rt] Voice `v`'s modulation for its next MOD_CHUNK frames, at frame `at`
// of this render (a multiple of MOD_CHUNK into its life): kept in the
// voice, so a chunk a block cuts in two plays on with it. Its trigger LFOs
// move on by the chunk.
@(private)
voice_mod :: proc "contextless" (s: ^Sampler, v: ^Sampler_Voice, at: int, transport: ^core.Transport) -> (m: Voice_Mod) {
	m.volume = 1
	fenv, penv := v.fenv.level, v.penv.level
	lfo: [LFOS]f64
	for k in 0 ..< LFOS {
		lfo[k] = lfo_value(s, v, k, at, transport)
		v.lfo_phase[k] += MOD_CHUNK * param(s, sampler_lfo_param(k, SAMPLER_PARAM_LFO_RATE)) / s.sample_rate
	}
	cut_oct, res := 0.0, param(s, SAMPLER_PARAM_FILTER_RESONANCE) * 0.01
	for r in 0 ..< MOD_ROUTES {
		src := Mod_Source(clamp(int(param(s, sampler_route_param(r, SAMPLER_PARAM_ROUTE_SOURCE))), 0, int(max(Mod_Source))))
		dst := Mod_Dest(clamp(int(param(s, sampler_route_param(r, SAMPLER_PARAM_ROUTE_DEST))), 0, int(max(Mod_Dest))))
		amt := param(s, sampler_route_param(r, SAMPLER_PARAM_ROUTE_AMOUNT)) * 0.01
		if src == .None || dst == .None || amt == 0 do continue
		x := lfo[int(src) - 1] * amt
		switch dst {
		case .None:
		case .Volume: // tremolo: down from full to 1 - |amount| (a negative amount, upside down)
			u := 0.5 + 0.5 * lfo[int(src) - 1] * math.sign(amt)
			m.volume *= 1 - abs(amt) * (1 - u)
		case .Pan:       m.pan += 0.5 * x
		case .Pitch:     m.semis += 12 * x
		case .Cutoff:    cut_oct += 5 * x
		case .Resonance: res += x
		}
	}
	// Pitch: its envelope and velocity, fine tuning.
	m.semis += param(s, SAMPLER_PARAM_PITCH_ENV) * penv + param(s, SAMPLER_PARAM_PITCH_VELOCITY) * v.note_velocity + param(s, SAMPLER_PARAM_FINE_TUNE) / 100
	// The filter.
	type := Voice_Filter(clamp(int(param(s, SAMPLER_PARAM_FILTER_TYPE)), 0, int(max(Voice_Filter))))
	if type == .Off do return
	m.filter = true
	cut_oct += param(s, SAMPLER_PARAM_FILTER_KEYTRACK) * 0.01 * (f64(v.key) - 60) / 12
	cut_oct += param(s, SAMPLER_PARAM_FILTER_VELOCITY) * 0.01 * 4 * (v.note_velocity - 1)
	cut_oct += param(s, SAMPLER_PARAM_FILTER_ENV) * 0.01 * 6 * fenv
	m.cutoff = clamp(param(s, SAMPLER_PARAM_FILTER_CUTOFF) * math.pow(2, cut_oct), 20, 20_000)
	m.res = clamp(res, 0, 1)
	m.coeffs, m.stages = voice_filter_design(type, int(param(s, SAMPLER_PARAM_FILTER_SLOPE)) == 1, m.cutoff, m.res, s.sample_rate)
	return
}

// Any thread. The voice filter's two stages for `type`, `steep` (24 dB),
// `cutoff` (Hz) and `res` (0..1), and how many are used: what the sampler
// runs, and what a UI can draw (with `dsp.svf_response`, multiplying the
// stages' gains).
voice_filter_design :: proc "contextless" (type: Voice_Filter, steep: bool, cutoff, res, sample_rate: f64) -> (c: [2]dsp.Svf_Coeffs, stages: int) {
	mode: dsp.Filter_Mode
	switch type {
	case .Off:      return
	case .Lowpass:  mode = .Lowpass
	case .Highpass: mode = .Highpass
	case .Bandpass: mode = .Bandpass
	case .Notch:    mode = .Notch
	}
	q := 0.707 * math.pow(20, clamp(res, 0, 1)) // 0.707 (flat) .. 14
	if !steep {
		c[0] = dsp.svf_design(mode, cutoff, q, 0, sample_rate)
		return c, 1
	}
	// Two stages: a gentle one under the resonant one (a 4-pole shape).
	c[0] = dsp.svf_design(mode, cutoff, 0.54, 0, sample_rate)
	c[1] = dsp.svf_design(mode, cutoff, q, 0, sample_rate)
	return c, 2
}

// [rt] Filters a voice's `s.mixed[:][at:at+n]` with its chunk's filter.
@(private)
voice_filter :: proc "contextless" (s: ^Sampler, v: ^Sampler_Voice, m: ^Voice_Mod, at, n: int) #no_bounds_check {
	for st in 0 ..< m.stages do for c in 0 ..< 2 do dsp.svf_process(&m.coeffs[st], &v.filt[st][c], s.mixed[c][at:][:n])
}

// [rt] After a render of `n` frames: the free-running LFOs move on, and
// what the newest voice is doing is published for a UI.
@(private)
mod_render_end :: proc "contextless" (s: ^Sampler, n: int, newest: ^Sampler_Voice, m: Voice_Mod, transport: ^core.Transport) {
	for k in 0 ..< LFOS {
		s.lfo_auto[k] += f64(n) * param(s, sampler_lfo_param(k, SAMPLER_PARAM_LFO_RATE)) / s.sample_rate
		s.lfo_auto[k] -= math.floor(s.lfo_auto[k])
	}
	l: Sampler_Live
	if newest != nil {
		l.sounding = true
		l.amp, l.filter_env, l.pitch_env = newest.amp.level, newest.fenv.level, newest.penv.level
		l.cutoff, l.resonance = m.cutoff, m.res
		for k in 0 ..< LFOS do l.lfo[k] = lfo_value(s, newest, k, n, transport)
		l.age = newest.age
	} else {
		l.cutoff, l.resonance = param(s, SAMPLER_PARAM_FILTER_CUTOFF), param(s, SAMPLER_PARAM_FILTER_RESONANCE) * 0.01
		for k in 0 ..< LFOS {
			idle: Sampler_Voice
			idle.age = 1 << 40
			l.lfo[k] = lfo_value(s, &idle, k, n, transport)
		}
	}
	// A seqlock: readers retry while it is odd or changes.
	intrinsics.atomic_add(&s.live_seq, 1)
	s.live = l
	intrinsics.atomic_add(&s.live_seq, 1)
}

// What a sampler is doing now, for a UI: the newest voice's envelopes,
// its modulated filter and the LFOs' levels.
Sampler_Live :: struct {
	sounding:  bool,
	amp, filter_env, pitch_env: f64, // 0..1
	cutoff:    f64, // Hz, with modulation (the setting when nothing sounds)
	resonance: f64, // 0..1, with modulation
	lfo:       [LFOS]f64, // −1..1
	age:       int, // frames since its note-on
}

// Any thread. What the sampler is doing now (see `Sampler_Live`).
sampler_live :: proc "contextless" (s: ^Sampler) -> (l: Sampler_Live) {
	for _ in 0 ..< 8 {
		a := intrinsics.atomic_load(&s.live_seq)
		if a & 1 != 0 do continue
		l = s.live
		if intrinsics.atomic_load(&s.live_seq) == a do return
	}
	return
}

// The LFOs' parameters, in order (see SAMPLER_PARAM_LFO_SHAPE).
@(private)
LFO_PARAM_INFOS :: [LFOS * LFO_PARAMS]core.Param_Info{
	{id = SAMPLER_PARAM_LFO_SHAPE, name = "LFO 1 Shape", min = 0, max = f64(max(Lfo_Shape)), flags = {.Stepped}},
	{id = SAMPLER_PARAM_LFO_MODE, name = "LFO 1 Mode", min = 0, max = f64(max(Lfo_Mode)), flags = {.Stepped}},
	{id = SAMPLER_PARAM_LFO_RATE, name = "LFO 1 Rate", unit = .Hertz, min = 0.01, max = 40, default = 2, flags = {.Automatable}},
	{id = SAMPLER_PARAM_LFO_SYNC_RATE, name = "LFO 1 Sync Rate", min = 0, max = f64(len(LFO_SYNC_BEATS) - 1), default = 4, flags = {.Stepped}},
	{id = SAMPLER_PARAM_LFO_FADE, name = "LFO 1 Fade In", min = 0, max = 10, default = 0, flags = {.Automatable}},
	{id = SAMPLER_PARAM_LFO_PHASE, name = "LFO 1 Phase", min = 0, max = 360, default = 0, flags = {.Automatable}},
	{id = SAMPLER_PARAM_LFO_SHAPE + LFO_PARAMS, name = "LFO 2 Shape", min = 0, max = f64(max(Lfo_Shape)), flags = {.Stepped}},
	{id = SAMPLER_PARAM_LFO_MODE + LFO_PARAMS, name = "LFO 2 Mode", min = 0, max = f64(max(Lfo_Mode)), flags = {.Stepped}},
	{id = SAMPLER_PARAM_LFO_RATE + LFO_PARAMS, name = "LFO 2 Rate", unit = .Hertz, min = 0.01, max = 40, default = 2, flags = {.Automatable}},
	{id = SAMPLER_PARAM_LFO_SYNC_RATE + LFO_PARAMS, name = "LFO 2 Sync Rate", min = 0, max = f64(len(LFO_SYNC_BEATS) - 1), default = 4, flags = {.Stepped}},
	{id = SAMPLER_PARAM_LFO_FADE + LFO_PARAMS, name = "LFO 2 Fade In", min = 0, max = 10, default = 0, flags = {.Automatable}},
	{id = SAMPLER_PARAM_LFO_PHASE + LFO_PARAMS, name = "LFO 2 Phase", min = 0, max = 360, default = 0, flags = {.Automatable}},
}

// The routes' parameters, in order (see SAMPLER_PARAM_ROUTE_SOURCE). Routes
// 1..3 start from LFO 1, 4..6 from LFO 2 (each to nothing yet).
@(private)
ROUTE_PARAM_INFOS :: [MOD_ROUTES * ROUTE_PARAMS]core.Param_Info{
	{id = SAMPLER_PARAM_ROUTE_SOURCE + 0, name = "Route 1 Source", min = 0, max = f64(max(Mod_Source)), default = 1, flags = {.Stepped}},
	{id = SAMPLER_PARAM_ROUTE_DEST + 0, name = "Route 1 Destination", min = 0, max = f64(max(Mod_Dest)), flags = {.Stepped}},
	{id = SAMPLER_PARAM_ROUTE_AMOUNT + 0, name = "Route 1 Amount", unit = .Percent, min = -100, max = 100, flags = {.Automatable}},
	{id = SAMPLER_PARAM_ROUTE_SOURCE + 3, name = "Route 2 Source", min = 0, max = f64(max(Mod_Source)), default = 1, flags = {.Stepped}},
	{id = SAMPLER_PARAM_ROUTE_DEST + 3, name = "Route 2 Destination", min = 0, max = f64(max(Mod_Dest)), flags = {.Stepped}},
	{id = SAMPLER_PARAM_ROUTE_AMOUNT + 3, name = "Route 2 Amount", unit = .Percent, min = -100, max = 100, flags = {.Automatable}},
	{id = SAMPLER_PARAM_ROUTE_SOURCE + 6, name = "Route 3 Source", min = 0, max = f64(max(Mod_Source)), default = 1, flags = {.Stepped}},
	{id = SAMPLER_PARAM_ROUTE_DEST + 6, name = "Route 3 Destination", min = 0, max = f64(max(Mod_Dest)), flags = {.Stepped}},
	{id = SAMPLER_PARAM_ROUTE_AMOUNT + 6, name = "Route 3 Amount", unit = .Percent, min = -100, max = 100, flags = {.Automatable}},
	{id = SAMPLER_PARAM_ROUTE_SOURCE + 9, name = "Route 4 Source", min = 0, max = f64(max(Mod_Source)), default = 2, flags = {.Stepped}},
	{id = SAMPLER_PARAM_ROUTE_DEST + 9, name = "Route 4 Destination", min = 0, max = f64(max(Mod_Dest)), flags = {.Stepped}},
	{id = SAMPLER_PARAM_ROUTE_AMOUNT + 9, name = "Route 4 Amount", unit = .Percent, min = -100, max = 100, flags = {.Automatable}},
	{id = SAMPLER_PARAM_ROUTE_SOURCE + 12, name = "Route 5 Source", min = 0, max = f64(max(Mod_Source)), default = 2, flags = {.Stepped}},
	{id = SAMPLER_PARAM_ROUTE_DEST + 12, name = "Route 5 Destination", min = 0, max = f64(max(Mod_Dest)), flags = {.Stepped}},
	{id = SAMPLER_PARAM_ROUTE_AMOUNT + 12, name = "Route 5 Amount", unit = .Percent, min = -100, max = 100, flags = {.Automatable}},
	{id = SAMPLER_PARAM_ROUTE_SOURCE + 15, name = "Route 6 Source", min = 0, max = f64(max(Mod_Source)), default = 2, flags = {.Stepped}},
	{id = SAMPLER_PARAM_ROUTE_DEST + 15, name = "Route 6 Destination", min = 0, max = f64(max(Mod_Dest)), flags = {.Stepped}},
	{id = SAMPLER_PARAM_ROUTE_AMOUNT + 15, name = "Route 6 Amount", unit = .Percent, min = -100, max = 100, flags = {.Automatable}},
}
