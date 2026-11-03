package audiofile

import "core:math"
import "core:mem"
import "core:os"

// How `writer_create` writes a file. Start from `default_writer_settings`.
Writer_Settings :: struct {
	format:          Format,        // .Wav or .Aiff (float AIFF is written as AIFC)
	encoding:        Sample_Format, // .Int16, .Int24, .Int32, .Float32 or .Float64
	sample_rate:     f64,           // Hz, a whole number
	channels:        int,           // 1 ..= 65535
	dither:          bool,          // add TPDF dither when writing 16-bit
	// Frames between header updates while writing. A crash then loses at
	// most this much from the header's point of view (the reader recovers
	// the rest from the file size anyway). 0 = only at `writer_close`.
	header_interval: i64,
	// WAV only: when the RIFF size would exceed this many bytes the file is
	// turned into RF64 in place. 0 means the format's limit (4 GiB); lower it
	// only to test RF64 handling.
	rf64_threshold:  i64,
}

// 24-bit WAV, header updated every second of audio, dither on (for 16-bit).
default_writer_settings :: proc(sample_rate: f64, channels: int) -> Writer_Settings {
	return {
		format          = .Wav,
		encoding        = .Int24,
		sample_rate     = sample_rate,
		channels        = channels,
		dither          = true,
		header_interval = i64(sample_rate),
	}
}

// A file being written. Create with `writer_create`, finish with
// `writer_close`. Writing blocks on I/O: use it from a disk thread, never
// the audio thread. Fields are internal.
Writer :: struct {
	settings:     Writer_Settings,
	allocator:    mem.Allocator,
	file:         ^os.File,
	scratch:      []u8,
	frame_bytes:  int,
	data_offset:  i64, // first sample byte
	data_bytes:   i64,
	frames:       i64,
	header_at:    i64, // `frames` when the header was last written
	rf64:         bool,
	rng:          u64,
}

// Creates (or replaces) `path` and writes a header for an empty file.
// Free with `writer_close`.
writer_create :: proc(path: string, settings: Writer_Settings, allocator := context.allocator) -> (w: ^Writer, err: Error) {
	s := settings
	switch s.encoding {
	case .Int16, .Int24, .Int32, .Float32, .Float64:
	case .Int8, .Compressed:
		return nil, .Invalid_Argument
	}
	if (s.format != .Wav && s.format != .Aiff) || s.channels < 1 || s.channels > 65535 ||
	   !(s.sample_rate >= 1) || s.sample_rate != math.floor(s.sample_rate) || s.header_interval < 0 {
		return nil, .Invalid_Argument
	}
	if s.rf64_threshold <= 0 do s.rf64_threshold = 0xFFFFFFFF
	f, oerr := os.create(path)
	if oerr != nil do return nil, .Not_Found
	w = new(Writer, allocator)
	if w == nil {
		os.close(f)
		return nil, .Out_Of_Memory
	}
	w^ = {settings = s, allocator = allocator, file = f, rng = 0x9E3779B97F4A7C15}
	w.frame_bytes = s.channels * bytes_per_sample(s.encoding)
	ae: mem.Allocator_Error
	w.scratch, ae = make([]u8, max(SCRATCH_BYTES - SCRATCH_BYTES % w.frame_bytes, w.frame_bytes), allocator)
	if ae != nil {
		os.close(f)
		free(w, allocator)
		return nil, .Out_Of_Memory
	}
	if err = write_header(w); err != .None {
		writer_close(w)
		return nil, err
	}
	return w, .None
}

// Appends `frames` frames from `input` (one slice per channel, each at least
// `frames` long). Samples are clipped to -1..1 for integer encodings.
// Allocates nothing; blocks on I/O.
writer_write :: proc(w: ^Writer, input: [][]f32, frames: int) -> Error {
	if len(input) < w.settings.channels do return .Invalid_Argument
	for ch in input[:w.settings.channels] do if len(ch) < frames do return .Invalid_Argument
	big := w.settings.format == .Aiff
	done := 0
	for done < frames {
		n := min(frames - done, len(w.scratch) / w.frame_bytes)
		buf := w.scratch[:n * w.frame_bytes]
		encode(w, buf, input, done, n, big)
		if w.settings.format == .Aiff && w.data_offset + w.data_bytes + i64(len(buf)) > 0xFFFFFFFF - 8 {
			return .Too_Large
		}
		write_exact(w.file, buf, w.data_offset + w.data_bytes) or_return
		w.data_bytes += i64(len(buf))
		w.frames += i64(n)
		done += n
	}
	if w.settings.header_interval > 0 && w.frames - w.header_at >= w.settings.header_interval {
		write_header(w) or_return
	}
	return .None
}

