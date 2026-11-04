package record

import "base:intrinsics"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:sync"

import "fire:audiofile"
import "fire:core"
import "fire:rt"
import tb "fire:timebase"

// Frames per block handed from the audio thread to the disk.
BLOCK_FRAMES :: 4096

// Settings for `audio_recorder_create`.
Audio_Recorder_Settings :: struct {
	timeline:       core.Timeline_Id, // takes are placed on it and recorded while it plays; zero = record whenever armed
	channels:       int,       // the node's inputs, and the takes' channels
	directory:      string,    // where take files go (must exist)
	name:           string,    // take files are `<directory>/<name>-<n>.wav`, n counting from 1
	encoding:       audiofile.Sample_Format, // of the files: .Int16, .Int24, .Int32 or .Float32 (the zero value, .Int8, means .Float32)
	latency_frames: int,       // round trip to compensate: see the package doc
	buffer_seconds: f64,       // audio held for the disk at 48 kHz; 0 = 4 s
}

// A finished take: a file and where it belongs. Free its path with
// `take_destroy`.
Take :: struct {
	path:           string,   // the WAV file
	run:            int,      // counts recordings: a new run starts at each start, punch-in or locate
	pass:           int,      // loop passes within the run, from 0
	start:          tb.Beats, // timeline position of the first frame
	length:         tb.Beats, // timeline beats the take covers
	start_frame:    i64,      // clock frame (after latency compensation) of the first frame
	frames:         i64,
	sample_rate:    f64,
	channels:       int,
	dropped_frames: i64,      // written as silence because the disk fell behind
	error:          audiofile.Error, // the file could not be written (then `frames` is what was)
}

// Records its inputs to disk as takes. From `audio_recorder_create`; the
// node owns it and frees it when destroyed. Procs not marked [rt] are for
// the control thread. Fields are internal.
Audio_Recorder :: struct {
	settings:     Audio_Recorder_Settings,
	allocator:    mem.Allocator,
	disk:         ^Disk_Writer,
	blocks:       []f32, // n_blocks × channels × BLOCK_FRAMES
	n_blocks:     int,
	free_blocks:  rt.Spsc_Queue(i32), // disk → audio
	messages:     rt.Spsc_Queue(Message), // audio → disk
	commands:     rt.Spsc_Queue(Gate_Command), // control → audio
	sample_rate:  f64, // atomic bits via `rate_bits`
	rate_bits:    u64, // atomic
	recording:    bool, // atomic: a take is open
	dropped:      u64, // atomic: frames lost (written as silence), all takes
	// Audio side.
	gate:         Gate,
	block:        i32, // being filled, or -1
	fill:         int,
	gap:          i64, // frames lost since the last data, to write as silence
	// Disk side (under `disk.lock`).
	file:         ^audiofile.Writer,
	open:         Take,
	counter:      int,
	done_lock:    sync.Mutex,
	done:         [dynamic]Take,
}

@(private)
Message_Kind :: enum u8 {
	Begin, // a take starts at `pos`, `frame`
	Data,  // `frames` of `block`
	Gap,   // `frames` of silence
	End,   // the take ends at `pos`
}

@(private)
Message :: struct {
	kind:   Message_Kind,
	block:  i32,
	run:    i32,
	pass:   i32,
	frames: i64,
	frame:  i64,
	pos:    tb.Beats,
}

@(private)
audio_recorder_vtable := core.Node_VTable {
	prepare = proc(self: rawptr, cfg: core.Prepare_Config, allocator: mem.Allocator) -> core.Error {
		r := (^Audio_Recorder)(self)
		intrinsics.atomic_store(&r.rate_bits, transmute(u64)cfg.sample_rate)
		return .None
	},
	process = audio_recorder_process,
	reset   = proc(self: rawptr) {},
	release = proc(self: rawptr, allocator: mem.Allocator) {},
	destroy = proc(self: rawptr, allocator: mem.Allocator) { audio_recorder_free((^Audio_Recorder)(self)) },
}

