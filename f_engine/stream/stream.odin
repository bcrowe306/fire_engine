/*
Disk streaming: audio files read ahead on background threads, so the audio
thread can play any number of them without ever touching the disk.

- A `Source` is a file, opened once and shared. Short files (by default, up
  to 16 MB once decoded) are decoded completely into memory in the
  background; longer ones are streamed.
- A `Stream` is a playback cursor on a source, one per playing clip or
  voice. The audio thread reads it with `stream_read` and jumps with
  `stream_seek`; disk threads keep a couple of seconds buffered ahead.
- **Cues** are positions given when the stream is created (a clip's start,
  its loop start) whose first second or so is decoded into memory ahead of
  time. A jump to a cue is instant while the disk catches up, so quantized
  launches and loop wraps never drop out.

The audio thread never waits: if data has not arrived it plays silence and
the stream counts an underrun.

	s, _ := stream.create(stream.default_settings())
	defer stream.destroy(s)

	src, _ := stream.source_open(s, "vocals.wav")
	defer stream.source_release(src)
	st, _ := stream.stream_create(s, src, cues = {0, 96_000})
	defer stream.stream_destroy(st)

	// Audio thread:
	stream.stream_read(st, out, frames)  // planar f32 at the file's sample rate
	stream.stream_seek(st, 96_000)       // a cue: instant

Frames are at the file's own sample rate; convert with `dsp.Resampler`.
Open compressed files by setting `Settings.open` to `codecs.open`.
*/
package stream

import "base:intrinsics"
import "core:mem"
import "core:strings"
import "core:thread"
import "core:time"

import "fire:audiofile"
import "fire:core"
import "fire:rt"

// Frames per streaming block.
BLOCK_FRAMES :: 4096

// Most cues one stream may have.
MAX_CUES :: 16

// Opens a file for reading: `audiofile.open` (WAV, AIFF) by default, or
// `codecs.open` for FLAC, MP3 and Ogg too.
Open_Proc :: proc(path: string, allocator: mem.Allocator) -> (^audiofile.Reader, audiofile.Error)

// Streamer-wide settings. Start from `default_settings`.
Settings :: struct {
	threads:        int,       // disk threads
	buffer_seconds: f64,       // read-ahead per stream
	cue_seconds:    f64,       // decoded at each cue, so jumps there are instant; must cover the disk's worst delay
	ram_bytes:      int,       // files whose decoded size (frames × channels × 4) is at most this are loaded into memory
	max_streams:    int,       // streams that can exist at once
	open:           Open_Proc, // how files are opened
}

// Two disk threads, 2 s of read-ahead, 1 s at each cue, files up to 16 MB
// decoded into memory, WAV and AIFF.
default_settings :: proc() -> Settings {
	return {
		threads        = 2,
		buffer_seconds = 2,
		cue_seconds    = 1,
		ram_bytes      = 16 << 20,
		max_streams    = 256,
		open           = audiofile.open,
	}
}

// Owns the disk threads, the sources and the streams. Create with `create`;
// every proc not marked [rt] is control thread only. Fields are internal.
Streamer :: struct {
	settings:  Settings,
	allocator: mem.Allocator,
	threads:   [dynamic]^thread.Thread,
	disks:     []Disk_Thread,
	running:   bool, // atomic
	sources:   map[string]^Source, // by path
	slots:     []^Stream, // atomic pointers; nil = free
	pending:   []^Source, // sources waiting to be loaded into memory; atomic pointers
	underruns: u64, // atomic: frames played as silence for lack of data, all streams
}

// Whether a source's data can be played.
Source_State :: enum u8 {
	Loading, // being decoded into memory
	Ready,
	Failed,  // the file could not be read; streams on it play silence
}

// An open file, shared by every stream that plays it. From `source_open`;
// release with `source_release`. Fields are internal.
Source :: struct {
	streamer: ^Streamer,
	path:     string,
	info:     audiofile.Info,
	refs:     int, // control thread
	ram:      [][]f32, // the whole file, when loaded into memory; nil when streamed
	reader:   ^audiofile.Reader, // used to load `ram`, then closed
	state:    Source_State, // atomic; a loading thread sets it last and then never touches the source
}

