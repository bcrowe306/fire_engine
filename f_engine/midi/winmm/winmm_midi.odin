#+build windows
// WinMM MIDI driver: works on every Windows version. No virtual ports (returns
// .Unsupported) and no scheduling: Midi_Output holds messages until their time.
// Windows MIDI Services (Windows 11 24H2+) will be a separate driver.
// See docs/design/backend.md.
package winmm_midi

import "base:intrinsics"
import "core:fmt"
import "core:mem"
import "core:sync"
import "core:thread"
import win "core:sys/windows"
import "core:time"

import "fire:core"
import "fire:midi"
import "fire:rt"
import mm "fire:sys/winmm"

SYSEX_BUFFERS :: 4
SYSEX_BUFFER_BYTES :: 4096 // a longer SysEx arrives over several buffers; the byte parser joins them

In_Port :: struct {
	owner:      ^Win_Midi,
	handle:     midi.Port,
	id:         string,
	hmi:        mm.HMIDIIN,
	port_index: u8,
	closing:    bool, // atomic: buffers returned during close are not re-added
	headers:    [SYSEX_BUFFERS]mm.MIDIHDR,
	buffers:    [SYSEX_BUFFERS][SYSEX_BUFFER_BYTES]u8,
}

Out_Port :: struct {
	handle: midi.Port,
	hmo:    mm.HMIDIOUT,
	id:     string,
}

Win_Midi :: struct {
	driver:     midi.Driver,
	allocator:  mem.Allocator,
	lock:       sync.Mutex, // ports; sends to one device are serialized by WinMM
	ins:        [dynamic]^In_Port,
	outs:       [dynamic]Out_Port,
	next:       u32,
	watcher:    ^thread.Thread,
	watch_stop: bool, // atomic
}

create :: proc(allocator := context.allocator) -> (^midi.Driver, core.Error) {
	w := new(Win_Midi, allocator)
	w.allocator = allocator
	w.driver = {vtable = &winmm_vtable, name = "WinMM", can_schedule = false, data = w}
	w.ins = make([dynamic]^In_Port, allocator)
	w.outs = make([dynamic]Out_Port, allocator)
	w.watcher = thread.create_and_start_with_data(w, watch_devices)
	return &w.driver, .None
}

// WinMM has no hot-plug notifications: compare device names every 500 ms.
// In practice this reports arrivals only: once a process has listed a device,
// WinMM keeps listing it after it is gone, and an open handle gets no callback
// (measured with teVirtualMIDI). The Port_Lost check below is best effort for
// devices WinMM does drop.
@(private)
watch_devices :: proc(data: rawptr) {
	w := (^Win_Midi)(data)
	last := signature()
	for !intrinsics.atomic_load(&w.watch_stop) {
		for _ in 0 ..< 10 {
			if intrinsics.atomic_load(&w.watch_stop) do return
			time.sleep(50 * time.Millisecond)
		}
		now := signature()
		if now != last {
			last = now
			midi.driver_notify(&w.driver, {kind = .Ports_Changed})
			ins, outs := input_names(), output_names()
			sync.mutex_lock(&w.lock)
			for p in w.ins do if _, ok := index_of(ins, p.id); !ok do midi.driver_notify(&w.driver, {kind = .Port_Lost, port = p.handle})
			for o in w.outs do if _, ok := index_of(outs, o.id); !ok do midi.driver_notify(&w.driver, {kind = .Port_Lost, port = o.handle})
			sync.mutex_unlock(&w.lock)
		}
		free_all(context.temp_allocator)
	}
}

@(private)
signature :: proc() -> u64 {
	h: u64 = 14695981039346656037 // FNV-1a over all names
	for list in ([][]string{input_names(), output_names()}) {
		for n in list {
			for b in transmute([]u8)n do h = (h ~ u64(b)) * 1099511628211
			h = (h ~ 0xFF) * 1099511628211
		}
		h = (h ~ 0xFE) * 1099511628211
	}
	return h
}

@(private)
winmm_vtable := midi.Driver_VTable {
	destroy               = winmm_destroy,
	enumerate             = winmm_enumerate,
	open_input            = winmm_open_input,
	open_output           = winmm_open_output,
	create_virtual_input  = proc(d: ^midi.Driver, name: string, port_index: u8) -> (midi.Port, core.Error) { return 0, .Unsupported },
	create_virtual_output = proc(d: ^midi.Driver, name: string) -> (midi.Port, core.Error) { return 0, .Unsupported },
	close                 = winmm_close,
	send                  = winmm_send,
}

