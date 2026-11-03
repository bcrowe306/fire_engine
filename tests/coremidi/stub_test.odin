#+build !darwin
package test_coremidi

import "core:testing"

// CoreMIDI exists only on macOS; this keeps the package building elsewhere.
@(test)
not_macos :: proc(t: ^testing.T) {}
