package test_surface

import "core:dynlib"
import "core:testing"

import "fire:core"
import "fire:graph"
import "fire:midi"
import "fire:surface"
import kit "fire:testkit"
import "fire:transport"

SR :: 48_000.0

script :: proc() -> string {
	when ODIN_OS == .Darwin {
		return #directory + "/../../.build/surface/mini.dylib"
	} else when ODIN_OS == .Windows {
		return #directory + "/../../.build/surface/mini.dll"
	} else {
		return #directory + "/../../.build/surface/mini.so"
	}
}

Layout :: struct { name: string, value: uintptr }

odin_layouts := [?]Layout {
	{"fire_transport_state", size_of(surface.Transport_State)},
	{"fire_transport_state.position", offset_of(surface.Transport_State, position)},
	{"fire_transport_state.bar", offset_of(surface.Transport_State, bar)},
	{"fire_transport_state.denominator", offset_of(surface.Transport_State, denominator)},
	{"fire_control_info", size_of(surface.Control_Info)},
	{"fire_control_info.name", offset_of(surface.Control_Info, name)},
	{"fire_control_info.default_value", offset_of(surface.Control_Info, default)},
	{"fire_control_info.steps", offset_of(surface.Control_Info, steps)},
	{"fire_surface_host", size_of(surface.Host)},
	{"fire_surface_host.send_midi", offset_of(surface.Host, send_midi)},
	{"fire_surface_host.get_transport", offset_of(surface.Host, get_transport)},
	{"fire_surface_host.control_touch", offset_of(surface.Host, control_touch)},
	{"fire_surface_host.log", offset_of(surface.Host, log)},
	{"fire_surface", size_of(surface.Surface)},
	{"fire_surface.on_idle", offset_of(surface.Surface, on_idle)},
	{"fire_surface_descriptor", size_of(surface.Descriptor)},
	{"fire_surface_descriptor.input_hints", offset_of(surface.Descriptor, input_hints)},
	{"fire_surface_descriptor.create", offset_of(surface.Descriptor, create)},
}

// fire_surface.h, as the C compiler lays it out, is fire:surface's ABI.
@(test)
header_matches_the_odin_abi :: proc(t: ^testing.T) {
	lib, ok := dynlib.load_library(script())
	if !testing.expectf(t, ok, "load %s", script()) do return
	defer dynlib.unload_library(lib)
	layout := cast(proc "c" (i: i32, name: ^cstring, is_offset: ^i32, value: ^u64) -> i32)dynlib.symbol_address(lib, "fire_surface_layout")
	if !testing.expect(t, layout != nil) do return
	checked := 0
	for i: i32 = 0; ; i += 1 {
		name: cstring
		is_offset: i32
		value: u64
		if layout(i, &name, &is_offset, &value) == 0 do break
		found := false
		for l in odin_layouts do if l.name == string(name) {
			testing.expectf(t, u64(l.value) == value, "%s: C %d, Odin %d", name, value, l.value)
			found = true
		}
		testing.expectf(t, found, "%s: not in the Odin table", name)
		checked += 1
	}
	testing.expect_value(t, checked, len(odin_layouts))
}

// What the app sees of the surfaces.
Seen :: struct {
	sent:    [dynamic][]u8, // MIDI to the controller
	ports:   [dynamic]int,
	sets:    [dynamic]struct{ id: u32, value: f64 },
	touches: [dynamic]struct{ id: u32, touched: bool },
	logs:    [dynamic]string,
}

Rig :: struct {
	clock:   ^transport.Clock,
	song:    core.Timeline_Id,
	g:       ^graph.Graph,
	probe:   ^kit.Probe,
	filter:  graph.Node_Id,
	m:       ^surface.Manager,
	seen:    Seen,
}

rig_make :: proc(t: ^testing.T) -> ^Rig {
	r := new(Rig)
	r.clock, _ = transport.create(transport.default_settings(SR))
	r.song, _ = transport.add_timeline(r.clock)
	settings := graph.default_settings(SR, 256)
	settings.input_channels, settings.output_channels, settings.workers = 0, 0, 0
	r.g, _ = graph.create(settings)
	node: core.Node
	node, r.probe = kit.probe_create(256)
	r.filter, _ = graph.add_node(r.g, node, 0, 0)
	graph.commit(r.g)
	r.m, _ = surface.manager_create({
		clock = r.clock, timeline = r.song, graph = r.g, user = r,
		midi_out = proc(user: rawptr, port: int, bytes: []u8) -> bool {
			r := (^Rig)(user)
			append(&r.seen.sent, clone(bytes))
			append(&r.seen.ports, port)
			return true
		},
		on_set = proc(user: rawptr, id: u32, value: f64) { append(&(^Rig)(user).seen.sets, struct{ id: u32, value: f64 }{id, value}) },
		on_touch = proc(user: rawptr, id: u32, touched: bool) { append(&(^Rig)(user).seen.touches, struct{ id: u32, touched: bool }{id, touched}) },
		log = proc(user: rawptr, level: i32, message: string) { append(&(^Rig)(user).seen.logs, clone_string(message)) },
	})
	surface.node_publish(r.m, "filter", r.filter)
	return r
}

clone :: proc(b: []u8) -> []u8 {
	c := make([]u8, len(b))
	copy(c, b)
	return c
}

clone_string :: proc(s: string) -> string { return string(clone(transmute([]u8)s)) }

