// Shared engine types: the contract between the engine, nodes, and backends.
package core

import "core:mem"
import tb "fire:timebase"

MAX_CHANNELS :: 64

Error :: enum u8 {
	None = 0,
	Out_Of_Memory,
	Invalid_Argument,
	Invalid_State,
	Unsupported,
	Device_Error,
}

from_allocator_error :: proc "contextless" (e: mem.Allocator_Error) -> Error {
	return e == .None ? .None : .Out_Of_Memory
}

// --- events ------------------------------------------------------------------

Note_Id :: distinct i32 // -1 = unspecified
NOTE_ID_ANY :: Note_Id(-1)

Note_On :: struct {
	id:       Note_Id,
	channel:  u8,  // 0..15
	key:      u8,  // 0..127
	velocity: f32, // 0..1
}

Note_Off :: struct {
	id:       Note_Id,
	channel:  u8,
	key:      u8,
	velocity: f32,
}

Note_Expression_Kind :: enum u8 {
	Volume,   // linear gain, 0..4
	Pan,      // 0 = left, 0.5 = center, 1 = right
	Tuning,   // semitones, -120..120
	Vibrato,  // 0..1
	Brightness,
	Pressure,
}

Note_Expression :: struct {
	id:      Note_Id,
	channel: u8,
	key:     u8,
	kind:    Note_Expression_Kind,
	value:   f64,
}

Param_Id :: distinct u32

Param_Value :: struct {
	param: Param_Id,
	value: f64, // plain value in the parameter's own units (not normalized)
}

// Raw MIDI 1.0 passthrough (status + up to 2 data bytes).
Midi_Raw :: struct {
	bytes: [3]u8,
	port:  u8,
}

Event_Payload :: union {
	Note_On,
	Note_Off,
	Note_Expression,
	Param_Value,
	Midi_Raw,
}

Event :: struct {
	offset:  u32, // frame offset into the current block
	payload: Event_Payload,
}

// Fixed-capacity output event sink handed to `process`. Never allocates.
Event_Writer :: struct {
	buffer:  []Event,
	count:   int,
	dropped: int, // events that did not fit; reported by the control thread
}

// [rt]
event_writer_push :: proc "contextless" (w: ^Event_Writer, e: Event) -> bool {
	if w.count >= len(w.buffer) {
		w.dropped += 1
		return false
	}
	w.buffer[w.count] = e
	w.count += 1
	return true
}

event_writer_events :: proc "contextless" (w: ^Event_Writer) -> []Event {
	return w.buffer[:w.count]
}

event_writer_clear :: proc "contextless" (w: ^Event_Writer) {
	w.count = 0
	w.dropped = 0
}

// --- transport -----------------------------------------------------------------

// Snapshot of the transport at the first frame of the current block.
Transport :: struct {
	playing:     bool,
	recording:   bool,
	looping:     bool,
	sample_pos:  tb.Sample_Time,
	beat_pos:    tb.Beats,
	tempo_bpm:   f64,
	meter:       tb.Meter,
	bar_start:   tb.Beats, // beat position of the current bar's downbeat
	loop_start:  tb.Beats,
	loop_end:    tb.Beats,
	sample_rate: f64,
	tempo_map:   ^tb.Tempo_Map, // read-only on the audio thread; may be nil
}

// --- parameters ----------------------------------------------------------------

Param_Unit :: enum u8 {
	None,
	Decibels,
	Hertz,
	Milliseconds,
	Percent,
	Semitones,
	Ratio,
}

Param_Smoothing :: enum u8 {
	None,     // stepped/discrete: apply at event offset exactly
	Linear,   // linear ramp over `smoothing_ms`
	One_Pole, // exponential approach with time constant `smoothing_ms`
}

Param_Flag :: enum u8 {
	Automatable,
	Stepped,
	Hidden,
}
Param_Flags :: bit_set[Param_Flag; u8]

Param_Info :: struct {
	id:           Param_Id, // stable forever once shipped
	name:         string,
	unit:         Param_Unit,
	min, max:     f64,
	default:      f64,
	smoothing:    Param_Smoothing,
	smoothing_ms: f64,
	flags:        Param_Flags,
}

// --- process context -----------------------------------------------------------

Process_Context :: struct {
	inputs:     [][]f32, // planar; each len == frames
	outputs:    [][]f32, // planar; each len == frames
	frames:     int,     // 0 ..= max_block
	events_in:  []Event, // sorted by offset, all offsets < frames
	events_out: ^Event_Writer,
	transport:  ^Transport,
}

Prepare_Config :: struct {
	sample_rate:  f64,
	max_block:    int,
	in_channels:  int,
	out_channels: int,
}
