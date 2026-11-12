// Simulated audio driver for tests and headless runs. It produces callbacks of
// fixed or jittery size in any native format and plane layout, can loop
// outputs back to inputs with a fixed latency, and can inject xruns, device
// loss and format changes. See /design/backend/.
package fake

import "base:intrinsics"
import "core:mem"
import "core:thread"
import "core:time"

import "fire:backend"
import "fire:core"
import "fire:rt"

// One simulated device, as listed by enumerate. Strings and slices are borrowed
// and must outlive the driver.
Device_Spec :: struct {
	id, name:              string, // stable ID and display name
	input_channels:        int,
	output_channels:       int,
	sample_rates:          []f64, // Hz; open accepts only these
	buffer_sizes:          []int, // frames; open accepts only these
	default_sample_rate:   f64,   // Hz
	default_buffer_frames: int,   // frames
	input_names, output_names: []string, // its channels' names (nil: none)
}

// How the fake driver behaves. Start from default_config.
Config :: struct {
	devices:          []Device_Spec, // nil = one 2-in/2-out device, id "fake:default"
	input_format:     backend.Sample_Format, // native format of the input planes
	output_format:    backend.Sample_Format, // native format of the output planes
	// Channels per plane. 0 = all channels interleaved in one plane;
	// 1 = one plane per channel (non-interleaved).
	input_plane_channels:  int,
	output_plane_channels: int,
	// Callback sizes. jitter_max == 0 → every callback is buffer_frames long.
	// Otherwise sizes are uniform in [jitter_min, jitter_max].
	jitter_min, jitter_max: int,
	seed:             u64, // seeds the jitter sequence
	// < 0: inputs are silent. >= 0: output channel k reappears on input
	// channel k this many frames later. Must be >= the largest callback.
	loopback_latency: int,
	// Reported in Device_Format and used for the input/output timestamps.
	input_latency_frames, output_latency_frames: int,
	// Threaded mode runs callbacks on a thread of its own after start;
	// otherwise the test drives them with `run`.
	threaded: bool,
	realtime: bool, // threaded mode: sleep one buffer duration per callback
	start_ns: u64,  // manual mode: host time of frame 0 (deterministic timestamps)
}

// Defaults: the built-in 2-in/2-out device, f32 interleaved, fixed-size
// callbacks, no loopback, manual mode with start_ns = 1 s.
default_config :: proc() -> Config {
	return {loopback_latency = -1, start_ns = 1_000_000_000}
}

@(private) default_rates := [?]f64{44_100, 48_000, 96_000}
@(private) default_sizes := [?]int{16, 32, 64, 128, 256, 512, 1024, 2048}
@(private) default_devices := [?]Device_Spec {
	{
		id = "fake:default", name = "Fake Device",
		input_channels = 2, output_channels = 2,
		sample_rates = default_rates[:], buffer_sizes = default_sizes[:],
		default_sample_rate = 48_000, default_buffer_frames = 256,
	},
}

// A fake driver instance. Fields are internal.
Fake :: struct {
	driver:      backend.Driver,
	cfg:         Config,
	allocator:   mem.Allocator,
	spec:        Device_Spec,
	format:      backend.Device_Format,
	max_frames:  int,

	in_storage:  []u8,
	out_storage: []u8,
	in_planes:   []backend.Driver_Plane,
	out_planes:  []backend.Driver_Plane,
	scratch:     []f32,
	ring:        []f32, // loopback, ring_len frames per looped channel
	ring_len:    int,
	looped:      int,   // channels looped back

	frame:       i64, // frames delivered since start
	last_frames: int,
	rng:         u64,
	open:        bool,
	started:     bool,
	thread:      ^thread.Thread,

	// Shared with the callback thread.
	stop_flag:   bool,
	unplugged:   bool,
	absent:      bool, // atomic: opening fails (see set_absent)
	xrun_next:   bool,
	callbacks:   u64,
}

// Makes a fake driver. Free it with backend.driver_destroy(driver(f)); that
// frees `f` too. `cfg.devices` is borrowed, not copied. Control thread.
create :: proc(cfg: Config, allocator := context.allocator) -> ^Fake {
	f := new(Fake, allocator)
	f.cfg = cfg
	if f.cfg.devices == nil do f.cfg.devices = default_devices[:]
	f.allocator = allocator
	f.driver = {vtable = &fake_vtable, name = "Fake", data = f}
	return f
}

// The backend.Driver to pass to backend.device_init. Owned by `f`.
driver :: proc(f: ^Fake) -> ^backend.Driver {
	return &f.driver
}

