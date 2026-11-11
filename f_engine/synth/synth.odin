package synth

import "base:intrinsics"
import "core:math"
import "core:mem"

import "fire:core"
import "fire:dsp"
import "fire:rt"

// The synth node: notes in, stereo out. Every parameter is a node
// parameter (`osc_param`, `filter_param` ...); the rest of a patch comes
// in whole with `synth_set_patch`.
//
//	node, s := synth.synth_create()
//	p := synth.patch_default()
//	p.tables[0] = saw // a ^Wavetable the caller keeps
//	synth.synth_set_patch(s, &p)

// Voices the node has: the most polyphony allows, and a few more for
// those fading out after being stolen.
MAX_VOICES :: 36

// Frames (at the voice rate) between modulation steps: envelopes, LFOs
// and routes are worked out this often, their effects glided between.
CONTROL_FRAMES :: 32

// A note's place among the synth's voices.
@(private)
Voice :: struct {
	on, held:    bool,
	dying:       bool,        // stolen: fading out, then free
	key, channel: u8,
	id:          core.Note_Id,
	velocity:    f32,
	random:      f32,
	age:         u64,
	pitch:       f32,         // the key it sounds at now (glide in it)
	glide_from, glide_to: f32,
	glide_pos, glide_len: f32, // 0..1 through the glide, and its length in seconds
	oscs:        [OSCS]Osc_State,
	sample:      Sample_Osc,
	filters:     [FILTERS]Filter_State,
	envs:        [ENVS]Env_State,
	lfos:        [LFOS]Lfo_State,
	mod:         [2][PARAM_COUNT_MAX]f32, // each parameter's modulation now, a side
	last_inc:    [OSCS]f32,
	last_cut:    [FILTERS]f32,
	started:     bool,
	raw:         [OSCS][2][CONTROL_FRAMES]f32, // each oscillator's output last step (FM, RM)
	sample_raw:  [2][CONTROL_FRAMES]f32,
	// Each step is rendered whole into `out` (on a grid from the note's
	// start), and the mix drains it: so a block's size never moves a step.
	out:         [2][CONTROL_FRAMES]f32,
	avail, read: int,
	finished:    bool, // its amp envelope ended: free once `out` is drained
}

// Room for every parameter's modulation.
@(private)
PARAM_COUNT_MAX :: 320

// What the newest voice is doing, for a UI to draw (written by the audio
// thread, read by any; each value is atomic on its own).
Synth_Live :: struct {
	sounding:  bool,
	voices:    i32,
	envs:      [ENVS]f32,
	env_stage: [ENVS]i32,
	lfos:      [LFOS]f32,
	lfo_phase: [LFOS]f32,
	frames:    [OSCS]f32, // each oscillator's frame position now (0..1)
	cutoffs:   [FILTERS]f32,
	peak:      [2]f32,    // the output's peak since the last read
}

// The node's state.
Synth :: struct {
	allocator:   mem.Allocator,
	sample_rate: f64,
	max_block:   int,
	values:      [PARAM_SLOTS]f32, // each parameter's plain value (by id)
	patch:       ^Patch,
	old:         ^Patch,
	pending:     rt.Spsc_Queue(^Patch),
	retired:     rt.Spsc_Queue(^Patch),
	voices:      [MAX_VOICES]Voice,
	clock:       u64,
	rng:         u32,
	held:        [128]bool, // keys held (mono: the note to fall back to)
	last_key:    f32,       // the last note's key (where a glide starts)
	any_held:    bool,
	shared:      Osc_Shared,
	os:          [3][2]dsp.Oversampler, // 2×, 4×, 8×, a side each
	os_factor:   int,
	mix:         [2][]f32,   // the voices' sum at the voice rate
	scratch:     [8][]f32,
	song_seconds: f64,
	bpm:         f64,
	live:        Synth_Live,
	// The output's last `SCOPE_FRAMES` (its two sides summed), for a UI's
	// oscilloscope and spectrum; `scope_at` is where the next goes.
	scope:       [SCOPE_FRAMES]f32,
	scope_at:    int,
}

// Frames of output a synth keeps for drawing.
SCOPE_FRAMES :: 2048

@(private)
synth_vtable := core.Node_VTable {
	prepare = synth_prepare,
	process = synth_process,
	reset   = proc(self: rawptr) {
		s := (^Synth)(self)
		for &v in s.voices do v = {}
	},
	params  = proc(self: rawptr) -> []core.Param_Info { return node_params[:] },
	destroy = proc(self: rawptr, allocator: mem.Allocator) { synth_free((^Synth)(self)) },
}

