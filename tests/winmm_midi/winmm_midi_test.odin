#+build windows
// WinMM MIDI tests. WinMM cannot create ports, so the loopback comes from
// teVirtualMIDI (installed with loopMIDI; scripts/cloud/windows.sh installs
// it): this test creates a port that appears to WinMM as an input and an
// output, and echoes whatever is sent to the output back on the input.
// Skipped when teVirtualMIDI64.dll is missing.
package test_winmm_midi

import "core:dynlib"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:testing"
import "core:time"
import win "core:sys/windows"

import "fire:core"
import "fire:midi"
import wmm "fire:midi/winmm"
import "fire:rt"
import mm "fire:sys/winmm"

// --- teVirtualMIDI (test-only helper) -------------------------------------------------------

TE_VM_FLAGS_PARSE_RX         :: u32(1)
TE_VM_FLAGS_INSTANTIATE_BOTH :: u32(12)

VM_Callback :: #type proc "system" (port: rawptr, data: [^]u8, length: u32, instance: uintptr)

Te_VM :: struct {
	lib:         dynlib.Library,
	create_port: proc "system" (name: win.wstring, callback: VM_Callback, instance: uintptr, max_sysex: u32, flags: u32) -> rawptr,
	close_port:  proc "system" (port: rawptr),
	send_data:   proc "system" (port: rawptr, data: [^]u8, length: u32) -> win.BOOL,
}

te: Te_VM

load_te :: proc() -> bool {
	if te.lib != nil do return true
	lib, ok := dynlib.load_library("teVirtualMIDI64.dll")
	if !ok do return false
	te.lib = lib
	te.create_port = auto_cast dynlib.symbol_address(lib, "virtualMIDICreatePortEx2")
	te.close_port = auto_cast dynlib.symbol_address(lib, "virtualMIDIClosePort")
	te.send_data = auto_cast dynlib.symbol_address(lib, "virtualMIDISendData")
	return te.create_port != nil && te.close_port != nil && te.send_data != nil
}

// Echo: data sent to the port's output side comes back on its input side.
echo :: proc "system" (port: rawptr, data: [^]u8, length: u32, instance: uintptr) {
	if data != nil && length > 0 do te.send_data(port, data, length)
}

Loop :: struct {
	port: rawptr,
	name: string,
}

// One port per test (tests run in parallel in one process); names stay under
// WinMM's 31 characters.
loop_make :: proc(tag: string) -> (l: Loop, ok: bool) {
	if !load_te() {
		log.info("teVirtualMIDI64.dll not installed (loopMIDI); skipping")
		return
	}
	l.name = fmt.tprintf("Fire%s%d", tag, os.get_pid() % 100000)
	l.port = te.create_port(win.utf8_to_wstring(l.name, context.temp_allocator), echo, 0, 65536, TE_VM_FLAGS_PARSE_RX | TE_VM_FLAGS_INSTANTIATE_BOTH)
	return l, l.port != nil
}

loop_destroy :: proc(l: Loop) {
	if l.port != nil do te.close_port(l.port)
}

// --- rig --------------------------------------------------------------------------------------

Rig :: struct {
	d:   ^midi.Driver,
	in_: midi.Midi_Input,
}

rig_make :: proc(t: ^testing.T) -> ^Rig {
	r := new(Rig)
	cfg := midi.default_input_config()
	cfg.max_sysex_len = 16384
	testing.expect_value(t, midi.input_init(&r.in_, cfg), mem.Allocator_Error.None)
	err: core.Error
	r.d, err = wmm.create()
	testing.expect_value(t, err, core.Error.None)
	r.d.input = &r.in_
	return r
}

rig_destroy :: proc(r: ^Rig) {
	midi.driver_destroy(r.d)
	midi.input_destroy(&r.in_)
	free(r)
}

