package audiofile

import "core:io"
import "core:math"
import "core:mem"
import "core:os"

// Bytes read from disk per step of a read.
@(private)
SCRATCH_BYTES :: 64 * 1024

// An open WAV or AIFF file: where its samples are and how they are stored.
@(private)
Pcm :: struct {
	file:        ^os.File,
	data_offset: i64,  // first byte of frame 0
	frame_bytes: int,  // bytes per frame, all channels
	big_endian:  bool,
	unsigned8:   bool, // WAV 8-bit is unsigned; AIFF 8-bit is signed
	scratch:     []u8,
}

@(private)
pcm_vtable := Reader_VTable {
	read  = pcm_read,
	seek  = proc(r: ^Reader, frame: i64) -> Error { return .None }, // reads are positional
	close = proc(r: ^Reader) {
		p := (^Pcm)(r.data)
		os.close(p.file)
		delete(p.scratch, r.allocator)
		free(p, r.allocator)
	},
}

@(private)
pcm_open :: proc(path: string, allocator: mem.Allocator) -> (r: ^Reader, err: Error) {
	f, oerr := os.open(path)
	if oerr != nil do return nil, .Not_Found
	p := new(Pcm, allocator)
	if p == nil {
		os.close(f)
		return nil, .Out_Of_Memory
	}
	p.file = f
	info: Info
	defer if err != .None {
		os.close(f)
		free(p, allocator)
	}
	size, serr := os.file_size(f)
	if serr != nil do return nil, .Io_Error
	head: [12]u8
	read_exact(f, head[:], 0) or_return
	switch string(head[0:4]) {
	case "RIFF", "RF64", "BW64":
		if string(head[8:12]) != "WAVE" do return nil, .Unsupported_Format
		parse_wav(p, &info, size) or_return
	case "FORM":
		form := string(head[8:12])
		if form != "AIFF" && form != "AIFC" do return nil, .Unsupported_Format
		parse_aiff(p, &info, size, form == "AIFC") or_return
	case:
		return nil, .Unsupported_Format
	}
	if info.channels <= 0 || info.sample_rate <= 0 do return nil, .Corrupt
	p.frame_bytes = info.channels * bytes_per_sample(info.encoding)
	if p.frame_bytes == 0 do return nil, .Unsupported_Format

	// The data runs to the end of the file at most; a header from a crashed
	// recording may claim nothing or more than is there.
	available := (size - p.data_offset) / i64(p.frame_bytes)
	declared_end := p.data_offset + info.frames * i64(p.frame_bytes)
	declared_end += declared_end & 1
	if info.frames <= 0 || info.frames > available || (declared_end < size && !chunk_at(f, declared_end, size, p.big_endian)) {
		// Audio past the declared end, with no chunk there: a header that
		// was not updated before a crash.
		info.recovered = info.frames != available
		info.frames = max(available, 0)
	}
	ae: mem.Allocator_Error
	p.scratch, ae = make([]u8, SCRATCH_BYTES - SCRATCH_BYTES % p.frame_bytes, allocator)
	if ae != nil do return nil, .Out_Of_Memory
	if len(p.scratch) == 0 do return nil, .Unsupported_Format // a frame bigger than the scratch buffer
	r, err = reader_make(&pcm_vtable, p, info, allocator)
	if err != .None do delete(p.scratch, allocator)
	return
}

@(private)
pcm_read :: proc(r: ^Reader, out: [][]f32, frames: int) -> (done: int, err: Error) {
	p := (^Pcm)(r.data)
	want := int(min(i64(frames), r.info.frames - r.position))

	for done < want {
		n := min(want - done, len(p.scratch) / p.frame_bytes)
		buf := p.scratch[:n * p.frame_bytes]
		read_exact(p.file, buf, p.data_offset + (r.position + i64(done)) * i64(p.frame_bytes)) or_return
		decode(buf, out, done, n, r.info.channels, r.info.encoding, p.big_endian, p.unsigned8)
		done += n
	}
	return done, .None
}

