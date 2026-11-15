package test_app_core

import "core:testing"

import app "app:core"
import fc "fire:core"
import "fire:midi"
import mfake "fire:midi/fake"
import grid "fsurf:examples/grid_odin"
import fsurf "fsurf:host"

has :: proc(sent: [][]u8, want: []u8) -> bool {
	for b in sent do if string(b) == string(want) do return true
	return false
}

// The control surfaces on the host's MIDI: a pretend Grid found and
// identified (its identity reply, SysEx), its pads and buttons taken
// before the engine sees them, the rest played, its lights sent; unplugged
// and plugged in again.
@(test)
a_controller_is_found_and_its_messages_are_taken_before_the_engine :: proc(t: ^testing.T) {
	d := mfake.create({{id = "grid", name = "Grid MIDI", input = true, output = true}, {id = "keys", name = "Keys 61", input = true}})
	defer midi.driver_destroy(d)
	b: app.Bus
	app.bus_init(&b)
	defer app.bus_destroy(&b)
	h: app.Host
	testing.expect_value(t, app.host_init(&h, {fake = true, max_block = 256, midi_driver = d}, &b), fc.Error.None)
	defer app.host_destroy(&h)
	testing.expect_value(t, len(h.midi_inputs), 2)
	testing.expect_value(t, app.host_open(&h), fc.Error.None) // (the engine made; rendered by hand below)
	app.host_close(&h)

	s: app.Surfaces
	app.surfaces_init(&s, &h, {})
	defer app.surfaces_destroy(&s)
	_, err := app.surfaces_add_static(&s, &grid.fsurf_entry, "grid (linked)")
	testing.expect_value(t, err, fsurf.Library_Error.None)
	// Its identity request, then its reply (SysEx: routed on this thread).
	testing.expect(t, has(mfake.sent_to(d, "grid"), {0xF0, 0x7E, 0x7F, 0x06, 0x01, 0xF7}))
	mfake.receive(d, "grid", {0xF0, 0x7E, 0x00, 0x06, 0x02, 0x7D, 0x20, 0x01, 0xF7})
	app.surfaces_update(&s)
	devs := fsurf.host_devices(&s.fs)
	if !testing.expect_value(t, len(devs), 1) do return
	testing.expect_value(t, devs[0].state, fsurf.Device_State.Active)
	testing.expect(t, has(mfake.sent_to(d, "grid"), {0xF0, 0x7D, 0x20, 0x01, 0xF7})) // its hello

	// Through the engine's input: its Play button taken, a pad remapped (played), a key played.
	mfake.clear_sent(d)
	mfake.receive(d, "grid", {0xB0, grid.CC_PLAY, 127})
	mfake.receive(d, "grid", {0x99, 36, 100})
	mfake.receive(d, "keys", {0x90, 60, 100})
	// What the engine's input lets through (the audio thread's filter; drained here, untimed).
	got := make([dynamic][3]u8, context.temp_allocator)
	midi.input_drain(&h.midi_in, proc(user: rawptr, port: u8, b: [3]u8, time_ns: u64) { append((^[dynamic][3]u8)(user), b) }, &got)
	testing.expect_value(t, len(got), 2) // the pad and the key; not the button
	if len(got) == 2 {
		testing.expect_value(t, got[0], [3]u8{0x99, 36, 100}) // drum 36: the bottom-left pad's own note
		testing.expect_value(t, got[1], [3]u8{0x90, 60, 100})
	}
	app.surfaces_update(&s) // the surface hears its pad: lit
	testing.expect(t, has(mfake.sent_to(d, "grid"), {0x99, 36, 127}))

	// Unplugged: gone (its surface kept); back: identified and started again.
	mfake.unplug(d, "grid")
	app.surfaces_update(&s)
	testing.expect_value(t, devs[0].state, fsurf.Device_State.Gone)
	mfake.clear_sent(d)
	mfake.plug(d, {id = "grid", name = "Grid MIDI", input = true, output = true})
	app.surfaces_update(&s)
	testing.expect(t, has(mfake.sent_to(d, "grid"), {0xF0, 0x7E, 0x7F, 0x06, 0x01, 0xF7}))
	mfake.receive(d, "grid", {0xF0, 0x7E, 0x00, 0x06, 0x02, 0x7D, 0x20, 0x01, 0xF7})
	app.surfaces_update(&s)
	testing.expect_value(t, fsurf.host_devices(&s.fs)[0].state, fsurf.Device_State.Active)
	testing.expect(t, has(mfake.sent_to(d, "grid"), {0xF0, 0x7D, 0x20, 0x01, 0xF7}))
}