rig_destroy :: proc(r: ^Rig) {
	surface.manager_destroy(r.m)
	graph.destroy(r.g)
	transport.destroy(r.clock)
	for b in r.seen.sent do delete(b)
	for s in r.seen.logs do delete(s)
	delete(r.seen.sent)
	delete(r.seen.ports)
	delete(r.seen.sets)
	delete(r.seen.touches)
	delete(r.seen.logs)
	free(r)
}

// One block of audio: the clock applies commands, the graph applies parameters.
rig_block :: proc(r: ^Rig) {
	ctx := core.Process_Context{frames = 256}
	transport.process(r.clock, &ctx, proc(user: rawptr, seg: ^core.Process_Context) {
		graph.process((^graph.Graph)(user), seg)
	}, r.g)
}

// The controller sending a message on port index `port`.
controller :: proc(r: ^Rig, port: u8, bytes: ..u8) {
	in_ := surface.manager_midi_input(r.m)
	if len(bytes) <= 3 {
		b: [3]u8
		copy(b[:], bytes)
		midi.input_push_short(in_, 1, port, b)
	} else {
		midi.input_push_bytes(in_, 1, port, bytes)
	}
}

last_sent :: proc(r: ^Rig) -> []u8 {
	return r.seen.sent[len(r.seen.sent) - 1] if len(r.seen.sent) > 0 else nil
}

@(test)
a_surface_drives_the_app_and_follows_it :: proc(t: ^testing.T) {
	r := rig_make(t)
	defer rig_destroy(r)
	lib, err := surface.library_open(r.m, script())
	if !testing.expect_value(t, err, core.Error.None) do return
	if !testing.expect_value(t, len(lib.surfaces), 1) do return
	d := lib.surfaces[0]
	testing.expect(t, string(d.name) == "Fire Mini" && surface.port_matches(d, "Fire Mini MIDI 1", true) && !surface.port_matches(d, "Other", true))
	s, serr := surface.surface_start(r.m, lib, 0, {midi_in = 3, midi_out = 7})
	if !testing.expect_value(t, serr, core.Error.None) do return
	surface.library_close(r.m, lib) // the surface keeps it loaded
	testing.expect(t, len(r.seen.logs) == 1 && r.seen.logs[0] == "Fire Mini started")
	surface.control_publish(r.m, {id = 1, name = "Volume", kind = .Continuous, min = 0, max = 1, default = 0.8}, 0.8)

	// The first update tells it the transport: the play LED goes off.
	rig_block(r)
	surface.manager_update(r.m)
	testing.expect(t, len(last_sent(r)) == 3 && last_sent(r)[0] == 0x90 && last_sent(r)[1] == 94 && last_sent(r)[2] == 0)
	testing.expect_value(t, r.seen.ports[len(r.seen.ports) - 1], 7)

	// The fader moves a control, with a gesture; its motor isn't told back.
	sent := len(r.seen.sent)
	controller(r, 3, 0xB0, 7, 64)
	surface.manager_update(r.m)
	if testing.expect_value(t, len(r.seen.sets), 1) do testing.expect(t, r.seen.sets[0].id == 1 && abs(r.seen.sets[0].value - 64.0 / 127) < 1e-12)
	testing.expect(t, len(r.seen.touches) == 1 && r.seen.touches[0].touched)
	testing.expect_value(t, len(r.seen.sent), sent)
	// The app moves it: the motor fader follows.
	surface.control_changed(r.m, 1, 0.25)
	surface.manager_update(r.m)
	testing.expect(t, len(last_sent(r)) == 3 && last_sent(r)[0] == 0xB0 && last_sent(r)[1] == 7 && last_sent(r)[2] == 32)

	// Play: the transport starts, the LED lights.
	controller(r, 3, 0x90, 94, 127)
	surface.manager_update(r.m)
	rig_block(r)
	rig_block(r) // its status is published at the end of a block
	surface.manager_update(r.m)
	_, playing, _ := transport.timeline_status(r.clock, r.song)
	testing.expect(t, playing)
	testing.expect(t, last_sent(r)[0] == 0x90 && last_sent(r)[1] == 94 && last_sent(r)[2] == 127)

	// A knob sets a parameter of the node it found by name.
	controller(r, 3, 0xB0, 16, 50)
	surface.manager_update(r.m)
	rig_block(r)
	found := false
	for e in kit.probe_events(r.probe) do if v, ok := e.payload.(core.Param_Value); ok && v.param == 1 && v.value == 20 + 50 * 100 do found = true
	testing.expect(t, found, "the filter got its cutoff")

	// SysEx: an identity request gets its reply.
	controller(r, 3, 0xF0, 0x7E, 0x7F, 0x06, 0x01, 0xF7)
	surface.manager_update(r.m)
	reply := last_sent(r)
	testing.expect(t, len(reply) == 11 && reply[0] == 0xF0 && reply[4] == 0x02 && reply[10] == 0xF7)

	// Another port's MIDI isn't for it.
	sets := len(r.seen.sets)
	controller(r, 4, 0xB0, 7, 1)
	surface.manager_update(r.m)
	testing.expect_value(t, len(r.seen.sets), sets)

	// Stopping it ends the gesture it was making.
	surface.surface_stop(r.m, s)
	t0 := r.seen.touches[len(r.seen.touches) - 1]
	testing.expect(t, t0.id == 1 && !t0.touched)
}
