/*
The part of libusb (libusb.info, LGPL-2.1+) the app layer uses for USB
devices: finding a device by its ids, opening it, claiming an interface,
bulk and interrupt transfers (synchronous, from a device's own thread).

The library is built by `scripts/libusb.sh` (`task deps:libusb`) into
lib/<os>_<arch>/; it isn't committed. Without it, build with
-define:FIRE_LIBUSB=false (app/devices then opens no USB bulk devices).
*/
package libusb

import "core:c"

_ :: c

FIRE_LIBUSB :: #config(FIRE_LIBUSB, true)

when !FIRE_LIBUSB {
	// (No library: nothing to link.)
} else when ODIN_OS == .Windows {
	foreign import lib {"lib/windows_x86_64/libusb.lib", "system:advapi32.lib", "system:ole32.lib"}
} else when ODIN_OS == .Darwin && ODIN_ARCH == .arm64 {
	foreign import lib {"lib/darwin_arm64/libusb.a", "system:IOKit.framework", "system:CoreFoundation.framework", "system:Security.framework"}
} else when ODIN_OS == .Darwin {
	foreign import lib {"lib/darwin_amd64/libusb.a", "system:IOKit.framework", "system:CoreFoundation.framework", "system:Security.framework"}
} else when ODIN_OS == .Linux && ODIN_ARCH == .arm64 {
	foreign import lib {"lib/linux_arm64/libusb.a", "system:pthread"}
} else {
	foreign import lib {"lib/linux_amd64/libusb.a", "system:pthread"}
}

Context :: struct {}
Device :: struct {}
Device_Handle :: struct {}

// libusb_device_descriptor.
Device_Descriptor :: struct {
	bLength:            u8,
	bDescriptorType:    u8,
	bcdUSB:             u16,
	bDeviceClass:       u8,
	bDeviceSubClass:    u8,
	bDeviceProtocol:    u8,
	bMaxPacketSize0:    u8,
	idVendor:           u16,
	idProduct:          u16,
	bcdDevice:          u16,
	iManufacturer:      u8,
	iProduct:           u8,
	iSerialNumber:      u8,
	bNumConfigurations: u8,
}

// libusb_error (the ones the app tells apart).
SUCCESS :: 0
ERROR_IO :: -1
ERROR_ACCESS :: -3
ERROR_NO_DEVICE :: -4
ERROR_NOT_FOUND :: -5
ERROR_BUSY :: -6
ERROR_TIMEOUT :: -7
ERROR_PIPE :: -9

when FIRE_LIBUSB {
	@(default_calling_convention = "c", link_prefix = "libusb_")
	foreign lib {
		init                         :: proc(ctx: ^^Context) -> c.int ---
		exit                         :: proc(ctx: ^Context) ---
		get_device_list              :: proc(ctx: ^Context, list: ^[^]^Device) -> int ---
		free_device_list             :: proc(list: [^]^Device, unref_devices: c.int) ---
		get_device_descriptor        :: proc(dev: ^Device, desc: ^Device_Descriptor) -> c.int ---
		get_bus_number               :: proc(dev: ^Device) -> u8 ---
		get_device_address           :: proc(dev: ^Device) -> u8 ---
		open                         :: proc(dev: ^Device, handle: ^^Device_Handle) -> c.int ---
		close                        :: proc(handle: ^Device_Handle) ---
		set_auto_detach_kernel_driver :: proc(handle: ^Device_Handle, enable: c.int) -> c.int ---
		claim_interface              :: proc(handle: ^Device_Handle, interface_number: c.int) -> c.int ---
		release_interface            :: proc(handle: ^Device_Handle, interface_number: c.int) -> c.int ---
		bulk_transfer                :: proc(handle: ^Device_Handle, endpoint: u8, data: [^]u8, length: c.int, transferred: ^c.int, timeout: c.uint) -> c.int ---
		interrupt_transfer           :: proc(handle: ^Device_Handle, endpoint: u8, data: [^]u8, length: c.int, transferred: ^c.int, timeout: c.uint) -> c.int ---
		error_name                   :: proc(code: c.int) -> cstring ---
	}
}

// Whether libusb is built in (FIRE_LIBUSB).
AVAILABLE :: FIRE_LIBUSB
