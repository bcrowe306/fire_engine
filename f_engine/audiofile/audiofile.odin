/*
Reading and writing audio files.

WAV (including RF64/BW64 and WAVE_FORMAT_EXTENSIBLE) and AIFF/AIFC are read
and written by this package itself, with no C code. FLAC, MP3 and Ogg Vorbis
are decoded by `fire:audiofile/codecs`, which returns the same `Reader`.

Readers deliver planar f32 whatever the file's encoding, and seek to any
frame. A reader allocates its buffers when it opens, so `read` and `seek`
never allocate: a disk-streaming thread can use them freely. They do block on
file I/O, so never call them on the audio thread.

	r, err := audiofile.open("drums.wav")
	if err != .None do return
	defer audiofile.close(r)
	info := audiofile.info(r)
	left := make([]f32, info.frames)
	right := make([]f32, info.frames)
	audiofile.read(r, {left, right}, int(info.frames))

Writers are made for recording: the header is brought up to date every
second of audio by default, so a crash leaves a playable file, and a WAV that
grows past 4 GB becomes RF64 in place.

	w, _ := audiofile.writer_create("take.wav", audiofile.default_writer_settings(48_000, 2))
	audiofile.writer_write(w, {left, right}, frames)
	audiofile.writer_close(w)

See /guides/audio-files/ for more.
*/
package audiofile

import "core:mem"

// A container format.
Format :: enum u8 {
	Unknown,
	Wav,  // RIFF/WAVE, RF64 or BW64
	Aiff, // AIFF or AIFC
	Flac,
	Mp3,
	Ogg_Vorbis,
}

// How samples are stored in a file.
Sample_Format :: enum u8 {
	Int8,
	Int16,
	Int24,
	Int32,
	Float32,
	Float64,
	Compressed, // FLAC, MP3, Ogg Vorbis
}

// What `open` found out about a file.
Info :: struct {
	format:      Format,
	encoding:    Sample_Format,
	bits:        int,  // bits per sample as stored; 0 for compressed formats
	sample_rate: f64,  // Hz
	channels:    int,
	frames:      i64,  // length in sample frames
	recovered:   bool, // the header disagreed with the file (for instance after a crash while recording); `frames` is what the file actually holds
}

// Result of file operations.
Error :: enum u8 {
	None,
	Not_Found,          // no such file, or no permission to open it
	Io_Error,           // reading or writing failed
	Unsupported_Format, // not a format this package (or codecs) reads, or an encoding it doesn't support
	Corrupt,            // the file is damaged or truncated beyond use
	Invalid_Argument,   // a bad setting or out-of-range position
	Out_Of_Memory,
	Too_Large,          // an AIFF writer reached the format's 4 GB limit
}

// A file opened for reading. Create with `open` (or `codecs.open`); free with
// `close`. Not safe to use from two threads at once. Fields are internal.
Reader :: struct {
	info:      Info,
	vtable:    ^Reader_VTable,
	data:      rawptr,
	position:  i64,
	allocator: mem.Allocator,
}

// The operations behind a `Reader`, for decoder packages such as
// `fire:audiofile/codecs` that make readers with `reader_make`.
Reader_VTable :: struct {
	// Decode up to `frames` frames into `out` (one slice per channel, each at
	// least `frames` long), returning how many were decoded: fewer only at
	// the end of the file.
	read:  proc(r: ^Reader, out: [][]f32, frames: int) -> (int, Error),
	// Move to frame `frame` (0 ..= info.frames).
	seek:  proc(r: ^Reader, frame: i64) -> Error,
	// Free the decoder's state (but not the Reader itself).
	close: proc(r: ^Reader),
}

// For decoder packages: makes a reader around `data` and `vtable`. `close`
// calls `vtable.close` and then frees the reader with `allocator`.
reader_make :: proc(vtable: ^Reader_VTable, data: rawptr, info: Info, allocator := context.allocator) -> (^Reader, Error) {
	r := new(Reader, allocator)
	if r == nil do return nil, .Out_Of_Memory
	r^ = {info = info, vtable = vtable, data = data, allocator = allocator}
	return r, .None
}

// Opens a WAV or AIFF file for reading. Allocates its buffers now; free with
// `close`. Use `codecs.open` to also open FLAC, MP3 and Ogg Vorbis.
open :: proc(path: string, allocator := context.allocator) -> (^Reader, Error) {
	return pcm_open(path, allocator)
}

// What the file is: format, encoding, rate, channels and length.
info :: proc(r: ^Reader) -> Info {
	return r.info
}

// The frame the next `read` starts at.
position :: proc(r: ^Reader) -> i64 {
	return r.position
}

// Decodes up to `frames` frames from the current position into `out`, as
// planar f32 in -1..1. `out` needs one slice per channel, each at least
// `frames` long; extra slices are left alone, and with fewer slices than
// channels the remaining channels are skipped. Returns how many frames were
// read: fewer than asked only at the end of the file. Never allocates;
// blocks on I/O.
read :: proc(r: ^Reader, out: [][]f32, frames: int) -> (n: int, err: Error) {
	if frames <= 0 do return 0, .None
	for ch in out[:min(len(out), r.info.channels)] do if len(ch) < frames do return 0, .Invalid_Argument
	n, err = r.vtable.read(r, out, frames)
	r.position += i64(n)
	return
}

// Moves to frame `frame` (0 ..= `info(r).frames`). Exact for every format.
seek :: proc(r: ^Reader, frame: i64) -> Error {
	if frame < 0 || frame > r.info.frames do return .Invalid_Argument
	r.vtable.seek(r, frame) or_return
	r.position = frame
	return .None
}

// Closes the file and frees the reader.
close :: proc(r: ^Reader) {
	if r == nil do return
	r.vtable.close(r)
	free(r, r.allocator)
}

// Bytes per sample of a PCM encoding (0 for `.Compressed`).
bytes_per_sample :: proc "contextless" (e: Sample_Format) -> int {
	switch e {
	case .Int8:       return 1
	case .Int16:      return 2
	case .Int24:      return 3
	case .Int32:      return 4
	case .Float32:    return 4
	case .Float64:    return 8
	case .Compressed: return 0
	}
	return 0
}
