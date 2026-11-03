#+build !windows
package rt

import "core:time"

// Sleeps for `d` with sub-millisecond precision (nanosleep). Not for the
// audio thread.
precise_sleep :: proc(d: time.Duration) {
	time.sleep(d)
}
