package test_record

import "core:os"
import "core:testing"
import "core:time"

import "fire:audiofile"
import "fire:core"
import "fire:record"
import tb "fire:timebase"
import kit "fire:testkit"
import "fire:transport"

SR :: 48_000.0
BEAT :: 24_000 // frames per beat at 120 BPM

// The input at clock frame f: f + 1 on channel 0, its negation on channel 1,
// exact in f32 for the lengths tested. Silence (0) is never valid input.
value :: proc(f: i64, c: int) -> f32 {
	return f32(f + 1) if c == 0 else -f32(f + 1)
}

Rig :: struct {
	clock: ^transport.Clock,
	tl:    core.Timeline_Id,
	disk:  ^record.Disk_Writer,
	node:  core.Node,
	rec:   ^record.Audio_Recorder,
	dir:   string,
	frame: i64,
	input: [2][]f32,
	trap:  kit.Trap_Allocator,
	service_each_block: bool,
}

rig_make :: proc(settings: record.Audio_Recorder_Settings = {}, timeline := true, manual := true) -> ^Rig {
	r := new(Rig)
	r.clock, _ = transport.create(transport.default_settings(SR))
	r.tl, _ = transport.add_timeline(r.clock)
	r.disk, _ = record.disk_writer_create({manual = manual})
	r.dir, _ = os.make_directory_temp("", "fire_record", context.allocator)
	s := settings
	s.timeline = r.tl if timeline else {}
	s.channels = 2
	s.directory, s.name = r.dir, "take"
	r.node, r.rec, _ = record.audio_recorder_create(r.disk, s)
	core.node_prepare(&r.node, {sample_rate = SR, max_block = 32_768})
	for &c in r.input do c = make([]f32, 32_768)
	r.service_each_block = manual
	return r
}

rig_destroy :: proc(r: ^Rig) {
	core.node_destroy(&r.node)
	record.disk_writer_destroy(r.disk)
	transport.destroy(r.clock)
	os.remove_all(r.dir)
	delete(r.dir)
	for c in r.input do delete(c)
	free(r)
}

// Runs `total` frames in blocks cycling through `blocks`.
rig_run :: proc(r: ^Rig, total: int, blocks: []int = {512}) {
	for done, k := 0, 0; done < total; k += 1 {
		n := min(blocks[k % len(blocks)], total - done)
		for c in 0 ..< 2 do for i in 0 ..< n do r.input[c][i] = value(r.frame + i64(i), c)
		ctx := core.Process_Context{inputs = {r.input[0][:n], r.input[1][:n]}, frames = n}
		{
			context.allocator = kit.trap_allocator(&r.trap)
			context.temp_allocator = context.allocator
			transport.process(r.clock, &ctx, proc(user: rawptr, seg: ^core.Process_Context) {
				core.node_process(&(^Rig)(user).node, seg)
			}, r)
		}
		if r.service_each_block do record.disk_writer_service(r.disk)
		r.frame += i64(n)
		done += n
	}
}

rig_takes :: proc(r: ^Rig) -> [dynamic]record.Take {
	takes := make([dynamic]record.Take, context.temp_allocator)
	for take in record.audio_recorder_poll(r.rec) do append(&takes, take)
	return takes
}

takes_destroy :: proc(takes: []record.Take) {
	for &t in takes do record.take_destroy(&t)
}

// The take's file, planar.
read_take :: proc(t: record.Take) -> [2][]f32 {
	rd, err := audiofile.open(t.path, context.temp_allocator)
	out: [2][]f32
	if err != .None do return out
	defer audiofile.close(rd)
	n := int(audiofile.info(rd).frames)
	for &c in out do c = make([]f32, n, context.temp_allocator)
	audiofile.read(rd, out[:], n)
	return out
}

// Every sample of the take is the input from clock frame `from` on.
expect_input :: proc(t: ^testing.T, take: record.Take, from: i64, loc := #caller_location) {
	data := read_take(take)
	testing.expect_value(t, len(data[0]), int(take.frames), loc = loc)
	bad := 0
	for c in 0 ..< 2 do for x, k in data[c] do if x != value(from + i64(k), c) {
		if bad == 0 do testing.expectf(t, false, "channel %d frame %d: %v, want %v", c, k, x, value(from + i64(k), c), loc = loc)
		bad += 1
	}
	testing.expect_value(t, bad, 0, loc = loc)
}

