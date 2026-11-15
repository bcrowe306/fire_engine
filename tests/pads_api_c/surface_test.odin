// The Pads API from C: the example surface (examples/pads_surface), a
// .fsurf library in C, found on a pretend controller's MIDI ports (its
// name), gets the function table by asking its host for "fire.pads" 1 and
// drives Pads through it; its claim table keeps its notes and knobs from
// the engine.
package test_pads_api_c

import "core:log"
import "core:os"
import "core:testing"

import pa "../../apps/pads/api"
import rig "../pads_api"
import "fire:midi"
import mfake "fire:midi/fake"

library :: proc() -> string {
	return #directory + "/../../.build/surface/pads_mini.fsurf"
}

last_sent :: proc(d: ^midi.Driver, status, data1: u8) -> (u8, bool) {
	sent := mfake.sent_to(d, "mini")
	#reverse for m in sent do if len(m) == 3 && m[0] == status && m[1] == data1 do return m[2], true
	return 0, false
}

controller :: proc(r: ^rig.Rig, d: ^midi.Driver, bytes: ..u8) {
	mfake.receive(d, "mini", bytes)
	// The audio thread's claim table: the rig renders by hand (and placing
	// waits for its time): drain the input, as the engine would take it.
	midi.input_drain(&r.core.host.midi_in, proc(user: rawptr, port: u8, b: [3]u8, time_ns: u64) { append((^[dynamic][3]u8)(user), b) }, &engine_got)
	rig.frame(r)
}

engine_got: [dynamic][3]u8

@(test)
a_c_surface_drives_pads_through_the_table :: proc(t: ^testing.T) {
	if !os.exists(library()) {
		log.warnf("skipped: no %s (./scripts/surface.sh)", library())
		return
	}
	d := mfake.create({{id = "mini", name = "Pads Mini MIDI", input = true, output = true}, {id = "keys", name = "Keys", input = true}})
	defer midi.driver_destroy(d)
	r := rig.rig_make(t, "c_surface", d)
	defer rig.rig_destroy(r)
	defer delete(engine_got)
	pa.surfaces_start(&r.api)

	// Loading: a library that isn't there; then the example: found on its port at once (by its name).
	_, res := pa.surface_load(&r.api, "no/such/library.fsurf")
	testing.expect_value(t, res, pa.Result.Io_Error)
	subs := len(r.api.subs)
	k, lr := pa.surface_load(&r.api, library())
	if !testing.expect_value(t, lr, pa.Result.Ok) do return
	testing.expect_value(t, k, 0)
	n, _ := pa.surface_count(&r.api)
	name, _ := pa.surface_name(&r.api, 0)
	path, _ := pa.surface_path(&r.api, 0)
	st, _ := pa.surface_state(&r.api, 0)
	testing.expect(t, n == 1 && name == "Pads Mini" && path == library())
	testing.expect_value(t, st, pa.Surface_State.Active)
	testing.expect_value(t, len(r.api.subs), subs + 1) // its transport subscription

	// CC 14: the tempo through the table (taken from the engine); the
	// surface hears the transport change and sends the tempo back.
	controller(r, d, 0xB0, 14, 40) // (100 BPM: not the 120 a project starts at)
	rig.render(r, 256) // (the clock's tempo is what a block published)
	rig.frame(r)
	ts, _ := pa.transport_state(&r.api)
	testing.expect_value(t, ts.bpm, 100)
	back, ok := last_sent(d, 0xB0, 14)
	testing.expectf(t, ok && back == 40, "the tempo went back out: %v %v", ok, back)

	// CC 15: pad 0's fader.
	controller(r, d, 0xB0, 15, 127)
	ps, _ := pa.pad_state(&r.api, 0)
	testing.expect_value(t, ps.volume, 6)

	// Note 94: play; the play LED lights when the transport says so.
	controller(r, d, 0x90, 94, 127)
	rig.render(r, 256)
	rig.frame(r)
	ts, _ = pa.transport_state(&r.api)
	testing.expect(t, ts.playing)
	led, lit := last_sent(d, 0x90, 94)
	testing.expect(t, lit && led == 127, "the play LED lit")
	controller(r, d, 0x90, 94, 127)
	rig.render(r, 256)
	rig.frame(r)
	led, _ = last_sent(d, 0x90, 94)
	testing.expect_value(t, led, 0)

	// A note plays a pad; none of its messages reached the engine; a key from the other port does.
	controller(r, d, 0x90, 36, 100)
	controller(r, d, 0x80, 36, 0)
	testing.expect_value(t, len(engine_got), 0)
	mfake.receive(d, "keys", {0x90, 60, 100})
	controller(r, d, 0xB0, 1, 2) // (not its: CC 1 plays on)
	testing.expect_value(t, len(engine_got), 2)

	// Stopped: its detection off (the controller is still there); it unsubscribes in its destroy.
	testing.expect_value(t, pa.surface_unload(&r.api, 0), pa.Result.Ok)
	n, _ = pa.surface_count(&r.api)
	testing.expect_value(t, n, 0)
	testing.expect_value(t, len(r.api.subs), subs)
	testing.expect_value(t, pa.surface_unload(&r.api, 0), pa.Result.Not_Found)
	_, res = pa.surface_name(&r.api, 0)
	testing.expect_value(t, res, pa.Result.Not_Found)
	testing.expect_value(t, pa.surface_set_detect(&r.api, 0, 0, true), pa.Result.Ok) // back
	n, _ = pa.surface_count(&r.api)
	testing.expect_value(t, n, 1)
}
