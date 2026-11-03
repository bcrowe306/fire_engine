#+build windows
// WASAPI driver: shared mode, event-driven, render and capture endpoints of
// one physical device, serviced by an MMCSS "Pro Audio" thread of our own.
// See docs/design/backend.md.
package wasapi

import "base:intrinsics"
import "base:runtime"
import "core:mem"
import win "core:sys/windows"
import "core:thread"

import "fire:backend"
import "fire:core"
import "fire:rt"
import w "fire:sys/wasapi"

// Periods of silence the capture FIFO starts with, as input latency: render
// and capture events are not phase-aligned, and capture can arrive in bursts
// (VB-CABLE on the test VM fell more than 2 periods behind). 4 periods = 40 ms
// at the default 10 ms period. Revisit on real hardware.
CUSHION_PERIODS := 4

Endpoint :: struct {
	device:        ^w.IMMDevice,
	client:        ^w.IAudioClient,
	render:        ^w.IAudioRenderClient,
	capture:       ^w.IAudioCaptureClient,
	event:         w.HANDLE,
	format:        backend.Sample_Format,
	channels:      int,
	frame_bytes:   int,
	buffer_frames: int, // the endpoint buffer
	period_frames: int, // the engine period we are woken at
	latency_ns:    u64,
}

// Our IMMNotificationClient: a COM object whose first field is its vtable.
// It lives inside the driver, so AddRef/Release only count.
Notifier :: struct {
	vtbl:  ^w.IMMNotificationClient_VTable,
	refs:  i32, // atomic
	owner: ^Wasapi,
}

Wasapi :: struct {
	driver:     backend.Driver,
	notifier:   Notifier,
	ids_lock:   win.SRWLOCK, // open endpoint IDs, read by the notification thread
	out_id:     string,
	in_id:      string,
	allocator:  mem.Allocator,
	enumerator: ^w.IMMDeviceEnumerator,
	out:        Endpoint,
	in_:        Endpoint,
	format:     backend.Device_Format,
	is_open:    bool,
	thread:     ^thread.Thread,

	// Capture FIFO: decouples capture packets from render periods.
	ring:          []u8,
	ring_frames:   int,
	ring_head:     int, // frame index of the oldest frame
	ring_len:      int, // frames stored
	ring_head_ns:  f64, // capture time of the oldest frame
	ring_timed:    bool, // ring_head_ns is known (set by the first capture packet)
	scratch:       []u8, // contiguous input for one cycle

	in_planes:  [1]backend.Driver_Plane,
	out_planes: [1]backend.Driver_Plane,

	// Shared with the audio thread.
	stop_flag:  bool, // atomic
	mmcss:      bool, // atomic: MMCSS registration succeeded
	last_error: i64,  // atomic: last failing HRESULT, for diagnostics
	min_padding: i64, // atomic: lowest render padding seen at a wake (frames)
	min_ring:    i64, // atomic: lowest captured backlog seen at a wake (frames); 0 = input ran dry

	// Audio thread only.
	xrun_pending:   bool,
	lost:           bool,
	last_output_ns: f64,
	last_frames:    int,
}

create :: proc(allocator := context.allocator) -> (^backend.Driver, core.Error) {
	hr := win.CoInitializeEx(nil, .MULTITHREADED)
	// S_FALSE: already initialized. RPC_E_CHANGED_MODE: the app chose STA; the
	// WASAPI interfaces are free-threaded, so we can still use them.
	_ = hr
	a := new(Wasapi, allocator)
	a.allocator = allocator
	a.driver = {vtable = &wasapi_vtable, name = "WASAPI", data = a}
	if win.CoCreateInstance(&w.CLSID_MMDeviceEnumerator, nil, w.CLSCTX_ALL, &w.IID_IMMDeviceEnumerator, (^rawptr)(&a.enumerator)) < 0 {
		free(a, allocator)
		return nil, .Device_Error
	}
	a.notifier = {vtbl = &notifier_vtable, refs = 1, owner = a}
	a.enumerator.vtbl.RegisterEndpointNotificationCallback(a.enumerator, &a.notifier)
	return &a.driver, .None
}

// --- hot-plug (an MMDevice notification thread) ------------------------------------------

