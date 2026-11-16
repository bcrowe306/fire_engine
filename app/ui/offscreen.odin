package ui

import "core:time"

import im "deps:imgui"
import imgpu "deps:imgui/backends/sdlgpu3"
import sdl "deps:sdl3"

/*
Drawing UI offscreen: an ImGui context of its own (sharing the window's
fonts and theme), drawn into a texture of any size on the same GPU, and
read back as RGBA without waiting: a frame's pixels are there by the next
call (one frame late). For a controller's display (Push 2's 960 x 160)
showing the app's own views.

	o: ui.Offscreen
	ui.offscreen_init(&o, p)
	// once a frame, after ui.frame_end (not inside a frame):
	ui.offscreen_draw(&o, 960, 160, proc(user: rawptr) { ... im calls ... }, app)
	if px, n := ui.offscreen_pixels(&o); px != nil { ... }
	ui.offscreen_destroy(&o)

Its window fills the size asked, with no decoration, padding or input.
*/

// An offscreen UI. Fields are internal.
Offscreen :: struct {
	p:        ^Platform,
	ctx:      ^im.Context,
	target:   ^sdl.GPUTexture,
	transfer: ^sdl.GPUTransferBuffer,
	w, h:     u32,
	fence:    ^sdl.GPUFence, // the frame in flight
	fence_w, fence_h: u32,
	pixels:   [dynamic]u8, // the newest finished frame (RGBA, rows top to bottom)
	px_w, px_h: int,
	frames:   int, // finished frames so far
	last:     time.Tick,
}

// Sets an offscreen UI up beside the platform's (after `platform_init`).
offscreen_init :: proc(o: ^Offscreen, p: ^Platform) -> bool {
	o^ = {p = p}
	o.pixels = make([dynamic]u8)
	prev := im.GetCurrentContext()
	defer im.SetCurrentContext(prev)
	// The window's fonts (the same atlas: their pointers are good here).
	o.ctx = im.CreateContext(im.GetIO().Fonts)
	im.SetCurrentContext(o.ctx)
	io := im.GetIO()
	io.IniFilename = nil
	io.LogFilename = nil
	info := imgpu.DEFAULT_INIT_INFO
	info.Device = p.device
	info.ColorTargetFormat = FRAME_FORMAT
	if !imgpu.Init(&info) {
		im.DestroyContext(o.ctx)
		o.ctx = nil
		return false
	}
	// The theme, as the window has it now.
	theme_apply(current, 1)
	return true
}

// Lets the offscreen UI go (its frame in flight finished first).
offscreen_destroy :: proc(o: ^Offscreen) {
	if o.p == nil do return
	d := o.p.device
	if o.fence != nil {
		_ = sdl.WaitForGPUFences(d, true, &o.fence, 1)
		sdl.ReleaseGPUFence(d, o.fence)
	}
	if o.ctx != nil {
		prev := im.GetCurrentContext()
		im.SetCurrentContext(o.ctx)
		imgpu.Shutdown()
		im.SetCurrentContext(prev if prev != o.ctx else nil)
		im.DestroyContext(o.ctx)
	}
	if o.target != nil do sdl.ReleaseGPUTexture(d, o.target)
	if o.transfer != nil do sdl.ReleaseGPUTransferBuffer(d, o.transfer)
	delete(o.pixels)
	o^ = {}
}

// Takes the frame in flight's pixels if the GPU has finished it.
@(private)
offscreen_collect :: proc(o: ^Offscreen) {
	d := o.p.device
	if o.fence == nil || !sdl.QueryGPUFence(d, o.fence) do return
	sdl.ReleaseGPUFence(d, o.fence)
	o.fence = nil
	n := int(o.fence_w * o.fence_h * 4)
	src := ([^]u8)(sdl.MapGPUTransferBuffer(d, o.transfer, false))
	if src == nil do return
	resize(&o.pixels, n)
	copy(o.pixels[:], src[:n])
	sdl.UnmapGPUTransferBuffer(d, o.transfer)
	o.px_w, o.px_h = int(o.fence_w), int(o.fence_h)
	o.frames += 1
}

