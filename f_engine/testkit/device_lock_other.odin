#+build !darwin
#+build !linux
#+build !freebsd
#+build !openbsd
#+build !netbsd
#+build !windows
package testkit

import "core:sync"

// Process-local only: no cross-process lock on this platform yet.
Device_Lock :: struct {}

@(private)
device_mutex: sync.Mutex

// Blocks until this process and thread hold the lock for the shared device `name`
// (a short identifier, used in a file or mutex name). Release with `device_unlock`.
device_lock :: proc(name: string) -> Device_Lock {
	sync.mutex_lock(&device_mutex)
	return {}
}

// Releases a lock taken by `device_lock`.
device_unlock :: proc(l: Device_Lock) {
	sync.mutex_unlock(&device_mutex)
}