@(private)
notifier_vtable := w.IMMNotificationClient_VTable {
	QueryInterface = proc "system" (this: rawptr, riid: ^w.GUID, out: ^rawptr) -> w.HRESULT {
		if riid^ == w.IID_IUnknown || riid^ == w.IID_IMMNotificationClient {
			out^ = this
			intrinsics.atomic_add(&(^Notifier)(this).refs, 1)
			return w.S_OK
		}
		out^ = nil
		return w.E_NOINTERFACE
	},
	AddRef  = proc "system" (this: rawptr) -> u32 { return u32(intrinsics.atomic_add(&(^Notifier)(this).refs, 1) + 1) },
	Release = proc "system" (this: rawptr) -> u32 { return u32(intrinsics.atomic_sub(&(^Notifier)(this).refs, 1) - 1) },
	OnDeviceStateChanged = proc "system" (this: rawptr, id: win.wstring, new_state: w.DWORD) -> w.HRESULT {
		endpoint_changed((^Notifier)(this).owner, id, new_state != w.DEVICE_STATE_ACTIVE)
		return w.S_OK
	},
	OnDeviceAdded = proc "system" (this: rawptr, id: win.wstring) -> w.HRESULT {
		endpoint_changed((^Notifier)(this).owner, id, false)
		return w.S_OK
	},
	OnDeviceRemoved = proc "system" (this: rawptr, id: win.wstring) -> w.HRESULT {
		endpoint_changed((^Notifier)(this).owner, id, true)
		return w.S_OK
	},
	OnDefaultDeviceChanged = proc "system" (this: rawptr, flow: w.EDataFlow, role: w.ERole, id: win.wstring) -> w.HRESULT {
		if role != .eConsole do return w.S_OK // reported once per role; we use the console role
		if host := intrinsics.atomic_load(&(^Notifier)(this).owner.driver.host); host != nil {
			context = runtime.default_context()
			backend.driver_notify(host, {kind = .Default_Device_Changed})
		}
		return w.S_OK
	},
	OnPropertyValueChanged = proc "system" (this: rawptr, id: win.wstring, key: ^w.PROPERTYKEY) -> w.HRESULT { return w.S_OK },
}

// Devices_Changed for any endpoint; Device_Lost when it is one we have open.
@(private)
endpoint_changed :: proc "system" (a: ^Wasapi, id: win.wstring, gone: bool) {
	context = runtime.default_context()
	host := intrinsics.atomic_load(&a.driver.host)
	if host == nil do return
	backend.driver_notify(host, {kind = .Devices_Changed})
	if !gone do return
	s, _ := win.wstring_to_utf8(id, -1, context.temp_allocator)
	win.AcquireSRWLockShared(&a.ids_lock)
	ours := s != "" && (s == a.out_id || s == a.in_id)
	win.ReleaseSRWLockShared(&a.ids_lock)
	if ours do backend.driver_notify(host, {kind = .Device_Lost})
	free_all(context.temp_allocator)
}

Diagnostics :: struct {
	mmcss:       bool,
	last_error:  i64,
	min_padding: i64,
	min_ring:    i64,
}

diagnostics :: proc(d: ^backend.Driver) -> Diagnostics {
	a := (^Wasapi)(d.data)
	return {
		mmcss       = intrinsics.atomic_load(&a.mmcss),
		last_error  = intrinsics.atomic_load(&a.last_error),
		min_padding = intrinsics.atomic_load(&a.min_padding),
		min_ring    = intrinsics.atomic_load(&a.min_ring),
	}
}

@(private)
wasapi_vtable := backend.Driver_VTable {
	destroy   = wasapi_destroy,
	enumerate = wasapi_enumerate,
	open      = wasapi_open,
	start     = wasapi_start,
	stop      = wasapi_stop,
	close     = wasapi_close,
}

@(private)
wasapi_destroy :: proc(d: ^backend.Driver) {
	a := (^Wasapi)(d.data)
	wasapi_stop(d)
	wasapi_close(d)
	a.enumerator.vtbl.UnregisterEndpointNotificationCallback(a.enumerator, &a.notifier)
	w.release(a.enumerator)
	free(a, a.allocator)
}

// --- enumeration ------------------------------------------------------------------------

