#+build !darwin
package rt

import "core:time"

// [rt] The clock all device and MIDI timestamps use, in nanoseconds from an
// arbitrary origin. On macOS it is mach_absolute_time (CLOCK_UPTIME_RAW), the
// clock CoreAudio and CoreMIDI timestamps use; it stops while the machine
// sleeps (unlike CLOCK_MONOTONIC_RAW, which core:time uses there). Elsewhere it
// is core:time's monotonic tick (QueryPerformanceCounter on Windows, which
// WASAPI timestamps use).
host_time_ns :: proc "contextless" () -> u64 {
	return u64(time.tick_now()._nsec)
}
