#+build !linux
package rt

// macOS: CoreAudio's IO thread is already realtime. Engine-created threads (the
// graph thread pool) will need a Mach time-constraint policy; not done yet.
set_realtime_priority :: proc(priority := 80) -> bool {
	return false
}
