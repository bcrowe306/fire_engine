package synth

import "base:runtime"
import "core:fmt"
import "core:math"

import "fire:core"
import "fire:fx"

// The synth's parameters. Each block (the oscillators, the filters, the
// envelopes, the LFOs) has its fields at fixed ids, so a parameter's id
// never changes: `osc_param(1, .Level)` is always the same id.
//
// A parameter holds a plain value in its range; modulation adds to it
// (a route's amount is a share of the range), and only then is it put
// through its curve (see `Param_Curve`) into the value the sound uses.

// The global parameters.
Global_Field :: enum u16 {
	Volume,          // dB
	Polyphony,       // voices 1..32
	Mono,            // 0 poly, 1 mono (retriggers), 2 legato (glides, no retrigger)
	Glide,           // seconds (quartic curve)
	Glide_Slope,     // -8..8: the glide's curve
	Glide_Octave,    // 0/1: a glide takes longer the further it goes
	Glide_Always,    // 0/1: glide on every note, not only overlapping ones
	Bend_Range,      // semitones
	Velocity_Track,  // 0..1: how much velocity sets the level
	Transpose,       // semitones, whole
	Tune,            // -1..1 semitone
	Oversampling,    // 0 1×, 1 2×, 2 4×, 3 8×
	Priority,        // a `Voice_Priority`
	Macro_1, Macro_2, Macro_3, Macro_4, // 0..1
	Pitch_Wheel,     // -1..1 (set by MIDI)
	Mod_Wheel,       // 0..1 (set by MIDI)
	Aftertouch,      // 0..1 (set by MIDI)
}

// An oscillator's parameters.
Osc_Field :: enum u16 {
	On, Table, Frame, Level, Pan, Transpose, Tune, Keytrack,
	Unison, Detune, Detune_Power, Detune_Range, Blend, Stereo_Spread, Stack,
	Phase, Random_Phase, Warp, Warp_Amount, Warp_Spread, Warp_Phase, Destination,
}

// The sample oscillator's parameters.
Sample_Field :: enum u16 {
	On, Sample, Level, Pan, Transpose, Tune, Keytrack, Loop, Bounce, Random_Phase, Destination,
}

// A filter's parameters.
Filter_Field :: enum u16 {
	On, Model, Style, Cutoff, Resonance, Drive, Blend, Mix, Keytrack, Gain,
	Formant_X, Formant_Y, Formant_Transpose, Formant_Resonance, Formant_Spread, Comb_Offset,
	From_Filter, // filter 2 only: filter 1's output into it (in series)
}

// An envelope's parameters.
Env_Field :: enum u16 {Delay, Attack, Hold, Decay, Sustain, Release, Attack_Power, Decay_Power, Release_Power}

// An LFO's parameters.
Lfo_Field :: enum u16 {Mode, Rate, Hz, Tempo, Phase, Fade, Delay, Smooth, Smooth_Time, Stereo, Key_Transpose, Key_Tune}

// A random modulator's parameters.
Random_Field :: enum u16 {Style, Rate, Hz, Tempo, Stereo, Retrigger, Key_Transpose, Key_Tune}

// Wavetable oscillators a synth has.
OSCS :: 3
// Filters a voice has.
FILTERS :: 2
// Envelopes a voice has (the first is the amplifier's).
ENVS :: 6
// LFOs a voice has.
LFOS :: 8
// Macro controls.
MACROS :: 4
// Random modulators a voice has.
RANDOMS :: 4

// Where a source's sound goes.
Destination :: enum u8 {Filter_1, Filter_2, Both_Filters, Effects, Direct}

// How a voice is chosen when every voice plays.
Voice_Priority :: enum u8 {Newest, Oldest, Highest, Lowest, Round_Robin}

// How a parameter's plain value becomes the value the sound uses.
Param_Curve :: enum u8 {
	Linear,
	Quadratic,   // squared (levels, unison detune)
	Quartic,     // to the fourth (envelope and glide times, in seconds)
	Exponential, // 2 to the power (LFO rates in Hz, smoothing in seconds)
	Indexed,     // a choice: rounded
}

