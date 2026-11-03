#+build darwin
package rt

foreign import system "system:System"

@(private)
thread_time_constraint_policy :: struct {
	period:      u32, // Mach absolute time units
	computation: u32,
	constraint:  u32,
	preemptible: i32,
}

@(private) THREAD_TIME_CONSTRAINT_POLICY :: 2
@(private) THREAD_TIME_CONSTRAINT_POLICY_COUNT :: 4

@(private)
mach_timebase_info_data_t :: struct {
	numer, denom: u32,
}

@(private, default_calling_convention = "c")
foreign system {
	mach_thread_self :: proc() -> u32 ---
	mach_port_deallocate :: proc(task: u32, name: u32) -> i32 ---
	mach_task_self_: u32
	thread_policy_set :: proc(thread: u32, flavor: u32, policy_info: ^thread_time_constraint_policy, count: u32) -> i32 ---
	mach_timebase_info :: proc(info: ^mach_timebase_info_data_t) -> i32 ---
}

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
	period := period_ns if period_ns > 0 else 2_900_000
	tb: mach_timebase_info_data_t
	if mach_timebase_info(&tb) != 0 || tb.numer == 0 do return false
	to_abs :: proc(ns: u64, tb: mach_timebase_info_data_t) -> u32 {
		return u32(min(ns * u64(tb.denom) / u64(tb.numer), u64(max(u32))))
	}
	policy := thread_time_constraint_policy {
		period      = to_abs(period, tb),
		computation = to_abs(period / 2, tb),
		constraint  = to_abs(period, tb),
		preemptible = 1,
	}
	thread := mach_thread_self()
	defer mach_port_deallocate(mach_task_self_, thread)
	return thread_policy_set(thread, THREAD_TIME_CONSTRAINT_POLICY, &policy, THREAD_TIME_CONSTRAINT_POLICY_COUNT) == 0
}
