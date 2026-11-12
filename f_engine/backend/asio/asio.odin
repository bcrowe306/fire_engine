#+build windows
/*
ASIO driver: the low-latency interface most Windows audio interfaces ship.
Opt-in: build with `-define:FIRE_ASIO=true`, or `create` returns
`.Unsupported`. The interface is declared in Fire Engine's own code
(fire:sys/asio); Steinberg's SDK isn't used, but ASIO is Steinberg's
technology: check their terms before you ship with it.

Each installed ASIO driver is one device with inputs and outputs on one
clock; its id is "asio:" and its registry name. Only one ASIO device can be
open in a process at a time (the interface's callbacks have no context).
The driver calls back on a thread of its own, with buffers exactly
`buffer_frames` long.

	d, err := asio.create()
	if err == .None {
		infos, _ := backend.driver_enumerate(d)
		backend.device_init(&dev, d)
		backend.device_open(&dev, {output_device_id = infos[0].id, input_channels = {0, 1}, output_channels = {0, 1}}, 512)
	}
*/
package asio

import "base:intrinsics"
import "core:mem"
import "core:slice"
import "core:strings"
import win "core:sys/windows"
import "core:thread"
import "core:time"

import "fire:backend"
import "fire:core"
import "fire:rt"
import a "fire:sys/asio"

// Whether this build includes ASIO support (`-define:FIRE_ASIO=true`).
ENABLED :: #config(FIRE_ASIO, false)

// The prefix of ASIO device ids.
ID_PREFIX :: "asio:"

@(private)
Asio :: struct {
	driver:       backend.Driver,
	allocator:    mem.Allocator,
	// The open driver.
	com:          ^a.IASIO,
	name:         string, // registry name
	format:       backend.Device_Format,
	infos:        []a.Buffer_Info, // the selected inputs, then outputs
	in_planes:    []backend.Driver_Plane, // one per device input channel; nil data unless selected
	out_planes:   []backend.Driver_Plane,
	output_ready: bool, // the driver wants output_ready after each buffer
	callbacks:    a.Callbacks,
	watcher:      ^thread.Thread,
	// Shared with the driver's thread (atomic).
	running:      bool,
	in_callback:  i32,
	xrun:         bool,
	reset:        bool, // the driver asked to be reopened
	rate_changed: bool,
	watching:     bool,
}

// The open device, for the callbacks (ASIO gives them no context).
@(private)
current: ^Asio

@(private)
asio_vtable := backend.Driver_VTable {
	destroy   = asio_destroy,
	enumerate = asio_enumerate,
	open      = asio_open,
	start     = asio_start,
	stop      = asio_stop,
	close     = asio_close,
}

// Makes an ASIO driver. Initializes COM (apartment-threaded, as ASIO
// drivers expect) on the calling thread, which must be the control thread
// for every later call. `.Unsupported` unless built with
// `-define:FIRE_ASIO=true`. Free with `backend.driver_destroy`.
create :: proc(allocator := context.allocator) -> (^backend.Driver, core.Error) {
	when !ENABLED {
		return nil, .Unsupported
	} else {
		win.CoInitializeEx(nil, .APARTMENTTHREADED) // S_FALSE or a mode change: COM is usable either way
		d := new(Asio, allocator)
		d.allocator = allocator
		d.driver = {vtable = &asio_vtable, name = "ASIO", data = d}
		return &d.driver, .None
	}
}

@(private)
asio_destroy :: proc(dr: ^backend.Driver) {
	d := (^Asio)(dr.data)
	if d.com != nil do asio_close(dr)
	free(d, d.allocator)
}

// --- the registry and loading ------------------------------------------------------------

@(private)
Registered :: struct {
	name:        string, // the registry key
	clsid:       win.GUID,
}

