/*
A sampler: notes play recorded sounds, pitched from a root key.

A `Sample_Map` is the instrument: zones, each a sample (a `stream.Source`
held in memory) with the keys and velocities it answers, its root key,
tuning, gain and optional loop. Build one with `sample_map_create`, then
give it to a sampler node, which plays the notes it receives with a
band-limited resampler per voice, an amp envelope, and per-note tuning,
volume and pan. Zones that match a note together all play (layers).

	zones := []sampler.Sample_Zone{
		{source = piano_c3, root_key = 48, key_hi = 54},
		{source = piano_f3, root_key = 53, key_lo = 55, key_hi = 127},
	}
	m, _ := sampler.sample_map_create(zones)
	node, s := sampler.sampler_create({})
	id, _ := graph.add_node(g, node, 0, 2)
	graph.connect_events(g, player, id)
	sampler.sampler_set_map(s, m)
	sampler.sample_map_release(m) // the sampler keeps its own reference

Samples must fit in memory: `stream.source_open` loads files up to the
streamer's `ram_bytes` (16 MB decoded by default) into memory; larger
ones play silent here.
*/
package sampler

import "base:intrinsics"
import "core:math"
import "core:mem"

import "fire:core"
import "fire:dsp"
import "fire:rt"
import "fire:stream"

// One sample of an instrument and when it plays.
Sample_Zone :: struct {
	source:     ^stream.Source, // in memory (the map retains it)
	root_key:   u8,  // the key at which it plays at its own pitch
	key_lo:     u8,  // the keys it answers, inclusive (0 and 0 = every key)
	key_hi:     u8,
	vel_lo:     f32, // the velocities it answers, inclusive (0 and 0 = all)
	vel_hi:     f32,
	tune_cents: f64,
	gain_db:    f64,
	start:      i64, // first frame played
	end:        i64, // one past the last; 0 = the end of the file
	loop:       bool, // loop from `loop_start` to `loop_end` while it sounds
	loop_start: i64,
	loop_end:   i64, // 0 = `end`
	one_shot:   bool, // plays to its end whatever the note-off (drums)
	loop_mode:  Loop_Mode, // how a loop repeats
	crossfade:  i64,  // forward loops: frames before the loop end blended into those before the start (0 = a plain jump)
	reverse:    bool, // plays from the end back to the start (loop points mirrored with it)
	pan:        f64,  // -1 (left) .. 1 (right)
}

// How a zone's loop repeats.
Loop_Mode :: enum u8 {
	Forward,   // jumps back to the loop start
	Ping_Pong, // plays the loop forward, then backward, and so on
}

// An immutable set of zones: the instrument. From `sample_map_create`;
// release with `sample_map_release`. Read its zones freely, never change
// them (the audio thread reads them).
Sample_Map :: struct {
	zones:     []Sample_Zone,
	refs:      int, // control thread
	allocator: mem.Allocator,
}

// Control thread. Makes a map of `zones` (copied; each source retained),
// with one reference held by the caller. `.Invalid_Argument` for a zone
// with no source or a range that doesn't fit its file.
sample_map_create :: proc(zones: []Sample_Zone, allocator := context.allocator) -> (m: ^Sample_Map, err: core.Error) {
	for z in zones {
		if z.source == nil do return nil, .Invalid_Argument
		frames := stream.source_info(z.source).frames
		end := z.end if z.end > 0 else frames
		if z.start < 0 || end > frames || z.start >= end do return nil, .Invalid_Argument
		if z.loop {
			le := z.loop_end if z.loop_end > 0 else end
			if z.loop_start < z.start || le > end || le - z.loop_start < 2 do return nil, .Invalid_Argument
		}
		if z.crossfade < 0 || z.pan < -1 || z.pan > 1 do return nil, .Invalid_Argument
	}
	m = new(Sample_Map, allocator)
	if m == nil do return nil, .Out_Of_Memory
	m.allocator, m.refs = allocator, 1
	ae: mem.Allocator_Error
	m.zones, ae = make([]Sample_Zone, len(zones), allocator)
	if ae != nil {
		free(m, allocator)
		return nil, .Out_Of_Memory
	}
	for z, i in zones {
		zz := z
		frames := stream.source_info(z.source).frames
		if zz.end <= 0 do zz.end = frames
		if zz.loop_end <= 0 do zz.loop_end = zz.end
		if zz.key_lo == 0 && zz.key_hi == 0 do zz.key_hi = 127
		if zz.vel_lo == 0 && zz.vel_hi == 0 do zz.vel_hi = 1
		// A crossfade fits in the loop and in what comes before it.
		zz.crossfade = min(zz.crossfade, zz.loop_end - zz.loop_start, zz.loop_start - zz.start)
		stream.source_retain(z.source)
		m.zones[i] = zz
	}
	return m, .None
}

