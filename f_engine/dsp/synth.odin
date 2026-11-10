package dsp

import "core:math"
import "core:mem"

import "fire:core"

// Parameter ids of the `Synth` node (envelope times in seconds).

// Parameter id of the first oscillator's shape: an `Osc_Shape` (default Saw).
SYNTH_PARAM_OSC1_SHAPE :: core.Param_Id(1)
// Parameter id of the second oscillator's shape (default Square).
SYNTH_PARAM_OSC2_SHAPE :: core.Param_Id(2)
// Parameter id of the second oscillator's detune, in cents (−1200..1200, default 7).
SYNTH_PARAM_OSC2_DETUNE :: core.Param_Id(3)
// Parameter id of the oscillator mix, in percent: 0 is the first only, 100 the second (default 40).
SYNTH_PARAM_OSC_MIX :: core.Param_Id(4)
// Parameter id of the filter cutoff, in Hz (20..20000, default 2000).
SYNTH_PARAM_CUTOFF_HZ :: core.Param_Id(5)
// Parameter id of the filter resonance, as Q (0.5..20, default 0.9).
SYNTH_PARAM_RESONANCE :: core.Param_Id(6)
// Parameter id of the filter envelope's reach, in octaves above the cutoff (0..8, default 3).
SYNTH_PARAM_FILTER_ENV :: core.Param_Id(7)
// Parameter id of the filter's key tracking, in percent (0..100, default 50; 100 follows the note).
SYNTH_PARAM_KEYTRACK :: core.Param_Id(8)
// Parameter id of the amp envelope's attack (0.0005..10, default 0.005).
SYNTH_PARAM_AMP_ATTACK :: core.Param_Id(9)
// Parameter id of the amp envelope's decay (0.005..10, default 0.3).
SYNTH_PARAM_AMP_DECAY :: core.Param_Id(10)
// Parameter id of the amp envelope's sustain, in percent (0..100, default 70).
SYNTH_PARAM_AMP_SUSTAIN :: core.Param_Id(11)
// Parameter id of the amp envelope's release (0.005..20, default 0.4).
SYNTH_PARAM_AMP_RELEASE :: core.Param_Id(12)
// Parameter id of the filter envelope's attack (0.0005..10, default 0.002).
SYNTH_PARAM_FILTER_ATTACK :: core.Param_Id(13)
// Parameter id of the filter envelope's decay (0.005..10, default 0.4).
SYNTH_PARAM_FILTER_DECAY :: core.Param_Id(14)
// Parameter id of the filter envelope's sustain, in percent (0..100, default 30).
SYNTH_PARAM_FILTER_SUSTAIN :: core.Param_Id(15)
// Parameter id of the filter envelope's release (0.005..20, default 0.5).
SYNTH_PARAM_FILTER_RELEASE :: core.Param_Id(16)
// Parameter id of the velocity sensitivity, in percent (0..100, default 70).
SYNTH_PARAM_VELOCITY :: core.Param_Id(17)
// Parameter id of the output gain, in dB (−60..12, default −12).
SYNTH_PARAM_GAIN_DB :: core.Param_Id(18)
// Parameter id of the pulse width of `.Pulse` oscillators, in percent (1..99, default 50).
SYNTH_PARAM_PULSE_WIDTH :: core.Param_Id(19)