// A parameter: its id, name, plain range and default, and curve.
Param_Spec :: struct {
	id:      core.Param_Id,
	name:    string,
	min, max, default: f32,
	curve:   Param_Curve,
	unit:    core.Param_Unit,
	poly:    bool, // modulatable per voice (else only by global sources)
}

// Id bases of the blocks.
@(private) GLOBAL_BASE :: 1
@(private) OSC_BASE :: 100
@(private) OSC_STRIDE :: 40
@(private) SAMPLE_BASE :: 240
@(private) FILTER_BASE :: 300
@(private) FILTER_STRIDE :: 30
@(private) ENV_BASE :: 400
@(private) ENV_STRIDE :: 16
@(private) LFO_BASE :: 520
@(private) LFO_STRIDE :: 16
@(private) RANDOM_BASE :: 650
@(private) RANDOM_STRIDE :: 10

// The id of global parameter `f`.
global_param :: #force_inline proc "contextless" (f: Global_Field) -> core.Param_Id { return core.Param_Id(GLOBAL_BASE + int(f)) }
// The id of oscillator `n`'s (1..3) parameter `f`.
osc_param :: #force_inline proc "contextless" (n: int, f: Osc_Field) -> core.Param_Id { return core.Param_Id(OSC_BASE + (n - 1) * OSC_STRIDE + int(f)) }
// The id of the sample oscillator's parameter `f`.
sample_param :: #force_inline proc "contextless" (f: Sample_Field) -> core.Param_Id { return core.Param_Id(SAMPLE_BASE + int(f)) }
// The id of filter `n`'s (1..2) parameter `f`.
filter_param :: #force_inline proc "contextless" (n: int, f: Filter_Field) -> core.Param_Id { return core.Param_Id(FILTER_BASE + (n - 1) * FILTER_STRIDE + int(f)) }
// The id of envelope `n`'s (1..6) parameter `f`.
env_param :: #force_inline proc "contextless" (n: int, f: Env_Field) -> core.Param_Id { return core.Param_Id(ENV_BASE + (n - 1) * ENV_STRIDE + int(f)) }
// The id of LFO `n`'s (1..8) parameter `f`.
lfo_param :: #force_inline proc "contextless" (n: int, f: Lfo_Field) -> core.Param_Id { return core.Param_Id(LFO_BASE + (n - 1) * LFO_STRIDE + int(f)) }

// The id of random modulator `n`'s (1..4) parameter `f`.
random_param :: #force_inline proc "contextless" (n: int, f: Random_Field) -> core.Param_Id { return core.Param_Id(RANDOM_BASE + (n - 1) * RANDOM_STRIDE + int(f)) }

// Ids span 1 ..< PARAM_SLOTS (with gaps between blocks).
PARAM_SLOTS :: FX_BASE + len(fx.Effect) * FX_STRIDE

// Every parameter, in id order (filled when the program starts).
PARAMS: [dynamic]Param_Spec

// Each id's place in `PARAMS` (-1: no parameter has it).
PARAM_INDEX: [PARAM_SLOTS]i16

// The parameter with id `id`, or nil.
param_spec :: proc "contextless" (id: core.Param_Id) -> ^Param_Spec {
	if int(id) <= 0 || int(id) >= PARAM_SLOTS do return nil
	i := PARAM_INDEX[id]
	return &PARAMS[i] if i >= 0 else nil
}

// [rt] A plain value (modulation in it) put through its curve.
param_curve :: #force_inline proc "contextless" (spec: ^Param_Spec, plain: f32) -> f32 {
	v := clamp(plain, spec.min, spec.max)
	switch spec.curve {
	case .Linear:      return v
	case .Quadratic:   return v * v
	case .Quartic:     v2 := v * v; return v2 * v2
	case .Exponential: return math.pow(2, v)
	case .Indexed:     return math.round(v)
	}
	return v
}

