#+build linux
package rt

import "core:sys/posix"

// Gives the calling thread realtime scheduling. Call it from the thread
// itself, before it starts processing; returns false if the OS refused (the
// thread then keeps normal priority).
//
// - macOS: a Mach time-constraint policy, as CoreAudio uses for its IO
//   thread: the thread wants half of `period_ns` (one audio block; 0 means
//   2.9 ms) in every `period_ns`. No privileges needed.
// - Linux: SCHED_FIFO at `priority` (1–99; JACK and PipeWire use 70–90).
//   Needs CAP_SYS_NICE or an rtprio limit (/etc/security/limits.d).
// - Windows: MMCSS "Pro Audio", as WASAPI audio threads use, for the
//   thread's lifetime.
// - Elsewhere: not supported (returns false).
set_realtime_priority :: proc(priority := 80, period_ns: u64 = 0) -> bool {
	lo := int(posix.sched_get_priority_min(.FIFO))
	hi := int(posix.sched_get_priority_max(.FIFO))
	param := posix.sched_param{sched_priority = i32(clamp(priority, lo, hi))}
	return posix.pthread_setschedparam(posix.pthread_self(), .FIFO, &param) == .NONE
}