// Control thread. Makes a recorder node with `settings.channels` inputs and
// no outputs, served by `disk`. `.Invalid_Argument` without channels, a
// directory or a name.
audio_recorder_create :: proc(disk: ^Disk_Writer, settings: Audio_Recorder_Settings, allocator := context.allocator) -> (node: core.Node, r: ^Audio_Recorder, err: core.Error) {
	if disk == nil || settings.channels < 1 || settings.directory == "" || settings.name == "" || settings.latency_frames < 0 {
		return {}, nil, .Invalid_Argument
	}
	r = new(Audio_Recorder, allocator)
	if r == nil do return {}, nil, .Out_Of_Memory
	r.settings, r.allocator, r.disk = settings, allocator, disk
	r.gate = {timeline = settings.timeline, latency = settings.latency_frames}
	if r.settings.encoding == .Int8 do r.settings.encoding = .Float32 // the zero value
	seconds := settings.buffer_seconds if settings.buffer_seconds > 0 else 4
	r.n_blocks = max(int(math.ceil(seconds * 48_000 / BLOCK_FRAMES)), 2)
	r.block, r.done = -1, make([dynamic]Take, allocator)
	ae: mem.Allocator_Error
	r.blocks, ae = make([]f32, r.n_blocks * settings.channels * BLOCK_FRAMES, allocator)
	if ae == nil do ae = rt.spsc_init(&r.free_blocks, r.n_blocks, allocator)
	if ae == nil do ae = rt.spsc_init(&r.messages, 2 * r.n_blocks + 64, allocator)
	if ae == nil do ae = rt.spsc_init(&r.commands, 64, allocator)
	if ae != nil {
		audio_recorder_free(r)
		return {}, nil, .Out_Of_Memory
	}
	for &x in r.blocks do x = 0 // touch every page now, not on the audio thread
	for i in 0 ..< r.n_blocks do rt.spsc_push(&r.free_blocks, i32(i))
	{
		sync.guard(&disk.lock)
		append(&disk.recorders, r)
	}
	return core.node_make(&audio_recorder_vtable, r, allocator), r, .None
}

// Control thread. Arms or disarms the recorder, from its next block. Armed,
// it records while its timeline plays (and inside the punch range, if set).
audio_recorder_arm :: proc(r: ^Audio_Recorder, armed: bool) -> core.Error {
	return push_command(r, {kind = .Arm if armed else .Disarm})
}

// Control thread. Changes `latency_frames`, from the next block: set it
// once the device runs, from `backend.round_trip_latency_frames`. Not while
// recording.
audio_recorder_set_latency :: proc(r: ^Audio_Recorder, frames: int) -> core.Error {
	if frames < 0 do return .Invalid_Argument
	return push_command(r, {kind = .Latency, a = tb.Beats(frames)})
}

// Control thread. Records only from timeline position `punch_in` to
// `punch_out` (after latency compensation).
audio_recorder_set_punch :: proc(r: ^Audio_Recorder, punch_in, punch_out: tb.Beats) -> core.Error {
	if !(punch_out > punch_in) do return .Invalid_Argument
	return push_command(r, {kind = .Punch, a = punch_in, b = punch_out})
}

// Control thread. Removes the punch range.
audio_recorder_clear_punch :: proc(r: ^Audio_Recorder) -> core.Error {
	return push_command(r, {kind = .No_Punch})
}

// Control thread. The next finished take, if any (iterate with `for take in`).
// The caller owns it: free with `take_destroy`.
audio_recorder_poll :: proc(r: ^Audio_Recorder) -> (take: Take, ok: bool) {
	if r.disk.settings.manual do disk_writer_service(r.disk)
	sync.guard(&r.done_lock)
	if len(r.done) == 0 do return {}, false
	take = r.done[0]
	ordered_remove(&r.done, 0)
	return take, true
}

