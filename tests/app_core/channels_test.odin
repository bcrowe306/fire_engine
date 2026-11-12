package test_app_core

import "core:testing"

import app "app:core"
import "fire:backend"
import "fire:backend/fake"
import fc "fire:core"

// A simulated 8-in/8-out interface with names.
@(private)
interface_8 := []fake.Device_Spec{{
	id = "fake:8x8", name = "Eight", input_channels = 8, output_channels = 8,
	sample_rates = {44_100, 48_000}, buffer_sizes = {128, 256, 512}, default_sample_rate = 48_000, default_buffer_frames = 256,
	input_names = {"Mic 1", "Mic 2", "Line 3", "Line 4", "", "", "S/PDIF L", "S/PDIF R"},
	output_names = {"Main L", "Main R", "Phones L", "Phones R", "", "", "", ""},
}}

// The channels chosen open, as the graph's INPUT and OUTPUT in order; a
// device channel maps to its graph channel; channels the device lacks are
// left out and reported; names come with the device list.
@(test)
chosen_channels_open :: proc(t: ^testing.T) {
	b: app.Bus
	app.bus_init(&b)
	defer app.bus_destroy(&b)
	h: app.Host
	s := app.Host_Settings{fake = true, max_block = 256, fake_devices = interface_8, output_device = "fake:8x8", input_device = "fake:8x8"}
	s.input_channels = {2, 3, 6}
	s.output_channels = {0, 1, 2, 3}
	testing.expect_value(t, app.host_init(&h, s, &b), fc.Error.None)
	defer app.host_destroy(&h)
	testing.expect_value(t, app.host_open(&h), fc.Error.None)
	testing.expect(t, h.graph.settings.input_channels == 3 && h.graph.settings.output_channels == 4)
	testing.expect_value(t, app.host_input_channel(&h, 6), 2)
	testing.expect_value(t, app.host_input_channel(&h, 0), -1)
	testing.expect_value(t, app.host_output_channel(&h, 3), 3)
	testing.expect(t, h.missing_inputs == {} && h.missing_outputs == {})
	infos, _ := backend.driver_enumerate(h.driver, context.temp_allocator)
	testing.expect(t, len(infos) == 1 && infos[0].input_channel_names[6] == "S/PDIF L" && infos[0].output_channel_names[2] == "Phones L")
	app.host_close(&h)

	// Channels it doesn't have: open without them, and say which.
	h.settings.input_channels = {1, 9, 12}
	h.settings.output_channels = {0, 1, 10, 11}
	testing.expect_value(t, app.host_open(&h), fc.Error.None)
	testing.expect(t, h.open_inputs == {1} && h.missing_inputs == {9, 12}, "inputs")
	testing.expect(t, h.open_outputs == {0, 1} && h.missing_outputs == {10, 11}, "outputs")
	testing.expect_value(t, h.graph.settings.input_channels, 1)
	app.host_close(&h)

	// No output it has at all: outputs 1–2.
	h.settings.output_channels = {20, 21}
	testing.expect_value(t, app.host_open(&h), fc.Error.None)
	testing.expect(t, h.open_outputs == {0, 1} && h.missing_outputs == {20, 21})
}
