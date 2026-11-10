package clip

import "core:mem"

import "fire:core"
import "fire:dsp"
import "fire:stream"
import tb "fire:timebase"

// Saved-state ID of `midi_player_create` nodes (with their clip).
MIDI_PLAYER_TYPE_ID :: "fire.midi_player"
// Saved-state ID of `audio_player_create` nodes (with their clip).
AUDIO_PLAYER_TYPE_ID :: "fire.audio_player"
// Saved-state ID of `automation_player_create` nodes (with their clip).
AUTOMATION_PLAYER_TYPE_ID :: "fire.automation_player"

// Chunk tags of saved clips.
MIDI_CLIP_TAG :: core.Tag{'M', 'C', 'L', 'P'}
// Chunk tag of a saved audio clip (its source's path and its settings).
AUDIO_CLIP_TAG :: core.Tag{'A', 'C', 'L', 'P'}
// Chunk tag of a saved automation clip.
AUTOMATION_CLIP_TAG :: core.Tag{'U', 'C', 'L', 'P'}

// What loading players needs from the app: the streamer audio clips read
// through, and the stretcher for `.Stretch` clips (nil: such players load
// without one, and their clips are refused). Must outlive the registry.
Player_Env :: struct {
	streamer:  ^stream.Streamer,
	stretcher: ^Stretcher_VTable,
}

// Registers the three players. Audio players are registered only if
// `env.streamer` is set. Control thread.
register_types :: proc(reg: ^core.Node_Registry, env: ^Player_Env = nil) -> core.Error {
	core.register_type(reg, {id = MIDI_PLAYER_TYPE_ID, load = load_midi_player}) or_return
	core.register_type(reg, {id = AUTOMATION_PLAYER_TYPE_ID, load = load_automation_player}) or_return
	if env != nil && env.streamer != nil {
		core.register_type(reg, {id = AUDIO_PLAYER_TYPE_ID, load = load_audio_player, data = env}) or_return
	}
	return .None
}

// --- clips ---------------------------------------------------------------------------------

// Writes `c` as a MIDI_CLIP_TAG chunk (nil: an empty chunk, read back as nil).
write_midi_clip :: proc(w: ^core.State_Writer, c: ^Midi_Clip) {
	core.begin_chunk(w, MIDI_CLIP_TAG, 2)
	if c != nil {
		core.write_f64(w, f64(c.length))
		core.write_f64(w, f64(c.loop_start))
		core.write_f64(w, f64(c.loop_end))
		core.write_int(w, len(c.notes))
		for n in c.notes {
			core.write_f64(w, f64(n.start))
			core.write_f64(w, f64(n.length))
			core.write_u8(w, n.key)
			core.write_u8(w, n.channel)
			core.write_f32(w, n.velocity)
			core.write_f32(w, n.release)
			core.write_f32(w, n.probability) // version 2
			points := c.expression[n.expression[0]:][:n.expression[1]]
			core.write_int(w, len(points))
			for x in points {
				core.write_f64(w, f64(x.at))
				core.write_u8(w, u8(x.kind))
				core.write_f64(w, x.value)
			}
		}
		core.write_int(w, len(c.controllers))
		for k in c.controllers {
			core.write_f64(w, f64(k.at))
			bytes := k.bytes
			core.write_payload(w, bytes[:])
		}
	}
	core.end_chunk(w)
}