// Parameter table of the `Synth` node, as returned by `node_params`. Read-only.
synth_params := [?]core.Param_Info {
	{id = SYNTH_PARAM_OSC1_SHAPE, name = "Osc 1", min = 0, max = f64(max(Osc_Shape)), default = f64(Osc_Shape.Saw), flags = {.Automatable, .Stepped}},
	{id = SYNTH_PARAM_OSC2_SHAPE, name = "Osc 2", min = 0, max = f64(max(Osc_Shape)), default = f64(Osc_Shape.Square), flags = {.Automatable, .Stepped}},
	{id = SYNTH_PARAM_OSC2_DETUNE, name = "Detune", min = -1200, max = 1200, default = 7, flags = {.Automatable}},
	{id = SYNTH_PARAM_OSC_MIX, name = "Osc mix", unit = .Percent, min = 0, max = 100, default = 40, flags = {.Automatable}},
	{id = SYNTH_PARAM_CUTOFF_HZ, name = "Cutoff", unit = .Hertz, min = 20, max = 20000, default = 2000, smoothing = .Linear, smoothing_ms = 20, flags = {.Automatable}},
	{id = SYNTH_PARAM_RESONANCE, name = "Resonance", min = 0.5, max = 20, default = 0.9, flags = {.Automatable}},
	{id = SYNTH_PARAM_FILTER_ENV, name = "Filter env", min = 0, max = 8, default = 3, flags = {.Automatable}},
	{id = SYNTH_PARAM_KEYTRACK, name = "Keytrack", unit = .Percent, min = 0, max = 100, default = 50, flags = {.Automatable}},
	{id = SYNTH_PARAM_AMP_ATTACK, name = "Attack", min = 0.0005, max = 10, default = 0.005, flags = {.Automatable}},
	{id = SYNTH_PARAM_AMP_DECAY, name = "Decay", min = 0.005, max = 10, default = 0.3, flags = {.Automatable}},
	{id = SYNTH_PARAM_AMP_SUSTAIN, name = "Sustain", unit = .Percent, min = 0, max = 100, default = 70, flags = {.Automatable}},
	{id = SYNTH_PARAM_AMP_RELEASE, name = "Release", min = 0.005, max = 20, default = 0.4, flags = {.Automatable}},
	{id = SYNTH_PARAM_FILTER_ATTACK, name = "Filter attack", min = 0.0005, max = 10, default = 0.002, flags = {.Automatable}},
	{id = SYNTH_PARAM_FILTER_DECAY, name = "Filter decay", min = 0.005, max = 10, default = 0.4, flags = {.Automatable}},
	{id = SYNTH_PARAM_FILTER_SUSTAIN, name = "Filter sustain", unit = .Percent, min = 0, max = 100, default = 30, flags = {.Automatable}},
	{id = SYNTH_PARAM_FILTER_RELEASE, name = "Filter release", min = 0.005, max = 20, default = 0.5, flags = {.Automatable}},
	{id = SYNTH_PARAM_VELOCITY, name = "Velocity", unit = .Percent, min = 0, max = 100, default = 70, flags = {.Automatable}},
	{id = SYNTH_PARAM_GAIN_DB, name = "Gain", unit = .Decibels, min = -60, max = 12, default = -12, smoothing = .Linear, smoothing_ms = 20, flags = {.Automatable}},
	{id = SYNTH_PARAM_PULSE_WIDTH, name = "Pulse width", unit = .Percent, min = 1, max = 99, default = 50, flags = {.Automatable}},
}

// Most voices a `Synth` may have.
SYNTH_MAX_VOICES :: 64

// A polyphonic subtractive synth node: per voice, two band-limited
// oscillators into a resonant lowpass with its own envelope and key
// tracking, and an amp envelope with velocity. It plays the notes it
// receives (`core.Note_On`, `core.Note_Off`) and follows per-note
// expression (MPE, MIDI 2.0, or clips' `add_expression`): tuning bends the
// note, volume and pan place it, vibrato wobbles its pitch, and
// brightness and pressure open its filter. Stereo out (mono with one
// output). When every voice is busy, a new note takes the quietest voice
// that is releasing, or else the oldest note's.
Synth :: struct {
	voices:      []Synth_Voice,
	settings:    [len(synth_params)]f64, // indexed by id − 1
	cutoff:      Smoothed_Value,
	gain:        Smoothed_Value, // dB
	clock:       u64, // notes started, for "oldest"
	sample_rate: f64,
	allocator:   mem.Allocator,
}

@(private)
Synth_Voice :: struct {
	on:          bool, // sounding (gate on, or releasing)
	id:          core.Note_Id,
	channel:     u8,
	key:         u8,
	started:     u64,
	velocity:    f64, // the gain from velocity
	osc:         [2]Oscillator,
	amp, env:    Adsr,
	filter:      Svf_State,
	tuning:      f64, // semitones
	volume:      f64,
	pan:         f64,
	vibrato:     f64,
	brightness:  f64,
	pressure:    f64,
	vib_phase:   f64,
}

@(private)
synth_vtable := core.Node_VTable {
	prepare = synth_prepare,
	process = synth_process,
	reset   = proc(self: rawptr) {
		s := (^Synth)(self)
		for &v in s.voices do v.on = false
	},
	params  = proc(self: rawptr) -> []core.Param_Info { return synth_params[:] },
	destroy = proc(self: rawptr, allocator: mem.Allocator) {
		s := (^Synth)(self)
		delete(s.voices, s.allocator)
		free(s, s.allocator)
	},
	type_id = SYNTH_TYPE_ID,
	state_version = 1,
	save = save_synth,
}

// Control thread. A `Synth` node with `voices` voices (1..SYNTH_MAX_VOICES)
// at its default sound. Free it with `core.node_destroy`.
synth_create :: proc(voices := 16, allocator := context.allocator) -> core.Node {
	s := new(Synth, allocator)
	s.allocator = allocator
	s.voices = make([]Synth_Voice, clamp(voices, 1, SYNTH_MAX_VOICES), allocator)
	for p in synth_params do s.settings[p.id - 1] = p.default
	return core.node_make(&synth_vtable, s, allocator)
}

