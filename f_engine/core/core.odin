// Shared engine types: the contract between the engine, nodes, and backends.
package core

import "core:mem"

// Maximum number of input or output channels a node may be prepared with.
MAX_CHANNELS :: 64

// Result code for control-thread operations such as `node_prepare`.
// `.None` means success. Audio-thread procs never return errors.
Error :: enum u8 {
	None = 0,         // success
	Out_Of_Memory,    // an allocation failed
	Invalid_Argument, // a parameter was out of range
	Invalid_State,    // the call is not legal in the object's current state
	Unsupported,      // the requested format or feature is not available
	Device_Error,     // the OS or driver reported a failure
	Invalid_Data,     // saved state or a file is malformed, truncated or of an unknown kind
}

// Maps an allocator error to `Error`: `.None` stays `.None`, anything else is
// `.Out_Of_Memory`. Any thread.
from_allocator_error :: proc "contextless" (e: mem.Allocator_Error) -> Error {
	return e == .None ? .None : .Out_Of_Memory
}

// --- events ------------------------------------------------------------------

// Identifies one sounding note so later events (off, expression) can target it.
// `NOTE_ID_ANY` (-1) means unspecified: match by channel and key instead.
Note_Id :: distinct i32 // -1 = unspecified
// Wildcard `Note_Id`: the event is not tied to a specific note instance.
NOTE_ID_ANY :: Note_Id(-1)

// Starts a note.
Note_On :: struct {
	id:       Note_Id, // note instance, or NOTE_ID_ANY
	channel:  u8,      // 0..15
	key:      u8,      // 0..127
	velocity: f32,     // 0..1
}

// Ends a note. Matches by `id`, or by channel and key when `id` is NOTE_ID_ANY.
Note_Off :: struct {
	id:       Note_Id, // note instance, or NOTE_ID_ANY
	channel:  u8,      // 0..15
	key:      u8,      // 0..127
	velocity: f32,     // release velocity, 0..1
}

// Which per-note property a `Note_Expression` changes.
Note_Expression_Kind :: enum u8 {
	Volume,     // linear gain, 0..4
	Pan,        // 0 = left, 0.5 = center, 1 = right
	Tuning,     // semitones, -120..120
	Vibrato,    // 0..1
	Brightness, // 0..1
	Pressure,   // 0..1
}

// Changes one expression value of a sounding note (per-note modulation).
Note_Expression :: struct {
	id:      Note_Id,              // note instance, or NOTE_ID_ANY
	channel: u8,                   // 0..15
	key:     u8,                   // 0..127
	kind:    Note_Expression_Kind, // which property changes
	value:   f64,                  // new value; range depends on `kind`
}

// Identifies a parameter within one node type. Stable once shipped.
Param_Id :: distinct u32

// Sets a parameter at the event's frame offset.
Param_Value :: struct {
	param: Param_Id, // parameter to change
	value: f64,      // plain value in the parameter's own units (not normalized)
}

// Moves a parameter in a straight line from wherever it is at the event's
// frame offset (that frame keeps the current value) to `target`, which it
// has `frames` frames later (possibly in a later block). Automation sends
// these so curves are followed exactly, so a node applies them as they are,
// without its own smoothing. `frames` = 0 sets `target` from the event's
// frame on, unsmoothed. A later `Param_Value` or `Param_Ramp` for the same
// parameter replaces the ramp.
Param_Ramp :: struct {
	param:  Param_Id, // parameter to change
	target: f64,      // plain value to arrive at
	frames: u32,      // ramp length in frames
}

// [rt] Reads `payload` as a change to parameter `param`: a `Param_Value`
// (`ramp_frames` = -1: approach `value` with the parameter's own smoothing)
// or a `Param_Ramp` (`ramp_frames` ≥ 0). `ok` is false for any other event
// or parameter. Pair with `dsp.smoothed_apply`.
param_event :: proc "contextless" (payload: Event_Payload, param: Param_Id) -> (value: f64, ramp_frames: int, ok: bool) {
	#partial switch e in payload {
	case Param_Value:
		if e.param == param do return e.value, -1, true
	case Param_Ramp:
		if e.param == param do return e.target, int(e.frames), true
	}
	return 0, 0, false
}

