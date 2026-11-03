#+build linux
// ALSA sequencer MIDI driver: virtual ports, routing to any sequencer port,
// kernel-timestamped input and queue-scheduled output. See /design/backend/.
package alsa_midi

import "base:intrinsics"
import "core:c"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sync"
import "core:thread"

import "fire:core"
import "fire:midi"
import "fire:rt"
import snd "fire:sys/alsa"

@(private)
Port_Kind :: enum u8 {
	Input,          // a source we subscribed our receive port to
	Output,         // a destination we send to
	Virtual_Input,  // our port others send to
	Virtual_Output, // our port others subscribe to
}

@(private)
Seq_Port :: struct {
	handle:     midi.Port,
	kind:       Port_Kind,
	client:     c.int, // remote address (Input/Output) or our client
	port:       c.int, // remote port, or our port for virtual ports
	port_index: u8,
}

@(private)
Alsa_Midi :: struct {
	driver:     midi.Driver,
	allocator:  mem.Allocator,
	seq:        snd.snd_seq_t,
	client:     c.int,
	in_port:    c.int, // receives from every connected source
	out_port:   c.int, // source of sends to ordinary outputs
	queue:      c.int,
	origin_ns:  u64,   // host time of queue time 0
	decoder:    snd.snd_midi_event_t, // input thread only
	encoder:    snd.snd_midi_event_t, // under send_lock
	send_lock:  sync.Mutex,
	ports_lock: sync.Mutex, // ports is read by the input thread
	ports:      [dynamic]Seq_Port,
	next:       u32,
	thread:     ^thread.Thread,
	stop_flag:  bool, // atomic
}

// Control thread. Creates the ALSA sequencer driver. The caller owns the result; free
// it with `midi.driver_destroy`. Starts its input thread.
// Returns .Device_Error if the sequencer cannot be opened (no `snd-seq`
// module) or set up.
create :: proc(allocator := context.allocator) -> (^midi.Driver, core.Error) {
	a := new(Alsa_Midi, allocator)
	a.allocator = allocator
	a.driver = {vtable = &alsa_vtable, name = "ALSA", can_schedule = true, data = a}
	a.ports = make([dynamic]Seq_Port, allocator)
	a.in_port, a.out_port, a.queue = -1, -1, -1
	if snd.snd_seq_open(&a.seq, "default", snd.SND_SEQ_OPEN_DUPLEX, snd.SND_SEQ_NONBLOCK) < 0 {
		free_driver(a)
		return nil, .Device_Error // no sequencer: `modprobe snd-seq`
	}
	snd.snd_seq_set_client_name(a.seq, "Fire Engine")
	a.client = snd.snd_seq_client_id(a.seq)

	// A queue gives input kernel timestamps and lets us schedule output.
	a.queue = snd.snd_seq_alloc_queue(a.seq)
	snd.snd_seq_control_queue(a.seq, a.queue, snd.SND_SEQ_EVENT_START, 0, nil)
	snd.snd_seq_drain_output(a.seq)
	a.origin_ns = rt.host_time_ns()

	hidden := snd.SND_SEQ_PORT_CAP_NO_EXPORT
	a.in_port = make_port(a, "Fire Engine In", snd.SND_SEQ_PORT_CAP_WRITE | hidden, true)
	a.out_port = make_port(a, "Fire Engine Out", snd.SND_SEQ_PORT_CAP_READ | hidden, false)
	if a.in_port < 0 || a.out_port < 0 || a.queue < 0 ||
	   snd.snd_midi_event_new(16, &a.decoder) < 0 || snd.snd_midi_event_new(16, &a.encoder) < 0 {
		free_driver(a)
		return nil, .Device_Error
	}
	snd.snd_midi_event_no_status(a.decoder, 1) // every decoded message carries its status byte
	// Hot-plug: the System Announce port (0:1) reports clients and ports
	// coming and going.
	snd.snd_seq_connect_from(a.seq, a.in_port, snd.SND_SEQ_CLIENT_SYSTEM, snd.SND_SEQ_PORT_SYSTEM_ANNOUNCE)
	a.thread = thread.create_and_start_with_data(a, input_thread)
	return &a.driver, .None
}

@(private)
alsa_vtable := midi.Driver_VTable {
	destroy               = alsa_destroy,
	enumerate             = alsa_enumerate,
	open_input            = alsa_open_input,
	open_output           = alsa_open_output,
	create_virtual_input  = alsa_create_virtual_input,
	create_virtual_output = alsa_create_virtual_output,
	close                 = alsa_close,
	send                  = alsa_send,
}

@(private)
alsa_destroy :: proc(d: ^midi.Driver) {
	free_driver((^Alsa_Midi)(d.data))
}

