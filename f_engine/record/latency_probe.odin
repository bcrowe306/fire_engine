package record

import "base:intrinsics"
import "core:math"
import "core:mem"

import "fire:core"
import "fire:dsp"

// Settings for `latency_probe_create`.
Latency_Probe_Settings :: struct {
	max_seconds:  f64, // longest round trip to look for; 0 = 1 s
	burst_frames: int, // length of the noise burst played; 0 = 4096
	level:        f32, // the burst's peak level, linear; 0 = 0.25 (−12 dBFS)
}

// Measures the round trip a recorder must compensate: plays a noise burst
// on its output and finds it in its input. Connect its output to the
// device output and its input from the device input, with a loopback cable
// between them (or a microphone near a speaker), and keep it in the graph
// where the recorders are. From `latency_probe_create`; the node owns it.
// Fields are internal.
Latency_Probe :: struct {
	settings:  Latency_Probe_Settings,
	burst:     []f32,
	capture:   []f32,
	state:     Probe_State, // atomic
	at:        int, // audio side: frames since the measurement started
	allocator: mem.Allocator,
}

@(private)
Probe_State :: enum u32 {
	Idle,
	Requested, // control → audio
	Running,
	Done,      // audio → control: `capture` is full
}

@(private)
latency_probe_vtable := core.Node_VTable {
	prepare = latency_probe_prepare,
	process = latency_probe_process,
	reset   = proc(self: rawptr) {},
	release = proc(self: rawptr, allocator: mem.Allocator) {
		p := (^Latency_Probe)(self)
		delete(p.burst, allocator)
		delete(p.capture, allocator)
		p.burst, p.capture = nil, nil
	},
	destroy = proc(self: rawptr, allocator: mem.Allocator) {
		p := (^Latency_Probe)(self)
		delete(p.burst, allocator)
		delete(p.capture, allocator)
		free(p, allocator)
	},
	type_id = LATENCY_PROBE_TYPE_ID,
	state_version = 1,
	save    = save_latency_probe,
}

// Control thread. Makes a probe node with one input and one output.
latency_probe_create :: proc(settings: Latency_Probe_Settings, allocator := context.allocator) -> (node: core.Node, p: ^Latency_Probe, err: core.Error) {
	if settings.max_seconds < 0 || settings.burst_frames < 0 do return {}, nil, .Invalid_Argument
	p = new(Latency_Probe, allocator)
	if p == nil do return {}, nil, .Out_Of_Memory
	p.settings, p.allocator = settings, allocator
	if p.settings.max_seconds == 0 do p.settings.max_seconds = 1
	if p.settings.burst_frames == 0 do p.settings.burst_frames = 4096
	if p.settings.level == 0 do p.settings.level = 0.25
	return core.node_make(&latency_probe_vtable, p, allocator), p, .None
}

// Control thread. Starts a measurement at the next block (the probe must
// be in a running graph). It takes `max_seconds` plus the burst.
latency_probe_start :: proc(p: ^Latency_Probe) {
	intrinsics.atomic_store(&p.state, Probe_State.Requested)
}

// Control thread. The measured round trip in frames, once the measurement
// is done (`ok`). `quality` is how cleanly the burst came back: the
// normalised correlation, 1 for a perfect copy at any level; below about
// 0.5, the result is likely wrong (too quiet, or too noisy).
latency_probe_result :: proc(p: ^Latency_Probe) -> (frames: int, quality: f64, ok: bool) {
	if intrinsics.atomic_load(&p.state) != .Done do return 0, 0, false
	defer intrinsics.atomic_store(&p.state, Probe_State.Idle)
	return correlate(p.burst, p.capture)
}

@(private)
latency_probe_prepare :: proc(self: rawptr, cfg: core.Prepare_Config, allocator: mem.Allocator) -> core.Error {
	p := (^Latency_Probe)(self)
	n := p.settings.burst_frames
	p.burst = make([]f32, n, allocator)
	p.capture = make([]f32, n + int(p.settings.max_seconds * cfg.sample_rate), allocator)
	if p.burst == nil || p.capture == nil do return .Out_Of_Memory
	seed := u32(0x9E3779B9)
	for &x, i in p.burst {
		seed ~= seed << 13
		seed ~= seed >> 17
		seed ~= seed << 5
		fade := f32(min(1, f64(min(i, n - 1 - i)) / 64)) // 64-frame fades: no clicks
		x = p.settings.level * fade * (f32(seed) / f32(max(u32)) * 2 - 1)
	}
	return .None
}

// [rt]
@(private)
latency_probe_process :: proc(self: rawptr, ctx: ^core.Process_Context) {
	p := (^Latency_Probe)(self)
	out := ctx.outputs[0] if len(ctx.outputs) > 0 else nil
	for &x in out do x = 0
	state := intrinsics.atomic_load(&p.state)
	if state == .Requested {
		p.at, state = 0, .Running
		intrinsics.atomic_store(&p.state, state)
	}
	if state != .Running do return
	for i in 0 ..< ctx.frames {
		f := p.at + i
		if f >= len(p.capture) {
			intrinsics.atomic_store(&p.state, Probe_State.Done)
			return
		}
		if f < len(p.burst) && out != nil do out[i] = p.burst[f]
		p.capture[f] = ctx.inputs[0][i] if len(ctx.inputs) > 0 else 0
	}
	p.at += ctx.frames
	if p.at >= len(p.capture) do intrinsics.atomic_store(&p.state, Probe_State.Done)
}

// The lag at which `burst` best matches `capture`, by FFT cross-correlation,
// and the normalised correlation there.
@(private)
correlate :: proc(burst, capture: []f32) -> (lag: int, quality: f64, ok: bool) {
	size := dsp.fft_fast_size_above(len(capture) + len(burst))
	f: dsp.Fft
	if dsp.fft_init(&f, size, context.temp_allocator) != .None do return 0, 0, false
	a := make([]complex64, size, context.temp_allocator)
	b := make([]complex64, size, context.temp_allocator)
	for x, i in capture do a[i] = complex(x, 0)
	for x, i in burst do b[i] = complex(x, 0)
	dsp.fft_forward(&f, a, a)
	dsp.fft_forward(&f, b, b)
	for i in 0 ..< size do a[i] *= conj(b[i])
	dsp.fft_inverse(&f, a, a)
	best := -math.F64_MAX
	for i in 0 ..= len(capture) - len(burst) {
		if v := f64(real(a[i])); v > best do best, lag = v, i
	}
	energy_b, energy_c: f64
	for x in burst do energy_b += f64(x) * f64(x)
	for x in capture[lag:][:len(burst)] do energy_c += f64(x) * f64(x)
	if energy_b <= 0 || energy_c <= 0 do return lag, 0, true
	return lag, best / f64(size) / math.sqrt(energy_b * energy_c), true
}
