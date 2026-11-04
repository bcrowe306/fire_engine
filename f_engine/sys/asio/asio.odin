#+build windows
// The ASIO driver interface, as Odin declarations: an ASIO driver is a COM
// object (its CLSID is in the registry under HKLM\SOFTWARE\ASIO\<name>)
// whose vtable, after IUnknown's three methods, is the methods below, in
// this order, with the driver as the first argument (thiscall, which is
// the ordinary calling convention on 64-bit Windows). Written for Fire
// Engine from the interface's published behaviour; no SDK files are used.
// 64-bit Windows only. No logic here: see fire:backend/asio.
package asio_sys

// TRUE or FALSE.
Bool :: i32

// An ASIO result: OK, SUCCESS (from `future`), or a negative error.
Error :: i32

// Results.
OK :: Error(0)
SUCCESS :: Error(0x3f4847a0) // `future` handled the selector
NOT_PRESENT :: Error(-1000)
HW_MALFUNCTION :: Error(-999)
INVALID_PARAMETER :: Error(-998)
INVALID_MODE :: Error(-997)
SP_NOT_ADVANCING :: Error(-996)
NO_CLOCK :: Error(-995)
NO_MEMORY :: Error(-994)

// A 64-bit count split in two halves, as the interface passes them.
Samples :: struct {
	hi, lo: u32,
}

// A 64-bit nanosecond time split in two halves.
Time_Stamp :: struct {
	hi, lo: u32,
}

// The sample formats a channel's buffers may use.
Sample_Type :: enum i32 {
	Int16_MSB    = 0,
	Int24_MSB    = 1,
	Int32_MSB    = 2,
	Float32_MSB  = 3,
	Float64_MSB  = 4,
	Int32_MSB16  = 8,
	Int32_MSB18  = 9,
	Int32_MSB20  = 10,
	Int32_MSB24  = 11,
	Int16_LSB    = 16,
	Int24_LSB    = 17,
	Int32_LSB    = 18,
	Float32_LSB  = 19,
	Float64_LSB  = 20,
	Int32_LSB16  = 24,
	Int32_LSB18  = 25,
	Int32_LSB20  = 26,
	Int32_LSB24  = 27,
}

// What `get_channel_info` fills in (set `channel` and `is_input` first).
Channel_Info :: struct {
	channel:       i32,
	is_input:      Bool,
	is_active:     Bool,
	channel_group: i32,
	type:          Sample_Type,
	name:          [32]u8,
}

// One channel's pair of buffers, from `create_buffers` (set `is_input` and
// `channel_num` first).
Buffer_Info :: struct {
	is_input:    Bool,
	channel_num: i32,
	buffers:     [2]rawptr,
}

// `Time_Info.flags`.
SYSTEM_TIME_VALID :: 1
SAMPLE_POSITION_VALID :: 2
SAMPLE_RATE_VALID :: 4
SPEED_VALID :: 8
SAMPLE_RATE_CHANGED :: 16
CLOCK_SOURCE_CHANGED :: 32

// Timing of a buffer switch.
Time_Info :: struct {
	speed:           f64,
	system_time:     Time_Stamp, // ns, on timeGetTime's clock
	sample_position: Samples,
	sample_rate:     f64,
	flags:           u32,
	reserved:        [12]u8,
}

// Timecode of a buffer switch (unused by Fire Engine).
Time_Code :: struct {
	speed:             f64,
	time_code_samples: Samples,
	flags:             u32,
	future:            [64]u8,
}

// What `buffer_switch_time_info` receives.
Time :: struct {
	reserved:  [4]i32,
	time_info: Time_Info,
	time_code: Time_Code,
}

// The host's callbacks, given to `create_buffers`. The driver calls them
// on a thread of its own; there is no user pointer.
Callbacks :: struct {
	buffer_switch:           proc "c" (double_buffer_index: i32, direct_process: Bool),
	sample_rate_did_change:  proc "c" (rate: f64),
	asio_message:            proc "c" (selector: i32, value: i32, message: rawptr, opt: ^f64) -> i32,
	buffer_switch_time_info: proc "c" (params: ^Time, double_buffer_index: i32, direct_process: Bool) -> ^Time,
}

// `asio_message` selectors.
SELECTOR_SUPPORTED :: 1 // `value` is a selector: return 1 if the host supports it
ENGINE_VERSION :: 2 // return 2
RESET_REQUEST :: 3 // the driver needs the host to stop, dispose, and reopen
BUFFER_SIZE_CHANGE :: 4
RESYNC_REQUEST :: 5 // the driver lost or dropped samples
LATENCIES_CHANGED :: 6
SUPPORTS_TIME_INFO :: 7 // return 1 to get `buffer_switch_time_info`
SUPPORTS_TIME_CODE :: 8
OVERLOAD :: 15

// An ASIO driver object: a pointer to its vtable.
IASIO :: struct {
	vtbl: ^IASIO_VTable,
}

// The driver's methods, IUnknown's first.
IASIO_VTable :: struct {
	query_interface:     proc "system" (this: ^IASIO, riid: rawptr, out: ^rawptr) -> i32,
	add_ref:             proc "system" (this: ^IASIO) -> u32,
	release:             proc "system" (this: ^IASIO) -> u32,
	init:                proc "system" (this: ^IASIO, sys_handle: rawptr) -> Bool,
	get_driver_name:     proc "system" (this: ^IASIO, name: [^]u8), // 32 bytes
	get_driver_version:  proc "system" (this: ^IASIO) -> i32,
	get_error_message:   proc "system" (this: ^IASIO, text: [^]u8), // 124 bytes
	start:               proc "system" (this: ^IASIO) -> Error,
	stop:                proc "system" (this: ^IASIO) -> Error,
	get_channels:        proc "system" (this: ^IASIO, inputs, outputs: ^i32) -> Error,
	get_latencies:       proc "system" (this: ^IASIO, input, output: ^i32) -> Error,
	get_buffer_size:     proc "system" (this: ^IASIO, min, max, preferred, granularity: ^i32) -> Error,
	can_sample_rate:     proc "system" (this: ^IASIO, rate: f64) -> Error,
	get_sample_rate:     proc "system" (this: ^IASIO, rate: ^f64) -> Error,
	set_sample_rate:     proc "system" (this: ^IASIO, rate: f64) -> Error,
	get_clock_sources:   proc "system" (this: ^IASIO, clocks: rawptr, count: ^i32) -> Error,
	set_clock_source:    proc "system" (this: ^IASIO, reference: i32) -> Error,
	get_sample_position: proc "system" (this: ^IASIO, position: ^Samples, stamp: ^Time_Stamp) -> Error,
	get_channel_info:    proc "system" (this: ^IASIO, info: ^Channel_Info) -> Error,
	create_buffers:      proc "system" (this: ^IASIO, infos: [^]Buffer_Info, count: i32, buffer_size: i32, callbacks: ^Callbacks) -> Error,
	dispose_buffers:     proc "system" (this: ^IASIO) -> Error,
	control_panel:       proc "system" (this: ^IASIO) -> Error,
	future:              proc "system" (this: ^IASIO, selector: i32, opt: rawptr) -> Error,
	output_ready:        proc "system" (this: ^IASIO) -> Error,
}
