#+build !darwin
package backend

import "core:time"

// [rt] The clock all device and MIDI timestamps use.
host_time_ns :: proc "contextless" () -> u64 {
	return u64(time.tick_now()._nsec)
}
