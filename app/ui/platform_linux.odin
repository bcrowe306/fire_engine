#+build linux
package ui

import "core:os"

import sdl "deps:sdl3"

// With no display server (a test machine), SDL's offscreen video driver.
@(private)
headless_hints :: proc() {
	if os.get_env("DISPLAY", context.temp_allocator) == "" && os.get_env("WAYLAND_DISPLAY", context.temp_allocator) == "" {
		_ = sdl.SetHint(sdl.HINT_VIDEO_DRIVER, "offscreen")
	}
}