// Control thread. Makes a synth node (stereo out) with every parameter at
// its default and no patch (silent until `synth_set_patch`).
synth_create :: proc(allocator := context.allocator) -> (node: core.Node, s: ^Synth) {
	s = new(Synth, allocator)
	s.allocator = allocator
	s.rng = 0x2545f491
	s.bpm = 120
	for p in PARAMS do s.values[p.id] = p.default
	rt.spsc_init(&s.pending, 8, allocator)
	rt.spsc_init(&s.retired, 16, allocator)
	osc_shared_init(&s.shared, allocator)
	return core.node_make(&synth_vtable, s, allocator), s
}

@(private)
synth_free :: proc(s: ^Synth) {
	a := s.allocator
	osc_shared_destroy(&s.shared, a)
	for &f in s.os do for &o in f do dsp.oversampler_destroy(&o, a)
	for b in s.mix do delete(b, a)
	for b in s.scratch do delete(b, a)
	for p in rt.spsc_pop(&s.pending) do free(p, a)
	for p in rt.spsc_pop(&s.retired) do free(p, a)
	if s.old != nil do free(s.old, a)
	if s.patch != nil do free(s.patch, a)
	rt.spsc_destroy(&s.pending, a)
	rt.spsc_destroy(&s.retired, a)
	free(s, a)
}

@(private)
synth_prepare :: proc(self: rawptr, cfg: core.Prepare_Config, allocator: mem.Allocator) -> core.Error {
	s := (^Synth)(self)
	s.sample_rate, s.max_block = cfg.sample_rate, cfg.max_block
	a := s.allocator
	for b in s.mix do delete(b, a)
	for b in s.scratch do delete(b, a)
	n := cfg.max_block * 8
	for &b in s.mix do b = make([]f32, n, a)
	for &b in s.scratch do b = make([]f32, n, a)
	for &f, k in s.os do for &o in f {
		dsp.oversampler_destroy(&o, a)
		dsp.oversampler_init(&o, 2 << uint(k), cfg.max_block, a) or_return
	}
	s.os_factor = 0
	return .None
}

// Control thread. Hands the node `p` (copied): its routes, LFO shapes,
// tables and sample take over at the next block. The tables and sample
// must stay alive until the node has let the patch go (see
// `synth_collect`).
synth_set_patch :: proc(s: ^Synth, p: ^Patch) -> bool {
	c := new(Patch, s.allocator)
	c^ = p^
	patch_prepare(c)
	if !rt.spsc_push(&s.pending, c) {
		free(c, s.allocator)
		return false
	}
	return true
}

// Control thread. Frees the patches the node has let go; returns how
// many (their tables and sample may be freed once all are).
synth_collect :: proc(s: ^Synth) -> int {
	n := 0
	for p in rt.spsc_pop(&s.retired) {
		free(p, s.allocator)
		n += 1
	}
	return n
}

// The output's last `len(out)` frames (at most SCOPE_FRAMES), oldest
// first: a copy for drawing (read while it plays, so a frame or two may
// be from the block being written).
synth_scope :: proc "contextless" (s: ^Synth, out: []f32) {
	n := min(len(out), SCOPE_FRAMES)
	at := s.scope_at
	for k in 0 ..< n do out[k] = s.scope[(at - n + k + SCOPE_FRAMES) % SCOPE_FRAMES]
}

// The newest voice, as `Synth_Live` (a copy).
synth_live :: proc "contextless" (s: ^Synth) -> Synth_Live {
	return s.live
}

// [rt] Takes the newest patch handed over; the one it replaces goes
// back once no voice can be reading it (at the next block: voices read
// a patch only within a block).
@(private)
adopt_patch :: proc "contextless" (s: ^Synth) {
	if s.old != nil && rt.spsc_push(&s.retired, s.old) do s.old = nil
	if s.old != nil do return
	newest: ^Patch
	got := false
	for p in rt.spsc_pop(&s.pending) {
		if got && newest != nil do rt.spsc_push(&s.retired, newest)
		newest, got = p, true
	}
	if !got do return
	s.old, s.patch = s.patch, newest
	if newest.has_values do for spec in PARAMS do s.values[spec.id] = clamp(newest.values[spec.id], spec.min, spec.max)
}

