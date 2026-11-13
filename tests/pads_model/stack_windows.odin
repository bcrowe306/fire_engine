#+build windows
package test_pads_model

// Runs `f(data)` here: a Windows thread's stack is 1 MB already (the size
// the other systems' version sets).
on_small_stack :: proc(f: proc(data: rawptr), data: rawptr, size: int) -> bool {
	f(data)
	return true
}
