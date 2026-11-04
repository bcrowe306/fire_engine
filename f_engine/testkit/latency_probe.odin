package testkit

import "core:time"

import "fire:backend"
import "fire:core"
import "fire:record"

// Runs a `record.Latency_Probe` on an opened (not started) device, from
// its first input channel to every output channel, and returns what it
// measured. Starts and stops the device.
run_latency_probe :: proc(dev: ^backend.Device, timeout := 10 * time.Second) -> (frames: int, quality: f64, ok: bool) {
	node, probe, _ := record.latency_probe_create({max_seconds = 0.5})
	defer core.node_destroy(&node)
	if core.node_prepare(&node, {sample_rate = dev.format.sample_rate, max_block = dev.max_block}) != .None do return
	cb := backend.Device_Callback {
		process = proc(user: rawptr, b: ^backend.Io_Block) {
			n := (^core.Node)(user)
			ctx := core.Process_Context{inputs = b.inputs[:min(len(b.inputs), 1)], outputs = b.outputs[:min(len(b.outputs), 1)], frames = b.frames}
			core.node_process(n, &ctx)
			for o in b.outputs[1:] do copy(o, b.outputs[0])
		},
		user = &node,
	}
	if backend.device_start(dev, cb) != .None do return
	defer backend.device_stop(dev)
	time.sleep(300 * time.Millisecond) // let the stream settle (VB-CABLE adjusts its latency in its first ~50 ms)
	record.latency_probe_start(probe)
	for start := time.tick_now(); time.tick_since(start) < timeout; {
		if frames, quality, ok = record.latency_probe_result(probe); ok do return
		time.sleep(5 * time.Millisecond)
	}
	return
}