@(private)
synth_process :: proc(self: rawptr, ctx: ^core.Process_Context) {
	s := (^Synth)(self)
	adopt_patch(s)
	if ctx.transport != nil {
		s.bpm = ctx.transport.tempo_bpm if ctx.transport.tempo_bpm > 0 else 120
		s.song_seconds = f64(ctx.transport.grid) * 60 / s.bpm
	}
	pos := 0
	for e in ctx.events_in {
		render(s, ctx, pos, int(e.offset))
		pos = int(e.offset)
		#partial switch ev in e.payload {
		case core.Note_On:    note_on(s, ev.key, ev.channel, ev.id, ev.velocity)
		case core.Note_Off:   note_off(s, ev.key, ev.channel, ev.id)
		case core.Note_Choke: for &v in s.voices do if v.on && (ev.key == core.NOTE_KEY_ALL || v.key == ev.key) do voice_kill(&v)
		case core.Param_Value:
			if spec := param_spec(ev.param); spec != nil do s.values[ev.param] = clamp(f32(ev.value), spec.min, spec.max)
		case core.Param_Ramp:
			if spec := param_spec(ev.param); spec != nil do s.values[ev.param] = clamp(f32(ev.target), spec.min, spec.max)
		}
	}
	render(s, ctx, pos, ctx.frames)
}

// [rt] A parameter's value, put through its curve, with no modulation.
@(private)
value :: #force_inline proc "contextless" (s: ^Synth, id: core.Param_Id) -> f32 {
	spec := param_spec(id)
	if spec == nil do return 0
	return param_curve(spec, s.values[id])
}

// [rt] A parameter's value for voice `v` (its modulation, side `side`),
// put through its curve.
@(private)
vvalue :: #force_inline proc "contextless" (s: ^Synth, v: ^Voice, id: core.Param_Id, side := 0) -> f32 {
	spec := param_spec(id)
	if spec == nil do return 0
	return param_curve(spec, s.values[id] + v.mod[side][PARAM_INDEX[id]])
}

// --- notes ---------------------------------------------------------------------------------------

@(private)
note_on :: proc "contextless" (s: ^Synth, key, channel: u8, id: core.Note_Id, velocity: f32) {
	s.clock += 1
	mode := int(value(s, global_param(.Mono)))
	glide := value(s, global_param(.Glide))
	always := value(s, global_param(.Glide_Always)) > 0
	had_held := s.any_held
	s.held[key] = true
	s.any_held = true
	from := s.last_key if s.last_key > 0 else f32(key)
	s.last_key = f32(key)
	if mode > 0 {
		// Mono: one voice; legato keeps its envelopes going under held notes.
		v: ^Voice
		for &x in s.voices do if x.on && !x.dying {
			v = &x
			break
		}
		if v != nil && mode == 2 && had_held {
			voice_glide(s, v, f32(key), glide)
			v.key, v.id, v.channel, v.held = key, id, channel, true
			return
		}
		if v != nil {
			if glide > 0 && (had_held || always) do voice_glide(s, v, f32(key), glide)
			else do v.pitch, v.glide_pos = f32(key), 1
			v.key, v.id, v.channel, v.held, v.velocity = key, id, channel, true, velocity
			voice_trigger(s, v, false)
			return
		}
	}
	v := &s.voices[pick_voice(s)]
	v^ = {}
	v.on, v.held = true, true
	v.key, v.channel, v.id, v.velocity = key, channel, id, velocity
	v.age = s.clock
	v.random = f32(next_random(&s.rng)) / 4294967296.0
	v.pitch, v.glide_to, v.glide_pos = f32(key), f32(key), 1
	if glide > 0 && (always || had_held) do voice_glide(s, v, f32(key), glide, from)
	voice_trigger(s, v, true)
}

// [rt] Starts a voice's envelopes, LFOs and (when `fresh`) oscillators.
@(private)
voice_trigger :: proc "contextless" (s: ^Synth, v: ^Voice, fresh: bool) {
	for i in 0 ..< ENVS {
		p := env_params(s, v, i + 1)
		env_gate_on(&v.envs[i], &p)
	}
	for i in 0 ..< LFOS {
		p := lfo_params(s, v, i + 1)
		lfo_note_on(&v.lfos[i], &p, lfo_hz(&p, s.bpm, v.pitch), s.song_seconds)
	}
	if fresh {
		seed := u32(s.clock) * 2654435761
		for i in 0 ..< OSCS {
			p := osc_params(s, v, i + 1)
			osc_start(&v.oscs[i], &p, seed + u32(i) * 977)
		}
		sp := sample_params(s, v)
		sample_osc_start(&v.sample, &sp, seed)
	}
}