// The new device can take a moment to appear to WinMM.
wait_for_device :: proc(d: ^midi.Driver, name: string) -> bool {
	start := time.tick_now()
	for time.tick_since(start) < 5 * time.Second {
		infos, _ := midi.enumerate(d, context.temp_allocator)
		ins, outs := false, false
		for info in infos do if info.id == name {
			if info.direction == .Input do ins = true
			if info.direction == .Output do outs = true
		}
		if ins && outs do return true
		time.sleep(50 * time.Millisecond)
	}
	return false
}

receive :: proc(r: ^Rig, n: int, timeout := 2 * time.Second) -> []midi.Input_Event {
	out := make([dynamic]midi.Input_Event, context.temp_allocator)
	start := time.tick_now()
	for len(out) < n && time.tick_since(start) < timeout {
		for e in rt.spsc_pop(&r.in_.queue) do append(&out, e)
		time.sleep(time.Millisecond)
	}
	return out[:]
}

receive_sysex :: proc(r: ^Rig, timeout := 3 * time.Second) -> (midi.Sysex_Message, bool) {
	start := time.tick_now()
	for time.tick_since(start) < timeout {
		if msg, ok := midi.sysex_pop(&r.in_.sysex, context.temp_allocator); ok do return msg, true
		time.sleep(time.Millisecond)
	}
	return {}, false
}

Msg :: struct {
	bytes: [3]u8,
	len:   int,
}

MESSAGES := [?]Msg {
	{{0x90, 60, 100}, 3},
	{{0xB3, 7, 64}, 3},
	{{0xE0, 0x00, 0x40}, 3},
	{{0xC5, 12, 0}, 2},
	{{0xD1, 99, 0}, 2},
	{{0x80, 60, 0}, 3},
}

sysex_message :: proc(n: int) -> []u8 {
	m := make([]u8, n + 2, context.temp_allocator)
	m[0], m[n + 1] = 0xF0, 0xF7
	for i in 1 ..= n do m[i] = u8(i * 13) & 0x7F
	return m
}

// --- tests ---------------------------------------------------------------------------------------

@(test)
midihdr_layout :: proc(t: ^testing.T) {
	testing.expect_value(t, size_of(mm.MIDIHDR), 120) // 64-bit mmeapi.h
	testing.expect_value(t, offset_of(mm.MIDIHDR, dwFlags), 24)
	testing.expect_value(t, size_of(mm.MIDIINCAPSW), 76)
	testing.expect_value(t, size_of(mm.MIDIOUTCAPSW), 84)
}

@(test)
loopback_messages_and_sysex :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	loop, ok := loop_make("Lb")
	if !ok do return
	defer loop_destroy(loop)
	r := rig_make(t)
	defer rig_destroy(r)
	if !wait_for_device(r.d, loop.name) {
		testing.expectf(t, false, "%s did not appear as a WinMM input and output", loop.name)
		return
	}
	in_port, err := midi.open_input(r.d, loop.name, 2)
	testing.expect_value(t, err, core.Error.None)
	out: midi.Port
	out, err = midi.open_output(r.d, loop.name)
	testing.expect_value(t, err, core.Error.None)

	before := rt.host_time_ns()
	for m in MESSAGES {
		bytes := m.bytes
		testing.expect_value(t, midi.send(r.d, out, bytes[:m.len]), core.Error.None)
	}
	got := receive(r, len(MESSAGES))
	testing.expect_value(t, len(got), len(MESSAGES))
	for e, i in got {
		if i >= len(MESSAGES) do break
		testing.expectf(t, e.bytes == MESSAGES[i].bytes, "message %d: got %v want %v", i, e.bytes, MESSAGES[i].bytes)
		testing.expect_value(t, e.port, 2)
		testing.expect(t, e.time_ns >= before)
	}
	// 3 KB fits one 4 KB WinMM buffer; 10 KB spans three and is joined by the byte parser.
	for n in ([]int{3000, 10000}) {
		sysex := sysex_message(n)
		testing.expect_value(t, midi.send(r.d, out, sysex), core.Error.None)
		msg, sysex_ok := receive_sysex(r)
		testing.expectf(t, sysex_ok, "no %d-byte SysEx received", n)
		testing.expectf(t, mem.compare(msg.data, sysex[1:len(sysex) - 1]) == 0, "SysEx payload mismatch (%d of %d bytes)", len(msg.data), n)
	}
	midi.close_port(r.d, in_port)
	testing.expect_value(t, midi.input_stats(&r.in_), midi.Input_Stats{})
}

