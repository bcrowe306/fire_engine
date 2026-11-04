// CLAP 1.2 (CLever Audio Plug-in, MIT, github.com/free-audio/clap) as Odin
// declarations: the entry point, the plug-in factory, plug-ins, hosts,
// processing, events, and the extensions Fire Engine uses (params,
// audio-ports, note-ports, latency, tail, state, gui, thread-check, log).
// Field for field the structs of the C headers vendored in vendor/clap,
// which tests/clap checks them against. No logic here: see fire:clap.
package clap_sys

import "core:c"

// The CLAP version this binding implements.
VERSION_MAJOR :: 1
VERSION_MINOR :: 2
VERSION_REVISION :: 10

// A CLAP version triple.
Version :: struct {
	major, minor, revision: u32,
}

// This binding's version, for descriptors and hosts.
VERSION :: Version{VERSION_MAJOR, VERSION_MINOR, VERSION_REVISION}

// [rt] Whether a plug-in or host of version `v` can work with this binding
// (CLAP 1.x is backwards compatible).
version_is_compatible :: proc "contextless" (v: Version) -> bool {
	return v.major >= 1
}

// Sizes of the fixed name and path buffers.
NAME_SIZE :: 256
PATH_SIZE :: 1024

// A parameter, port or note id.
Id :: u32
INVALID_ID :: max(u32)

// Fixed-point beats and seconds: 31 fractional bits.
BEATTIME_FACTOR :: i64(1) << 31
SECTIME_FACTOR :: i64(1) << 31

// The symbol every CLAP library exports, a `Plugin_Entry`.
ENTRY_SYMBOL :: "clap_entry"

// What a CLAP library exports as `clap_entry`.
Plugin_Entry :: struct {
	clap_version: Version,
	init:         proc "c" (plugin_path: cstring) -> bool,
	deinit:       proc "c" (),
	get_factory:  proc "c" (factory_id: cstring) -> rawptr,
}

// The id of the plug-in factory, for `get_factory`.
PLUGIN_FACTORY_ID :: "clap.plugin-factory"

// Lists and creates the plug-ins in a library.
Plugin_Factory :: struct {
	get_plugin_count:      proc "c" (factory: ^Plugin_Factory) -> u32,
	get_plugin_descriptor: proc "c" (factory: ^Plugin_Factory, index: u32) -> ^Plugin_Descriptor,
	create_plugin:         proc "c" (factory: ^Plugin_Factory, host: ^Host, plugin_id: cstring) -> ^Plugin,
}

// What a plug-in is.
Plugin_Descriptor :: struct {
	clap_version: Version,
	id:           cstring,
	name:         cstring,
	vendor:       cstring,
	url:          cstring,
	manual_url:   cstring,
	support_url:  cstring,
	version:      cstring,
	description:  cstring,
	features:     [^]cstring, // nil-terminated
}

// The host, as a plug-in sees it.
Host :: struct {
	clap_version:     Version,
	host_data:        rawptr,
	name:             cstring,
	vendor:           cstring,
	url:              cstring,
	version:          cstring,
	get_extension:    proc "c" (host: ^Host, extension_id: cstring) -> rawptr,
	request_restart:  proc "c" (host: ^Host),
	request_process:  proc "c" (host: ^Host),
	request_callback: proc "c" (host: ^Host),
}

// A plug-in instance.
Plugin :: struct {
	desc:             ^Plugin_Descriptor,
	plugin_data:      rawptr,
	init:             proc "c" (plugin: ^Plugin) -> bool,
	destroy:          proc "c" (plugin: ^Plugin),
	activate:         proc "c" (plugin: ^Plugin, sample_rate: f64, min_frames_count, max_frames_count: u32) -> bool,
	deactivate:       proc "c" (plugin: ^Plugin),
	start_processing: proc "c" (plugin: ^Plugin) -> bool,
	stop_processing:  proc "c" (plugin: ^Plugin),
	reset:            proc "c" (plugin: ^Plugin),
	process:          proc "c" (plugin: ^Plugin, process: ^Process) -> Process_Status,
	get_extension:    proc "c" (plugin: ^Plugin, id: cstring) -> rawptr,
	on_main_thread:   proc "c" (plugin: ^Plugin),
}

// What `process` returns.
Process_Status :: i32

// Process results.
PROCESS_ERROR :: Process_Status(0)
PROCESS_CONTINUE :: Process_Status(1)
PROCESS_CONTINUE_IF_NOT_QUIET :: Process_Status(2)
PROCESS_TAIL :: Process_Status(3)
PROCESS_SLEEP :: Process_Status(4)

