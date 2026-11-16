package app

import "base:intrinsics"
import "base:runtime"
import "core:sync"
import "core:thread"
import "core:time"

import abi "fsurf:abi"
import fsurf "fsurf:host"

/*
A control surface's devices other than MIDI: a display over USB bulk (Push
2's), HID. A `Device_Driver` opens and talks to them (app/devices: libusb
and SDL's hidapi; `devices_fake_create` for tests). Each device a surface
opens gets a thread of its own:

- **Writes** (`device_write`, on the surface thread) are copied into its
  queue and written there, so a slow transfer never holds up the surface
  thread. While more than DEVICE_QUEUE_LIMIT bytes wait, a write is
  dropped (a display sends its next frame whole).
- **Reads** (an IN endpoint, an HID report) are read there and handed to
  the surface on the surface thread (`surfaces_update`).
- **Unplugged:** a write or read finds it gone; it's tried again every
  second, and the surface is told when it goes and comes back
  (`instance_device_state`): a display then sends a whole frame.

The driver's procedures are called from the devices' threads, several at
once (each with its own handle).
*/

// How a driver's write or read went.
Device_Io :: enum {
	Ok,
	Timeout, // nothing (a read), or not taken in time (a write)
	Gone,    // unplugged: close it, and open it again later
	Failed,  // another error
}

// Opens and talks to devices (USB bulk, HID). Its procedures are called
// from the devices' threads.
Device_Driver :: struct {
	// The device `spec` names, opened (its interface claimed): a handle, or
	// nil if it isn't there or won't open (`why`, for the log).
	open:    proc(d: ^Device_Driver, spec: Device_Want) -> (handle: rawptr, why: string),
	write:   proc(d: ^Device_Driver, handle: rawptr, bytes: []u8) -> Device_Io,
	// Waits up to `timeout_ms` for what the device sends: bytes read into `buf`.
	read:    proc(d: ^Device_Driver, handle: rawptr, buf: []u8, timeout_ms: int) -> (int, Device_Io),
	close:   proc(d: ^Device_Driver, handle: rawptr),
	destroy: proc(d: ^Device_Driver),
	name:    string, // for the log ("libusb + hidapi", "fake")
	user:    rawptr,
}

// The device a surface asks for (abi.Device_Spec, copied).
Device_Want :: struct {
	transport:             abi.Device_Transport,
	vendor_id, product_id: u16,
	interface:             i32, // -1 = any
	endpoint_out:          u8,
	endpoint_in:           u8,
	usage_page, usage:     u16,
}

// What crosses threads (writes, reads, events) is on the heap, the same
// allocator on every thread.
@(private)
HEAP :: proc() -> runtime.Allocator { return runtime.heap_allocator() }

// Bytes a device's queue holds before writes are dropped (about six of
// Push 2's frames).
DEVICE_QUEUE_LIMIT :: 2 << 20

// The most bytes a device's read gives at once.
DEVICE_READ_SIZE :: 1024

// A device a surface opened.
@(private)
Open_Device :: struct {
	s:        ^Surfaces,
	inst:     ^fsurf.Instance,
	index:    int,
	want:     Device_Want,
	thread:   ^thread.Thread,
	mutex:    sync.Mutex,
	cond:     sync.Cond,
	writes:   [dynamic][]u8, // waiting (owned)
	queued:   int, // their bytes
	quit:     bool,
	present:  bool, // atomic: open now (writes go through)
	dropped:  int, // atomic: writes dropped (queue full, or gone)
	handle:   rawptr, // the thread's
}

@(private)
Device_Event_Kind :: enum u8 {
	Opened, // came back
	Gone,
	Read,
	Failing, // writes started failing (Timeout or Failed): once, until one goes through
}

@(private)
Device_Event :: struct {
	dev:   ^Open_Device,
	kind:  Device_Event_Kind,
	bytes: []u8, // Read (owned)
	io:    Device_Io, // Failing: how
}

@(private)
want_of :: proc(spec: ^abi.Device_Spec) -> Device_Want {
	return {
		transport = spec.transport, vendor_id = spec.vendor_id, product_id = spec.product_id, interface = spec.interface,
		endpoint_out = spec.endpoint_out, endpoint_in = spec.endpoint_in, usage_page = spec.usage_page, usage = spec.usage,
	}
}

// Surface thread (the host's device_open): opens it now if it's there; its
// thread keeps trying if it isn't.
@(private)
device_open :: proc(s: ^Surfaces, inst: ^fsurf.Instance, index: int, spec: ^abi.Device_Spec) -> bool {
	drv := s.config.devices
	if drv == nil do return false
	d := new(Open_Device, HEAP())
	d^ = {s = s, inst = inst, index = index, want = want_of(spec)}
	d.writes = make([dynamic][]u8, HEAP())
	h, why := drv.open(drv, d.want)
	d.handle = h
	d.present = h != nil
	if h == nil && why != "" do fsurf.log_add(&s.fs, inst, .Info, why)
	append(&s.devices, d)
	d.thread = thread.create_and_start_with_poly_data(d, device_thread)
	return h != nil
}

@(private)
device_find :: proc(s: ^Surfaces, inst: ^fsurf.Instance, index: int) -> (^Open_Device, int) {
	for d, i in s.devices do if d.inst == inst && d.index == index do return d, i
	return nil, -1
}

// Surface thread (the host's device_write): queued for its thread.
@(private)
device_write :: proc(s: ^Surfaces, inst: ^fsurf.Instance, index: int, bytes: []u8) -> bool {
	d, _ := device_find(s, inst, index)
	if d == nil || len(bytes) == 0 do return false
	if !intrinsics.atomic_load(&d.present) {
		intrinsics.atomic_add(&d.dropped, 1)
		return false
	}
	sync.mutex_lock(&d.mutex)
	defer sync.mutex_unlock(&d.mutex)
	if d.queued + len(bytes) > DEVICE_QUEUE_LIMIT {
		intrinsics.atomic_add(&d.dropped, 1)
		return false
	}
	b := make([]u8, len(bytes), HEAP())
	copy(b, bytes)
	append(&d.writes, b)
	d.queued += len(b)
	sync.cond_signal(&d.cond)
	return true
}

