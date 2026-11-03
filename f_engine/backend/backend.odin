// Audio device abstraction: the driver contract and the types both sides share.
// See docs/BACKEND.md.
package backend

import "core:mem"

import "fire:core"

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

sample_format_bytes :: proc "contextless" (f: Sample_Format) -> int {
	switch f {
	case .F32, .I32, .I24_In_32: return 4
	case .F64:                    return 8
	case .I16:                    return 2
	case .I24:                    return 3
	}
	return 0
}

Device_Info :: struct {
	id:                    string, // stable across runs (CoreAudio UID, WASAPI endpoint ID, ...)
	name:                  string,
	input_channels:        int,
	output_channels:       int,
	sample_rates:          []f64,
	buffer_sizes:          []int, // frames
	default_sample_rate:   f64,
	default_buffer_frames: int,
	is_default_input:      bool,
	is_default_output:     bool,
}

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

Driver :: struct {
	vtable: ^Driver_VTable,
	name:   string,
	data:   rawptr,
	host:   ^Device, // set by device_open, cleared by device_close
}

driver_destroy :: proc(d: ^Driver) {
	if d != nil && d.vtable != nil do d.vtable.destroy(d)
}

driver_enumerate :: proc(d: ^Driver, allocator := context.allocator) -> ([]Device_Info, core.Error) {
	return d.vtable.enumerate(d, allocator)
}

Device_Event_Kind :: enum u8 {
	Devices_Changed, // devices added or removed; re-enumerate
	Default_Device_Changed, // the system default input or output changed
	Device_Lost,     // the open device went away; stop and close it
	Format_Changed,  // the device changed rate or layout under us; reopen
	Xrun,            // `count` discontinuities since the last poll
	Error,           // driver failure; `error` says what
}

Device_Event :: struct {
	kind:  Device_Event_Kind,
	count: int,
	error: core.Error,
}

Io_Block :: struct {
	inputs:      [][]f32, // selected input channels, ascending device order
	outputs:     [][]f32, // selected output channels; the callback must write all frames
	frames:      int,     // 1 ..= max_block
	sample_time: i64,     // frames since device_start
	sample_rate: f64,
	callback_ns: u64,
	input_ns:    u64,
	output_ns:   u64,
	xrun:        bool,
}

Device_Callback :: struct {
	prepare: proc(user: rawptr, cfg: core.Prepare_Config) -> core.Error, // control thread; may be nil
	process: proc(user: rawptr, block: ^Io_Block),                       // [rt]
	release: proc(user: rawptr),                                         // control thread; may be nil
	user:    rawptr,
}