@(private)
free_driver :: proc(a: ^Alsa_Midi) {
	if a.thread != nil {
		intrinsics.atomic_store(&a.stop_flag, true)
		thread.join(a.thread)
		thread.destroy(a.thread)
	}
	if a.seq != nil {
		for len(a.ports) > 0 do alsa_close(&a.driver, a.ports[len(a.ports) - 1].handle)
		if a.queue >= 0 do snd.snd_seq_free_queue(a.seq, a.queue)
		snd.snd_seq_close(a.seq)
	}
	if a.decoder != nil do snd.snd_midi_event_free(a.decoder)
	if a.encoder != nil do snd.snd_midi_event_free(a.encoder)
	delete(a.ports)
	free(a, a.allocator)
}

// Creates one of our ports. Receiving ports get kernel timestamps from our
// queue, in real time.
@(private)
make_port :: proc(a: ^Alsa_Midi, name: string, caps: c.uint, receiving: bool) -> c.int {
	cname := strings.clone_to_cstring(name, context.temp_allocator)
	port := snd.snd_seq_create_simple_port(a.seq, cname, caps, snd.SND_SEQ_PORT_TYPE_MIDI_GENERIC | snd.SND_SEQ_PORT_TYPE_APPLICATION)
	if port < 0 || !receiving do return port
	info: snd.snd_seq_port_info_t
	snd.snd_seq_port_info_malloc(&info)
	defer snd.snd_seq_port_info_free(info)
	if snd.snd_seq_get_port_info(a.seq, port, info) >= 0 {
		snd.snd_seq_port_info_set_timestamping(info, 1)
		snd.snd_seq_port_info_set_timestamp_real(info, 1)
		snd.snd_seq_port_info_set_timestamp_queue(info, a.queue)
		snd.snd_seq_set_port_info(a.seq, port, info)
	}
	return port
}

// --- enumeration -----------------------------------------------------------------------

// IDs are "client name:port name" (as aconnect -l shows them), which survive
// restarts, unlike client numbers.
@(private)
alsa_enumerate :: proc(d: ^midi.Driver, allocator: mem.Allocator) -> ([]midi.Port_Info, core.Error) {
	a := (^Alsa_Midi)(d.data)
	infos := make([dynamic]midi.Port_Info, allocator)
	for p in all_ports(a) {
		read  := p.caps & (snd.SND_SEQ_PORT_CAP_READ | snd.SND_SEQ_PORT_CAP_SUBS_READ) == (snd.SND_SEQ_PORT_CAP_READ | snd.SND_SEQ_PORT_CAP_SUBS_READ)
		write := p.caps & (snd.SND_SEQ_PORT_CAP_WRITE | snd.SND_SEQ_PORT_CAP_SUBS_WRITE) == (snd.SND_SEQ_PORT_CAP_WRITE | snd.SND_SEQ_PORT_CAP_SUBS_WRITE)
		if read do append(&infos, midi.Port_Info{strings.clone(p.id, allocator), strings.clone(p.id, allocator), .Input})
		if write do append(&infos, midi.Port_Info{strings.clone(p.id, allocator), strings.clone(p.id, allocator), .Output})
	}
	return infos[:], .None
}

@(private)
Remote :: struct {
	id:     string, // temp-allocated
	client: c.int,
	port:   c.int,
	caps:   c.uint,
}

@(private)
all_ports :: proc(a: ^Alsa_Midi) -> []Remote {
	out := make([dynamic]Remote, context.temp_allocator)
	cinfo: snd.snd_seq_client_info_t
	pinfo: snd.snd_seq_port_info_t
	snd.snd_seq_client_info_malloc(&cinfo)
	snd.snd_seq_port_info_malloc(&pinfo)
	defer snd.snd_seq_client_info_free(cinfo)
	defer snd.snd_seq_port_info_free(pinfo)
	snd.snd_seq_client_info_set_client(cinfo, -1)
	for snd.snd_seq_query_next_client(a.seq, cinfo) >= 0 {
		client := snd.snd_seq_client_info_get_client(cinfo)
		if client == snd.SND_SEQ_CLIENT_SYSTEM do continue
		cname := string(snd.snd_seq_client_info_get_name(cinfo))
		snd.snd_seq_port_info_set_client(pinfo, client)
		snd.snd_seq_port_info_set_port(pinfo, -1)
		for snd.snd_seq_query_next_port(a.seq, pinfo) >= 0 {
			caps := snd.snd_seq_port_info_get_capability(pinfo)
			if caps & snd.SND_SEQ_PORT_CAP_NO_EXPORT != 0 do continue
			id := fmt.tprintf("%s:%s", cname, string(snd.snd_seq_port_info_get_name(pinfo)))
			append(&out, Remote{id, client, snd.snd_seq_port_info_get_port(pinfo), caps})
		}
	}
	return out[:]
}

