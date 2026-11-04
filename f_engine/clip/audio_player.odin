package clip

import "base:intrinsics"
import "core:math"
import "core:mem"

import "fire:core"
import "fire:dsp"
import "fire:rt"
import "fire:stream"
import tb "fire:timebase"

// Settings for `audio_player_create`. Start from `default_audio_player_settings`.
Audio_Player_Settings :: struct {
	timeline:  core.Timeline_Id,
	streamer:  ^stream.Streamer,       // reads the clips' sources
	channels:  int,                    // the node's output channels
	quality:   dsp.Resampler_Quality,  // for rate conversion and repitching
	max_speed: f64,                    // fastest playback (source frames per output frame), ≥ 1
	stretcher: ^Stretcher_VTable,      // for `.Stretch` clips (e.g. `&stretch.signalsmith`); nil: they are refused
}

// Stereo out, Medium resampling, up to 4× speed.
default_audio_player_settings :: proc(timeline: core.Timeline_Id, streamer: ^stream.Streamer) -> Audio_Player_Settings {
	return {timeline = timeline, streamer = streamer, channels = 2, quality = .Medium, max_speed = 4}
}

// Plays an `Audio_Clip` on a timeline, as a graph node with `channels`
// audio outputs (no inputs). Uses the same `Placement`s as MIDI clips.
//
// - Converts the source's sample rate to the device's, and in `.Repitch`
//   mode follows the tempo (and timeline rate) by playing faster or slower.
//   A small continuous correction keeps it locked to the timeline through
//   tempo changes, with no seeking.
// - Loops are seamless: the resampler is fed audio that already wraps at
//   the loop points.
// - Never clicks: starts fade in, and stops and jumps crossfade over
//   `DECLICK_FRAMES`.
// - Reads through `fire:stream`: jumps to the clip start, its loop start and
//   the placement's offset are instant; others are silent until the disk
//   delivers (see `audio_player_ready`).
//
// Mono sources play on every output; with a mono output, channels are
// averaged; otherwise channel c plays on output c. Fields are internal.
Audio_Player :: struct {
	settings:    Audio_Player_Settings,
	allocator:   mem.Allocator,
	// Control thread.
	live:        [dynamic]^Audio_Config,
	latest:      ^Audio_Config,
	// Control → audio, and back.
	pending:     ^Audio_Config, // atomic
	retired:     rt.Spsc_Queue(^Audio_Config),
	// Audio thread.
	config:      ^Audio_Config,
	sample_rate: f64, // the device's, from prepare
	active:      bool,
	out_pos:     f64, // source frame of the next output frame
	in_pos:      i64, // source frame of the next input frame
	speed:       f64, // last speed used
	// Stretch mode.
	stretch_rate:  f64, // stretcher input per output frame, last chunk
	stretch_carry: f64, // fraction of an input frame owed to the next chunk
}

// Frames over which starts fade in and stops and jumps crossfade.
DECLICK_FRAMES :: 128

// Output frames rendered per step.
@(private)
AUDIO_CHUNK :: 256

// Everything one clip needs while playing, made on the control thread.
@(private)
Audio_Config :: struct {
	clip:      ^Audio_Clip,
	placement: Placement,
	stream:    ^stream.Stream,
	resampler: dsp.Resampler,
	input:     [][]f32, // per source channel: resampler input
	rendered:  [][]f32, // per source channel: AUDIO_CHUNK resampled frames
	views:     [][]f32, // scratch slice headers
	views2:    [][]f32,
	// Stretch mode: the stretcher, and the device-rate audio it is fed.
	stretcher: rawptr,
	stage:     [][]f32,
	views3:    [][]f32,
	input_latency, output_latency: int,
}