// Frames written so far.
writer_frames :: proc(w: ^Writer) -> i64 {
	return w.frames
}

// Finishes the header, closes the file and frees the writer (even when it
// returns an error).
writer_close :: proc(w: ^Writer) -> (err: Error) {
	if w == nil do return .None
	if w.data_bytes & 1 == 1 { // chunks are padded to even sizes
		err = write_exact(w.file, {0}, w.data_offset + w.data_bytes)
	}
	if err == .None do err = write_header(w)
	if os.close(w.file) != nil && err == .None do err = .Io_Error
	delete(w.scratch, w.allocator)
	free(w, w.allocator)
	return
}

// --- headers -----------------------------------------------------------------------------

// Rewrites the whole header for the current length. The layout never moves:
// WAV keeps a JUNK chunk where RF64's ds64 goes, so the upgrade is in place.
@(private)
write_header :: proc(w: ^Writer) -> Error {
	h: [128]u8
	n: int
	if w.settings.format == .Wav {
		n = wav_header(w, h[:])
	} else {
		n = aiff_header(w, h[:])
	}
	w.data_offset = i64(n)
	write_exact(w.file, h[:n], 0) or_return
	w.header_at = w.frames
	return .None
}

@(private)
wav_header :: proc(w: ^Writer, h: []u8) -> int {
	s := w.settings
	float := s.encoding == .Float32 || s.encoding == .Float64
	extensible := s.channels > 2
	fmt_size := 40 if extensible else 16
	data_offset := 12 + 36 + 8 + fmt_size + 8
	riff_size := i64(data_offset) - 8 + w.data_bytes + (w.data_bytes & 1)
	if riff_size > s.rf64_threshold do w.rf64 = true

	b := mem.buffer_from_slice(h)
	put_tag(&b, "RF64" if w.rf64 else "RIFF")
	put_u32le(&b, 0xFFFFFFFF if w.rf64 else u32(riff_size))
	put_tag(&b, "WAVE")
	// ds64 (RF64) or a JUNK placeholder of the same size.
	put_tag(&b, "ds64" if w.rf64 else "JUNK")
	put_u32le(&b, 28)
	if w.rf64 {
		put_u64le(&b, u64(riff_size))
		put_u64le(&b, u64(w.data_bytes))
		put_u64le(&b, u64(w.frames))
		put_u32le(&b, 0) // no table entries
	} else {
		for _ in 0 ..< 28 do append(&b, 0)
	}
	put_tag(&b, "fmt ")
	put_u32le(&b, u32(fmt_size))
	tag := u16(WAVE_FORMAT_IEEE_FLOAT if float else WAVE_FORMAT_PCM)
	put_u16le(&b, WAVE_FORMAT_EXTENSIBLE if extensible else tag)
	put_u16le(&b, u16(s.channels))
	put_u32le(&b, u32(s.sample_rate))
	put_u32le(&b, u32(s.sample_rate) * u32(w.frame_bytes))
	put_u16le(&b, u16(w.frame_bytes))
	put_u16le(&b, u16(bytes_per_sample(s.encoding) * 8))
	if extensible {
		put_u16le(&b, 22)                                    // cbSize
		put_u16le(&b, u16(bytes_per_sample(s.encoding) * 8)) // valid bits
		put_u32le(&b, 0)                                     // channel mask: unassigned
		put_u16le(&b, tag)                                   // SubFormat GUID: tag, then the fixed tail
		for x in ([14]u8{0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71}) do append(&b, x)
	}
	put_tag(&b, "data")
	put_u32le(&b, 0xFFFFFFFF if w.rf64 else u32(w.data_bytes))
	assert(len(b) == data_offset)
	return len(b)
}

@(private)
aiff_header :: proc(w: ^Writer, h: []u8) -> int {
	s := w.settings
	float := s.encoding == .Float32 || s.encoding == .Float64
	b := mem.buffer_from_slice(h)
	put_tag(&b, "FORM")
	form_size_at := len(b)
	put_u32be(&b, 0)
	put_tag(&b, "AIFC" if float else "AIFF")
	if float {
		put_tag(&b, "FVER")
		put_u32be(&b, 4)
		put_u32be(&b, 0xA2805140) // AIFC version 1
	}
	put_tag(&b, "COMM")
	put_u32be(&b, 24 if float else 18)
	put_u16be(&b, u16(s.channels))
	put_u32be(&b, u32(w.frames))
	put_u16be(&b, u16(bytes_per_sample(s.encoding) * 8))
	put_extended(&b, s.sample_rate)
	if float {
		put_tag(&b, "fl32" if s.encoding == .Float32 else "fl64")
		append(&b, 0, 0) // empty compression name (a Pascal string, padded to even)
	}
	put_tag(&b, "SSND")
	put_u32be(&b, u32(8 + w.data_bytes))
	put_u32be(&b, 0) // offset
	put_u32be(&b, 0) // block size
	form_size := i64(len(b)) - 8 + w.data_bytes + (w.data_bytes & 1)
	store_u32be(b[form_size_at:], u32(form_size))
	return len(b)
}