@(private)
find :: proc(a: ^Alsa_Midi, id: string, caps: c.uint) -> (Remote, bool) {
	for p in all_ports(a) do if p.id == id && p.caps & caps == caps do return p, true
	return {}, false
}

// --- ports ---------------------------------------------------------------------------------

@(private)
alsa_open_input :: proc(d: ^midi.Driver, id: string, port_index: u8) -> (midi.Port, core.Error) {
	a := (^Alsa_Midi)(d.data)
	r, ok := find(a, id, snd.SND_SEQ_PORT_CAP_READ | snd.SND_SEQ_PORT_CAP_SUBS_READ)
	if !ok do return 0, .Invalid_Argument
	if snd.snd_seq_connect_from(a.seq, a.in_port, r.client, r.port) < 0 do return 0, .Device_Error
	return add(a, {kind = .Input, client = r.client, port = r.port, port_index = port_index}), .None
}

@(private)
alsa_open_output :: proc(d: ^midi.Driver, id: string) -> (midi.Port, core.Error) {
	a := (^Alsa_Midi)(d.data)
	r, ok := find(a, id, snd.SND_SEQ_PORT_CAP_WRITE | snd.SND_SEQ_PORT_CAP_SUBS_WRITE)
	if !ok do return 0, .Invalid_Argument
	return add(a, {kind = .Output, client = r.client, port = r.port}), .None
}

@(private)
alsa_create_virtual_input :: proc(d: ^midi.Driver, name: string, port_index: u8) -> (midi.Port, core.Error) {
	a := (^Alsa_Midi)(d.data)
	port := make_port(a, name, snd.SND_SEQ_PORT_CAP_WRITE | snd.SND_SEQ_PORT_CAP_SUBS_WRITE, true)
	if port < 0 do return 0, .Device_Error
	return add(a, {kind = .Virtual_Input, client = a.client, port = port, port_index = port_index}), .None
}

@(private)
alsa_create_virtual_output :: proc(d: ^midi.Driver, name: string) -> (midi.Port, core.Error) {
	a := (^Alsa_Midi)(d.data)
	port := make_port(a, name, snd.SND_SEQ_PORT_CAP_READ | snd.SND_SEQ_PORT_CAP_SUBS_READ, false)
	if port < 0 do return 0, .Device_Error
	return add(a, {kind = .Virtual_Output, client = a.client, port = port}), .None
}

@(private)
alsa_close :: proc(d: ^midi.Driver, handle: midi.Port) {
	a := (^Alsa_Midi)(d.data)
	sync.mutex_lock(&a.ports_lock)
	defer sync.mutex_unlock(&a.ports_lock)
	for p, i in a.ports {
		if p.handle != handle do continue
		switch p.kind {
		case .Input:                          snd.snd_seq_disconnect_from(a.seq, a.in_port, p.client, p.port)
		case .Output:
		case .Virtual_Input, .Virtual_Output: snd.snd_seq_delete_simple_port(a.seq, p.port)
		}
		ordered_remove(&a.ports, i)
		return
	}
}

@(private)
add :: proc(a: ^Alsa_Midi, p: Seq_Port) -> midi.Port {
	sync.mutex_lock(&a.ports_lock)
	defer sync.mutex_unlock(&a.ports_lock)
	a.next += 1
	p := p
	p.handle = midi.Port(a.next)
	append(&a.ports, p)
	return p.handle
}

// --- sending -------------------------------------------------------------------------------

// Short messages go through the sequencer's encoder; SysEx is sent as one
// variable-length event. A future `time_ns` is scheduled on our queue (the
// kernel delivers it then); otherwise the event goes out directly.
@(private)
alsa_send :: proc(d: ^midi.Driver, handle: midi.Port, message: []u8, time_ns: u64) -> core.Error {
	a := (^Alsa_Midi)(d.data)
	target: Seq_Port
	found := false
	sync.mutex_lock(&a.ports_lock)
	for p in a.ports do if p.handle == handle {
		target, found = p, true
		break
	}
	sync.mutex_unlock(&a.ports_lock)
	if !found || (target.kind != .Output && target.kind != .Virtual_Output) do return .Invalid_Argument

	sync.mutex_lock(&a.send_lock)
	defer sync.mutex_unlock(&a.send_lock)
	ev: snd.snd_seq_event_t
	if message[0] == 0xF0 {
		if message[len(message) - 1] != 0xF7 do return .Invalid_Argument
		ev.type = snd.SND_SEQ_EVENT_SYSEX
		snd.ev_set_ext(&ev, message)
	} else {
		if midi.message_length(message[0]) != len(message) do return .Invalid_Argument
		snd.snd_midi_event_reset_encode(a.encoder)
		bytes := message
		if snd.snd_midi_event_encode(a.encoder, raw_data(bytes), c.long(len(bytes)), &ev) != c.long(len(bytes)) || ev.type == 0 {
			return .Invalid_Argument
		}
	}
	if target.kind == .Output {
		ev.source = {u8(a.client), u8(a.out_port)}
		ev.dest = {u8(target.client), u8(target.port)}
	} else {
		ev.source = {u8(a.client), u8(target.port)}
		ev.dest = {snd.SND_SEQ_ADDRESS_SUBSCRIBERS, snd.SND_SEQ_ADDRESS_UNKNOWN}
	}
	if time_ns > rt.host_time_ns() && time_ns > a.origin_ns {
		t := time_ns - a.origin_ns
		ev.queue = u8(a.queue)
		ev.flags = (ev.flags & snd.SND_SEQ_EVENT_LENGTH_MASK) | snd.SND_SEQ_TIME_STAMP_REAL | snd.SND_SEQ_TIME_MODE_ABS
		ev.time = {u32(t / 1_000_000_000), u32(t % 1_000_000_000)}
	} else {
		ev.queue = snd.SND_SEQ_QUEUE_DIRECT
	}
	return .None if snd.snd_seq_event_output_direct(a.seq, &ev) >= 0 else .Device_Error
}

