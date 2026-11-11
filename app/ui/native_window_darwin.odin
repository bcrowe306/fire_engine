#+build darwin
package ui

import "core:dynlib"

// An NSWindow's content view (an NSView): [window contentView], called
// through the Objective-C runtime looked up at run time.
@(private)
cocoa_content_view :: proc(window: rawptr) -> uintptr {
	@(static) lib: dynlib.Library
	@(static) sel_register: proc "c" (name: cstring) -> rawptr
	@(static) send: proc "c" (self: rawptr, sel: rawptr) -> rawptr
	if send == nil {
		ok: bool
		lib, ok = dynlib.load_library("/usr/lib/libobjc.A.dylib")
		if !ok do return 0
		sel_register = cast(proc "c" (name: cstring) -> rawptr)dynlib.symbol_address(lib, "sel_registerName")
		send = cast(proc "c" (self: rawptr, sel: rawptr) -> rawptr)dynlib.symbol_address(lib, "objc_msgSend")
		if sel_register == nil || send == nil {
			send = nil
			return 0
		}
	}
	return uintptr(send(window, sel_register("contentView")))
}