// Control thread. Adds a reference.
sample_map_retain :: proc(m: ^Sample_Map) {
	if m != nil do m.refs += 1
}

// Control thread. Drops a reference; the last frees the map and releases
// its sources.
sample_map_release :: proc(m: ^Sample_Map) {
	if m == nil do return
	m.refs -= 1
	if m.refs > 0 do return
	for z in m.zones do stream.source_release(z.source)
	delete(m.zones, m.allocator)
	free(m, m.allocator)
}

// How a sampler voice reads between a sample's frames when it plays it at
// another pitch.
Sampler_Quality :: enum u8 {
	Cubic,       // 4-point Hermite: cheap; pitched up, some aliasing
	Sinc_Low,    // band-limited (`dsp.Resampler` at Low): no audible aliasing, about 10× the cost
	Sinc_Medium,
	Sinc_High,
}

// Settings for `sampler_create`.
Sampler_Settings :: struct {
	voices:  int, // 0 = 32
	quality: Sampler_Quality, // default Cubic
}

// Parameter id of the amp envelope's attack, in seconds (0.0005..10, default 0.001).
SAMPLER_PARAM_ATTACK :: core.Param_Id(1)
// Parameter id of the amp envelope's decay, in seconds (0.005..10, default 1).
SAMPLER_PARAM_DECAY :: core.Param_Id(2)
// Parameter id of the amp envelope's sustain, in percent (0..100, default 100).
SAMPLER_PARAM_SUSTAIN :: core.Param_Id(3)
// Parameter id of the amp envelope's release, in seconds (0.005..20, default 0.2).
SAMPLER_PARAM_RELEASE :: core.Param_Id(4)
// Parameter id of the velocity sensitivity, in percent (0..100, default 80).
SAMPLER_PARAM_VELOCITY :: core.Param_Id(5)
// Parameter id of the output gain, in dB (−60..12, default 0).
SAMPLER_PARAM_GAIN_DB :: core.Param_Id(6)
// Parameter id of a transposition of every note, in semitones (−48..48, default 0).
SAMPLER_PARAM_TRANSPOSE :: core.Param_Id(7)

// Parameter table of the sampler node, as returned by `node_params`. Read-only.
sampler_params := [?]core.Param_Info {
	{id = SAMPLER_PARAM_ATTACK, name = "Attack", min = 0.0005, max = 10, default = 0.001, flags = {.Automatable}},
	{id = SAMPLER_PARAM_DECAY, name = "Decay", min = 0.005, max = 10, default = 1, flags = {.Automatable}},
	{id = SAMPLER_PARAM_SUSTAIN, name = "Sustain", unit = .Percent, min = 0, max = 100, default = 100, flags = {.Automatable}},
	{id = SAMPLER_PARAM_RELEASE, name = "Release", min = 0.005, max = 20, default = 0.2, flags = {.Automatable}},
	{id = SAMPLER_PARAM_VELOCITY, name = "Velocity", unit = .Percent, min = 0, max = 100, default = 80, flags = {.Automatable}},
	{id = SAMPLER_PARAM_GAIN_DB, name = "Gain", unit = .Decibels, min = -60, max = 12, default = 0, smoothing = .Linear, smoothing_ms = 20, flags = {.Automatable}},
	{id = SAMPLER_PARAM_TRANSPOSE, name = "Transpose", unit = .Semitones, min = -48, max = 48, default = 0, flags = {.Automatable, .Stepped}},
}

