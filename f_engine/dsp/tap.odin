package dsp

import "base:intrinsics"
import "core:mem"

import "fire:core"

// Frames a `Tap` keeps (a power of two).
TAP_FRAMES :: 4096

// Listens to what it is given and keeps the last TAP_FRAMES frames (the
// channels averaged), for a picture of the sound: a spectrum, a scope. It
// has inputs and no outputs; connect anything to it, as many times as
// needed (connections sum). Read from any thread with `tap_read`.
Tap :: struct {
	ring:  [TAP_FRAMES]f32,
	write: u64, // atomic: frames written so far
}

@(private)
tap_vtable := core.Node_VTable {
	prepare = proc(self: rawptr, cfg: core.Prepare_Config, a: mem.Allocator) -> core.Error { return .None },
	process = tap_process,
	reset   = proc(self: rawptr) {},
	destroy = proc(self: rawptr, a: mem.Allocator) { free((^Tap)(self), a) },
}

// Control thread. A tap node (add it with inputs and no outputs) and its
// handle, valid until the graph destroys the node.
tap_create :: proc(allocator := context.allocator) -> (core.Node, ^Tap) {
	t := new(Tap, allocator)
	return core.node_make(&tap_vtable, t, allocator), t
}

// Any thread. The last `len(out)` frames heard (at most TAP_FRAMES), oldest
// first; silence before anything arrives. A reader racing the audio thread
// may see a few frames of the next block among them: it is for drawing.
// Returns how many frames have been heard in all (to tell new from old).
tap_read :: proc "contextless" (t: ^Tap, out: []f32) -> u64 {
	n := min(len(out), TAP_FRAMES)
	w := intrinsics.atomic_load(&t.write)
	for i in 0 ..< n {
		k := i64(w) - i64(n) + i64(i)
		out[i] = t.ring[u64(k) & (TAP_FRAMES - 1)] if k >= 0 else 0
	}
	return w
}

// [rt]
@(private)
tap_process :: proc(self: rawptr, ctx: ^core.Process_Context) {
	t := (^Tap)(self)
	w := intrinsics.atomic_load(&t.write)
	ch := len(ctx.inputs)
	for i in 0 ..< ctx.frames {
		x: f32 = 0
		for c in 0 ..< ch do x += ctx.inputs[c][i]
		t.ring[(w + u64(i)) & (TAP_FRAMES - 1)] = x / f32(max(ch, 1))
	}
	intrinsics.atomic_store(&t.write, w + u64(ctx.frames))
}
