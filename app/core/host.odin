package app

import "base:intrinsics"
import "core:time"

import "fire:backend"
import "fire:backend/fake"
import "fire:clip"
import fc "fire:core"
import "fire:graph"
import "fire:midi"
import "fire:record"
import "fire:session"
import "fire:stream"
import "fire:stretch"
import "fire:transport"

// What the host opens. Zero values are the system's defaults.
Host_Settings :: struct {
	output_device: string, // a `backend.Device_Info.id`; "" = the default output
	input_device:  string, // "" = the default input
	sample_rate:   f64,    // 0 = the device's
	buffer_frames: int,    // 0 = the device's
	outputs:       int,    // output channels; 0 = 2
	inputs:        int,    // input channels (0 = none)
	max_block:     int,    // largest block the graph processes; 0 = 1024
	fake:          bool,   // the simulated driver (tests, headless runs)
	ram_bytes:     int,    // audio files up to this decoded size are held in memory (samplers need it); 0 = the streamer's default
	midi:          bool,   // open the system's MIDI: every input port into the graph (see `host_midi_*`)
	midi_output:   string, // a MIDI output port id the graph's MIDI goes to; "" = none
	// At a new sample rate, start from an empty graph and clock instead of
	// carrying the old ones over (for apps that rebuild the engine from
	// their own model on `Host_Engine_Changed`).
	rebuild_on_rate_change: bool,
}

// The engine an app plays through: a driver and device, the clock, the
// graph, a streamer for audio files, a disk writer for recordings, and the
// node registry sessions load with. The graph and clock are made at the
// device's sample rate; if a later device runs at another, `host_open`
// moves everything to a new graph and clock at that rate (through a
// session saved in memory). Control thread.
Host :: struct {
	settings:  Host_Settings,
	bus:       ^Bus,
	driver:    ^backend.Driver,
	fake:      ^fake.Fake, // when `settings.fake`
	device:    backend.Device,
	format:    backend.Device_Format, // what the device opened at
	opened:    bool,
	running:   bool,
	lost:      bool, // the device went away; `host_update` tries to reopen it
	retry_at:  time.Tick,
	clock:     ^transport.Clock,
	graph:     ^graph.Graph,
	streamer:  ^stream.Streamer,
	disk:      ^record.Disk_Writer,
	env:       session.Environment,
	registry:  fc.Node_Registry,
	xruns:     int,
	// MIDI: what arrives (from the ports, or `host_midi_inject`) reaches the
	// graph's INPUT as `core.Midi_Raw`; `core.Midi_Raw` the graph sends to
	// OUTPUT goes to the output port.
	midi_driver: ^midi.Driver,
	midi_in:     midi.Midi_Input,
	midi_out:    midi.Midi_Output,
	midi_port:   midi.Port, // the output port, when `midi_out_open`
	midi_out_open: bool,
	midi_inputs: [dynamic]midi.Port, // open input ports
	midi_sent:   u64, // atomic: MIDI messages the graph has sent out (sent to the port if one is open)
	midi_received: u64, // atomic: MIDI messages into the graph
	in_events:   []fc.Event, // audio thread: MIDI in, per block
	out_events:  []fc.Event, // audio thread: the graph's events out, per block
}

// Announced on the bus when the device changes.
Host_Event :: struct {
	kind:  Host_Event_Kind,
	error: fc.Error,
}

// What happened to the device (see `Host_Event`).
Host_Event_Kind :: enum u8 {
	Opened,   // the device is open and running
	Lost,     // it went away (unplugged); the host keeps trying to reopen it
	Restored, // it came back and runs again
	Failed,   // it could not be opened (`error`)
	Xruns,    // dropouts since the last update
	Devices,  // devices were added or removed
}

// How often a lost device is retried.
RETRY_INTERVAL :: 500 * time.Millisecond

