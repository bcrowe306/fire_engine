#+build !windows
package test_asio

import "core:testing"

// ASIO is Windows-only.
@(test)
asio_is_windows_only :: proc(t: ^testing.T) {}
