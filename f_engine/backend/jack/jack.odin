// JACK driver: the JACK server is the device. We register one JACK port per
// channel; JACK's realtime thread calls us once per period. libjack is loaded
// at run time (create returns .Unsupported without it). See docs/design/backend.md.
package jack

import "base:intrinsics"
import "base:runtime"
import "core:c"
import "core:fmt"
import "core:mem"
import "core:strings"

import "fire:backend"
import "fire:core"
import "fire:rt"
import j "fire:sys/jack"

Options :: struct {
	client_name:  string, // "" = "Fire Engine"
	server_name:  string, // "" = the default server
	// Connect our ports to the physical ports (output k → playback k,
	// capture k → input k) at start. Off for apps that route themselves.
	auto_connect: bool,
}

default_options :: proc() -> Options {
	return {auto_connect = true}
}

Jack :: struct {
	driver:     backend.Driver,
	allocator:  mem.Allocator,
	api:        j.Api,
	opts:       Options,
	client:     rawptr,
	format:     backend.Device_Format,
	in_ports:   []rawptr, // one JACK port per device channel
	out_ports:  []rawptr,
	in_planes:  []backend.Driver_Plane,
	out_planes: []backend.Driver_Plane,
	active:     bool,

	// Shared with JACK's threads.
	xrun_next: bool, // atomic
}

create :: proc(opts := Options{auto_connect = true}, allocator := context.allocator) -> (^backend.Driver, core.Error) {
	a := new(Jack, allocator)
	a.allocator = allocator
	a.opts = opts
	if !j.load(&a.api) {
		free(a, allocator)
		return nil, .Unsupported // libjack not installed
	}
	a.driver = {vtable = &jack_vtable, name = "JACK", data = a}
	// libjack prints to stderr by default (including "no server" noise while
	// probing); applications see errors through our return values instead.
	silent :: proc "c" (message: cstring) {}
	if a.api.set_error_function != nil do a.api.set_error_function(silent)
	if a.api.set_info_function != nil do a.api.set_info_function(silent)
	return &a.driver, .None
}

// The full JACK name ("client:port") of our port for a channel, for routing.
port_name :: proc(d: ^backend.Driver, output: bool, channel: int) -> string {
	a := (^Jack)(d.data)
	ports := a.out_ports if output else a.in_ports
	if channel < 0 || channel >= len(ports) || ports[channel] == nil do return ""
	return string(a.api.port_name(ports[channel]))
}

// Connects two JACK ports by full name (ours or anyone's). While running.
connect :: proc(d: ^backend.Driver, source, destination: string) -> core.Error {
	a := (^Jack)(d.data)
	if a.client == nil do return .Invalid_State
	r := a.api.connect(a.client, strings.clone_to_cstring(source, context.temp_allocator), strings.clone_to_cstring(destination, context.temp_allocator))
	return .None if r == 0 || r == 17 /* EEXIST: already connected */ else .Device_Error
}

@(private)
jack_vtable := backend.Driver_VTable {
	destroy   = jack_destroy,
	enumerate = jack_enumerate,
	open      = jack_open,
	start     = jack_start,
	stop      = jack_stop,
	close     = jack_close,
}

@(private)
jack_destroy :: proc(d: ^backend.Driver) {
	a := (^Jack)(d.data)
	jack_stop(d)
	jack_close(d)
	free(a, a.allocator)
}

@(private)
open_client :: proc(a: ^Jack, name: string) -> rawptr {
	status: c.int
	cname := strings.clone_to_cstring(name, context.temp_allocator)
	if a.opts.server_name != "" {
		return a.api.client_open(cname, j.JackNoStartServer | j.JackServerName, &status, strings.clone_to_cstring(a.opts.server_name, context.temp_allocator))
	}
	return a.api.client_open(cname, j.JackNoStartServer, &status)
}

// One device: the server. Channel counts are its physical ports.
@(private)
jack_enumerate :: proc(d: ^backend.Driver, allocator: mem.Allocator) -> ([]backend.Device_Info, core.Error) {
	a := (^Jack)(d.data)
	client := a.client
	if client == nil {
		client = open_client(a, "Fire Engine probe")
		if client == nil do return make([]backend.Device_Info, 0, allocator), .None // no server running
	}
	defer if client != a.client do a.api.client_close(client)
	rate, frames := a.api.get_sample_rate(client), a.api.get_buffer_size(client)
	infos := make([]backend.Device_Info, 1, allocator)
	infos[0] = {
		id                    = strings.clone(a.opts.server_name if a.opts.server_name != "" else "default", allocator),
		name                  = fmt.aprintf("JACK (%s)", a.opts.server_name if a.opts.server_name != "" else "default", allocator = allocator),
		input_channels        = count_ports(a, client, j.JackPortIsPhysical | j.JackPortIsOutput),
		output_channels       = count_ports(a, client, j.JackPortIsPhysical | j.JackPortIsInput),
		default_sample_rate   = f64(rate),
		default_buffer_frames = int(frames),
		is_default_input      = true,
		is_default_output     = true,
	}
	infos[0].sample_rates = make([]f64, 1, allocator)
	infos[0].sample_rates[0] = f64(rate)
	infos[0].buffer_sizes = make([]int, 1, allocator)
	infos[0].buffer_sizes[0] = int(frames)
	return infos, .None
}