// A playback cursor on a source. From `stream_create`; free with
// `stream_destroy`. `stream_read` and `stream_seek` are for one audio thread.
// Fields are internal.
Stream :: struct {
	streamer:  ^Streamer,
	source:    ^Source,
	slot:      int,
	// Disk side.
	reader:    ^audiofile.Reader, // nil for sources in memory
	busy:      bool, // atomic: a disk thread is working on this stream
	prod_gen:  u32,
	prod_pos:  i64,
	blocks:    []Block,
	filled:    rt.Spsc_Queue(i32), // disk → audio
	free:      rt.Spsc_Queue(i32), // audio → disk
	cues:      [MAX_CUES]Cue,
	cue_count: int,
	cue_frames: int,
	// Audio → disk: where to read next, as generation << 40 | frame.
	request:   u64, // atomic
	finished:  u64, // atomic: the request the disk has read to the end of the file for
	// Audio side.
	position:  i64,
	gen:       u32,
	current:   i32, // block being read, or -1
	cue:       int, // cue being played from memory, or -1
	underruns: u64, // atomic: frames of silence for lack of data
}

@(private)
Disk_Thread :: struct {
	streamer: ^Streamer,
	epoch:    u64, // atomic: bumped every loop, when the thread holds no stream pointers
}

@(private)
Block :: struct {
	gen:    u32,
	start:  i64,
	frames: int,
	data:   [][]f32,
}

@(private)
Cue :: struct {
	frame:  i64,
	frames: int,
	data:   [][]f32,
	ready:  bool, // atomic: decoded
}

// Counters, readable from any thread.
Stats :: struct {
	underrun_frames: u64, // frames played as silence for lack of data, all streams
	streams:         int,
}

// Control thread. Starts the disk threads. Free with `destroy`.
create :: proc(settings: Settings, allocator := context.allocator) -> (s: ^Streamer, err: core.Error) {
	if settings.threads < 1 || !(settings.buffer_seconds > 0) || settings.cue_seconds < 0 || settings.max_streams < 1 || settings.open == nil {
		return nil, .Invalid_Argument
	}
	s = new(Streamer, allocator)
	if s == nil do return nil, .Out_Of_Memory
	s.settings, s.allocator = settings, allocator
	s.sources = make(map[string]^Source, allocator)
	s.slots = make([]^Stream, settings.max_streams, allocator)
	s.pending = make([]^Source, settings.max_streams, allocator)
	s.threads = make([dynamic]^thread.Thread, allocator)
	s.disks = make([]Disk_Thread, settings.threads, allocator)
	if s.slots == nil || s.pending == nil || s.disks == nil {
		destroy(s)
		return nil, .Out_Of_Memory
	}
	intrinsics.atomic_store(&s.running, true)
	for &d in s.disks {
		d.streamer = s
		th := thread.create_and_start_with_data(&d, disk_main)
		if th == nil {
			destroy(s)
			return nil, .Out_Of_Memory
		}
		append(&s.threads, th)
	}
	return s, .None
}

// Control thread. Stops the disk threads and frees everything, including
// streams and sources not yet released. Nothing may be reading a stream.
destroy :: proc(s: ^Streamer) {
	if s == nil do return
	intrinsics.atomic_store(&s.running, false)
	for th in s.threads {
		thread.join(th)
		thread.destroy(th)
	}
	delete(s.threads)
	for st in s.slots do if st != nil do free_stream(st)
	for _, src in s.sources do free_source(src)
	delete(s.sources)
	delete(s.slots, s.allocator)
	delete(s.pending, s.allocator)
	delete(s.disks, s.allocator)
	free(s, s.allocator)
}

// Any thread. Counters.
stats :: proc "contextless" (s: ^Streamer) -> Stats {
	n := 0
	for i in 0 ..< len(s.slots) do if intrinsics.atomic_load(&s.slots[i]) != nil do n += 1
	return {underrun_frames = intrinsics.atomic_load(&s.underruns), streams = n}
}

