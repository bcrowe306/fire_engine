#+build darwin
package backend

foreign import system "system:System"

@(private)
CLOCK_UPTIME_RAW :: 8

@(private, default_calling_convention = "c")
foreign system {
	clock_gettime_nsec_np :: proc(clock: u32) -> u64 ---
}

// [rt] The clock all device and MIDI timestamps use. On macOS this is
// mach_absolute_time in nanoseconds (CLOCK_UPTIME_RAW), the clock CoreAudio
// and CoreMIDI timestamps use. It stops while the machine sleeps, unlike
// CLOCK_MONOTONIC_RAW, which core:time uses.
host_time_ns :: proc "contextless" () -> u64 {
	return clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
}
