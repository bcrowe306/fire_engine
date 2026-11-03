#+build !windows
package test_winmm_midi

import "core:testing"

// WinMM exists only on Windows; this keeps the package building elsewhere.
@(test)
not_windows :: proc(t: ^testing.T) {}