// WinMM cannot schedule, so Midi_Output's sender holds each message until
// its time: each must arrive no earlier than scheduled, and soon after.
@(test)
scheduled_output_arrives_on_time :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	loop, ok := loop_make("Sc")
	if !ok do return
	defer loop_destroy(loop)
	r := rig_make(t)
	defer rig_destroy(r)
	if !wait_for_device(r.d, loop.name) do return
	_, err := midi.open_input(r.d, loop.name, 0)
	testing.expect_value(t, err, core.Error.None)
	out: midi.Port
	out, err = midi.open_output(r.d, loop.name)
	testing.expect_value(t, err, core.Error.None)

	o: midi.Midi_Output
	midi.output_init(&o, r.d, 64)
	defer midi.output_destroy(&o)
	midi.output_start(&o)
	base := rt.host_time_ns() + 30_000_000
	for i in 0 ..< 5 do midi.output_push(&o, {base + u64(i) * 20_000_000, out, {0x90, u8(60 + i), 100}})
	got := receive(r, 5)
	testing.expect_value(t, len(got), 5)
	for e, i in got {
		due := base + u64(i) * 20_000_000
		late := i64(e.time_ns) - i64(due)
		// Never early (that would mean no scheduling). The bound on lateness
		// covers the teVirtualMIDI echo hop and a busy 2-vCPU test machine
		// (17 ms seen with four test packages running; < 10 ms when idle).
		testing.expectf(t, late >= 0 && late < 25_000_000, "message %d arrived %d ns after its time", i, late)
	}
}

@(test)
unsupported_and_bad_arguments :: proc(t: ^testing.T) {
	r := rig_make(t)
	defer rig_destroy(r)
	_, err := midi.create_virtual_input(r.d, "x", 0)
	testing.expect_value(t, err, core.Error.Unsupported)
	_, err = midi.create_virtual_output(r.d, "x")
	testing.expect_value(t, err, core.Error.Unsupported)
	_, err = midi.open_input(r.d, "No Such Device", 0)
	testing.expect_value(t, err, core.Error.Invalid_Argument)
	_, err = midi.open_output(r.d, "No Such Device")
	testing.expect_value(t, err, core.Error.Invalid_Argument)
	testing.expect_value(t, midi.send(r.d, 999, {0x90, 1, 1}), core.Error.Invalid_Argument)
}

// A teVirtualMIDI port appears: the watcher reports Ports_Changed. That is
// all WinMM can show. Once a process has listed a device, WinMM keeps listing
// it after it is gone, and an open handle gets no callback when its device
// vanishes (both measured with teVirtualMIDI). Removal and Port_Lost are left
// to the Windows MIDI Services driver.
@(test)
hotplug_reports_arrivals :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	if !load_te() do return
	r := rig_make(t)
	defer rig_destroy(r)
	time.sleep(600 * time.Millisecond) // let the watcher take its first snapshot
	for _ in midi.poll_event(r.d) {}

	loop, ok := loop_make("Hp")
	if !ok do return
	defer loop_destroy(loop)
	changed := false
	start := time.tick_now()
	for !changed && time.tick_since(start) < 5 * time.Second {
		for e in midi.poll_event(r.d) do changed ||= e.kind == .Ports_Changed
		time.sleep(20 * time.Millisecond)
	}
	testing.expect(t, changed, "no Ports_Changed when a port appeared")
	testing.expect(t, wait_for_device(r.d, loop.name), "new port not listed")
}
