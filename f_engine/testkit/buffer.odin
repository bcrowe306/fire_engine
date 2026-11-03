// Test-only toolkit for nodes: signal generators, analyzers, WAV I/O, golden
// files, the null backend (`render`), a probe node, and real-device loopback
// helpers.
//
// A typical test builds an input with the generators, renders the node through
// the null backend (which traps allocations inside `process`, fills outputs with
// NaN so unwritten samples show up, and varies the block size), checks the report
// with `expect_clean_render`, then asserts behavior with the analyzers:
//
//	n := dsp.gain_create()
//	defer core.node_destroy(&n)
//
//	input := testkit.buffer_make(2, 48_000, 48_000, context.temp_allocator)
//	testkit.sine(input.channels[0], 48_000, 440, 0.5)
//	testkit.buffer_mono_to_all(input)
//
//	cfg := testkit.default_render_config()
//	cfg.blocks = testkit.Random_Blocks{seed = 1, min = 0, max = cfg.max_block}
//	out, report := testkit.render(&n, input, cfg, context.temp_allocator)
//	defer testkit.render_report_destroy(&report)
//	testkit.expect_clean_render(t, report)
//	testkit.expect_near(t, testkit.tone_amplitude(out.channels[0], 48_000, 440), 0.5, 1e-3, "level")
//
// Add `expect_block_invariant` with `standard_block_patterns` for any node that
// takes events, and `expect_golden` to pin down exact output.
//
// Engine packages must never import testkit.
package testkit

import "core:mem"

// Planar multichannel buffer that owns its storage.
Audio_Buffer :: struct {
	channels:    [][]f32,
	frames:      int,
	sample_rate: f64,
	storage:     []f32,
	allocator:   mem.Allocator,
}

// Allocates a zeroed buffer of `channels` x `frames` from `allocator` (one contiguous
// block plus the channel slice table). Free with `buffer_destroy`, or let a temp
// allocator reclaim it.
buffer_make :: proc(channels, frames: int, sample_rate: f64, allocator := context.allocator) -> Audio_Buffer {
	b := Audio_Buffer{frames = frames, sample_rate = sample_rate, allocator = allocator}
	b.storage = make([]f32, channels * frames, allocator)
	b.channels = make([][]f32, channels, allocator)
	for c in 0 ..< channels {
		b.channels[c] = b.storage[c * frames:(c + 1) * frames]
	}
	return b
}

// Frees a buffer made by `buffer_make`, `buffer_clone` or `wav_read` with the allocator
// it was made with, and zeroes it.
buffer_destroy :: proc(b: ^Audio_Buffer) {
	delete(b.storage, b.allocator)
	delete(b.channels, b.allocator)
	b^ = {}
}

// Deep copy of `src` (same channels, frames and sample rate), allocated from `allocator`.
buffer_clone :: proc(src: Audio_Buffer, allocator := context.allocator) -> Audio_Buffer {
	b := buffer_make(len(src.channels), src.frames, src.sample_rate, allocator)
	for c in 0 ..< len(src.channels) do copy(b.channels[c], src.channels[c])
	return b
}

// Same signal in every channel: generate into channel 0, then copy.
buffer_mono_to_all :: proc(b: Audio_Buffer) {
	for c in 1 ..< len(b.channels) do copy(b.channels[c], b.channels[0])
}

// A zero-channel buffer that only says how many frames to render (for generators).
buffer_length_only :: proc(frames: int, sample_rate: f64) -> Audio_Buffer {
	return Audio_Buffer{frames = frames, sample_rate = sample_rate}
}

// Converts a duration in seconds to frames at `sample_rate`, rounded to the nearest frame.
seconds_to_frames :: proc(seconds, sample_rate: f64) -> int {
	return int(seconds * sample_rate + 0.5)
}
