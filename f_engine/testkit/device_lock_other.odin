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

device_lock :: proc(name: string) -> Device_Lock {
	sync.mutex_lock(&device_mutex)
	return {}
}

device_unlock :: proc(l: Device_Lock) {
	sync.mutex_unlock(&device_mutex)
}