// --- samples -----------------------------------------------------------------------------

@(private)
encode :: proc(w: ^Writer, buf: []u8, input: [][]f32, at, n: int, big: bool) {
	e := w.settings.encoding
	bps := bytes_per_sample(e)
	pos := 0
	for i in 0 ..< n {
		for c in 0 ..< w.settings.channels {
			x := f64(input[c][at + i])
			if x != x do x = 0 // NaN
			out := buf[pos:pos + bps]
			switch e {
			case .Float32:
				store_u32(out, transmute(u32)f32(x), big)
			case .Float64:
				store_u64(out, transmute(u64)x, big)
			case .Int16, .Int24, .Int32:
				full := f64(i64(1) << uint(bps * 8 - 1))
				v := x * full
				if e == .Int16 && w.settings.dither do v += tpdf(w)
				q := i64(math.round(v))
				q = clamp(q, -i64(full), i64(full) - 1)
				for k in 0 ..< bps {
					shift := uint(8 * (bps - 1 - k)) if big else uint(8 * k)
					out[k] = u8(u64(q) >> shift)
				}
			case .Int8, .Compressed:
			}
			pos += bps
		}
	}
}

// Triangular dither of ±1 LSB.
@(private)
tpdf :: proc "contextless" (w: ^Writer) -> f64 {
	next :: proc "contextless" (s: ^u64) -> f64 {
		s^ ~= s^ << 13
		s^ ~= s^ >> 7
		s^ ~= s^ << 17
		return f64(s^ >> 11) / f64(u64(1) << 53)
	}
	return next(&w.rng) - next(&w.rng)
}

// --- bytes -------------------------------------------------------------------------------

@(private)
write_exact :: proc(f: ^os.File, buf: []u8, offset: i64) -> Error {
	done := 0
	for done < len(buf) {
		n, err := os.write_at(f, buf[done:], offset + i64(done))
		if err != nil || n <= 0 do return .Io_Error
		done += n
	}
	return .None
}

@(private)
put_tag :: proc(b: ^[dynamic]u8, tag: string) {
	for i in 0 ..< 4 do append(b, tag[i])
}

@(private)
put_u16le :: proc(b: ^[dynamic]u8, v: u16) {
	append(b, u8(v), u8(v >> 8))
}

@(private)
put_u32le :: proc(b: ^[dynamic]u8, v: u32) {
	append(b, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24))
}

@(private)
put_u64le :: proc(b: ^[dynamic]u8, v: u64) {
	put_u32le(b, u32(v))
	put_u32le(b, u32(v >> 32))
}

@(private)
put_u16be :: proc(b: ^[dynamic]u8, v: u16) {
	append(b, u8(v >> 8), u8(v))
}

@(private)
put_u32be :: proc(b: ^[dynamic]u8, v: u32) {
	append(b, u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v))
}

// IEEE 754 80-bit extended, big-endian (AIFF's sample rate).
@(private)
put_extended :: proc(b: ^[dynamic]u8, x: f64) {
	frac, exp := math.frexp(x) // x = frac · 2^exp, frac in [0.5, 1)
	put_u16be(b, u16(exp - 1 + 16383))
	mantissa := u64(math.ldexp(frac, 64))
	put_u32be(b, u32(mantissa >> 32))
	put_u32be(b, u32(mantissa))
}

@(private)
store_u32be :: proc "contextless" (b: []u8, v: u32) {
	b[0], b[1], b[2], b[3] = u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v)
}

@(private)
store_u32 :: proc "contextless" (b: []u8, v: u32, big: bool) {
	if big {
		store_u32be(b, v)
	} else {
		b[0], b[1], b[2], b[3] = u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24)
	}
}

@(private)
store_u64 :: proc "contextless" (b: []u8, v: u64, big: bool) {
	if big {
		store_u32be(b[0:], u32(v >> 32))
		store_u32be(b[4:], u32(v))
	} else {
		store_u32(b[0:], u32(v), false)
		store_u32(b[4:], u32(v >> 32), false)
	}
}