// Manual mode: run `n` driver callbacks on the calling thread. Returns the
// frames delivered. Does nothing once unplugged or when not started.
run :: proc(f: ^Fake, n: int) -> (frames: int) {
	assert(!f.cfg.threaded, "run is for manual mode")
	if !f.started do return 0
	for _ in 0 ..< n {
		if intrinsics.atomic_load(&f.unplugged) do break
		frames += cycle(f, f.cfg.start_ns + u64(f64(f.frame) * 1e9 / f.format.sample_rate))
	}
	return
}

// The next callback reports a discontinuity.
inject_xrun :: proc(f: ^Fake) {
	intrinsics.atomic_store(&f.xrun_next, true)
}

// The open device disappears: callbacks stop and Device_Lost and
// Devices_Changed are posted.
unplug :: proc(f: ^Fake) {
	intrinsics.atomic_store(&f.unplugged, true)
	backend.driver_notify(f.driver.host, {kind = .Device_Lost})
	backend.driver_notify(f.driver.host, {kind = .Devices_Changed})
}

// While true, opening fails as though the device were still unplugged
// (until set false again). Lets tests keep a device away for a while.
set_absent :: proc(f: ^Fake, absent: bool) {
	intrinsics.atomic_store(&f.absent, absent)
}

// The device reports a format change (as when another app changes its rate).
change_format :: proc(f: ^Fake) {
	backend.driver_notify(f.driver.host, {kind = .Format_Changed})
}

// Number of driver callbacks delivered so far. Safe from any thread.
callback_count :: proc(f: ^Fake) -> u64 {
	return intrinsics.atomic_load(&f.callbacks)
}

// The native output buffers of the most recent callback.
last_output :: proc(f: ^Fake) -> (planes: []backend.Driver_Plane, frames: int) {
	return f.out_planes, f.last_frames
}

// --- driver vtable -------------------------------------------------------------

@(private)
fake_vtable := backend.Driver_VTable {
	destroy   = fake_destroy,
	enumerate = fake_enumerate,
	open      = fake_open,
	start     = fake_start,
	stop      = fake_stop,
	close     = fake_close,
}

@(private)
fake_destroy :: proc(d: ^backend.Driver) {
	f := (^Fake)(d.data)
	fake_stop(d)
	fake_close(d)
	free(f, f.allocator)
}

@(private)
fake_enumerate :: proc(d: ^backend.Driver, allocator: mem.Allocator) -> ([]backend.Device_Info, core.Error) {
	f := (^Fake)(d.data)
	infos, err := make([]backend.Device_Info, len(f.cfg.devices), allocator)
	if err != nil do return nil, .Out_Of_Memory
	for spec, i in f.cfg.devices {
		info := &infos[i]
		ok := true
		info.id, err = clone_string(spec.id, allocator); ok &&= err == nil
		info.name, err = clone_string(spec.name, allocator); ok &&= err == nil
		info.sample_rates, err = clone_slice(spec.sample_rates, allocator); ok &&= err == nil
		info.buffer_sizes, err = clone_slice(spec.buffer_sizes, allocator); ok &&= err == nil
		info.input_channels = spec.input_channels
		info.output_channels = spec.output_channels
		names :: proc(src: []string, allocator: mem.Allocator) -> []string {
			if src == nil do return nil
			out := make([]string, len(src), allocator)
			for n, k in src do out[k], _ = clone_string(n, allocator)
			return out
		}
		info.input_channel_names = names(spec.input_names, allocator)
		info.output_channel_names = names(spec.output_names, allocator)
		info.default_sample_rate = spec.default_sample_rate
		info.default_buffer_frames = spec.default_buffer_frames
		info.is_default_input = i == 0
		info.is_default_output = i == 0
		if !ok {
			backend.device_infos_destroy(infos, allocator)
			return nil, .Out_Of_Memory
		}
	}
	return infos, .None
}

