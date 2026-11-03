#+build darwin
// CoreAudio HAL driver: one device, driven by an AudioDeviceIOProc.
// See docs/design/backend.md. The HAL hands IOProcs canonical f32 buffers, one
// AudioBuffer per stream, so the device's AudioBufferList maps 1:1 onto planes.
package coreaudio

import "base:intrinsics"
import "base:runtime"
import "core:mem"
import CF "core:sys/darwin/CoreFoundation"
import "core:time"

import "fire:backend"
import "fire:core"
import ca "fire:sys/coreaudio"

Core_Audio :: struct {
	driver:     backend.Driver,
	allocator:  mem.Allocator,
	device:     ca.AudioObjectID,
	proc_id:    ca.AudioDeviceIOProcID,
	format:     backend.Device_Format,
	in_planes:  []backend.Driver_Plane, // one per input stream
	out_planes: []backend.Driver_Plane,
	is_open:    bool,
	started:    bool,

	// Shared with the IO thread.
	active:      bool, // atomic
	in_callback: i32,  // atomic
	overload:    bool, // atomic; set by the listener, consumed as an xrun

	// IO thread only.
	expected_sample_time: f64,
	have_expected:        bool,
}

create :: proc(allocator := context.allocator) -> ^backend.Driver {
	c := new(Core_Audio, allocator)
	c.allocator = allocator
	c.driver = {vtable = &ca_vtable, name = "CoreAudio", data = c}
	// Deliver property notifications on the HAL's own thread, so listeners work
	// without a CFRunLoop on the main thread (command-line apps, tests).
	run_loop: rawptr = nil
	a := addr(ca.kAudioHardwarePropertyRunLoop)
	ca.AudioObjectSetPropertyData(ca.kAudioObjectSystemObject, &a, 0, nil, size_of(run_loop), &run_loop)
	return &c.driver
}

@(private)
ca_vtable := backend.Driver_VTable {
	destroy   = ca_destroy,
	enumerate = ca_enumerate,
	open      = ca_open,
	start     = ca_start,
	stop      = ca_stop,
	close     = ca_close,
}

@(private)
ca_destroy :: proc(d: ^backend.Driver) {
	c := (^Core_Audio)(d.data)
	ca_stop(d)
	ca_close(d)
	free(c, c.allocator)
}

// --- enumeration ------------------------------------------------------------------

@(private)
STANDARD_RATES := [?]f64{22_050, 32_000, 44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000}

@(private)
ca_enumerate :: proc(d: ^backend.Driver, allocator: mem.Allocator) -> ([]backend.Device_Info, core.Error) {
	ids, ok := get_array(ca.kAudioObjectSystemObject, ca.kAudioHardwarePropertyDevices, ca.AudioObjectID, context.temp_allocator)
	if !ok do return nil, .Device_Error
	default_in, _ := get_value(ca.kAudioObjectSystemObject, ca.kAudioHardwarePropertyDefaultInputDevice, ca.AudioObjectID)
	default_out, _ := get_value(ca.kAudioObjectSystemObject, ca.kAudioHardwarePropertyDefaultOutputDevice, ca.AudioObjectID)

	infos := make([dynamic]backend.Device_Info, 0, len(ids), allocator)
	for id in ids {
		info, info_ok := device_info(id, allocator)
		if !info_ok do continue // the device vanished while we were looking
		info.is_default_input = id == default_in
		info.is_default_output = id == default_out
		append(&infos, info)
	}
	return infos[:], .None
}

