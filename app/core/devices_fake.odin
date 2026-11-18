package app

import "core:strings"
import "core:sync"
import "core:time"

/*
Pretend USB and HID devices, for tests and scripted runs (Pads'
--fake-usb): plugged in and out by id, what they send given to them, what
was written to them kept.

	drv := devices_fake_create()
	devices_fake_plug(drv, "push", 0x2982, 0x1967)
	surfaces_init(&s, &host, {devices = drv, ...})
	...
	n, writes := devices_fake_written(drv, "push")
	devices_fake_destroy(drv)
*/

// A pretend device.
@(private)
Fake_Device :: struct {
	id:                    string, // owned
	vendor_id, product_id: u16,
	hid:                   bool,
	usage_page:            u16,
	plugged:               bool,
	opened:                int, // handles open on it
	written:               int, // bytes
	writes:                int,
	recent:                [dynamic]u8, // the newest bytes written (FAKE_RECENT or more)
	reads:                 [dynamic][]u8, // what it sends, waiting (owned)
}

@(private)
Fake_Devices :: struct {
	using driver: Device_Driver,
	mutex:        sync.Mutex,
	devices:      [dynamic]^Fake_Device,
}

// A handle: the device it opened.
@(private)
Fake_Handle :: struct {
	dev: ^Fake_Device,
}

// A driver of pretend devices (none plugged in); on the heap, as its
// devices' threads use it. Free with `devices_fake_destroy`.
devices_fake_create :: proc() -> ^Device_Driver {
	f := new(Fake_Devices, HEAP())
	f.devices = make([dynamic]^Fake_Device, HEAP())
	f.name = "fake"
	f.open = proc(d: ^Device_Driver, want: Device_Want) -> (rawptr, string) {
		f := (^Fake_Devices)(d)
		sync.mutex_lock(&f.mutex)
		defer sync.mutex_unlock(&f.mutex)
		for v in f.devices do if v.plugged && v.vendor_id == want.vendor_id && v.product_id == want.product_id && v.hid == (want.transport == .Hid) {
			if want.transport == .Hid && want.usage_page != 0 && v.usage_page != want.usage_page do continue
			v.opened += 1
			h := new(Fake_Handle, HEAP())
			h.dev = v
			return h, ""
		}
		return nil, ""
	}
	f.write = proc(d: ^Device_Driver, handle: rawptr, bytes: []u8) -> Device_Io {
		f := (^Fake_Devices)(d)
		h := (^Fake_Handle)(handle)
		sync.mutex_lock(&f.mutex)
		defer sync.mutex_unlock(&f.mutex)
		if !h.dev.plugged do return .Gone
		h.dev.written += len(bytes)
		h.dev.writes += 1
		append(&h.dev.recent, ..bytes)
		if n := len(h.dev.recent); n > 2 * FAKE_RECENT { // (the oldest let go)
			copy(h.dev.recent[:], h.dev.recent[n - FAKE_RECENT:])
			resize(&h.dev.recent, FAKE_RECENT)
		}
		return .Ok
	}
	f.read = proc(d: ^Device_Driver, handle: rawptr, buf: []u8, timeout_ms: int) -> (int, Device_Io) {
		f := (^Fake_Devices)(d)
		h := (^Fake_Handle)(handle)
		sync.mutex_lock(&f.mutex)
		if !h.dev.plugged {
			sync.mutex_unlock(&f.mutex)
			return 0, .Gone
		}
		if len(h.dev.reads) > 0 {
			r := h.dev.reads[0]
			ordered_remove(&h.dev.reads, 0)
			sync.mutex_unlock(&f.mutex)
			n := copy(buf, r)
			delete(r, HEAP())
			return n, .Ok
		}
		sync.mutex_unlock(&f.mutex)
		time.sleep(time.Duration(timeout_ms) * time.Millisecond)
		return 0, .Timeout
	}
	f.close = proc(d: ^Device_Driver, handle: rawptr) {
		f := (^Fake_Devices)(d)
		h := (^Fake_Handle)(handle)
		sync.mutex_lock(&f.mutex)
		h.dev.opened -= 1
		sync.mutex_unlock(&f.mutex)
		free(h, HEAP())
	}
	f.destroy = proc(d: ^Device_Driver) { devices_fake_destroy(d) }
	return f
}