// Control thread. Creates a player node and a handle for controlling it;
// the handle stays valid until the graph destroys the node. Add it with
// `graph.add_node(g, node, 0, settings.channels)`.
audio_player_create :: proc(settings: Audio_Player_Settings, allocator := context.allocator) -> (node: core.Node, player: ^Audio_Player) {
	p := new(Audio_Player, allocator)
	p.settings, p.allocator = settings, allocator
	p.settings.channels = max(p.settings.channels, 1)
	if !(p.settings.max_speed >= 1) do p.settings.max_speed = 4
	p.live = make([dynamic]^Audio_Config, allocator)
	return core.node_make(&audio_player_vtable, p, allocator), p
}

// Control thread. Plays `clip` (nil: nothing) placed as `placement`, from
// the player's next block; the switch crossfades. Allocates the clip's
// stream (with cues at the clip's start, its loop start and the placement's
// start), resampler and (for `.Stretch`) stretcher now. Keeps its own
// reference to the clip. A `.Stretch` clip needs `settings.stretcher`, one
// with `set_transpose` if the clip has a `transpose` (`.Unsupported` otherwise) and a prepared node (`.Invalid_State`: add it
// to the graph first).
audio_player_set :: proc(p: ^Audio_Player, clip: ^Audio_Clip, placement: Placement) -> core.Error {
	audio_collect(p)
	cfg := new(Audio_Config, p.allocator)
	if cfg == nil do return .Out_Of_Memory
	cfg^ = {clip = clip, placement = placement}
	if clip != nil {
		if err := audio_config_init(p, cfg); err != .None {
			audio_config_free(p, cfg)
			return err
		}
		audio_clip_retain(clip)
	}
	append(&p.live, cfg)
	p.latest = cfg
	old := intrinsics.atomic_exchange(&p.pending, cfg)
	if old != nil do audio_retire(p, old) // never adopted
	return .None
}

// Control thread. Whether the clip given to the last `audio_player_set` can
// start without a dropout (its stream's start and cues are buffered). Poll
// it before a quantized launch.
audio_player_ready :: proc(p: ^Audio_Player) -> bool {
	if p.latest == nil || p.latest.clip == nil do return true
	return stream.stream_ready(p.latest.stream)
}

@(private)
audio_config_init :: proc(p: ^Audio_Player, cfg: ^Audio_Config) -> core.Error {
	c := cfg.clip
	a := p.allocator
	cue_offset := c.start + i64(f64(cfg.placement.offset) * frames_per_beat(c, c.bpm if c.bpm > 0 else 120))
	cues := [3]i64{c.start, c.loop_start, clamp(cue_offset, c.start, c.end - 1)}
	st, serr := stream.stream_create(p.settings.streamer, c.source, cues = cues[:], start = c.start)
	if serr != .None do return .Out_Of_Memory
	cfg.stream = st
	max_input := int(f64(AUDIO_CHUNK) * p.settings.max_speed) + 2048 // plus the filter's reach
	if c.mode == .Stretch {
		vt := p.settings.stretcher
		if vt == nil || (c.transpose != 0 && vt.set_transpose == nil) do return .Unsupported
		if p.sample_rate == 0 do return .Invalid_State
		rate_speed := c.sample_rate / p.sample_rate
		if rate_speed > p.settings.max_speed do return .Unsupported
		max_rate := p.settings.max_speed / rate_speed
		cfg.stretcher = vt.create(c.channels, p.sample_rate, max_rate)
		if cfg.stretcher == nil do return .Out_Of_Memory
		if c.transpose != 0 do vt.set_transpose(cfg.stretcher, c.transpose)
		cfg.input_latency, cfg.output_latency = vt.input_latency(cfg.stretcher), vt.output_latency(cfg.stretcher)
		// Room for a seek's priming, or a chunk at the fastest rate plus a
		// latency change.
		stage := cfg.input_latency + int(max_rate * f64(cfg.output_latency)) + int(max_rate * AUDIO_CHUNK) + 64
		cfg.stage = make([][]f32, c.channels, a)
		cfg.views3 = make([][]f32, c.channels, a)
		for &b in cfg.stage do b = make([]f32, stage, a)
		max_input = max(max_input, int(f64(stage) * rate_speed) + 2048)
	}
	dsp.resampler_init(&cfg.resampler, c.channels, p.settings.quality, p.settings.max_speed, max_input, a) or_return
	cfg.input = make([][]f32, c.channels, a)
	cfg.rendered = make([][]f32, c.channels, a)
	cfg.views = make([][]f32, c.channels, a)
	cfg.views2 = make([][]f32, c.channels, a)
	for ch in 0 ..< c.channels {
		cfg.input[ch] = make([]f32, max_input, a)
		cfg.rendered[ch] = make([]f32, AUDIO_CHUNK, a)
	}
	return .None
}

