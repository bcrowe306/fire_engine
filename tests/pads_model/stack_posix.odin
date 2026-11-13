#+build !windows
package test_pads_model

import "base:runtime"
import "core:sys/posix"

// Runs `f(data)` on a thread whose stack is `size` bytes (as a Windows
// thread's 1 MB, or smaller): what keeps large values on the stack shows
// here too, where threads otherwise get 8 MB. False if it could not start.
on_small_stack :: proc(f: proc(data: rawptr), data: rawptr, size: int) -> bool {
	Call :: struct {
		f:    proc(data: rawptr),
		data: rawptr,
	}
	call := Call{f, data}
	attr: posix.pthread_attr_t
	if posix.pthread_attr_init(&attr) != .NONE do return false
	defer posix.pthread_attr_destroy(&attr)
	if posix.pthread_attr_setstacksize(&attr, uint(size)) != .NONE do return false
	th: posix.pthread_t
	start :: proc "c" (arg: rawptr) -> rawptr {
		context = runtime.default_context()
		c := (^Call)(arg)
		c.f(c.data)
		runtime.default_temp_allocator_destroy(&runtime.global_default_temp_allocator_data)
		return nil
	}
	if posix.pthread_create(&th, &attr, start, &call) != .NONE do return false
	posix.pthread_join(th)
	return true
}
