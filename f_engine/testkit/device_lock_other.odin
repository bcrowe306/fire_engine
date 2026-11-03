#+build !darwin
#+build !linux
#+build !freebsd
#+build !openbsd
#+build !netbsd
package testkit

import "core:sync"

// Process-local only for now; Windows gets a named mutex with the WASAPI tests.
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