// One call's worth of audio and events.
Process :: struct {
	steady_time:         i64, // frames since processing started; −1 if unknown
	frames_count:        u32,
	transport:           ^Event_Transport, // nil when free-running
	audio_inputs:        [^]Audio_Buffer,
	audio_outputs:       [^]Audio_Buffer,
	audio_inputs_count:  u32,
	audio_outputs_count: u32,
	in_events:           ^Input_Events,
	out_events:          ^Output_Events,
}

// One port's channels.
Audio_Buffer :: struct {
	data32:        [^][^]f32,
	data64:        [^][^]f64,
	channel_count: u32,
	latency:       u32,
	constant_mask: u64,
}

// What every event starts with.
Event_Header :: struct {
	size:     u32, // of the whole event
	time:     u32, // frame offset into the block
	space_id: u16,
	type:     u16,
	flags:    u32,
}

// The space of the events below.
CORE_EVENT_SPACE_ID :: u16(0)

// Event flags.
EVENT_IS_LIVE :: u32(1)
EVENT_DONT_RECORD :: u32(2)

// Event types in the core space.
EVENT_NOTE_ON :: u16(0)
EVENT_NOTE_OFF :: u16(1)
EVENT_NOTE_CHOKE :: u16(2)
EVENT_NOTE_END :: u16(3)
EVENT_NOTE_EXPRESSION :: u16(4)
EVENT_PARAM_VALUE :: u16(5)
EVENT_PARAM_MOD :: u16(6)
EVENT_PARAM_GESTURE_BEGIN :: u16(7)
EVENT_PARAM_GESTURE_END :: u16(8)
EVENT_TRANSPORT :: u16(9)
EVENT_MIDI :: u16(10)
EVENT_MIDI_SYSEX :: u16(11)
EVENT_MIDI2 :: u16(12)

// Note on, off, choke and end.
Event_Note :: struct {
	header:     Event_Header,
	note_id:    i32, // −1 = unspecified
	port_index: i16,
	channel:    i16, // 0..15, −1 = all
	key:        i16, // 0..127, −1 = all
	velocity:   f64, // 0..1
}

// Note expression ids.
NOTE_EXPRESSION_VOLUME :: i32(0) // linear 0..4
NOTE_EXPRESSION_PAN :: i32(1) // 0..1, 0.5 centre
NOTE_EXPRESSION_TUNING :: i32(2) // semitones, −120..120
NOTE_EXPRESSION_VIBRATO :: i32(3) // 0..1
NOTE_EXPRESSION_EXPRESSION :: i32(4) // 0..1
NOTE_EXPRESSION_BRIGHTNESS :: i32(5) // 0..1
NOTE_EXPRESSION_PRESSURE :: i32(6) // 0..1

// A per-note expression change.
Event_Note_Expression :: struct {
	header:        Event_Header,
	expression_id: i32,
	note_id:       i32,
	port_index:    i16,
	channel:       i16,
	key:           i16,
	value:         f64,
}

// A parameter's new value.
Event_Param_Value :: struct {
	header:     Event_Header,
	param_id:   Id,
	cookie:     rawptr,
	note_id:    i32,
	port_index: i16,
	channel:    i16,
	key:        i16,
	value:      f64,
}

// A parameter's modulation amount.
Event_Param_Mod :: struct {
	header:     Event_Header,
	param_id:   Id,
	cookie:     rawptr,
	note_id:    i32,
	port_index: i16,
	channel:    i16,
	key:        i16,
	amount:     f64,
}

// The user starting or ending a gesture on a parameter.
Event_Param_Gesture :: struct {
	header:   Event_Header,
	param_id: Id,
}

// Transport flags.
TRANSPORT_HAS_TEMPO :: u32(1 << 0)
TRANSPORT_HAS_BEATS_TIMELINE :: u32(1 << 1)
TRANSPORT_HAS_SECONDS_TIMELINE :: u32(1 << 2)
TRANSPORT_HAS_TIME_SIGNATURE :: u32(1 << 3)
TRANSPORT_IS_PLAYING :: u32(1 << 4)
TRANSPORT_IS_RECORDING :: u32(1 << 5)
TRANSPORT_IS_LOOP_ACTIVE :: u32(1 << 6)
TRANSPORT_IS_WITHIN_PRE_ROLL :: u32(1 << 7)

// The transport at a frame.
Event_Transport :: struct {
	header:             Event_Header,
	flags:              u32,
	song_pos_beats:     i64, // BEATTIME_FACTOR fixed point
	song_pos_seconds:   i64, // SECTIME_FACTOR fixed point
	tempo:              f64,
	tempo_inc:          f64, // tempo change per frame
	loop_start_beats:   i64,
	loop_end_beats:     i64,
	loop_start_seconds: i64,
	loop_end_seconds:   i64,
	bar_start:          i64, // beats
	bar_number:         i32,
	tsig_num:           u16,
	tsig_denom:         u16,
}

// A MIDI 1.0 message.
Event_Midi :: struct {
	header:     Event_Header,
	port_index: u16,
	data:       [3]u8,
}

