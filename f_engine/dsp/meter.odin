package dsp

import "base:intrinsics"
import "core:math"
import "core:mem"

import "fire:core"

// Channels a `Meter` measures (more pass through unmeasured).
METER_CHANNELS :: 2

// Passes audio through unchanged and measures it: each channel's peak and
// RMS since the last `meter_read`, for level meters. Read from any thread.
Meter :: struct {
	peak:  [METER_CHANNELS]u32, // atomic: f32 bits, the largest |sample| since the last read
	sum:   [METER_CHANNELS]u64, // atomic: f64 bits, Σ x² since the last read
	count: u64,                 // atomic: frames since the last read
}

@(private)
meter_vtable := core.Node_VTable {
	prepare = proc(self: rawptr, cfg: core.Prepare_Config, a: mem.Allocator) -> core.Error { return .None },
	process = meter_process,
	destroy = proc(self: rawptr, a: mem.Allocator) { free((^Meter)(self), a) },
}

// Control thread. A meter node (give it as many inputs as outputs) and its
// handle, valid until the graph destroys the node.
meter_create :: proc(allocator := context.allocator) -> (core.Node, ^Meter) {
	m := new(Meter, allocator)
	return core.node_make(&meter_vtable, m, allocator), m
}

// Any thread. Each channel's peak and RMS (linear) since the last read,
// which starts the next measurement. Channels the meter has not seen
// read 0.
meter_read :: proc "contextless" (m: ^Meter) -> (peak, rms: [METER_CHANNELS]f32) {
	n := intrinsics.atomic_exchange(&m.count, 0)
	for c in 0 ..< METER_CHANNELS {
		peak[c] = transmute(f32)intrinsics.atomic_exchange(&m.peak[c], 0)
		s := transmute(f64)intrinsics.atomic_exchange(&m.sum[c], 0)
		if n > 0 do rms[c] = f32(math.sqrt(s / f64(n)))
	}
	return
}

// [rt]
@(private)
meter_process :: proc(self: rawptr, ctx: ^core.Process_Context) {
	m := (^Meter)(self)
	for out, c in ctx.outputs {
		if c < len(ctx.inputs) {
			copy(out[:ctx.frames], ctx.inputs[c][:ctx.frames])
		} else {
			for &v in out[:ctx.frames] do v = 0
		}
		if c >= METER_CHANNELS do continue
		pk: f32 = 0
		sq: f64 = 0
		for v in out[:ctx.frames] {
			pk = max(pk, abs(v))
			sq += f64(v) * f64(v)
		}
		// One writer (the audio thread): read, combine, store.
		old := transmute(f32)intrinsics.atomic_load(&m.peak[c])
		if pk > old do intrinsics.atomic_store(&m.peak[c], transmute(u32)pk)
		total := transmute(f64)intrinsics.atomic_load(&m.sum[c]) + sq
		intrinsics.atomic_store(&m.sum[c], transmute(u64)total)
	}
	intrinsics.atomic_add(&m.count, u64(ctx.frames))
}