// The fastest a voice plays its sample (two octaves up at equal rates).
MAX_SPEED :: 4.0

// A sampler node's state. From `sampler_create`; the node owns it. Procs
// not marked [rt] are for the control thread. Fields are internal.
Sampler :: struct {
	settings:    Sampler_Settings,
	voices:      []Sampler_Voice,
	params:      [len(sampler_params)]f64,
	gain:        dsp.Smoothed_Value, // dB
	current:     ^Sample_Map, // audio side
	old:         ^Sample_Map, // audio side: replaced, still sounding
	pending:     rt.Spsc_Queue(^Sample_Map), // control → audio
	retired:     rt.Spsc_Queue(^Sample_Map), // audio → control
	latest:      ^Sample_Map, // control side: the last one set
	scratch:     [2][]f32, // gathered input of one voice
	mixed:       [2][]f32, // one voice's output
	sample_rate: f64,
	max_block:   int,
	clock:       u64,
	allocator:   mem.Allocator,
}

@(private)
Sampler_Voice :: struct {
	on:         bool,
	map_:       ^Sample_Map,
	zone:       ^Sample_Zone,
	id:         core.Note_Id,
	channel:    u8,
	key:        u8,
	started:    u64,
	velocity:   f64,
	pos:        i64, // Sinc: next sample frame to feed the resampler
	phase:      f64, // Cubic: the read position in sample frames
	mono:       dsp.Resampler, // Sinc: for one-channel samples
	stereo:     dsp.Resampler, // Sinc: for the rest
	amp:        dsp.Adsr,
	tuning:     f64, // semitones, from expression
	volume:     f64,
	pan:        f64,
	held:       bool, // the note is down (a released one stops looping)
	tail:       int,  // frames fed after the sample's end; the voice ends once the resampler has drained
}

@(private)
sampler_vtable := core.Node_VTable {
	prepare = sampler_prepare,
	process = sampler_process,
	reset   = proc(self: rawptr) {
		s := (^Sampler)(self)
		for &v in s.voices do v.on = false
	},
	release = sampler_release,
	params  = proc(self: rawptr) -> []core.Param_Info { return sampler_params[:] },
	destroy = proc(self: rawptr, allocator: mem.Allocator) { sampler_free((^Sampler)(self)) },
	type_id = SAMPLER_TYPE_ID,
	state_version = 1,
	save    = save_sampler,
}

// Control thread. Makes a sampler node (no audio inputs, stereo out; mono
// with one output) with no map yet: it is silent until `sampler_set_map`.
sampler_create :: proc(settings: Sampler_Settings, allocator := context.allocator) -> (node: core.Node, s: ^Sampler) {
	s = new(Sampler, allocator)
	s.settings, s.allocator = settings, allocator
	if s.settings.voices <= 0 do s.settings.voices = 32
	for p in sampler_params do s.params[p.id - 1] = p.default
	rt.spsc_init(&s.pending, 8, allocator)
	rt.spsc_init(&s.retired, 16, allocator)
	return core.node_make(&sampler_vtable, s, allocator), s
}

// Control thread. Plays `m` from the next block (nil: silence). Notes
// already sounding finish on the old map, which is released once they
// have. The sampler takes its own reference.
sampler_set_map :: proc(s: ^Sampler, m: ^Sample_Map) -> core.Error {
	sampler_collect(s)
	sample_map_retain(m)
	if !rt.spsc_push(&s.pending, m) {
		sample_map_release(m)
		return .Out_Of_Memory
	}
	s.latest = m
	return .None
}

