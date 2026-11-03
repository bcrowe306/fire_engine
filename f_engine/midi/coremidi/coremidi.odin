#+build darwin
// CoreMIDI driver (macOS 11+), using the UMP event-list APIs with the MIDI 1.0
// protocol. Input from every connected source arrives through one input port,
// so CoreMIDI delivers it on one thread. See docs/design/backend.md.
package coremidi

import "base:intrinsics"
import "core:fmt"
import "core:mem"
import "core:strconv"
import CF "core:sys/darwin/CoreFoundation"
import "core:sync"
import "core:thread"
import "core:time"

import "fire:core"
import "fire:midi"
import "fire:rt"
import cm "fire:sys/coremidi"

Port_Kind :: enum u8 {
	Input,
	Output,
	Virtual_Input,  // our destination: others send to us
	Virtual_Output, // our source: others receive from us
}

Open_Port :: struct {
	handle:     midi.Port,
	kind:       Port_Kind,
	endpoint:   cm.MIDIEndpointRef,
	port_index: u8,
	block:      ^cm.Receive_Block, // virtual inputs: must outlive the endpoint
	owner:      ^Core_Midi,
}

Core_Midi :: struct {
	driver:      midi.Driver,
	allocator:   mem.Allocator,
	client:      cm.MIDIClientRef,
	in_port:     cm.MIDIPortRef,
	out_port:    cm.MIDIPortRef,
	in_block:    cm.Receive_Block,
	ports:       [dynamic]^Open_Port,
	next_handle: u32,
	timebase:    cm.mach_timebase_info_data_t,

	ports_lock:    sync.Mutex, // ports is read by the notification thread
}

// CoreMIDI delivers every client's notifications on the run loop of the
// thread that created the *first* client in the process. So one notifier
// thread, started on first use and alive for the rest of the process, creates
// every client and runs its run loop.
@(private)
Notifier :: struct {
	lock:    sync.Mutex, // one request at a time
	thread:  ^thread.Thread,
	request: ^Core_Midi, // atomic: client to create
	status:  cm.OSStatus,
	done:    sync.Sema,
}

@(private)
notifier: Notifier

@(private)
create_client :: proc(c: ^Core_Midi) -> cm.OSStatus {
	sync.mutex_lock(&notifier.lock)
	defer sync.mutex_unlock(&notifier.lock)
	if notifier.thread == nil {
		notifier.thread = thread.create_and_start(notifier_main, context)
	}
	intrinsics.atomic_store(&notifier.request, c)
	sync.sema_wait(&notifier.done)
	return notifier.status
}

@(private)
notifier_main :: proc() {
	for {
		if c := intrinsics.atomic_exchange(&notifier.request, nil); c != nil {
			name := cfstring("Fire Engine")
			notifier.status = cm.MIDIClientCreate(name, on_notify, c, &c.client)
			CF.CFRelease(CF.TypeRef(name))
			sync.sema_post(&notifier.done)
		}
		if cm.CFRunLoopRunInMode(cm.kCFRunLoopDefaultMode, 0.02, false) == cm.kCFRunLoopRunFinished {
			time.sleep(20 * time.Millisecond) // nothing attached yet
		}
	}
}

create :: proc(allocator := context.allocator) -> (^midi.Driver, core.Error) {
	c := new(Core_Midi, allocator)
	c.allocator = allocator
	c.driver = {vtable = &cm_vtable, name = "CoreMIDI", can_schedule = true, data = c}
	c.ports = make([dynamic]^Open_Port, allocator)
	cm.mach_timebase_info(&c.timebase)

	if create_client(c) != cm.NO_ERR {
		cm_destroy(&c.driver)
		return nil, .Device_Error
	}
	cm.receive_block_init(&c.in_block, on_receive, c)
	in_name := cfstring("Fire Engine In")
	defer CF.CFRelease(CF.TypeRef(in_name))
	out_name := cfstring("Fire Engine Out")
	defer CF.CFRelease(CF.TypeRef(out_name))
	if cm.MIDIInputPortCreateWithProtocol(c.client, in_name, cm.kMIDIProtocol_1_0, &c.in_port, &c.in_block) != cm.NO_ERR ||
	   cm.MIDIOutputPortCreate(c.client, out_name, &c.out_port) != cm.NO_ERR {
		cm_destroy(&c.driver)
		return nil, .Device_Error
	}
	return &c.driver, .None
}

