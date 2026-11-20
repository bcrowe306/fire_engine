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
script on machines without a display (see `Driver`). Headless, a frame is
drawn only when a screenshot takes it: ImGui still builds every frame (so
items, their rects and input work as ever), but nobody sees the pixels, and
on a machine without a GPU drawing them is most of a frame's time.

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

import "fire:prof"

// How to open the platform. Zero values are sensible defaults.
Platform_Settings :: struct {
	title:    string, // window title
	width:    int,    // window size in logical points; 0 = 1280 × 800
	height:   int,
	headless: bool,   // no window surface: draw offscreen only (for scripted runs)
	draw_unseen: bool, // headless: draw every frame, not only those a screenshot takes (to time the GPU)
	vsync:    bool,   // wait for the display between frames (ignored headless)
	ini_path: string, // where ImGui keeps window and docking layout; "" = nowhere
}

// The window, the GPU device and the ImGui context. Fields are read-only.
// What a frame gave the GPU: ImGui's vertices, indices, draw lists and
// draw commands (a frame's draw cost on a real GPU goes with these).
Draw_Stats :: struct {
	vertices, indices, lists, commands: int,
}

Platform :: struct {
	settings:     Platform_Settings,
	confirm_quit: bool, // the window's close and the system's quit only set `quit_requested` (the app decides)
	quit_requested: bool,
	window:       ^sdl.Window,
	device:       ^sdl.GPUDevice,
	claimed:      bool, // the window has a swapchain
	drawn:        Draw_Stats, // what the last frame gave the GPU
	max_fps:      f64,       // frames a second at most (0: as many as the display shows); `set_frame_rate_cap`
	frame_at:     time.Tick, // when the last frame began
	target:       ^sdl.GPUTexture, // what every frame is drawn into
	target_w:     u32, // its size in pixels
	target_h:     u32,
	scale:        f32, // pixels per logical point (2 on a Retina display)
	ui_scale:     f32, // the display's scale beyond that (1.5 on a Windows display at 150%)
	zoom:         f32, // the user's zoom of the whole UI (1 = as designed; see `set_zoom`)
	density:      Density, // how large controls are (see `set_density`)
	base:         Theme, // the theme as set (before `set_accent` and the density)
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
	failed:       Platform_Failure, // what `platform_init` could not do
	failed_why:   [256]u8, // SDL's words for it (`platform_failure_text`)
}

// What `platform_init` could not do.
Platform_Failure :: enum {
	None,
	Video,  // start SDL's video (no display to open a window on)
	Window, // open the window
	Gpu,    // find a GPU device: no Vulkan, Direct3D 12 or Metal driver it can use
	Claim,  // give the window a swapchain
	Imgui,  // start ImGui's SDL or SDL_GPU backend
}

// A file dropped on the window, at a position in logical points.
Drop :: struct {
	path: string, // valid until the next `frame_begin`
	pos:  im.Vec2,
}

// Target format of the offscreen frame (and of ImGui's pipeline).
FRAME_FORMAT :: sdl.GPUTextureFormat.R8G8B8A8_UNORM

// Notes failure `f` at step `step` (SDL's error for it kept and logged).
@(private)
platform_fail :: proc(p: ^Platform, f: Platform_Failure, step: string) -> bool {
	why := string(sdl.GetError())
	fmt.eprintln("ui:", step, "failed:", why)
	p.failed = f
	p.failed_why = {}
	copy(p.failed_why[:len(p.failed_why) - 1], fmt.tprintf("%s: %s", step, why))
	return false
}

// What `platform_init` could not do, for a person: what is wrong, what
// usually fixes it, and SDL's own words. Empty if nothing failed.
platform_failure_text :: proc(p: ^Platform, app_name: string, allocator := context.temp_allocator) -> string {
	why := string(cstring(&p.failed_why[0]))
	switch p.failed {
	case .None:
		return ""
	case .Gpu:
		return fmt.aprintf("%s can't draw its window: this computer has no graphics driver it can use " +
			"(Vulkan on Linux, Direct3D 12 or Vulkan on Windows, Metal on macOS).\n\n" +
			"Installing or updating the graphics driver usually fixes it. On Linux, Mesa's Vulkan drivers " +
			"(the mesa-vulkan-drivers package) work too, without a graphics card, but slowly.\n\nDetails: %s",
			app_name, why, allocator = allocator)
	case .Video:
		return fmt.aprintf("%s can't open a window: there is no display it can use.\n\nDetails: %s", app_name, why, allocator = allocator)
	case .Window, .Claim, .Imgui:
	}
	return fmt.aprintf("%s can't open its window.\n\nDetails: %s", app_name, why, allocator = allocator)
}