@(private)
fake_open :: proc(d: ^backend.Driver, setup: backend.Device_Setup) -> (backend.Device_Format, core.Error) {
	f := (^Fake)(d.data)
	if f.open do return {}, .Invalid_State
	if intrinsics.atomic_load(&f.absent) do return {}, .Device_Error
	if setup.input_device_id != "" && setup.output_device_id != "" && setup.input_device_id != setup.output_device_id {
		return {}, .Unsupported
	}
	id := setup.output_device_id if setup.output_device_id != "" else setup.input_device_id
	spec, found := find_device(f, id)
	if !found do return {}, .Invalid_Argument

	all_in := backend.Channel_Mask{}
	all_out := backend.Channel_Mask{}
	for c in 0 ..< spec.input_channels do all_in += {c}
	for c in 0 ..< spec.output_channels do all_out += {c}
	if setup.input_channels - all_in != {} || setup.output_channels - all_out != {} do return {}, .Invalid_Argument

	rate := setup.sample_rate if setup.sample_rate > 0 else spec.default_sample_rate
	frames := setup.buffer_frames if setup.buffer_frames > 0 else spec.default_buffer_frames
	if !contains(spec.sample_rates, rate) || !contains(spec.buffer_sizes, frames) do return {}, .Unsupported

	f.spec = spec
	f.max_frames = max(frames, f.cfg.jitter_max)
	if f.cfg.loopback_latency >= 0 && f.cfg.loopback_latency < f.max_frames do return {}, .Invalid_Argument
	f.format = {
		sample_rate            = rate,
		buffer_frames          = frames,
		max_driver_frames      = f.max_frames,
		input_channels         = setup.input_channels,
		output_channels        = setup.output_channels,
		device_input_channels  = spec.input_channels,
		device_output_channels = spec.output_channels,
		input_format           = f.cfg.input_format,
		output_format          = f.cfg.output_format,
		input_latency_frames   = f.cfg.input_latency_frames,
		output_latency_frames  = f.cfg.output_latency_frames,
	}
	if alloc_buffers(f) != nil {
		free_buffers(f)
		return {}, .Out_Of_Memory
	}
	f.open = true
	return f.format, .None
}

@(private)
fake_start :: proc(d: ^backend.Driver) -> core.Error {
	f := (^Fake)(d.data)
	if !f.open || f.started do return .Invalid_State
	f.frame = 0
	f.rng = f.cfg.seed
	f.last_frames = 0
	for &s in f.ring do s = 0
	intrinsics.atomic_store(&f.callbacks, 0)
	intrinsics.atomic_store(&f.stop_flag, false)
	f.started = true
	if f.cfg.threaded {
		f.thread = thread.create_and_start_with_data(f, thread_main)
		if f.thread == nil {
			f.started = false
			return .Device_Error
		}
	}
	return .None
}

@(private)
fake_stop :: proc(d: ^backend.Driver) {
	f := (^Fake)(d.data)
	if !f.started do return
	if f.thread != nil {
		intrinsics.atomic_store(&f.stop_flag, true)
		thread.join(f.thread)
		thread.destroy(f.thread)
		f.thread = nil
	}
	f.started = false
}

@(private)
fake_close :: proc(d: ^backend.Driver) {
	f := (^Fake)(d.data)
	if !f.open do return
	free_buffers(f)
	f.open = false
	intrinsics.atomic_store(&f.unplugged, false)
}

// --- callback simulation -------------------------------------------------------

@(private)
thread_main :: proc(data: rawptr) {
	f := (^Fake)(data)
	for !intrinsics.atomic_load(&f.stop_flag) {
		if intrinsics.atomic_load(&f.unplugged) {
			time.sleep(time.Millisecond)
			continue
		}
		frames := cycle(f, rt.host_time_ns())
		if f.cfg.realtime {
			time.sleep(time.Duration(f64(frames) * 1e9 / f.format.sample_rate))
		} else if intrinsics.atomic_load(&f.callbacks) % 256 == 0 {
			// Rarely: on a loaded machine with long scheduler quanta
			// (Windows Server), each yield can cost most of a second.
			thread.yield()
		}
	}
}

// One OS callback: fill inputs, call the host, capture outputs for loopback.
@(private)
cycle :: proc(f: ^Fake, now_ns: u64) -> int {
	n := next_size(f)
	fill_inputs(f, n)
	// OS buffers arrive holding stale data; the layer must overwrite every byte.
	for &b in f.out_storage do b = 0x7F

	ns_per_frame := 1e9 / f.format.sample_rate
	buf := backend.Driver_Buffers {
		frames      = n,
		input       = f.in_planes,
		output      = f.out_planes,
		callback_ns = now_ns,
		input_ns    = now_ns - u64(f64(f.format.input_latency_frames) * ns_per_frame),
		output_ns   = now_ns + u64(f64(f.format.output_latency_frames) * ns_per_frame),
		xrun        = intrinsics.atomic_exchange(&f.xrun_next, false),
	}
	backend.driver_process(f.driver.host, &buf)

	capture_outputs(f, n)
	f.frame += i64(n)
	f.last_frames = n
	intrinsics.atomic_add(&f.callbacks, 1)
	return n
}

@(private)
next_size :: proc(f: ^Fake) -> int {
	if f.cfg.jitter_max <= 0 do return f.format.buffer_frames
	lo, hi := max(f.cfg.jitter_min, 1), f.cfg.jitter_max
	// SplitMix64
	f.rng += 0x9E3779B97F4A7C15
	z := f.rng
	z = (z ~ (z >> 30)) * 0xBF58476D1CE4E5B9
	z = (z ~ (z >> 27)) * 0x94D049BB133111EB
	z ~= z >> 31
	return lo + int(z % u64(hi - lo + 1))
}

