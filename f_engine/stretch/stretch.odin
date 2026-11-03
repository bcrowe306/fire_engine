/*
Time-stretching for audio clips: Signalsmith Stretch (MIT, by Geraint Luff /
Signalsmith Audio), as a `clip.Stretcher_VTable`.

The library is C++, vendored in vendor/signalsmith; build it once with
`scripts/stretch.sh` (needs CMake and a C++17 compiler). Only apps that
import this package need it: `fire:clip` itself is pure Odin. A pure-Odin
port is planned.

	settings := clip.default_audio_player_settings(tl, streamer)
	settings.stretcher = &stretch.signalsmith
	node, player := clip.audio_player_create(settings)
	// ... add the node to the graph, then:
	loop, _ := clip.audio_clip_create(src, {bpm = 100, mode = .Stretch})
	clip.audio_player_set(player, loop, {loop = true}) // follows tempo, pitch unchanged

Its preset analyses 120 ms blocks every 30 ms, so a stretched clip is heard
about 60 ms after its input; the player compensates, so clips stay in time.
*/
package stretch

import ss "fire:sys/signalsmith"
import "fire:clip"

// Most channels a stretcher handles.
MAX_CHANNELS :: 16

// Signalsmith Stretch's default preset, for `Audio_Player_Settings.stretcher`.
signalsmith := clip.Stretcher_VTable {
	create = proc(channels: int, sample_rate, max_rate: f64) -> rawptr {
		if channels < 1 || channels > MAX_CHANNELS do return nil
		return ss.create(i32(channels), f32(sample_rate), f32(max_rate))
	},
	destroy = proc(s: rawptr) {
		ss.destroy((^ss.Stretch)(s))
	},
	input_latency = proc(s: rawptr) -> int {
		return int(ss.input_latency((^ss.Stretch)(s)))
	},
	output_latency = proc(s: rawptr) -> int {
		return int(ss.output_latency((^ss.Stretch)(s)))
	},
	output_seek = proc "contextless" (s: rawptr, input: [][]f32, frames: int) {
		ptrs: [MAX_CHANNELS][^]f32
		for ch, i in input do ptrs[i] = raw_data(ch)
		ss.output_seek((^ss.Stretch)(s), raw_data(ptrs[:]), i32(frames))
	},
	process = proc "contextless" (s: rawptr, input: [][]f32, in_frames: int, output: [][]f32, out_frames: int) {
		in_ptrs, out_ptrs: [MAX_CHANNELS][^]f32
		for ch, i in input do in_ptrs[i] = raw_data(ch)
		for ch, i in output do out_ptrs[i] = raw_data(ch)
		ss.process((^ss.Stretch)(s), raw_data(in_ptrs[:]), i32(in_frames), raw_data(out_ptrs[:]), i32(out_frames))
	},
}