// Reads a clip written by `write_midi_clip` from the reader's next chunk:
// a new clip with one reference (yours), or nil for a saved nil clip.
// `.Invalid_Data` for a malformed chunk.
read_midi_clip :: proc(r: ^core.State_Reader, allocator := context.allocator) -> (^Midi_Clip, core.Error) {
	ch, ok := core.find_chunk(r, MIDI_CLIP_TAG)
	if !ok do return nil, .Invalid_Data
	if len(ch.data) == 0 do return nil, .None
	cr := core.chunk_reader(ch)
	b: Midi_Builder
	midi_builder_init(&b, tb.Beats(core.read_f64(&cr)), context.temp_allocator)
	defer midi_builder_destroy(&b)
	set_loop(&b, tb.Beats(core.read_f64(&cr)), tb.Beats(core.read_f64(&cr)))
	notes := core.read_int(&cr)
	if notes < 0 || notes > len(ch.data) / 34 do return nil, .Invalid_Data
	for _ in 0 ..< notes {
		start, length := tb.Beats(core.read_f64(&cr)), tb.Beats(core.read_f64(&cr))
		key, channel := core.read_u8(&cr), core.read_u8(&cr)
		velocity, release := core.read_f32(&cr), core.read_f32(&cr)
		probability: f32 = 1
		if ch.version >= 2 do probability = core.read_f32(&cr)
		i := add_note(&b, start, length, key, velocity, channel, release, probability)
		points := core.read_int(&cr)
		if points < 0 || points > len(ch.data) / 17 do return nil, .Invalid_Data
		for _ in 0 ..< points {
			at := tb.Beats(core.read_f64(&cr))
			kind := core.read_u8(&cr)
			value := core.read_f64(&cr)
			if int(kind) > int(max(core.Note_Expression_Kind)) do return nil, .Invalid_Data
			add_expression(&b, i, at, core.Note_Expression_Kind(kind), value)
		}
	}
	controllers := core.read_int(&cr)
	if controllers < 0 || controllers > len(ch.data) / 11 do return nil, .Invalid_Data
	for _ in 0 ..< controllers {
		at := tb.Beats(core.read_f64(&cr))
		add_controller(&b, at, {core.read_u8(&cr), core.read_u8(&cr), core.read_u8(&cr)})
	}
	if cr.err != .None do return nil, .Invalid_Data
	c, err := midi_build(&b, allocator)
	return c, .Invalid_Data if err == .Invalid_Argument else err
}

// Writes `c` as an AUTOMATION_CLIP_TAG chunk (nil: an empty chunk).
write_automation_clip :: proc(w: ^core.State_Writer, c: ^Automation_Clip) {
	core.begin_chunk(w, AUTOMATION_CLIP_TAG, 1)
	if c != nil {
		core.write_f64(w, f64(c.length))
		core.write_f64(w, f64(c.loop_start))
		core.write_f64(w, f64(c.loop_end))
		core.write_int(w, len(c.lanes))
		for l in c.lanes {
			core.write_u32(w, u32(l.param))
			core.write_int(w, len(l.points))
			for p in l.points {
				core.write_f64(w, f64(p.at))
				core.write_f64(w, p.value)
				core.write_u8(w, u8(p.shape))
				core.write_f32(w, p.tension)
			}
		}
	}
	core.end_chunk(w)
}

// Reads a clip written by `write_automation_clip` from the reader's next
// chunk (as `read_midi_clip`).
read_automation_clip :: proc(r: ^core.State_Reader, allocator := context.allocator) -> (^Automation_Clip, core.Error) {
	ch, ok := core.find_chunk(r, AUTOMATION_CLIP_TAG)
	if !ok do return nil, .Invalid_Data
	if len(ch.data) == 0 do return nil, .None
	cr := core.chunk_reader(ch)
	b: Automation_Builder
	automation_builder_init(&b, tb.Beats(core.read_f64(&cr)), context.temp_allocator)
	defer automation_builder_destroy(&b)
	automation_set_loop(&b, tb.Beats(core.read_f64(&cr)), tb.Beats(core.read_f64(&cr)))
	lanes := core.read_int(&cr)
	if lanes < 0 || lanes > len(ch.data) / 12 do return nil, .Invalid_Data
	for _ in 0 ..< lanes {
		param := core.Param_Id(core.read_u32(&cr))
		points := core.read_int(&cr)
		if points < 0 || points > len(ch.data) / 21 do return nil, .Invalid_Data
		for _ in 0 ..< points {
			at, value := tb.Beats(core.read_f64(&cr)), core.read_f64(&cr)
			shape, tension := core.read_u8(&cr), core.read_f32(&cr)
			if int(shape) > int(max(Segment_Shape)) do return nil, .Invalid_Data
			automation_add_point(&b, param, at, value, Segment_Shape(shape), tension)
		}
	}
	if cr.err != .None do return nil, .Invalid_Data
	c, err := automation_build(&b, allocator)
	return c, .Invalid_Data if err == .Invalid_Argument else err
}