// Each WASAPI endpoint is one direction: render endpoints have outputs only,
// capture endpoints inputs only. IDs are the endpoint ID strings, stable
// across reboots.
@(private)
wasapi_enumerate :: proc(d: ^backend.Driver, allocator: mem.Allocator) -> ([]backend.Device_Info, core.Error) {
	a := (^Wasapi)(d.data)
	infos := make([dynamic]backend.Device_Info, allocator)
	for flow in ([]w.EDataFlow{.eRender, .eCapture}) {
		default_id := default_endpoint_id(a, flow)
		coll: ^w.IMMDeviceCollection
		if a.enumerator.vtbl.EnumAudioEndpoints(a.enumerator, flow, w.DEVICE_STATE_ACTIVE, &coll) < 0 do continue
		defer w.release(coll)
		count: w.UINT
		coll.vtbl.GetCount(coll, &count)
		for i in 0 ..< count {
			dev: ^w.IMMDevice
			if coll.vtbl.Item(coll, i, &dev) < 0 do continue
			defer w.release(dev)
			info := backend.Device_Info{id = device_id(dev, allocator), name = friendly_name(dev, allocator)}
			client: ^w.IAudioClient
			if dev.vtbl.Activate(dev, &w.IID_IAudioClient3, w.CLSCTX_ALL, nil, (^rawptr)(&client)) < 0 &&
			   dev.vtbl.Activate(dev, &w.IID_IAudioClient, w.CLSCTX_ALL, nil, (^rawptr)(&client)) < 0 {
				delete(info.id, allocator)
				delete(info.name, allocator)
				continue
			}
			defer w.release(client)
			mix: ^w.WAVEFORMATEX
			if client.vtbl.GetMixFormat(client, &mix) >= 0 {
				if flow == .eRender do info.output_channels = int(mix.nChannels)
				else do info.input_channels = int(mix.nChannels)
				info.default_sample_rate = f64(mix.nSamplesPerSec)
				info.sample_rates = make([]f64, 1, allocator)
				info.sample_rates[0] = f64(mix.nSamplesPerSec)
				info.buffer_sizes, info.default_buffer_frames = period_sizes(client, mix, allocator)
				win.CoTaskMemFree(mix)
			}
			if flow == .eRender do info.is_default_output = info.id == default_id
			else do info.is_default_input = info.id == default_id
			append(&infos, info)
		}
		delete(default_id, context.temp_allocator)
	}
	return infos[:], .None
}

// Shared-mode periods: IAudioClient3 reports a range in multiples of a
// fundamental period; without it only the default period exists.
@(private)
period_sizes :: proc(client: ^w.IAudioClient, mix: ^w.WAVEFORMATEX, allocator: mem.Allocator) -> (sizes: []int, default_frames: int) {
	def, fund, lo, hi: w.UINT
	if client.vtbl.GetSharedModeEnginePeriod != nil && client.vtbl.GetSharedModeEnginePeriod(client, mix, &def, &fund, &lo, &hi) >= 0 && fund > 0 {
		list := make([dynamic]int, allocator)
		for n := lo; n <= hi && len(list) < 64; n += fund do append(&list, int(n))
		return list[:], int(def)
	}
	period, min_period: w.REFERENCE_TIME
	client.vtbl.GetDevicePeriod(client, &period, &min_period)
	frames := int(f64(period) * f64(mix.nSamplesPerSec) / 1e7 + 0.5)
	sizes = make([]int, 1, allocator)
	sizes[0] = frames
	return sizes, frames
}

// --- open / close ------------------------------------------------------------------------

