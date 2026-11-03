// Test-only toolkit: signal generators, analyzers, WAV I/O, golden files,
// the null backend (`render`), and callback-loop probes.
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

buffer_make :: proc(channels, frames: int, sample_rate: f64, allocator := context.allocator) -> Audio_Buffer {
	b := Audio_Buffer{frames = frames, sample_rate = sample_rate, allocator = allocator}
	b.storage = make([]f32, channels * frames, allocator)
	b.channels = make([][]f32, channels, allocator)
	for c in 0 ..< channels {
		b.channels[c] = b.storage[c * frames:(c + 1) * frames]
	}
	return b
}

buffer_destroy :: proc(b: ^Audio_Buffer) {
	delete(b.storage, b.allocator)
	delete(b.channels, b.allocator)
	b^ = {}
}

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

seconds_to_frames :: proc(seconds, sample_rate: f64) -> int {
	return int(seconds * sample_rate + 0.5)
}
