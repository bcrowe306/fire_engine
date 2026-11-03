package midi

import "core:mem"
import "core:sync"

import "fire:core"

Port_Direction :: enum u8 {
	Input,  // a source we can receive from
	Output, // a destination we can send to
}

Port_Info :: struct {
	id:        string, // stable across runs where the OS allows it
	name:      string,
	direction: Port_Direction,
}

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

Driver :: struct {
	vtable:       ^Driver_VTable,
	name:         string,
	data:         rawptr,
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

Event_Kind :: enum u8 {
	Ports_Changed, // ports appeared or disappeared: re-enumerate
	Port_Lost,     // an open port's device went away; `port` says which. Close it.
}

Event :: struct {
	kind: Event_Kind,
	port: Port,
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

driver_destroy :: proc(d: ^Driver) {
	if d != nil && d.vtable != nil do d.vtable.destroy(d)
}

enumerate :: proc(d: ^Driver, allocator := context.allocator) -> ([]Port_Info, core.Error) {
	return d.vtable.enumerate(d, allocator)
}

open_input :: proc(d: ^Driver, id: string, port_index: u8) -> (Port, core.Error) {
	if d.input == nil || int(port_index) >= MAX_PORTS do return 0, .Invalid_Argument
	return d.vtable.open_input(d, id, port_index)
}

open_output :: proc(d: ^Driver, id: string) -> (Port, core.Error) {
	return d.vtable.open_output(d, id)
}

create_virtual_input :: proc(d: ^Driver, name: string, port_index: u8) -> (Port, core.Error) {
	if d.input == nil || int(port_index) >= MAX_PORTS do return 0, .Invalid_Argument
	return d.vtable.create_virtual_input(d, name, port_index)
}

create_virtual_output :: proc(d: ^Driver, name: string) -> (Port, core.Error) {
	return d.vtable.create_virtual_output(d, name)
}

close_port :: proc(d: ^Driver, port: Port) {
	d.vtable.close(d, port)
}

send :: proc(d: ^Driver, port: Port, message: []u8, time_ns: u64 = 0) -> core.Error {
	if len(message) == 0 do return .Invalid_Argument
	return d.vtable.send(d, port, message, time_ns)
}