@(private)
wasapi_open :: proc(d: ^backend.Driver, setup: backend.Device_Setup) -> (backend.Device_Format, core.Error) {
	a := (^Wasapi)(d.data)
	if a.is_open do return {}, .Invalid_State
	err: core.Error
	if setup.output_channels != {} {
		if err = open_endpoint(a, &a.out, setup.output_device_id, .eRender, setup.output_channels, setup.sample_rate, setup.buffer_frames); err != .None {
			close_endpoints(a)
			return {}, err
		}
	}
	if setup.input_channels != {} {
		if err = open_endpoint(a, &a.in_, setup.input_device_id, .eCapture, setup.input_channels, setup.sample_rate, setup.buffer_frames); err != .None {
			close_endpoints(a)
			return {}, err
		}
	}
	both := a.out.client != nil && a.in_.client != nil
	if both {
		// One clock: both endpoints must belong to one physical device.
		if !same_container(a.out.device, a.in_.device) {
			close_endpoints(a)
			return {}, .Unsupported
		}
	}
	main := &a.out if a.out.client != nil else &a.in_
	rate := setup.sample_rate if setup.sample_rate > 0 else mix_rate(main)

	if alloc_err := alloc_buffers(a); alloc_err != nil {
		close_endpoints(a)
		return {}, .Out_Of_Memory
	}
	a.format = {
		sample_rate            = rate,
		buffer_frames          = main.period_frames,
		max_driver_frames      = max(a.out.buffer_frames, a.in_.buffer_frames),
		input_channels         = setup.input_channels,
		output_channels        = setup.output_channels,
		device_input_channels  = a.in_.channels,
		device_output_channels = a.out.channels,
		input_format           = a.in_.format,
		output_format          = a.out.format,
		input_latency_frames   = int(f64(a.in_.latency_ns) * rate / 1e9),
		output_latency_frames  = int(f64(a.out.latency_ns) * rate / 1e9),
	}
	win.AcquireSRWLockExclusive(&a.ids_lock)
	if a.out.device != nil do a.out_id = device_id(a.out.device, a.allocator)
	if a.in_.device != nil do a.in_id = device_id(a.in_.device, a.allocator)
	win.ReleaseSRWLockExclusive(&a.ids_lock)
	a.is_open = true
	return a.format, .None
}

@(private)
// Fills `e` in place. On failure it releases whatever was opened and leaves `e`
// zeroed. (Not a returned value: a deferred cleanup of a named result is not
// reliably visible to the caller, and at -o:speed released COM pointers
// escaped and were released twice.)
open_endpoint :: proc(a: ^Wasapi, e: ^Endpoint, id: string, flow: w.EDataFlow, mask: backend.Channel_Mask, rate: f64, period: int) -> (err: core.Error) {
	e^ = {}
	defer if err != .None do close_endpoint(e)
	if id == "" {
		if a.enumerator.vtbl.GetDefaultAudioEndpoint(a.enumerator, flow, .eConsole, &e.device) < 0 do return .Invalid_Argument
	} else {
		wid := win.utf8_to_wstring(id, context.temp_allocator)
		if a.enumerator.vtbl.GetDevice(a.enumerator, wid, &e.device) < 0 do return .Invalid_Argument
	}
	has3 := e.device.vtbl.Activate(e.device, &w.IID_IAudioClient3, w.CLSCTX_ALL, nil, (^rawptr)(&e.client)) >= 0
	if !has3 && e.device.vtbl.Activate(e.device, &w.IID_IAudioClient, w.CLSCTX_ALL, nil, (^rawptr)(&e.client)) < 0 {
		return .Device_Error
	}

	mix: ^w.WAVEFORMATEX
	if e.client.vtbl.GetMixFormat(e.client, &mix) < 0 do return .Device_Error
	defer win.CoTaskMemFree(mix)
	if rate > 0 && f64(mix.nSamplesPerSec) != rate do return .Unsupported // shared mode runs at the mix rate
	ok: bool
	if e.format, ok = sample_format(mix); !ok do return .Unsupported
	e.channels = int(mix.nChannels)
	e.frame_bytes = int(mix.nBlockAlign)
	for ch in mask do if ch >= e.channels do return .Invalid_Argument

	flags := w.AUDCLNT_STREAMFLAGS_EVENTCALLBACK | w.AUDCLNT_STREAMFLAGS_NOPERSIST
	hr: w.HRESULT
	if period > 0 {
		def, fund, lo, hi: w.UINT
		if !has3 || e.client.vtbl.GetSharedModeEnginePeriod(e.client, mix, &def, &fund, &lo, &hi) < 0 {
			// No IAudioClient3: only the default period is possible.
			default_period, min_period: w.REFERENCE_TIME
			e.client.vtbl.GetDevicePeriod(e.client, &default_period, &min_period)
			if int(f64(default_period) * f64(mix.nSamplesPerSec) / 1e7 + 0.5) != period do return .Unsupported
			hr = e.client.vtbl.Initialize(e.client, .SHARED, flags, 0, 0, mix, nil)
		} else {
			p := w.UINT(period)
			if p < lo || p > hi || fund == 0 || (p - lo) % fund != 0 do return .Unsupported
			hr = e.client.vtbl.InitializeSharedAudioStream(e.client, flags, p, mix, nil)
		}
	} else {
		hr = e.client.vtbl.Initialize(e.client, .SHARED, flags, 0, 0, mix, nil)
	}
	if hr < 0 {
		intrinsics.atomic_store(&a.last_error, i64(hr))
		return .Device_Error
	}

	frames: w.UINT
	e.client.vtbl.GetBufferSize(e.client, &frames)
	e.buffer_frames = int(frames)
	current: w.UINT
	cur_fmt: ^w.WAVEFORMATEX
	if has3 && e.client.vtbl.GetCurrentSharedModeEnginePeriod(e.client, &cur_fmt, &current) >= 0 {
		win.CoTaskMemFree(cur_fmt)
		e.period_frames = int(current)
	} else {
		default_period, min_period: w.REFERENCE_TIME
		e.client.vtbl.GetDevicePeriod(e.client, &default_period, &min_period)
		e.period_frames = int(f64(default_period) * f64(mix.nSamplesPerSec) / 1e7 + 0.5)
	}
	latency: w.REFERENCE_TIME
	e.client.vtbl.GetStreamLatency(e.client, &latency)
	e.latency_ns = u64(latency) * 100

	e.event = win.CreateEventW(nil, false, false, nil)
	if e.event == nil || e.client.vtbl.SetEventHandle(e.client, e.event) < 0 do return .Device_Error
	if flow == .eRender {
		if e.client.vtbl.GetService(e.client, &w.IID_IAudioRenderClient, (^rawptr)(&e.render)) < 0 do return .Device_Error
	} else {
		if e.client.vtbl.GetService(e.client, &w.IID_IAudioCaptureClient, (^rawptr)(&e.capture)) < 0 do return .Device_Error
	}
	return .None
}