// Surface thread (the host's device_close): its thread stopped, the device
// closed.
@(private)
device_close :: proc(s: ^Surfaces, inst: ^fsurf.Instance, index: int) {
	d, i := device_find(s, inst, index)
	if d == nil do return
	ordered_remove(&s.devices, i)
	device_stop(s, d)
}

@(private)
device_stop :: proc(s: ^Surfaces, d: ^Open_Device) {
	sync.mutex_lock(&d.mutex)
	d.quit = true
	sync.cond_signal(&d.cond)
	sync.mutex_unlock(&d.mutex)
	thread.join(d.thread)
	thread.destroy(d.thread)
	// Its events not yet handed on.
	sync.mutex_lock(&s.device_mutex)
	for i := len(s.device_events) - 1; i >= 0; i -= 1 do if s.device_events[i].dev == d {
		delete(s.device_events[i].bytes, HEAP())
		ordered_remove(&s.device_events, i)
	}
	sync.mutex_unlock(&s.device_mutex)
	for w in d.writes do delete(w, HEAP())
	delete(d.writes)
	free(d, HEAP())
}

// Surface thread: what the devices' threads saw, to the surfaces.
@(private)
devices_update :: proc(s: ^Surfaces) {
	sync.mutex_lock(&s.device_mutex)
	events := s.device_events
	s.device_events = make([dynamic]Device_Event, HEAP())
	sync.mutex_unlock(&s.device_mutex)
	defer delete(events)
	for e in events {
		defer delete(e.bytes, HEAP())
		switch e.kind {
		case .Opened:
			fsurf.log_add(&s.fs, e.dev.inst, .Info, "its device is back")
			fsurf.instance_device_state(e.dev.inst, e.dev.index, true)
		case .Gone:
			fsurf.log_add(&s.fs, e.dev.inst, .Warning, "its device went away")
			fsurf.instance_device_state(e.dev.inst, e.dev.index, false)
		case .Read:
			fsurf.instance_device_read(e.dev.inst, e.dev.index, e.bytes)
		case .Failing:
			fsurf.log_add(&s.fs, e.dev.inst, .Warning, "writes to its device are failing (timed out)" if e.io == .Timeout else "writes to its device are failing")
		}
	}
}

// Surface thread: every device closed (the host gone).
@(private)
devices_stop_all :: proc(s: ^Surfaces) {
	for d in s.devices do device_stop(s, d)
	clear(&s.devices)
	sync.mutex_lock(&s.device_mutex)
	for e in s.device_events do delete(e.bytes, HEAP())
	clear(&s.device_events)
	sync.mutex_unlock(&s.device_mutex)
}

@(private)
device_event :: proc(d: ^Open_Device, kind: Device_Event_Kind, bytes: []u8 = nil, io := Device_Io.Ok) {
	s := d.s
	sync.mutex_lock(&s.device_mutex)
	append(&s.device_events, Device_Event{dev = d, kind = kind, bytes = bytes, io = io})
	sync.mutex_unlock(&s.device_mutex)
}

// A device's own thread: its writes, its reads, and opening it again.
@(private)
device_thread :: proc(d: ^Open_Device) {
	drv := d.s.config.devices
	reads := d.want.transport == .Hid || d.want.endpoint_in != 0
	buf: [DEVICE_READ_SIZE]u8
	local := make([dynamic][]u8, HEAP())
	defer delete(local)
	last_try: time.Tick
	failing := false
	for {
		sync.mutex_lock(&d.mutex)
		if d.quit {
			sync.mutex_unlock(&d.mutex)
			break
		}
		// Nothing to do: wait for a write (or, while gone, to try again).
		if len(d.writes) == 0 && (!reads || d.handle == nil) {
			sync.cond_wait_with_timeout(&d.cond, &d.mutex, 100 * time.Millisecond)
		}
		for w in d.writes do append(&local, w)
		clear(&d.writes)
		d.queued = 0
		quit := d.quit
		sync.mutex_unlock(&d.mutex)
		if quit {
			for w in local do delete(w, HEAP())
			break
		}
		if d.handle == nil {
			for w in local do delete(w, HEAP())
			clear(&local)
			if time.tick_since(last_try) < time.Second do continue
			last_try = time.tick_now()
			h, _ := drv.open(drv, d.want)
			if h == nil do continue
			d.handle = h
			intrinsics.atomic_store(&d.present, true)
			device_event(d, .Opened)
			continue
		}
		gone := false
		for w in local {
			if !gone {
				switch r := drv.write(drv, d.handle, w); r {
				case .Ok: failing = false
				case .Gone: gone = true
				case .Timeout, .Failed:
					if !failing do device_event(d, .Failing, io = r)
					failing = true
				}
			}
			delete(w, HEAP())
		}
		clear(&local)
		if !gone && reads {
			n, r := drv.read(drv, d.handle, buf[:], 10)
			if r == .Gone do gone = true
			else if r == .Ok && n > 0 {
				b := make([]u8, n, HEAP())
				copy(b, buf[:n])
				device_event(d, .Read, b)
			}
		}
		if gone {
			intrinsics.atomic_store(&d.present, false)
			drv.close(drv, d.handle)
			d.handle = nil
			last_try = time.tick_now()
			device_event(d, .Gone)
		}
	}
	if d.handle != nil do drv.close(drv, d.handle)
	d.handle = nil
}
