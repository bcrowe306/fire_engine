package midi

import "core:mem"
import "core:sync"

import "fire:core"

// Whether a port is a source (we receive from it) or a destination (we send
// to it).
Port_Direction :: enum u8 {
	Input,  // a source we can receive from
	Output, // a destination we can send to
}

// One port as listed by `enumerate`. Pass `id` to `open_input` or
// `open_output`. The strings are owned by the slice; free the whole slice
// with `port_infos_destroy`.
Port_Info :: struct {
	id:        string, // stable across runs where the OS allows it
	name:      string, // display name
	direction: Port_Direction, // .Input = source, .Output = destination
}

// Frees a slice returned by `enumerate`, including its strings. Pass the same
// allocator that was given to `enumerate`.
port_infos_destroy :: proc(infos: []Port_Info, allocator := context.allocator) {
	for info in infos {
		delete(info.id, allocator)
		delete(info.name, allocator)
	}
	delete(infos, allocator)
}

// Handle to an open port. 0 is invalid.
Port :: distinct u32

// A MIDI driver wraps one OS API. All procs run on the control thread, except
// `send`, which runs on the Midi_Output sender thread (or the control thread).
// Input from every open input port goes to `Driver.input`, tagged with the
// port index given at open.
Driver_VTable :: struct {
	destroy:               proc(d: ^Driver),
	enumerate:             proc(d: ^Driver, allocator: mem.Allocator) -> ([]Port_Info, core.Error),
	open_input:            proc(d: ^Driver, id: string, port_index: u8) -> (Port, core.Error),
	open_output:           proc(d: ^Driver, id: string) -> (Port, core.Error),
	// A destination other apps can send to; its input arrives on `port_index`.
	create_virtual_input:  proc(d: ^Driver, name: string, port_index: u8) -> (Port, core.Error),
	// A source other apps can receive from; send to it like an output.
	create_virtual_output: proc(d: ^Driver, name: string) -> (Port, core.Error),
	close:                 proc(d: ^Driver, port: Port),
	// One complete message: a short message, or F0 … F7. `time_ns` on the host
	// clock; 0 = now. Drivers that can schedule (CoreMIDI) do.
	send:                  proc(d: ^Driver, port: Port, message: []u8, time_ns: u64) -> core.Error,
}

// One OS MIDI API, created by a driver package (`fire:midi/coremidi`,
// `fire:midi/alsa`, `fire:midi/winmm`) and freed with `driver_destroy`. Set
// `input` before opening input ports. Read hot-plug events with `poll_event`.
// The event fields are internal to `poll_event` and `driver_notify`.
Driver :: struct {
	vtable:       ^Driver_VTable, // the driver's implementation
	name:         string, // API name, e.g. "CoreMIDI"
	data:         rawptr, // the driver's own state
	input:        ^Midi_Input, // set before opening inputs
	// The OS delivers a timestamped send at its time (CoreMIDI, ALSA). If
	// false (WinMM), Midi_Output's sender thread holds messages until then.
	can_schedule: bool,

	// Driver notification threads → control thread (see poll_event).
	event_lock:     sync.Mutex,
	events:         [EVENT_RING]Event,
	event_head:     int,
	event_count:    int,
	events_dropped: int,
}

@(private) EVENT_RING :: 64

// What a driver `Event` reports.
Event_Kind :: enum u8 {
	Ports_Changed, // ports appeared or disappeared: re-enumerate
	Port_Lost,     // an open port's device went away; `port` says which. Close it.
}

// A hot-plug event, read with `poll_event`.
Event :: struct {
	kind: Event_Kind,
	port: Port, // the lost port (Port_Lost only)
}

// Control thread. Hot-plug events in the order the driver saw them.
poll_event :: proc(d: ^Driver) -> (e: Event, ok: bool) {
	sync.mutex_lock(&d.event_lock)
	defer sync.mutex_unlock(&d.event_lock)
	if d.event_count == 0 do return {}, false
	e = d.events[d.event_head]
	d.event_head = (d.event_head + 1) % EVENT_RING
	d.event_count -= 1
	return e, true
}

// Drivers call this from their notification thread (never an audio thread).
// Consecutive Ports_Changed events are merged.
driver_notify :: proc "contextless" (d: ^Driver, e: Event) {
	sync.mutex_lock(&d.event_lock)
	defer sync.mutex_unlock(&d.event_lock)
	if e.kind == .Ports_Changed && d.event_count > 0 {
		last := d.events[(d.event_head + d.event_count - 1) % EVENT_RING]
		if last.kind == .Ports_Changed do return
	}
	if d.event_count == EVENT_RING {
		d.events_dropped += 1
		return
	}
	d.events[(d.event_head + d.event_count) % EVENT_RING] = e
	d.event_count += 1
}

// Control thread. Closes every open port and frees the driver. Nil is allowed.
// Stop any Midi_Output using the driver first.
driver_destroy :: proc(d: ^Driver) {
	if d != nil && d.vtable != nil do d.vtable.destroy(d)
}

// Control thread. Lists the sources and destinations the OS currently has.
// The caller owns the result; free it with `port_infos_destroy`.
enumerate :: proc(d: ^Driver, allocator := context.allocator) -> ([]Port_Info, core.Error) {
	return d.vtable.enumerate(d, allocator)
}

// Control thread. Starts receiving from the source with this `id` (from
// `enumerate`) into `Driver.input`, tagged with `port_index` (0 ..< MAX_PORTS).
// Returns .Invalid_Argument if `input` is unset, the index is out of range or
// the port is not found. Close the port with `close_port`.
open_input :: proc(d: ^Driver, id: string, port_index: u8) -> (Port, core.Error) {
	if d.input == nil || int(port_index) >= MAX_PORTS do return 0, .Invalid_Argument
	return d.vtable.open_input(d, id, port_index)
}

// Control thread. Opens the destination with this `id` (from `enumerate`) for
// `send`. Returns .Invalid_Argument if the port is not found. Close it with
// `close_port`.
open_output :: proc(d: ^Driver, id: string) -> (Port, core.Error) {
	return d.vtable.open_output(d, id)
}

// Control thread. Creates a destination called `name` that other apps can
// send to; what they send arrives on `Driver.input` tagged with `port_index`.
// Returns .Invalid_Argument as for `open_input`, or .Unsupported (WinMM).
create_virtual_input :: proc(d: ^Driver, name: string, port_index: u8) -> (Port, core.Error) {
	if d.input == nil || int(port_index) >= MAX_PORTS do return 0, .Invalid_Argument
	return d.vtable.create_virtual_input(d, name, port_index)
}

// Control thread. Creates a source called `name` that other apps can receive
// from. Send to it like an output. Returns .Unsupported on WinMM.
create_virtual_output :: proc(d: ^Driver, name: string) -> (Port, core.Error) {
	return d.vtable.create_virtual_output(d, name)
}

// Control thread. Closes a port opened or created on this driver. Unknown
// handles are ignored.
close_port :: proc(d: ^Driver, port: Port) {
	d.vtable.close(d, port)
}

// Sends one complete message: a short message or SysEx (F0 … F7). `time_ns` is
// on the host clock (rt.host_time_ns); 0 sends now. Drivers that can schedule
// send it at that time, others send at once. May block (WinMM SysEx); call it
// from the control thread or the Midi_Output sender thread, never the audio
// thread. Returns .Invalid_Argument for an empty or invalid message or a port
// that is not an output.
send :: proc(d: ^Driver, port: Port, message: []u8, time_ns: u64 = 0) -> core.Error {
	if len(message) == 0 do return .Invalid_Argument
	return d.vtable.send(d, port, message, time_ns)
}