// Raw MIDI 1.0 passthrough (status + up to 2 data bytes).
Midi_Raw :: struct {
	bytes: [3]u8, // status byte then data bytes; unused bytes are 0
	port:  u8,    // source or destination port index
}

// The kinds of event a node can receive or emit.
Event_Payload :: union {
	Note_On,
	Note_Off,
	Note_Expression,
	Param_Value,
	Param_Ramp,
	Midi_Raw,
}

// A timestamped event within one `process` block.
Event :: struct {
	offset:  u32,           // frame offset into the current block
	payload: Event_Payload, // what happens at `offset`
}

// Fixed-capacity output event sink handed to `process`. Never allocates.
Event_Writer :: struct {
	buffer:  []Event, // storage, owned by whoever set up the writer
	count:   int,     // events written so far
	dropped: int,     // events that did not fit; reported by the control thread
}

// [rt] Appends `e`. Returns false (and counts it in `dropped`) if the buffer is full.
event_writer_push :: proc "contextless" (w: ^Event_Writer, e: Event) -> bool {
	if w.count >= len(w.buffer) {
		w.dropped += 1
		return false
	}
	w.buffer[w.count] = e
	w.count += 1
	return true
}

// [rt] The events written so far, as a view into the writer's buffer (valid
// until the next push or clear).
event_writer_events :: proc "contextless" (w: ^Event_Writer) -> []Event {
	return w.buffer[:w.count]
}

// [rt] Empties the writer and zeroes its dropped counter. Does not free the buffer.
event_writer_clear :: proc "contextless" (w: ^Event_Writer) {
	w.count = 0
	w.dropped = 0
}

// --- parameters ----------------------------------------------------------------

// Display unit of a parameter's plain value.
Param_Unit :: enum u8 {
	None,
	Decibels,
	Hertz,
	Milliseconds,
	Percent,
	Semitones,
	Ratio,
}

// How a node applies changes to a parameter.
Param_Smoothing :: enum u8 {
	None,     // stepped/discrete: apply at event offset exactly
	Linear,   // linear ramp over `smoothing_ms`
	One_Pole, // exponential approach with time constant `smoothing_ms`
}

// Parameter attributes for hosts and UIs.
Param_Flag :: enum u8 {
	Automatable, // the host may automate it
	Stepped,     // only whole values within min..max are meaningful
	Hidden,      // not shown in generic UIs
}
// Set of `Param_Flag`.
Param_Flags :: bit_set[Param_Flag; u8]

// Static description of one node parameter, as returned by `node_params`.
Param_Info :: struct {
	id:           Param_Id,        // stable forever once shipped
	name:         string,          // display name
	unit:         Param_Unit,      // unit of min, max, default and values
	min, max:     f64,             // plain-value range, inclusive
	default:      f64,             // value after prepare
	smoothing:    Param_Smoothing, // how changes are applied
	smoothing_ms: f64,             // ramp length or time constant, ms
	flags:        Param_Flags,
}

// --- process context -----------------------------------------------------------

// Everything a node's `process` receives for one block. Buffers and events are
// owned by the caller and valid only for the duration of the call.
Process_Context :: struct {
	inputs:     [][]f32,       // planar; each len == frames
	outputs:    [][]f32,       // planar; each len == frames
	frames:     int,           // 0 ..= max_block
	events_in:  []Event,       // sorted by offset, all offsets < frames
	events_out: ^Event_Writer, // sink for events the node emits
	transport:  ^Transport,    // transport state at the block start
}

// Stream format passed to `node_prepare`.
Prepare_Config :: struct {
	sample_rate:  f64, // Hz, > 0
	max_block:    int, // largest `frames` any `process` call will pass
	in_channels:  int, // 0 ..= MAX_CHANNELS
	out_channels: int, // 0 ..= MAX_CHANNELS
}