@(init, private)
build_params :: proc "contextless" () {
	context = runtime.default_context()
	for &i in PARAM_INDEX do i = -1
	add :: param_add
	g :: global_param
	add(g(.Volume), "Volume", -60, 12, -6, poly = false, unit = .Decibels)
	add(g(.Polyphony), "Polyphony", 1, 32, 8, .Indexed, false)
	add(g(.Mono), "Voice Mode", 0, 2, 0, .Indexed, false)
	add(g(.Glide), "Glide", 0, 2.37842, 0, .Quartic, false)
	add(g(.Glide_Slope), "Glide Slope", -8, 8, 0, poly = false)
	add(g(.Glide_Octave), "Glide Octave Scale", 0, 1, 0, .Indexed, false)
	add(g(.Glide_Always), "Always Glide", 0, 1, 0, .Indexed, false)
	add(g(.Bend_Range), "Bend Range", 0, 48, 2, .Indexed, false)
	add(g(.Velocity_Track), "Velocity Track", 0, 1, 0)
	add(g(.Transpose), "Transpose", -48, 48, 0, .Indexed)
	add(g(.Tune), "Tune", -1, 1, 0)
	add(g(.Oversampling), "Oversampling", 0, 3, 0, .Indexed, false)
	add(g(.Priority), "Voice Priority", 0, f32(len(Voice_Priority) - 1), 0, .Indexed, false)
	for m in 0 ..< MACROS do add(core.Param_Id(int(g(.Macro_1)) + m), fmt.aprintf("Macro %d", m + 1), 0, 1, 0, poly = false)
	add(g(.Pitch_Wheel), "Pitch Wheel", -1, 1, 0, poly = false)
	add(g(.Mod_Wheel), "Mod Wheel", 0, 1, 0, poly = false)
	add(g(.Aftertouch), "Aftertouch", 0, 1, 0, poly = false)

	for n in 1 ..= OSCS {
		o :: proc(n: int, f: Osc_Field) -> core.Param_Id { return osc_param(n, f) }
		name :: proc(n: int, s: string) -> string { return fmt.aprintf("Osc %d %s", n, s) }
		add(o(n, .On), name(n, "On"), 0, 1, 1 if n == 1 else 0, .Indexed, false)
		add(o(n, .Table), name(n, "Wavetable"), 0, 4095, 0, .Indexed, false)
		add(o(n, .Frame), name(n, "Frame"), 0, 1, 0)
		add(o(n, .Level), name(n, "Level"), 0, 1, 0.70710678, .Quadratic)
		add(o(n, .Pan), name(n, "Pan"), -1, 1, 0)
		add(o(n, .Transpose), name(n, "Transpose"), -48, 48, 0, .Indexed)
		add(o(n, .Tune), name(n, "Tune"), -1, 1, 0)
		add(o(n, .Keytrack), name(n, "Key Track"), 0, 1, 1, .Indexed, false)
		add(o(n, .Unison), name(n, "Unison"), 1, 16, 1, .Indexed)
		add(o(n, .Detune), name(n, "Detune"), 0, 10, 4.472136, .Quadratic)
		add(o(n, .Detune_Power), name(n, "Detune Power"), -5, 5, 1.5)
		add(o(n, .Detune_Range), name(n, "Detune Range"), 0, 48, 2)
		add(o(n, .Blend), name(n, "Blend"), 0, 1, 0.8)
		add(o(n, .Stereo_Spread), name(n, "Stereo Spread"), 0, 1, 1)
		add(o(n, .Stack), name(n, "Stack"), 0, f32(len(Unison_Stack) - 1), 0, .Indexed, false)
		add(o(n, .Phase), name(n, "Phase"), 0, 1, 0.5)
		add(o(n, .Random_Phase), name(n, "Random Phase"), 0, 1, 1)
		add(o(n, .Warp), name(n, "Warp"), 0, f32(len(Osc_Warp) - 1), 0, .Indexed, false)
		add(o(n, .Warp_Amount), name(n, "Warp Amount"), 0, 1, 0.5)
		add(o(n, .Warp_Spread), name(n, "Warp Spread"), -0.5, 0.5, 0)
		add(o(n, .Warp_Phase), name(n, "Warp Phase"), 0, 1, 0.5)
		add(o(n, .Destination), name(n, "Destination"), 0, f32(len(Destination) - 1), 0, .Indexed, false)
	}
	{
		s :: sample_param
		add(s(.On), "Sample On", 0, 1, 0, .Indexed, false)
		add(s(.Sample), "Sample", 0, 4095, 0, .Indexed, false)
		add(s(.Level), "Sample Level", 0, 1, 0.70710678, .Quadratic)
		add(s(.Pan), "Sample Pan", -1, 1, 0)
		add(s(.Transpose), "Sample Transpose", -48, 48, 0, .Indexed)
		add(s(.Tune), "Sample Tune", -1, 1, 0)
		add(s(.Keytrack), "Sample Key Track", 0, 1, 1, .Indexed, false)
		add(s(.Loop), "Sample Loop", 0, 1, 1, .Indexed, false)
		add(s(.Bounce), "Sample Bounce", 0, 1, 0, .Indexed, false)
		add(s(.Random_Phase), "Sample Random Start", 0, 1, 1, .Indexed, false)
		add(s(.Destination), "Sample Destination", 0, f32(len(Destination) - 1), 0, .Indexed, false)
	}
	for n in 1 ..= FILTERS {
		f :: proc(n: int, x: Filter_Field) -> core.Param_Id { return filter_param(n, x) }
		name :: proc(n: int, s: string) -> string { return fmt.aprintf("Filter %d %s", n, s) }
		add(f(n, .On), name(n, "On"), 0, 1, 1 if n == 1 else 0, .Indexed, false)
		add(f(n, .Model), name(n, "Model"), 0, f32(len(fx.Filter_Model) - 1), 0, .Indexed, false)
		add(f(n, .Style), name(n, "Style"), 0, 5, 0, .Indexed, false)
		add(f(n, .Cutoff), name(n, "Cutoff"), 8, 136, 60)
		add(f(n, .Resonance), name(n, "Resonance"), 0, 1, 0.5)
		add(f(n, .Drive), name(n, "Drive"), 0, 20, 0, unit = .Decibels)
		add(f(n, .Blend), name(n, "Blend"), 0, 2, 0)
		add(f(n, .Mix), name(n, "Mix"), 0, 1, 1)
		add(f(n, .Keytrack), name(n, "Key Track"), -1, 1, 0)
		add(f(n, .Gain), name(n, "Shelf Gain"), -15, 15, 0, unit = .Decibels)
		add(f(n, .Formant_X), name(n, "Formant X"), 0, 1, 0.5)
		add(f(n, .Formant_Y), name(n, "Formant Y"), 0, 1, 0.5)
		add(f(n, .Formant_Transpose), name(n, "Formant Transpose"), -12, 12, 0)
		add(f(n, .Formant_Resonance), name(n, "Formant Resonance"), 0.3, 1, 0.85)
		add(f(n, .Formant_Spread), name(n, "Formant Spread"), -1, 1, 0)
		add(f(n, .Comb_Offset), name(n, "Comb Offset"), 0, 84, 42)
		add(f(n, .From_Filter), name(n, "From Filter 1"), 0, 1, 0, .Indexed, false)
	}
	for n in 1 ..= ENVS {
		e :: proc(n: int, f: Env_Field) -> core.Param_Id { return env_param(n, f) }
		name :: proc(n: int, s: string) -> string { return fmt.aprintf("Env %d %s", n, s) }
		add(e(n, .Delay), name(n, "Delay"), 0, 1.4142135, 0, .Quartic)
		add(e(n, .Attack), name(n, "Attack"), 0, 2.37842, 0.1495, .Quartic)
		add(e(n, .Hold), name(n, "Hold"), 0, 1.4142135, 0, .Quartic)
		add(e(n, .Decay), name(n, "Decay"), 0, 2.37842, 1, .Quartic)
		add(e(n, .Sustain), name(n, "Sustain"), 0, 1, 1)
		add(e(n, .Release), name(n, "Release"), 0, 2.37842, 0.5476, .Quartic)
		add(e(n, .Attack_Power), name(n, "Attack Curve"), -20, 20, 0)
		add(e(n, .Decay_Power), name(n, "Decay Curve"), -20, 20, -2)
		add(e(n, .Release_Power), name(n, "Release Curve"), -20, 20, -2)
	}
	for n in 1 ..= LFOS {
		l :: proc(n: int, f: Lfo_Field) -> core.Param_Id { return lfo_param(n, f) }
		name :: proc(n: int, s: string) -> string { return fmt.aprintf("LFO %d %s", n, s) }
		add(l(n, .Mode), name(n, "Mode"), 0, f32(len(Lfo_Mode) - 1), 0, .Indexed, false)
		add(l(n, .Rate), name(n, "Rate Mode"), 0, f32(len(Lfo_Rate) - 1), 1, .Indexed, false)
		add(l(n, .Hz), name(n, "Frequency"), -7, 9, 1, .Exponential)
		add(l(n, .Tempo), name(n, "Tempo"), 0, 12, 7, .Indexed)
		add(l(n, .Phase), name(n, "Phase"), 0, 1, 0)
		add(l(n, .Fade), name(n, "Fade In"), 0, 8, 0)
		add(l(n, .Delay), name(n, "Delay"), 0, 4, 0)
		add(l(n, .Smooth), name(n, "Smooth"), 0, 1, 0, .Indexed, false)
		add(l(n, .Smooth_Time), name(n, "Smooth Time"), -10, 4, -7.5, .Exponential)
		add(l(n, .Stereo), name(n, "Stereo"), -0.5, 0.5, 0)
		add(l(n, .Key_Transpose), name(n, "Key Transpose"), -60, 36, -12, .Indexed)
		add(l(n, .Key_Tune), name(n, "Key Tune"), -1, 1, 0)
	}
	for n in 1 ..= RANDOMS {
		r :: proc(n: int, f: Random_Field) -> core.Param_Id { return random_param(n, f) }
		name :: proc(n: int, s: string) -> string { return fmt.aprintf("Random %d %s", n, s) }
		add(r(n, .Style), name(n, "Style"), 0, f32(len(Random_Style) - 1), 0, .Indexed, false)
		add(r(n, .Rate), name(n, "Rate Mode"), 0, f32(len(Lfo_Rate) - 1), 1, .Indexed, false)
		add(r(n, .Hz), name(n, "Frequency"), -7, 9, 1, .Exponential)
		add(r(n, .Tempo), name(n, "Tempo"), 0, 12, 8, .Indexed)
		add(r(n, .Stereo), name(n, "Stereo"), 0, 1, 0, .Indexed, false)
		add(r(n, .Retrigger), name(n, "Retrigger"), 0, 1, 0, .Indexed, false)
		add(r(n, .Key_Transpose), name(n, "Key Transpose"), -60, 36, -12, .Indexed)
		add(r(n, .Key_Tune), name(n, "Key Tune"), -1, 1, 0)
	}
	build_fx_params()
	for p in PARAMS do append(&node_params, core.Param_Info{id = p.id, name = p.name, unit = p.unit, min = f64(p.min), max = f64(p.max), default = f64(p.default), flags = {.Automatable}})
}

@(private)
param_add :: proc(id: core.Param_Id, name: string, lo, hi, def: f32, curve := Param_Curve.Linear, poly := true, unit := core.Param_Unit.None) {
	PARAM_INDEX[id] = i16(len(PARAMS))
	append(&PARAMS, Param_Spec{id = id, name = name, min = lo, max = hi, default = def, curve = curve, poly = poly, unit = unit})
}

// The node's parameters, for hosts: every synth parameter, automatable.
@(private)
node_params: [dynamic]core.Param_Info