// Releases the maps the audio thread has finished with.
@(private)
sampler_collect :: proc(s: ^Sampler) {
	for m in rt.spsc_pop(&s.retired) do sample_map_release(m)
}

@(private)
sampler_prepare :: proc(self: rawptr, cfg: core.Prepare_Config, allocator: mem.Allocator) -> core.Error {
	s := (^Sampler)(self)
	s.sample_rate, s.max_block = cfg.sample_rate, cfg.max_block
	max_input := int(f64(cfg.max_block) * MAX_SPEED) + 64
	ae: mem.Allocator_Error
	s.voices, ae = make([]Sampler_Voice, s.settings.voices, allocator)
	for c in 0 ..< 2 {
		if ae == nil do s.scratch[c], ae = make([]f32, max_input, allocator)
		if ae == nil do s.mixed[c], ae = make([]f32, cfg.max_block, allocator)
	}
	if ae != nil {
		sampler_release(s, allocator)
		return .Out_Of_Memory
	}
	if s.settings.quality != .Cubic {
		q := dsp.Resampler_Quality(int(s.settings.quality) - 1)
		for &v in s.voices {
			err := dsp.resampler_init(&v.mono, 1, q, MAX_SPEED, max_input, allocator)
			if err == .None do err = dsp.resampler_init(&v.stereo, 2, q, MAX_SPEED, max_input, allocator)
			if err != .None {
				sampler_release(s, allocator)
				return err
			}
		}
	}
	dsp.smoothed_init(&s.gain, s.params[SAMPLER_PARAM_GAIN_DB - 1], .Linear, 20, cfg.sample_rate)
	return .None
}

@(private)
sampler_release :: proc(self: rawptr, allocator: mem.Allocator) {
	s := (^Sampler)(self)
	for &v in s.voices {
		dsp.resampler_destroy(&v.mono, allocator)
		dsp.resampler_destroy(&v.stereo, allocator)
	}
	delete(s.voices, allocator)
	for c in 0 ..< 2 {
		delete(s.scratch[c], allocator)
		delete(s.mixed[c], allocator)
	}
	s.voices = nil
	s.scratch, s.mixed = {}, {}
}

@(private)
sampler_free :: proc(s: ^Sampler) {
	for m in rt.spsc_pop(&s.pending) do sample_map_release(m)
	sampler_collect(s)
	sample_map_release(s.current)
	sample_map_release(s.old)
	rt.spsc_destroy(&s.pending, s.allocator)
	rt.spsc_destroy(&s.retired, s.allocator)
	free(s, s.allocator)
}

// --- the audio side ----------------------------------------------------------------------

// [rt]
@(private)
sampler_process :: proc(self: rawptr, ctx: ^core.Process_Context) {
	s := (^Sampler)(self)
	adopt(s)
	pos := 0
	for e in ctx.events_in {
		sampler_render(s, ctx, pos, int(e.offset))
		pos = int(e.offset)
		#partial switch ev in e.payload {
		case core.Note_On:  note_on(s, ev)
		case core.Note_Off: for &v in s.voices do if v.on && v.held && same(&v, ev.id, ev.channel, ev.key) do note_off(&v)
		case core.Note_Choke: for &v in s.voices do if v.on && same(&v, ev.id, ev.channel, ev.key) do choke(s, &v)
		case core.Note_Expression:
			for &v in s.voices do if v.on && same(&v, ev.id, ev.channel, ev.key) {
				#partial switch ev.kind {
				case .Tuning: v.tuning = clamp(ev.value, -48, 48)
				case .Volume: v.volume = clamp(ev.value, 0, 4)
				case .Pan:    v.pan = clamp(ev.value, 0, 1)
				}
			}
		case core.Param_Value, core.Param_Ramp:
			id, value, frames, ok := dsp_param(e.payload)
			if !ok || id < 1 || int(id) > len(sampler_params) do continue
			p := sampler_params[id - 1]
			s.params[id - 1] = clamp(value, p.min, p.max)
			if id == SAMPLER_PARAM_GAIN_DB do dsp.smoothed_apply(&s.gain, s.params[id - 1], frames)
		}
	}
	sampler_render(s, ctx, pos, ctx.frames)
	// The replaced map, once nothing plays from it, goes back to be released.
	if s.old != nil {
		busy := false
		for v in s.voices do busy ||= v.on && v.map_ == s.old
		if !busy && rt.spsc_push(&s.retired, s.old) do s.old = nil
	}
}

