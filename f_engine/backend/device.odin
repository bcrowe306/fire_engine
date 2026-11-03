package backend

import "base:intrinsics"
import "base:runtime"
import "core:mem"
import "core:sync"
import "core:time"

import "fire:core"
import "fire:rt"

Device_State :: enum u8 {
	Closed,
	Open,
	Running,
}

Device_Stats :: struct {
	callbacks: u64, // driver callbacks
	blocks:    u64, // Device_Callback.process calls
	frames:    u64,
	xruns:     u64,
	overloads: u64, // driver callbacks that took longer than their real-time budget
	load:      f64, // last driver callback: elapsed / budget
	peak_load: f64, // since start or the last device_reset_peak_load
}

@(private) EVENT_RING :: 64

// Address of one selected channel inside the OS buffers for the current callback.
@(private)
Sample_Ref :: struct {
	data:   [^]u8, // nil = channel not present in this callback's planes
	stride: int,   // bytes between frames
}

// The shared layer between a driver and the application. One open device at a
// time. All procs except `driver_process` run on the control thread.
Device :: struct {
	driver:       ^Driver,
	allocator:    mem.Allocator,
	// Installed as context.allocator and context.temp_allocator during the
	// realtime callback. Defaults to the nil allocator.
	rt_allocator: mem.Allocator,
	state:        Device_State,
	format:       Device_Format,
	max_block:    int,
	callback:     Device_Callback,

	// Owned by the audio thread while running; sized in device_open.
	in_storage:   []f32,
	out_storage:  []f32,
	in_bufs:      [][]f32, // per selected channel, len max_block
	out_bufs:     [][]f32,
	in_views:     [][]f32, // in_bufs[c][:frames] for the current chunk
	out_views:    [][]f32,
	in_channels:  []int,   // device channel index of each selected channel
	out_channels: []int,
	in_refs:      []Sample_Ref,
	out_refs:     []Sample_Ref,
	sample_time:  i64,
	pending_xrun: bool,
	running:      bool, // atomic; gates driver_process

	// Written by the audio thread, read by the control thread.
	stat_callbacks: u64,
	stat_blocks:    u64,
	stat_frames:    u64,
	stat_xruns:     u64,
	stat_overloads: u64,
	stat_load:      u64, // f64 bits
	stat_peak_load: u64, // f64 bits

	// Driver notification thread → control thread.
	event_lock:     sync.Mutex,
	events:         [EVENT_RING]Device_Event,
	event_head:     int,
	event_count:    int,
	events_dropped: int,
	xruns_reported: u64, // control thread only
}

device_init :: proc(dev: ^Device, driver: ^Driver, allocator := context.allocator) {
	assert(driver != nil && driver.vtable != nil)
	dev^ = {}
	dev.driver = driver
	dev.allocator = allocator
	dev.rt_allocator = runtime.nil_allocator()
}

// Closes the device if needed. Does not destroy the driver.
device_destroy :: proc(dev: ^Device) {
	device_close(dev)
}

device_open :: proc(dev: ^Device, setup: Device_Setup, max_block: int) -> core.Error {
	if dev.state != .Closed do return .Invalid_State
	if max_block <= 0 do return .Invalid_Argument
	if setup.input_channels == {} && setup.output_channels == {} do return .Invalid_Argument

	dev.driver.host = dev
	format, err := dev.driver.vtable.open(dev.driver, setup)
	if err != .None {
		dev.driver.host = nil
		return err
	}
	if format.sample_rate <= 0 {
		dev.driver.vtable.close(dev.driver)
		dev.driver.host = nil
		return .Device_Error
	}
	dev.format = format
	dev.max_block = max_block

	if alloc_err := device_alloc_buffers(dev); alloc_err != .None {
		device_free_buffers(dev)
		dev.driver.vtable.close(dev.driver)
		dev.driver.host = nil
		return .Out_Of_Memory
	}
	dev.state = .Open
	return .None
}

device_start :: proc(dev: ^Device, callback: Device_Callback) -> core.Error {
	if dev.state != .Open do return .Invalid_State
	if callback.process == nil do return .Invalid_Argument

	cfg := core.Prepare_Config {
		sample_rate  = dev.format.sample_rate,
		max_block    = dev.max_block,
		in_channels  = len(dev.in_bufs),
		out_channels = len(dev.out_bufs),
	}
	if callback.prepare != nil {
		callback.prepare(callback.user, cfg) or_return
	}

	dev.callback = callback
	dev.sample_time = 0
	dev.pending_xrun = false
	reset_stats(dev)
	intrinsics.atomic_store_explicit(&dev.running, true, .Release)

	if err := dev.driver.vtable.start(dev.driver); err != .None {
		intrinsics.atomic_store_explicit(&dev.running, false, .Release)
		if callback.release != nil do callback.release(callback.user)
		dev.callback = {}
		return err
	}
	dev.state = .Running
	return .None
}