@(private)
device_info :: proc(id: ca.AudioObjectID, allocator: mem.Allocator) -> (info: backend.Device_Info, ok: bool) {
	info.id = get_string(id, ca.kAudioDevicePropertyDeviceUID, allocator) or_return
	info.name, _ = get_string(id, ca.kAudioObjectPropertyName, allocator)
	info.input_channels, _ = channel_count(id, ca.kAudioObjectPropertyScopeInput)
	info.output_channels, _ = channel_count(id, ca.kAudioObjectPropertyScopeOutput)

	rates := make([dynamic]f64, 0, 8, allocator)
	ranges, _ := get_array(id, ca.kAudioDevicePropertyAvailableNominalSampleRates, ca.AudioValueRange, context.temp_allocator)
	for r in ranges {
		if r.mMinimum == r.mMaximum {
			append_unique(&rates, r.mMinimum)
		} else {
			for sr in STANDARD_RATES do if sr >= r.mMinimum && sr <= r.mMaximum do append_unique(&rates, sr)
		}
	}
	info.sample_rates = rates[:]

	sizes := make([dynamic]int, 0, 12, allocator)
	current_frames, _ := get_value(id, ca.kAudioDevicePropertyBufferFrameSize, u32)
	if size_range, range_ok := get_value(id, ca.kAudioDevicePropertyBufferFrameSizeRange, ca.AudioValueRange); range_ok {
		for n := 16; n <= 4096; n *= 2 {
			if f64(n) >= size_range.mMinimum && f64(n) <= size_range.mMaximum do append(&sizes, n)
		}
	}
	append_unique(&sizes, int(current_frames))
	info.buffer_sizes = sizes[:]
	info.default_sample_rate, _ = get_value(id, ca.kAudioDevicePropertyNominalSampleRate, f64)
	info.default_buffer_frames = int(current_frames)
	return info, true
}

// --- open / close -------------------------------------------------------------------

@(private)
ca_open :: proc(d: ^backend.Driver, setup: backend.Device_Setup) -> (backend.Device_Format, core.Error) {
	c := (^Core_Audio)(d.data)
	if c.is_open do return {}, .Invalid_State
	if setup.input_device_id != "" && setup.output_device_id != "" && setup.input_device_id != setup.output_device_id {
		return {}, .Unsupported // separate devices need an aggregate device
	}
	id, found := resolve_device(setup)
	if !found do return {}, .Invalid_Argument

	ins, _ := channel_count(id, ca.kAudioObjectPropertyScopeInput)
	outs, _ := channel_count(id, ca.kAudioObjectPropertyScopeOutput)
	if !mask_fits(setup.input_channels, ins) || !mask_fits(setup.output_channels, outs) do return {}, .Invalid_Argument

	if err := set_sample_rate(id, setup.sample_rate); err != .None do return {}, err
	if err := set_buffer_frames(id, setup.buffer_frames); err != .None do return {}, err

	rate, rate_ok := get_value(id, ca.kAudioDevicePropertyNominalSampleRate, f64)
	frames, frames_ok := get_value(id, ca.kAudioDevicePropertyBufferFrameSize, u32)
	if !rate_ok || !frames_ok do return {}, .Device_Error
	max_frames := int(frames)
	if size_range, ok := get_value(id, ca.kAudioDevicePropertyBufferFrameSizeRange, ca.AudioValueRange); ok {
		max_frames = max(max_frames, int(size_range.mMaximum))
	}

	in_streams, _ := stream_count(id, ca.kAudioObjectPropertyScopeInput)
	out_streams, _ := stream_count(id, ca.kAudioObjectPropertyScopeOutput)
	err: mem.Allocator_Error
	c.in_planes, err = make([]backend.Driver_Plane, in_streams, c.allocator)
	if err != nil do return {}, .Out_Of_Memory
	c.out_planes, err = make([]backend.Driver_Plane, out_streams, c.allocator)
	if err != nil {
		delete(c.in_planes, c.allocator)
		return {}, .Out_Of_Memory
	}

	if ca.AudioDeviceCreateIOProcID(id, io_proc, c, &c.proc_id) != ca.NO_ERR {
		free_planes(c)
		return {}, .Device_Error
	}

	c.device = id
	c.format = {
		sample_rate            = rate,
		buffer_frames          = int(frames),
		max_driver_frames      = max_frames,
		input_channels         = setup.input_channels,
		output_channels        = setup.output_channels,
		device_input_channels  = ins,
		device_output_channels = outs,
		input_format           = .F32,
		output_format          = .F32,
		input_latency_frames   = latency_frames(id, ca.kAudioObjectPropertyScopeInput),
		output_latency_frames  = latency_frames(id, ca.kAudioObjectPropertyScopeOutput),
	}
	add_listeners(c)
	c.is_open = true
	return c.format, .None
}