@(private)
winmm_destroy :: proc(d: ^midi.Driver) {
	w := (^Win_Midi)(d.data)
	if w.watcher != nil {
		intrinsics.atomic_store(&w.watch_stop, true)
		thread.join(w.watcher)
		thread.destroy(w.watcher)
	}
	for len(w.ins) > 0 do winmm_close(d, w.ins[len(w.ins) - 1].handle)
	for len(w.outs) > 0 do winmm_close(d, w.outs[len(w.outs) - 1].handle)
	delete(w.ins)
	delete(w.outs)
	free(w, w.allocator)
}

// --- enumeration ------------------------------------------------------------------------

// WinMM device numbers change when devices come and go, so IDs are device
// names, with " #2", " #3" for duplicates.
@(private)
winmm_enumerate :: proc(d: ^midi.Driver, allocator: mem.Allocator) -> ([]midi.Port_Info, core.Error) {
	infos := make([dynamic]midi.Port_Info, allocator)
	for name in input_names() do append(&infos, midi.Port_Info{fmt.aprint(name, allocator = allocator), fmt.aprint(name, allocator = allocator), .Input})
	for name in output_names() do append(&infos, midi.Port_Info{fmt.aprint(name, allocator = allocator), fmt.aprint(name, allocator = allocator), .Output})
	return infos[:], .None
}

@(private)
input_names :: proc() -> []string {
	names := make([]string, mm.midiInGetNumDevs(), context.temp_allocator)
	for &n, i in names {
		caps: mm.MIDIINCAPSW
		if mm.midiInGetDevCapsW(uintptr(i), &caps, size_of(caps)) == mm.MMSYSERR_NOERROR do n = utf16_name(caps.szPname[:])
	}
	return dedupe(names)
}

@(private)
output_names :: proc() -> []string {
	names := make([]string, mm.midiOutGetNumDevs(), context.temp_allocator)
	for &n, i in names {
		caps: mm.MIDIOUTCAPSW
		if mm.midiOutGetDevCapsW(uintptr(i), &caps, size_of(caps)) == mm.MMSYSERR_NOERROR do n = utf16_name(caps.szPname[:])
	}
	return dedupe(names)
}

@(private)
utf16_name :: proc(raw: []u16) -> string {
	n := 0
	for n < len(raw) && raw[n] != 0 do n += 1
	s, _ := win.utf16_to_utf8(raw[:n], context.temp_allocator)
	return s
}

@(private)
dedupe :: proc(names: []string) -> []string {
	for &n, i in names {
		count := 1
		for prev in names[:i] do if prev == n || (len(prev) > len(n) && prev[:len(n)] == n && prev[len(n):len(n) + 2] == " #") do count += 1
		if count > 1 do n = fmt.tprintf("%s #%d", n, count)
	}
	return names
}

@(private)
index_of :: proc(names: []string, id: string) -> (u32, bool) {
	for n, i in names do if n == id do return u32(i), true
	return 0, false
}

// --- ports --------------------------------------------------------------------------------

@(private)
winmm_open_input :: proc(d: ^midi.Driver, id: string, port_index: u8) -> (midi.Port, core.Error) {
	w := (^Win_Midi)(d.data)
	dev, found := index_of(input_names(), id)
	if !found do return 0, .Invalid_Argument
	p := new(In_Port, w.allocator)
	p.owner, p.port_index = w, port_index
	p.id = fmt.aprint(id, allocator = w.allocator)
	if mm.midiInOpen(&p.hmi, dev, uintptr(rawptr(on_input)), uintptr(p), mm.CALLBACK_FUNCTION | mm.MIDI_IO_STATUS) != mm.MMSYSERR_NOERROR {
		delete(p.id, w.allocator)
		free(p, w.allocator)
		return 0, .Device_Error // in use by another application, usually
	}
	for &h, i in p.headers {
		h = {lpData = &p.buffers[i][0], dwBufferLength = SYSEX_BUFFER_BYTES}
		mm.midiInPrepareHeader(p.hmi, &h, size_of(h))
		mm.midiInAddBuffer(p.hmi, &h, size_of(h))
	}
	if mm.midiInStart(p.hmi) != mm.MMSYSERR_NOERROR {
		close_input(p)
		delete(p.id, w.allocator)
		free(p, w.allocator)
		return 0, .Device_Error
	}
	sync.mutex_lock(&w.lock)
	defer sync.mutex_unlock(&w.lock)
	w.next += 1
	p.handle = midi.Port(w.next)
	append(&w.ins, p)
	return p.handle, .None
}

@(private)
winmm_open_output :: proc(d: ^midi.Driver, id: string) -> (midi.Port, core.Error) {
	w := (^Win_Midi)(d.data)
	dev, found := index_of(output_names(), id)
	if !found do return 0, .Invalid_Argument
	hmo: mm.HMIDIOUT
	if mm.midiOutOpen(&hmo, dev, 0, 0, mm.CALLBACK_NULL) != mm.MMSYSERR_NOERROR do return 0, .Device_Error
	sync.mutex_lock(&w.lock)
	defer sync.mutex_unlock(&w.lock)
	w.next += 1
	append(&w.outs, Out_Port{midi.Port(w.next), hmo, fmt.aprint(id, allocator = w.allocator)})
	return midi.Port(w.next), .None
}