@(private)
audio_config_free :: proc(p: ^Audio_Player, cfg: ^Audio_Config) {
	a := p.allocator
	if cfg.stream != nil do stream.stream_destroy(cfg.stream)
	if cfg.resampler.buf != nil do dsp.resampler_destroy(&cfg.resampler, a)
	for b in cfg.input do delete(b, a)
	for b in cfg.rendered do delete(b, a)
	delete(cfg.input, a)
	delete(cfg.rendered, a)
	delete(cfg.views, a)
	delete(cfg.views2, a)
	if cfg.stretcher != nil do p.settings.stretcher.destroy(cfg.stretcher)
	for b in cfg.stage do delete(b, a)
	delete(cfg.stage, a)
	delete(cfg.views3, a)
	free(cfg, a)
}

@(private)
audio_collect :: proc(p: ^Audio_Player) {
	if p.retired.buffer == nil do return
	for cfg in rt.spsc_pop(&p.retired) do audio_retire(p, cfg)
}

@(private)
audio_retire :: proc(p: ^Audio_Player, cfg: ^Audio_Config) {
	for c, i in p.live do if c == cfg {
		unordered_remove(&p.live, i)
		break
	}
	if p.latest == cfg do p.latest = nil
	audio_clip_release(cfg.clip)
	audio_config_free(p, cfg)
}

@(private)
audio_player_vtable := core.Node_VTable {
	prepare = proc(self: rawptr, cfg: core.Prepare_Config, a: mem.Allocator) -> core.Error {
		p := (^Audio_Player)(self)
		p.sample_rate = cfg.sample_rate
		if rt.spsc_init(&p.retired, 64, a) != nil do return .Out_Of_Memory
		return .None
	},
	release = proc(self: rawptr, a: mem.Allocator) {
		p := (^Audio_Player)(self)
		rt.spsc_destroy(&p.retired, a)
	},
	reset = proc(self: rawptr) {
		(^Audio_Player)(self).active = false
	},
	process = audio_player_process,
	destroy = proc(self: rawptr, a: mem.Allocator) {
		p := (^Audio_Player)(self)
		for cfg in p.live {
			audio_clip_release(cfg.clip)
			audio_config_free(p, cfg)
		}
		delete(p.live)
		free(p, a)
	},
}

// --- audio thread ------------------------------------------------------------------------------