@(private)
ca_close :: proc(d: ^backend.Driver) {
	c := (^Core_Audio)(d.data)
	if !c.is_open do return
	remove_listeners(c)
	ca.AudioDeviceDestroyIOProcID(c.device, c.proc_id)
	free_planes(c)
	c.proc_id = nil
	c.device = ca.kAudioObjectUnknown
	c.is_open = false
}

@(private)
free_planes :: proc(c: ^Core_Audio) {
	delete(c.in_planes, c.allocator)
	delete(c.out_planes, c.allocator)
	c.in_planes, c.out_planes = nil, nil
}

@(private)
resolve_device :: proc(setup: backend.Device_Setup) -> (ca.AudioObjectID, bool) {
	uid := setup.output_device_id if setup.output_device_id != "" else setup.input_device_id
	if uid == "" {
		sel := ca.kAudioHardwarePropertyDefaultOutputDevice
		if setup.output_channels == {} do sel = ca.kAudioHardwarePropertyDefaultInputDevice
		id, ok := get_value(ca.kAudioObjectSystemObject, sel, ca.AudioObjectID)
		return id, ok && id != ca.kAudioObjectUnknown
	}
	ids, ok := get_array(ca.kAudioObjectSystemObject, ca.kAudioHardwarePropertyDevices, ca.AudioObjectID, context.temp_allocator)
	if !ok do return ca.kAudioObjectUnknown, false
	for id in ids {
		s, s_ok := get_string(id, ca.kAudioDevicePropertyDeviceUID, context.temp_allocator)
		if s_ok && s == uid do return id, true
	}
	return ca.kAudioObjectUnknown, false
}

@(private)
mask_fits :: proc(mask: backend.Channel_Mask, channels: int) -> bool {
	for ch in mask do if ch >= channels do return false
	return true
}

// Changes the device's nominal rate (system-wide; left in place on close).
// The HAL applies it asynchronously, so wait until the device reports it.
@(private)
set_sample_rate :: proc(id: ca.AudioObjectID, rate: f64) -> core.Error {
	if rate <= 0 do return .None
	current, ok := get_value(id, ca.kAudioDevicePropertyNominalSampleRate, f64)
	if !ok do return .Device_Error
	if current == rate do return .None

	supported := false
	ranges, _ := get_array(id, ca.kAudioDevicePropertyAvailableNominalSampleRates, ca.AudioValueRange, context.temp_allocator)
	for r in ranges do supported ||= rate >= r.mMinimum && rate <= r.mMaximum
	if !supported do return .Unsupported

	a := addr(ca.kAudioDevicePropertyNominalSampleRate)
	value := rate
	if ca.AudioObjectSetPropertyData(id, &a, 0, nil, size_of(value), &value) != ca.NO_ERR do return .Device_Error
	for _ in 0 ..< 200 {
		if now, now_ok := get_value(id, ca.kAudioDevicePropertyNominalSampleRate, f64); now_ok && now == rate do return .None
		time.sleep(10 * time.Millisecond)
	}
	return .Device_Error
}

