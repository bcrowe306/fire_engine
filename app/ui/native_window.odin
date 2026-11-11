package ui

import "core:strings"

import sdl "deps:sdl3"

// A plain system window beside the app's, for something else to draw in
// (a plug-in's editor): made, sized and closed here, its native handle
// given to whatever draws in it. Hidden when the app runs headless.
Native_Window :: struct {
	window: ^sdl.Window,
	id:     sdl.WindowID,
}

// The kind of native handle a window has.
Native_Api :: enum u8 {
	None,
	Cocoa, // an NSView (the window's content view)
	Win32, // an HWND
	X11,   // an X11 window id
}

// Opens a window `w` × `h` points titled `title` (resizable or not).
// False if the system would not.
native_window_open :: proc(p: ^Platform, title: string, w, h: int, resizable := false) -> (nw: Native_Window, ok: bool) {
	flags := sdl.WindowFlags{.HIGH_PIXEL_DENSITY}
	if resizable do flags += {.RESIZABLE}
	if p.settings.headless do flags += {.HIDDEN}
	t := strings.clone_to_cstring(title, context.temp_allocator)
	nw.window = sdl.CreateWindow(t, i32(max(w, 64)), i32(max(h, 48)), flags)
	if nw.window == nil do return {}, false
	nw.id = sdl.GetWindowID(nw.window)
	return nw, true
}

// The window's native handle: an NSView on macOS, an HWND on Windows, an
// X11 window id on Linux (None under Wayland or offscreen).
native_window_handle :: proc(nw: Native_Window) -> (api: Native_Api, handle: uintptr) {
	if nw.window == nil do return .None, 0
	props := sdl.GetWindowProperties(nw.window)
	when ODIN_OS == .Darwin {
		if w := sdl.GetPointerProperty(props, sdl.PROP_WINDOW_COCOA_WINDOW_POINTER, nil); w != nil {
			return .Cocoa, cocoa_content_view(w)
		}
	} else when ODIN_OS == .Windows {
		if w := sdl.GetPointerProperty(props, sdl.PROP_WINDOW_WIN32_HWND_POINTER, nil); w != nil do return .Win32, uintptr(w)
	} else {
		if x := sdl.GetNumberProperty(props, sdl.PROP_WINDOW_X11_WINDOW_NUMBER, 0); x != 0 do return .X11, uintptr(x)
	}
	return .None, 0
}

// Sizes the window to `w` × `h` points.
native_window_resize :: proc(nw: Native_Window, w, h: int) {
	if nw.window != nil do _ = sdl.SetWindowSize(nw.window, i32(w), i32(h))
}

// Whether the window's close button was clicked this frame.
native_window_closed :: proc(p: ^Platform, nw: Native_Window) -> bool {
	for id in p.closed do if id == nw.id do return true
	return false
}

// Raises the window and gives it focus.
native_window_raise :: proc(nw: Native_Window) {
	if nw.window != nil do _ = sdl.RaiseWindow(nw.window)
}

// Closes the window.
native_window_close :: proc(nw: ^Native_Window) {
	if nw.window != nil do sdl.DestroyWindow(nw.window)
	nw^ = {}
}
