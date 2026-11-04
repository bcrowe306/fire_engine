package test_stream

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

import "fire:audiofile"
import "fire:stream"
import kit "fire:testkit"

SR :: 48_000

// Frame i of a test file holds (i + 1) / 2^24 on channel 0 and its negative
// on channel 1, so every frame says where it came from (and silence, 0,
// can't be mistaken for data).
value :: proc(i: i64) -> f32 {
	return f32(i + 1) / (1 << 24)
}

// Writes (once per process) a float WAV of `frames` frames encoding its
// positions; returns its path.
test_file :: proc(name: string, frames: int) -> string {
	@(static) mutex: sync.Mutex
	sync.guard(&mutex)
	dir := os.get_env("FIRE_ARTIFACTS_DIR", context.temp_allocator)
	if dir == "" do dir = "."
	sub, _ := filepath.join({dir, "stream"}, context.temp_allocator)
	_ = os.make_directory_all(sub)
	path, _ := filepath.join({sub, name}, context.temp_allocator)
	if os.exists(path) do return path
	tmp := fmt.aprintf("%s.part", path, allocator = context.temp_allocator)
	s := audiofile.default_writer_settings(SR, 2)
	s.encoding = .Float32
	w, _ := audiofile.writer_create(tmp, s)
	l, r: [4096]f32
	for at := 0; at < frames; at += 4096 {
		n := min(4096, frames - at)
		for i in 0 ..< n {
			l[i] = value(i64(at + i))
			r[i] = -l[i]
		}
		audiofile.writer_write(w, {l[:], r[:]}, n)
	}
	audiofile.writer_close(w)
	_ = os.rename(tmp, path)
	return path
}

// Checks frames read from `start`: each is the file's frame or silence.
// Returns the number of silent frames, or -1 (after failing) on wrong data.
check :: proc(t: ^testing.T, out: [2][]f32, start: i64, frames: int, file_frames: i64, loc := #caller_location) -> int {
	silent := 0
	for i in 0 ..< frames {
		pos := start + i64(i)
		if pos >= file_frames {
			if out[0][i] != 0 {
				testing.expectf(t, false, "frame %d past the end is %v", pos, out[0][i], loc = loc)
				return -1
			}
			continue
		}
		if out[0][i] == 0 && out[1][i] == 0 {
			silent += 1
			continue
		}
		if out[0][i] != value(pos) || out[1][i] != -value(pos) {
			testing.expectf(t, false, "frame %d holds %v (frame %v)", pos, out[0][i], out[0][i] * (1 << 24) - 1, loc = loc)
			return -1
		}
	}
	return silent
}

wait_ready :: proc(t: ^testing.T, st: ^stream.Stream) -> bool {
	start := time.tick_now()
	for !stream.stream_ready(st) {
		if time.tick_since(start) > 5 * time.Second {
			testing.expect(t, false, "stream never became ready")
			return false
		}
		time.sleep(time.Millisecond)
	}
	return true
}

streaming_settings :: proc() -> stream.Settings {
	s := stream.default_settings()
	s.ram_bytes = 0 // stream everything
	s.buffer_seconds = 0.5
	s.cue_seconds = 0.25
	return s
}

// Read paced at 4× real time, a streamed file arrives complete and in
// order, without underruns.
@(test)
streams_a_file_exactly :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 60 * time.Second)
	path := test_file("ten_seconds.wav", 10 * SR)
	s, _ := stream.create(streaming_settings())
	defer stream.destroy(s)
	src, err := stream.source_open(s, path)
	if !testing.expect_value(t, err, audiofile.Error.None) do return
	defer stream.source_release(src)
	testing.expect(t, !stream.source_in_memory(src))
	st, _ := stream.stream_create(s, src)
	defer stream.stream_destroy(st)
	if !wait_ready(t, st) do return

	out := [2][]f32{make([]f32, 4096, context.temp_allocator), make([]f32, 4096, context.temp_allocator)}
	rng := kit.Rng{state = 5}
	pos := i64(0)
	for pos < 10 * SR + 1000 {
		n := kit.rng_range(&rng, 1, 1024)
		got := stream.stream_read(st, {out[0][:n], out[1][:n]}, n)
		if check(t, out, pos, n, 10 * SR) != 0 do break
		testing.expect(t, got == int(min(i64(n), max(10 * SR - pos, 0))))
		pos += i64(n)
		time.sleep(time.Duration(f64(n) / SR / 4 * 1e9))
	}
	testing.expect_value(t, stream.stream_underruns(st), 0)
}