// Shows `message` in the system's own error box, titled `title`, and waits
// for it to be closed. Needs no window, GPU or `platform_init` (call it
// after `platform_destroy`); false if there was no way to show it.
show_error :: proc(title, message: string) -> bool {
	t := strings.clone_to_cstring(title, context.temp_allocator)
	msg := message
	// (X11's box, SDL's own, doesn't wrap: its lines run off its edges.)
	when ODIN_OS == .Linux do msg = wrap_text(message, 72)
	m := strings.clone_to_cstring(msg, context.temp_allocator)
	return sdl.ShowSimpleMessageBox({.ERROR}, t, m, nil)
}

// `text` with each line broken at spaces to at most `width` characters (a
// word longer than that on a line of its own). Temp-allocated.
wrap_text :: proc(text: string, width: int) -> string {
	b := strings.builder_make(context.temp_allocator)
	for line, i in strings.split(text, "\n", context.temp_allocator) {
		if i > 0 do strings.write_byte(&b, '\n')
		n := 0
		for word in strings.fields(line, context.temp_allocator) {
			w := strings.rune_count(word)
			if n > 0 && n + 1 + w > width {
				strings.write_byte(&b, '\n')
				n = 0
			} else if n > 0 {
				strings.write_byte(&b, ' ')
				n += 1
			}
			strings.write_string(&b, word)
			n += w
		}
	}
	return strings.to_string(b)
}

