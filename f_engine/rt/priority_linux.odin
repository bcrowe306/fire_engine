#+build linux
package rt

import "core:sys/posix"

// Gives the calling thread realtime scheduling. Call it from the thread
// itself, before it starts processing; returns false if the OS refused (the
// thread keeps normal priority).
//
// Linux: SCHED_FIFO at `priority` (1–99; JACK and PipeWire use 70–90). Needs
// CAP_SYS_NICE or an rtprio limit (/etc/security/limits.d). `period_ns` is
// unused here.
set_realtime_priority :: proc(priority := 80, period_ns: u64 = 0) -> bool {
	lo := int(posix.sched_get_priority_min(.FIFO))
	hi := int(posix.sched_get_priority_max(.FIFO))
	param := posix.sched_param{sched_priority = i32(clamp(priority, lo, hi))}
	return posix.pthread_setschedparam(posix.pthread_self(), .FIFO, &param) == .NONE
}
