package app

import "core:time"

import "fire:backend"
import "fire:backend/fake"
import "fire:clip"
import fc "fire:core"
import "fire:graph"
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
	return session.register_builtin(&h.registry, &h.env)
}

// Stops and closes everything, then frees it.
host_destroy :: proc(h: ^Host) {
	host_close(h)
	if h.graph != nil do graph.destroy(h.graph)
	if h.clock != nil do transport.destroy(h.clock)
	if h.disk != nil do record.disk_writer_destroy(h.disk)
	if h.streamer != nil do stream.destroy(h.streamer)
	fc.registry_destroy(&h.registry)
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
host_render :: proc(h: ^Host, out: [][]f32, frames: int) {
	for done := 0; done < frames; {
		n := min(h.settings.max_block, frames - done)
		views := make([][]f32, len(out), context.temp_allocator)
		for o, c in out do views[c] = o[done:][:n]
		ctx := fc.Process_Context{outputs = views, frames = n}
		transport.process(h.clock, &ctx, render_segment, h.graph)
		if h.disk != nil && h.settings.fake do record.disk_writer_service(h.disk)
		done += n
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
			ctx := fc.Process_Context{inputs = block.inputs, outputs = block.outputs, frames = block.frames}
			transport.process(h.clock, &ctx, render_segment, h.graph, block.output_ns)
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