// [rt] Takes the newest map set, unless the last replacement is still
// sounding: the current one becomes `old` until its notes end. Maps set
// in a burst and never played go straight back.
@(private)
adopt :: proc "contextless" (s: ^Sampler) {
	if s.old != nil do return
	newest: ^Sample_Map
	got := false
	for m in rt.spsc_pop(&s.pending) {
		if got && newest != nil do rt.spsc_push(&s.retired, newest) // fits: retired outsizes pending
		newest, got = m, true
	}
	if !got do return
	s.old, s.current = s.current, newest
}

@(private)
dsp_param :: proc "contextless" (p: core.Event_Payload) -> (id: core.Param_Id, value: f64, frames: int, ok: bool) {
	#partial switch v in p {
	case core.Param_Value: return v.param, v.value, -1, true
	case core.Param_Ramp:  return v.param, v.target, int(v.frames), true
	}
	return
}

@(private)
same :: #force_inline proc "contextless" (v: ^Sampler_Voice, id: core.Note_Id, channel, key: u8) -> bool {
	if v.id != core.NOTE_ID_ANY && id != core.NOTE_ID_ANY do return v.id == id
	return v.channel == channel && v.key == key
}

// [rt] Starts a voice for every zone of the current map that matches.
@(private)
note_on :: proc "contextless" (s: ^Sampler, ev: core.Note_On) {
	m := s.current
	if m == nil do return
	for &z in m.zones {
		if ev.key < z.key_lo || ev.key > z.key_hi || ev.velocity < z.vel_lo || ev.velocity > z.vel_hi do continue
		v := &s.voices[pick_voice(s)]
		s.clock += 1
		sens := s.params[SAMPLER_PARAM_VELOCITY - 1] * 0.01
		v^ = {
			on = true, map_ = m, zone = &z, id = ev.id, channel = ev.channel, key = ev.key, started = s.clock,
			velocity = (1 - sens + sens * f64(ev.velocity)) * math.pow(10, z.gain_db / 20),
			pos = z.start, phase = f64(z.start), mono = v.mono, stereo = v.stereo, volume = 1, pan = 0.5 + 0.5 * z.pan, held = true,
		}
		if s.settings.quality != .Cubic {
			dsp.resampler_reset(&v.mono)
			dsp.resampler_reset(&v.stereo)
		}
		dsp.adsr_set(&v.amp, s.params[SAMPLER_PARAM_ATTACK - 1], s.params[SAMPLER_PARAM_DECAY - 1], s.params[SAMPLER_PARAM_SUSTAIN - 1] * 0.01, s.params[SAMPLER_PARAM_RELEASE - 1], s.sample_rate)
		dsp.adsr_gate(&v.amp, true)
	}
}

// [rt] A free voice, else the quietest releasing one, else the oldest.
@(private)
pick_voice :: proc "contextless" (s: ^Sampler) -> int {
	for v, i in s.voices do if !v.on do return i
	pick := 0
	for v, i in s.voices {
		q := s.voices[pick]
		releasing, best := v.amp.stage == .Release, q.amp.stage == .Release
		if releasing != best {
			if releasing do pick = i
		} else if releasing ? v.amp.level < q.amp.level : v.started < q.started {
			pick = i
		}
	}
	return pick
}