// The ASIO drivers in the registry. Strings in `allocator`.
@(private)
registered :: proc(allocator: mem.Allocator) -> []Registered {
	out := make([dynamic]Registered, allocator)
	key: win.HKEY
	if win.RegOpenKeyExW(win.HKEY_LOCAL_MACHINE, win.L("SOFTWARE\\ASIO"), 0, win.KEY_READ, &key) != 0 do return out[:]
	defer win.RegCloseKey(key)
	for i: u32 = 0; ; i += 1 {
		buf: [256]u16
		n := u32(len(buf))
		if win.RegEnumKeyExW(key, i, &buf[0], &n, nil, nil, nil, nil) != 0 do break
		clsid_text: [64]u16
		bytes := u32(size_of(clsid_text))
		if win.RegGetValueW(key, cstring16(&buf[0]), win.L("CLSID"), win.RRF_RT_REG_SZ, nil, &clsid_text[0], &bytes) != 0 do continue
		r: Registered
		if win.CLSIDFromString(cstring16(&clsid_text[0]), &r.clsid) < 0 do continue
		r.name, _ = win.utf16_to_utf8(buf[:n], allocator)
		append(&out, r)
	}
	return out[:]
}

// Creates and initializes the driver object for `r`.
@(private)
load :: proc(r: Registered) -> (com: ^a.IASIO, err: core.Error) {
	clsid := r.clsid
	// An ASIO driver's interface id is its class id.
	if win.CoCreateInstance(&clsid, nil, win.CLSCTX_INPROC_SERVER, &clsid, (^rawptr)(&com)) < 0 || com == nil do return nil, .Device_Error
	if com.vtbl.init(com, rawptr(win.GetDesktopWindow())) == 0 {
		com.vtbl.release(com)
		return nil, .Device_Error
	}
	return com, .None
}

@(private)
standard_rates := [?]f64{44_100, 48_000, 88_200, 96_000, 176_400, 192_000}

@(private)
asio_enumerate :: proc(dr: ^backend.Driver, allocator: mem.Allocator) -> ([]backend.Device_Info, core.Error) {
	d := (^Asio)(dr.data)
	list := registered(context.temp_allocator)
	out := make([dynamic]backend.Device_Info, allocator)
	for r in list {
		// Load each driver to ask it (except the one already open).
		com := d.com if d.com != nil && r.name == d.name else nil
		ours := com != nil
		if !ours {
			c, err := load(r)
			if err != .None do continue
			com = c
		}
		info := backend.Device_Info{id = strings.concatenate({ID_PREFIX, r.name}, allocator), name = strings.clone(r.name, allocator)}
		ins, outs: i32
		com.vtbl.get_channels(com, &ins, &outs)
		info.input_channels, info.output_channels = int(ins), int(outs)
		// Each channel's name, from the driver.
		names :: proc(com: ^a.IASIO, n: int, input: bool, allocator: mem.Allocator) -> []string {
			out := make([]string, n, allocator)
			for &name, c in out {
				ci := a.Channel_Info{channel = i32(c), is_input = 1 if input else 0}
				if com.vtbl.get_channel_info(com, &ci) != a.OK do continue
				name = strings.clone(strings.truncate_to_byte(string(ci.name[:]), 0), allocator)
			}
			return out
		}
		info.input_channel_names = names(com, info.input_channels, true, allocator)
		info.output_channel_names = names(com, info.output_channels, false, allocator)
		rates := make([dynamic]f64, allocator)
		for rate in standard_rates do if com.vtbl.can_sample_rate(com, rate) == a.OK do append(&rates, rate)
		info.sample_rates = rates[:]
		com.vtbl.get_sample_rate(com, &info.default_sample_rate)
		lo, hi, pref, gran: i32
		com.vtbl.get_buffer_size(com, &lo, &hi, &pref, &gran)
		info.default_buffer_frames = int(pref)
		info.buffer_sizes = buffer_sizes(int(lo), int(hi), int(pref), int(gran), allocator)
		append(&out, info)
		if !ours do com.vtbl.release(com)
	}
	return out[:], .None
}