// [rt] Sets a voice gliding to `to` over the glide time (longer the
// further, with octave scaling), from where it is or from `from`.
@(private)
voice_glide :: proc "contextless" (s: ^Synth, v: ^Voice, to: f32, glide: f32, from: f32 = -1) {
	v.glide_from = from if from >= 0 else v.pitch
	v.glide_to = to
	v.glide_pos = 0
	octaves := abs(to - v.glide_from) / 12
	v.glide_len = glide * (max(octaves, 0.0) if value(s, global_param(.Glide_Octave)) > 0 else 1)
	if v.glide_len <= 0 do v.pitch, v.glide_pos = to, 1
}

@(private)
note_off :: proc "contextless" (s: ^Synth, key, channel: u8, id: core.Note_Id) {
	s.held[key] = false
	s.any_held = false
	for h in s.held do s.any_held ||= h
	mode := int(value(s, global_param(.Mono)))
	for &v in s.voices {
		if !v.on || !v.held || v.dying do continue
		if v.id != core.NOTE_ID_ANY && id != core.NOTE_ID_ANY {
			if v.id != id do continue
		} else if v.key != key do continue
		// Mono, another key still held: back to it (the newest held below or above).
		if mode > 0 && s.any_held {
			back := -1
			for k := 127; k >= 0; k -= 1 do if s.held[k] {
				back = k
				break
			}
			if back >= 0 {
				voice_glide(s, &v, f32(back), value(s, global_param(.Glide)))
				v.key = u8(back)
				v.id = core.NOTE_ID_ANY
				if mode == 1 do voice_trigger(s, &v, false)
				continue
			}
		}
		v.held = false
		for &e in v.envs do env_gate_off(&e)
		for &l in v.lfos do lfo_note_off(&l)
	}
}

// [rt] A voice stolen: a quick fade, then free.
@(private)
voice_kill :: proc "contextless" (v: ^Voice) {
	v.dying = true
	v.held = false
	env_kill(&v.envs[0])
}

// [rt] A free voice for a new note: one not sounding, else (when as many
// sound as polyphony allows) the one the priority picks is faded out
// and a free one used, else the quietest fading one taken outright.
@(private)
pick_voice :: proc "contextless" (s: ^Synth) -> int {
	poly := int(value(s, global_param(.Polyphony)))
	if value(s, global_param(.Mono)) > 0 do poly = 1
	playing := 0
	for v in s.voices do if v.on && !v.dying && !v.finished do playing += 1
	if playing >= poly {
		victim := -1
		prio := Voice_Priority(int(value(s, global_param(.Priority))))
		for v, i in s.voices {
			if !v.on || v.dying do continue
			if victim < 0 { victim = i; continue }
			w := s.voices[victim]
			better: bool
			switch prio {
			case .Newest, .Round_Robin: better = v.age < w.age // keep the newest: steal the oldest
			case .Oldest:  better = v.age > w.age              // keep the oldest: steal the newest
			case .Highest: better = v.key < w.key              // keep the high notes
			case .Lowest:  better = v.key > w.key
			}
			// (released notes go first)
			if !v.held && w.held do better = true
			if v.held && !w.held do better = false
			if better do victim = i
		}
		if victim >= 0 do voice_kill(&s.voices[victim])
	}
	for v, i in s.voices do if !v.on do return i
	// None free: the dying voice nearest silence.
	best, level := 0, f32(2)
	for v, i in s.voices do if v.dying && v.envs[0].value < level {
		best, level = i, v.envs[0].value
	}
	return best
}

// --- the per-voice settings, as the parts take them ---------------------------------------------

@(private)
env_params :: proc "contextless" (s: ^Synth, v: ^Voice, n: int) -> Env_Params {
	e :: env_param
	return {
		delay = vvalue(s, v, e(n, .Delay)), attack = vvalue(s, v, e(n, .Attack)), hold = vvalue(s, v, e(n, .Hold)),
		decay = vvalue(s, v, e(n, .Decay)), sustain = vvalue(s, v, e(n, .Sustain)), release = vvalue(s, v, e(n, .Release)),
		attack_power = vvalue(s, v, e(n, .Attack_Power)), decay_power = vvalue(s, v, e(n, .Decay_Power)), release_power = vvalue(s, v, e(n, .Release_Power)),
	}
}