@(test)
records_input_exactly_at_any_block_size :: proc(t: ^testing.T) {
	patterns := [][]int{{512}, {1, 511, 64}, {4096 + 3}, {13, 1000, 7, 2048}}
	for p in patterns {
		r := rig_make()
		defer rig_destroy(r)
		record.audio_recorder_arm(r.rec, true)
		transport.play(r.clock, r.tl)
		transport.stop(r.clock, r.tl, transport.At_Beat(6)) // 3 s
		rig_run(r, 4 * 48_000, p)
		takes := rig_takes(r)
		defer takes_destroy(takes[:])
		if !testing.expect_value(t, len(takes), 1) do continue
		tk := takes[0]
		testing.expect_value(t, tk.start, tb.Beats(0))
		testing.expect_value(t, tk.length, tb.Beats(6))
		testing.expect_value(t, tk.frames, i64(6 * BEAT))
		testing.expect_value(t, tk.run, 1)
		testing.expect_value(t, tk.dropped_frames, i64(0))
		testing.expect_value(t, tk.error, audiofile.Error.None)
		expect_input(t, tk, 0)
		testing.expect_value(t, r.trap.violations, 0) // no allocations on the audio thread
	}
}

@(test)
latency_and_punch_place_takes_exactly :: proc(t: ^testing.T) {
	for p in ([][]int{{512}, {7, 300, 1}}) {
		r := rig_make({latency_frames = 300})
		defer rig_destroy(r)
		record.audio_recorder_arm(r.rec, true)
		record.audio_recorder_set_punch(r.rec, 1, 3.5)
		transport.play(r.clock, r.tl)
		rig_run(r, 5 * BEAT, p)
		takes := rig_takes(r)
		defer takes_destroy(takes[:])
		if !testing.expect_value(t, len(takes), 1) do continue
		tk := takes[0]
		testing.expect_value(t, tk.start, tb.Beats(1))
		testing.expect_value(t, tk.length, tb.Beats(2.5))
		testing.expect_value(t, tk.start_frame, i64(BEAT))
		testing.expect_value(t, tk.frames, i64(2.5 * BEAT))
		expect_input(t, tk, BEAT + 300) // what arrived 300 frames after the beat
	}
}

@(test)
each_loop_pass_is_a_take :: proc(t: ^testing.T) {
	r := rig_make({latency_frames = 128})
	defer rig_destroy(r)
	record.audio_recorder_arm(r.rec, true)
	transport.set_loop(r.clock, r.tl, 0, 2)
	transport.play(r.clock, r.tl)
	transport.stop(r.clock, r.tl, transport.At_Beat(7)) // three passes and a half
	rig_run(r, 8 * BEAT, {500, 33})
	takes := rig_takes(r)
	defer takes_destroy(takes[:])
	if !testing.expect_value(t, len(takes), 4) do return
	for tk, i in takes {
		testing.expect_value(t, tk.run, 1)
		testing.expect_value(t, tk.pass, i)
		testing.expect_value(t, tk.start, tb.Beats(0))
		want := i64(2 * BEAT) if i < 3 else i64(BEAT)
		testing.expect_value(t, tk.frames, want)
		testing.expect(t, abs(f64(tk.length) - f64(want) / BEAT) < 1e-9)
		expect_input(t, tk, i64(i) * 2 * BEAT + 128)
	}
}

@(test)
locate_starts_a_new_run :: proc(t: ^testing.T) {
	r := rig_make()
	defer rig_destroy(r)
	record.audio_recorder_arm(r.rec, true)
	transport.play(r.clock, r.tl)
	transport.locate(r.clock, r.tl, 10, transport.At_Beat(2))
	transport.stop(r.clock, r.tl, transport.At_Beat(3))
	rig_run(r, 4 * BEAT)
	takes := rig_takes(r)
	defer takes_destroy(takes[:])
	if !testing.expect_value(t, len(takes), 2) do return
	testing.expect_value(t, takes[0].run, 1)
	testing.expect_value(t, takes[1].run, 2)
	testing.expect_value(t, takes[1].pass, 0)
	testing.expect_value(t, takes[1].start, tb.Beats(10))
	testing.expect_value(t, takes[1].frames, i64(BEAT))
	expect_input(t, takes[1], 2 * BEAT)
}