// The buffer sizes a driver allows: from `lo` to `hi` in steps of `gran`,
// or powers of two when `gran` is −1, or just `pref` when it is 0. A long
// range (FlexASIO allows every size) is listed as its ends, the preferred
// size, and the powers of two it allows.
@(private)
buffer_sizes :: proc(lo, hi, pref, gran: int, allocator: mem.Allocator) -> []int {
	out := make([dynamic]int, allocator)
	switch {
	case gran == -1:
		for n := lo; n <= hi && n > 0; n *= 2 do append(&out, n)
	case gran > 0 && (hi - lo) / gran < 32:
		for n := lo; n <= hi; n += gran do append(&out, n)
	case gran > 0:
		append(&out, lo)
		for n := 16; n < hi; n *= 2 do if n > lo && (n - lo) % gran == 0 && n != pref do append(&out, n)
		if pref > lo && pref < hi do append(&out, pref)
		append(&out, hi)
		slice.sort(out[:])
	}
	if len(out) == 0 do append(&out, pref)
	return out[:]
}

// The allowed size nearest `want` (`pref` for 0).
@(private)
fit_buffer :: proc(lo, hi, pref, gran, want: int) -> int {
	if want <= 0 || gran == 0 do return pref
	n := clamp(want, lo, hi)
	if gran == -1 { // the nearest power of two in range
		best := lo
		for p := lo; p <= hi && p > 0; p *= 2 do if abs(p - n) < abs(best - n) do best = p
		return best
	}
	return clamp(lo + (n - lo + gran / 2) / gran * gran, lo, hi)
}

@(private)
sample_format :: proc(t: a.Sample_Type) -> (backend.Sample_Format, bool) {
	#partial switch t {
	case .Int16_LSB:   return .I16, true
	case .Int24_LSB:   return .I24, true
	case .Int32_LSB:   return .I32, true
	case .Float32_LSB: return .F32, true
	case .Float64_LSB: return .F64, true
	case .Int32_LSB24: return .I24_In_32, true
	}
	return .F32, false // big-endian and 16/18/20-in-32 layouts: not supported
}

// --- open, start, stop, close ------------------------------------------------------------

@(private)
asio_open :: proc(dr: ^backend.Driver, setup: backend.Device_Setup) -> (backend.Device_Format, core.Error) {
	d := (^Asio)(dr.data)
	if d.com != nil || intrinsics.atomic_load(&current) != nil do return {}, .Invalid_State // one ASIO device per process
	id := setup.output_device_id if setup.output_device_id != "" else setup.input_device_id
	if setup.output_device_id != "" && setup.input_device_id != "" && setup.input_device_id != setup.output_device_id do return {}, .Unsupported // one driver: one device
	if setup.input_channels == {} && setup.output_channels == {} do return {}, .Invalid_Argument
	list := registered(context.temp_allocator)
	pick := -1
	for r, i in list do if id == "" || id == strings.concatenate({ID_PREFIX, r.name}, context.temp_allocator) {
		pick = i
		break
	}
	if pick < 0 do return {}, .Invalid_Argument // no such driver
	err := open_driver(d, list[pick], setup)
	if err != .None {
		close_driver(d)
		return {}, err
	}
	return d.format, .None
}