// Shared-mode mix formats are float32 almost everywhere. WASAPI's 24-in-32 PCM
// is left-justified, so it reads exactly like 32-bit PCM.
@(private)
sample_format :: proc(f: ^w.WAVEFORMATEX) -> (backend.Sample_Format, bool) {
	tag := f.wFormatTag
	if tag == w.WAVE_FORMAT_EXTENSIBLE {
		ext := (^w.WAVEFORMATEXTENSIBLE)(f)
		if ext.SubFormat == w.KSDATAFORMAT_SUBTYPE_IEEE_FLOAT do tag = w.WAVE_FORMAT_IEEE_FLOAT
		else if ext.SubFormat == w.KSDATAFORMAT_SUBTYPE_PCM do tag = w.WAVE_FORMAT_PCM
	}
	switch {
	case tag == w.WAVE_FORMAT_IEEE_FLOAT && f.wBitsPerSample == 32: return .F32, true
	case tag == w.WAVE_FORMAT_IEEE_FLOAT && f.wBitsPerSample == 64: return .F64, true
	case tag == w.WAVE_FORMAT_PCM && f.wBitsPerSample == 16:        return .I16, true
	case tag == w.WAVE_FORMAT_PCM && f.wBitsPerSample == 24:        return .I24, true
	case tag == w.WAVE_FORMAT_PCM && f.wBitsPerSample == 32:        return .I32, true
	}
	return .F32, false
}

@(private)
mix_rate :: proc(e: ^Endpoint) -> f64 {
	mix: ^w.WAVEFORMATEX
	if e.client.vtbl.GetMixFormat(e.client, &mix) < 0 do return 0
	defer win.CoTaskMemFree(mix)
	return f64(mix.nSamplesPerSec)
}

@(private)
alloc_buffers :: proc(a: ^Wasapi) -> (err: mem.Allocator_Error) {
	if a.in_.client != nil {
		a.ring_frames = 8 * max(a.in_.buffer_frames, a.out.buffer_frames, 1024)
		a.ring = make([]u8, a.ring_frames * a.in_.frame_bytes, a.allocator) or_return
		a.scratch = make([]u8, a.ring_frames * a.in_.frame_bytes, a.allocator) or_return
	}
	return nil
}

@(private)
close_endpoint :: proc(e: ^Endpoint) {
	w.release(e.render)
	w.release(e.capture)
	w.release(e.client)
	w.release(e.device)
	if e.event != nil do win.CloseHandle(e.event)
	e^ = {}
}

@(private)
close_endpoints :: proc(a: ^Wasapi) {
	close_endpoint(&a.out)
	close_endpoint(&a.in_)
	delete(a.ring, a.allocator)
	delete(a.scratch, a.allocator)
	a.ring, a.scratch = nil, nil
}