@(private)
lfo_params :: proc "contextless" (s: ^Synth, v: ^Voice, n: int) -> Lfo_Params {
	l :: lfo_param
	return {
		mode = Lfo_Mode(int(value(s, l(n, .Mode)))), rate = Lfo_Rate(int(value(s, l(n, .Rate)))),
		hz = vvalue(s, v, l(n, .Hz)), tempo = int(vvalue(s, v, l(n, .Tempo))),
		key_transpose = vvalue(s, v, l(n, .Key_Transpose)), key_tune = vvalue(s, v, l(n, .Key_Tune)),
		phase = vvalue(s, v, l(n, .Phase)), fade = vvalue(s, v, l(n, .Fade)), delay = vvalue(s, v, l(n, .Delay)),
		smooth = value(s, l(n, .Smooth)) > 0, smooth_time = vvalue(s, v, l(n, .Smooth_Time)), stereo = vvalue(s, v, l(n, .Stereo)),
	}
}

@(private)
osc_params :: proc "contextless" (s: ^Synth, v: ^Voice, n: int, side := 0) -> Osc_Params {
	o :: osc_param
	table: ^Wavetable
	if s.patch != nil do table = s.patch.tables[n - 1]
	return {
		table = table, frame = vvalue(s, v, o(n, .Frame), side), level = vvalue(s, v, o(n, .Level), side), pan = vvalue(s, v, o(n, .Pan), side),
		unison = int(vvalue(s, v, o(n, .Unison))), detune_cents = vvalue(s, v, o(n, .Detune_Range)) * vvalue(s, v, o(n, .Detune)),
		detune_power = vvalue(s, v, o(n, .Detune_Power)), blend = vvalue(s, v, o(n, .Blend)), stereo_spread = vvalue(s, v, o(n, .Stereo_Spread)),
		stack = Unison_Stack(int(value(s, o(n, .Stack)))), phase = vvalue(s, v, o(n, .Phase)), random_phase = vvalue(s, v, o(n, .Random_Phase)),
		warp = Osc_Warp(int(value(s, o(n, .Warp)))), warp_amount = vvalue(s, v, o(n, .Warp_Amount), side),
		warp_spread = vvalue(s, v, o(n, .Warp_Spread)), warp_phase = vvalue(s, v, o(n, .Warp_Phase)),
	}
}

@(private)
sample_params :: proc "contextless" (s: ^Synth, v: ^Voice) -> Sample_Params {
	x :: sample_param
	smp: ^Sample
	if s.patch != nil do smp = s.patch.sample
	return {
		sample = smp, keytrack = value(s, x(.Keytrack)) > 0, transpose = vvalue(s, v, x(.Transpose)) + vvalue(s, v, x(.Tune)),
		level = vvalue(s, v, x(.Level)), pan = vvalue(s, v, x(.Pan)), loop = value(s, x(.Loop)) > 0,
		bounce = value(s, x(.Bounce)) > 0, random_phase = value(s, x(.Random_Phase)) > 0,
	}
}

@(private)
filter_params :: proc "contextless" (s: ^Synth, v: ^Voice, n: int) -> Filter_Params {
	f :: filter_param
	return {
		model = Filter_Model(int(value(s, f(n, .Model)))), style = Filter_Style(int(value(s, f(n, .Style)))),
		cutoff = vvalue(s, v, f(n, .Cutoff)), resonance = vvalue(s, v, f(n, .Resonance)), drive_db = vvalue(s, v, f(n, .Drive)),
		blend = vvalue(s, v, f(n, .Blend)), mix = vvalue(s, v, f(n, .Mix)), gain_db = vvalue(s, v, f(n, .Gain)),
		formant_x = vvalue(s, v, f(n, .Formant_X)), formant_y = vvalue(s, v, f(n, .Formant_Y)),
		formant_transpose = vvalue(s, v, f(n, .Formant_Transpose)), formant_resonance = vvalue(s, v, f(n, .Formant_Resonance)),
		formant_spread = vvalue(s, v, f(n, .Formant_Spread)), comb_offset = vvalue(s, v, f(n, .Comb_Offset)),
	}
}

// --- rendering -----------------------------------------------------------------------------------