// Frees a driver `devices_fake_create` made (after the surfaces are gone).
devices_fake_destroy :: proc(d: ^Device_Driver) {
	f := (^Fake_Devices)(d)
	for v in f.devices {
		for r in v.reads do delete(r, HEAP())
		delete(v.reads)
		delete(v.recent)
		delete(v.id, HEAP())
		free(v, HEAP())
	}
	delete(f.devices)
	free(f, HEAP())
}

@(private)
fake_find :: proc(f: ^Fake_Devices, id: string) -> ^Fake_Device {
	for v in f.devices do if v.id == id do return v
	return nil
}

// Plugs in a pretend device (again, if `id` was unplugged): USB bulk, or
// HID with `hid` (its usage page).
devices_fake_plug :: proc(d: ^Device_Driver, id: string, vendor_id, product_id: u16, hid := false, usage_page: u16 = 0) {
	f := (^Fake_Devices)(d)
	sync.mutex_lock(&f.mutex)
	defer sync.mutex_unlock(&f.mutex)
	v := fake_find(f, id)
	if v == nil {
		v = new(Fake_Device, HEAP())
		v.id = strings.clone(id, HEAP())
		v.recent = make([dynamic]u8, HEAP())
		v.reads = make([dynamic][]u8, HEAP())
		append(&f.devices, v)
	}
	v.vendor_id, v.product_id, v.hid, v.usage_page = vendor_id, product_id, hid, usage_page
	v.plugged = true
}

// Unplugs a pretend device: its handles' writes and reads find it gone.
devices_fake_unplug :: proc(d: ^Device_Driver, id: string) -> bool {
	f := (^Fake_Devices)(d)
	sync.mutex_lock(&f.mutex)
	defer sync.mutex_unlock(&f.mutex)
	v := fake_find(f, id)
	if v == nil do return false
	v.plugged = false
	return true
}

// What the device sends (an IN transfer, an HID report), read next.
devices_fake_send :: proc(d: ^Device_Driver, id: string, bytes: []u8) -> bool {
	f := (^Fake_Devices)(d)
	sync.mutex_lock(&f.mutex)
	defer sync.mutex_unlock(&f.mutex)
	v := fake_find(f, id)
	if v == nil do return false
	b := make([]u8, len(bytes), HEAP())
	copy(b, bytes)
	append(&v.reads, b)
	return true
}

// How much of what was written a pretend device keeps: at least a Push 2
// display's frame twice over.
FAKE_RECENT :: 1 << 20

// What was written to a pretend device: its bytes and writes in all, and
// the newest bytes written (at least FAKE_RECENT of them, or all; a copy in
// `allocator`).
devices_fake_written :: proc(d: ^Device_Driver, id: string, allocator := context.temp_allocator) -> (bytes, writes: int, recent: []u8, ok: bool) {
	f := (^Fake_Devices)(d)
	sync.mutex_lock(&f.mutex)
	defer sync.mutex_unlock(&f.mutex)
	v := fake_find(f, id)
	if v == nil do return
	l := make([]u8, len(v.recent), allocator)
	copy(l, v.recent[:])
	return v.written, v.writes, l, true
}

// Whether a pretend device is open (a surface has it).
devices_fake_open :: proc(d: ^Device_Driver, id: string) -> bool {
	f := (^Fake_Devices)(d)
	sync.mutex_lock(&f.mutex)
	defer sync.mutex_unlock(&f.mutex)
	v := fake_find(f, id)
	return v != nil && v.opened > 0
}
