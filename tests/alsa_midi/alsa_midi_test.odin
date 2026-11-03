#+build linux
// ALSA sequencer MIDI tests. No hardware: the driver loops back through
// virtual ports it creates itself. Needs the snd-seq module; skipped without
// it. Port names include the process ID, so concurrent runs don't collide.
package test_alsa_midi

import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:testing"
import "core:time"

import "fire:core"
import "fire:midi"
import amd "fire:midi/alsa"
import "fire:rt"
import snd "fire:sys/alsa"

@(test)
event_layout_matches_headers :: proc(t: ^testing.T) {
	// Values printed by a C program against <alsa/asoundlib.h>.
	testing.expect_value(t, size_of(snd.snd_seq_event_t), 28)
	testing.expect_value(t, offset_of(snd.snd_seq_event_t, time), 4)
	testing.expect_value(t, offset_of(snd.snd_seq_event_t, source), 12)
	testing.expect_value(t, offset_of(snd.snd_seq_event_t, dest), 14)
	testing.expect_value(t, offset_of(snd.snd_seq_event_t, data), 16)
}

Rig :: struct {
	d:   ^midi.Driver,
	in_: midi.Midi_Input,
}

rig_make :: proc(t: ^testing.T) -> (^Rig, bool) {
	r := new(Rig)
	testing.expect_value(t, midi.input_init(&r.in_), mem.Allocator_Error.None)
	err: core.Error
	r.d, err = amd.create()
	if err != .None {
		log.info("ALSA sequencer unavailable (modprobe snd-seq); skipping")
		return r, false
	}
	r.d.input = &r.in_
	return r, true
}

rig_destroy :: proc(r: ^Rig) {
	if r.d != nil do midi.driver_destroy(r.d)
	midi.input_destroy(&r.in_)
	free(r)
}

unique_name :: proc(base: string) -> string {
	return fmt.tprintf("%s %d", base, os.get_pid())
}

find_port :: proc(d: ^midi.Driver, name: string, dir: midi.Port_Direction) -> (string, bool) {
	infos, _ := midi.enumerate(d, context.temp_allocator)
	want := fmt.tprintf("Fire Engine:%s", name)
	for info in infos do if info.id == want && info.direction == dir do return info.id, true
	return "", false
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
	{{0xE0, 0x00, 0x40}, 3},
	{{0xC5, 12, 0}, 2},
	{{0xD1, 99, 0}, 2},
	{{0xF8, 0, 0}, 1},
	{{0x80, 60, 0}, 3},
}

sysex_message :: proc(n: int) -> []u8 {
	m := make([]u8, n + 2, context.temp_allocator)
	m[0], m[n + 1] = 0xF0, 0xF7
	for i in 1 ..= n do m[i] = u8(i * 13) & 0x7F
	return m
}

// Our virtual output → our input port, subscribed to it. Messages are sent
// 50 ms ahead: the kernel queue must hold them until then, and our input
// port's kernel timestamp must say when they arrived.
@(test)
virtual_output_loops_back_with_scheduling :: proc(t: ^testing.T) {
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

	stamp := rt.host_time_ns() + 50_000_000
	for m in MESSAGES {
		bytes := m.bytes
		testing.expect_value(t, midi.send(r.d, src, bytes[:m.len], stamp), core.Error.None)
	}
	sent_at := rt.host_time_ns()
	got := receive(r, len(MESSAGES))
	testing.expect_value(t, len(got), len(MESSAGES))
	for e, i in got {
		if i >= len(MESSAGES) do break
		testing.expectf(t, e.bytes == MESSAGES[i].bytes, "message %d: got %v want %v", i, e.bytes, MESSAGES[i].bytes)
		testing.expect_value(t, e.port, 3)
		late := i64(e.time_ns) - i64(stamp)
		testing.expectf(t, late >= -1_000_000 && late < 5_000_000, "message %d arrived %d ns from its scheduled time", i, late)
	}
	testing.expectf(t, stamp > sent_at, "sending took longer than the 50 ms lead")

	sysex := sysex_message(1000)
	testing.expect_value(t, midi.send(r.d, src, sysex), core.Error.None)
	msg, sysex_ok := receive_sysex(r)
	testing.expect(t, sysex_ok, "no SysEx received")
	testing.expectf(t, mem.compare(msg.data, sysex[1:len(sysex) - 1]) == 0, "SysEx payload mismatch (%d bytes)", len(msg.data))

	midi.close_port(r.d, in_port)
	testing.expect_value(t, midi.send(r.d, src, {0x90, 1, 1}), core.Error.None)
	testing.expect_value(t, len(receive(r, 1, 200 * time.Millisecond)), 0) // unsubscribed
	testing.expect_value(t, midi.input_stats(&r.in_), midi.Input_Stats{})
}

// Direct sends to our own virtual input (a destination).
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
	sysex := sysex_message(3000) // larger than the sequencer's chunk size
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
	_, err := midi.open_input(r.d, "No Such Client:Port", 0)
	testing.expect_value(t, err, core.Error.Invalid_Argument)
	_, err = midi.open_output(r.d, "No Such Client:Port")
	testing.expect_value(t, err, core.Error.Invalid_Argument)
	testing.expect_value(t, midi.send(r.d, 999, {0x90, 1, 1}), core.Error.Invalid_Argument)
	src, _ := midi.create_virtual_output(r.d, unique_name("Fire Test Bad"))
	testing.expect_value(t, midi.send(r.d, src, {0x90, 1}), core.Error.Invalid_Argument)   // truncated
	testing.expect_value(t, midi.send(r.d, src, {0xF0, 1, 2}), core.Error.Invalid_Argument) // unterminated SysEx
}

wait_midi_event :: proc(d: ^midi.Driver, kind: midi.Event_Kind, timeout := 2 * time.Second) -> (midi.Event, bool) {
	start := time.tick_now()
	for time.tick_since(start) < timeout {
		for e in midi.poll_event(d) do if e.kind == kind do return e, true
		time.sleep(5 * time.Millisecond)
	}
	return {}, false
}

// Another client (a second driver instance) adds a port, we open it, and it
// goes away: Ports_Changed, then Port_Lost for our handle.
@(test)
hotplug_reports_ports_and_loss :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 20 * time.Second)
	r, ok := rig_make(t)
	defer rig_destroy(r)
	if !ok do return
	other, err := amd.create()
	testing.expect_value(t, err, core.Error.None)
	if err != .None do return
	defer midi.driver_destroy(other)
	for _ in midi.poll_event(r.d) {}

	name := unique_name("Fire Test Hotplug")
	src: midi.Port
	src, err = midi.create_virtual_output(other, name)
	testing.expect_value(t, err, core.Error.None)
	_, changed := wait_midi_event(r.d, .Ports_Changed)
	testing.expect(t, changed, "no Ports_Changed when another client added a port")

	infos, _ := midi.enumerate(r.d, context.temp_allocator)
	id := ""
	for info in infos do if info.direction == .Input && len(info.id) >= len(name) && info.id[len(info.id) - len(name):] == name do id = info.id
	testing.expectf(t, id != "", "new port %q not listed", name)
	if id == "" do return
	handle: midi.Port
	handle, err = midi.open_input(r.d, id, 1)
	testing.expect_value(t, err, core.Error.None)

	midi.close_port(other, src)
	lost, got := wait_midi_event(r.d, .Port_Lost)
	testing.expect(t, got, "no Port_Lost when the open port went away")
	testing.expect_value(t, lost.port, handle)
}