// Makes the driver, streamer, disk writer and registry. Opens nothing yet.
host_init :: proc(h: ^Host, settings: Host_Settings, bus: ^Bus) -> fc.Error {
	h.settings, h.bus = settings, bus
	if h.settings.outputs <= 0 do h.settings.outputs = 2
	if h.settings.max_block <= 0 do h.settings.max_block = 1024
	if settings.fake {
		cfg := fake.default_config()
		cfg.devices = nil
		h.fake = fake.create(cfg)
		h.driver = fake.driver(h.fake)
	} else {
		h.driver = platform_driver()
	}
	if h.driver == nil do return .Device_Error
	backend.device_init(&h.device, h.driver)
	ss := stream.default_settings()
	if settings.ram_bytes > 0 do ss.ram_bytes = settings.ram_bytes
	h.streamer = stream.create(ss) or_return
	h.disk = record.disk_writer_create({manual = settings.fake}) or_return
	h.env = {players = {streamer = h.streamer, stretcher = &stretch.signalsmith}, disk = h.disk}
	fc.registry_init(&h.registry)
	if midi.input_init(&h.midi_in) != nil do return .Out_Of_Memory
	h.in_events = make([]fc.Event, 1024)
	h.out_events = make([]fc.Event, 2048)
	if settings.midi && !settings.fake do open_midi(h)
	return session.register_builtin(&h.registry, &h.env)
}

// Opens the platform's MIDI, every input port, and the output port in the
// settings. A machine with no MIDI is not an error: there is just none.
@(private)
open_midi :: proc(h: ^Host) {
	d, err := platform_midi()
	if err != .None || d == nil do return
	h.midi_driver = d
	d.input = &h.midi_in
	h.midi_inputs = make([dynamic]midi.Port)
	ports, _ := midi.enumerate(d, context.temp_allocator)
	for p in ports {
		if p.direction == .Input {
			if port, e := midi.open_input(d, p.id, u8(len(h.midi_inputs))); e == .None do append(&h.midi_inputs, port)
		} else if p.direction == .Output && h.settings.midi_output != "" && p.id == h.settings.midi_output && !h.midi_out_open {
			if midi.output_init(&h.midi_out, d) == nil {
				if port, e := midi.open_output(d, p.id); e == .None {
					h.midi_port, h.midi_out_open = port, true
					midi.output_start(&h.midi_out)
				} else {
					midi.output_destroy(&h.midi_out)
				}
			}
		}
	}
}

// The MIDI ports the system has (inputs and outputs), or none. Control thread.
host_midi_ports :: proc(h: ^Host, allocator := context.allocator) -> []midi.Port_Info {
	if h.midi_driver == nil do return nil
	ports, _ := midi.enumerate(h.midi_driver, allocator)
	return ports
}

// MIDI messages the graph has sent and received so far (for activity
// lights). Any thread.
host_midi_counts :: proc "contextless" (h: ^Host) -> (sent, received: u64) {
	return intrinsics.atomic_load(&h.midi_sent), intrinsics.atomic_load(&h.midi_received)
}

// Plays a MIDI message into the graph as if it came from a port (port index
// `port`): for tests, scripts and on-screen keyboards. Any thread but the
// audio thread.
host_midi_inject :: proc(h: ^Host, bytes: [3]u8, port: u8 = 0) {
	midi.input_push_short(&h.midi_in, 0, port, bytes)
}

// Stops and closes everything, then frees it.
host_destroy :: proc(h: ^Host) {
	host_close(h)
	if h.graph != nil do graph.destroy(h.graph)
	if h.clock != nil do transport.destroy(h.clock)
	if h.disk != nil do record.disk_writer_destroy(h.disk)
	if h.streamer != nil do stream.destroy(h.streamer)
	fc.registry_destroy(&h.registry)
	if h.midi_driver != nil {
		if h.midi_out_open {
			midi.output_stop(&h.midi_out)
			midi.close_port(h.midi_driver, h.midi_port)
			midi.output_destroy(&h.midi_out)
		}
		for p in h.midi_inputs do midi.close_port(h.midi_driver, p)
		delete(h.midi_inputs)
		midi.driver_destroy(h.midi_driver)
	}
	midi.input_destroy(&h.midi_in)
	delete(h.in_events)
	delete(h.out_events)
	if h.driver != nil {
		backend.device_destroy(&h.device)
		backend.driver_destroy(h.driver)
	}
	h^ = {}
}