// [rt]
@(private)
audio_player_process :: proc(self: rawptr, ctx: ^core.Process_Context) {
	p := (^Audio_Player)(self)
	for out in ctx.outputs do for &s in out[:ctx.frames] do s = 0
	if ctx.frames <= 0 do return

	// A new clip: fade the old one out, then start the new one fresh.
	if intrinsics.atomic_load(&p.pending) != nil && rt.spsc_len(&p.retired) < rt.spsc_capacity(&p.retired) {
		cfg := intrinsics.atomic_exchange(&p.pending, nil)
		if cfg != nil {
			if p.active && p.config != nil && p.config.clip != nil do tail(p, ctx)
			if p.config != nil do rt.spsc_push(&p.retired, p.config)
			p.config = cfg
			p.active = false
		}
	}
	cfg := p.config
	t := ctx.transport
	tl := core.transport_timeline(t, p.settings.timeline) if t != nil else nil
	if cfg == nil || cfg.clip == nil || tl == nil || !tl.playing {
		if p.active do tail(p, ctx)
		p.active = false
		return
	}
	c := cfg.clip
	pl := cfg.placement
	frames := ctx.frames

	// Where the placement starts and ends in this call.
	region_end := pl.at + pl.length if pl.length > 0 else tb.Beats(math.F64_MAX)
	if tl.position >= region_end {
		if p.active do tail(p, ctx)
		p.active = false
		return
	}
	start := core.timeline_offset_of(t, tl, pl.at)
	if start >= frames {
		if p.active do tail(p, ctx)
		p.active = false
		return
	}
	stop := core.timeline_offset_of(t, tl, region_end) if pl.length > 0 else max(int)

	// Speed. Original: the source's own rate. Repitch: whatever covers, in
	// source frames, exactly the beats the timeline moves through by the
	// end of this call (so tempo ramps inside a call are followed too).
	speed := c.sample_rate / p.sample_rate
	fresh := !p.active || start > 0 || .Jumped in tl.flags || .Started in tl.flags
	drift := 0.0
	if !fresh {
		target, inside := source_position(cfg, tl.position, t.tempo_bpm)
		if !inside {
			if p.active do tail(p, ctx)
			p.active = false
			return
		}
		if c.mode != .Original {
			// Correct any drift as well, or jump if it is too far off (an
			// edited tempo map, say).
			drift = target - p.out_pos
			if pl.loop {
				l := f64(c.loop_end - c.loop_start)
				drift -= l * math.round(drift / l) // the nearest way round the loop
			}
			if abs(drift) > 2048 do fresh, drift = true, 0
		}
	}
	speed = clamp(speed, 1e-3, p.settings.max_speed)
	// Repitch: each chunk covers, in source frames, exactly the beats the
	// timeline moves through during it (so tempo ramps are followed within a
	// call), plus a share of the drift.
	plan := Speed_Plan{fixed = speed}
	if c.mode != .Original {
		plan = {t = t, tl = tl, offset = start, frames_per_beat = frames_per_beat(c, c.bpm), drift = drift / f64(max(min(frames, stop) - start, 1)), max_speed = p.settings.max_speed}
	}
	envelope := Envelope{1, 0, stop}
	if fresh {
		if p.active do tail(p, ctx) // crossfade out of where we were
		target, inside := source_position(cfg, core.timeline_position_at(t, tl, start), t.tempo_bpm)
		if !inside {
			p.active = false
			return
		}
		begin(p, cfg, target)
		if c.mode == .Stretch do stretch_seek(p, cfg, plan_speed(plan, 0, min(AUDIO_CHUNK, min(frames, stop) - start)))
		envelope = {0, 1.0 / DECLICK_FRAMES, stop - start}
	}
	p.active = true
	render(p, cfg, ctx.outputs, start, min(frames, stop) - start, plan, envelope)
	if stop < frames do p.active = false // the placement ended inside this call
}

// A gain ramp over a render, clamped to 0..1, times a fade to 0 ending
// `end` frames after the render starts (the end of the placement).
@(private)
Envelope :: struct {
	start, step: f64,
	end:         int,
}

// Where a timeline position falls in the source, in frames; inside = false
// before the placement, after it, or past the end of a clip that does not loop.
@(private)
source_position :: proc "contextless" (cfg: ^Audio_Config, beat: tb.Beats, tempo: f64) -> (frame: f64, inside: bool) {
	c := cfg.clip
	pl := cfg.placement
	d := beat - pl.at
	if d < 0 || (pl.length > 0 && d >= pl.length) do return 0, false
	fpb := frames_per_beat(c, tempo if c.mode == .Original else c.bpm)
	frame = f64(c.start) + f64(pl.offset + d) * fpb
	if pl.loop && frame >= f64(c.loop_end) {
		l := f64(c.loop_end - c.loop_start)
		frame = f64(c.loop_start) + math.mod(frame - f64(c.loop_end), l)
	}
	return frame, frame < f64(c.end)
}