@(private)
synth_prepare :: proc(self: rawptr, cfg: core.Prepare_Config, allocator: mem.Allocator) -> core.Error {
	s := (^Synth)(self)
	s.sample_rate = cfg.sample_rate
	smoothed_init(&s.cutoff, s.settings[SYNTH_PARAM_CUTOFF_HZ - 1], .Linear, 20, cfg.sample_rate)
	smoothed_init(&s.gain, s.settings[SYNTH_PARAM_GAIN_DB - 1], .Linear, 20, cfg.sample_rate)
	for &v in s.voices do v.on = false
	return .None
}

@(private)
setting :: #force_inline proc "contextless" (s: ^Synth, id: core.Param_Id) -> f64 {
	return s.settings[id - 1]
}

// [rt] Sets a voice's envelopes and oscillator shapes from the settings.
@(private)
voice_configure :: proc "contextless" (s: ^Synth, v: ^Synth_Voice) {
	sr := s.sample_rate
	adsr_set(&v.amp, setting(s, SYNTH_PARAM_AMP_ATTACK), setting(s, SYNTH_PARAM_AMP_DECAY), setting(s, SYNTH_PARAM_AMP_SUSTAIN) * 0.01, setting(s, SYNTH_PARAM_AMP_RELEASE), sr)
	adsr_set(&v.env, setting(s, SYNTH_PARAM_FILTER_ATTACK), setting(s, SYNTH_PARAM_FILTER_DECAY), setting(s, SYNTH_PARAM_FILTER_SUSTAIN) * 0.01, setting(s, SYNTH_PARAM_FILTER_RELEASE), sr)
	v.osc[0].shape = Osc_Shape(int(setting(s, SYNTH_PARAM_OSC1_SHAPE)))
	v.osc[1].shape = Osc_Shape(int(setting(s, SYNTH_PARAM_OSC2_SHAPE)))
	pw := setting(s, SYNTH_PARAM_PULSE_WIDTH) * 0.01
	v.osc[0].pulse_width, v.osc[1].pulse_width = pw, pw
}

// [rt]
@(private)
synth_process :: proc(self: rawptr, ctx: ^core.Process_Context) {
	s := (^Synth)(self)
	pos := 0
	for e in ctx.events_in {
		synth_render(s, ctx, pos, int(e.offset))
		pos = int(e.offset)
		#partial switch ev in e.payload {
		case core.Note_On:         note_on(s, ev)
		case core.Note_Off:        for &v in s.voices do if v.on && same_voice(&v, ev.id, ev.channel, ev.key) do note_release(&v)
		case core.Note_Expression: for &v in s.voices do if v.on && same_voice(&v, ev.id, ev.channel, ev.key) do note_express(&v, ev)
		case core.Param_Value, core.Param_Ramp:
			id, raw, frames, _ := any_param(e.payload)
			if id < 1 || int(id) > len(synth_params) do continue
			p := synth_params[id - 1]
			value := clamp(raw, p.min, p.max)
			if .Stepped in p.flags do value = math.round(value)
			s.settings[id - 1] = value
			switch id {
			case SYNTH_PARAM_CUTOFF_HZ: smoothed_apply(&s.cutoff, value, frames)
			case SYNTH_PARAM_GAIN_DB:   smoothed_apply(&s.gain, value, frames)
			case:                       for &v in s.voices do if v.on do voice_configure(s, &v) // envelopes and shapes change for sounding notes too
			}
		}
	}
	synth_render(s, ctx, pos, ctx.frames)
}

// [rt] Matches a note by id, or by channel and key when either has none.
@(private)
same_voice :: #force_inline proc "contextless" (v: ^Synth_Voice, id: core.Note_Id, channel, key: u8) -> bool {
	if v.id != core.NOTE_ID_ANY && id != core.NOTE_ID_ANY do return v.id == id
	return v.channel == channel && v.key == key
}

// [rt]
@(private)
note_on :: proc "contextless" (s: ^Synth, ev: core.Note_On) {
	// The voice already playing this note, else a free one, else the quietest.
	pick := -1
	for &v, i in s.voices do if v.on && v.amp.stage != .Release && same_voice(&v, ev.id, ev.channel, ev.key) do pick = i
	if pick < 0 do for v, i in s.voices do if !v.on {
		pick = i
		break
	}
	if pick < 0 { // steal: the quietest releasing voice, else the oldest note
		pick = 0
		for v, i in s.voices {
			q := s.voices[pick]
			releasing, best_releasing := v.amp.stage == .Release, q.amp.stage == .Release
			if releasing != best_releasing {
				if releasing do pick = i
			} else if releasing ? v.amp.level < q.amp.level : v.started < q.started {
				pick = i
			}
		}
	}
	v := &s.voices[pick]
	fresh := !v.on
	v.on, v.id, v.channel, v.key = true, ev.id, ev.channel, ev.key
	s.clock += 1
	v.started = s.clock
	sens := setting(s, SYNTH_PARAM_VELOCITY) * 0.01
	v.velocity = 1 - sens + sens * f64(clamp(ev.velocity, 0, 1))
	v.tuning, v.volume, v.pan, v.vibrato, v.brightness, v.pressure = 0, 1, 0.5, 0, 0.5, 0
	voice_configure(s, v)
	if fresh { // a stolen voice keeps its phases and levels: the envelope rises from there, no click
		v.osc[0].phase, v.osc[1].phase = 0, 0.25 // apart, so a unison pair doesn't start in phase
		v.osc[0].integrated, v.osc[1].integrated = 0, 0
		v.filter = {}
		v.amp.level, v.env.level = 0, 0
	}
	adsr_gate(&v.amp, true)
	adsr_gate(&v.env, true)
}

