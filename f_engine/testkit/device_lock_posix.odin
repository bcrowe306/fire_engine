#+build darwin, linux, freebsd, openbsd, netbsd
package testkit

import "core:c"
import "core:fmt"
import "core:sync"
import "core:sys/posix"

// Real-device tests share physical devices, so they take turns: a mutex
// within the process, and a lock file across processes (test.sh runs each
// package once per optimization level, concurrently). POSIX record locks
// belong to the process, hence both. The OS drops the file lock on a crash.
Device_Lock :: struct {
	fd: posix.FD,
}

@(private)
device_mutex: sync.Mutex

// Blocks until this process and thread hold the lock for the shared device `name`
// (a short identifier, used in a file or mutex name). Release with `device_unlock`.
device_lock :: proc(name: string) -> Device_Lock {
	sync.mutex_lock(&device_mutex)
	path := fmt.ctprintf("/tmp/fire_engine_%s.lock", name)
	fd := posix.open(path, {.CREAT, .RDWR}, posix.mode_t{.IRUSR, .IWUSR, .IRGRP, .IROTH})
	if fd >= 0 {
		lock := posix.flock{l_type = .WRLCK, l_whence = c.short(posix.Whence.SET)}
		posix.fcntl(fd, .SETLKW, &lock)
	}
	return {fd}
}

// Releases a lock taken by `device_lock`.
device_unlock :: proc(l: Device_Lock) {
	if l.fd >= 0 do posix.close(l.fd) // closing releases the record lock
	sync.mutex_unlock(&device_mutex)
}
