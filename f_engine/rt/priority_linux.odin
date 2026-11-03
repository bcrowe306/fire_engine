#+build linux
package rt

import "core:sys/posix"

// Gives the calling thread realtime (SCHED_FIFO) scheduling. `priority` is 1–99
// (JACK and PipeWire use 70–90 for audio threads). Fails without CAP_SYS_NICE
// or an rtprio limit (/etc/security/limits.d) that allows it; the thread then
// keeps normal priority and the caller should report it. Control thread or
// the thread itself, before it starts processing.
set_realtime_priority :: proc(priority := 80) -> bool {
	lo := int(posix.sched_get_priority_min(.FIFO))
	hi := int(posix.sched_get_priority_max(.FIFO))
	param := posix.sched_param{sched_priority = i32(clamp(priority, lo, hi))}
	return posix.pthread_setschedparam(posix.pthread_self(), .FIFO, &param) == .NONE
}
