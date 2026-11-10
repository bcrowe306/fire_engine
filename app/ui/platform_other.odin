#+build !linux
package ui

// Windows and macOS draw headless into a hidden window.
@(private)
headless_hints :: proc() {}
