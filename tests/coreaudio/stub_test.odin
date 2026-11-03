#+build !darwin
package test_coreaudio

import "core:testing"

// CoreAudio exists only on macOS; this keeps the package building elsewhere.
@(test)
not_macos :: proc(t: ^testing.T) {}