// A seek to a cue plays at once from memory, and the disk catches up before
// the cue runs out.
@(test)
cue_jumps_are_instant :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 60 * time.Second)
	path := test_file("ten_seconds.wav", 10 * SR)
	s, _ := stream.create(streaming_settings())
	defer stream.destroy(s)
	src, _ := stream.source_open(s, path)
	defer stream.source_release(src)
	st, _ := stream.stream_create(s, src, cues = {0, 200_000, 400_000})
	defer stream.stream_destroy(st)
	if !wait_ready(t, st) do return

	out := [2][]f32{make([]f32, 512, context.temp_allocator), make([]f32, 512, context.temp_allocator)}
	for target in ([]i64{400_000, 0, 200_000, 400_000}) {
		stream.stream_seek(st, target)
		// Straight away and for two seconds after, paced at real time.
		pos := target
		for _ in 0 ..< 2 * SR / 512 {
			stream.stream_read(st, {out[0][:], out[1][:]}, 512)
			testing.expectf(t, check(t, out, pos, 512, 10 * SR) == 0, "silence %d frames after jumping to cue %d", pos - target, target)
			pos += 512
			time.sleep(time.Duration(10_666_667)) // 512 frames at 48 kHz
		}
	}
	testing.expect_value(t, stream.stream_underruns(st), 0)
}

// A jump elsewhere may be silent briefly (counted), then data is right.
@(test)
seeks_without_a_cue_recover :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 60 * time.Second)
	path := test_file("ten_seconds.wav", 10 * SR)
	s, _ := stream.create(streaming_settings())
	defer stream.destroy(s)
	src, _ := stream.source_open(s, path)
	defer stream.source_release(src)
	st, _ := stream.stream_create(s, src)
	defer stream.stream_destroy(st)
	out := [2][]f32{make([]f32, 256, context.temp_allocator), make([]f32, 256, context.temp_allocator)}
	silent := 0
	for target in ([]i64{123_457, 9, 479_000, 333_333}) {
		stream.stream_seek(st, target)
		pos := target
		for _ in 0 ..< 40 {
			stream.stream_read(st, {out[0][:], out[1][:]}, 256)
			n := check(t, out, pos, 256, 10 * SR)
			if n < 0 do return
			silent += n
			pos += 256
			time.sleep(time.Millisecond)
		}
		// By now it plays.
		stream.stream_read(st, {out[0][:], out[1][:]}, 256)
		testing.expect_value(t, check(t, out, pos, 256, 10 * SR), 0)
	}
	testing.expect_value(t, int(stream.stream_underruns(st)), silent)
}

// Short files are decoded into memory: any position, any time.
@(test)
short_files_play_from_memory :: proc(t: ^testing.T) {
	path := test_file("one_second.wav", SR)
	s, _ := stream.create(stream.default_settings())
	defer stream.destroy(s)
	src, _ := stream.source_open(s, path)
	defer stream.source_release(src)
	again, _ := stream.source_open(s, path)
	testing.expect(t, again == src, "the same path gives the same source")
	stream.source_release(again)
	testing.expect(t, stream.source_in_memory(src))
	st, _ := stream.stream_create(s, src)
	defer stream.stream_destroy(st)
	if !wait_ready(t, st) do return
	out := [2][]f32{make([]f32, 300, context.temp_allocator), make([]f32, 300, context.temp_allocator)}
	for target in ([]i64{47_900, 0, 12_345, 47_999}) {
		stream.stream_seek(st, target)
		stream.stream_read(st, {out[0][:], out[1][:]}, 300)
		testing.expect_value(t, check(t, out, target, 300, SR), 0)
	}
	testing.expect_value(t, stream.stream_underruns(st), 0)
}

@(test)
reading_never_allocates :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 60 * time.Second)
	path := test_file("ten_seconds.wav", 10 * SR)
	s, _ := stream.create(streaming_settings())
	defer stream.destroy(s)
	src, _ := stream.source_open(s, path)
	defer stream.source_release(src)
	st, _ := stream.stream_create(s, src, cues = {0, 300_000})
	defer stream.stream_destroy(st)
	wait_ready(t, st)
	out := [2][]f32{make([]f32, 512, context.temp_allocator), make([]f32, 512, context.temp_allocator)}
	trap: kit.Trap_Allocator
	for i in 0 ..< 400 {
		context.allocator = kit.trap_allocator(&trap)
		context.temp_allocator = context.allocator
		if i % 50 == 0 do stream.stream_seek(st, 300_000 if i % 100 == 0 else 1_234)
		stream.stream_read(st, {out[0][:], out[1][:]}, 512)
		time.sleep(500 * time.Microsecond)
	}
	testing.expect_value(t, trap.violations, 0)
}