// --- receiving -------------------------------------------------------------------------------

@(private)
input_thread :: proc(data: rawptr) {
	a := (^Alsa_Midi)(data)
	fds: [8]snd.pollfd
	n := snd.snd_seq_poll_descriptors(a.seq, &fds[0], len(fds), snd.POLLIN)
	for !intrinsics.atomic_load(&a.stop_flag) {
		if snd.poll(&fds[0], c.ulong(n), 100) <= 0 do continue
		for {
			ev: ^snd.snd_seq_event_t
			if snd.snd_seq_event_input(a.seq, &ev) < 0 || ev == nil do break
			deliver(a, ev)
		}
	}
}

@(private)
deliver :: proc(a: ^Alsa_Midi, ev: ^snd.snd_seq_event_t) {
	if ev.type >= snd.SND_SEQ_EVENT_CLIENT_START && ev.type <= snd.SND_SEQ_EVENT_PORT_CHANGE {
		announce(a, ev)
		return
	}
	in_ := a.driver.input
	if in_ == nil do return
	index, ok := port_index(a, ev)
	if !ok do return
	// Kernel timestamp on our queue, else arrival time.
	t := rt.host_time_ns()
	if ev.flags & snd.SND_SEQ_TIME_STAMP_REAL != 0 && c.int(ev.queue) == a.queue {
		t = a.origin_ns + u64(ev.time.tv_sec) * 1_000_000_000 + u64(ev.time.tv_nsec)
	}
	if ev.type == snd.SND_SEQ_EVENT_SYSEX {
		midi.input_push_bytes(in_, t, index, snd.ev_ext(ev))
		return
	}
	buf: [16]u8
	if n := snd.snd_midi_event_decode(a.decoder, &buf[0], len(buf), ev); n > 0 {
		midi.input_push_bytes(in_, t, index, buf[:n])
	}
}

@(private)
port_index :: proc(a: ^Alsa_Midi, ev: ^snd.snd_seq_event_t) -> (u8, bool) {
	sync.mutex_lock(&a.ports_lock)
	defer sync.mutex_unlock(&a.ports_lock)
	for p in a.ports {
		switch p.kind {
		case .Input:
			if c.int(ev.dest.port) == a.in_port && c.int(ev.source.client) == p.client && c.int(ev.source.port) == p.port do return p.port_index, true
		case .Virtual_Input:
			if c.int(ev.dest.port) == p.port do return p.port_index, true
		case .Output, .Virtual_Output:
		}
	}
	return 0, false
}

// System Announce: anything changed means re-enumerate; a port (or whole
// client) we have open going away is Port_Lost for that handle.
@(private)
announce :: proc(a: ^Alsa_Midi, ev: ^snd.snd_seq_event_t) {
	addr := snd.snd_seq_addr_t{ev.data[0], ev.data[1]}
	if c.int(addr.client) == a.client do return // our own ports
	midi.driver_notify(&a.driver, {kind = .Ports_Changed})
	if ev.type != snd.SND_SEQ_EVENT_PORT_EXIT && ev.type != snd.SND_SEQ_EVENT_CLIENT_EXIT do return
	sync.mutex_lock(&a.ports_lock)
	defer sync.mutex_unlock(&a.ports_lock)
	for p in a.ports {
		if p.kind != .Input && p.kind != .Output do continue
		if p.client != c.int(addr.client) do continue
		if ev.type == snd.SND_SEQ_EVENT_PORT_EXIT && p.port != c.int(addr.port) do continue
		midi.driver_notify(&a.driver, {kind = .Port_Lost, port = p.handle})
	}
}
