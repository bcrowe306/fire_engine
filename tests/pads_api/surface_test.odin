// Control surfaces through the API: libraries, the surfaces found on the
// MIDI ports (a pretend controller), assigning by hand, detection, the
// monitor, controls by name; and fsurf.daw over the API, through the kit's
// keyboard example (extern/fire-surface/examples/keys_odin), linked in.
package test_pads_api

import "core:strings"
import "core:testing"

import pa "../../apps/pads/api"
import app "app:core"
import "fire:midi"
import mfake "fire:midi/fake"
import keys "fsurf:examples/keys_odin"

// The surfaces started, the keyboard example linked in, its controller
// plugged in.
surfaces_rig :: proc(t: ^testing.T, name: string) -> (^Rig, ^midi.Driver) {
	d := mfake.create({{id = "keys", name = "Keys 25 MIDI", input = true, output = true}, {id = "other", name = "Other", input = true, output = true}})
	r := rig_make(t, name, d)
	pa.surfaces_start(&r.api)
	app.surfaces_add_static(&r.api.surfaces, &keys.fsurf_entry, "keys (linked)")
	frame(r)
	return r, d
}

// What the input lets through to the engine (the claim table), and a frame.
pass :: proc(r: ^Rig) -> int {
	n := 0
	midi.input_drain(&r.core.host.midi_in, proc(user: rawptr, port: u8, b: [3]u8, time_ns: u64) { (^int)(user)^ += 1 }, &n)
	frame(r)
	return n
}

sent_has :: proc(d: ^midi.Driver, port: string, want: []u8) -> bool {
	for m in mfake.sent_to(d, port) do if string(m) == string(want) do return true
	return false
}

@(test)
surfaces_are_found_listed_and_played_by_name :: proc(t: ^testing.T) {
	r, d := surfaces_rig(t, "surfaces")
	defer midi.driver_destroy(d)
	defer rig_destroy(r)

	// Its library, and the surface it offers.
	nl, _ := pa.surface_library_count(&r.api)
	testing.expect(t, nl >= 1)
	lib := nl - 1
	p, _ := pa.surface_library_path(&r.api, lib)
	why, _ := pa.surface_library_error(&r.api, lib)
	no, _ := pa.surface_offered_count(&r.api, lib)
	on, _ := pa.surface_offered_name(&r.api, lib, 0)
	oid, _ := pa.surface_offered_id(&r.api, lib, 0)
	testing.expect(t, p == "keys (linked)" && why == "" && no == 1 && on == "Keys 25 (kit example)" && oid == "org.fsurf.example.keys")
	_, res := pa.surface_offered_name(&r.api, lib, 1)
	testing.expect_value(t, res, pa.Result.Not_Found)

	// Found on its port (by name), running.
	n, _ := pa.surface_count(&r.api)
	if !testing.expect_value(t, n, 1) do return
	st, _ := pa.surface_state(&r.api, 0)
	ports, _ := pa.surface_ports(&r.api, 0)
	testing.expect_value(t, st, pa.Surface_State.Active)
	testing.expect_value(t, ports, "Keys 25 MIDI")

	// Its controls, by name: Play plays (taken from the engine).
	nc, _ := pa.surface_control_count(&r.api, 0)
	testing.expect(t, nc > 20)
	found := false
	for k in 0 ..< nc do if name, _ := pa.surface_control_name(&r.api, 0, k); name == "Play" do found = true
	testing.expect(t, found)
	pa.surface_monitor(&r.api, true)
	testing.expect_value(t, pa.surface_press(&r.api, 0, "Play"), pa.Result.Ok)
	pa.surface_release(&r.api, 0, "Play")
	testing.expect_value(t, pass(r), 0)
	render(r, 256)
	frame(r)
	ts, _ := pa.transport_state(&r.api)
	testing.expect(t, ts.playing)
	testing.expect_value(t, pa.surface_press(&r.api, 0, "Nothing"), pa.Result.Not_Found)

	// The monitor named it.
	mn, _ := pa.surface_monitor_count(&r.api)
	named := false
	for i in 0 ..< mn do if line, _ := pa.surface_monitor_line(&r.api, i); strings.contains(line, "Play (Transport)") do named = true
	testing.expect(t, named)
	pa.surface_monitor_clear(&r.api)
	mn, _ = pa.surface_monitor_count(&r.api)
	testing.expect_value(t, mn, 0)

	// Detection off: forgotten; on: found again.
	testing.expect_value(t, pa.surface_set_detect(&r.api, lib, 0, false), pa.Result.Ok)
	det, _ := pa.surface_detect(&r.api, lib, 0)
	n, _ = pa.surface_count(&r.api)
	testing.expect(t, !det && n == 0)
	pa.surface_set_detect(&r.api, lib, 0, true)
	n, _ = pa.surface_count(&r.api)
	testing.expect_value(t, n, 1)

	// Assigned by hand to the other port; stopped again.
	k, ar := pa.surface_assign(&r.api, lib, 0, "other", "other")
	testing.expect_value(t, ar, pa.Result.Ok)
	n, _ = pa.surface_count(&r.api)
	testing.expect_value(t, n, 2)
	ports, _ = pa.surface_ports(&r.api, k)
	testing.expect_value(t, ports, "Other")
	testing.expect_value(t, pa.surface_unload(&r.api, k), pa.Result.Ok)
	_, ar = pa.surface_assign(&r.api, lib, 0, "nothing", "")
	testing.expect_value(t, ar, pa.Result.Not_Found)

	// Unloading its library: no surfaces.
	testing.expect_value(t, pa.surface_library_unload(&r.api, lib), pa.Result.Ok)
	n, _ = pa.surface_count(&r.api)
	testing.expect_value(t, n, 0)
}