// [rt]
@(private)
note_off :: proc "contextless" (v: ^Sampler_Voice) {
	v.held = false
	if !v.zone.one_shot do dsp.adsr_gate(&v.amp, false)
}

// [rt] Fades a voice out over CHOKE_SECONDS, one-shot or not.
@(private)
choke :: proc "contextless" (s: ^Sampler, v: ^Sampler_Voice) {
	v.held = false
	dsp.adsr_set(&v.amp, v.amp.attack_s, v.amp.decay_s, v.amp.sustain, CHOKE_SECONDS, s.sample_rate)
	dsp.adsr_gate(&v.amp, false)
}

// How long a choked voice takes to fade out.
CHOKE_SECONDS :: 0.003

// [rt]
@(private)
sampler_render :: proc(s: ^Sampler, ctx: ^core.Process_Context, from, to: int) {
	n := to - from
	if n <= 0 do return
	outs := len(ctx.outputs)
	for c in 0 ..< outs do for i in from ..< to do ctx.outputs[c][i] = 0
	gain0 := s.gain
	for &v in s.voices {
		if !v.on do continue
		s.gain = gain0 // every voice sees the same gain ramp
		render_voice(s, &v, n)
		l, r := math.cos(v.pan * math.PI / 2), math.sin(v.pan * math.PI / 2)
		for i in 0 ..< n {
			k := dsp.adsr_next(&v.amp) * v.velocity * v.volume * dsp.db_to_gain(dsp.smoothed_next(&s.gain))
			if outs == 1 {
				ctx.outputs[0][from + i] += f32(k * 0.5 * (f64(s.mixed[0][i]) + f64(s.mixed[1][i])))
			} else if outs >= 2 {
				ctx.outputs[0][from + i] += f32(k * l * math.SQRT_TWO * f64(s.mixed[0][i]))
				ctx.outputs[1][from + i] += f32(k * r * math.SQRT_TWO * f64(s.mixed[1][i]))
			}
		}
		if v.amp.stage == .Idle || v.tail > 512 do v.on = false
	}
	if !has_voices(s) do for _ in 0 ..< n do dsp.smoothed_next(&s.gain)
}

@(private)
has_voices :: proc "contextless" (s: ^Sampler) -> bool {
	for v in s.voices do if v.on do return true
	return false
}

// [rt] Renders `n` frames of a voice into `s.mixed` (left, right), at its pitch.
@(private)
render_voice :: proc(s: ^Sampler, v: ^Sampler_Voice, n: int) {
	z := v.zone
	frames := stream.source_frames(z.source)
	info := stream.source_info(z.source)
	semis := f64(v.key) - f64(z.root_key) + z.tune_cents / 100 + v.tuning + s.params[SAMPLER_PARAM_TRANSPOSE - 1]
	speed := min(math.pow(2, semis / 12) * info.sample_rate / s.sample_rate, MAX_SPEED)
	if s.settings.quality == .Cubic {
		render_cubic(s, v, frames, n, speed)
	} else {
		render_sinc(s, v, frames, n, speed)
	}
}