@(private)
wasapi_close :: proc(d: ^backend.Driver) {
	a := (^Wasapi)(d.data)
	if !a.is_open do return
	close_endpoints(a)
	win.AcquireSRWLockExclusive(&a.ids_lock)
	delete(a.out_id, a.allocator)
	delete(a.in_id, a.allocator)
	a.out_id, a.in_id = "", ""
	win.ReleaseSRWLockExclusive(&a.ids_lock)
	a.is_open = false
}

// --- start / stop --------------------------------------------------------------------------

@(private)
wasapi_start :: proc(d: ^backend.Driver) -> core.Error {
	a := (^Wasapi)(d.data)
	if !a.is_open || a.thread != nil do return .Invalid_State
	intrinsics.atomic_store(&a.stop_flag, false)
	a.xrun_pending, a.lost = false, false
	// Input cushion (see CUSHION_PERIODS): keeps render fed when a capture
	// packet lands just after a render wake.
	a.ring_head, a.ring_len, a.ring_timed = 0, 0, false
	if a.in_.client != nil {
		a.ring_len = min(CUSHION_PERIODS * a.in_.period_frames, a.ring_frames / 2)
		intrinsics.mem_zero(raw_data(a.ring), a.ring_len * a.in_.frame_bytes)
	}
	a.last_output_ns, a.last_frames = 0, 0
	intrinsics.atomic_store(&a.min_padding, max(i64))
	intrinsics.atomic_store(&a.min_ring, max(i64))
	// Prefill the whole render buffer with silence. Each cycle renders only as
	// many frames as capture has delivered, and capture needs a few periods
	// to get going; with less cushion the first cycles underrun and the
	// endpoint plays a gap (seen as a dropout ~1000 frames in on VB-CABLE).
	if a.out.client != nil {
		a.out.client.vtbl.Reset(a.out.client)
		data: [^]u8
		fill := w.UINT(a.out.buffer_frames)
		if a.out.render.vtbl.GetBuffer(a.out.render, fill, &data) >= 0 {
			a.out.render.vtbl.ReleaseBuffer(a.out.render, fill, w.AUDCLNT_BUFFERFLAGS_SILENT)
		}
	}
	if a.in_.client != nil {
		a.in_.client.vtbl.Reset(a.in_.client)
		if a.in_.client.vtbl.Start(a.in_.client) < 0 do return .Device_Error
	}
	if a.out.client != nil && a.out.client.vtbl.Start(a.out.client) < 0 {
		if a.in_.client != nil do a.in_.client.vtbl.Stop(a.in_.client)
		return .Device_Error
	}
	a.thread = thread.create_and_start_with_data(a, audio_thread)
	return .None if a.thread != nil else .Device_Error
}

// The thread waits at most 100 ms per wake, so this returns promptly.
@(private)
wasapi_stop :: proc(d: ^backend.Driver) {
	a := (^Wasapi)(d.data)
	if a.thread == nil do return
	intrinsics.atomic_store(&a.stop_flag, true)
	thread.join(a.thread)
	thread.destroy(a.thread)
	a.thread = nil
	if a.out.client != nil do a.out.client.vtbl.Stop(a.out.client)
	if a.in_.client != nil do a.in_.client.vtbl.Stop(a.in_.client)
}

// --- audio thread ------------------------------------------------------------------------------

@(private)
audio_thread :: proc(data: rawptr) {
	a := (^Wasapi)(data)
	win.CoInitializeEx(nil, .MULTITHREADED)
	defer win.CoUninitialize()
	task_index: w.DWORD
	mmcss := w.AvSetMmThreadCharacteristicsW(win.L("Pro Audio"), &task_index)
	intrinsics.atomic_store(&a.mmcss, mmcss != nil)
	defer if mmcss != nil do w.AvRevertMmThreadCharacteristics(mmcss)

	ns_per_frame := 1e9 / a.format.sample_rate
	wake := a.out.event if a.out.client != nil else a.in_.event
	for !intrinsics.atomic_load(&a.stop_flag) {
		if win.WaitForSingleObject(wake, 100) != win.WAIT_OBJECT_0 do continue
		if a.lost do continue
		if a.in_.client != nil {
			if hr := drain_capture(a, ns_per_frame); hr < 0 {
				fail(a, hr)
				continue
			}
		}
		frames := a.ring_len
		padding: w.UINT
		if a.out.client != nil {
			if hr := a.out.client.vtbl.GetCurrentPadding(a.out.client, &padding); hr < 0 {
				fail(a, hr)
				continue
			}
			if i64(padding) < intrinsics.atomic_load(&a.min_padding) do intrinsics.atomic_store(&a.min_padding, i64(padding))
			if a.in_.client != nil && i64(a.ring_len) < intrinsics.atomic_load(&a.min_ring) do intrinsics.atomic_store(&a.min_ring, i64(a.ring_len))
			space := a.out.buffer_frames - int(padding)
			if a.in_.client == nil {
				frames = space
			} else if a.ring_len >= space || int(padding) >= a.out.period_frames {
				frames = min(a.ring_len, space)
			} else {
				// Render is about to run dry and capture is behind: keep the
				// output going and fill the missing input with silence.
				frames = space
				a.xrun_pending = true
			}
		}
		if frames <= 0 do continue
		cycle(a, frames, int(padding), ns_per_frame)
	}
}