@(private)
cm_vtable := midi.Driver_VTable {
	destroy               = cm_destroy,
	enumerate             = cm_enumerate,
	open_input            = cm_open_input,
	open_output           = cm_open_output,
	create_virtual_input  = cm_create_virtual_input,
	create_virtual_output = cm_create_virtual_output,
	close                 = cm_close,
	send                  = cm_send,
}

@(private)
cm_destroy :: proc(d: ^midi.Driver) {
	c := (^Core_Midi)(d.data)
	for len(c.ports) > 0 do cm_close(d, c.ports[len(c.ports) - 1].handle)
	if c.in_port != 0 do cm.MIDIPortDispose(c.in_port)
	if c.out_port != 0 do cm.MIDIPortDispose(c.out_port)
	if c.client != 0 do cm.MIDIClientDispose(c.client)
	delete(c.ports)
	free(c, c.allocator)
}

// Run-loop thread. Setup changes mean re-enumerate; removal of an endpoint we
// have open is Port_Lost for that handle.
@(private)
on_notify :: proc "c" (message: ^cm.MIDINotification, refcon: rawptr) {
	c := (^Core_Midi)(refcon)
	switch message.messageID {
	case cm.kMIDIMsgSetupChanged, cm.kMIDIMsgObjectAdded:
		midi.driver_notify(&c.driver, {kind = .Ports_Changed})
	case cm.kMIDIMsgObjectRemoved:
		midi.driver_notify(&c.driver, {kind = .Ports_Changed})
		n := (^cm.MIDIObjectAddRemoveNotification)(message)
		sync.mutex_lock(&c.ports_lock)
		defer sync.mutex_unlock(&c.ports_lock)
		for p in c.ports {
			if (p.kind == .Input || p.kind == .Output) && p.endpoint == n.child {
				midi.driver_notify(&c.driver, {kind = .Port_Lost, port = p.handle})
			}
		}
	}
}

// --- enumeration -------------------------------------------------------------------

@(private)
cm_enumerate :: proc(d: ^midi.Driver, allocator: mem.Allocator) -> ([]midi.Port_Info, core.Error) {
	infos := make([dynamic]midi.Port_Info, allocator)
	for i in 0 ..< cm.MIDIGetNumberOfSources() {
		append(&infos, port_info(cm.MIDIGetSource(i), .Input, allocator))
	}
	for i in 0 ..< cm.MIDIGetNumberOfDestinations() {
		append(&infos, port_info(cm.MIDIGetDestination(i), .Output, allocator))
	}
	return infos[:], .None
}

@(private)
port_info :: proc(e: cm.MIDIEndpointRef, dir: midi.Port_Direction, allocator: mem.Allocator) -> midi.Port_Info {
	uid: i32
	cm.MIDIObjectGetIntegerProperty(e, cm.kMIDIPropertyUniqueID, &uid)
	name := string_property(e, cm.kMIDIPropertyDisplayName, allocator)
	if name == "" do name = string_property(e, cm.kMIDIPropertyName, allocator)
	return {id = fmt.aprintf("%d", uid, allocator = allocator), name = name, direction = dir}
}

// Endpoints are identified by their CoreMIDI unique ID, which persists.
@(private)
find_endpoint :: proc(id: string, dir: midi.Port_Direction) -> (cm.MIDIEndpointRef, bool) {
	want, ok := strconv.parse_i64(id)
	if !ok do return 0, false
	count := cm.MIDIGetNumberOfSources() if dir == .Input else cm.MIDIGetNumberOfDestinations()
	for i in 0 ..< count {
		e := cm.MIDIGetSource(i) if dir == .Input else cm.MIDIGetDestination(i)
		uid: i32
		if cm.MIDIObjectGetIntegerProperty(e, cm.kMIDIPropertyUniqueID, &uid) == cm.NO_ERR && i64(uid) == want do return e, true
	}
	return 0, false
}

// --- ports -------------------------------------------------------------------------

@(private)
cm_open_input :: proc(d: ^midi.Driver, id: string, port_index: u8) -> (midi.Port, core.Error) {
	c := (^Core_Midi)(d.data)
	src, found := find_endpoint(id, .Input)
	if !found do return 0, .Invalid_Argument
	// connRefCon carries the port index (+1, so it is never nil).
	if cm.MIDIPortConnectSource(c.in_port, src, rawptr(uintptr(port_index) + 1)) != cm.NO_ERR do return 0, .Device_Error
	return add_port(c, {kind = .Input, endpoint = src, port_index = port_index}), .None
}

