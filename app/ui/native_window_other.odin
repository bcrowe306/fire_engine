#+build !darwin
package ui

@(private)
cocoa_content_view :: proc(window: rawptr) -> uintptr { return 0 }
