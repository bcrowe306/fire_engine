#+build !windows
package test_wasapi

import "core:testing"

// WASAPI exists only on Windows; this keeps the package building elsewhere.
@(test)
not_windows :: proc(t: ^testing.T) {}