// [rt] One callback of `frames`, render buffer and input FIFO permitting.
@(private)
cycle :: proc(a: ^Wasapi, frames, padding: int, ns_per_frame: f64) {
	now := rt.host_time_ns()
	buf := backend.Driver_Buffers {
		frames      = frames,
		callback_ns = now,
		xrun        = a.xrun_pending,
	}
	a.xrun_pending = false

	if a.in_.client != nil {
		buf.input_ns = u64(a.ring_head_ns)
		pop_ring(a, frames, ns_per_frame)
		a.in_planes[0] = {raw_data(a.scratch), a.in_.channels}
		buf.input = a.in_planes[:]
	}
	out_data: [^]u8
	if a.out.client != nil {
		if hr := a.out.render.vtbl.GetBuffer(a.out.render, w.UINT(frames), &out_data); hr < 0 {
			fail(a, hr)
			return
		}
		// Heard after the frames already queued. Kept monotonic: a reading
		// earlier than the end of the previous block is clamped to it.
		measured := f64(now) + f64(padding) * ns_per_frame
		earliest := a.last_output_ns + f64(a.last_frames) * ns_per_frame
		if a.last_frames > 0 && measured < earliest do measured = earliest
		a.last_output_ns, a.last_frames = measured, frames
		buf.output_ns = u64(measured)
		a.out_planes[0] = {out_data, a.out.channels}
		buf.output = a.out_planes[:]
	}
	backend.driver_process(a.driver.host, &buf)
	if a.out.client != nil {
		if hr := a.out.render.vtbl.ReleaseBuffer(a.out.render, w.UINT(frames), 0); hr < 0 do fail(a, hr)
	}
}

// [rt] Moves every available capture packet into the FIFO.
@(private)
drain_capture :: proc(a: ^Wasapi, ns_per_frame: f64) -> w.HRESULT {
	c := a.in_.capture
	for {
		next: w.UINT
		if hr := c.vtbl.GetNextPacketSize(c, &next); hr < 0 do return hr
		if next == 0 do return w.S_OK
		data: [^]u8
		frames, flags: w.UINT
		flags_dw: w.DWORD
		dev_pos, qpc_pos: u64
		if hr := c.vtbl.GetBuffer(c, &data, &frames, &flags_dw, &dev_pos, &qpc_pos); hr < 0 do return hr
		_ = flags
		if flags_dw & w.AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY != 0 && dev_pos > 0 do a.xrun_pending = true
		// QPC in 100-ns units, the same clock as rt.host_time_ns. The first
		// packet dates whatever is already queued (the cushion) as well.
		if a.ring_len == 0 || !a.ring_timed {
			a.ring_head_ns = f64(qpc_pos) * 100 - f64(a.ring_len) * ns_per_frame
			a.ring_timed = true
		}
		push_ring(a, data, int(frames), flags_dw & w.AUDCLNT_BUFFERFLAGS_SILENT != 0, ns_per_frame)
		c.vtbl.ReleaseBuffer(c, frames)
	}
}