@(private)
count_ports :: proc(a: ^Jack, client: rawptr, flags: c.ulong) -> int {
	names := a.api.get_ports(client, nil, j.JACK_DEFAULT_AUDIO_TYPE, flags)
	if names == nil do return 0
	defer a.api.free(names)
	n := 0
	for names[n] != nil do n += 1
	return n
}

// --- open / close -----------------------------------------------------------------

@(private)
jack_open :: proc(d: ^backend.Driver, setup: backend.Device_Setup) -> (backend.Device_Format, core.Error) {
	a := (^Jack)(d.data)
	if a.client != nil do return {}, .Invalid_State
	a.client = open_client(a, a.opts.client_name if a.opts.client_name != "" else "Fire Engine")
	if a.client == nil do return {}, .Invalid_Argument // no server
	rate := f64(a.api.get_sample_rate(a.client))
	frames := int(a.api.get_buffer_size(a.client))
	// The server owns rate and period: a different request cannot be honoured.
	if (setup.sample_rate > 0 && setup.sample_rate != rate) || (setup.buffer_frames > 0 && setup.buffer_frames != frames) {
		jack_close(d)
		return {}, .Unsupported
	}
	ins, outs := highest(setup.input_channels) + 1, highest(setup.output_channels) + 1
	err: mem.Allocator_Error
	if a.in_ports, err = make([]rawptr, ins, a.allocator); err == nil {
		if a.out_ports, err = make([]rawptr, outs, a.allocator); err == nil {
			if a.in_planes, err = make([]backend.Driver_Plane, ins, a.allocator); err == nil {
				a.out_planes, err = make([]backend.Driver_Plane, outs, a.allocator)
			}
		}
	}
	if err != nil {
		jack_close(d)
		return {}, .Out_Of_Memory
	}
	for &p, k in a.in_ports {
		p = a.api.port_register(a.client, fmt.ctprintf("in_%d", k + 1), j.JACK_DEFAULT_AUDIO_TYPE, j.JackPortIsInput, 0)
		if p == nil {
			jack_close(d)
			return {}, .Device_Error
		}
	}
	for &p, k in a.out_ports {
		p = a.api.port_register(a.client, fmt.ctprintf("out_%d", k + 1), j.JACK_DEFAULT_AUDIO_TYPE, j.JackPortIsOutput, 0)
		if p == nil {
			jack_close(d)
			return {}, .Device_Error
		}
	}
	a.api.set_process_callback(a.client, on_process, a)
	if a.api.set_xrun_callback != nil do a.api.set_xrun_callback(a.client, on_xrun, a)
	if a.api.on_shutdown != nil do a.api.on_shutdown(a.client, on_shutdown, a)
	if a.api.set_port_registration_callback != nil do a.api.set_port_registration_callback(a.client, on_registration, a)
	if a.api.set_buffer_size_callback != nil do a.api.set_buffer_size_callback(a.client, on_buffer_size, a)
	if a.api.set_client_registration_callback != nil do a.api.set_client_registration_callback(a.client, on_client_registration, a)

	a.format = {
		sample_rate            = rate,
		buffer_frames          = frames,
		max_driver_frames      = frames,
		input_channels         = setup.input_channels,
		output_channels        = setup.output_channels,
		device_input_channels  = ins,
		device_output_channels = outs,
		input_format           = .F32,
		output_format          = .F32,
		output_latency_frames  = frames, // one period queued in JACK's usual 2-period buffer
	}
	return a.format, .None
}

@(private)
jack_close :: proc(d: ^backend.Driver) {
	a := (^Jack)(d.data)
	if a.client == nil do return
	a.api.client_close(a.client) // also unregisters our ports
	a.client = nil
	delete(a.in_ports, a.allocator)
	delete(a.out_ports, a.allocator)
	delete(a.in_planes, a.allocator)
	delete(a.out_planes, a.allocator)
	a.in_ports, a.out_ports, a.in_planes, a.out_planes = nil, nil, nil, nil
}

// --- start / stop ------------------------------------------------------------------------