@(private)
set_buffer_frames :: proc(id: ca.AudioObjectID, frames: int) -> core.Error {
	if frames <= 0 do return .None
	size_range, ok := get_value(id, ca.kAudioDevicePropertyBufferFrameSizeRange, ca.AudioValueRange)
	if !ok do return .Device_Error
	if f64(frames) < size_range.mMinimum || f64(frames) > size_range.mMaximum do return .Unsupported
	a := addr(ca.kAudioDevicePropertyBufferFrameSize)
	value := u32(frames)
	if ca.AudioObjectSetPropertyData(id, &a, 0, nil, size_of(value), &value) != ca.NO_ERR do return .Device_Error
	if now, now_ok := get_value(id, ca.kAudioDevicePropertyBufferFrameSize, u32); !now_ok || int(now) != frames do return .Device_Error
	return .None
}

// Device latency + safety offset + the first stream's latency, in frames.
// Excludes the buffer itself.
@(private)
latency_frames :: proc(id: ca.AudioObjectID, scope: u32) -> int {
	device, _ := get_value(id, ca.kAudioDevicePropertyLatency, u32, scope)
	safety, _ := get_value(id, ca.kAudioDevicePropertySafetyOffset, u32, scope)
	stream: u32
	if streams, ok := get_array(id, ca.kAudioDevicePropertyStreams, ca.AudioObjectID, context.temp_allocator, scope); ok && len(streams) > 0 {
		stream, _ = get_value(streams[0], ca.kAudioStreamPropertyLatency, u32)
	}
	return int(device + safety + stream)
}

// --- start / stop -------------------------------------------------------------------

@(private)
ca_start :: proc(d: ^backend.Driver) -> core.Error {
	c := (^Core_Audio)(d.data)
	if !c.is_open || c.started do return .Invalid_State
	c.have_expected = false
	intrinsics.atomic_store(&c.overload, false)
	intrinsics.atomic_store(&c.active, true)
	if ca.AudioDeviceStart(c.device, c.proc_id) != ca.NO_ERR {
		intrinsics.atomic_store(&c.active, false)
		return .Device_Error
	}
	c.started = true
	return .None
}

// AudioDeviceStop is synchronous from a non-IO thread, but a callback may already
// be past its entry check; `active` and `in_callback` close that window.
@(private)
ca_stop :: proc(d: ^backend.Driver) {
	c := (^Core_Audio)(d.data)
	if !c.started do return
	ca.AudioDeviceStop(c.device, c.proc_id)
	intrinsics.atomic_store(&c.active, false)
	for intrinsics.atomic_load(&c.in_callback) != 0 do time.sleep(100 * time.Microsecond)
	c.started = false
}

// [rt] HAL IO thread.
@(private)
io_proc :: proc "c" (
	device: ca.AudioObjectID,
	now: ^ca.AudioTimeStamp,
	input: ^ca.AudioBufferList,
	input_time: ^ca.AudioTimeStamp,
	output: ^ca.AudioBufferList,
	output_time: ^ca.AudioTimeStamp,
	client: rawptr,
) -> ca.OSStatus {
	c := (^Core_Audio)(client)
	intrinsics.atomic_add(&c.in_callback, 1)
	defer intrinsics.atomic_sub(&c.in_callback, 1)

	in_bufs := ca.audio_buffer_list_buffers(input) if input != nil else nil
	out_bufs := ca.audio_buffer_list_buffers(output) if output != nil else nil
	if !intrinsics.atomic_load(&c.active) {
		for b in out_bufs do if b.mData != nil do intrinsics.mem_zero(b.mData, int(b.mDataByteSize))
		return ca.NO_ERR
	}

	frames := 0
	for b in out_bufs do if b.mNumberChannels > 0 {
		frames = int(b.mDataByteSize) / (4 * int(b.mNumberChannels))
		break
	}
	if frames == 0 do for b in in_bufs do if b.mNumberChannels > 0 {
		frames = int(b.mDataByteSize) / (4 * int(b.mNumberChannels))
		break
	}

	n_in := min(len(in_bufs), len(c.in_planes))
	n_out := min(len(out_bufs), len(c.out_planes))
	for i in 0 ..< n_in do c.in_planes[i] = {in_bufs[i].mData, int(in_bufs[i].mNumberChannels)}
	for i in 0 ..< n_out do c.out_planes[i] = {out_bufs[i].mData, int(out_bufs[i].mNumberChannels)}

	// A jump in the device's sample clock means the HAL skipped a cycle.
	clock := output_time if n_out > 0 else input_time
	xrun := intrinsics.atomic_exchange(&c.overload, false)
	if clock != nil && .Sample_Time_Valid in clock.mFlags {
		if c.have_expected && clock.mSampleTime != c.expected_sample_time do xrun = true
		c.expected_sample_time = clock.mSampleTime + f64(frames)
		c.have_expected = true
	}

	buf := backend.Driver_Buffers {
		frames      = frames,
		input       = c.in_planes[:n_in],
		output      = c.out_planes[:n_out],
		callback_ns = host_ns(now),
		input_ns    = host_ns(input_time),
		output_ns   = host_ns(output_time),
		xrun        = xrun,
	}
	backend.driver_process(c.driver.host, &buf)
	return ca.NO_ERR
}