// --- sources -----------------------------------------------------------------------------

// Control thread. Opens `path`, or returns the source already open for it
// (counting another reference). Small files start loading into memory in
// the background; check `source_state`. Release with `source_release`.
source_open :: proc(s: ^Streamer, path: string) -> (result: ^Source, err: audiofile.Error) {
	if src, ok := s.sources[path]; ok {
		src.refs += 1
		return src, .None
	}
	r := s.settings.open(path, s.allocator) or_return
	src := new(Source, s.allocator)
	src^ = {streamer = s, path = strings.clone(path, s.allocator), info = audiofile.info(r), refs = 1, state = .Ready}
	decoded := src.info.frames * i64(src.info.channels) * 4
	if decoded <= i64(s.settings.ram_bytes) && src.info.frames > 0 {
		src.ram = make([][]f32, src.info.channels, s.allocator)
		for &c in src.ram do c = make([]f32, src.info.frames, s.allocator)
		src.reader, src.state = r, .Loading
		queued := false
		for &p in s.pending {
			if _, ok := intrinsics.atomic_compare_exchange_strong(&p, nil, src); ok {
				queued = true
				break
			}
		}
		if !queued do load_source(src) // every disk thread busy with loads: do it here
	} else {
		audiofile.close(r)
	}
	s.sources[src.path] = src
	return src, .None
}

// Control thread. Adds a reference, for something else that keeps the
// source (a clip, say). Each reference is dropped with `source_release`.
source_retain :: proc(src: ^Source) {
	if src != nil do src.refs += 1
}

// Control thread. Drops a reference; the source is freed with the last one.
// Streams keep their own reference, so a source can be released while its
// streams play.
source_release :: proc(src: ^Source) {
	if src == nil do return
	src.refs -= 1
	if src.refs > 0 do return
	s := src.streamer
	// Take the load back if no disk thread has; otherwise wait for it.
	taken := false
	for &p in s.pending {
		if _, ok := intrinsics.atomic_compare_exchange_strong(&p, src, nil); ok do taken = true
	}
	if !taken do for intrinsics.atomic_load(&src.state) == .Loading do time.sleep(time.Millisecond)
	delete_key(&s.sources, src.path)
	free_source(src)
}

// Any thread. What the file is.
source_info :: proc "contextless" (src: ^Source) -> audiofile.Info {
	return src.info
}

// Any thread. Whether the source can be played (see `Source_State`).
source_state :: proc "contextless" (src: ^Source) -> Source_State {
	return intrinsics.atomic_load(&src.state)
}

// Any thread. Whether the source is held in memory (rather than streamed).
source_in_memory :: proc "contextless" (src: ^Source) -> bool {
	return src.ram != nil
}

@(private)
free_source :: proc(src: ^Source) {
	a := src.streamer.allocator
	if src.reader != nil do audiofile.close(src.reader)
	for c in src.ram do delete(c, a)
	delete(src.ram, a)
	delete(src.path, a)
	free(src, a)
}

// --- streams -----------------------------------------------------------------------------