@(private)
winmm_close :: proc(d: ^midi.Driver, handle: midi.Port) {
	w := (^Win_Midi)(d.data)
	sync.mutex_lock(&w.lock)
	defer sync.mutex_unlock(&w.lock)
	for p, i in w.ins do if p.handle == handle {
		close_input(p)
		delete(p.id, w.allocator)
		free(p, w.allocator)
		ordered_remove(&w.ins, i)
		return
	}
	for o, i in w.outs do if o.handle == handle {
		mm.midiOutReset(o.hmo)
		mm.midiOutClose(o.hmo)
		delete(o.id, w.allocator)
		ordered_remove(&w.outs, i)
		return
	}
}

// midiInReset returns every SysEx buffer through the callback (marked done);
// `closing` stops the callback re-adding them.
@(private)
close_input :: proc(p: ^In_Port) {
	intrinsics.atomic_store(&p.closing, true)
	mm.midiInStop(p.hmi)
	mm.midiInReset(p.hmi)
	for &h in p.headers do mm.midiInUnprepareHeader(p.hmi, &h, size_of(h))
	mm.midiInClose(p.hmi)
}

// --- sending --------------------------------------------------------------------------------

// Sends now: WinMM cannot schedule (Driver.can_schedule = false, so
// Midi_Output calls this at the message's time). SysEx blocks until WinMM is
// done with the buffer.
@(private)
winmm_send :: proc(d: ^midi.Driver, handle: midi.Port, message: []u8, time_ns: u64) -> core.Error {
	w := (^Win_Midi)(d.data)
	hmo: mm.HMIDIOUT
	sync.mutex_lock(&w.lock)
	for o in w.outs do if o.handle == handle do hmo = o.hmo
	sync.mutex_unlock(&w.lock)
	if hmo == nil do return .Invalid_Argument

	if message[0] != 0xF0 {
		if midi.message_length(message[0]) != len(message) do return .Invalid_Argument
		packed := u32(message[0])
		if len(message) > 1 do packed |= u32(message[1]) << 8
		if len(message) > 2 do packed |= u32(message[2]) << 16
		return .None if mm.midiOutShortMsg(hmo, packed) == mm.MMSYSERR_NOERROR else .Device_Error
	}
	if message[len(message) - 1] != 0xF7 do return .Invalid_Argument
	hdr := mm.MIDIHDR{lpData = raw_data(message), dwBufferLength = u32(len(message)), dwBytesRecorded = u32(len(message))}
	if mm.midiOutPrepareHeader(hmo, &hdr, size_of(hdr)) != mm.MMSYSERR_NOERROR do return .Device_Error
	defer for mm.midiOutUnprepareHeader(hmo, &hdr, size_of(hdr)) == mm.MIDIERR_STILLPLAYING do time.sleep(time.Millisecond)
	if mm.midiOutLongMsg(hmo, &hdr, size_of(hdr)) != mm.MMSYSERR_NOERROR do return .Device_Error
	for intrinsics.atomic_load(&hdr.dwFlags) & mm.MHDR_DONE == 0 do time.sleep(time.Millisecond)
	return .None
}

// --- receiving (WinMM's callback thread) -------------------------------------------------------

// Short messages arrive packed in param1; SysEx in a returned buffer, which is
// handed back for reuse. Times are arrival on the host clock (WinMM's own
// timestamps are whole milliseconds).
@(private)
on_input :: proc "system" (h: mm.HMIDIIN, msg: u32, instance: uintptr, param1: uintptr, param2: uintptr) {
	p := (^In_Port)(instance)
	in_ := p.owner.driver.input
	t := rt.host_time_ns()
	switch msg {
	case mm.MIM_DATA, mm.MIM_MOREDATA:
		if in_ == nil do return
		status := u8(param1)
		n := midi.message_length(status)
		if n == 0 do return
		bytes := [3]u8{status, u8(param1 >> 8), u8(param1 >> 16)}
		midi.input_push_bytes(in_, t, p.port_index, bytes[:n])
	case mm.MIM_LONGDATA:
		hdr := (^mm.MIDIHDR)(param1)
		if in_ != nil && hdr.dwBytesRecorded > 0 {
			midi.input_push_bytes(in_, t, p.port_index, hdr.lpData[:hdr.dwBytesRecorded])
		}
		if !intrinsics.atomic_load(&p.closing) do mm.midiInAddBuffer(h, hdr, size_of(mm.MIDIHDR))
	case mm.MIM_ERROR, mm.MIM_LONGERROR:
		if in_ != nil do intrinsics.atomic_add_explicit(&in_.ignored, 1, .Relaxed)
	}
}
