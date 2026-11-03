#+build windows
package rt

import win "core:sys/windows"
import "core:time"

foreign import kernel32 "system:Kernel32.lib"

@(private)
CREATE_WAITABLE_TIMER_HIGH_RESOLUTION :: u32(0x00000002)
@(private)
TIMER_ALL_ACCESS :: u32(0x001F0003)

@(private, default_calling_convention = "system")
foreign kernel32 {
	CreateWaitableTimerExW :: proc(attributes: rawptr, name: win.wstring, flags: u32, access: u32) -> win.HANDLE ---
	SetWaitableTimer :: proc(timer: win.HANDLE, due: ^i64, period: i32, routine: rawptr, arg: rawptr, resume: win.BOOL) -> win.BOOL ---
}

// Sleeps for `d` with sub-millisecond precision, without spinning: nanosleep,
// or on Windows a high-resolution waitable timer (time.sleep there rounds down
// to whole milliseconds, and Sleep(0) only yields). Not for the audio thread.
precise_sleep :: proc(d: time.Duration) {
	if d <= 0 do return
	timer := CreateWaitableTimerExW(nil, nil, CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, TIMER_ALL_ACCESS)
	if timer == nil {
		win.Sleep(win.DWORD(max(1, d / time.Millisecond)))
		return
	}
	defer win.CloseHandle(timer)
	due := -i64(d / 100) // negative: relative, in 100-ns units
	if due == 0 do due = -1
	if !SetWaitableTimer(timer, &due, 0, nil, nil, false) {
		win.Sleep(win.DWORD(max(1, d / time.Millisecond)))
		return
	}
	win.WaitForSingleObject(timer, win.INFINITE)
}