@(private)
cm_open_output :: proc(d: ^midi.Driver, id: string) -> (midi.Port, core.Error) {
	c := (^Core_Midi)(d.data)
	dst, found := find_endpoint(id, .Output)
	if !found do return 0, .Invalid_Argument
	return add_port(c, {kind = .Output, endpoint = dst}), .None
}

@(private)
cm_create_virtual_input :: proc(d: ^midi.Driver, name: string, port_index: u8) -> (midi.Port, core.Error) {
	c := (^Core_Midi)(d.data)
	p := new(Open_Port, c.allocator)
	p^ = {kind = .Virtual_Input, port_index = port_index, owner = c}
	p.block = new(cm.Receive_Block, c.allocator)
	cm.receive_block_init(p.block, on_receive_virtual, p)
	cf_name := cfstring(name)
	defer CF.CFRelease(CF.TypeRef(cf_name))
	if cm.MIDIDestinationCreateWithProtocol(c.client, cf_name, cm.kMIDIProtocol_1_0, &p.endpoint, p.block) != cm.NO_ERR {
		free(p.block, c.allocator)
		free(p, c.allocator)
		return 0, .Device_Error
	}
	return register(c, p), .None
}

@(private)
cm_create_virtual_output :: proc(d: ^midi.Driver, name: string) -> (midi.Port, core.Error) {
	c := (^Core_Midi)(d.data)
	endpoint: cm.MIDIEndpointRef
	cf_name := cfstring(name)
	defer CF.CFRelease(CF.TypeRef(cf_name))
	if cm.MIDISourceCreateWithProtocol(c.client, cf_name, cm.kMIDIProtocol_1_0, &endpoint) != cm.NO_ERR do return 0, .Device_Error
	return add_port(c, {kind = .Virtual_Output, endpoint = endpoint}), .None
}

@(private)
cm_close :: proc(d: ^midi.Driver, handle: midi.Port) {
	c := (^Core_Midi)(d.data)
	sync.mutex_lock(&c.ports_lock)
	defer sync.mutex_unlock(&c.ports_lock)
	for p, i in c.ports {
		if p.handle != handle do continue
		switch p.kind {
		case .Input:          cm.MIDIPortDisconnectSource(c.in_port, p.endpoint)
		case .Output:
		case .Virtual_Input, .Virtual_Output: cm.MIDIEndpointDispose(p.endpoint)
		}
		if p.block != nil do free(p.block, c.allocator)
		free(p, c.allocator)
		ordered_remove(&c.ports, i)
		return
	}
}

@(private)
add_port :: proc(c: ^Core_Midi, p: Open_Port) -> midi.Port {
	np := new(Open_Port, c.allocator)
	np^ = p
	np.owner = c
	return register(c, np)
}

@(private)
register :: proc(c: ^Core_Midi, p: ^Open_Port) -> midi.Port {
	sync.mutex_lock(&c.ports_lock)
	defer sync.mutex_unlock(&c.ports_lock)
	c.next_handle += 1
	p.handle = midi.Port(c.next_handle)
	append(&c.ports, p)
	return p.handle
}

// --- sending -----------------------------------------------------------------------

