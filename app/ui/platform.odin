/*
The windowing and drawing layer of the application library: an SDL3 window,
an SDL_GPU device, and a Dear ImGui context drawn into it.

	p: ui.Platform
	if !ui.platform_init(&p, {title = "Pads", width = 1280, height = 800}) do return
	defer ui.platform_destroy(&p)
	for ui.frame_begin(&p) {
		// ... ImGui calls ...
		ui.frame_end(&p)
	}

Every frame is drawn into an offscreen texture, then copied to the
window. That makes screenshots a texture download, and lets the platform
run without a window surface at all (`headless`), for driving the UI from a
script on machines without a display (see `Driver`).

See /guides/app-layer/ for a walk-through.
*/
package ui

import "core:fmt"
import "core:strings"
import "core:time"

import im "deps:imgui"
import imsdl "deps:imgui/backends/sdl3"
import imgpu "deps:imgui/backends/sdlgpu3"
import sdl "deps:sdl3"

// How to open the platform. Zero values are sensible defaults.
Platform_Settings :: struct {
	title:    string, // window title
	width:    int,    // window size in logical points; 0 = 1280 × 800
	height:   int,
	headless: bool,   // no window surface: draw offscreen only (for scripted runs)
	vsync:    bool,   // wait for the display between frames (ignored headless)
	ini_path: string, // where ImGui keeps window and docking layout; "" = nowhere
}

// The window, the GPU device and the ImGui context. Fields are read-only.
Platform :: struct {
	settings:     Platform_Settings,
	confirm_quit: bool, // the window's close and the system's quit only set `quit_requested` (the app decides)
	quit_requested: bool,
	window:       ^sdl.Window,
	device:       ^sdl.GPUDevice,
	claimed:      bool, // the window has a swapchain
	target:       ^sdl.GPUTexture, // what every frame is drawn into
	target_w:     u32, // its size in pixels
	target_h:     u32,
	scale:        f32, // pixels per logical point (2 on a Retina display)
	ui_scale:     f32, // the display's scale beyond that (1.5 on a Windows display at 150%)
	zoom:         f32, // the user's zoom of the whole UI (1 = as designed; see `set_zoom`)
	running:      bool,
	frame:        u64, // frames drawn
	driver:       ^Driver, // when the UI runs from a script
	control:      ^Control, // live commands from a test harness (with a live driver)
	fence:        ^sdl.GPUFence, // headless: the frame in flight (waited for before the next)
	fixed_dt:     f32, // > 0: every frame advances this many seconds (repeatable runs)
	clear:        [4]f32, // background colour
	fonts:        Fonts,
	ini_cstr:     cstring,
	drops:        [dynamic]Drop, // files dropped on the window this frame
	closed:       [dynamic]sdl.WindowID, // other windows (see `Native_Window`) whose close was clicked this frame
}

// A file dropped on the window, at a position in logical points.
Drop :: struct {
	path: string, // valid until the next `frame_begin`
	pos:  im.Vec2,
}

// Target format of the offscreen frame (and of ImGui's pipeline).
FRAME_FORMAT :: sdl.GPUTextureFormat.R8G8B8A8_UNORM

// Opens the window, the GPU device and ImGui. Returns false (and logs why)
// if any of them fails. Call `platform_destroy` either way.
platform_init :: proc(p: ^Platform, settings: Platform_Settings) -> bool {
	p.settings = settings
	if p.settings.width <= 0 do p.settings.width = 1280
	if p.settings.height <= 0 do p.settings.height = 800
	p.clear = {0.11, 0.115, 0.13, 1}
	if p.settings.headless do headless_hints()
	if !sdl.Init({.VIDEO, .EVENTS}) {
		fmt.eprintln("ui: SDL_Init:", sdl.GetError())
		return false
	}
	flags := sdl.WindowFlags{.RESIZABLE, .HIGH_PIXEL_DENSITY}
	if p.settings.headless do flags += {.HIDDEN}
	title := strings.clone_to_cstring(p.settings.title, context.temp_allocator)
	p.window = sdl.CreateWindow(title, i32(p.settings.width), i32(p.settings.height), flags)
	if p.window == nil {
		fmt.eprintln("ui: SDL_CreateWindow:", sdl.GetError())
		return false
	}
	p.device = sdl.CreateGPUDevice({.SPIRV, .DXIL, .MSL, .METALLIB}, ODIN_DEBUG, nil)
	if p.device == nil {
		fmt.eprintln("ui: SDL_CreateGPUDevice:", sdl.GetError())
		return false
	}
	if !p.settings.headless {
		if !sdl.ClaimWindowForGPUDevice(p.device, p.window) {
			fmt.eprintln("ui: SDL_ClaimWindowForGPUDevice:", sdl.GetError())
			return false
		}
		p.claimed = true
		_ = sdl.SetGPUSwapchainParameters(p.device, p.window, .SDR, .VSYNC if p.settings.vsync else .IMMEDIATE)
	}
	p.scale = sdl.GetWindowPixelDensity(p.window)
	if p.scale <= 0 do p.scale = 1
	// ImGui works in logical points and draws at the pixel density itself;
	// only a content scale beyond it (Windows, Linux) enlarges the style.
	p.ui_scale = sdl.GetWindowDisplayScale(p.window) / p.scale
	if p.ui_scale <= 0 do p.ui_scale = 1

	im.CHECKVERSION()
	im.CreateContext()
	io := im.GetIO()
	io.ConfigFlags += {.NavEnableKeyboard, .DockingEnable}
	p.ini_cstr = strings.clone_to_cstring(p.settings.ini_path) if p.settings.ini_path != "" else nil
	io.IniFilename = p.ini_cstr
	if !imsdl.InitForSDLGPU(p.window) {
		fmt.eprintln("ui: ImGui SDL3 backend failed")
		return false
	}
	info := imgpu.DEFAULT_INIT_INFO
	info.Device = p.device
	info.ColorTargetFormat = FRAME_FORMAT
	if !imgpu.Init(&info) {
		fmt.eprintln("ui: ImGui SDL_GPU backend failed")
		return false
	}
	fonts_load(&p.fonts)
	set_theme(p, theme_dark())
	p.running = true
	return true
}