// [rt] Whether a take is being recorded, and the frames lost so far because
// the disk fell behind (written as silence).
audio_recorder_status :: proc "contextless" (r: ^Audio_Recorder) -> (recording: bool, dropped_frames: u64) {
	return intrinsics.atomic_load(&r.recording), intrinsics.atomic_load(&r.dropped)
}

// Frees a take's path (the file stays).
take_destroy :: proc(t: ^Take, allocator := context.allocator) {
	delete(t.path, allocator)
	t^ = {}
}

@(private)
push_command :: proc(r: ^Audio_Recorder, c: Gate_Command) -> core.Error {
	return .None if rt.spsc_push(&r.commands, c) else .Out_Of_Memory
}

// Unregisters from the disk, finishes the open file, frees everything.
@(private)
audio_recorder_free :: proc(r: ^Audio_Recorder) {
	if r.disk != nil {
		sync.guard(&r.disk.lock)
		for x, i in r.disk.recorders do if x == r {
			ordered_remove(&r.disk.recorders, i)
			break
		}
		serve(r)
		if r.file != nil do finish(r)
	}
	for &t in r.done do take_destroy(&t, r.allocator)
	delete(r.done)
	rt.spsc_destroy(&r.free_blocks, r.allocator)
	rt.spsc_destroy(&r.messages, r.allocator)
	rt.spsc_destroy(&r.commands, r.allocator)
	delete(r.blocks, r.allocator)
	free(r, r.allocator)
}

// --- the audio side ----------------------------------------------------------------------

// [rt]
@(private)
audio_recorder_process :: proc(self: rawptr, ctx: ^core.Process_Context) {
	r := (^Audio_Recorder)(self)
	for c in rt.spsc_pop(&r.commands) do gate_command(&r.gate, c)
	gate_process(&r.gate, ctx, {
		user = r,
		begin = proc "contextless" (user: rawptr, g: ^Gate, frame: i64, pos: tb.Beats) -> bool {
			r := (^Audio_Recorder)(user)
			r.gap = 0
			return rt.spsc_push(&r.messages, Message{kind = .Begin, run = g.run, pass = g.pass, frame = frame, pos = pos})
		},
		data = proc "contextless" (user: rawptr, g: ^Gate, e: ^History, a, b: i64, at: int) {
			write((^Audio_Recorder)(user), g.ctx, at, int(b - a))
		},
		end = proc "contextless" (user: rawptr, g: ^Gate) {
			r := (^Audio_Recorder)(user)
			if r.block >= 0 && r.fill > 0 do flush(r)
			push_gap(r)
			if !rt.spsc_push(&r.messages, Message{kind = .End, pos = g.last_pos}) {
				intrinsics.atomic_add(&r.dropped, 1) // the disk closes it on the next Begin
			}
		},
	})
	intrinsics.atomic_store(&r.recording, r.gate.taking)
}

// [rt] Copies `frames` input frames from offset `at` into blocks.
@(private)
write :: proc "contextless" (r: ^Audio_Recorder, ctx: ^core.Process_Context, at, frames: int) {
	ch := r.settings.channels
	for done := 0; done < frames; {
		if r.block < 0 {
			block, ok := rt.spsc_pop(&r.free_blocks)
			if !ok {
				r.gap += i64(frames - done) // the disk is behind
				intrinsics.atomic_add(&r.dropped, u64(frames - done))
				return
			}
			push_gap(r)
			r.block, r.fill = block, 0
		}
		n := min(frames - done, BLOCK_FRAMES - r.fill)
		for c in 0 ..< ch {
			dst := r.blocks[(int(r.block) * ch + c) * BLOCK_FRAMES + r.fill:][:n]
			if c < len(ctx.inputs) {
				copy(dst, ctx.inputs[c][at + done:][:n])
			} else {
				for &x in dst do x = 0
			}
		}
		r.fill += n
		done += n
		if r.fill == BLOCK_FRAMES do flush(r)
	}
}