// [rt]
@(private)
host_ns :: proc "contextless" (ts: ^ca.AudioTimeStamp) -> u64 {
	if ts == nil || .Host_Time_Valid not_in ts.mFlags do return 0
	return ca.AudioConvertHostTimeToNanos(ts.mHostTime)
}

// --- notifications -------------------------------------------------------------------

@(private)
Watched :: struct {
	object:   enum u8 {System, Device},
	selector: u32,
}

@(private)
WATCHED := [?]Watched {
	{.System, ca.kAudioHardwarePropertyDevices},
	{.System, ca.kAudioHardwarePropertyDefaultInputDevice},
	{.System, ca.kAudioHardwarePropertyDefaultOutputDevice},
	{.Device, ca.kAudioDevicePropertyDeviceIsAlive},
	{.Device, ca.kAudioDevicePropertyNominalSampleRate},
	{.Device, ca.kAudioDeviceProcessorOverload},
}

@(private)
add_listeners :: proc(c: ^Core_Audio) {
	for w in WATCHED {
		a := addr(w.selector)
		ca.AudioObjectAddPropertyListener(watched_object(c, w), &a, on_property, c)
	}
}

@(private)
remove_listeners :: proc(c: ^Core_Audio) {
	for w in WATCHED {
		a := addr(w.selector)
		ca.AudioObjectRemovePropertyListener(watched_object(c, w), &a, on_property, c)
	}
}

@(private)
watched_object :: proc(c: ^Core_Audio, w: Watched) -> ca.AudioObjectID {
	return ca.kAudioObjectSystemObject if w.object == .System else c.device
}

// HAL notification thread (not realtime).
@(private)
on_property :: proc "c" (object: ca.AudioObjectID, count: u32, addrs: [^]ca.AudioObjectPropertyAddress, client: rawptr) -> ca.OSStatus {
	c := (^Core_Audio)(client)
	context = runtime.default_context()
	for a in addrs[:count] {
		switch a.mSelector {
		case ca.kAudioHardwarePropertyDevices:
			backend.driver_notify(c.driver.host, {kind = .Devices_Changed})
		case ca.kAudioHardwarePropertyDefaultInputDevice, ca.kAudioHardwarePropertyDefaultOutputDevice:
			backend.driver_notify(c.driver.host, {kind = .Default_Device_Changed})
		case ca.kAudioDevicePropertyDeviceIsAlive:
			alive, ok := get_value(c.device, ca.kAudioDevicePropertyDeviceIsAlive, u32)
			if !ok || alive == 0 do backend.driver_notify(c.driver.host, {kind = .Device_Lost})
		case ca.kAudioDevicePropertyNominalSampleRate:
			rate, ok := get_value(c.device, ca.kAudioDevicePropertyNominalSampleRate, f64)
			if ok && rate != c.format.sample_rate do backend.driver_notify(c.driver.host, {kind = .Format_Changed})
		case ca.kAudioDeviceProcessorOverload:
			intrinsics.atomic_store(&c.overload, true)
		}
	}
	return ca.NO_ERR
}