// Converts `n` interleaved frames in `buf` to planar f32 at `out[c][at:]`.
@(private)
decode :: proc(buf: []u8, out: [][]f32, at, n, channels: int, e: Sample_Format, big_endian, unsigned8: bool) {
	bps := bytes_per_sample(e)
	for c in 0 ..< min(channels, len(out)) {
		dst := out[c][at:at + n]
		pos := c * bps
		step := channels * bps
		switch e {
		case .Int8:
			for &s in dst {
				v := unsigned8 ? f32(i32(buf[pos]) - 128) : f32(i8(buf[pos]))
				s = v / 128
				pos += step
			}
		case .Int16:
			for &s in dst {
				s = f32(i16(load_u16(buf[pos:], big_endian))) / 32768
				pos += step
			}
		case .Int24:
			for &s in dst {
				b0, b1, b2 := u32(buf[pos]), u32(buf[pos + 1]), u32(buf[pos + 2])
				u := big_endian ? b0 << 24 | b1 << 16 | b2 << 8 : b2 << 24 | b1 << 16 | b0 << 8
				s = f32(f64(i32(u)) / 2147483648)
				pos += step
			}
		case .Int32:
			for &s in dst {
				s = f32(f64(i32(load_u32(buf[pos:], big_endian))) / 2147483648)
				pos += step
			}
		case .Float32:
			for &s in dst {
				s = transmute(f32)load_u32(buf[pos:], big_endian)
				pos += step
			}
		case .Float64:
			for &s in dst {
				s = f32(transmute(f64)load_u64(buf[pos:], big_endian))
				pos += step
			}
		case .Compressed:
		}
	}
}

// --- WAV ---------------------------------------------------------------------------------

@(private)
WAVE_FORMAT_PCM        :: 0x0001
@(private)
WAVE_FORMAT_IEEE_FLOAT :: 0x0003
@(private)
WAVE_FORMAT_EXTENSIBLE :: 0xFFFE

@(private)
parse_wav :: proc(p: ^Pcm, info: ^Info, size: i64) -> Error {
	info.format = .Wav
	ds64_data: i64 = -1
	have_fmt := false
	pos := i64(12)
	for pos + 8 <= size {
		h: [8]u8
		read_exact(p.file, h[:], pos) or_return
		id := string(h[0:4])
		chunk := i64(load_u32(h[4:], false))
		body := pos + 8
		switch id {
		case "ds64": // RF64/BW64: 64-bit sizes; data size at offset 8
			b: [24]u8
			read_exact(p.file, b[:], body) or_return
			ds64_data = i64(load_u64(b[8:], false))
		case "fmt ":
			b: [40]u8
			n := int(min(chunk, 40))
			if n < 16 do return .Corrupt
			read_exact(p.file, b[:n], body) or_return
			tag := int(load_u16(b[0:], false))
			info.channels = int(load_u16(b[2:], false))
			info.sample_rate = f64(load_u32(b[4:], false))
			info.bits = int(load_u16(b[14:], false))
			if tag == WAVE_FORMAT_EXTENSIBLE {
				if n < 40 do return .Corrupt
				tag = int(load_u16(b[24:], false)) // first two bytes of the SubFormat GUID
			}
			container := info.bits
			if n >= 16 && load_u16(b[12:], false) != 0 && info.channels > 0 {
				container = int(load_u16(b[12:], false)) / info.channels * 8 // block align says the container size
			}
			switch {
			case tag == WAVE_FORMAT_PCM && container == 8:   info.encoding = .Int8
			case tag == WAVE_FORMAT_PCM && container == 16:  info.encoding = .Int16
			case tag == WAVE_FORMAT_PCM && container == 24:  info.encoding = .Int24
			case tag == WAVE_FORMAT_PCM && container == 32:  info.encoding = .Int32
			case tag == WAVE_FORMAT_IEEE_FLOAT && container == 32: info.encoding = .Float32
			case tag == WAVE_FORMAT_IEEE_FLOAT && container == 64: info.encoding = .Float64
			case: return .Unsupported_Format
			}
			have_fmt = true
		case "data":
			if !have_fmt do return .Corrupt
			p.data_offset = body
			p.unsigned8 = true
			data := chunk
			if chunk == 0xFFFFFFFF && ds64_data >= 0 do data = ds64_data
			if chunk == 0xFFFFFFFF && ds64_data < 0 do data = 0 // RF64 without ds64: recover from the file size
			info.frames = data / i64(info.channels * bytes_per_sample(info.encoding))
			return .None
		}
		pos = body + chunk + (chunk & 1) // chunks are padded to even sizes
	}
	return .Corrupt
}