// A SysEx message.
Event_Midi_Sysex :: struct {
	header:     Event_Header,
	port_index: u16,
	buffer:     [^]u8,
	size:       u32,
}

// A MIDI 2.0 (UMP) message.
Event_Midi2 :: struct {
	header:     Event_Header,
	port_index: u16,
	data:       [4]u32,
}

// The events of a call, sorted by time.
Input_Events :: struct {
	ctx:  rawptr,
	size: proc "c" (list: ^Input_Events) -> u32,
	get:  proc "c" (list: ^Input_Events, index: u32) -> ^Event_Header,
}

// Where a plug-in sends events.
Output_Events :: struct {
	ctx:      rawptr,
	try_push: proc "c" (list: ^Output_Events, event: ^Event_Header) -> bool,
}

// A stream a plug-in reads its state from.
Istream :: struct {
	ctx:  rawptr,
	read: proc "c" (stream: ^Istream, buffer: rawptr, size: u64) -> i64,
}

// A stream a plug-in writes its state to.
Ostream :: struct {
	ctx:   rawptr,
	write: proc "c" (stream: ^Ostream, buffer: rawptr, size: u64) -> i64,
}

// --- extensions ---------------------------------------------------------------------------

// Extension ids.
EXT_PARAMS :: "clap.params"
EXT_AUDIO_PORTS :: "clap.audio-ports"
EXT_NOTE_PORTS :: "clap.note-ports"
EXT_LATENCY :: "clap.latency"
EXT_TAIL :: "clap.tail"
EXT_STATE :: "clap.state"
EXT_GUI :: "clap.gui"
EXT_THREAD_CHECK :: "clap.thread-check"
EXT_LOG :: "clap.log"

// Parameter info flags.
PARAM_IS_STEPPED :: u32(1 << 0)
PARAM_IS_PERIODIC :: u32(1 << 1)
PARAM_IS_HIDDEN :: u32(1 << 2)
PARAM_IS_READONLY :: u32(1 << 3)
PARAM_IS_BYPASS :: u32(1 << 4)
PARAM_IS_AUTOMATABLE :: u32(1 << 5)
PARAM_IS_MODULATABLE :: u32(1 << 10)
PARAM_REQUIRES_PROCESS :: u32(1 << 15)
PARAM_IS_ENUM :: u32(1 << 16)

// One parameter.
Param_Info :: struct {
	id:            Id,
	flags:         u32,
	cookie:        rawptr,
	name:          [NAME_SIZE]u8,
	module:        [PATH_SIZE]u8,
	min_value:     f64,
	max_value:     f64,
	default_value: f64,
}

// The plug-in's parameters.
Plugin_Params :: struct {
	count:         proc "c" (plugin: ^Plugin) -> u32,
	get_info:      proc "c" (plugin: ^Plugin, param_index: u32, info: ^Param_Info) -> bool,
	get_value:     proc "c" (plugin: ^Plugin, param_id: Id, out_value: ^f64) -> bool,
	value_to_text: proc "c" (plugin: ^Plugin, param_id: Id, value: f64, out_buffer: [^]u8, capacity: u32) -> bool,
	text_to_value: proc "c" (plugin: ^Plugin, param_id: Id, text: cstring, out_value: ^f64) -> bool,
	flush:         proc "c" (plugin: ^Plugin, in_events: ^Input_Events, out_events: ^Output_Events),
}

// Rescan flags for `Host_Params.rescan`.
PARAM_RESCAN_VALUES :: u32(1 << 0)
PARAM_RESCAN_TEXT :: u32(1 << 1)
PARAM_RESCAN_INFO :: u32(1 << 2)
PARAM_RESCAN_ALL :: u32(1 << 3)

// What the host offers about parameters.
Host_Params :: struct {
	rescan:        proc "c" (host: ^Host, flags: u32),
	clear:         proc "c" (host: ^Host, param_id: Id, flags: u32),
	request_flush: proc "c" (host: ^Host),
}

// Audio port flags.
AUDIO_PORT_IS_MAIN :: u32(1 << 0)
AUDIO_PORT_SUPPORTS_64BITS :: u32(1 << 1)

// One audio port.
Audio_Port_Info :: struct {
	id:            Id,
	name:          [NAME_SIZE]u8,
	flags:         u32,
	channel_count: u32,
	port_type:     cstring,
	in_place_pair: Id,
}

// The plug-in's audio ports.
Plugin_Audio_Ports :: struct {
	count: proc "c" (plugin: ^Plugin, is_input: bool) -> u32,
	get:   proc "c" (plugin: ^Plugin, index: u32, is_input: bool, info: ^Audio_Port_Info) -> bool,
}