// Fills `d` in place (see the convention about cleanup in CONVENTIONS.md);
// the caller closes on failure.
@(private)
open_driver :: proc(d: ^Asio, r: Registered, setup: backend.Device_Setup) -> core.Error {
	d.com = load(r) or_return
	d.name = strings.clone(r.name, d.allocator)
	com := d.com
	ins, outs: i32
	if com.vtbl.get_channels(com, &ins, &outs) != a.OK do return .Device_Error
	for c in setup.input_channels do if c >= int(ins) do return .Invalid_Argument
	for c in setup.output_channels do if c >= int(outs) do return .Invalid_Argument

	rate := setup.sample_rate
	if rate > 0 {
		if com.vtbl.can_sample_rate(com, rate) != a.OK do return .Unsupported
		if com.vtbl.set_sample_rate(com, rate) != a.OK do return .Device_Error
	} else if com.vtbl.get_sample_rate(com, &rate) != a.OK || !(rate > 0) {
		return .Device_Error
	}
	lo, hi, pref, gran: i32
	if com.vtbl.get_buffer_size(com, &lo, &hi, &pref, &gran) != a.OK do return .Device_Error
	frames := fit_buffer(int(lo), int(hi), int(pref), int(gran), setup.buffer_frames)

	// One buffer pair per selected channel; every channel of a direction
	// must use one format.
	n := card(setup.input_channels) + card(setup.output_channels)
	ae: mem.Allocator_Error
	d.infos, ae = make([]a.Buffer_Info, n, d.allocator)
	if ae == nil do d.in_planes, ae = make([]backend.Driver_Plane, int(ins), d.allocator)
	if ae == nil do d.out_planes, ae = make([]backend.Driver_Plane, int(outs), d.allocator)
	if ae != nil do return .Out_Of_Memory
	for &p in d.in_planes do p.channels = 1
	for &p in d.out_planes do p.channels = 1
	k := 0
	in_format, out_format: backend.Sample_Format
	for input in ([]bool{true, false}) {
		mask := setup.input_channels if input else setup.output_channels
		first := true
		for c in mask {
			info := a.Channel_Info{channel = i32(c), is_input = 1 if input else 0}
			if com.vtbl.get_channel_info(com, &info) != a.OK do return .Device_Error
			f, ok := sample_format(info.type)
			if !ok do return .Unsupported
			if input {
				if !first && f != in_format do return .Unsupported
				in_format = f
			} else {
				if !first && f != out_format do return .Unsupported
				out_format = f
			}
			first = false
			d.infos[k] = {is_input = 1 if input else 0, channel_num = i32(c)}
			k += 1
		}
	}
	d.callbacks = {
		buffer_switch = on_buffer_switch,
		sample_rate_did_change = on_rate_change,
		asio_message = on_message,
		buffer_switch_time_info = on_buffer_switch_time_info,
	}
	intrinsics.atomic_store(&current, d) // the driver may send messages while making buffers
	if com.vtbl.create_buffers(com, raw_data(d.infos), i32(n), i32(frames), &d.callbacks) != a.OK do return .Device_Error
	in_lat, out_lat: i32
	com.vtbl.get_latencies(com, &in_lat, &out_lat)
	d.output_ready = com.vtbl.output_ready(com) == a.OK
	d.format = {
		sample_rate            = rate,
		buffer_frames          = frames,
		max_driver_frames      = frames,
		input_channels         = setup.input_channels,
		output_channels        = setup.output_channels,
		device_input_channels  = int(ins),
		device_output_channels = int(outs),
		input_format           = in_format,
		output_format          = out_format,
		input_latency_frames   = int(in_lat),
		output_latency_frames  = int(out_lat),
	}
	return .None
}

@(private)
asio_start :: proc(dr: ^backend.Driver) -> core.Error {
	d := (^Asio)(dr.data)
	if d.com == nil do return .Invalid_State
	intrinsics.atomic_store(&d.running, true)
	if d.com.vtbl.start(d.com) != a.OK {
		intrinsics.atomic_store(&d.running, false)
		return .Device_Error
	}
	intrinsics.atomic_store(&d.watching, true)
	d.watcher = thread.create_and_start_with_data(d, watch)
	return .None
}

@(private)
asio_stop :: proc(dr: ^backend.Driver) {
	d := (^Asio)(dr.data)
	if d.com == nil || !intrinsics.atomic_load(&d.running) do return
	intrinsics.atomic_store(&d.running, false)
	d.com.vtbl.stop(d.com)
	for intrinsics.atomic_load(&d.in_callback) != 0 do time.sleep(time.Millisecond) // a switch in flight finishes first
	intrinsics.atomic_store(&d.watching, false)
	if d.watcher != nil {
		thread.join(d.watcher)
		thread.destroy(d.watcher)
		d.watcher = nil
	}
}

@(private)
asio_close :: proc(dr: ^backend.Driver) {
	d := (^Asio)(dr.data)
	asio_stop(dr)
	close_driver(d)
}