// Starts playing from source frame `at` (rounded down; the fade-in hides
// the fraction).
@(private)
begin :: proc "contextless" (p: ^Audio_Player, cfg: ^Audio_Config, at: f64) {
	frame := i64(at)
	stream.stream_seek(cfg.stream, frame)
	dsp.resampler_reset(&cfg.resampler)
	p.in_pos = frame
	p.out_pos = f64(frame)
}

// Fades out over DECLICK_FRAMES from where playback is, at frame 0, at the
// speed it last had.
@(private)
tail :: proc "contextless" (p: ^Audio_Player, ctx: ^core.Process_Context) {
	render(p, p.config, ctx.outputs, 0, min(DECLICK_FRAMES, ctx.frames), {fixed = p.speed}, {1, -1.0 / DECLICK_FRAMES, max(int)})
}

// How fast to play each chunk of a render: a fixed speed, or (when `t` is
// set) the source frames matching the timeline's movement during the chunk
// plus `drift` per frame.
@(private)
Speed_Plan :: struct {
	fixed:           f64,
	t:               ^core.Transport,
	tl:              ^core.Timeline_State,
	offset:          int, // call frame where the render starts
	frames_per_beat: f64,
	drift:           f64,
	max_speed:       f64,
}

@(private)
plan_speed :: proc "contextless" (plan: Speed_Plan, done, n: int) -> f64 {
	if plan.t == nil do return plan.fixed
	from := core.timeline_position_at(plan.t, plan.tl, plan.offset + done)
	to := core.timeline_position_at(plan.t, plan.tl, plan.offset + done + n)
	return clamp(f64(to - from) * plan.frames_per_beat / f64(n) + plan.drift, 1e-3, plan.max_speed)
}

// Renders `frames` frames at the planned speed, shaped by the envelope, and adds them
// to `out` from offset `at`.
@(private)
render :: proc "contextless" (p: ^Audio_Player, cfg: ^Audio_Config, out: [][]f32, at, frames: int, plan: Speed_Plan, env: Envelope) {
	c := cfg.clip
	looping := cfg.placement.loop
	loop_len := f64(c.loop_end - c.loop_start)
	fade_in := c.fade_in * c.sample_rate
	fade_out := c.fade_out * c.sample_rate
	done := 0
	for done < frames {
		n := min(AUDIO_CHUNK, frames - done)
		speed := plan_speed(plan, done, n)
		p.speed = speed
		made := 0
		if c.mode == .Stretch {
			made = stretch_chunk(p, cfg, n, speed)
		} else {
			made = resample(p, cfg, cfg.rendered, n, speed)
		}
		for i in 0 ..< made {
			k := done + i
			g := f64(c.gain) * clamp(env.start + env.step * f64(k), 0, 1) * clamp(f64(env.end - k) / DECLICK_FRAMES, 0, 1)
			if !looping {
				if fade_in > 0 do g *= clamp((p.out_pos - f64(c.start)) / fade_in, 0, 1)
				if fade_out > 0 do g *= clamp((f64(c.end) - p.out_pos) / fade_out, 0, 1)
			}
			mix(out, cfg.rendered, at + k, i, f32(g))
			p.out_pos += speed
			if looping && p.out_pos >= f64(c.loop_end) do p.out_pos -= loop_len
		}
		if made == 0 do break
		done += made
	}
}

// Resamples `n` frames at `speed` (source frames per frame) into `out`
// (one slice per source channel), reading the source as needed. Returns the
// frames made.
@(private)
resample :: proc "contextless" (p: ^Audio_Player, cfg: ^Audio_Config, out: [][]f32, n: int, speed: f64) -> int {
	need := min(dsp.resampler_input_needed(&cfg.resampler, n, speed), len(cfg.input[0]))
	feed(p, cfg, need)
	for ch in 0 ..< cfg.clip.channels {
		cfg.views[ch] = cfg.input[ch][:need]
		cfg.views2[ch] = out[ch][:n]
	}
	_, made := dsp.resampler_process(&cfg.resampler, cfg.views, cfg.views2, speed)
	return made
}