// fsurf.daw over the API: the keyboard example's faders, mute buttons,
// knobs, transport and undo drive Pads, and follow it.
@(test)
fsurf_daw_drives_pads :: proc(t: ^testing.T) {
	r, d := surfaces_rig(t, "fsurf_daw")
	defer midi.driver_destroy(d)
	defer rig_destroy(r)
	testing.expect_value(t, pa.pad_set_kind(&r.api, 0, .Synth), pa.Result.Ok) // (a device with parameters)
	frame(r)

	// The first fader: pad 0's volume, picked up at its 0 dB, then down.
	ps, _ := pa.pad_state(&r.api, 0)
	at := f64(0.8674) // (0 dB on the fader's taper)
	if ps.volume != 0 do at = 0
	pa.surface_move(&r.api, 0, "Fader", at)
	pass(r)
	pa.surface_move(&r.api, 0, "Fader", 0.5)
	pass(r)
	ps, _ = pa.pad_state(&r.api, 0)
	testing.expectf(t, abs(ps.volume - (-18.3)) < 0.5, "the fader: %v dB", ps.volume) // (0.5: CC 64 of 127)

	// Mute: pad 0; and from Pads, its light.
	pa.surface_press(&r.api, 0, "Mute")
	pa.surface_release(&r.api, 0, "Mute")
	pass(r)
	ps, _ = pa.pad_state(&r.api, 0)
	testing.expect(t, ps.mute)
	frame(r)
	testing.expectf(t, sent_has(d, "keys", {0xB0, keys.CC_MUTE, 127}), "lit: %v", mfake.sent_to(d, "keys"))
	mfake.clear_sent(d)
	pa.pad_set_mute(&r.api, 0, false)
	frame(r)
	frame(r)
	testing.expect(t, sent_has(d, "keys", {0xB0, keys.CC_MUTE, 0}))

	// A knob: the synth's first parameter moves.
	ref, _ := pa.param_at(&r.api, {track = .Pad, index = 0, device = .Sound}, 0)
	before, _ := pa.param_get(&r.api, ref)
	pa.surface_turn(&r.api, 0, "Knob", 20)
	pass(r)
	after, _ := pa.param_get(&r.api, ref)
	testing.expectf(t, after != before, "the parameter moved: %v -> %v", before, after)

	// Undo: the knob's change undone.
	pa.surface_press(&r.api, 0, "Undo")
	pa.surface_release(&r.api, 0, "Undo")
	pass(r)
	back, _ := pa.param_get(&r.api, ref)
	testing.expectf(t, back != after, "undone: %v", back)
}