// Opens and starts the device in `h.settings` (change them first to switch
// devices). Makes the clock and graph at its rate, or moves them to it.
// Announces `.Opened` or `.Failed`.
host_open :: proc(h: ^Host) -> fc.Error {
	host_close(h)
	err := open_device(h)
	if err != .None {
		publish(h.bus, Host_Event{.Failed, err})
		return err
	}
	publish(h.bus, Host_Event{.Opened, .None})
	return .None
}

// Stops and closes the device (the graph and clock stay).
host_close :: proc(h: ^Host) {
	if h.running do backend.device_stop(&h.device)
	if h.opened do backend.device_close(&h.device)
	h.running, h.opened = false, false
}

// Call once per frame on the control thread: handles device events
// (losing a device and getting it back, dropouts, devices coming and
// going) and frees what the audio thread has finished with.
host_update :: proc(h: ^Host) {
	if h.graph != nil do graph.collect(h.graph)
	if h.clock != nil do transport.collect(h.clock)
	if h.opened {
		for e in backend.device_poll_event(&h.device) {
			#partial switch e.kind {
			case .Device_Lost, .Format_Changed, .Error:
				host_close(h)
				h.lost = true
				h.retry_at = time.tick_now()
				publish(h.bus, Host_Event{.Lost, e.error})
			case .Xrun:
				h.xruns += e.count
				publish(h.bus, Host_Event{.Xruns, .None})
			case .Devices_Changed, .Default_Device_Changed:
				publish(h.bus, Host_Event{.Devices, .None})
			}
		}
	}
	if h.lost && time.tick_diff(h.retry_at, time.tick_now()) >= 0 {
		if open_device(h) == .None {
			h.lost = false
			publish(h.bus, Host_Event{.Restored, .None})
		} else {
			h.retry_at = time.tick_add(time.tick_now(), RETRY_INTERVAL)
		}
	}
}

// The devices the driver offers, allocated with `allocator` (free with
// `backend.device_infos_destroy`).
host_devices :: proc(h: ^Host, allocator := context.allocator) -> ([]backend.Device_Info, fc.Error) {
	return backend.driver_enumerate(h.driver, allocator)
}

// Renders `frames` frames through the clock and graph without the device
// (which must be closed): for exporting. `out` holds one slice per output
// channel, each at least `frames` long.
host_render :: proc(h: ^Host, out: [][]f32, frames: int, inputs: [][]f32 = nil) {
	for done := 0; done < frames; {
		n := min(h.settings.max_block, frames - done)
		views := make([][]f32, len(out), context.temp_allocator)
		for o, c in out do views[c] = o[done:][:n]
		ins: [][]f32
		if inputs != nil {
			ins = make([][]f32, len(inputs), context.temp_allocator)
			for x, c in inputs do ins[c] = x[done:][:n]
		}
		run_block(h, ins, views, n, 0)
		if h.disk != nil && h.settings.fake do record.disk_writer_service(h.disk)
		done += n
	}
}