// Note dialects.
NOTE_DIALECT_CLAP :: u32(1 << 0)
NOTE_DIALECT_MIDI :: u32(1 << 1)
NOTE_DIALECT_MIDI_MPE :: u32(1 << 2)
NOTE_DIALECT_MIDI2 :: u32(1 << 3)

// One note port.
Note_Port_Info :: struct {
	id:                 Id,
	supported_dialects: u32,
	preferred_dialect:  u32,
	name:               [NAME_SIZE]u8,
}

// The plug-in's note ports.
Plugin_Note_Ports :: struct {
	count: proc "c" (plugin: ^Plugin, is_input: bool) -> u32,
	get:   proc "c" (plugin: ^Plugin, index: u32, is_input: bool, info: ^Note_Port_Info) -> bool,
}

// The plug-in's latency.
Plugin_Latency :: struct {
	get: proc "c" (plugin: ^Plugin) -> u32,
}

// The host side of latency.
Host_Latency :: struct {
	changed: proc "c" (host: ^Host),
}

// The plug-in's tail (frames it keeps sounding after its input stops).
Plugin_Tail :: struct {
	get: proc "c" (plugin: ^Plugin) -> u32,
}

// Saving and loading the plug-in's state.
Plugin_State :: struct {
	save: proc "c" (plugin: ^Plugin, stream: ^Ostream) -> bool,
	load: proc "c" (plugin: ^Plugin, stream: ^Istream) -> bool,
}

// The host side of state.
Host_State :: struct {
	mark_dirty: proc "c" (host: ^Host),
}

// Window APIs for the gui extension.
WINDOW_API_WIN32 :: "win32"
WINDOW_API_COCOA :: "cocoa"
WINDOW_API_X11 :: "x11"
WINDOW_API_WAYLAND :: "wayland"

// A native window to embed an editor in.
Window :: struct {
	api:    cstring,
	using _: struct #raw_union {
		cocoa: rawptr, // NSView
		x11:   c.ulong, // Window
		win32: rawptr, // HWND
		ptr:   rawptr,
	},
}

// How an editor may be resized.
Gui_Resize_Hints :: struct {
	can_resize_horizontally: bool,
	can_resize_vertically:   bool,
	preserve_aspect_ratio:   bool,
	aspect_ratio_width:      u32,
	aspect_ratio_height:     u32,
}

// The plug-in's editor.
Plugin_Gui :: struct {
	is_api_supported:  proc "c" (plugin: ^Plugin, api: cstring, is_floating: bool) -> bool,
	get_preferred_api: proc "c" (plugin: ^Plugin, api: ^cstring, is_floating: ^bool) -> bool,
	create:            proc "c" (plugin: ^Plugin, api: cstring, is_floating: bool) -> bool,
	destroy:           proc "c" (plugin: ^Plugin),
	set_scale:         proc "c" (plugin: ^Plugin, scale: f64) -> bool,
	get_size:          proc "c" (plugin: ^Plugin, width, height: ^u32) -> bool,
	can_resize:        proc "c" (plugin: ^Plugin) -> bool,
	get_resize_hints:  proc "c" (plugin: ^Plugin, hints: ^Gui_Resize_Hints) -> bool,
	adjust_size:       proc "c" (plugin: ^Plugin, width, height: ^u32) -> bool,
	set_size:          proc "c" (plugin: ^Plugin, width, height: u32) -> bool,
	set_parent:        proc "c" (plugin: ^Plugin, window: ^Window) -> bool,
	set_transient:     proc "c" (plugin: ^Plugin, window: ^Window) -> bool,
	suggest_title:     proc "c" (plugin: ^Plugin, title: cstring),
	show:              proc "c" (plugin: ^Plugin) -> bool,
	hide:              proc "c" (plugin: ^Plugin) -> bool,
}

// The host side of the editor.
Host_Gui :: struct {
	resize_hints_changed: proc "c" (host: ^Host),
	request_resize:       proc "c" (host: ^Host, width, height: u32) -> bool,
	request_show:         proc "c" (host: ^Host) -> bool,
	request_hide:         proc "c" (host: ^Host) -> bool,
	closed:               proc "c" (host: ^Host, was_destroyed: bool),
}

// Which thread the plug-in is called from.
Host_Thread_Check :: struct {
	is_main_thread:  proc "c" (host: ^Host) -> bool,
	is_audio_thread: proc "c" (host: ^Host) -> bool,
}

// Log severities.
LOG_DEBUG :: i32(0)
LOG_INFO :: i32(1)
LOG_WARNING :: i32(2)
LOG_ERROR :: i32(3)
LOG_FATAL :: i32(4)
LOG_HOST_MISBEHAVING :: i32(5)
LOG_PLUGIN_MISBEHAVING :: i32(6)

// The plug-in's log.
Host_Log :: struct {
	log: proc "c" (host: ^Host, severity: i32, msg: cstring),
}