// Many streams on a few files, read and sought at random by an "audio"
// thread while the control thread creates and destroys more: every frame
// that arrives is the right one.
@(test)
many_streams_under_load :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 120 * time.Second)
	paths := [4]string{}
	for &p, i in paths do p = test_file(fmt.tprintf("load_%d.wav", i), (3 + i) * SR)
	settings := streaming_settings()
	settings.threads = 3
	s, _ := stream.create(settings)
	defer stream.destroy(s)
	srcs: [4]^stream.Source
	for &src, i in srcs do src, _ = stream.source_open(s, paths[i])
	defer for src in srcs do stream.source_release(src)

	Shared :: struct {
		t:      ^testing.T,
		streams: [24]^stream.Stream,
		lengths: [24]i64,
		stop:   bool,
		bad:    int,
		reads:  int,
	}
	sh := Shared{t = t}
	for i in 0 ..< len(sh.streams) {
		sh.streams[i], _ = stream.stream_create(s, srcs[i % 4], cues = {0, 50_000})
		sh.lengths[i] = i64((3 + i % 4) * SR)
	}
	audio := thread.create_and_start_with_data(&sh, proc(data: rawptr) {
		sh := (^Shared)(data)
		out := [2][]f32{make([]f32, 256), make([]f32, 256)}
		defer delete(out[0])
		defer delete(out[1])
		rng := kit.Rng{state = 11}
		for !sync.atomic_load(&sh.stop) {
			for st, i in sh.streams {
				if kit.rng_range(&rng, 0, 40) == 0 {
					stream.stream_seek(st, i64(kit.rng_range(&rng, 0, int(sh.lengths[i]) - 1)) if kit.rng_range(&rng, 0, 1) == 0 else 50_000)
				}
				pos := stream.stream_position(st)
				stream.stream_read(st, {out[0][:], out[1][:]}, 256)
				if check(sh.t, out, pos, 256, sh.lengths[i]) < 0 do sh.bad += 1
				sh.reads += 1
			}
			time.sleep(2 * time.Millisecond)
		}
	})
	// Meanwhile, churn: extra streams come and go.
	for k in 0 ..< 200 {
		extra, _ := stream.stream_create(s, srcs[k % 4], cues = {SR})
		time.sleep(5 * time.Millisecond)
		stream.stream_destroy(extra)
	}
	sync.atomic_store(&sh.stop, true)
	thread.join(audio)
	thread.destroy(audio)
	for st in sh.streams do stream.stream_destroy(st)
	testing.expect_value(t, sh.bad, 0)
	testing.expect(t, sh.reads > 1000)
}

// A bounce reads as fast as it can, far faster than the disk: offline, every
// read waits for its data, from the first one (no `stream_ready` wait), after
// seeks without cues, and from a file still loading into memory. Live, the
// same reads underrun (so the test does test the waiting).
@(test)
offline_reads_wait_for_the_disk :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 120 * time.Second)
	path := test_file("ten_seconds.wav", 10 * SR)
	for offline in ([]bool{true, false}) {
		settings := streaming_settings()
		settings.threads = 1
		s, _ := stream.create(settings)
		stream.set_offline(s, offline)
		testing.expect_value(t, stream.is_offline(s), offline)
		src, _ := stream.source_open(s, path)
		st, _ := stream.stream_create(s, src)
		out := [2][]f32{make([]f32, 4096, context.temp_allocator), make([]f32, 4096, context.temp_allocator)}
		pos := i64(0)
		bad := false
		read :: proc(t: ^testing.T, st: ^stream.Stream, out: [2][]f32, pos: ^i64, bad: ^bool, offline: bool) {
			n := stream.stream_read(st, {out[0][:], out[1][:]}, 4096)
			silent := check(t, out, pos^, 4096, 10 * SR)
			if offline && silent != 0 && !bad^ {
				testing.expectf(t, false, "offline: %d silent frames at %d", silent, pos^)
				bad^ = true
			}
			if offline do testing.expect_value(t, n, int(min(4096, max(10 * SR - pos^, 0))))
			pos^ += 4096
		}
		for pos < 4 * SR do read(t, st, out, &pos, &bad, offline)
		stream.stream_seek(st, 7 * SR + 77)
		pos = 7 * SR + 77
		for pos < 10 * SR do read(t, st, out, &pos, &bad, offline)
		if offline {
			testing.expect_value(t, stream.stream_underruns(st), 0)
		} else {
			testing.expect(t, stream.stream_underruns(st) > 0, "live reads at full speed never underran")
		}
		stream.stream_destroy(st)
		stream.source_release(src)
		stream.destroy(s)
	}

	// In memory: the first read waits while the file loads.
	s, _ := stream.create(stream.default_settings())
	defer stream.destroy(s)
	stream.set_offline(s, true)
	src, _ := stream.source_open(s, test_file("one_second.wav", SR))
	defer stream.source_release(src)
	st, _ := stream.stream_create(s, src)
	defer stream.stream_destroy(st)
	out := [2][]f32{make([]f32, 300, context.temp_allocator), make([]f32, 300, context.temp_allocator)}
	stream.stream_read(st, {out[0][:], out[1][:]}, 300)
	testing.expect_value(t, check(t, out, 0, 300, SR), 0)
	testing.expect_value(t, stream.stream_underruns(st), 0)
}
