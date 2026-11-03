#+build darwin
// CoreMIDI driver tests. No hardware: the driver loops back through virtual
// ports it creates itself. Port names include the process ID, so concurrent
// runs (one per optimization level) don't see each other's ports.
package test_coremidi

import "core:fmt"
import "core:mem"
import "core:os"
import "core:testing"
import "core:time"

import "fire:core"
import "fire:midi"
import cmd "fire:midi/coremidi"
import "fire:rt"
import cm "fire:sys/coremidi"

@(test)
struct_layouts_match_sdk :: proc(t: ^testing.T) {
	// Values printed by a C program against the macOS SDK.
	testing.expect_value(t, size_of(cm.MIDIEventPacket), 268)
	testing.expect_value(t, offset_of(cm.MIDIEventPacket, wordCount), 8)
	testing.expect_value(t, offset_of(cm.MIDIEventPacket, words), 12)
	testing.expect_value(t, size_of(cm.MIDIEventList), 276)
	testing.expect_value(t, offset_of(cm.MIDIEventList, packet), 8)
	// Clang block ABI: isa, flags, reserved, invoke, descriptor, captures.
	testing.expect_value(t, offset_of(cm.Receive_Block, invoke), 16)
	testing.expect_value(t, offset_of(cm.Receive_Block, descriptor), 24)
}

Rig :: struct {
	d:   ^midi.Driver,
	in_: midi.Midi_Input,
}

rig_make :: proc(t: ^testing.T) -> (^Rig, bool) {
	r := new(Rig)
	testing.expect_value(t, midi.input_init(&r.in_), mem.Allocator_Error.None)
	err: core.Error
	r.d, err = cmd.create()
	testing.expect_value(t, err, core.Error.None)
	if err != .None do return r, false
	r.d.input = &r.in_
	return r, true
}

rig_destroy :: proc(r: ^Rig) {
	midi.driver_destroy(r.d)
	midi.input_destroy(&r.in_)
	free(r)
}

unique_name :: proc(base: string) -> string {
	return fmt.tprintf("%s %d", base, os.get_pid())
}

find_port :: proc(d: ^midi.Driver, name: string, dir: midi.Port_Direction) -> (string, bool) {
	infos, _ := midi.enumerate(d, context.temp_allocator)
	for info in infos do if info.name == name && info.direction == dir do return info.id, true
	return "", false
}

// Waits until `n` short messages are queued, then drains them.
receive :: proc(r: ^Rig, n: int, timeout := 2 * time.Second) -> []midi.Input_Event {
	out := make([dynamic]midi.Input_Event, context.temp_allocator)
	start := time.tick_now()
	for len(out) < n && time.tick_since(start) < timeout {
		for e in rt.spsc_pop(&r.in_.queue) do append(&out, e)
		time.sleep(time.Millisecond)
	}
	return out[:]
}

receive_sysex :: proc(r: ^Rig, timeout := 2 * time.Second) -> (midi.Sysex_Message, bool) {
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
	{{0xE0, 0x00, 0x40}, 3}, // pitch bend center
	{{0xC5, 12, 0}, 2},
	{{0xF8, 0, 0}, 1},       // clock
	{{0x80, 60, 0}, 3},
}

sysex_message :: proc(n: int) -> []u8 {
	m := make([]u8, n + 2, context.temp_allocator)
	m[0], m[n + 1] = 0xF0, 0xF7
	for i in 1 ..= n do m[i] = u8(i * 13) & 0x7F
	return m
}

