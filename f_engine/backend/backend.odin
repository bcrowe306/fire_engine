// Audio device abstraction: the driver contract and the types both sides share.
// See /design/backend/.
package backend

import "core:mem"

import "fire:core"

// A set of device channel indices (0-based, below core.MAX_CHANNELS) to open.
Channel_Mask :: bit_set[0 ..< core.MAX_CHANNELS; u64]

// Native sample formats a driver may hand us. All are little-endian.
Sample_Format :: enum u8 {
	F32,
	F64,
	I16,
	I24,       // packed, 3 bytes
	I32,
	I24_In_32, // 24 significant bits, LSB-aligned in 4 bytes (ASIO Int32LSB24)
}

// [rt] Bytes one sample of format `f` occupies in a driver buffer.
sample_format_bytes :: proc "contextless" (f: Sample_Format) -> int {
	switch f {
	case .F32, .I32, .I24_In_32: return 4
	case .F64:                    return 8
	case .I16:                    return 2
	case .I24:                    return 3
	}
	return 0
}

// One device as listed by driver_enumerate. Strings and slices are owned by the
// enumeration result; free them all with device_infos_destroy.
Device_Info :: struct {
	id:                    string, // stable across runs (CoreAudio UID, WASAPI endpoint ID, ...)
	name:                  string, // human-readable name
	input_channels:        int,    // number of input channels
	output_channels:       int,    // number of output channels
	sample_rates:          []f64,  // supported rates in Hz
	buffer_sizes:          []int,  // supported buffer sizes in frames
	default_sample_rate:   f64,    // Hz
	default_buffer_frames: int,    // frames
	is_default_input:      bool,   // the system default input device
	is_default_output:     bool,   // the system default output device
}

// Frees a slice returned by driver_enumerate and everything in it. Pass the
// same allocator that was given to driver_enumerate.
device_infos_destroy :: proc(infos: []Device_Info, allocator := context.allocator) {
	for info in infos {
		delete(info.id, allocator)
		delete(info.name, allocator)
		delete(info.sample_rates, allocator)
		delete(info.buffer_sizes, allocator)
	}
	delete(infos, allocator)
}

// What the application asks for. Zero values mean "device default".
Device_Setup :: struct {
	input_device_id:  string, // "" = default input; ignored if input_channels == {}
	output_device_id: string, // "" = default output
	sample_rate:      f64,
	buffer_frames:    int,
	input_channels:   Channel_Mask,
	output_channels:  Channel_Mask,
}

// What the driver actually opened.
Device_Format :: struct {
	sample_rate:            f64,
	buffer_frames:          int, // nominal frames per OS callback
	max_driver_frames:      int, // most frames a single OS callback may deliver
	input_channels:         Channel_Mask,
	output_channels:        Channel_Mask,
	device_input_channels:  int, // total channels in the OS input buffers
	device_output_channels: int,
	input_format:           Sample_Format,
	output_format:          Sample_Format,
	input_latency_frames:   int,
	output_latency_frames:  int,
}

// `channels` interleaved channels starting at `data`.
Driver_Plane :: struct {
	data:     rawptr,
	channels: int,
}

// The OS buffers for one driver callback, described without copying.
Driver_Buffers :: struct {
	frames:      int,
	input:       []Driver_Plane,
	output:      []Driver_Plane,
	callback_ns: u64, // host clock; 0 = let the layer read it
	input_ns:    u64, // capture time of input frame 0; 0 = unknown
	output_ns:   u64, // presentation time of output frame 0; 0 = unknown
	xrun:        bool, // discontinuity before this buffer
}

// The procs a driver implements. Application code does not call these directly;
// it goes through driver_* and device_*. All run on the control thread.
Driver_VTable :: struct {
	destroy:   proc(d: ^Driver),
	enumerate: proc(d: ^Driver, allocator: mem.Allocator) -> ([]Device_Info, core.Error),
	// Called with `d.host` already set. Must not start callbacks.
	open:      proc(d: ^Driver, setup: Device_Setup) -> (Device_Format, core.Error),
	start:     proc(d: ^Driver) -> core.Error,
	// Must not return while a driver_process call is in flight.
	stop:      proc(d: ^Driver),
	close:     proc(d: ^Driver),
}

// A driver instance, made by a driver package's `create` (for example
// coreaudio.create) and freed with driver_destroy.
Driver :: struct {
	vtable: ^Driver_VTable, // the driver's implementation
	name:   string,         // driver name, e.g. "coreaudio"
	data:   rawptr,         // driver-private state
	host:   ^Device,        // set by device_open, cleared by device_close
}

// Frees a driver made by a driver package's `create`. Close any Device using it
// first. Nil-safe. Control thread.
driver_destroy :: proc(d: ^Driver) {
	if d != nil && d.vtable != nil do d.vtable.destroy(d)
}

// Lists the devices the driver can open. The caller owns the result and frees it
// with device_infos_destroy using the same allocator. Control thread.
driver_enumerate :: proc(d: ^Driver, allocator := context.allocator) -> ([]Device_Info, core.Error) {
	return d.vtable.enumerate(d, allocator)
}

// What a Device_Event reports.
Device_Event_Kind :: enum u8 {
	Devices_Changed, // devices added or removed; re-enumerate
	Default_Device_Changed, // the system default input or output changed
	Device_Lost,     // the open device went away; stop and close it
	Format_Changed,  // the device changed rate or layout under us; reopen
	Xrun,            // `count` discontinuities since the last poll
	Error,           // driver failure; `error` says what
}

// A notification returned by device_poll_event.
Device_Event :: struct {
	kind:  Device_Event_Kind, // what happened
	count: int,               // number of xruns, for .Xrun
	error: core.Error,        // the failure, for .Error
}

// One block of audio handed to Device_Callback.process. Buffers are planar f32
// and only valid during the call.
Io_Block :: struct {
	inputs:      [][]f32, // selected input channels, ascending device order
	outputs:     [][]f32, // selected output channels; the callback must write all frames
	frames:      int,     // 1 ..= max_block
	sample_time: i64,     // frames since device_start
	sample_rate: f64,     // Hz
	callback_ns: u64,     // host clock (rt.host_time_ns) when the OS callback began
	input_ns:    u64,     // capture time of input frame 0; 0 = unknown
	output_ns:   u64,     // presentation time of output frame 0; 0 = unknown
	xrun:        bool,    // a discontinuity happened before this block
}

// The application's audio callback, passed to device_start. `user` is handed
// back to every proc.
Device_Callback :: struct {
	prepare: proc(user: rawptr, cfg: core.Prepare_Config) -> core.Error, // control thread; may be nil
	process: proc(user: rawptr, block: ^Io_Block),                       // [rt]
	release: proc(user: rawptr),                                         // control thread; may be nil
	user:    rawptr,
}
