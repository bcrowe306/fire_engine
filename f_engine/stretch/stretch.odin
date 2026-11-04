/*
Time-stretching and pitch-shifting: Signalsmith Stretch (by Geraint Luff /
Signalsmith Audio, MIT), ported to Odin. No C or C++, no build step.

Use it directly on buffers:

	s: stretch.Stretch
	stretch.stretch_preset_default(&s, channels = 2, sample_rate = 48_000)
	defer stretch.stretch_destroy(&s)
	stretch.stretch_set_transpose_semitones(&s, 3)
	stretch.stretch_output_seek(&s, input, stretch.stretch_output_seek_length(&s, rate))
	// then, per block (realtime-safe, allocation-free):
	stretch.stretch_process(&s, input, in_frames, output, out_frames)

or let audio clips use it, for clips that follow tempo at their own pitch,
or at a `transpose` of it:

	settings := clip.default_audio_player_settings(tl, streamer)
	settings.stretcher = &stretch.signalsmith
	node, player := clip.audio_player_create(settings)
	// ... add the node to the graph, then:
	loop, _ := clip.audio_clip_create(src, {bpm = 100, mode = .Stretch, transpose = -2})
	clip.audio_player_set(player, loop, {loop = true})

The default preset analyses 120 ms blocks every 30 ms, so output is heard
about 60 ms after its input; the clip player compensates. Beyond 2× slower,
phases are randomised (deterministically, the same on every platform).
*/
package stretch

import "fire:clip"

// Most channels a stretcher handles.
MAX_CHANNELS :: 16

// The default preset as a `clip.Stretcher_VTable`, for
// `Audio_Player_Settings.stretcher`.
signalsmith := clip.Stretcher_VTable {
	create = proc(channels: int, sample_rate, max_rate: f64) -> rawptr {
		if channels < 1 || channels > MAX_CHANNELS do return nil
		s := new(Stretch)
		if s == nil || stretch_preset_default(s, channels, f32(sample_rate)) != .None {
			free(s)
			return nil
		}
		return s
	},
	destroy = proc(s: rawptr) {
		stretch_destroy((^Stretch)(s))
		free(s)
	},
	input_latency = proc(s: rawptr) -> int {
		return stretch_input_latency((^Stretch)(s))
	},
	output_latency = proc(s: rawptr) -> int {
		return stretch_output_latency((^Stretch)(s))
	},
	output_seek = proc "contextless" (s: rawptr, input: [][]f32, frames: int) {
		stretch_output_seek((^Stretch)(s), input, frames)
	},
	set_transpose = proc(s: rawptr, semitones: f64) {
		stretch_set_transpose_semitones((^Stretch)(s), f32(semitones))
	},
	process = proc "contextless" (s: rawptr, input: [][]f32, in_frames: int, output: [][]f32, out_frames: int) {
		stretch_process((^Stretch)(s), input, in_frames, output, out_frames)
	},
}