// Returns once no further callbacks can happen.
device_stop :: proc(dev: ^Device) {
	if dev.state != .Running do return
	dev.driver.vtable.stop(dev.driver)
	intrinsics.atomic_store_explicit(&dev.running, false, .Release)
	if dev.callback.release != nil do dev.callback.release(dev.callback.user)
	dev.callback = {}
	dev.state = .Open
}

device_close :: proc(dev: ^Device) {
	if dev.state == .Closed do return
	device_stop(dev)
	dev.driver.vtable.close(dev.driver)
	dev.driver.host = nil
	device_free_buffers(dev)
	dev.format = {}
	dev.state = .Closed
}

// Control thread. Returns pending xruns first, then driver events in order.
device_poll_event :: proc(dev: ^Device) -> (e: Device_Event, ok: bool) {
	xruns := intrinsics.atomic_load_explicit(&dev.stat_xruns, .Acquire)
	if xruns != dev.xruns_reported {
		e = {kind = .Xrun, count = int(xruns - dev.xruns_reported)}
		dev.xruns_reported = xruns
		return e, true
	}
	sync.mutex_lock(&dev.event_lock)
	defer sync.mutex_unlock(&dev.event_lock)
	if dev.event_count == 0 do return {}, false
	e = dev.events[dev.event_head]
	dev.event_head = (dev.event_head + 1) % EVENT_RING
	dev.event_count -= 1
	return e, true
}

device_stats :: proc(dev: ^Device) -> Device_Stats {
	load :: proc(p: ^u64) -> u64 { return intrinsics.atomic_load_explicit(p, .Relaxed) }
	return {
		callbacks = load(&dev.stat_callbacks),
		blocks    = load(&dev.stat_blocks),
		frames    = load(&dev.stat_frames),
		xruns     = load(&dev.stat_xruns),
		overloads = load(&dev.stat_overloads),
		load      = transmute(f64)load(&dev.stat_load),
		peak_load = transmute(f64)load(&dev.stat_peak_load),
	}
}

// Benign race: a peak written by a callback running concurrently may survive.
device_reset_peak_load :: proc(dev: ^Device) {
	intrinsics.atomic_store_explicit(&dev.stat_peak_load, 0, .Relaxed)
}

// Called by drivers from their notification thread (never the audio thread).
driver_notify :: proc(dev: ^Device, e: Device_Event) {
	if dev == nil do return
	sync.mutex_lock(&dev.event_lock)
	defer sync.mutex_unlock(&dev.event_lock)
	if dev.event_count == EVENT_RING {
		dev.events_dropped += 1
		return
	}
	dev.events[(dev.event_head + dev.event_count) % EVENT_RING] = e
	dev.event_count += 1
}

// [rt] Called by drivers from the OS audio thread, once per OS callback.
// `buf.frames` may be any size; it is processed in chunks of at most max_block.
driver_process :: proc "contextless" (dev: ^Device, buf: ^Driver_Buffers) {
	context = runtime.default_context()
	context.allocator = dev.rt_allocator
	context.temp_allocator = dev.rt_allocator

	start := time.tick_now()
	fp := rt.enable_flush_to_zero()
	defer rt.restore_fp_state(fp)

	silence_planes(buf.output, buf.frames, dev.format.output_format)
	if !intrinsics.atomic_load_explicit(&dev.running, .Acquire) || buf.frames <= 0 do return

	if buf.xrun {
		intrinsics.atomic_add_explicit(&dev.stat_xruns, 1, .Release)
		dev.pending_xrun = true
	}
	locate_channels(dev.in_refs, dev.in_channels, buf.input, dev.format.input_format)
	locate_channels(dev.out_refs, dev.out_channels, buf.output, dev.format.output_format)

	sr := dev.format.sample_rate
	callback_ns := buf.callback_ns != 0 ? buf.callback_ns : rt.host_time_ns()

	block := Io_Block {
		inputs      = dev.in_views,
		outputs     = dev.out_views,
		sample_rate = sr,
		callback_ns = callback_ns,
	}
	chunks: u64
	for pos := 0; pos < buf.frames; {
		n := min(dev.max_block, buf.frames - pos)
		for &v, c in dev.in_views {
			v = dev.in_bufs[c][:n]
			ref := dev.in_refs[c]
			if ref.data == nil {
				for &s in v do s = 0
			} else {
				read_samples(v, &ref.data[pos * ref.stride], ref.stride, dev.format.input_format)
			}
		}
		for &v, c in dev.out_views {
			v = dev.out_bufs[c][:n]
			for &s in v do s = 0
		}

		offset_ns := u64(f64(pos) * 1e9 / sr)
		block.frames = n
		block.sample_time = dev.sample_time
		block.input_ns = buf.input_ns != 0 ? buf.input_ns + offset_ns : 0
		block.output_ns = buf.output_ns != 0 ? buf.output_ns + offset_ns : 0
		block.xrun = dev.pending_xrun
		dev.pending_xrun = false

		dev.callback.process(dev.callback.user, &block)

		for v, c in dev.out_views {
			ref := dev.out_refs[c]
			if ref.data != nil do write_samples(v, &ref.data[pos * ref.stride], ref.stride, dev.format.output_format)
		}
		dev.sample_time += i64(n)
		pos += n
		chunks += 1
	}

	elapsed_ns := f64(time.tick_since(start))
	budget_ns := f64(buf.frames) * 1e9 / sr
	record_load(dev, elapsed_ns / budget_ns, chunks, u64(buf.frames))
}