// Shuts ImGui, the device and the window down, in that order.
platform_destroy :: proc(p: ^Platform) {
	if p.device != nil do _ = sdl.WaitForGPUIdle(p.device)
	if p.fence != nil do sdl.ReleaseGPUFence(p.device, p.fence)
	if im.GetCurrentContext() != nil {
		imgpu.Shutdown()
		imsdl.Shutdown()
		im.DestroyContext()
	}
	if p.target != nil do sdl.ReleaseGPUTexture(p.device, p.target)
	if p.claimed do sdl.ReleaseWindowFromGPUDevice(p.device, p.window)
	if p.device != nil do sdl.DestroyGPUDevice(p.device)
	if p.window != nil do sdl.DestroyWindow(p.window)
	delete(p.ini_cstr)
	for d in p.drops do delete(d.path)
	delete(p.drops)
	delete(p.closed)
	sdl.Quit()
	p^ = {}
}

// Polls input (and the driver's, when one runs), and starts an ImGui
// frame. Returns false once the app should quit.
frame_begin :: proc(p: ^Platform) -> bool {
	// SDL delivers typed text only while text input is on. ImGui's backend
	// turns it on for a clicked field but not for one focused from code (a
	// palette's search box): keep it in step with what ImGui wants.
	if im.GetCurrentContext() != nil {
		want := im.GetIO().WantTextInput
		if want != sdl.TextInputActive(p.window) {
			if want do _ = sdl.StartTextInput(p.window)
			else do _ = sdl.StopTextInput(p.window)
		}
	}
	for d in p.drops do delete(d.path)
	clear(&p.drops)
	clear(&p.closed)
	if p.control != nil && p.driver != nil do control_poll(p.control, p.driver)
	z := p.zoom if p.zoom > 0 else 1
	if p.driver != nil {
		p.driver.zoom = z
		driver_step(p.driver, p)
	}
	e: sdl.Event
	for sdl.PollEvent(&e) {
		// Zoomed: the window's positions are ImGui's times the zoom.
		if z != 1 {
			#partial switch e.type {
			case .MOUSE_MOTION:
				e.motion.x, e.motion.y, e.motion.xrel, e.motion.yrel = e.motion.x / z, e.motion.y / z, e.motion.xrel / z, e.motion.yrel / z
			case .MOUSE_BUTTON_DOWN, .MOUSE_BUTTON_UP:
				e.button.x, e.button.y = e.button.x / z, e.button.y / z
			case .MOUSE_WHEEL:
				e.wheel.mouse_x, e.wheel.mouse_y = e.wheel.mouse_x / z, e.wheel.mouse_y / z
			case .DROP_FILE, .DROP_POSITION, .DROP_TEXT:
				e.drop.x, e.drop.y = e.drop.x / z, e.drop.y / z
			}
		}
		imsdl.ProcessEvent(&e)
		#partial switch e.type {
		case .DROP_FILE:
			if e.drop.data != nil do append(&p.drops, Drop{strings.clone(string(e.drop.data)), {e.drop.x, e.drop.y}})
		case .QUIT:
			if p.confirm_quit do p.quit_requested = true
			else do p.running = false
		case .WINDOW_CLOSE_REQUESTED:
			if e.window.windowID == sdl.GetWindowID(p.window) {
				if p.confirm_quit do p.quit_requested = true
				else do p.running = false
			} else {
				append(&p.closed, e.window.windowID)
			}
		}
	}
	if !p.running do return false
	im.probe_frame() // the frame just drawn's items become the ones a test reads
	imgpu.NewFrame()
	imsdl.NewFrame()
	// Zoomed: ImGui sees a window `z` times smaller at `z` times the pixel
	// density, so everything (fixed sizes too) is drawn `z` times larger,
	// and the mouse (which the backend may have read from the system
	// unscaled while a button is held) is where it is in that window.
	if z != 1 {
		io := im.GetIO()
		io.DisplaySize = {io.DisplaySize.x / z, io.DisplaySize.y / z}
		io.DisplayFramebufferScale = {io.DisplayFramebufferScale.x * z, io.DisplayFramebufferScale.y * z}
		if p.driver == nil && sdl.GetMouseFocus() == p.window {
			mx, my: f32
			_ = sdl.GetMouseState(&mx, &my)
			im.IO_AddMousePosEvent(io, mx / z, my / z)
		}
	}
	if p.fixed_dt > 0 do im.GetIO().DeltaTime = p.fixed_dt
	im.NewFrame()
	return true
}