// Our virtual output (a source) → our input port, which is connected to it.
@(test)
virtual_output_loops_back_to_input :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 20 * time.Second)
	r, ok := rig_make(t)
	defer rig_destroy(r)
	if !ok do return

	name := unique_name("Fire Test Source")
	src, err := midi.create_virtual_output(r.d, name)
	testing.expect_value(t, err, core.Error.None)
	id, found := find_port(r.d, name, .Input)
	testing.expectf(t, found, "virtual source %q not listed as an input", name)
	if !found do return
	in_port: midi.Port
	in_port, err = midi.open_input(r.d, id, 3)
	testing.expect_value(t, err, core.Error.None)

	// Timestamps travel with the messages (to the nanosecond, give or take one
	// host-clock tick); a virtual source does not delay delivery to them.
	stamp := rt.host_time_ns() + 50_000_000
	for m, i in MESSAGES {
		bytes := m.bytes
		testing.expect_value(t, midi.send(r.d, src, bytes[:m.len], stamp + u64(i)), core.Error.None)
	}
	got := receive(r, len(MESSAGES))
	testing.expect_value(t, len(got), len(MESSAGES))
	for e, i in got {
		if i >= len(MESSAGES) do break
		testing.expectf(t, e.bytes == MESSAGES[i].bytes, "message %d: got %v want %v", i, e.bytes, MESSAGES[i].bytes)
		testing.expect_value(t, e.port, 3)
		testing.expectf(t, abs(i64(e.time_ns) - i64(stamp + u64(i))) < 100, "message %d: time %d want %d", i, e.time_ns, stamp + u64(i))
	}

	sysex := sysex_message(300)
	testing.expect_value(t, midi.send(r.d, src, sysex), core.Error.None)
	msg, sysex_ok := receive_sysex(r)
	testing.expect(t, sysex_ok, "no SysEx received")
	testing.expectf(t, mem.compare(msg.data, sysex[1:len(sysex) - 1]) == 0, "SysEx payload mismatch (%d bytes)", len(msg.data))
	testing.expect_value(t, msg.port, 3)

	midi.close_port(r.d, in_port)
	testing.expect_value(t, midi.send(r.d, src, {0x90, 1, 1}), core.Error.None)
	testing.expect_value(t, len(receive(r, 1, 200 * time.Millisecond)), 0) // disconnected
	testing.expect_value(t, midi.input_stats(&r.in_), midi.Input_Stats{})
}

// Our output port → our virtual input (a destination).
@(test)
output_reaches_virtual_input :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 20 * time.Second)
	r, ok := rig_make(t)
	defer rig_destroy(r)
	if !ok do return

	name := unique_name("Fire Test Destination")
	_, err := midi.create_virtual_input(r.d, name, 5)
	testing.expect_value(t, err, core.Error.None)
	id, found := find_port(r.d, name, .Output)
	testing.expectf(t, found, "virtual destination %q not listed as an output", name)
	if !found do return
	out: midi.Port
	out, err = midi.open_output(r.d, id)
	testing.expect_value(t, err, core.Error.None)

	for m in MESSAGES {
		bytes := m.bytes
		testing.expect_value(t, midi.send(r.d, out, bytes[:m.len]), core.Error.None)
	}
	got := receive(r, len(MESSAGES))
	testing.expect_value(t, len(got), len(MESSAGES))
	for e, i in got {
		if i >= len(MESSAGES) do break
		testing.expect_value(t, e.bytes, MESSAGES[i].bytes)
		testing.expect_value(t, e.port, 5)
	}
	// 1000 bytes: CoreMIDI delivers it in packets longer than the nominal 64 words.
	sysex := sysex_message(1000)
	testing.expect_value(t, midi.send(r.d, out, sysex), core.Error.None)
	msg, sysex_ok := receive_sysex(r)
	testing.expect(t, sysex_ok, "no SysEx received")
	testing.expectf(t, mem.compare(msg.data, sysex[1:len(sysex) - 1]) == 0, "SysEx payload mismatch (%d bytes)", len(msg.data))
}

@(test)
bad_arguments :: proc(t: ^testing.T) {
	r, ok := rig_make(t)
	defer rig_destroy(r)
	if !ok do return
	_, err := midi.open_input(r.d, "not-a-number", 0)
	testing.expect_value(t, err, core.Error.Invalid_Argument)
	_, err = midi.open_output(r.d, "123456789")
	testing.expect_value(t, err, core.Error.Invalid_Argument)
	_, err = midi.open_input(r.d, "1", midi.MAX_PORTS)
	testing.expect_value(t, err, core.Error.Invalid_Argument)
	testing.expect_value(t, midi.send(r.d, 999, {0x90, 1, 1}), core.Error.Invalid_Argument)
	src, _ := midi.create_virtual_output(r.d, unique_name("Fire Test Bad"))
	testing.expect_value(t, midi.send(r.d, src, {0xF4}), core.Error.Invalid_Argument) // undefined status
	testing.expect_value(t, midi.send(r.d, src, sysex_message(2000)), core.Error.Invalid_Argument) // too long for one send
}