// [rt]
@(private)
record_load :: proc "contextless" (dev: ^Device, load: f64, chunks, frames: u64) {
	intrinsics.atomic_add_explicit(&dev.stat_callbacks, 1, .Relaxed)
	intrinsics.atomic_add_explicit(&dev.stat_blocks, chunks, .Relaxed)
	intrinsics.atomic_add_explicit(&dev.stat_frames, frames, .Relaxed)
	if load > 1 do intrinsics.atomic_add_explicit(&dev.stat_overloads, 1, .Relaxed)
	intrinsics.atomic_store_explicit(&dev.stat_load, transmute(u64)load, .Relaxed)
	peak := transmute(f64)intrinsics.atomic_load_explicit(&dev.stat_peak_load, .Relaxed)
	if load > peak do intrinsics.atomic_store_explicit(&dev.stat_peak_load, transmute(u64)load, .Relaxed)
}

// [rt] Finds each selected device channel in this callback's planes.
@(private)
locate_channels :: proc "contextless" (refs: []Sample_Ref, channels: []int, planes: []Driver_Plane, format: Sample_Format) {
	bytes := sample_format_bytes(format)
	for &ref, i in refs {
		ref = {}
		first := 0
		for plane in planes {
			ch := channels[i]
			if ch < first + plane.channels {
				if plane.data != nil {
					ref.data = ([^]u8)(plane.data)[(ch - first) * bytes:]
					ref.stride = plane.channels * bytes
				}
				break
			}
			first += plane.channels
		}
	}
}

// [rt] Unselected device outputs must be silent, so every plane starts zeroed.
@(private)
silence_planes :: proc "contextless" (planes: []Driver_Plane, frames: int, format: Sample_Format) {
	if frames <= 0 do return
	bytes := sample_format_bytes(format)
	for plane in planes {
		if plane.data != nil do intrinsics.mem_zero(plane.data, frames * plane.channels * bytes)
	}
}

@(private)
reset_stats :: proc(dev: ^Device) {
	dev.stat_callbacks = 0
	dev.stat_blocks = 0
	dev.stat_frames = 0
	dev.stat_xruns = 0
	dev.stat_overloads = 0
	dev.stat_load = 0
	dev.stat_peak_load = 0
	dev.xruns_reported = 0
}

@(private)
mask_to_indices :: proc(mask: Channel_Mask, allocator: mem.Allocator) -> (out: []int, err: mem.Allocator_Error) {
	out = make([]int, card(mask), allocator) or_return
	i := 0
	for ch in mask {
		out[i] = ch
		i += 1
	}
	return out, nil
}

@(private)
device_alloc_buffers :: proc(dev: ^Device) -> mem.Allocator_Error {
	a := dev.allocator
	dev.in_channels = mask_to_indices(dev.format.input_channels, a) or_return
	dev.out_channels = mask_to_indices(dev.format.output_channels, a) or_return
	ins, outs := len(dev.in_channels), len(dev.out_channels)

	dev.in_storage = make([]f32, ins * dev.max_block, a) or_return
	dev.out_storage = make([]f32, outs * dev.max_block, a) or_return
	dev.in_bufs = make([][]f32, ins, a) or_return
	dev.out_bufs = make([][]f32, outs, a) or_return
	dev.in_views = make([][]f32, ins, a) or_return
	dev.out_views = make([][]f32, outs, a) or_return
	dev.in_refs = make([]Sample_Ref, ins, a) or_return
	dev.out_refs = make([]Sample_Ref, outs, a) or_return
	for c in 0 ..< ins do dev.in_bufs[c] = dev.in_storage[c * dev.max_block:][:dev.max_block]
	for c in 0 ..< outs do dev.out_bufs[c] = dev.out_storage[c * dev.max_block:][:dev.max_block]
	return nil
}

@(private)
device_free_buffers :: proc(dev: ^Device) {
	a := dev.allocator
	delete(dev.in_channels, a)
	delete(dev.out_channels, a)
	delete(dev.in_storage, a)
	delete(dev.out_storage, a)
	delete(dev.in_bufs, a)
	delete(dev.out_bufs, a)
	delete(dev.in_views, a)
	delete(dev.out_views, a)
	delete(dev.in_refs, a)
	delete(dev.out_refs, a)
	dev.in_channels, dev.out_channels = nil, nil
	dev.in_storage, dev.out_storage = nil, nil
	dev.in_bufs, dev.out_bufs = nil, nil
	dev.in_views, dev.out_views = nil, nil
	dev.in_refs, dev.out_refs = nil, nil
}
