package ui

import im "deps:imgui"
import sdl "deps:sdl3"

/*
A picture the app makes (RGBA pixels: a controller's display mirrored),
kept on the GPU and drawn with ImGui: uploaded again when it changes.

	img: ui.Image
	ui.image_set(&img, p, rgba, 960, 160) // when the pixels change
	im.DrawList_AddImage(dl, ui.image_ref(&img), p0, p1)
	ui.image_destroy(&img)

Its pixels' alpha is ignored (drawn opaque).
*/

// A picture on the GPU. Fields are internal.
Image :: struct {
	p:        ^Platform,
	tex:      ^sdl.GPUTexture,
	transfer: ^sdl.GPUTransferBuffer,
	w, h:     u32,
}

// Uploads `rgba` (`w` x `h` pixels, rows top to bottom) as the image's
// pixels, made or resized as needed. Inside or between frames. False if
// the GPU wouldn't take it (the image as it was).
image_set :: proc(img: ^Image, p: ^Platform, rgba: []u8, w, h: int) -> bool {
	if p == nil || p.device == nil || w <= 0 || h <= 0 || len(rgba) < w * h * 4 do return false
	d := p.device
	uw, uh := u32(w), u32(h)
	if img.tex == nil || img.w != uw || img.h != uh || img.p != p {
		image_destroy(img)
		img.p = p
		img.tex = sdl.CreateGPUTexture(d, {type = .D2, format = FRAME_FORMAT, usage = {.SAMPLER}, width = uw, height = uh, layer_count_or_depth = 1, num_levels = 1})
		img.transfer = sdl.CreateGPUTransferBuffer(d, {usage = .UPLOAD, size = uw * uh * 4})
		img.w, img.h = uw, uh
		if img.tex == nil || img.transfer == nil {
			image_destroy(img)
			return false
		}
	}
	dst := ([^]u8)(sdl.MapGPUTransferBuffer(d, img.transfer, true)) // (cycled: the last upload may be in flight)
	if dst == nil do return false
	n := w * h * 4
	copy(dst[:n], rgba[:n])
	for i := 3; i < n; i += 4 do dst[i] = 255
	sdl.UnmapGPUTransferBuffer(d, img.transfer)
	cmd := sdl.AcquireGPUCommandBuffer(d)
	if cmd == nil do return false
	pass := sdl.BeginGPUCopyPass(cmd)
	sdl.UploadToGPUTexture(pass, {transfer_buffer = img.transfer, pixels_per_row = uw, rows_per_layer = uh}, {texture = img.tex, w = uw, h = uh, d = 1}, true)
	sdl.EndGPUCopyPass(pass)
	return sdl.SubmitGPUCommandBuffer(cmd)
}

// The image for ImGui's drawing (`DrawList_AddImage`); none before the
// first `image_set`.
image_ref :: proc(img: ^Image) -> im.TextureRef {
	return {_TexID = im.TextureID(uintptr(img.tex))}
}

// Whether the image has pixels.
image_ready :: proc(img: ^Image) -> bool { return img.tex != nil }

// Lets the image go (the GPU done with it first).
image_destroy :: proc(img: ^Image) {
	if img.p == nil || img.p.device == nil {
		img^ = {}
		return
	}
	d := img.p.device
	if img.tex != nil || img.transfer != nil do _ = sdl.WaitForGPUIdle(d)
	if img.tex != nil do sdl.ReleaseGPUTexture(d, img.tex)
	if img.transfer != nil do sdl.ReleaseGPUTransferBuffer(d, img.transfer)
	img^ = {}
}