@(private)
cm_send :: proc(d: ^midi.Driver, handle: midi.Port, message: []u8, time_ns: u64) -> core.Error {
	c := (^Core_Midi)(d.data)
	p: ^Open_Port
	sync.mutex_lock(&c.ports_lock)
	for q in c.ports do if q.handle == handle do p = q
	sync.mutex_unlock(&c.ports_lock)
	if p == nil || (p.kind != .Output && p.kind != .Virtual_Output) do return .Invalid_Argument

	words_buf: [512]u32
	words: []u32
	if message[0] == 0xF0 {
		payload := message[1:]
		if len(payload) > 0 && payload[len(payload) - 1] == 0xF7 do payload = payload[:len(payload) - 1]
		n := midi.ump_sysex_packet_count(len(payload))
		if n * 2 > len(words_buf) do return .Invalid_Argument // > 1530 bytes: send in parts
		for i in 0 ..< n {
			w := midi.ump_sysex_packet(payload, i)
			words_buf[2 * i], words_buf[2 * i + 1] = w[0], w[1]
		}
		words = words_buf[:2 * n]
	} else {
		b: [3]u8
		copy(b[:], message)
		w, ok := midi.ump_from_short(b)
		if !ok do return .Invalid_Argument
		words_buf[0] = w
		words = words_buf[:1]
	}

	// A packet we build holds at most 64 words; send each 64-word chunk (32
	// SysEx packets, never split mid-packet) as its own event list.
	stamp := ns_to_host(c, time_ns)
	for start := 0; start < len(words); start += 64 {
		chunk := words[start:min(start + 64, len(words))]
		list_buf: [36]u64 // 288 bytes ≥ one MIDIEventList with a full packet
		list := (^cm.MIDIEventList)(&list_buf)
		pkt := cm.MIDIEventListInit(list, cm.kMIDIProtocol_1_0)
		if cm.MIDIEventListAdd(list, size_of(list_buf), pkt, stamp, len(chunk), raw_data(chunk)) == nil do return .Invalid_Argument
		status: cm.OSStatus
		if p.kind == .Output {
			status = cm.MIDISendEventList(c.out_port, p.endpoint, list)
		} else {
			status = cm.MIDIReceivedEventList(p.endpoint, list)
		}
		if status != cm.NO_ERR do return .Device_Error
	}
	return .None
}

// --- receiving (CoreMIDI's receive thread) -----------------------------------------

@(private)
on_receive :: proc "c" (block: ^cm.Receive_Block, list: ^cm.MIDIEventList, src_ref: rawptr) {
	c := (^Core_Midi)(block.user)
	deliver(c, list, u8(uintptr(src_ref) - 1))
}

@(private)
on_receive_virtual :: proc "c" (block: ^cm.Receive_Block, list: ^cm.MIDIEventList, src_ref: rawptr) {
	p := (^Open_Port)(block.user)
	deliver(p.owner, list, p.port_index)
}

@(private)
deliver :: proc "contextless" (c: ^Core_Midi, list: ^cm.MIDIEventList, port_index: u8) {
	in_ := c.driver.input
	if in_ == nil do return
	pkt := &list.packet[0]
	for _ in 0 ..< list.numPackets {
		t := host_to_ns(c, pkt.timeStamp) if pkt.timeStamp != 0 else rt.host_time_ns()
		// wordCount may exceed the declared 64: received packets are variable length.
		words := ([^]u32)(&pkt.words)[:pkt.wordCount]
		midi.input_push_ump(in_, t, port_index, words)
		pkt = cm.event_packet_next(pkt)
	}
}

// --- helpers -----------------------------------------------------------------------

@(private)
host_to_ns :: proc "contextless" (c: ^Core_Midi, host: u64) -> u64 {
	return u64(u128(host) * u128(c.timebase.numer) / u128(c.timebase.denom))
}

@(private)
ns_to_host :: proc "contextless" (c: ^Core_Midi, ns: u64) -> u64 {
	if ns == 0 do return 0
	return u64(u128(ns) * u128(c.timebase.denom) / u128(c.timebase.numer))
}

@(private)
cfstring :: proc(s: string) -> cm.CFStringRef {
	return cm.CFStringCreateWithBytes(nil, raw_data(s), CF.Index(len(s)), cm.kCFStringEncodingUTF8, false)
}

@(private)
string_property :: proc(e: cm.MIDIObjectRef, key: cm.CFStringRef, allocator: mem.Allocator) -> string {
	ref: cm.CFStringRef
	if cm.MIDIObjectGetStringProperty(e, key, &ref) != cm.NO_ERR || ref == nil do return ""
	defer CF.CFRelease(CF.TypeRef(ref))
	utf8 := CF.StringEncoding(CF.StringBuiltInEncodings.UTF8)
	cap := int(CF.StringGetMaximumSizeForEncoding(CF.StringGetLength(ref), utf8)) + 1
	buf := make([]u8, cap, allocator)
	if !CF.StringGetCString(ref, raw_data(buf), CF.Index(cap), utf8) {
		delete(buf, allocator)
		return ""
	}
	n := 0
	for n < cap && buf[n] != 0 do n += 1
	return string(buf[:n])
}
