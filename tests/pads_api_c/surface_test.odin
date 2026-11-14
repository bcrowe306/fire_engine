// The Pads API from C: the example surface (examples/pads_surface), a
// C library, loaded into Pads (headless), gets the function table by
// asking fire:surface's host for "fire.pads" 1 and drives Pads through it.
package test_pads_api_c

import "core:sync"
import "core:testing"

import pa "../../apps/pads/api"
import rig "../pads_api"
import "fire:midi"
import "fire:surface"

library :: proc() -> string {
	when ODIN_OS == .Darwin {
		return #directory + "/../../.build/surface/pads_mini.dylib"
	} else when ODIN_OS == .Windows {
		return #directory + "/../../.build/surface/pads_mini.dll"
	} else {
		return #directory + "/../../.build/surface/pads_mini.so"
	}
}

// What the surface sent its controller (Pads gives it no MIDI port yet:
// the test stands in for one).
sent: [dynamic][3]u8
sent_lock: sync.Mutex

controller :: proc(r: ^rig.Rig, bytes: ..u8) {
	b: [3]u8
	copy(b[:], bytes)
	midi.input_push_short(surface.manager_midi_input(r.api.manager), 1, 0, b)
	rig.frame(r)
}

last_sent :: proc(status, data1: u8) -> (u8, bool) {
	sync.mutex_guard(&sent_lock)
	#reverse for m in sent do if m[0] == status && m[1] == data1 do return m[2], true
	return 0, false
}

@(test)
a_c_surface_drives_pads_through_the_table :: proc(t: ^testing.T) {
	r := rig.rig_make(t, "c_surface")
	defer rig.rig_destroy(r)
	defer delete(sent)

	// Loading: a library that isn't there, a surface it doesn't have.
	_, res := pa.surface_load(&r.api, "no/such/library.dylib")
	testing.expect_value(t, res, pa.Result.Io_Error)
	_, res = pa.surface_load(&r.api, library(), 5)
	testing.expect_value(t, res, pa.Result.Not_Found)

	subs := len(r.api.subs)
	k, lr := pa.surface_load(&r.api, library())
	if !testing.expect_value(t, lr, pa.Result.Ok) do return
	testing.expect_value(t, k, 0)
	n, _ := pa.surface_count(&r.api)
	name, _ := pa.surface_name(&r.api, 0)
	path, _ := pa.surface_path(&r.api, 0)
	testing.expect(t, n == 1 && name == "Pads Mini" && path == library())
	testing.expect_value(t, len(r.api.subs), subs + 1) // its transport subscription
	r.api.manager.settings.midi_out = proc(user: rawptr, port: int, bytes: []u8) -> bool {
		sync.mutex_guard(&sent_lock)
		m: [3]u8
		copy(m[:], bytes)
		append(&sent, m)
		return true
	}

	// CC 14: the tempo through the table; the surface hears the transport
	// change (its subscription) and sends the tempo back.
	controller(r, 0xB0, 14, 40) // (100 BPM: not the 120 a project starts at)
	rig.render(r, 256) // (the clock's tempo is what a block published)
	rig.frame(r)
	ts, _ := pa.transport_state(&r.api)
	testing.expect_value(t, ts.bpm, 100)
	back, ok := last_sent(0xB0, 14)
	testing.expectf(t, ok && back == 40, "the tempo went back out: %v %v %v", ok, back, sent)

	// CC 15: pad 0's fader.
	controller(r, 0xB0, 15, 127)
	ps, _ := pa.pad_state(&r.api, 0)
	testing.expect_value(t, ps.volume, 6)

	// Note 94: play; the play LED lights when the transport says so.
	controller(r, 0x90, 94, 127)
	rig.render(r, 256)
	rig.frame(r)
	ts, _ = pa.transport_state(&r.api)
	testing.expect(t, ts.playing)
	led, lit := last_sent(0x90, 94)
	testing.expect(t, lit && led == 127, "the play LED lit")
	controller(r, 0x90, 94, 127)
	rig.render(r, 256)
	rig.frame(r)
	led, _ = last_sent(0x90, 94)
	testing.expect_value(t, led, 0)

	// A note plays a pad (its velocity in range: the call succeeds, nothing breaks).
	controller(r, 0x90, 36, 100)
	controller(r, 0x80, 36, 0)

	// Unloading: it unsubscribes in its destroy.
	testing.expect_value(t, pa.surface_unload(&r.api, 0), pa.Result.Ok)
	n, _ = pa.surface_count(&r.api)
	testing.expect_value(t, n, 0)
	testing.expect_value(t, len(r.api.subs), subs)
	testing.expect_value(t, pa.surface_unload(&r.api, 0), pa.Result.Not_Found)
	_, res = pa.surface_name(&r.api, 0)
	testing.expect_value(t, res, pa.Result.Not_Found)
}