// [rt]
@(private)
note_release :: proc "contextless" (v: ^Synth_Voice) {
	adsr_gate(&v.amp, false)
	adsr_gate(&v.env, false)
}

// [rt]
@(private)
note_express :: proc "contextless" (v: ^Synth_Voice, ev: core.Note_Expression) {
	switch ev.kind {
	case .Volume:     v.volume = clamp(ev.value, 0, 4)
	case .Pan:        v.pan = clamp(ev.value, 0, 1)
	case .Tuning:     v.tuning = clamp(ev.value, -120, 120)
	case .Vibrato:    v.vibrato = clamp(ev.value, 0, 1)
	case .Brightness: v.brightness = clamp(ev.value, 0, 1)
	case .Pressure:   v.pressure = clamp(ev.value, 0, 1)
	}
}

// Vibrato's rate in Hz and depth at full vibrato in semitones.
@(private) VIBRATO_HZ :: 5.5
@(private) VIBRATO_SEMITONES :: 0.5

// [rt]
@(private)
synth_render :: proc(s: ^Synth, ctx: ^core.Process_Context, from, to: int) #no_bounds_check {
	if to <= from do return
	outs := len(ctx.outputs)
	for c in 0 ..< outs do for i in from ..< to do ctx.outputs[c][i] = 0
	if outs == 0 do return
	sr := s.sample_rate
	detune := math.pow(2, setting(s, SYNTH_PARAM_OSC2_DETUNE) / 1200) // a frequency ratio
	mix := setting(s, SYNTH_PARAM_OSC_MIX) * 0.01
	q := setting(s, SYNTH_PARAM_RESONANCE)
	reach := setting(s, SYNTH_PARAM_FILTER_ENV)
	track := setting(s, SYNTH_PARAM_KEYTRACK) * 0.01
	// The cutoff and gain move the same for every voice: step them once per frame.
	cutoffs, gains: [64]f64
	for start := from; start < to; start += 64 {
		n := min(64, to - start)
		for i in 0 ..< n {
			cutoffs[i] = smoothed_next(&s.cutoff)
			gains[i] = db_to_gain(smoothed_next(&s.gain))
		}
		for &v in s.voices {
			if !v.on do continue
			// Constant power: −3 dB each side in the middle.
			l, r := math.cos(v.pan * math.PI / 2), math.sin(v.pan * math.PI / 2)
			if outs == 1 do l, r = 1, 0
			key_octaves := track * (f64(v.key) - 60) / 12
			expression_octaves := (v.brightness - 0.5) * 4 + v.pressure * 2
			hz := 440 * math.pow(2, (f64(v.key) + v.tuning - 69) / 12)
			osc_set_freq(&v.osc[0], hz, sr)
			osc_set_freq(&v.osc[1], hz * detune, sr)
			for i in 0 ..< n {
				if v.vibrato > 0 { // the pitch moves every frame only with vibrato
					k := math.pow(2, v.vibrato * VIBRATO_SEMITONES * math.sin(math.TAU * v.vib_phase) / 12)
					osc_set_freq(&v.osc[0], hz * k, sr)
					osc_set_freq(&v.osc[1], hz * k * detune, sr)
					v.vib_phase += VIBRATO_HZ / sr
					if v.vib_phase >= 1 do v.vib_phase -= 1
				}
				x := (1 - mix) * osc_next(&v.osc[0]) + mix * osc_next(&v.osc[1])
				fc := cutoffs[i] * math.pow(2, key_octaves + reach * adsr_next(&v.env) + expression_octaves)
				c := svf_design(.Lowpass, clamp(fc, 20, 20_000), q, 0, sr)
				y := svf_tick(&c, &v.filter, x) * adsr_next(&v.amp) * v.velocity * v.volume * gains[i]
				ctx.outputs[0][start + i] += f32(y * l)
				if outs > 1 do ctx.outputs[1][start + i] += f32(y * r)
			}
			if v.amp.stage == .Idle do v.on = false
		}
	}
}
