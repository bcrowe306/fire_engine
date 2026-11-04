package clip

// A time-stretcher for `.Stretch` audio clips: changes duration, not pitch
// (unless the clip asks for a `transpose`).
// Fire Engine's clips don't depend on any particular one; `fire:stretch`
// provides Signalsmith Stretch, and you can supply your own. Give it to the
// player in `Audio_Player_Settings.stretcher`.
//
// The player feeds it audio at the device's sample rate and keeps it in
// sync with this model: after `output_seek` with input starting at
// position P, the next output is P; from then on, the position heard is
// the input fed so far, minus `input_latency`, minus the playback rate
// (input per output frame) times `output_latency`.
Stretcher_VTable :: struct {
	// Control thread. A stretcher for `channels` channels at `sample_rate`,
	// ready for rates up to `max_rate` (input frames per output frame).
	// After this, no other proc may allocate. nil on failure.
	create:         proc(channels: int, sample_rate, max_rate: f64) -> rawptr,
	// Control thread.
	destroy:        proc(s: rawptr),
	// Frames of input ahead of the position being processed.
	input_latency:  proc(s: rawptr) -> int,
	// Frames by which output trails the position being processed.
	output_latency: proc(s: rawptr) -> int,
	// [rt] Start over so that the next output begins at input frame 0;
	// `frames` = input_latency + rate × output_latency.
	output_seek:    proc "contextless" (s: rawptr, input: [][]f32, frames: int),
	// Control thread, after `create`; optional (nil: clips with a
	// `transpose` are refused). Shifts pitch by `semitones`.
	set_transpose:  proc(s: rawptr, semitones: f64),
	// [rt] Consume `in_frames` frames and produce `out_frames`; their ratio
	// is the playback rate.
	process:        proc "contextless" (s: rawptr, input: [][]f32, in_frames: int, output: [][]f32, out_frames: int),
}