@(private)
jack_start :: proc(d: ^backend.Driver) -> core.Error {
	a := (^Jack)(d.data)
	if a.client == nil || a.active do return .Invalid_State
	intrinsics.atomic_store(&a.xrun_next, false)
	if a.api.activate(a.client) != 0 do return .Device_Error
	a.active = true
	if a.opts.auto_connect do connect_physical(a)
	return .None
}

// jack_deactivate returns only once the process callback can no longer run.
@(private)
jack_stop :: proc(d: ^backend.Driver) {
	a := (^Jack)(d.data)
	if !a.active do return
	a.api.deactivate(a.client)
	a.active = false
}

@(private)
connect_physical :: proc(a: ^Jack) {
	capture := a.api.get_ports(a.client, nil, j.JACK_DEFAULT_AUDIO_TYPE, j.JackPortIsPhysical | j.JackPortIsOutput)
	playback := a.api.get_ports(a.client, nil, j.JACK_DEFAULT_AUDIO_TYPE, j.JackPortIsPhysical | j.JackPortIsInput)
	defer if capture != nil do a.api.free(capture)
	defer if playback != nil do a.api.free(playback)
	for p, k in a.in_ports {
		if capture == nil || capture[k] == nil do break
		a.api.connect(a.client, capture[k], a.api.port_name(p))
	}
	for p, k in a.out_ports {
		if playback == nil || playback[k] == nil do break
		a.api.connect(a.client, a.api.port_name(p), playback[k])
	}
}

// --- JACK's threads ---------------------------------------------------------------------------

// [rt] JACK's process thread (already realtime).
@(private)
on_process :: proc "c" (nframes: j.jack_nframes_t, arg: rawptr) -> c.int {
	a := (^Jack)(arg)
	for p, k in a.in_ports do a.in_planes[k] = {a.api.port_get_buffer(p, nframes), 1}
	for p, k in a.out_ports do a.out_planes[k] = {a.api.port_get_buffer(p, nframes), 1}

	// JACK's clock (jack_get_time, µs) mapped onto ours by reading both now.
	// The period being processed was captured during the previous period and
	// plays during the next.
	now := rt.host_time_ns()
	frames: j.jack_nframes_t
	current, next: j.jack_time_t
	period_us: f32
	buf := backend.Driver_Buffers {
		frames      = int(nframes),
		input       = a.in_planes,
		output      = a.out_planes,
		callback_ns = now,
		xrun        = intrinsics.atomic_exchange(&a.xrun_next, false),
	}
	if a.api.get_cycle_times(a.client, &frames, &current, &next, &period_us) == 0 {
		offset := i64(now) - i64(a.api.get_time()) * 1000
		period_ns := i64(next - current) * 1000
		buf.input_ns = u64(i64(current) * 1000 + offset - period_ns)
		buf.output_ns = u64(i64(next) * 1000 + offset)
	}
	backend.driver_process(a.driver.host, &buf)
	return 0
}

@(private)
on_xrun :: proc "c" (arg: rawptr) -> c.int {
	intrinsics.atomic_store(&(^Jack)(arg).xrun_next, true)
	return 0
}

// The server went away. (May run on the process thread; the stream is dead
// anyway, so taking driver_notify's mutex is acceptable.)
@(private)
on_shutdown :: proc "c" (arg: rawptr) {
	a := (^Jack)(arg)
	context = runtime.default_context()
	if host := intrinsics.atomic_load(&a.driver.host); host != nil do backend.driver_notify(host, {kind = .Device_Lost})
}

@(private)
on_registration :: proc "c" (port_id: u32, register: c.int, arg: rawptr) {
	a := (^Jack)(arg)
	context = runtime.default_context()
	if host := intrinsics.atomic_load(&a.driver.host); host != nil do backend.driver_notify(host, {kind = .Devices_Changed})
}

@(private)
on_client_registration :: proc "c" (name: cstring, register: c.int, arg: rawptr) {
	a := (^Jack)(arg)
	context = runtime.default_context()
	if host := intrinsics.atomic_load(&a.driver.host); host != nil do backend.driver_notify(host, {kind = .Devices_Changed})
}

@(private)
on_buffer_size :: proc "c" (nframes: j.jack_nframes_t, arg: rawptr) -> c.int {
	a := (^Jack)(arg)
	context = runtime.default_context()
	if int(nframes) != a.format.buffer_frames {
		if host := intrinsics.atomic_load(&a.driver.host); host != nil do backend.driver_notify(host, {kind = .Format_Changed})
	}
	return 0
}

@(private)
highest :: proc(mask: backend.Channel_Mask) -> int {
	h := -1
	for ch in mask do h = max(h, ch)
	return h
}