// Stretch: primes the stretcher from the current source position, so its
// next output is that position, for a start at `speed`.
@(private)
stretch_seek :: proc "contextless" (p: ^Audio_Player, cfg: ^Audio_Config, speed: f64) {
	rate_speed := cfg.clip.sample_rate / p.sample_rate
	rate := speed / rate_speed
	frames := min(cfg.input_latency + int(math.round(rate * f64(cfg.output_latency))), len(cfg.stage[0]))
	made := resample(p, cfg, cfg.stage, frames, rate_speed)
	for ch in 0 ..< cfg.clip.channels do cfg.views3[ch] = cfg.stage[ch][:made]
	p.settings.stretcher.output_seek(cfg.stretcher, cfg.views3, made)
	p.stretch_rate, p.stretch_carry = rate, 0
}

// Stretch: makes `n` output frames that advance the heard position by
// `speed` source frames each. The stretcher is fed device-rate audio (the
// source converted, pitch unchanged): enough to cover the advance, plus the
// change in its rate-dependent output latency.
@(private)
stretch_chunk :: proc "contextless" (p: ^Audio_Player, cfg: ^Audio_Config, n: int, speed: f64) -> int {
	rate_speed := cfg.clip.sample_rate / p.sample_rate
	rate := speed / rate_speed
	want := rate * f64(n) + (rate - p.stretch_rate) * f64(cfg.output_latency) + p.stretch_carry
	in_frames := clamp(int(math.floor(want)), 0, len(cfg.stage[0]))
	p.stretch_carry = want - f64(in_frames)
	p.stretch_rate = rate
	made := resample(p, cfg, cfg.stage, in_frames, rate_speed)
	for ch in 0 ..< cfg.clip.channels {
		cfg.views3[ch] = cfg.stage[ch][:made]
		cfg.views2[ch] = cfg.rendered[ch][:n]
	}
	p.settings.stretcher.process(cfg.stretcher, cfg.views3, made, cfg.views2, n)
	return n
}

// Reads `need` source frames into the resampler input, wrapping at the
// loop end (seamless loops) or giving silence past the clip's end.
@(private)
feed :: proc "contextless" (p: ^Audio_Player, cfg: ^Audio_Config, need: int) {
	c := cfg.clip
	looping := cfg.placement.loop
	k := 0
	for k < need {
		if looping && p.in_pos >= c.loop_end {
			stream.stream_seek(cfg.stream, c.loop_start) // a cue: instant
			p.in_pos = c.loop_start
		}
		limit := c.loop_end if looping else c.end
		if p.in_pos >= limit {
			for ch in 0 ..< c.channels do for &s in cfg.input[ch][k:need] do s = 0
			p.in_pos += i64(need - k)
			return
		}
		n := int(min(i64(need - k), limit - p.in_pos))
		for ch in 0 ..< c.channels do cfg.views[ch] = cfg.input[ch][k:k + n]
		stream.stream_read(cfg.stream, cfg.views, n)
		p.in_pos += i64(n)
		k += n
	}
}

// Adds one source frame to the outputs (mono sources to every output,
// averaged to a mono output, otherwise channel to channel).
@(private)
mix :: #force_inline proc "contextless" (out: [][]f32, src: [][]f32, at, i: int, g: f32) {
	switch {
	case len(src) == 1:
		for o in out do o[at] += src[0][i] * g
	case len(out) == 1:
		sum: f32
		for s in src do sum += s[i]
		out[0][at] += sum / f32(len(src)) * g
	case:
		for o, ch in out do if ch < len(src) do o[at] += src[ch][i] * g
	}
}