// [rt] Renders base frames `from ..< to` into the outputs: the voices at
// the voice rate (the oversampling factor times the base), brought down.
@(private)
render :: proc "contextless" (s: ^Synth, ctx: ^core.Process_Context, from, to: int) #no_bounds_check {
	n := to - from
	if n <= 0 || len(ctx.outputs) == 0 do return
	factors := [4]int{1, 2, 4, 8}
	fac := factors[clamp(int(value(s, global_param(.Oversampling))), 0, 3)]
	if fac != s.os_factor {
		for &f in s.os do for &o in f do dsp.oversampler_reset(&o)
		s.os_factor = fac
	}
	vn := n * fac
	sr := s.sample_rate * f64(fac)
	for ch in 0 ..< 2 do for i in 0 ..< vn do s.mix[ch][i] = 0
	// Each voice's steps, drained into the mix.
	for &v in s.voices {
		if !v.on do continue
		at := 0
		for at < vn {
			if v.avail == 0 {
				if v.finished {
					v.on = false
					break
				}
				voice_render(s, &v, sr)
				v.avail, v.read = CONTROL_FRAMES, 0
			}
			k := min(v.avail, vn - at)
			for ch in 0 ..< 2 do for i in 0 ..< k do s.mix[ch][at + i] += v.out[ch][v.read + i]
			v.read += k
			v.avail -= k
			at += k
		}
	}
	// Down to the base rate, then the volume.
	vol := math.pow(10, value(s, global_param(.Volume)) / 20)
	outs := len(ctx.outputs)
	peak := s.live.peak
	for ch in 0 ..< min(outs, 2) {
		out := ctx.outputs[ch][from:to]
		if fac == 1 {
			for i in 0 ..< n do out[i] = s.mix[ch][i] * vol
		} else {
			stage := 0 if fac == 2 else (1 if fac == 4 else 2)
			dsp.oversampler_down(&s.os[stage][ch], s.mix[ch][:vn], out)
			for &x in out do x *= vol
		}
		for x in out do peak[ch] = max(peak[ch], abs(x))
	}
	if outs == 1 { // one output: both sides, at half each
		out := ctx.outputs[0][from:to]
		if fac == 1 do for i in 0 ..< n do out[i] = (s.mix[0][i] + s.mix[1][i]) * 0.5 * vol
		else do for &x in out do x *= 1 // (the left side, brought down above)
	}
	for ch in 2 ..< outs do for i in from ..< to do ctx.outputs[ch][i] = 0
	s.live.peak = peak
	if outs > 0 do for i in 0 ..< n {
		x := ctx.outputs[0][from + i]
		if outs > 1 do x = (x + ctx.outputs[1][from + i]) * 0.5
		s.scope[s.scope_at] = x
		s.scope_at = (s.scope_at + 1) % SCOPE_FRAMES
	}
	live_update(s)
}