// Writes `c` as an AUDIO_CLIP_TAG chunk: its source's path (see
// `core.write_path`) and its settings (nil: an empty chunk).
write_audio_clip :: proc(w: ^core.State_Writer, ctx: ^core.Save_Context, c: ^Audio_Clip) {
	core.begin_chunk(w, AUDIO_CLIP_TAG, 1)
	if c != nil {
		core.write_path(w, ctx, c.source.path)
		s := c.settings
		core.write_i64(w, s.start)
		core.write_i64(w, s.end)
		core.write_i64(w, s.loop_start)
		core.write_i64(w, s.loop_end)
		core.write_f64(w, s.bpm)
		core.write_u8(w, u8(s.mode))
		core.write_f64(w, s.transpose)
		core.write_f32(w, s.gain)
		core.write_f64(w, s.fade_in)
		core.write_f64(w, s.fade_out)
	}
	core.end_chunk(w)
}

// Reads a clip written by `write_audio_clip` from the reader's next chunk,
// opening its file through `streamer`: a new clip with one reference, or
// nil for a saved nil clip. `.Invalid_Data` for a malformed chunk;
// `.Device_Error` if the file cannot be opened; `.Invalid_Argument` if the
// file no longer fits the clip (shorter, say).
read_audio_clip :: proc(r: ^core.State_Reader, ctx: ^core.Load_Context, streamer: ^stream.Streamer, allocator := context.allocator) -> (^Audio_Clip, core.Error) {
	ch, ok := core.find_chunk(r, AUDIO_CLIP_TAG)
	if !ok do return nil, .Invalid_Data
	if len(ch.data) == 0 do return nil, .None
	cr := core.chunk_reader(ch)
	path := core.read_path(&cr, ctx, context.temp_allocator)
	s: Audio_Clip_Settings
	s.start, s.end = core.read_i64(&cr), core.read_i64(&cr)
	s.loop_start, s.loop_end = core.read_i64(&cr), core.read_i64(&cr)
	s.bpm = core.read_f64(&cr)
	mode := core.read_u8(&cr)
	s.transpose = core.read_f64(&cr)
	s.gain = core.read_f32(&cr)
	s.fade_in, s.fade_out = core.read_f64(&cr), core.read_f64(&cr)
	if cr.err != .None || int(mode) > int(max(Audio_Mode)) do return nil, .Invalid_Data
	s.mode = Audio_Mode(mode)
	src, serr := stream.source_open(streamer, path)
	if serr != .None do return nil, .Device_Error
	defer stream.source_release(src) // the clip keeps its own reference
	return audio_clip_create(src, s, allocator)
}

@(private)
write_placement :: proc(w: ^core.State_Writer, p: Placement) {
	core.write_f64(w, f64(p.at))
	core.write_f64(w, f64(p.length))
	core.write_f64(w, f64(p.offset))
	core.write_bool(w, p.loop)
}

@(private)
read_placement :: proc(r: ^core.State_Reader) -> Placement {
	return {tb.Beats(core.read_f64(r)), tb.Beats(core.read_f64(r)), tb.Beats(core.read_f64(r)), core.read_bool(r)}
}

@(private)
write_timeline_id :: proc(w: ^core.State_Writer, id: core.Timeline_Id) {
	core.write_u32(w, id.index)
	core.write_u32(w, id.generation)
}

@(private)
read_timeline_id :: proc(r: ^core.State_Reader, ctx: ^core.Load_Context) -> core.Timeline_Id {
	id := core.Timeline_Id{core.read_u32(r), core.read_u32(r)}
	return core.load_timeline(ctx, id) if id != {} else id
}

// A clip given to a player before it is prepared (by a loader), set at the
// end of its `prepare`.
@(private)
Deferred :: struct($T: typeid) {
	clip:      T,
	placement: Placement,
	set:       bool,
}

// --- players -------------------------------------------------------------------------------

@(private)
save_midi_player :: proc(self: rawptr, w: ^core.State_Writer, ctx: ^core.Save_Context) -> core.Error {
	p := (^Midi_Player)(self)
	write_timeline_id(w, p.settings.timeline)
	core.write_int(w, p.settings.max_notes)
	core.write_int(w, p.settings.max_events)
	c, pl := p.deferred.clip, p.deferred.placement
	if !p.deferred.set {
		c, pl = nil, {}
		if len(p.live) > 0 do c, pl = p.live[len(p.live) - 1].clip, p.live[len(p.live) - 1].placement
	}
	write_placement(w, pl)
	write_midi_clip(w, c)
	return .None
}

