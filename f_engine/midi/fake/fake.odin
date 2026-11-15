/*
A MIDI driver with pretend ports, for tests and headless runs: what is
sent to its outputs is kept (`sent`), its inputs receive what a test plays
into them (`receive`), and ports come and go (`plug`, `unplug`), with the
hot-plug events a real driver gives.

	import mfake "fire:midi/fake"

	d := mfake.create({{id = "grid", name = "Grid MIDI", input = true, output = true}})
	d.input = &my_input
	port, _ := midi.open_input(d, "grid", 0)
	mfake.receive(d, "grid", {0x90, 36, 100})
	mfake.plug(d, {id = "keys", name = "Keys 25", input = true})
*/
package midi_fake

import "core:mem"
import "core:strings"
import "core:sync"

import "fire:core"
import "fire:midi"
import "fire:rt"

// A pretend device's ports: an input and/or an output of the same id.
Port_Spec :: struct {
	id, name:      string,
	input, output: bool,
}

// A message sent to an output.
Sent :: struct {
	port:  string, // its id
	bytes: []u8,
}

// The fake's state (the driver's `data`). Lock `lock` to read `sent` from
// another thread than the one sending.
Fake :: struct {
	lock:   sync.Mutex,
	specs:  [dynamic]Port_Spec, // owned strings
	open:   [dynamic]Open, // open ports
	next:   midi.Port,
	sent:   [dynamic]Sent,
}

@(private)
Open :: struct {
	handle: midi.Port,
	id:     string, // owned
	output: bool,
	index:  u8, // an input's port index
}

@(private)
vtable := midi.Driver_VTable{
	destroy = fake_destroy,
	enumerate = fake_enumerate,
	open_input = fake_open_input,
	open_output = fake_open_output,
	create_virtual_input = proc(d: ^midi.Driver, name: string, port_index: u8) -> (midi.Port, core.Error) { return 0, .Unsupported },
	create_virtual_output = proc(d: ^midi.Driver, name: string) -> (midi.Port, core.Error) { return 0, .Unsupported },
	close = fake_close,
	send = fake_send,
}

// A fake driver with these ports. Free it with `midi.driver_destroy`.
create :: proc(ports: []Port_Spec = nil) -> ^midi.Driver {
	f := new(Fake)
	f.specs = make([dynamic]Port_Spec)
	f.open = make([dynamic]Open)
	f.sent = make([dynamic]Sent)
	f.next = 1
	for p in ports do append(&f.specs, clone_spec(p))
	d := new(midi.Driver)
	d.vtable = &vtable
	d.name = "Fake"
	d.data = f
	d.can_schedule = true
	return d
}

// The fake behind a driver made by `create`.
state :: proc(d: ^midi.Driver) -> ^Fake { return (^Fake)(d.data) }

@(private)
clone_spec :: proc(p: Port_Spec) -> Port_Spec {
	return {id = strings.clone(p.id), name = strings.clone(p.name), input = p.input, output = p.output}
}

// A device plugged in: its ports appear (Ports_Changed).
plug :: proc(d: ^midi.Driver, p: Port_Spec) {
	f := state(d)
	append(&f.specs, clone_spec(p))
	midi.driver_notify(d, {kind = .Ports_Changed})
}

// A device unplugged: its ports go, an open one reports Port_Lost.
unplug :: proc(d: ^midi.Driver, id: string) {
	f := state(d)
	for p, i in f.specs do if p.id == id {
		delete(p.id)
		delete(p.name)
		ordered_remove(&f.specs, i)
		break
	}
	for o in f.open do if o.id == id do midi.driver_notify(d, {kind = .Port_Lost, port = o.handle})
	midi.driver_notify(d, {kind = .Ports_Changed})
}

// MIDI from a device into its open input (a short message, or a whole
// SysEx), as a driver's thread delivers it. False when the input isn't open.
receive :: proc(d: ^midi.Driver, id: string, bytes: []u8) -> bool {
	f := state(d)
	for o in f.open do if !o.output && o.id == id {
		if d.input == nil do return false
		midi.input_push_bytes(d.input, rt.host_time_ns(), o.index, bytes)
		return true
	}
	return false
}

// What was sent to an output (since `clear_sent`), its bytes in the temp
// allocator, oldest first.
sent_to :: proc(d: ^midi.Driver, id: string) -> [][]u8 {
	f := state(d)
	sync.mutex_lock(&f.lock)
	defer sync.mutex_unlock(&f.lock)
	out := make([dynamic][]u8, context.temp_allocator)
	for s in f.sent do if s.port == id {
		b := make([]u8, len(s.bytes), context.temp_allocator)
		copy(b, s.bytes)
		append(&out, b)
	}
	return out[:]
}

// Forgets what was sent.
clear_sent :: proc(d: ^midi.Driver) {
	f := state(d)
	sync.mutex_lock(&f.lock)
	defer sync.mutex_unlock(&f.lock)
	for s in f.sent {
		delete(s.bytes)
		delete(s.port)
	}
	clear(&f.sent)
}

@(private)
fake_destroy :: proc(d: ^midi.Driver) {
	f := state(d)
	clear_sent(d)
	delete(f.sent)
	for p in f.specs {
		delete(p.id)
		delete(p.name)
	}
	delete(f.specs)
	for o in f.open do delete(o.id)
	delete(f.open)
	free(f)
	free(d)
}

@(private)
fake_enumerate :: proc(d: ^midi.Driver, allocator: mem.Allocator) -> ([]midi.Port_Info, core.Error) {
	f := state(d)
	out := make([dynamic]midi.Port_Info, allocator)
	for p in f.specs {
		if p.input do append(&out, midi.Port_Info{id = strings.clone(p.id, allocator), name = strings.clone(p.name, allocator), direction = .Input})
		if p.output do append(&out, midi.Port_Info{id = strings.clone(p.id, allocator), name = strings.clone(p.name, allocator), direction = .Output})
	}
	return out[:], .None
}

@(private)
find :: proc(f: ^Fake, id: string) -> (Port_Spec, bool) {
	for p in f.specs do if p.id == id do return p, true
	return {}, false
}

@(private)
fake_open_input :: proc(d: ^midi.Driver, id: string, index: u8) -> (midi.Port, core.Error) {
	f := state(d)
	p, ok := find(f, id)
	if !ok || !p.input do return 0, .Invalid_Argument
	h := f.next
	f.next += 1
	append(&f.open, Open{handle = h, id = strings.clone(id), index = index})
	return h, .None
}

@(private)
fake_open_output :: proc(d: ^midi.Driver, id: string) -> (midi.Port, core.Error) {
	f := state(d)
	p, ok := find(f, id)
	if !ok || !p.output do return 0, .Invalid_Argument
	h := f.next
	f.next += 1
	append(&f.open, Open{handle = h, id = strings.clone(id), output = true})
	return h, .None
}

@(private)
fake_close :: proc(d: ^midi.Driver, port: midi.Port) {
	f := state(d)
	for o, i in f.open do if o.handle == port {
		delete(o.id)
		ordered_remove(&f.open, i)
		return
	}
}

@(private)
fake_send :: proc(d: ^midi.Driver, port: midi.Port, message: []u8, time_ns: u64) -> core.Error {
	f := state(d)
	for o in f.open do if o.handle == port && o.output {
		sync.mutex_lock(&f.lock)
		defer sync.mutex_unlock(&f.lock)
		b := make([]u8, len(message))
		copy(b, message)
		append(&f.sent, Sent{port = strings.clone(o.id), bytes = b})
		return .None
	}
	return .Invalid_Argument
}