// [rt]
@(private)
push_ring :: proc(a: ^Wasapi, data: [^]u8, frames: int, silent: bool, ns_per_frame: f64) {
	fb := a.in_.frame_bytes
	if a.ring_len + frames > a.ring_frames {
		// Overflow: render stalled. Drop the oldest frames and flag an xrun.
		drop := a.ring_len + frames - a.ring_frames
		a.ring_head = (a.ring_head + drop) % a.ring_frames
		a.ring_len -= drop
		a.ring_head_ns += f64(drop) * ns_per_frame
		a.xrun_pending = true
	}
	tail := (a.ring_head + a.ring_len) % a.ring_frames
	for i in 0 ..< frames {
		dst := a.ring[((tail + i) % a.ring_frames) * fb:][:fb]
		if silent do intrinsics.mem_zero(raw_data(dst), fb)
		else do intrinsics.mem_copy_non_overlapping(raw_data(dst), &data[i * fb], fb)
	}
	a.ring_len += frames
}

// [rt] Copies `frames` from the FIFO into scratch.
@(private)
pop_ring :: proc(a: ^Wasapi, frames: int, ns_per_frame: f64) {
	fb := a.in_.frame_bytes
	have := min(frames, a.ring_len) // any shortfall is filled with silence
	first := min(have, a.ring_frames - a.ring_head)
	intrinsics.mem_copy_non_overlapping(raw_data(a.scratch), &a.ring[a.ring_head * fb], first * fb)
	if have > first do intrinsics.mem_copy_non_overlapping(&a.scratch[first * fb], raw_data(a.ring), (have - first) * fb)
	if frames > have do intrinsics.mem_zero(&a.scratch[have * fb], (frames - have) * fb)
	a.ring_head = (a.ring_head + have) % a.ring_frames
	a.ring_len -= have
	a.ring_head_ns += f64(frames) * ns_per_frame
}

// Device gone: report it and idle until stopped. Anything else: count it and
// flag the next block. (driver_notify takes a mutex; acceptable here because
// the stream is already broken.)
@(private)
fail :: proc(a: ^Wasapi, hr: w.HRESULT) {
	intrinsics.atomic_store(&a.last_error, i64(hr))
	if hr == w.AUDCLNT_E_DEVICE_INVALIDATED {
		a.lost = true
		backend.driver_notify(a.driver.host, {kind = .Device_Lost})
		return
	}
	a.xrun_pending = true
}

// --- helpers --------------------------------------------------------------------------------

@(private)
device_id :: proc(dev: ^w.IMMDevice, allocator: mem.Allocator) -> string {
	wid: win.wstring
	if dev.vtbl.GetId(dev, &wid) < 0 do return ""
	defer win.CoTaskMemFree(rawptr(wid))
	s, _ := win.wstring_to_utf8(wid, -1, allocator)
	return s
}

@(private)
default_endpoint_id :: proc(a: ^Wasapi, flow: w.EDataFlow) -> string {
	dev: ^w.IMMDevice
	if a.enumerator.vtbl.GetDefaultAudioEndpoint(a.enumerator, flow, .eConsole, &dev) < 0 do return ""
	defer w.release(dev)
	return device_id(dev, context.temp_allocator)
}

@(private)
friendly_name :: proc(dev: ^w.IMMDevice, allocator: mem.Allocator) -> string {
	store: ^w.IPropertyStore
	if dev.vtbl.OpenPropertyStore(dev, w.STGM_READ, &store) < 0 do return ""
	defer w.release(store)
	v: w.PROPVARIANT
	if store.vtbl.GetValue(store, &w.PKEY_Device_FriendlyName, &v) < 0 do return ""
	defer win.PropVariantClear((^win.PROPVARIANT)(&v))
	if v.vt != w.VT_LPWSTR do return ""
	s, _ := win.wstring_to_utf8(win.wstring(rawptr(uintptr(v.data[0]))), -1, allocator)
	return s
}

// Endpoints of one physical device share a container ID.
@(private)
same_container :: proc(a, b: ^w.IMMDevice) -> bool {
	container :: proc(dev: ^w.IMMDevice) -> (id: w.GUID, ok: bool) {
		store: ^w.IPropertyStore
		if dev.vtbl.OpenPropertyStore(dev, w.STGM_READ, &store) < 0 do return
		defer w.release(store)
		v: w.PROPVARIANT
		if store.vtbl.GetValue(store, &w.PKEY_Device_ContainerId, &v) < 0 do return
		defer win.PropVariantClear((^win.PROPVARIANT)(&v))
		if v.vt != w.VT_CLSID || v.data[0] == 0 do return
		return (^w.GUID)(uintptr(v.data[0]))^, true
	}
	ida, oka := container(a)
	idb, okb := container(b)
	return oka && okb && ida == idb
}
