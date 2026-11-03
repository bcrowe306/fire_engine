#+build windows
package testkit

import "core:fmt"
import "core:sync"
import win "core:sys/windows"

foreign import kernel32 "system:Kernel32.lib"

@(private, default_calling_convention = "system")
foreign kernel32 {
	CreateMutexW :: proc(attributes: rawptr, initial_owner: win.BOOL, name: win.wstring) -> win.HANDLE ---
	ReleaseMutex :: proc(mutex: win.HANDLE) -> win.BOOL ---
}

// Real-device tests share physical devices, so they take turns: a mutex
// within the process, and a named kernel mutex across processes (test.sh runs
// each package once per optimization level, concurrently). Windows releases
// the named mutex if the holder dies.
Device_Lock :: struct {
	handle: win.HANDLE,
}

@(private)
device_mutex: sync.Mutex

// Blocks until this process and thread hold the lock for the shared device `name`
// (a short identifier, used in a file or mutex name). Release with `device_unlock`.
device_lock :: proc(name: string) -> Device_Lock {
	sync.mutex_lock(&device_mutex)
	h := CreateMutexW(nil, false, win.utf8_to_wstring(fmt.tprintf("Local\\fire_engine_%s", name), context.temp_allocator))
	if h != nil do win.WaitForSingleObject(h, win.INFINITE) // WAIT_ABANDONED also grants ownership
	return {h}
}

// Releases a lock taken by `device_lock`.
device_unlock :: proc(l: Device_Lock) {
	if l.handle != nil {
		ReleaseMutex(l.handle)
		win.CloseHandle(l.handle)
	}
	sync.mutex_unlock(&device_mutex)
}