// [rt] Hands the block being filled to the disk.
@(private)
flush :: proc "contextless" (r: ^Audio_Recorder) {
	if rt.spsc_push(&r.messages, Message{kind = .Data, block = r.block, frames = i64(r.fill)}) {
		r.block = -1
	} else { // no room: keep the block, lose its frames
		r.gap += i64(r.fill)
		intrinsics.atomic_add(&r.dropped, u64(r.fill))
	}
	r.fill = 0
}

// [rt]
@(private)
push_gap :: proc "contextless" (r: ^Audio_Recorder) {
	if r.gap > 0 && rt.spsc_push(&r.messages, Message{kind = .Gap, frames = r.gap}) do r.gap = 0
}

// --- the disk side (under disk.lock) -----------------------------------------------------

// Handles every queued message. Returns whether there were any.
@(private)
serve :: proc(r: ^Audio_Recorder) -> bool {
	worked := false
	for m in rt.spsc_pop(&r.messages) {
		worked = true
		switch m.kind {
		case .Begin:
			if r.file != nil || r.open.path != "" do finish(r)
			start(r, m)
		case .Data:
			if r.file != nil && r.open.error == .None {
				ch := r.settings.channels
				planes: [MAX_CHANNELS][]f32
				for c in 0 ..< min(ch, MAX_CHANNELS) do planes[c] = r.blocks[(int(m.block) * ch + c) * BLOCK_FRAMES:][:m.frames]
				r.open.error = audiofile.writer_write(r.file, planes[:min(ch, MAX_CHANNELS)], int(m.frames))
			}
			r.open.frames += m.frames
			rt.spsc_push(&r.free_blocks, m.block)
		case .Gap:
			write_silence(r, m.frames)
			r.open.frames += m.frames
			r.open.dropped_frames += m.frames
		case .End:
			r.open.length = m.pos - r.open.start
			finish(r)
		}
	}
	return worked
}

// Most channels a take may have.
MAX_CHANNELS :: 64

@(private)
start :: proc(r: ^Audio_Recorder, m: Message) {
	r.counter += 1
	rate := transmute(f64)intrinsics.atomic_load(&r.rate_bits)
	name := fmt.tprintf("%s-%d.wav", r.settings.name, r.counter)
	path, _ := filepath.join({r.settings.directory, name}, r.allocator)
	r.open = {
		path = path, run = int(m.run), pass = int(m.pass), start = m.pos,
		start_frame = m.frame, sample_rate = rate, channels = r.settings.channels,
	}
	ws := audiofile.default_writer_settings(rate, r.settings.channels)
	ws.encoding = r.settings.encoding
	r.file, r.open.error = audiofile.writer_create(path, ws, r.allocator)
}

// Closes the open take and hands it to the control thread.
@(private)
finish :: proc(r: ^Audio_Recorder) {
	if r.file != nil {
		if err := audiofile.writer_close(r.file); r.open.error == .None do r.open.error = err
		r.file = nil
	}
	if r.open.frames == 0 && r.open.error == .None {
		os.remove(r.open.path)
		delete(r.open.path, r.allocator)
	} else {
		sync.guard(&r.done_lock)
		append(&r.done, r.open)
	}
	r.open = {}
}

@(private)
write_silence :: proc(r: ^Audio_Recorder, frames: i64) {
	if r.file == nil || r.open.error != .None do return
	zero: [BLOCK_FRAMES]f32
	planes: [MAX_CHANNELS][]f32
	ch := min(r.settings.channels, MAX_CHANNELS)
	for left := frames; left > 0; {
		n := min(left, BLOCK_FRAMES)
		for c in 0 ..< ch do planes[c] = zero[:n]
		r.open.error = audiofile.writer_write(r.file, planes[:ch], int(n))
		if r.open.error != .None do return
		left -= n
	}
}