// [rt] Frame `k` of the zone as a voice plays it. `k` counts frames played
// from the zone's start and never wraps; the zone's loop (forward or
// ping-pong), crossfade and direction map it onto the sample. Outside the
// sample there is silence.
@(private)
frame_at :: #force_inline proc "contextless" (z: ^Sample_Zone, data: []f32, k: i64) -> f32 #no_bounds_check {
	if k < z.start do return 0
	// Reversed, the zone is read mirrored, and so are its loop points.
	ls, le := z.loop_start, z.loop_end
	if z.reverse do ls, le = z.start + z.end - z.loop_end, z.start + z.end - z.loop_start
	idx := k
	if z.loop && k >= le {
		span := le - ls
		switch z.loop_mode {
		case .Forward:
			idx = ls + (k - ls) % span
		case .Ping_Pong:
			// Back from le-2 to ls, forward from ls+1 to le-1, and again: each
			// end frame once per turn.
			if span < 2 do break
			turn := span - 1
			q := (k - le) % (2 * turn)
			idx = le - 2 - q if q < turn else ls + 1 + (q - turn)
		}
	} else if k >= z.end {
		return 0
	}
	x := read_frame(z, data, idx)
	// A crossfaded loop: on the way to the loop end, fade into the frames
	// that lead into the loop start, so the jump back is seamless.
	if z.loop && z.loop_mode == .Forward && z.crossfade > 0 && idx >= le - z.crossfade && idx < le {
		w := f32(idx - (le - z.crossfade) + 1) / f32(z.crossfade + 1)
		x = (1 - w) * x + w * read_frame(z, data, idx - (le - ls))
	}
	return x
}

// [rt] Frame `idx` of the zone (in the direction it plays).
@(private)
read_frame :: #force_inline proc "contextless" (z: ^Sample_Zone, data: []f32, idx: i64) -> f32 #no_bounds_check {
	j := z.start + z.end - 1 - idx if z.reverse else idx
	return data[j] if j >= z.start && j < z.end else 0
}

// [rt] 4-point Hermite interpolation straight from the sample.
@(private)
render_cubic :: proc(s: ^Sampler, v: ^Sampler_Voice, frames: [][]f32, n: int, speed: f64) #no_bounds_check {
	z := v.zone
	if frames == nil {
		for c in 0 ..< 2 do for i in 0 ..< n do s.mixed[c][i] = 0
		return
	}
	stereo := len(frames) > 1
	for i in 0 ..< n {
		k := i64(math.floor(v.phase))
		t := f32(v.phase - f64(k))
		for c in 0 ..< (2 if stereo else 1) {
			d := frames[c]
			xm1, x0, x1, x2 := frame_at(z, d, k - 1), frame_at(z, d, k), frame_at(z, d, k + 1), frame_at(z, d, k + 2)
			c1 := 0.5 * (x1 - xm1)
			c2 := xm1 - 2.5 * x0 + 2 * x1 - 0.5 * x2
			c3 := 0.5 * (x2 - xm1) + 1.5 * (x0 - x1)
			s.mixed[c][i] = ((c3 * t + c2) * t + c1) * t + x0
		}
		if !stereo do s.mixed[1][i] = s.mixed[0][i]
		v.phase += speed
		if !z.loop && v.phase >= f64(z.end) + 2 do v.tail = 1 << 20 // past the end: done (a loop plays through the release too)
	}
}

// [rt] Band-limited: gathers the frames the resampler needs (looping, and
// silence past the end), then resamples, with one channel for mono samples.
@(private)
render_sinc :: proc(s: ^Sampler, v: ^Sampler_Voice, frames: [][]f32, n: int, speed: f64) #no_bounds_check {
	z := v.zone
	channels := 1 if frames != nil && len(frames) == 1 else 2
	r := &v.mono if channels == 1 else &v.stereo
	need := min(dsp.resampler_input_needed(r, n, speed), len(s.scratch[0]))
	for i in 0 ..< need {
		for c in 0 ..< channels do s.scratch[c][i] = frame_at(z, frames[c], v.pos) if frames != nil else 0
		if frames == nil || (!z.loop && v.pos >= z.end) do v.tail += 1
		v.pos += 1 // never wraps: frame_at maps loops (which play through the release too)
	}
	in_ := [2][]f32{s.scratch[0][:need], s.scratch[1][:need]}
	out := [2][]f32{s.mixed[0][:n], s.mixed[1][:n]}
	_, produced := dsp.resampler_process(r, in_[:channels], out[:channels], speed)
	for c in 0 ..< channels do for i in produced ..< n do out[c][i] = 0
	if channels == 1 do copy(out[1], out[0])
}
