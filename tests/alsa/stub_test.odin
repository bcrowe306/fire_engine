#+build !linux
package test_alsa

import "core:testing"

// ALSA exists only on Linux; this keeps the package building elsewhere.
@(test)
not_linux :: proc(t: ^testing.T) {}
