package record

import "core:mem"

import "fire:audiofile"
import "fire:core"

// Saved-state ID of `audio_recorder_create` nodes (settings only: takes and
// arming are not saved).
AUDIO_RECORDER_TYPE_ID :: "fire.audio_recorder"
// Saved-state ID of `midi_recorder_create` nodes (settings only).
MIDI_RECORDER_TYPE_ID :: "fire.midi_recorder"
// Saved-state ID of `automation_recorder_create` nodes (settings only).
AUTOMATION_RECORDER_TYPE_ID :: "fire.automation_recorder"
// Saved-state ID of `latency_probe_create` nodes.
LATENCY_PROBE_TYPE_ID :: "fire.latency_probe"

// Registers this package's nodes. Audio recorders are registered only with
// a `disk` to write through (it must outlive the registry). Control thread.
register_types :: proc(reg: ^core.Node_Registry, disk: ^Disk_Writer = nil) -> core.Error {
	core.register_type(reg, {id = MIDI_RECORDER_TYPE_ID, load = load_midi_recorder}) or_return
	core.register_type(reg, {id = AUTOMATION_RECORDER_TYPE_ID, load = load_automation_recorder}) or_return
	core.register_type(reg, {id = LATENCY_PROBE_TYPE_ID, load = load_latency_probe}) or_return
	if disk != nil do core.register_type(reg, {id = AUDIO_RECORDER_TYPE_ID, load = load_audio_recorder, data = disk}) or_return
	return .None
}

@(private)
write_timeline :: proc(w: ^core.State_Writer, id: core.Timeline_Id) {
	core.write_u32(w, id.index)
	core.write_u32(w, id.generation)
}

@(private)
read_timeline :: proc(r: ^core.State_Reader, ctx: ^core.Load_Context) -> core.Timeline_Id {
	id := core.Timeline_Id{core.read_u32(r), core.read_u32(r)}
	return core.load_timeline(ctx, id) if id != {} else id
}

@(private)
save_audio_recorder :: proc(self: rawptr, w: ^core.State_Writer, ctx: ^core.Save_Context) -> core.Error {
	s := (^Audio_Recorder)(self).settings
	write_timeline(w, s.timeline)
	core.write_int(w, s.channels)
	core.write_path(w, ctx, s.directory)
	core.write_string(w, s.name)
	core.write_u8(w, u8(s.encoding))
	core.write_int(w, s.latency_frames)
	core.write_f64(w, s.buffer_seconds)
	return .None
}

@(private)
load_audio_recorder :: proc(data: rawptr, r: ^core.State_Reader, version: u32, ctx: ^core.Load_Context, allocator: mem.Allocator) -> (core.Node, core.Error) {
	s: Audio_Recorder_Settings
	s.timeline = read_timeline(r, ctx)
	s.channels = core.read_int(r)
	s.directory = core.read_path(r, ctx, context.temp_allocator)
	s.name = core.read_string(r)
	encoding := core.read_u8(r)
	s.latency_frames = core.read_int(r)
	s.buffer_seconds = core.read_f64(r)
	if r.err != .None || int(encoding) > int(max(audiofile.Sample_Format)) do return {}, .Invalid_Data
	s.encoding = audiofile.Sample_Format(encoding)
	node, _, err := audio_recorder_create((^Disk_Writer)(data), s, allocator)
	return node, err
}

@(private)
save_midi_recorder :: proc(self: rawptr, w: ^core.State_Writer, ctx: ^core.Save_Context) -> core.Error {
	s := (^Midi_Recorder)(self).settings
	write_timeline(w, s.timeline)
	core.write_int(w, s.latency_frames)
	core.write_int(w, s.max_events)
	return .None
}

@(private)
load_midi_recorder :: proc(_: rawptr, r: ^core.State_Reader, version: u32, ctx: ^core.Load_Context, allocator: mem.Allocator) -> (core.Node, core.Error) {
	s: Midi_Recorder_Settings
	s.timeline = read_timeline(r, ctx)
	s.latency_frames, s.max_events = core.read_int(r), core.read_int(r)
	if r.err != .None do return {}, .Invalid_Data
	node, _, err := midi_recorder_create(s, allocator)
	return node, err
}

@(private)
save_automation_recorder :: proc(self: rawptr, w: ^core.State_Writer, ctx: ^core.Save_Context) -> core.Error {
	s := (^Automation_Recorder)(self).settings
	write_timeline(w, s.timeline)
	core.write_u8(w, u8(s.mode))
	core.write_int(w, s.max_params)
	core.write_int(w, s.max_events)
	core.write_f64(w, s.glide_ms)
	return .None
}

@(private)
load_automation_recorder :: proc(_: rawptr, r: ^core.State_Reader, version: u32, ctx: ^core.Load_Context, allocator: mem.Allocator) -> (core.Node, core.Error) {
	s: Automation_Recorder_Settings
	s.timeline = read_timeline(r, ctx)
	mode := core.read_u8(r)
	s.max_params, s.max_events = core.read_int(r), core.read_int(r)
	s.glide_ms = core.read_f64(r)
	if r.err != .None || int(mode) > int(max(Write_Mode)) do return {}, .Invalid_Data
	s.mode = Write_Mode(mode)
	node, _, err := automation_recorder_create(s, allocator)
	return node, err
}

@(private)
save_latency_probe :: proc(self: rawptr, w: ^core.State_Writer, ctx: ^core.Save_Context) -> core.Error {
	s := (^Latency_Probe)(self).settings
	core.write_f64(w, s.max_seconds)
	core.write_int(w, s.burst_frames)
	core.write_f32(w, s.level)
	return .None
}

@(private)
load_latency_probe :: proc(_: rawptr, r: ^core.State_Reader, version: u32, ctx: ^core.Load_Context, allocator: mem.Allocator) -> (core.Node, core.Error) {
	s: Latency_Probe_Settings
	s.max_seconds, s.burst_frames, s.level = core.read_f64(r), core.read_int(r), core.read_f32(r)
	if r.err != .None do return {}, .Invalid_Data
	node, _, err := latency_probe_create(s, allocator)
	return node, err
}