// [rt] One control step of a voice (`CONTROL_FRAMES`): its modulation
// worked out, its sources rendered and sent through the filters, the amp
// envelope on it, into `v.out`.
@(private)
voice_render :: proc "contextless" (s: ^Synth, v: ^Voice, sr: f64) #no_bounds_check {
	n := CONTROL_FRAMES
	dt := f32(f64(n) / sr)
	patch := s.patch
	// Glide.
	if v.glide_pos < 1 {
		v.glide_pos = min(v.glide_pos + dt / max(v.glide_len, 1e-6), 1)
		t := power_scale(v.glide_pos, value(s, global_param(.Glide_Slope)))
		v.pitch = v.glide_from + (v.glide_to - v.glide_from) * t
	}
	// Modulators (at the start of the step), then the routes.
	env_vals: [ENVS]f32
	for i in 1 ..< ENVS {
		if patch == nil || i not_in patch.used_envs do continue // (no route reads it)
		p := env_params(s, v, i + 1)
		env_vals[i] = env_step(&v.envs[i], &p, dt)
	}
	env_vals[0] = v.envs[0].value
	lfo_vals: [LFOS][2]f32
	for i in 0 ..< LFOS {
		if patch == nil || i not_in patch.used_lfos do continue
		p := lfo_params(s, v, i + 1)
		table: []f32
		if patch != nil do table = patch.shape_tables[i][:]
		if table == nil do continue
		lfo_vals[i] = lfo_step(&v.lfos[i], &p, table, lfo_hz(&p, s.bpm, v.pitch), dt)
	}
	voice_mod(s, v, env_vals, lfo_vals)
	// The amp envelope, a sample at a time.
	amp := s.scratch[6][:n]
	{
		p := env_params(s, v, 1)
		env_render(&v.envs[0], &p, amp, sr)
	}
	vel := v.velocity
	track := vvalue(s, v, global_param(.Velocity_Track))
	vgain := 1 + (vel - 1) * track
	// The note's pitch, then each source.
	base := v.pitch + vvalue(s, v, global_param(.Transpose)) + vvalue(s, v, global_param(.Tune)) +
	        value(s, global_param(.Pitch_Wheel)) * value(s, global_param(.Bend_Range))
	f1 := [2][]f32{s.scratch[0][:n], s.scratch[1][:n]}
	f2 := [2][]f32{s.scratch[2][:n], s.scratch[3][:n]}
	dry := [2][]f32{s.scratch[4][:n], s.scratch[5][:n]}
	for ch in 0 ..< 2 do for i in 0 ..< n do f1[ch][i], f2[ch][i], dry[ch][i] = 0, 0, 0
	tmp := [2][]f32{s.scratch[7][:n], s.scratch[7][n:2 * n]}
	inc_buf := s.scratch[7][2 * n:3 * n]
	for k in 0 ..< OSCS {
		o := k + 1
		if value(s, osc_param(o, .On)) <= 0 do continue
		p := osc_params(s, v, o)
		key := base + vvalue(s, v, osc_param(o, .Transpose)) + vvalue(s, v, osc_param(o, .Tune))
		if value(s, osc_param(o, .Keytrack)) <= 0 do key = key - v.pitch + 60
		inc := key_to_hz(key) / f32(sr)
		if !v.started do v.last_inc[k] = inc
		for i in 0 ..< n do inc_buf[i] = v.last_inc[k] + (inc - v.last_inc[k]) * f32(i + 1) / f32(n)
		v.last_inc[k] = inc
		// FM and RM: the other oscillators (A, B) or the sample, as they
		// came out last step (or this one, for those rendered before).
		mod: ^[2][]f32
		srcbuf: [2][]f32
		#partial switch p.warp {
		case .Fm_A, .Rm_A, .Fm_B, .Rm_B:
			// A is the first other oscillator, B the second: osc 1's are 2
			// and 3, osc 2's 1 and 3, osc 3's 1 and 2.
			OTHERS :: [OSCS][2]int{{1, 2}, {0, 2}, {0, 1}}
			others := OTHERS
			other := others[k][0] if p.warp == .Fm_A || p.warp == .Rm_A else others[k][1]
			srcbuf = {v.raw[other][0][:n], v.raw[other][1][:n]}
			mod = &srcbuf
		case .Fm_Sample, .Rm_Sample:
			srcbuf = {v.sample_raw[0][:n], v.sample_raw[1][:n]}
			mod = &srcbuf
		}
		raw := [2][]f32{v.raw[k][0][:n], v.raw[k][1][:n]}
		osc_render(&s.shared, &v.oscs[k], &p, inc_buf, mod, tmp[0], tmp[1], &raw, sr)
		route_source(s, Destination(int(value(s, osc_param(o, .Destination)))), tmp, f1, f2, dry, n)
	}
	if value(s, sample_param(.On)) > 0 {
		p := sample_params(s, v)
		key := base
		raw := [2][]f32{v.sample_raw[0][:n], v.sample_raw[1][:n]}
		sample_osc_render(&v.sample, &p, key, tmp[0], tmp[1], &raw, sr)
		route_source(s, Destination(int(value(s, sample_param(.Destination)))), tmp, f1, f2, dry, n)
	}
	// The filters: filter 2 takes filter 1's output too when in series.
	cut := s.scratch[7][3 * n:4 * n]
	serial := value(s, filter_param(2, .From_Filter)) > 0
	for k in 0 ..< FILTERS {
		fi := k + 1
		buf := f1 if k == 0 else f2
		if value(s, filter_param(fi, .On)) > 0 {
			p := filter_params(s, v, fi)
			c := p.cutoff + vvalue(s, v, filter_param(fi, .Keytrack)) * (v.pitch - 60)
			if !v.started do v.last_cut[k] = c
			for i in 0 ..< n do cut[i] = v.last_cut[k] + (c - v.last_cut[k]) * f32(i + 1) / f32(n)
			v.last_cut[k] = c
			filter_render(&v.filters[k], &p, cut, &buf, &buf, sr)
		}
		if k == 0 && serial {
			for ch in 0 ..< 2 do for i in 0 ..< n do f2[ch][i] += buf[ch][i]
		} else {
			for ch in 0 ..< 2 do for i in 0 ..< n do dry[ch][i] += buf[ch][i]
		}
	}
	// The amp envelope and velocity.
	for ch in 0 ..< 2 do for i in 0 ..< n do v.out[ch][i] = dry[ch][i] * amp[i] * vgain
	v.started = true
	if env_done(&v.envs[0]) do v.finished = true
}

