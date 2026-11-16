/*
The app layer's driver for control surfaces' USB and HID devices
(app/core's `Device_Driver`): USB bulk through libusb (vendor/libusb,
built by `task deps:libusb`), HID through the hidapi in SDL3.

	drv := devices.create()
	pa.surfaces_start(&api, {folder}, devices = drv)
	...
	pa.surfaces_stop(&api)
	drv.destroy(drv)

Built with -define:FIRE_LIBUSB=false (no libusb): USB bulk devices aren't
opened (HID still is).

Per platform:
- macOS: no driver needed for either.
- Linux: a user opens USB devices only with a udev rule granting it
  (docs/guides/surfaces.md); the kernel's driver on the interface is
  detached while it's open.
- Windows: a USB bulk interface needs the WinUSB driver bound (Push 2's
  display has it).
*/
package devices

import "core:c"
import "core:fmt"
import "core:sync"

import app "app:core"
import usb "deps:libusb"
import sdl "deps:sdl3"

@(private)
Driver :: struct {
	using driver: app.Device_Driver,
	mutex:        sync.Mutex, // (opening: one at a time)
	usb:          ^usb.Context,
	usb_ok:       bool,
	hid_ok:       bool,
}

@(private)
Handle :: struct {
	hid:       ^sdl.hid_device,
	dev:       ^usb.Device_Handle,
	interface: c.int,
	ep_out:    u8,
	ep_in:     u8,
}

// A driver opening USB bulk devices (libusb) and HID devices (SDL's
// hidapi). Free with its `destroy`, after the surfaces are stopped.
create :: proc() -> ^app.Device_Driver {
	d := new(Driver)
	d.name = "libusb + hidapi" when usb.AVAILABLE else "hidapi"
	when usb.AVAILABLE do d.usb_ok = usb.init(&d.usb) == 0
	d.hid_ok = sdl.hid_init() == 0
	d.open = open
	d.write = write
	d.read = read
	d.close = close
	d.destroy = proc(drv: ^app.Device_Driver) {
		d := (^Driver)(drv)
		when usb.AVAILABLE do if d.usb_ok do usb.exit(d.usb)
		if d.hid_ok do _ = sdl.hid_exit()
		free(d)
	}
	return d
}

@(private)
open :: proc(drv: ^app.Device_Driver, want: app.Device_Want) -> (rawptr, string) {
	d := (^Driver)(drv)
	sync.mutex_lock(&d.mutex)
	defer sync.mutex_unlock(&d.mutex)
	switch want.transport {
	case .Usb_Bulk:
		when usb.AVAILABLE {
			return open_usb(d, want)
		} else {
			return nil, "USB bulk devices need libusb (task deps:libusb)"
		}
	case .Hid:
		return open_hid(d, want)
	}
	return nil, ""
}

when usb.AVAILABLE {
	@(private)
	open_usb :: proc(d: ^Driver, want: app.Device_Want) -> (rawptr, string) {
		if !d.usb_ok do return nil, "libusb didn't start"
		list: [^]^usb.Device
		n := usb.get_device_list(d.usb, &list)
		if n < 0 do return nil, ""
		defer usb.free_device_list(list, 1)
		why := ""
		for i in 0 ..< n {
			desc: usb.Device_Descriptor
			if usb.get_device_descriptor(list[i], &desc) != 0 do continue
			if desc.idVendor != want.vendor_id || desc.idProduct != want.product_id do continue
			h: ^usb.Device_Handle
			if r := usb.open(list[i], &h); r != 0 {
				why = fmt.tprintf("USB %04X:%04X won't open (%s)", want.vendor_id, want.product_id, usb.error_name(r))
				continue
			}
			iface := c.int(max(want.interface, 0))
			usb.set_auto_detach_kernel_driver(h, 1) // (Linux; not supported elsewhere)
			if r := usb.claim_interface(h, iface); r != 0 {
				why = fmt.tprintf("USB %04X:%04X's interface %d is taken (%s)", want.vendor_id, want.product_id, iface, usb.error_name(r))
				usb.close(h)
				continue
			}
			out := new(Handle)
			out^ = {dev = h, interface = iface, ep_out = want.endpoint_out, ep_in = want.endpoint_in}
			return out, ""
		}
		return nil, why
	}
}

@(private)
open_hid :: proc(d: ^Driver, want: app.Device_Want) -> (rawptr, string) {
	if !d.hid_ok do return nil, "hidapi didn't start"
	devs := sdl.hid_enumerate(want.vendor_id, want.product_id)
	defer sdl.hid_free_enumeration(devs)
	for e := devs; e != nil; e = e.next {
		if want.usage_page != 0 && e.usage_page != want.usage_page do continue
		if want.usage != 0 && e.usage != want.usage do continue
		if want.interface >= 0 && e.interface_number != c.int(want.interface) do continue
		h := sdl.hid_open_path(cstring(e.path))
		if h == nil do return nil, fmt.tprintf("HID %04X:%04X won't open", want.vendor_id, want.product_id)
		out := new(Handle)
		out.hid = h
		return out, ""
	}
	return nil, ""
}

@(private)
write :: proc(drv: ^app.Device_Driver, handle: rawptr, bytes: []u8) -> app.Device_Io {
	h := (^Handle)(handle)
	if h.hid != nil {
		return .Ok if sdl.hid_write(h.hid, raw_data(bytes), uint(len(bytes))) >= 0 else .Gone
	}
	when usb.AVAILABLE {
		sent: c.int
		r := usb.bulk_transfer(h.dev, h.ep_out, raw_data(bytes), c.int(len(bytes)), &sent, 1000)
		return io_of(r)
	} else {
		return .Failed
	}
}

@(private)
read :: proc(drv: ^app.Device_Driver, handle: rawptr, buf: []u8, timeout_ms: int) -> (int, app.Device_Io) {
	h := (^Handle)(handle)
	if h.hid != nil {
		n := sdl.hid_read_timeout(h.hid, raw_data(buf), uint(len(buf)), c.int(timeout_ms))
		if n < 0 do return 0, .Gone
		return int(n), .Ok if n > 0 else .Timeout
	}
	when usb.AVAILABLE {
		if h.ep_in == 0 do return 0, .Timeout
		got: c.int
		r := usb.bulk_transfer(h.dev, h.ep_in, raw_data(buf), c.int(len(buf)), &got, c.uint(timeout_ms))
		if r == usb.ERROR_TIMEOUT && got > 0 do return int(got), .Ok
		return int(got), io_of(r)
	} else {
		return 0, .Failed
	}
}

@(private)
close :: proc(drv: ^app.Device_Driver, handle: rawptr) {
	h := (^Handle)(handle)
	if h.hid != nil {
		_ = sdl.hid_close(h.hid)
	} else {
		when usb.AVAILABLE {
			usb.release_interface(h.dev, h.interface)
			usb.close(h.dev)
		}
	}
	free(h)
}

when usb.AVAILABLE {
	@(private)
	io_of :: proc(r: c.int) -> app.Device_Io {
		switch r {
		case usb.SUCCESS: return .Ok
		case usb.ERROR_TIMEOUT: return .Timeout
		case usb.ERROR_NO_DEVICE, usb.ERROR_IO, usb.ERROR_NOT_FOUND: return .Gone
		}
		return .Failed
	}
}
