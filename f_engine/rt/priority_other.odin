#+build !linux
#+build !darwin
#+build !windows
package rt

// Gives the calling thread realtime scheduling: not supported on this OS
// (returns false).
set_realtime_priority :: proc(priority := 80, period_ns: u64 = 0) -> bool {
	return false
}
