package testkit

import "base:intrinsics"
import "core:time"

import "fire:backend"
import "fire:rt"

// A Device_Callback for real-device tests: plays `play` (mono, on every
// output) and records every input, both indexed by sample_time, and checks the
// block contract and timestamps as it goes.
Loop_Recorder :: struct {
	play:           []f32,    // mono signal played on every output, indexed by sample_time
	rec:            [2][]f32, // first two inputs, indexed by sample_time
	next_time:      i64, // atomic
	gaps:           int, // sample_time discontinuities
	blocks:         u64, // atomic: callbacks so far
	xrun_blocks:    int, // blocks with the xrun flag set
	max_entry_skew: i64, // |host_time_ns() at entry − callback_ns|
	time_order_bad: int, // blocks where input_ns ≤ callback_ns ≤ output_ns fails (known times only)
	non_monotonic:  int, // output_ns did not increase
	last_output_ns: u64,
	stall_ns:       i64, // atomic: sleep this long once, in the next block (forces an xrun)
}

// Allocates a recorder (and its `play` and two `rec` channels of `frames` frames each)
// from `allocator`. Fill `play` before starting the device. Free with
// `loop_recorder_destroy` using the same allocator.
loop_recorder_make :: proc(frames: int, allocator := context.allocator) -> ^Loop_Recorder {
	r := new(Loop_Recorder, allocator)
	r.play = make([]f32, frames, allocator)
	for &c in r.rec do c = make([]f32, frames, allocator)
	return r
}

// Frees a recorder made by `loop_recorder_make`. Pass the allocator it was made with.
loop_recorder_destroy :: proc(r: ^Loop_Recorder, allocator := context.allocator) {
	delete(r.play, allocator)
	for c in r.rec do delete(c, allocator)
	free(r, allocator)
}

// The `backend.Device_Callback` to hand to the device; it runs `loop_recorder_process`
// with `r` as its user pointer. `r` must outlive the stream.
loop_recorder_callback :: proc(r: ^Loop_Recorder) -> backend.Device_Callback {
	return {process = loop_recorder_process, user = r}
}

// [rt] (apart from the deliberate stall)
loop_recorder_process :: proc(user: rawptr, b: ^backend.Io_Block) {
	r := (^Loop_Recorder)(user)
	entry := rt.host_time_ns()
	if b.sample_time != intrinsics.atomic_load(&r.next_time) do r.gaps += 1
	if b.xrun do r.xrun_blocks += 1
	r.max_entry_skew = max(r.max_entry_skew, abs(i64(entry) - i64(b.callback_ns)))
	in_ok := b.input_ns == 0 || b.input_ns <= b.callback_ns
	out_ok := b.output_ns == 0 || b.callback_ns <= b.output_ns
	if !in_ok || !out_ok do r.time_order_bad += 1
	if b.output_ns != 0 {
		if b.output_ns <= r.last_output_ns do r.non_monotonic += 1
		r.last_output_ns = b.output_ns
	}
	for out in b.outputs {
		for &s, i in out {
			t := int(b.sample_time) + i
			s = r.play[t] if t < len(r.play) else 0
		}
	}
	for input, c in b.inputs {
		if c >= len(r.rec) do break
		for s, i in input {
			t := int(b.sample_time) + i
			if t < len(r.rec[c]) do r.rec[c][t] = s
		}
	}
	if stall := intrinsics.atomic_exchange(&r.stall_ns, 0); stall > 0 do time.sleep(time.Duration(stall))
	intrinsics.atomic_store(&r.next_time, b.sample_time + i64(b.frames))
	intrinsics.atomic_add(&r.blocks, 1)
}

// Waits until the recorder has processed `frames` frames. False on timeout.
loop_recorder_wait :: proc(r: ^Loop_Recorder, frames: i64, timeout: time.Duration) -> bool {
	start := time.tick_now()
	for intrinsics.atomic_load(&r.next_time) < frames {
		if time.tick_since(start) > timeout do return false
		time.sleep(time.Millisecond)
	}
	return true
}

// Outcome of `analyze_loopback`. Only meaningful when `found` is true.
Loopback_Result :: struct {
	latency:  int, // frames from play to rec
	gain:     f64, // least-squares rec / play
	residual: f64, // max |rec − gain·play| after alignment
	at:       int, // where the residual peaks
	found:    bool, // false if no positive latency within max_lag, or `play` is silent
}

// Aligns `rec` to `play` and measures how exactly it is a scaled copy.
// `play` must be a non-periodic signal (noise) for the alignment to be unique.
analyze_loopback :: proc(play, rec: []f32, max_lag: int) -> (res: Loopback_Result) {
	res.latency = estimate_latency(play, rec, max_lag)
	if res.latency <= 0 || res.latency >= len(rec) do return
	n := min(len(play), len(rec) - res.latency)
	p, r := play[:n], rec[res.latency:][:n]
	pp, pr: f64
	for i in 0 ..< n {
		pp += f64(p[i]) * f64(p[i])
		pr += f64(p[i]) * f64(r[i])
	}
	if pp == 0 do return
	res.gain = pr / pp
	for i in 0 ..< n {
		e := abs(f64(r[i]) - res.gain * f64(p[i]))
		if e > res.residual do res.residual, res.at = e, i
	}
	res.found = true
	return
}