// --- AIFF --------------------------------------------------------------------------------

@(private)
parse_aiff :: proc(p: ^Pcm, info: ^Info, size: i64, aifc: bool) -> Error {
	info.format = .Aiff
	p.big_endian = true
	have_comm := false
	pos := i64(12)
	for pos + 8 <= size {
		h: [8]u8
		read_exact(p.file, h[:], pos) or_return
		id := string(h[0:4])
		chunk := i64(load_u32(h[4:], true))
		body := pos + 8
		switch id {
		case "COMM":
			b: [22]u8
			n := int(min(chunk, 22))
			if n < 18 do return .Corrupt
			read_exact(p.file, b[:n], body) or_return
			info.channels = int(load_u16(b[0:], true))
			info.frames = i64(load_u32(b[2:], true))
			info.bits = int(load_u16(b[6:], true))
			info.sample_rate = extended_to_f64(b[8:18])
			compression := "NONE"
			if aifc {
				if n < 22 do return .Corrupt
				compression = string(b[18:22])
			}
			switch compression {
			case "NONE", "twos":
			case "sowt":
				p.big_endian = false
			case "fl32", "FL32":
				info.bits = 32
				info.encoding = .Float32
			case "fl64", "FL64":
				info.bits = 64
				info.encoding = .Float64
			case:
				return .Unsupported_Format
			}
			if compression != "fl32" && compression != "FL32" && compression != "fl64" && compression != "FL64" {
				switch (info.bits + 7) / 8 {
				case 1: info.encoding = .Int8
				case 2: info.encoding = .Int16
				case 3: info.encoding = .Int24
				case 4: info.encoding = .Int32
				case:   return .Unsupported_Format
				}
			}
			have_comm = true
		case "SSND":
			if !have_comm do return .Corrupt
			b: [8]u8
			read_exact(p.file, b[:], body) or_return
			p.data_offset = body + 8 + i64(load_u32(b[0:], true))
			return .None
		}
		pos = body + chunk + (chunk & 1)
	}
	return .Corrupt
}

// Whether a plausible chunk header (four printable ASCII characters and a
// size that fits in the file) starts at `pos`.
@(private)
chunk_at :: proc(f: ^os.File, pos, size: i64, big_endian: bool) -> bool {
	if pos + 8 > size do return false
	h: [8]u8
	if read_exact(f, h[:], pos) != .None do return false
	for c in h[:4] do if c < 0x20 || c > 0x7E do return false
	return pos + 8 + i64(load_u32(h[4:], big_endian)) <= size
}

// IEEE 754 80-bit extended (big-endian), as AIFF stores its sample rate.
@(private)
extended_to_f64 :: proc(b: []u8) -> f64 {
	exponent := int(load_u16(b, true) & 0x7FFF)
	mantissa := load_u64(b[2:], true)
	if exponent == 0 && mantissa == 0 do return 0
	return math.ldexp(f64(mantissa), exponent - 16383 - 63)
}

// --- bytes -------------------------------------------------------------------------------

@(private)
read_exact :: proc(f: ^os.File, buf: []u8, offset: i64) -> Error {
	got := 0
	for got < len(buf) {
		n, err := os.read_at(f, buf[got:], offset + i64(got))
		if err != nil && err != io.Error.EOF do return .Io_Error
		if n <= 0 do return .Corrupt // the file ends early
		got += n
	}
	return .None
}

@(private)
load_u16 :: #force_inline proc "contextless" (b: []u8, big: bool) -> u16 {
	return big ? u16(b[0]) << 8 | u16(b[1]) : u16(b[1]) << 8 | u16(b[0])
}

@(private)
load_u32 :: #force_inline proc "contextless" (b: []u8, big: bool) -> u32 {
	if big do return u32(b[0]) << 24 | u32(b[1]) << 16 | u32(b[2]) << 8 | u32(b[3])
	return u32(b[3]) << 24 | u32(b[2]) << 16 | u32(b[1]) << 8 | u32(b[0])
}

@(private)
load_u64 :: #force_inline proc "contextless" (b: []u8, big: bool) -> u64 {
	first, second := u64(load_u32(b[0:], big)), u64(load_u32(b[4:], big))
	return big ? first << 32 | second : second << 32 | first
}