@(private)
close_driver :: proc(d: ^Asio) {
	if d.com != nil {
		if d.infos != nil do d.com.vtbl.dispose_buffers(d.com)
		d.com.vtbl.release(d.com)
		d.com = nil
	}
	intrinsics.atomic_compare_exchange_strong(&current, d, nil)
	delete(d.infos, d.allocator)
	delete(d.in_planes, d.allocator)
	delete(d.out_planes, d.allocator)
	delete(d.name, d.allocator)
	d.infos, d.in_planes, d.out_planes, d.name = nil, nil, nil, ""
}

// Hands the driver's requests to the device's event queue (which mustn't
// be touched from the driver's audio thread).
@(private)
watch :: proc(data: rawptr) {
	d := (^Asio)(data)
	for intrinsics.atomic_load(&d.watching) {
		host := d.driver.host
		if host != nil {
			if intrinsics.atomic_exchange(&d.reset, false) do backend.driver_notify(host, {kind = .Format_Changed})
			if intrinsics.atomic_exchange(&d.rate_changed, false) do backend.driver_notify(host, {kind = .Format_Changed})
		}
		time.sleep(10 * time.Millisecond)
	}
}

// --- the driver's thread -----------------------------------------------------------------

@(private)
on_buffer_switch :: proc "c" (index: i32, direct: a.Bool) {
	process(index)
}

@(private)
on_buffer_switch_time_info :: proc "c" (params: ^a.Time, index: i32, direct: a.Bool) -> ^a.Time {
	process(index)
	return params
}

@(private)
on_rate_change :: proc "c" (rate: f64) {
	if d := intrinsics.atomic_load(&current); d != nil do intrinsics.atomic_store(&d.rate_changed, true)
}

@(private)
on_message :: proc "c" (selector, value: i32, message: rawptr, opt: ^f64) -> i32 {
	d := intrinsics.atomic_load(&current)
	switch selector {
	case a.SELECTOR_SUPPORTED:
		switch value {
		case a.ENGINE_VERSION, a.RESET_REQUEST, a.BUFFER_SIZE_CHANGE, a.RESYNC_REQUEST, a.LATENCIES_CHANGED, a.SUPPORTS_TIME_INFO: return 1
		}
		return 0
	case a.ENGINE_VERSION:
		return 2
	case a.RESET_REQUEST, a.BUFFER_SIZE_CHANGE: // reopen to follow
		if d != nil do intrinsics.atomic_store(&d.reset, true)
		return 1
	case a.RESYNC_REQUEST: // samples were lost
		if d != nil do intrinsics.atomic_store(&d.xrun, true)
		return 1
	case a.LATENCIES_CHANGED:
		return 1
	case a.SUPPORTS_TIME_INFO:
		return 1
	}
	return 0
}

// [rt] One buffer switch: point the planes at half `index` of every
// buffer pair and run the device.
@(private)
process :: proc "contextless" (index: i32) {
	d := intrinsics.atomic_load(&current)
	if d == nil || !intrinsics.atomic_load(&d.running) do return
	intrinsics.atomic_add(&d.in_callback, 1)
	defer intrinsics.atomic_sub(&d.in_callback, 1)
	for info in d.infos {
		planes := d.in_planes if info.is_input != 0 else d.out_planes
		planes[info.channel_num].data = info.buffers[index & 1]
	}
	now := rt.host_time_ns()
	ns := 1e9 / d.format.sample_rate
	f := d.format
	buf := backend.Driver_Buffers {
		frames      = f.buffer_frames,
		input       = d.in_planes,
		output      = d.out_planes,
		callback_ns = now,
		// The input was captured over the last buffer, `input_latency`
		// before the switch; the output is heard `output_latency` after it.
		input_ns    = u64(f64(now) - f64(f.input_latency_frames) * ns) if f.device_input_channels > 0 else 0,
		output_ns   = u64(f64(now) + f64(f.output_latency_frames) * ns) if f.device_output_channels > 0 else 0,
		xrun        = intrinsics.atomic_exchange(&d.xrun, false),
	}
	if host := d.driver.host; host != nil do backend.driver_process(host, &buf)
	if d.output_ready do d.com.vtbl.output_ready(d.com)
}
