package ui

import "core:fmt"
import "core:hash"
import "core:os"

import sdl "deps:sdl3"

// Submits `cmd` with a download of the frame appended, waits for it, and
// writes the frame to `path` as a PNG.
@(private)
screenshot_submit :: proc(p: ^Platform, cmd: ^sdl.GPUCommandBuffer, path: string) {
	w, h := p.target_w, p.target_h
	size := w * h * 4
	tb := sdl.CreateGPUTransferBuffer(p.device, {usage = .DOWNLOAD, size = size})
	defer sdl.ReleaseGPUTransferBuffer(p.device, tb)
	copy_pass := sdl.BeginGPUCopyPass(cmd)
	sdl.DownloadFromGPUTexture(copy_pass, {texture = p.target, w = w, h = h, d = 1}, {transfer_buffer = tb})
	sdl.EndGPUCopyPass(copy_pass)
	fence := sdl.SubmitGPUCommandBufferAndAcquireFence(cmd)
	if fence == nil {
		fmt.eprintln("ui: screenshot: submit failed:", sdl.GetError())
		return
	}
	defer sdl.ReleaseGPUFence(p.device, fence)
	fences := [1]^sdl.GPUFence{fence}
	_ = sdl.WaitForGPUFences(p.device, true, raw_data(fences[:]), 1)
	pixels := ([^]u8)(sdl.MapGPUTransferBuffer(p.device, tb, false))
	if pixels == nil do return
	defer sdl.UnmapGPUTransferBuffer(p.device, tb)
	if err := png_write(path, pixels[:size], int(w), int(h)); err != nil {
		fmt.eprintfln("ui: screenshot %s: %v", path, err)
	}
}

// Writes RGBA8 pixels (rows top to bottom) as a PNG. The image data is
// stored uncompressed (deflate's stored blocks): simple, and the files are
// for tests, not for shipping.
png_write :: proc(path: string, rgba: []u8, w, h: int) -> os.Error {
	out := make([dynamic]u8, 0, len(rgba) + h + 1024, context.temp_allocator)
	append(&out, 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A)

	ihdr: [13]u8
	be32(ihdr[0:], u32(w))
	be32(ihdr[4:], u32(h))
	ihdr[8], ihdr[9] = 8, 6 // 8 bits, RGBA
	chunk(&out, "IHDR", ihdr[:])

	// Scanlines, each with filter byte 0, wrapped in zlib stored blocks.
	raw := make([dynamic]u8, 0, len(rgba) + h, context.temp_allocator)
	for y in 0 ..< h {
		append(&raw, 0)
		append(&raw, ..rgba[y * w * 4:][:w * 4])
	}
	z := make([dynamic]u8, 0, len(raw) + len(raw) / 65535 * 5 + 16, context.temp_allocator)
	append(&z, 0x78, 0x01)
	for at := 0; at < len(raw) || at == 0; {
		n := min(len(raw) - at, 65535)
		last := at + n >= len(raw)
		append(&z, 1 if last else 0, u8(n), u8(n >> 8), u8(~n), u8(~n >> 8))
		append(&z, ..raw[at:][:n])
		at += n
		if last do break
	}
	adler := hash.adler32(raw[:])
	a: [4]u8
	be32(a[:], adler)
	append(&z, ..a[:])
	chunk(&out, "IDAT", z[:])
	chunk(&out, "IEND", nil)
	return os.write_entire_file(path, out[:])
}

@(private)
chunk :: proc(out: ^[dynamic]u8, kind: string, data: []u8) {
	n: [4]u8
	be32(n[:], u32(len(data)))
	append(out, ..n[:])
	start := len(out)
	append(out, ..transmute([]u8)kind)
	append(out, ..data)
	crc: [4]u8
	be32(crc[:], hash.crc32(out[start:]))
	append(out, ..crc[:])
}

@(private)
be32 :: proc "contextless" (b: []u8, v: u32) {
	b[0], b[1], b[2], b[3] = u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v)
}