@(private)
load_midi_player :: proc(_: rawptr, r: ^core.State_Reader, version: u32, ctx: ^core.Load_Context, allocator: mem.Allocator) -> (core.Node, core.Error) {
	s: Midi_Player_Settings
	s.timeline = read_timeline_id(r, ctx)
	s.max_notes, s.max_events = core.read_int(r), core.read_int(r)
	pl := read_placement(r)
	if r.err != .None do return {}, .Invalid_Data
	c, cerr := read_midi_clip(r, allocator)
	if cerr != .None do return {}, cerr
	node, p := midi_player_create(s, allocator)
	p.deferred = {c, pl, true}
	return node, .None
}

@(private)
save_automation_player :: proc(self: rawptr, w: ^core.State_Writer, ctx: ^core.Save_Context) -> core.Error {
	p := (^Automation_Player)(self)
	write_timeline_id(w, p.settings.timeline)
	core.write_int(w, p.settings.max_events)
	core.write_int(w, p.settings.max_lanes)
	core.write_int(w, p.settings.curve_frames)
	c, pl := p.deferred.clip, p.deferred.placement
	if !p.deferred.set {
		c, pl = nil, {}
		if len(p.live) > 0 do c, pl = p.live[len(p.live) - 1].clip, p.live[len(p.live) - 1].placement
	}
	write_placement(w, pl)
	write_automation_clip(w, c)
	return .None
}

@(private)
load_automation_player :: proc(_: rawptr, r: ^core.State_Reader, version: u32, ctx: ^core.Load_Context, allocator: mem.Allocator) -> (core.Node, core.Error) {
	s: Automation_Player_Settings
	s.timeline = read_timeline_id(r, ctx)
	s.max_events, s.max_lanes, s.curve_frames = core.read_int(r), core.read_int(r), core.read_int(r)
	pl := read_placement(r)
	if r.err != .None do return {}, .Invalid_Data
	c, cerr := read_automation_clip(r, allocator)
	if cerr != .None do return {}, cerr
	node, p, err := automation_player_create(s, allocator)
	if err != .None {
		automation_clip_release(c)
		return {}, err
	}
	p.deferred = {c, pl, true}
	return node, .None
}

@(private)
save_audio_player :: proc(self: rawptr, w: ^core.State_Writer, ctx: ^core.Save_Context) -> core.Error {
	p := (^Audio_Player)(self)
	write_timeline_id(w, p.settings.timeline)
	core.write_int(w, p.settings.channels)
	core.write_u8(w, u8(p.settings.quality))
	core.write_f64(w, p.settings.max_speed)
	core.write_bool(w, p.settings.stretcher != nil)
	c, pl := p.deferred.clip, p.deferred.placement
	if !p.deferred.set {
		c, pl = nil, {}
		if p.latest != nil do c, pl = p.latest.clip, p.latest.placement
	}
	write_placement(w, pl)
	write_audio_clip(w, ctx, c)
	return .None
}

@(private)
load_audio_player :: proc(data: rawptr, r: ^core.State_Reader, version: u32, ctx: ^core.Load_Context, allocator: mem.Allocator) -> (core.Node, core.Error) {
	env := (^Player_Env)(data)
	s := default_audio_player_settings(read_timeline_id(r, ctx), env.streamer)
	s.channels = core.read_int(r)
	quality := core.read_u8(r)
	s.max_speed = core.read_f64(r)
	if core.read_bool(r) do s.stretcher = env.stretcher
	pl := read_placement(r)
	if r.err != .None || int(quality) > int(max(dsp.Resampler_Quality)) || s.channels <= 0 || s.channels > core.MAX_CHANNELS {
		return {}, .Invalid_Data
	}
	s.quality = dsp.Resampler_Quality(quality)
	c, cerr := read_audio_clip(r, ctx, env.streamer, allocator)
	if cerr != .None do return {}, cerr
	node, p := audio_player_create(s, allocator)
	p.deferred = {c, pl, true}
	return node, .None
}
