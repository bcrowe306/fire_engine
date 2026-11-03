#+build !linux
package test_alsa_midi

import "core:testing"

// The ALSA sequencer exists only on Linux; this keeps the package building elsewhere.
@(test)
not_linux :: proc(t: ^testing.T) {}
