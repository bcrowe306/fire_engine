#+build windows
package rt

import win "core:sys/windows"

foreign import avrt "system:Avrt.lib"

@(private, default_calling_convention = "system")
foreign avrt {
	AvSetMmThreadCharacteristicsW :: proc(task_name: win.wstring, task_index: ^u32) -> win.HANDLE ---
}

// Gives the calling thread realtime scheduling. Call it from the thread
// itself, before it starts processing; returns false if the OS refused (the
// thread keeps normal priority).
//
// Windows: registers the thread with MMCSS as "Pro Audio", as WASAPI audio
// threads are. `priority` and `period_ns` are unused here. The registration
// lasts for the thread's lifetime.
set_realtime_priority :: proc(priority := 80, period_ns: u64 = 0) -> bool {
	index: u32
	return AvSetMmThreadCharacteristicsW(win.L("Pro Audio"), &index) != nil
}