@(private)
fill_inputs :: proc(f: ^Fake, n: int) {
	bytes := backend.sample_format_bytes(f.format.input_format)
	for ch in 0 ..< f.spec.input_channels {
		data, stride := locate(f.in_planes, ch, bytes)
		src := f.scratch[:n]
		for &s, i in src {
			s = 0
			if ch < f.looped {
				t := f.frame + i64(i) - i64(f.cfg.loopback_latency)
				if t >= 0 do s = f.ring[ch * f.ring_len + int(t % i64(f.ring_len))]
			}
		}
		backend.write_samples(src, data, stride, f.format.input_format)
	}
}

@(private)
capture_outputs :: proc(f: ^Fake, n: int) {
	bytes := backend.sample_format_bytes(f.format.output_format)
	for ch in 0 ..< f.looped {
		data, stride := locate(f.out_planes, ch, bytes)
		dst := f.scratch[:n]
		backend.read_samples(dst, data, stride, f.format.output_format)
		for s, i in dst {
			t := f.frame + i64(i)
			f.ring[ch * f.ring_len + int(t % i64(f.ring_len))] = s
		}
	}
}

@(private)
locate :: proc(planes: []backend.Driver_Plane, ch, bytes: int) -> (rawptr, int) {
	first := 0
	for p in planes {
		if ch < first + p.channels do return &([^]u8)(p.data)[(ch - first) * bytes], p.channels * bytes
		first += p.channels
	}
	unreachable()
}

// --- buffers -------------------------------------------------------------------

@(private)
alloc_buffers :: proc(f: ^Fake) -> (err: mem.Allocator_Error) {
	a := f.allocator
	f.in_storage, f.in_planes = make_planes(f.spec.input_channels, f.cfg.input_plane_channels, f.max_frames, f.cfg.input_format, a) or_return
	f.out_storage, f.out_planes = make_planes(f.spec.output_channels, f.cfg.output_plane_channels, f.max_frames, f.cfg.output_format, a) or_return
	f.scratch = make([]f32, f.max_frames, a) or_return
	if f.cfg.loopback_latency >= 0 {
		f.looped = min(f.spec.input_channels, f.spec.output_channels)
		f.ring_len = f.cfg.loopback_latency + f.max_frames
		f.ring = make([]f32, f.looped * f.ring_len, a) or_return
	}
	return nil
}

@(private)
make_planes :: proc(channels, per_plane, frames: int, format: backend.Sample_Format, a: mem.Allocator) -> (storage: []u8, planes: []backend.Driver_Plane, err: mem.Allocator_Error) {
	if channels == 0 do return
	per := per_plane if per_plane > 0 else channels
	count := (channels + per - 1) / per
	bytes := backend.sample_format_bytes(format)
	storage = make([]u8, channels * frames * bytes, a) or_return
	planes = make([]backend.Driver_Plane, count, a) or_return
	offset := 0
	for &p, i in planes {
		p.channels = min(per, channels - i * per)
		p.data = &storage[offset]
		offset += p.channels * frames * bytes
	}
	return
}

@(private)
free_buffers :: proc(f: ^Fake) {
	a := f.allocator
	delete(f.in_storage, a)
	delete(f.out_storage, a)
	delete(f.in_planes, a)
	delete(f.out_planes, a)
	delete(f.scratch, a)
	delete(f.ring, a)
	f.in_storage, f.out_storage = nil, nil
	f.in_planes, f.out_planes = nil, nil
	f.scratch, f.ring = nil, nil
	f.looped, f.ring_len = 0, 0
}

// --- helpers -------------------------------------------------------------------

@(private)
find_device :: proc(f: ^Fake, id: string) -> (Device_Spec, bool) {
	if id == "" {
		if len(f.cfg.devices) == 0 do return {}, false
		return f.cfg.devices[0], true
	}
	for spec in f.cfg.devices do if spec.id == id do return spec, true
	return {}, false
}

@(private)
contains :: proc(xs: []$T, x: T) -> bool {
	for v in xs do if v == x do return true
	return false
}

@(private)
clone_string :: proc(s: string, a: mem.Allocator) -> (string, mem.Allocator_Error) {
	b, err := make([]u8, len(s), a)
	if err != nil do return "", err
	copy(b, s)
	return string(b), nil
}

@(private)
clone_slice :: proc(s: []$T, a: mem.Allocator) -> ([]T, mem.Allocator_Error) {
	out, err := make([]T, len(s), a)
	if err != nil do return nil, err
	copy(out, s)
	return out, nil
}