// Control thread. Makes a stream on `src`, positioned at `start` (in the
// source's frames). Each frame in `cues` gets `Settings.cue_seconds`
// decoded in memory so `stream_seek` to it is instant. Allocates its
// buffers now and opens its own file handle (for streamed sources).
// Reading starts in the background at once; `stream_ready` says when the
// start and every cue are buffered.
stream_create :: proc(s: ^Streamer, src: ^Source, cues: []i64 = nil, start: i64 = 0) -> (st: ^Stream, err: audiofile.Error) {
	if len(cues) > MAX_CUES || start < 0 do return nil, .Invalid_Argument
	slot := -1
	for p, i in s.slots do if p == nil {
		slot = i
		break
	}
	if slot < 0 do return nil, .Out_Of_Memory
	a := s.allocator
	st = new(Stream, a)
	st^ = {streamer = s, source = src, slot = slot, current = -1, cue = -1, position = start, gen = 1, prod_gen = 0}
	src.refs += 1
	defer if err != .None do free_stream(st)
	info := src.info
	if src.ram == nil {
		st.reader = s.settings.open(src.path, a) or_return
		count := max(3, int(s.settings.buffer_seconds * info.sample_rate / BLOCK_FRAMES + 0.999))
		st.blocks = make([]Block, count, a)
		if rt.spsc_init(&st.filled, count, a) != nil || rt.spsc_init(&st.free, count, a) != nil do return st, .Out_Of_Memory
		for &b, i in st.blocks {
			b.data = make([][]f32, info.channels, a)
			for &c in b.data do c = make([]f32, BLOCK_FRAMES, a)
			rt.spsc_push(&st.free, i32(i))
		}
		st.cue_frames = int(s.settings.cue_seconds * info.sample_rate)
		for f in cues {
			if f < 0 || f >= info.frames || st.cue_frames == 0 do continue
			c := &st.cues[st.cue_count]
			c.frame, c.frames = f, int(min(i64(st.cue_frames), info.frames - f))
			c.data = make([][]f32, info.channels, a)
			for &ch in c.data do ch = make([]f32, c.frames, a)
			st.cue_count += 1
		}
	}
	intrinsics.atomic_store(&st.request, pack(st.gen, start))
	intrinsics.atomic_store(&s.slots[slot], st)
	return st, .None
}

// Control thread. Frees a stream, after waiting (briefly) until no disk
// thread can still hold it. The audio thread must have stopped using it.
stream_destroy :: proc(st: ^Stream) {
	if st == nil do return
	s := st.streamer
	intrinsics.atomic_store(&s.slots[st.slot], nil)
	// A disk thread that read the slot before we cleared it is still in the
	// same loop; once every thread's epoch moves on, none can.
	seen := make([]u64, len(s.disks), context.temp_allocator)
	for &d, i in s.disks do seen[i] = intrinsics.atomic_load(&d.epoch)
	for &d, i in s.disks {
		for intrinsics.atomic_load(&s.running) && intrinsics.atomic_load(&d.epoch) == seen[i] do time.sleep(100 * time.Microsecond)
	}
	free_stream(st)
}

// Any thread. Whether the stream can play without a dropout from its
// current position and from every cue: its source is ready, its cues are
// decoded and its read-ahead is at least half full. Poll it before a
// quantized launch to preroll.
stream_ready :: proc "contextless" (st: ^Stream) -> bool {
	if intrinsics.atomic_load(&st.source.state) != .Ready do return false
	if st.source.ram != nil do return true
	for i in 0 ..< st.cue_count do if !intrinsics.atomic_load(&st.cues[i].ready) do return false
	return rt.spsc_len(&st.filled) * 2 >= len(st.blocks)
}

// Any thread. Frames this stream has played as silence for lack of data.
stream_underruns :: proc "contextless" (st: ^Stream) -> u64 {
	return intrinsics.atomic_load(&st.underruns)
}

@(private)
free_stream :: proc(st: ^Stream) {
	a := st.streamer.allocator
	if st.reader != nil do audiofile.close(st.reader)
	for b in st.blocks {
		for c in b.data do delete(c, a)
		delete(b.data, a)
	}
	delete(st.blocks, a)
	rt.spsc_destroy(&st.filled, a)
	rt.spsc_destroy(&st.free, a)
	for c in st.cues[:st.cue_count] {
		for ch in c.data do delete(ch, a)
		delete(c.data, a)
	}
	source_release(st.source)
	free(st, a)
}

@(private)
pack :: #force_inline proc "contextless" (gen: u32, frame: i64) -> u64 {
	return u64(gen & 0xFFFFFF) << 40 | u64(frame) & (1 << 40 - 1)
}

@(private)
unpack :: #force_inline proc "contextless" (r: u64) -> (gen: u32, frame: i64) {
	return u32(r >> 40), i64(r & (1 << 40 - 1))
}
