/*
FLAC, MP3 and Ogg Vorbis decoding, as `audiofile.Reader`s.

A separate package so that apps reading only WAV and AIFF link no C code.
Decoding uses `vendor:miniaudio`, which ships with Odin: its built-in dr_flac
and dr_mp3 decoders, and stb_vorbis compiled into it (public domain or
MIT-0). It comes prebuilt for macOS and Windows; on Linux build it once with
Odin's own script:

	"$(odin root)/vendor/miniaudio/src/build_miniaudio.sh"

`open` recognises a file by its content, not its name, and also opens WAV and
AIFF (through `audiofile.open`), so it can be the one call an app uses:

	r, err := codecs.open("loop.flac")
	if err != .None do return
	defer audiofile.close(r)
	audiofile.read(r, channels, frames)

Seeking is sample-exact in every format.
*/
package codecs

import "core:mem"
import "core:os"
import "core:strings"

import "fire:audiofile"
import ma "vendor:miniaudio"

// Most channels a compressed file may have.
MAX_CHANNELS :: 8

// Opens any file `fire:audiofile` and this package can read, recognising
// the format from its first bytes. Free with `audiofile.close`.
open :: proc(path: string, allocator := context.allocator) -> (^audiofile.Reader, audiofile.Error) {
	head: [12]u8
	{
		f, err := os.open(path)
		if err != nil do return nil, .Not_Found
		n, _ := os.read(f, head[:])
		os.close(f)
		if n < 4 do return nil, .Unsupported_Format
	}
	switch {
	case string(head[0:4]) == "RIFF", string(head[0:4]) == "RF64", string(head[0:4]) == "BW64", string(head[0:4]) == "FORM":
		return audiofile.open(path, allocator)
	case string(head[0:4]) == "fLaC":
		return open_miniaudio(path, .flac, .Flac, allocator)
	case string(head[0:4]) == "OggS":
		return open_miniaudio(path, .vorbis, .Ogg_Vorbis, allocator)
	case string(head[0:3]) == "ID3", head[0] == 0xFF && head[1] & 0xE0 == 0xE0: // ID3 tag or MPEG frame sync
		return open_miniaudio(path, .mp3, .Mp3, allocator)
	}
	return nil, .Unsupported_Format
}

// --- miniaudio decoders ------------------------------------------------------------

// Frames decoded per step (interleaved scratch, then split into channels).
@(private)
CHUNK :: 4096

@(private)
Mini :: struct {
	decoder: ma.decoder,
	scratch: []f32, // CHUNK frames, interleaved
}

@(private)
mini_vtable := audiofile.Reader_VTable {
	read = proc(r: ^audiofile.Reader, out: [][]f32, frames: int) -> (done: int, err: audiofile.Error) {
		m := (^Mini)(r.data)
		ch := r.info.channels
		for done < frames {
			want := min(frames - done, CHUNK)
			got: u64
			res := ma.decoder_read_pcm_frames(&m.decoder, raw_data(m.scratch), u64(want), &got)
			if res != .SUCCESS && res != .AT_END do return done, .Corrupt
			for c in 0 ..< min(ch, len(out)) {
				for i in 0 ..< int(got) do out[c][done + i] = m.scratch[i * ch + c]
			}
			done += int(got)
			if int(got) < want do break
		}
		return
	},
	seek = proc(r: ^audiofile.Reader, frame: i64) -> audiofile.Error {
		m := (^Mini)(r.data)
		return .None if ma.decoder_seek_to_pcm_frame(&m.decoder, u64(frame)) == .SUCCESS else .Corrupt
	},
	close = proc(r: ^audiofile.Reader) {
		m := (^Mini)(r.data)
		ma.decoder_uninit(&m.decoder)
		delete(m.scratch, r.allocator)
		free(m, r.allocator)
	},
}

@(private)
open_miniaudio :: proc(path: string, encoding: ma.encoding_format, format: audiofile.Format, allocator: mem.Allocator) -> (r: ^audiofile.Reader, err: audiofile.Error) {
	m := new(Mini, allocator)
	if m == nil do return nil, .Out_Of_Memory
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	config := ma.decoder_config_init(.f32, 0, 0) // native channels and rate
	config.encodingFormat = encoding
	if ma.decoder_init_file(cpath, &config, &m.decoder) != .SUCCESS {
		free(m, allocator)
		return nil, .Unsupported_Format
	}
	defer if err != .None {
		ma.decoder_uninit(&m.decoder)
		delete(m.scratch, allocator)
		free(m, allocator)
	}
	sample_format: ma.format
	channels, rate: u32
	if ma.decoder_get_data_format(&m.decoder, &sample_format, &channels, &rate, nil, 0) != .SUCCESS do return nil, .Corrupt
	length: u64
	if ma.decoder_get_length_in_pcm_frames(&m.decoder, &length) != .SUCCESS do return nil, .Corrupt
	if channels == 0 || channels > MAX_CHANNELS || rate == 0 do return nil, .Unsupported_Format
	ae: mem.Allocator_Error
	m.scratch, ae = make([]f32, CHUNK * int(channels), allocator)
	if ae != nil do return nil, .Out_Of_Memory
	info := audiofile.Info {
		format      = format,
		encoding    = .Compressed,
		sample_rate = f64(rate),
		channels    = int(channels),
		frames      = i64(length),
	}
	return audiofile.reader_make(&mini_vtable, m, info, allocator)
}
