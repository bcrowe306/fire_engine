package testkit

import "core:os"

// Result of `wav_read` and `wav_write`.
Wav_Error :: enum {
	None,
	Io,                 // file could not be read or written
	Not_Riff_Wave,      // not a RIFF/WAVE file
	Missing_Chunk,      // no fmt or data chunk
	Unsupported_Format, // sample format other than those wav_read lists
}

// Writes 32-bit IEEE float WAV.
wav_write :: proc(path: string, b: Audio_Buffer) -> Wav_Error {
	channels := len(b.channels)
	data_bytes := b.frames * channels * 4
	out := make([dynamic]u8, 0, 44 + data_bytes, context.temp_allocator)

	put_tag(&out, "RIFF")
	put_u32(&out, u32(36 + data_bytes))
	put_tag(&out, "WAVE")
	put_tag(&out, "fmt ")
	put_u32(&out, 16)
	put_u16(&out, 3) // WAVE_FORMAT_IEEE_FLOAT
	put_u16(&out, u16(channels))
	put_u32(&out, u32(b.sample_rate))
	put_u32(&out, u32(b.sample_rate) * u32(channels) * 4)
	put_u16(&out, u16(channels * 4))
	put_u16(&out, 32)
	put_tag(&out, "data")
	put_u32(&out, u32(data_bytes))
	for i in 0 ..< b.frames {
		for c in 0 ..< channels {
			put_u32(&out, transmute(u32)b.channels[c][i])
		}
	}
	if os.write_entire_file(path, out[:]) != nil do return .Io
	return .None
}

// Reads PCM 16/24/32-bit int and 32/64-bit float WAV (including WAVE_FORMAT_EXTENSIBLE).
wav_read :: proc(path: string, allocator := context.allocator) -> (b: Audio_Buffer, err: Wav_Error) {
	data, ioerr := os.read_entire_file(path, context.temp_allocator)
	if ioerr != nil do return {}, .Io
	if len(data) < 12 || string(data[0:4]) != "RIFF" || string(data[8:12]) != "WAVE" {
		return {}, .Not_Riff_Wave
	}

	format, channels, bits: int
	sample_rate: f64
	pcm: []u8
	have_fmt := false

	pos := 12
	for pos + 8 <= len(data) {
		id := string(data[pos:pos + 4])
		size := int(get_u32(data, pos + 4))
		body_start := pos + 8
		body_end := min(body_start + size, len(data))
		switch id {
		case "fmt ":
			format = int(get_u16(data, body_start))
			channels = int(get_u16(data, body_start + 2))
			sample_rate = f64(get_u32(data, body_start + 4))
			bits = int(get_u16(data, body_start + 14))
			if format == 0xFFFE && size >= 40 {
				format = int(get_u16(data, body_start + 24)) // SubFormat GUID's first two bytes
			}
			have_fmt = true
		case "data":
			pcm = data[body_start:body_end]
		}
		pos = body_start + size + (size & 1) // chunks are word-aligned
	}
	if !have_fmt || pcm == nil do return {}, .Missing_Chunk

	bytes_per := bits / 8
	if channels <= 0 || bytes_per <= 0 do return {}, .Unsupported_Format
	frames := len(pcm) / (channels * bytes_per)
	b = buffer_make(channels, frames, sample_rate, allocator)

	for i in 0 ..< frames {
		for c in 0 ..< channels {
			o := (i * channels + c) * bytes_per
			v: f32
			switch {
			case format == 3 && bits == 32: v = transmute(f32)get_u32(pcm, o)
			case format == 3 && bits == 64: v = f32(transmute(f64)(u64(get_u32(pcm, o)) | u64(get_u32(pcm, o + 4)) << 32))
			case format == 1 && bits == 16: v = f32(i16(get_u16(pcm, o))) / 32768.0
			case format == 1 && bits == 24:
				raw := i32(u32(pcm[o]) << 8 | u32(pcm[o + 1]) << 16 | u32(pcm[o + 2]) << 24) >> 8
				v = f32(raw) / 8388608.0
			case format == 1 && bits == 32: v = f32(f64(i32(get_u32(pcm, o))) / 2147483648.0)
			case:
				buffer_destroy(&b)
				return {}, .Unsupported_Format
			}
			b.channels[c][i] = v
		}
	}
	return b, .None
}

@(private)
put_tag :: proc(out: ^[dynamic]u8, tag: string) {
	append(out, tag)
}

@(private)
put_u16 :: proc(out: ^[dynamic]u8, v: u16) {
	append(out, u8(v), u8(v >> 8))
}

@(private)
put_u32 :: proc(out: ^[dynamic]u8, v: u32) {
	append(out, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24))
}

@(private)
get_u16 :: proc(d: []u8, o: int) -> u16 {
	return u16(d[o]) | u16(d[o + 1]) << 8
}

@(private)
get_u32 :: proc(d: []u8, o: int) -> u32 {
	return u32(d[o]) | u32(d[o + 1]) << 8 | u32(d[o + 2]) << 16 | u32(d[o + 3]) << 24
}