// Draws a frame `w` x `h` pixels with `draw` (ImGui calls, in a window
// filling it), when the last one has finished on the GPU; its pixels are
// `offscreen_pixels`' by the next call. Call between the window's frames.
// Whether a frame was started.
offscreen_draw :: proc(o: ^Offscreen, w, h: int, draw: proc(user: rawptr), user: rawptr) -> bool {
	if o.ctx == nil || w <= 0 || h <= 0 do return false
	offscreen_collect(o)
	if o.fence != nil do return false // (the GPU is still on the last one)
	d := o.p.device
	uw, uh := u32(w), u32(h)
	if o.target == nil || o.w != uw || o.h != uh {
		if o.target != nil do sdl.ReleaseGPUTexture(d, o.target)
		if o.transfer != nil do sdl.ReleaseGPUTransferBuffer(d, o.transfer)
		o.target = sdl.CreateGPUTexture(d, {type = .D2, format = FRAME_FORMAT, usage = {.COLOR_TARGET, .SAMPLER}, width = uw, height = uh, layer_count_or_depth = 1, num_levels = 1})
		o.transfer = sdl.CreateGPUTransferBuffer(d, {usage = .DOWNLOAD, size = uw * uh * 4})
		o.w, o.h = uw, uh
		if o.target == nil || o.transfer == nil do return false
	}
	prev := im.GetCurrentContext()
	im.SetCurrentContext(o.ctx)
	defer im.SetCurrentContext(prev)
	io := im.GetIO()
	io.DisplaySize = {f32(w), f32(h)}
	io.DisplayFramebufferScale = {1, 1}
	dt := f32(time.duration_seconds(time.tick_since(o.last))) if o.last != {} else 1.0 / 60
	io.DeltaTime = clamp(dt, 1.0 / 1000, 0.25)
	o.last = time.tick_now()
	theme_apply(current, 1) // (the window's theme may have changed)
	imgpu.NewFrame() // (makes its pipeline the first time)
	im.NewFrame()
	im.SetNextWindowPos({0, 0})
	im.SetNextWindowSize({f32(w), f32(h)})
	im.PushStyleVarVec2(.WindowPadding, {0, 0})
	im.PushStyleVar(.WindowBorderSize, 0)
	im.PushStyleVar(.WindowRounding, 0)
	if im.Begin("##offscreen", nil, {.NoTitleBar, .NoResize, .NoScrollbar, .NoCollapse, .NoMove, .NoSavedSettings, .NoMouseInputs, .NoNavInputs, .NoNavFocus, .NoScrollWithMouse, .NoBringToFrontOnFocus, .NoDocking}) {
		draw(user)
	}
	im.End()
	im.PopStyleVar(3)
	im.Render()
	dd := im.GetDrawData()
	cmd := sdl.AcquireGPUCommandBuffer(d)
	if cmd == nil do return false
	imgpu.PrepareDrawData(dd, cmd)
	c := current.bg
	color := sdl.GPUColorTargetInfo{texture = o.target, clear_color = {c[0], c[1], c[2], 1}, load_op = .CLEAR, store_op = .STORE}
	pass := sdl.BeginGPURenderPass(cmd, &color, 1, nil)
	imgpu.RenderDrawData(dd, cmd, pass)
	sdl.EndGPURenderPass(pass)
	copy_pass := sdl.BeginGPUCopyPass(cmd)
	sdl.DownloadFromGPUTexture(copy_pass, {texture = o.target, w = uw, h = uh, d = 1}, {transfer_buffer = o.transfer})
	sdl.EndGPUCopyPass(copy_pass)
	o.fence = sdl.SubmitGPUCommandBufferAndAcquireFence(cmd)
	o.fence_w, o.fence_h = uw, uh
	return true
}

// The newest finished frame: RGBA pixels (rows top to bottom), its size,
// and how many frames have finished. Nil before the first.
offscreen_pixels :: proc(o: ^Offscreen) -> (rgba: []u8, w, h: int, frames: int) {
	offscreen_collect(o)
	if o.frames == 0 do return nil, 0, 0, 0
	return o.pixels[:], o.px_w, o.px_h, o.frames
}

// Waits for the frame in flight (tests, a screenshot of the view).
offscreen_finish :: proc(o: ^Offscreen) {
	if o.fence == nil do return
	_ = sdl.WaitForGPUFences(o.p.device, true, &o.fence, 1)
	offscreen_collect(o)
}