// --- property helpers -------------------------------------------------------------------

@(private)
addr :: proc "contextless" (selector: u32, scope := ca.kAudioObjectPropertyScopeGlobal) -> ca.AudioObjectPropertyAddress {
	return {selector, scope, ca.kAudioObjectPropertyElementMain}
}

@(private)
get_value :: proc "contextless" (id: ca.AudioObjectID, selector: u32, $T: typeid, scope := ca.kAudioObjectPropertyScopeGlobal) -> (value: T, ok: bool) {
	a := addr(selector, scope)
	size := u32(size_of(T))
	ok = ca.AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value) == ca.NO_ERR && size == size_of(T)
	return
}

@(private)
get_array :: proc(id: ca.AudioObjectID, selector: u32, $T: typeid, allocator: mem.Allocator, scope := ca.kAudioObjectPropertyScopeGlobal) -> ([]T, bool) {
	a := addr(selector, scope)
	size: u32
	if ca.AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) != ca.NO_ERR do return nil, false
	out, err := make([]T, int(size) / size_of(T), allocator)
	if err != nil do return nil, false
	if len(out) == 0 do return out, true
	if ca.AudioObjectGetPropertyData(id, &a, 0, nil, &size, raw_data(out)) != ca.NO_ERR {
		delete(out, allocator)
		return nil, false
	}
	return out[:int(size) / size_of(T)], true
}

@(private)
get_string :: proc(id: ca.AudioObjectID, selector: u32, allocator: mem.Allocator) -> (string, bool) {
	ref, ok := get_value(id, selector, ca.CFStringRef)
	if !ok || ref == nil do return "", false
	defer CF.CFRelease(CF.TypeRef(ref))
	utf8 := CF.StringEncoding(CF.StringBuiltInEncodings.UTF8)
	cap := int(CF.StringGetMaximumSizeForEncoding(CF.StringGetLength(ref), utf8)) + 1
	buf, err := make([]u8, cap, allocator)
	if err != nil do return "", false
	if !CF.StringGetCString(ref, raw_data(buf), CF.Index(cap), utf8) {
		delete(buf, allocator)
		return "", false
	}
	n := 0
	for n < cap && buf[n] != 0 do n += 1
	return string(buf[:n]), true
}

// Channel and stream counts come from the stream configuration (an AudioBufferList).
@(private)
stream_config :: proc(id: ca.AudioObjectID, scope: u32) -> ([]ca.AudioBuffer, bool) {
	a := addr(ca.kAudioDevicePropertyStreamConfiguration, scope)
	size: u32
	if ca.AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) != ca.NO_ERR || size < size_of(u32) do return nil, false
	raw, err := make([]u8, int(size), context.temp_allocator)
	if err != nil do return nil, false
	if ca.AudioObjectGetPropertyData(id, &a, 0, nil, &size, raw_data(raw)) != ca.NO_ERR do return nil, false
	return ca.audio_buffer_list_buffers((^ca.AudioBufferList)(raw_data(raw))), true
}

@(private)
channel_count :: proc(id: ca.AudioObjectID, scope: u32) -> (int, bool) {
	bufs, ok := stream_config(id, scope)
	n := 0
	for b in bufs do n += int(b.mNumberChannels)
	return n, ok
}

@(private)
stream_count :: proc(id: ca.AudioObjectID, scope: u32) -> (int, bool) {
	bufs, ok := stream_config(id, scope)
	return len(bufs), ok
}

@(private)
append_unique :: proc(xs: ^[dynamic]$T, x: T) {
	for v in xs do if v == x do return
	append(xs, x)
}