// Opens the window, the GPU device and ImGui. Returns false (and logs why;
// `Platform.failed` says which, `platform_failure_text` in words) if any of
// them fails. Call `platform_destroy` either way.
platform_init :: proc(p: ^Platform, settings: Platform_Settings) -> bool {
	p.settings = settings
	if p.settings.width <= 0 do p.settings.width = 1280
	if p.settings.height <= 0 do p.settings.height = 800
	p.clear = {0.11, 0.115, 0.13, 1}
	if p.settings.headless do headless_hints()
	if !sdl.Init({.VIDEO, .EVENTS}) {
		return platform_fail(p, .Video, "SDL_Init")
	}
	flags := sdl.WindowFlags{.RESIZABLE, .HIGH_PIXEL_DENSITY}
	if p.settings.headless do flags += {.HIDDEN}
	title := strings.clone_to_cstring(p.settings.title, context.temp_allocator)
	p.window = sdl.CreateWindow(title, i32(p.settings.width), i32(p.settings.height), flags)
	if p.window == nil {
		return platform_fail(p, .Window, "SDL_CreateWindow")
	}
	p.device = sdl.CreateGPUDevice({.SPIRV, .DXIL, .MSL, .METALLIB}, ODIN_DEBUG, nil)
	if p.device == nil {
		return platform_fail(p, .Gpu, "SDL_CreateGPUDevice")
	}
	if !p.settings.headless {
		if !sdl.ClaimWindowForGPUDevice(p.device, p.window) {
			return platform_fail(p, .Claim, "SDL_ClaimWindowForGPUDevice")
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
		return platform_fail(p, .Imgui, "ImGui's SDL3 backend")
	}
	info := imgpu.DEFAULT_INIT_INFO
	info.Device = p.device
	info.ColorTargetFormat = FRAME_FORMAT
	if !imgpu.Init(&info) {
		return platform_fail(p, .Imgui, "ImGui's SDL_GPU backend")
	}
	fonts_load(&p.fonts)
	set_theme(p, theme_dark())
	p.running = true
	return true
}

// Puts the window over the whole screen (`on`), or back as it was.
set_fullscreen :: proc(p: ^Platform, on: bool) {
	if p.window != nil do _ = sdl.SetWindowFullscreen(p.window, on)
}

// Whether the window is over the whole screen.
fullscreen :: proc(p: ^Platform) -> bool {
	return p.window != nil && .FULLSCREEN in sdl.GetWindowFlags(p.window)
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
	// The frame-rate cap: the time left of this frame's share waited out
	// (not headless or driven: tests count frames, not time).
	if p.max_fps > 0 && !p.settings.headless && p.driver == nil && p.frame_at != {} {
		share := time.Duration(1e9 / p.max_fps)
		if left := share - time.tick_since(p.frame_at); left > 0 do time.accurate_sleep(left)
	}
	p.frame_at = time.tick_now()
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
	prof.begin("events")
	defer prof.end()
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
	probe_report_conflicts()
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
// the window. Takes the driver's screenshot, if it asked for one. Headless,
// only a frame a screenshot takes is drawn (unless `draw_unseen`).
frame_end :: proc(p: ^Platform) {
	prof.zone("frame_end")
	prof.begin("im.Render")
	im.Render()
	prof.end()
	if dd := im.GetDrawData(); dd != nil {
		p.drawn = {vertices = int(dd.TotalVtxCount), indices = int(dd.TotalIdxCount), lists = int(dd.CmdLists.Size)}
		p.drawn.commands = 0
		for k in 0 ..< int(dd.CmdLists.Size) do p.drawn.commands += int(dd.CmdLists.Data[k].CmdBuffer.Size)
	}
	shot := p.driver != nil && p.driver.shot_path != ""
	if p.settings.headless && !p.settings.draw_unseen && !shot {
		// Textures ImGui wants made or updated (the font atlas) wait in its
		// list for the next frame that is drawn.
		p.frame += 1
		free_all(context.temp_allocator)
		return
	}
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

	prof.begin("gpu draw")
	defer prof.end()
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
	if shot {
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
	p.base = t
	u := t
	u.control_h = DENSITY_HEIGHT[p.density]
	if current_accent.a > 0 do u.accent, u.accent_text = accent_for(current_accent, u.surface)
	theme_apply(u, p.ui_scale)
	p.clear = u.bg
	current = u
	// The waveforms' and plots' background: black on a dark theme; on a
	// light one a shade darker than the panels, so the traces (in the
	// pads' colours) stand out from it and it from the panel.
	WAVE_BG = Color{0, 0, 0, 1} if theme_is_dark(u) else mix(u.inset, u.text, 0.07)
	PLOT_BG = WAVE_BG
	WAVE_INK = Color{1, 1, 1, 1} if theme_is_dark(u) else u.text
}

// Makes controls the size `d` gives them (the theme set again with it).
set_density :: proc(p: ^Platform, d: Density) {
	if d == p.density do return
	p.density = d
	set_theme(p, p.base)
}

// Draws the accent (selection, focus, the active tab, a knob's arc) in `c`
// instead of the theme's: lightened or darkened until it stands out from
// the surfaces, with text that reads on it. A colour with zero alpha goes
// back to the theme's accent. Cheap when `c` is unchanged: call it every
// frame with what should lead (the selected pad's colour).
set_accent :: proc(p: ^Platform, c: Color) {
	if c == current_accent do return
	current_accent = c
	if c.a > 0 {
		current.accent, current.accent_text = accent_for(c, current.surface)
	} else {
		current.accent, current.accent_text = p.base.accent, p.base.accent_text
	}
	theme_apply_accent(current)
}

@(private) current_accent: Color // the colour `set_accent` was given (zero alpha: none)

// Zooms the whole UI by `zoom` (0.5..3; 1 = as designed): everything is
// drawn that much larger, fixed sizes included, as a browser zooms.
set_zoom :: proc(p: ^Platform, zoom: f32) {
	p.zoom = clamp(zoom, 0.5, 3)
}

// Draws at most `fps` frames a second (0: as many as the display shows,
// the default). For small machines: the UI's cost goes with its frames.
set_frame_rate_cap :: proc(p: ^Platform, fps: f64) {
	p.max_fps = max(fps, 0)
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