@(test)
disarming_ends_the_take :: proc(t: ^testing.T) {
	r := rig_make(timeline = false) // a tape: records whenever armed
	defer rig_destroy(r)
	record.audio_recorder_arm(r.rec, true)
	rig_run(r, 10_000)
	record.audio_recorder_arm(r.rec, false)
	rig_run(r, 5_000)
	record.audio_recorder_arm(r.rec, true)
	rig_run(r, 2_000)
	record.audio_recorder_arm(r.rec, false)
	rig_run(r, 512)
	takes := rig_takes(r)
	defer takes_destroy(takes[:])
	if !testing.expect_value(t, len(takes), 2) do return
	testing.expect_value(t, takes[0].frames, i64(10_000))
	testing.expect_value(t, takes[1].frames, i64(2_000))
	expect_input(t, takes[0], 0)
	expect_input(t, takes[1], 15_000)
}

@(test)
a_slow_disk_leaves_silence_not_a_shift :: proc(t: ^testing.T) {
	r := rig_make({buffer_seconds = 0.1}) // 2 blocks
	defer rig_destroy(r)
	r.service_each_block = false // the disk stalls
	record.audio_recorder_arm(r.rec, true)
	transport.play(r.clock, r.tl)
	rig_run(r, 30_000)
	r.service_each_block = true
	rig_run(r, 30_000)
	record.audio_recorder_arm(r.rec, false)
	rig_run(r, 512)
	_, dropped := record.audio_recorder_status(r.rec)
	testing.expect(t, dropped > 0)
	takes := rig_takes(r)
	defer takes_destroy(takes[:])
	if !testing.expect_value(t, len(takes), 1) do return
	tk := takes[0]
	testing.expect_value(t, tk.frames, i64(60_000))
	testing.expect_value(t, tk.dropped_frames, i64(dropped))
	data := read_take(tk)
	silent, wrong := 0, 0
	for x, k in data[0] {
		if x == 0 {
			silent += 1
		} else if x != value(i64(k), 0) {
			wrong += 1
		}
	}
	testing.expect_value(t, i64(silent), tk.dropped_frames)
	testing.expect_value(t, wrong, 0) // whatever was kept is where it belongs
}

@(test)
disk_thread_writes_in_the_background :: proc(t: ^testing.T) {
	r := rig_make(manual = false)
	defer rig_destroy(r)
	record.audio_recorder_arm(r.rec, true)
	transport.play(r.clock, r.tl)
	transport.stop(r.clock, r.tl, transport.At_Beat(4))
	for _ in 0 ..< 5 {
		rig_run(r, BEAT)
		time.sleep(5 * time.Millisecond) // a device's pace, roughly
	}
	takes: [dynamic]record.Take
	defer delete(takes)
	for deadline := time.tick_now(); len(takes) == 0 && time.tick_since(deadline) < 5 * time.Second; {
		for take in record.audio_recorder_poll(r.rec) do append(&takes, take)
		time.sleep(time.Millisecond)
	}
	defer takes_destroy(takes[:])
	if !testing.expect_value(t, len(takes), 1) do return
	testing.expect_value(t, takes[0].frames, i64(4 * BEAT))
	expect_input(t, takes[0], 0)
}

@(test)
a_recorder_made_again_never_writes_over_a_take :: proc(t: ^testing.T) {
	r := rig_make(timeline = false)
	defer rig_destroy(r)
	record.audio_recorder_arm(r.rec, true)
	rig_run(r, 3_000)
	record.audio_recorder_arm(r.rec, false)
	rig_run(r, 512)
	first := rig_takes(r)
	defer takes_destroy(first[:])
	if !testing.expect_value(t, len(first), 1) do return
	// Made again (a project opened again, its input changed): counting from
	// 1 again, it takes the next name no file has.
	core.node_destroy(&r.node)
	r.node, r.rec, _ = record.audio_recorder_create(r.disk, {channels = 2, directory = r.dir, name = "take"})
	core.node_prepare(&r.node, {sample_rate = SR, max_block = 32_768})
	from := r.frame
	record.audio_recorder_arm(r.rec, true)
	rig_run(r, 2_000)
	record.audio_recorder_arm(r.rec, false)
	rig_run(r, 512)
	second := rig_takes(r)
	defer takes_destroy(second[:])
	if !testing.expect_value(t, len(second), 1) do return
	testing.expect(t, first[0].path != second[0].path, "the second take has a name of its own")
	expect_input(t, first[0], 0) // the first take is as it was
	expect_input(t, second[0], from)
}