// Ends the ImGui frame and draws it: into the offscreen frame, then onto
// the window. Takes the driver's screenshot, if it asked for one.
frame_end :: proc(p: ^Platform) {
	im.Render()
	draw_data := im.GetDrawData()
	cmd := sdl.AcquireGPUCommandBuffer(p.device)
	if cmd == nil do return

	swapchain: ^sdl.GPUTexture
	sw, sh: u32
	if p.claimed {
		if !sdl.WaitAndAcquireGPUSwapchainTexture(cmd, p.window, &swapchain, &sw, &sh) do swapchain = nil
	}
	// The frame is the window's size in pixels.
	w, h: i32
	sdl.GetWindowSizeInPixels(p.window, &w, &h)
	ensure_target(p, u32(max(w, 1)), u32(max(h, 1)))

	imgpu.PrepareDrawData(draw_data, cmd)
	color := sdl.GPUColorTargetInfo {
		texture     = p.target,
		clear_color = {p.clear[0], p.clear[1], p.clear[2], p.clear[3]},
		load_op     = .CLEAR,
		store_op    = .STORE,
	}
	pass := sdl.BeginGPURenderPass(cmd, &color, 1, nil)
	imgpu.RenderDrawData(draw_data, cmd, pass)
	sdl.EndGPURenderPass(pass)

	if swapchain != nil {
		blit := sdl.GPUBlitInfo {
			source      = {texture = p.target, w = p.target_w, h = p.target_h},
			destination = {texture = swapchain, w = sw, h = sh},
			load_op     = .DONT_CARE,
			filter      = .NEAREST,
		}
		sdl.BlitGPUTexture(cmd, blit)
	}
	if p.driver != nil && p.driver.shot_path != "" {
		screenshot_submit(p, cmd, p.driver.shot_path)
		delete(p.driver.shot_path)
		p.driver.shot_path = ""
	} else if swapchain == nil {
		// No swapchain paces a headless frame: wait for the last one to finish
		// before going on, or frames queue up faster than a (software) GPU
		// draws them and their memory piles up (gigabytes on Linux's
		// lavapipe). One frame stays in flight.
		fence := sdl.SubmitGPUCommandBufferAndAcquireFence(cmd)
		if p.fence != nil {
			_ = sdl.WaitForGPUFences(p.device, true, &p.fence, 1)
			sdl.ReleaseGPUFence(p.device, p.fence)
		}
		p.fence = fence
	} else {
		_ = sdl.SubmitGPUCommandBuffer(cmd)
	}
	p.frame += 1
	free_all(context.temp_allocator)
}

// Makes `t` the UI's theme: ImGui's style, and the background behind
// every window.
set_theme :: proc(p: ^Platform, t: Theme) {
	theme_apply(t, p.ui_scale)
	p.clear = t.bg
	current = t
}

// Zooms the whole UI by `zoom` (0.5..3; 1 = as designed): everything is
// drawn that much larger, fixed sizes included, as a browser zooms.
set_zoom :: proc(p: ^Platform, zoom: f32) {
	p.zoom = clamp(zoom, 0.5, 3)
}

// Asks the app to quit after this frame.
quit :: proc(p: ^Platform) {
	p.running = false
}

@(private)
ensure_target :: proc(p: ^Platform, w, h: u32) {
	if p.target != nil && p.target_w == w && p.target_h == h do return
	if p.target != nil do sdl.ReleaseGPUTexture(p.device, p.target)
	info := sdl.GPUTextureCreateInfo {
		type                 = .D2,
		format               = FRAME_FORMAT,
		usage                = {.COLOR_TARGET, .SAMPLER},
		width                = w,
		height               = h,
		layer_count_or_depth = 1,
		num_levels           = 1,
	}
	p.target = sdl.CreateGPUTexture(p.device, info)
	p.target_w, p.target_h = w, h
}

// Seconds since the platform started (for animation outside ImGui).
now :: proc() -> f64 {
	return f64(time.tick_now()._nsec) / 1e9
}