// [rt] One block through the clock and graph, with MIDI in and out.
@(private)
run_block :: proc(h: ^Host, inputs, outputs: [][]f32, frames: int, block_ns: u64) {
	rate := h.graph.settings.sample_rate
	in_w := fc.Event_Writer{buffer = h.in_events}
	midi.input_process(&h.midi_in, block_ns, frames, rate, &in_w)
	out_w := fc.Event_Writer{buffer = h.out_events}
	ctx := fc.Process_Context{inputs = inputs, outputs = outputs, frames = frames, events_in = fc.event_writer_events(&in_w), events_out = &out_w}
	transport.process(h.clock, &ctx, render_segment, h.graph, block_ns)
	if n := in_w.count; n > 0 do intrinsics.atomic_add(&h.midi_received, u64(n))
	sent: u64 = 0
	for e in fc.event_writer_events(&out_w) do if _, ok := e.payload.(fc.Midi_Raw); ok do sent += 1
	if sent > 0 do intrinsics.atomic_add(&h.midi_sent, sent)
	if h.midi_out_open {
		ports := [1]midi.Port{h.midi_port}
		midi.output_push_events(&h.midi_out, fc.event_writer_events(&out_w), ports[:], block_ns, rate)
	}
}

@(private)
render_segment :: proc(user: rawptr, seg: ^fc.Process_Context) {
	graph.process((^graph.Graph)(user), seg)
}

@(private)
open_device :: proc(h: ^Host) -> fc.Error {
	s := h.settings
	setup := backend.Device_Setup {
		output_device_id = s.output_device,
		input_device_id  = s.input_device,
		sample_rate      = s.sample_rate,
		buffer_frames    = s.buffer_frames,
	}
	for c in 0 ..< s.outputs do setup.output_channels += {c}
	for c in 0 ..< s.inputs do setup.input_channels += {c}
	backend.device_open(&h.device, setup, s.max_block) or_return
	h.opened = true
	h.format = h.device.format
	if err := ensure_engine(h, h.format.sample_rate); err != .None {
		host_close(h)
		return err
	}
	cb := backend.Device_Callback {
		process = proc(user: rawptr, block: ^backend.Io_Block) {
			h := (^Host)(user)
			run_block(h, block.inputs, block.outputs, block.frames, block.output_ns)
		},
		user = h,
	}
	if err := backend.device_start(&h.device, cb); err != .None {
		host_close(h)
		return err
	}
	h.running = true
	return .None
}

// Makes the clock and graph at `rate`, or moves the existing ones there.
@(private)
ensure_engine :: proc(h: ^Host, rate: f64) -> fc.Error {
	if h.graph != nil && h.graph.settings.sample_rate == rate do return .None
	st := graph.default_settings(rate, h.settings.max_block)
	st.input_channels = h.settings.inputs
	st.output_channels = h.settings.outputs
	g := graph.create(st) or_return
	c, cerr := transport.create(transport.default_settings(rate))
	if cerr != .None {
		graph.destroy(g)
		return cerr
	}
	if h.graph != nil && !h.settings.rebuild_on_rate_change {
		// Carry everything over: save the old session, load it at the new rate.
		data, serr := session.save_bytes({h.clock, h.graph}, allocator = context.temp_allocator)
		if serr == .None {
			l, lerr := session.load_bytes({c, g}, data, &h.registry, allocator = context.temp_allocator)
			session.loaded_destroy(&l)
			serr = lerr
		}
		if serr != .None {
			graph.destroy(g)
			transport.destroy(c)
			return serr
		}
	}
	if h.graph != nil {
		graph.destroy(h.graph)
		transport.destroy(h.clock)
	}
	h.graph, h.clock = g, c
	publish(h.bus, Host_Engine_Changed{h})
	return .None
}

// Announced when the host made a new graph and clock (the first time, or
// at a new sample rate): node and timeline ids from before are stale.
Host_Engine_Changed :: struct {
	host: ^Host,
}

// [rt] The fake driver, when the host runs one: advance it by `callbacks`
// device callbacks (tests and headless runs drive time this way).
host_fake_run :: proc(h: ^Host, callbacks: int) -> int {
	if h.fake == nil do return 0
	return fake.run(h.fake, callbacks)
}

// The fake driver, to simulate unplugging (`fake.unplug`) in tests.
host_fake :: proc(h: ^Host) -> ^fake.Fake {
	return h.fake
}

@(private)
_ :: clip.Player_Env
