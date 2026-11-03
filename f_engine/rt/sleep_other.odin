#+build !windows
package rt

import "core:time"

// Sleeps for `d` with sub-millisecond precision, without spinning: nanosleep,
// or on Windows a high-resolution waitable timer (time.sleep there rounds down
// to whole milliseconds, and Sleep(0) only yields). Not for the audio thread.
precise_sleep :: proc(d: time.Duration) {
	time.sleep(d)
}
