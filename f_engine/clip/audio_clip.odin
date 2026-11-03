package clip

import "core:mem"

import "fire:core"
import "fire:stream"
import tb "fire:timebase"

// How an audio clip relates to tempo.
Audio_Mode :: enum u8 {
	Original, // plays at the file's own speed whatever the tempo (one-shots, dialogue, field recordings)
	Repitch,  // follows tempo by playing faster or slower, so pitch moves with it (turntable-style)
	Stretch,  // follows tempo at the original pitch (time-stretching; not available yet)
}

// How to make an audio clip from a source. Positions are in the source's
// frames.
Audio_Clip_Settings :: struct {
	start:      i64,         // first frame used
	end:        i64,         // one past the last frame used; 0 = the end of the file
	loop_start: i64,         // part repeated by a looping placement; 0 and 0 = all of start..end
	loop_end:   i64,
	bpm:        f64,         // the material's tempo, to place it in beats; needed by Repitch and Stretch
	mode:       Audio_Mode,
	gain:       f32,         // linear; 0 is taken as 1
	fade_in:    f64,         // seconds, at the clip's start; negative = none, 0 = 5 ms
	fade_out:   f64,         // seconds, at the clip's end; negative = none, 0 = 5 ms
}

// An immutable audio clip: a region of a streamed or in-memory source and
// how to play it. Create with `audio_clip_create`; release with
// `audio_clip_release`. Read its fields freely, never change them.
Audio_Clip :: struct {
	source:      ^stream.Source,
	using settings: Audio_Clip_Settings, // with `end`, the loop and the fades resolved
	sample_rate: f64, // the source's
	channels:    int,
	refs:        int, // control thread
	allocator:   mem.Allocator,
}

// Control thread. Makes a clip on `src` (which it keeps a reference to).
// Fails with `.Invalid_Argument` for an empty or out-of-range region or
// loop, or a Repitch or Stretch clip without a `bpm`; with `.Unsupported`
// for `.Stretch` (coming in a later version).
audio_clip_create :: proc(src: ^stream.Source, settings: Audio_Clip_Settings, allocator := context.allocator) -> (^Audio_Clip, core.Error) {
	info := stream.source_info(src)
	s := settings
	if s.end == 0 do s.end = info.frames
	if s.start < 0 || s.end > info.frames || s.end <= s.start do return nil, .Invalid_Argument
	if s.loop_start == 0 && s.loop_end == 0 do s.loop_start, s.loop_end = s.start, s.end
	if s.loop_start < s.start || s.loop_end > s.end || s.loop_end <= s.loop_start do return nil, .Invalid_Argument
	if s.mode != .Original && !(s.bpm > 0) do return nil, .Invalid_Argument
	if s.mode == .Stretch do return nil, .Unsupported
	if s.gain == 0 do s.gain = 1
	if s.fade_in == 0 do s.fade_in = 0.005
	if s.fade_out == 0 do s.fade_out = 0.005
	c := new(Audio_Clip, allocator)
	if c == nil do return nil, .Out_Of_Memory
	c^ = {source = src, settings = s, sample_rate = info.sample_rate, channels = info.channels, refs = 1, allocator = allocator}
	stream.source_retain(src)
	return c, .None
}

// Control thread. Adds a reference.
audio_clip_retain :: proc(c: ^Audio_Clip) {
	if c != nil do c.refs += 1
}

// Control thread. Drops a reference; the clip (and its hold on the source)
// goes with the last one.
audio_clip_release :: proc(c: ^Audio_Clip) {
	if c == nil do return
	c.refs -= 1
	if c.refs > 0 do return
	stream.source_release(c.source)
	free(c, c.allocator)
}

// The clip's length in beats at its `bpm` (0 without one).
audio_clip_beats :: proc "contextless" (c: ^Audio_Clip) -> tb.Beats {
	if !(c.bpm > 0) do return 0
	return tb.Beats(f64(c.end - c.start) / frames_per_beat(c, c.bpm))
}

// Source frames per beat at `bpm`.
@(private)
frames_per_beat :: #force_inline proc "contextless" (c: ^Audio_Clip, bpm: f64) -> f64 {
	return c.sample_rate * 60 / bpm
}