// [rt] Adds a source's sound where it goes (both filters: half to each).
@(private)
route_source :: proc "contextless" (s: ^Synth, d: Destination, src, f1, f2, dry: [2][]f32, n: int) #no_bounds_check {
	for ch in 0 ..< 2 {
		switch d {
		case .Filter_1:     for i in 0 ..< n do f1[ch][i] += src[ch][i]
		case .Filter_2:     for i in 0 ..< n do f2[ch][i] += src[ch][i]
		case .Both_Filters: for i in 0 ..< n {
				f1[ch][i] += src[ch][i]
				f2[ch][i] += src[ch][i]
			}
		case .Effects, .Direct: for i in 0 ..< n do dry[ch][i] += src[ch][i]
		}
	}
}

// [rt] Works out every route for voice `v`: each destination's
// modulation, a side each.
@(private)
voice_mod :: proc "contextless" (s: ^Synth, v: ^Voice, envs: [ENVS]f32, lfos: [LFOS][2]f32) #no_bounds_check {
	for &side in v.mod do for &x in side do x = 0
	p := s.patch
	if p == nil do return
	for r in p.routes[:p.route_count] {
		if r.bypass || r.source == .None do continue
		spec := param_spec(r.dest)
		if spec == nil do continue
		idx := PARAM_INDEX[r.dest]
		vals := source_value(s, v, r.source, envs, lfos)
		span := spec.max - spec.min
		for side in 0 ..< 2 {
			x := vals[side]
			if r.bipolar do x = x * 2 - 1
			// The curve, kept symmetric for bipolar sources.
			if r.power != 0 {
				if r.bipolar do x = power_scale(abs(x), r.power) * (1 if x >= 0 else -1)
				else do x = power_scale(x, r.power)
			}
			amt := r.amount * span
			if r.stereo && side == 1 do amt = -amt
			v.mod[side][idx] += x * amt
		}
	}
}

// [rt] A source's value now for voice `v` (left, right).
@(private)
source_value :: proc "contextless" (s: ^Synth, v: ^Voice, src: Mod_Source, envs: [ENVS]f32, lfos: [LFOS][2]f32) -> [2]f32 {
	#partial switch src {
	case .Env_1 ..= .Env_6:
		e := envs[int(src) - int(Mod_Source.Env_1)]
		return {e, e}
	case .Lfo_1 ..= .Lfo_8:
		return lfos[int(src) - int(Mod_Source.Lfo_1)]
	case .Macro_1 ..= .Macro_4:
		m := s.values[int(global_param(.Macro_1)) + int(src) - int(Mod_Source.Macro_1)]
		return {m, m}
	case .Velocity:       return {v.velocity, v.velocity}
	case .Note:           x := v.pitch / 127; return {x, x}
	case .Note_In_Octave: x := math.mod(v.pitch, 12) / 12; return {x, x}
	case .Aftertouch:     x := s.values[global_param(.Aftertouch)]; return {x, x}
	case .Mod_Wheel:      x := s.values[global_param(.Mod_Wheel)]; return {x, x}
	case .Pitch_Wheel:    x := s.values[global_param(.Pitch_Wheel)]; return {x, x}
	case .Stereo:         return {1, -1}
	case .Random:         return {v.random, v.random}
	}
	return {}
}

// [rt] The newest voice, for a UI.
@(private)
live_update :: proc "contextless" (s: ^Synth) {
	newest: ^Voice
	count: i32 = 0
	for &v in s.voices do if v.on && !v.dying && !v.finished {
		count += 1
		if newest == nil || v.age > newest.age do newest = &v
	}
	s.live.voices = count
	s.live.sounding = newest != nil
	if newest == nil do return
	for i in 0 ..< ENVS {
		s.live.envs[i] = newest.envs[i].value
		s.live.env_stage[i] = i32(newest.envs[i].stage)
	}
	for i in 0 ..< LFOS {
		s.live.lfos[i] = newest.lfos[i].value[0]
		s.live.lfo_phase[i] = newest.lfos[i].phase
	}
	for i in 0 ..< OSCS do s.live.frames[i] = vvalue(s, newest, osc_param(i + 1, .Frame))
	for i in 0 ..< FILTERS do s.live.cutoffs[i] = newest.last_cut[i]
}

_ :: intrinsics.atomic_load
