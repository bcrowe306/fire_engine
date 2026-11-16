package test_app_core

import "core:strings"
import "core:testing"
import "core:time"

import app "app:core"
import fc "fire:core"
import "fire:midi"
import mfake "fire:midi/fake"
import screen "fsurf:examples/screen_odin"
import fsurf "fsurf:host"

// Runs the surfaces until `done` or `ms` pass (the devices' threads work meanwhile).
until :: proc(s: ^app.Surfaces, ms: int, done: proc(data: rawptr) -> bool, data: rawptr) -> bool {
	start := time.tick_now()
	for time.duration_milliseconds(time.tick_since(start)) < f64(ms) {
		app.surfaces_update(s)
		if done(data) do return true
		time.sleep(5 * time.Millisecond)
	}
	return false
}

logged :: proc(s: ^app.Surfaces, text: string) -> bool {
	for e in fsurf.log_entries(&s.fs) do if strings.contains(e.message, text) do return true
	return false
}

// A surface's USB display (the screen example's: 1209:0001) opened through
// the app's driver (pretend devices), written on its own thread; not there
// when the surface starts, found when it's plugged in and sent whole.
@(test)
a_surfaces_display_is_opened_written_and_found_when_plugged_in :: proc(t: ^testing.T) {
	d := mfake.create({{id = "screen", name = "Screen MIDI", input = true, output = true}})
	defer midi.driver_destroy(d)
	usb := app.devices_fake_create()
	defer app.devices_fake_destroy(usb)
	b: app.Bus
	app.bus_init(&b)
	defer app.bus_destroy(&b)
	h: app.Host
	testing.expect_value(t, app.host_init(&h, {fake = true, max_block = 256, midi_driver = d}, &b), fc.Error.None)
	defer app.host_destroy(&h)

	// Started with its display unplugged: noted, and tried again.
	s: app.Surfaces
	app.surfaces_init(&s, &h, {devices = usb})
	_, err := app.surfaces_add_static(&s, &screen.fsurf_entry, "screen (linked)")
	testing.expect_value(t, err, fsurf.Library_Error.None)
	app.surfaces_update(&s)
	devs := fsurf.host_devices(&s.fs)
	if !testing.expect_value(t, len(devs), 1) do return
	testing.expect_value(t, devs[0].state, fsurf.Device_State.Active)
	testing.expect(t, !app.devices_fake_open(usb, "display"))

	// Plugged in: opened by its thread (within a second or so), told to the
	// surface, which sends its frame whole (256 x 64 RGB565).
	app.devices_fake_plug(usb, "display", 0x1209, 0x0001)
	written :: proc(data: rawptr) -> bool {
		bytes, _, _, _ := app.devices_fake_written((^app.Device_Driver)(data), "display")
		return bytes >= 256 * 64 * 2
	}
	testing.expect(t, until(&s, 3000, written, usb), "a frame written")
	testing.expect(t, app.devices_fake_open(usb, "display"))
	testing.expect(t, logged(&s, "its device is back"))
	bytes, writes, last, _ := app.devices_fake_written(usb, "display")
	testing.expect_value(t, bytes, 256 * 64 * 2)
	testing.expect_value(t, writes, 1)
	testing.expect_value(t, len(last), 256 * 64 * 2)

	// What it sends reaches the surface's thread (the screen ignores it).
	app.devices_fake_send(usb, "display", {1, 2, 3})
	for _ in 0 ..< 10 {
		app.surfaces_update(&s)
		time.sleep(5 * time.Millisecond)
	}

	// Stopped: the device closed, its thread gone.
	app.surfaces_destroy(&s)
	testing.expect(t, !app.devices_fake_open(usb, "display"))
}
