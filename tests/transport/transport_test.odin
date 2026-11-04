package test_transport

import "core:math"
import "core:testing"

import "fire:core"
import tb "fire:timebase"
import kit "fire:testkit"
import "fire:transport"

SR :: 48_000.0

// One `run` call as the segment proc saw it.
Call :: struct {
	frame:  i64,
	frames: int,
	t:      core.Transport,  // `timelines` cleared
	tl:     [4]core.Timeline_State, // the first four slots
}

Rec :: struct {
	calls: [dynamic]Call,
}

record :: proc(user: rawptr, ctx: ^core.Process_Context) {
	r := (^Rec)(user)
	c := Call{frame = i64(ctx.transport.frame), frames = ctx.frames, t = ctx.transport^}
	for i in 0 ..< min(4, len(ctx.transport.timelines)) do c.tl[i] = ctx.transport.timelines[i]
	c.t.timelines = nil
	append(&r.calls, c)
}

// Runs `total` frames in blocks of `block`.
run :: proc(c: ^transport.Clock, r: ^Rec, total: int, block := 512) {
	for done := 0; done < total; {
		n := min(block, total - done)
		ctx := core.Process_Context{frames = n}
		transport.process(c, &ctx, record, r)
		done += n
	}
}

new_clock :: proc(bpm := 120.0) -> ^transport.Clock {
	s := transport.default_settings(SR)
	s.bpm = bpm
	c, err := transport.create(s)
	assert(err == .None)
	return c
}

// The first call whose timeline `slot` has `flag`, or nil.
find_flag :: proc(r: ^Rec, slot: int, flag: core.Timeline_Flag) -> ^Call {
	for &call in r.calls do if flag in call.tl[slot].flags do return &call
	return nil
}

@(test)
grid_advances_exactly :: proc(t: ^testing.T) {
	c := new_clock(120)
	defer transport.destroy(c)
	r: Rec
	defer delete(r.calls)
	run(c, &r, 48_000 * 60, 509) // a minute, in odd blocks
	st := transport.status(c)
	testing.expect_value(t, st.frame, tb.Sample_Time(48_000 * 60))
	kit.expect_near(t, f64(st.grid), 120, 1e-9, "a minute at 120 BPM")
	for call in r.calls {
		kit.expect_near(t, f64(call.t.grid), f64(call.frame) / 24_000, 1e-9, "grid at each call")
		testing.expect_value(t, call.t.bar, i64(math.floor(f64(call.t.grid) / 4 + 1e-9)))
	}
	testing.expect_value(t, len(r.calls), (48_000 * 60 + 508) / 509) // nothing split
}

@(test)
quantized_play_lands_on_the_downbeat :: proc(t: ^testing.T) {
	c := new_clock(120)
	defer transport.destroy(c)
	r: Rec
	defer delete(r.calls)
	clip, _ := transport.add_timeline(c)
	run(c, &r, 30_000) // grid 1.25
	transport.play(c, clip, tb.Quantize.Bar)
	run(c, &r, 100_000)

	start := find_flag(&r, int(clip.index), .Started)
	if !testing.expect(t, start != nil, "never started") do return
	testing.expect_value(t, start.frame, i64(96_000)) // beat 4 at 120 BPM
	testing.expect_value(t, start.tl[clip.index].position, tb.Beats(0))
	testing.expect(t, start.tl[clip.index].playing)
	pos, playing, ok := transport.timeline_status(c, clip)
	testing.expect(t, ok && playing)
	kit.expect_near(t, f64(pos), f64(130_000 - 96_000) / 24_000, 1e-9, "position after")
}

@(test)
quantize_lengths :: proc(t: ^testing.T) {
	cases := []struct {
		q:    tb.Quantize,
		from: f64, // grid when the command arrives
		want: f64,
	}{
		{.Quarter, 1.25, 2},
		{.Quarter, 2, 2}, // on the boundary: now
		{.Eighth_T, 0.5, 2.0 / 3},
		{.Quarter_D, 3.2, 4}, // dotted: 0, 1.5, 3, then the next bar resets the grid
		{.Bars_2, 5, 8},
		{.Bars_4, 4, 16},
		{.Bars_4, 0, 0},
	}
	for tc in cases {
		c := new_clock(120)
		r: Rec
		clip, _ := transport.add_timeline(c)
		run(c, &r, int(tc.from * 24_000), 1000)
		transport.play(c, clip, tc.q)
		run(c, &r, 24_000 * 20)
		start := find_flag(&r, int(clip.index), .Started)
		if testing.expectf(t, start != nil, "%v from %v: never started", tc.q, tc.from) {
			want := i64(math.ceil(tc.want * 24_000 - 1e-6))
			testing.expectf(t, start.frame == want, "%v from %v: started at frame %d, want %d", tc.q, tc.from, start.frame, want)
		}
		delete(r.calls)
		transport.destroy(c)
	}
}

// A loop of a length that is not a whole number of frames wraps on the right
// frames for hundreds of cycles, without drift, and every call is continuous.
@(test)
loops_wrap_without_drift :: proc(t: ^testing.T) {
	c := new_clock(120)
	defer transport.destroy(c)
	r: Rec
	defer delete(r.calls)
	tl, _ := transport.add_timeline(c)
	LOOP :: 0.29171 // beats: 7001.04 frames
	transport.set_loop(c, tl, 1, 1 + LOOP)
	transport.locate(c, tl, 1)
	transport.play(c, tl)
	run(c, &r, 48_000 * 50)

	wraps := 0
	for call, i in r.calls {
		s := call.tl[tl.index]
		if .Wrapped in s.flags {
			wraps += 1
			// Wraps land on the first frame at or after each loop end.
			want := i64(math.ceil(f64(wraps) * LOOP * 24_000 - 1e-6))
			testing.expectf(t, call.frame == want, "wrap %d at frame %d, want %d", wraps, call.frame, want)
			testing.expect(t, .Jumped in s.flags)
		} else if i > 0 && r.calls[i - 1].tl[tl.index].playing {
			prev := r.calls[i - 1]
			expect := prev.tl[tl.index].position + tb.Beats(f64(prev.frames) / 24_000)
			kit.expect_near(t, f64(s.position), f64(expect), 1e-9, "continuous between wraps")
		}
		// Inside the loop, always (a wrap may land up to 1e-6 frames early).
		testing.expect(t, s.position >= 1 - 1e-9 && s.position < 1 + LOOP + 1e-9)
		// Exact phase: position = 1 + (time mod loop).
		phase := math.mod(f64(call.frame) / 24_000, LOOP)
		if abs(phase - LOOP) < 1e-6 do phase = 0
		kit.expect_near(t, f64(s.position) - 1, phase, 1e-6, "phase")
	}
	cycles := f64(50 * 2) / LOOP
	testing.expect_value(t, wraps, int(cycles))
}

@(test)
leader_tempo_map_sets_tempo_and_splits :: proc(t: ^testing.T) {
	c := new_clock(100)
	defer transport.destroy(c)
	r: Rec
	defer delete(r.calls)
	m: tb.Tempo_Map
	tb.tempo_map_init(&m, 120)
	defer tb.tempo_map_destroy(&m)
	tb.tempo_map_set_tempo(&m, 4, 60)
	tb.tempo_map_set_meter(&m, 1, {3, 4})

	song, _ := transport.add_timeline(c, &m)
	transport.set_leader(c, song)
	transport.play(c, song)
	run(c, &r, 48_000 * 5, 512)

	split := false
	for call in r.calls {
		pos := call.tl[song.index].position
		// The grid follows the song's map from frame 0.
		kit.expect_near(t, f64(pos), f64(tb.samples_to_beats(&m, tb.Sample_Time(call.frame), SR)), 1e-9, "song position")
		kit.expect_near(t, f64(call.t.grid), f64(pos), 1e-9, "grid = song")
		testing.expect_value(t, call.t.tempo_bpm, tb.tempo_at(&m, pos))
		if call.frame == 96_000 {
			split = true
			testing.expect(t, .Tempo_Changed in call.t.flags)
		}
		// Bars follow the map: bar 0 is 4/4, then 3/4.
		want_bar := pos < 4 ? 0 : 1 + i64(math.floor(f64(pos - 4) / 3 + 1e-9))
		testing.expect_value(t, call.t.bar, want_bar)
		testing.expect_value(t, call.t.meter, pos < 4 ? tb.Meter{4, 4} : tb.Meter{3, 4})
	}
	testing.expect(t, split, "block not split at the tempo change")
	testing.expect_value(t, transport.status(c).tempo_bpm, 60)
}

@(test)
ramps_are_exact_inside_a_call :: proc(t: ^testing.T) {
	c := new_clock(120)
	defer transport.destroy(c)
	r: Rec
	defer delete(r.calls)
	m: tb.Tempo_Map
	tb.tempo_map_init(&m, 60)
	defer tb.tempo_map_destroy(&m)
	tb.tempo_map_set_tempo(&m, 0, 60, 180) // ramp 60 → 180 over 8 beats
	tb.tempo_map_set_tempo(&m, 8, 180)

	song, _ := transport.add_timeline(c, &m)
	transport.set_leader(c, song)
	transport.play(c, song)
	run(c, &r, 48_000 * 6, 4096)
	for &call in r.calls {
		for off in ([]int{0, call.frames / 2, call.frames}) {
			got := core.transport_grid_at(&call.t, off)
			want := tb.samples_to_beats(&m, tb.Sample_Time(call.frame + i64(off)), SR)
			kit.expect_near(t, f64(got), f64(want), 1e-9, "grid inside a ramping call")
		}
		if call.t.grid < 8 - 1e-9 do kit.expect_near(t, call.t.tempo_slope, 15, 1e-9, "slope")
	}
}

// When the leader stops, the live tempo and bars carry on where it was.
@(test)
leader_stop_hands_over_tempo_and_bars :: proc(t: ^testing.T) {
	c := new_clock(100)
	defer transport.destroy(c)
	r: Rec
	defer delete(r.calls)
	m: tb.Tempo_Map
	tb.tempo_map_init(&m, 120, {3, 4})
	defer tb.tempo_map_destroy(&m)
	tb.tempo_map_set_tempo(&m, 3, 90)

	song, _ := transport.add_timeline(c, &m)
	transport.set_leader(c, song)
	transport.locate(c, song, 1) // mid-bar
	transport.play(c, song)
	run(c, &r, 48_000 * 2)
	transport.stop(c, song)
	clip, _ := transport.add_timeline(c)
	transport.play(c, clip, tb.Quantize.Bar)
	run(c, &r, 48_000 * 4)

	st := transport.status(c)
	testing.expect_value(t, st.tempo_bpm, 90)
	last := r.calls[len(r.calls) - 1]
	testing.expect_value(t, last.t.meter, tb.Meter{3, 4})
	// Song bar lines are at grid 2, 5, 8, ... (song beat 1 was grid 0). It
	// stopped at song beat 1 + 2 + 1.5 = 4.5 = grid 3.5, so the clip starts at
	// grid 5.
	start := find_flag(&r, int(clip.index), .Started)
	if testing.expect(t, start != nil) do kit.expect_near(t, f64(start.t.grid), 5, 1e-6, "clip starts on the song's next bar")
	sp, playing, _ := transport.timeline_status(c, song)
	testing.expect(t, !playing)
	kit.expect_near(t, f64(sp), 4.5, 1e-9, "song stopped where it was")
}

// Commands in one batch apply in order: a clip launched on the next bar
// right after the song starts mid-bar follows the song's bar lines.
@(test)
same_batch_quantizes_against_earlier_commands :: proc(t: ^testing.T) {
	c := new_clock(120)
	defer transport.destroy(c)
	r: Rec
	defer delete(r.calls)
	song, _ := transport.add_timeline(c)
	clip, _ := transport.add_timeline(c)
	run(c, &r, 24_000 * 10) // grid 10
	transport.set_leader(c, song)
	transport.locate(c, song, 2.5)
	transport.play(c, song)
	transport.play(c, clip, tb.Quantize.Bar)
	run(c, &r, 24_000 * 4)
	start := find_flag(&r, int(clip.index), .Started)
	if testing.expect(t, start != nil) do kit.expect_near(t, f64(start.t.grid), 11.5, 1e-6, "clip on the song's bar 1")
}

@(test)
live_meter_and_override :: proc(t: ^testing.T) {
	c := new_clock(120)
	defer transport.destroy(c)
	r: Rec
	defer delete(r.calls)
	transport.set_meter(c, {3, 4}, nil) // now: bar 0 restarts here at grid 0
	clip, _ := transport.add_timeline(c)
	run(c, &r, 24_000 * 4) // grid 4: bar 1 began at 3
	transport.play(c, clip, tb.Quantize.Bar)
	run(c, &r, 24_000 * 4)
	start := find_flag(&r, int(clip.index), .Started)
	if testing.expect(t, start != nil) do kit.expect_near(t, f64(start.t.grid), 6, 1e-6, "next 3/4 bar")

	m: tb.Tempo_Map
	tb.tempo_map_init(&m, 60)
	defer tb.tempo_map_destroy(&m)
	song, _ := transport.add_timeline(c, &m)
	transport.set_leader(c, song)
	transport.play(c, song)
	run(c, &r, 4800)
	testing.expect_value(t, transport.status(c).tempo_bpm, 60)
	transport.set_tempo(c, 140)
	run(c, &r, 4800)
	testing.expect_value(t, transport.status(c).tempo_bpm, 60) // the map wins
	transport.set_tempo_override(c, true)
	run(c, &r, 4800)
	testing.expect_value(t, transport.status(c).tempo_bpm, 140)
	testing.expect_value(t, r.calls[len(r.calls) - 1].t.meter, tb.Meter{4, 4}) // the map's meter still applies
}

@(test)
rates_and_locate :: proc(t: ^testing.T) {
	c := new_clock(120)
	defer transport.destroy(c)
	r: Rec
	defer delete(r.calls)
	half, _ := transport.add_timeline(c)
	transport.set_rate(c, half, 0.5)
	transport.play(c, half)
	run(c, &r, 48_000)
	p, _, _ := transport.timeline_status(c, half)
	kit.expect_near(t, f64(p), 1, 1e-9, "half time: 2 grid beats → 1")
	transport.locate(c, half, 10)
	run(c, &r, 48_000)
	p, _, _ = transport.timeline_status(c, half)
	kit.expect_near(t, f64(p), 11, 1e-9, "located, then 1 more")
	jump := find_flag(&r, int(half.index), .Jumped)
	testing.expect(t, jump != nil && jump.frame == 48_000)
	transport.stop(c, half)
	run(c, &r, 48_000)
	p2, playing, _ := transport.timeline_status(c, half)
	p = p2
	testing.expect(t, !playing)
	kit.expect_near(t, f64(p), 11, 1e-9, "stopped")
}

// --- splitting the block for the segment proc -------------------------------------------

Echo :: struct {
	writer: ^core.Event_Writer,
}

// Writes each frame's absolute index to output 0 and echoes events.
echo :: proc(user: rawptr, ctx: ^core.Process_Context) {
	for &s, i in ctx.outputs[0] do s = f32(ctx.transport.frame) + f32(i)
	for e in ctx.events_in do core.event_writer_push(ctx.events_out, e)
	testing_assert_inputs(ctx)
}

testing_assert_inputs :: proc(ctx: ^core.Process_Context) {
	for in_ in ctx.inputs do assert(len(in_) == ctx.frames)
	for e in ctx.events_in do assert(int(e.offset) < ctx.frames)
}

@(test)
split_blocks_keep_buffers_and_events_aligned :: proc(t: ^testing.T) {
	c := new_clock(120)
	defer transport.destroy(c)
	tl, _ := transport.add_timeline(c)
	transport.set_loop(c, tl, 0, 0.05) // wraps every 1200 frames
	transport.play(c, tl)

	out := make([]f32, 4096)
	defer delete(out)
	in_ := make([]f32, 4096)
	defer delete(in_)
	events := []core.Event{{0, core.Midi_Raw{}}, {1199, core.Midi_Raw{}}, {1200, core.Midi_Raw{}}, {4095, core.Midi_Raw{}}}
	buf := make([]core.Event, 16)
	defer delete(buf)
	w := core.Event_Writer{buffer = buf}
	outs := [][]f32{out}
	ins := [][]f32{in_}
	trap: kit.Trap_Allocator
	{
		context.allocator = kit.trap_allocator(&trap)
		context.temp_allocator = context.allocator
		ctx := core.Process_Context{inputs = ins, outputs = outs, frames = 4096, events_in = events, events_out = &w}
		transport.process(c, &ctx, echo, nil)
	}
	testing.expect_value(t, trap.violations, 0)
	for s, i in out do if s != f32(i) {
		testing.expectf(t, false, "frame %d holds %v", i, s)
		break
	}
	testing.expect_value(t, w.count, 4)
	for e, i in core.event_writer_events(&w) do testing.expect_value(t, e.offset, events[i].offset)
}

// Any block size gives the same positions at every frame.
@(test)
block_size_invariance :: proc(t: ^testing.T) {
	scenario :: proc(block_sizes: []int) -> [dynamic]f64 {
		c := new_clock(117)
		defer transport.destroy(c)
		m: tb.Tempo_Map
		tb.tempo_map_init(&m, 117)
		defer tb.tempo_map_destroy(&m)
		tb.tempo_map_set_tempo(&m, 6, 90, 150)
		tb.tempo_map_set_tempo(&m, 14, 150)
		song, _ := transport.add_timeline(c, &m)
		clip, _ := transport.add_timeline(c)
		transport.set_leader(c, song)
		transport.set_loop(c, song, 2, 18.5)
		transport.set_loop(c, clip, 0, 1.75)
		transport.set_rate(c, clip, 1.5)
		transport.play(c, song)
		transport.play(c, clip, tb.Quantize.Eighth_T)
		Positions :: struct { song, clip: core.Timeline_Id, out: [dynamic]f64 }
		p := Positions{song = song, clip = clip}
		k := 0
		for done := 0; done < 48_000 * 20; k += 1 {
			n := min(block_sizes[k % len(block_sizes)], 48_000 * 20 - done)
			ctx := core.Process_Context{frames = n}
			transport.process(c, &ctx, proc(user: rawptr, ctx: ^core.Process_Context) {
				p := (^Positions)(user)
				t := ctx.transport
				s := core.transport_timeline(t, p.song)
				cl := core.transport_timeline(t, p.clip)
				for i in 0 ..< ctx.frames {
					append(&p.out, f64(core.timeline_position_at(t, s, i)), f64(core.timeline_position_at(t, cl, i)), f64(core.transport_grid_at(t, i)))
				}
			}, &p)
			done += n
		}
		return p.out
	}
	a := scenario({512})
	defer delete(a)
	for sizes in ([][]int{{1, 7, 64, 333, 4096}, {2048}, {100, 3}}) {
		b := scenario(sizes)
		defer delete(b)
		worst, at := 0.0, 0
		for i in 0 ..< len(a) do if d := abs(a[i] - b[i]); d > worst do worst, at = d, i / 3
		testing.expectf(t, worst < 1e-9, "blocks %v differ by %v at frame %d", sizes, worst, at)
	}
}

@(test)
no_allocation_while_processing :: proc(t: ^testing.T) {
	c := new_clock(120)
	defer transport.destroy(c)
	m: tb.Tempo_Map
	tb.tempo_map_init(&m, 120)
	defer tb.tempo_map_destroy(&m)
	tb.tempo_map_set_tempo(&m, 2, 80, 160)
	song, _ := transport.add_timeline(c, &m)
	transport.set_leader(c, song)
	transport.set_loop(c, song, 0, 7)
	transport.play(c, song)
	trap: kit.Trap_Allocator
	for i in 0 ..< 2000 {
		if i % 50 == 0 do transport.play(c, song, tb.Quantize.Sixteenth)
		if i % 70 == 0 do transport.set_tempo_map(c, song, &m) // retires the old copy
		{
			context.allocator = kit.trap_allocator(&trap)
			context.temp_allocator = context.allocator
			ctx := core.Process_Context{frames = 256}
			transport.process(c, &ctx, proc(user: rawptr, ctx: ^core.Process_Context) {}, nil)
		}
		transport.collect(c)
	}
	testing.expect_value(t, trap.violations, 0)
}

@(test)
removed_timelines_are_rejected :: proc(t: ^testing.T) {
	c := new_clock(120)
	defer transport.destroy(c)
	r: Rec
	defer delete(r.calls)
	m: tb.Tempo_Map
	tb.tempo_map_init(&m, 90)
	defer tb.tempo_map_destroy(&m)
	a, _ := transport.add_timeline(c, &m)
	transport.set_leader(c, a)
	transport.play(c, a)
	run(c, &r, 4800)
	testing.expect_value(t, transport.remove_timeline(c, a), core.Error.None)
	testing.expect_value(t, transport.play(c, a), core.Error.Invalid_Argument)
	b, _ := transport.add_timeline(c)
	testing.expect_value(t, b.index, a.index) // slot reused, new generation
	testing.expect(t, b.generation != a.generation)
	run(c, &r, 4800)
	last := &r.calls[len(r.calls) - 1]
	testing.expect_value(t, last.t.leader, core.Timeline_Id{})
	testing.expect_value(t, last.t.tempo_bpm, 90) // carried on from the removed leader
	transport.collect(c)
}

// --- following an outside clock ----------------------------------------------------------

Fake_Sync :: struct {
	bpm:     f64,
	origin:  f64, // the outside clock's beat at our frame 0
	desired: [dynamic]f64, // desired_bpm at each block
	calls:   int,
}

fake_begin_block :: proc(user: rawptr, b: ^transport.Sync_Block) {
	s := (^Fake_Sync)(user)
	s.calls += 1
	append(&s.desired, b.desired_bpm)
	b.ok, b.bpm = true, s.bpm
	b.beat = tb.Beats(s.origin + f64(b.frame) / b.sample_rate * s.bpm / 60)
}

@(test)
sync_takes_tempo_and_grid_keeping_timelines_continuous :: proc(t: ^testing.T) {
	c := new_clock(120)
	defer transport.destroy(c)
	r: Rec
	defer delete(r.calls)
	tl, _ := transport.add_timeline(c)
	transport.play(c, tl)
	run(c, &r, 24_000) // grid 1, timeline 1

	fake := Fake_Sync{bpm = 100, origin = 1000}
	defer delete(fake.desired)
	transport.set_sync(c, {begin_block = fake_begin_block, user = &fake})
	transport.set_tempo(c, 133)
	run(c, &r, 48_000)
	testing.expect(t, fake.calls > 0)
	// A local tempo change reaches the outside clock once; afterwards the
	// clock wants what the outside clock gave it.
	testing.expect_value(t, fake.desired[0], 133)
	testing.expect_value(t, fake.desired[1], 100)
	testing.expect_value(t, transport.status(c).tempo_bpm, 100)

	jumped := 0
	for call, i in r.calls {
		if .Grid_Jumped in call.t.flags do jumped += 1
		if i == 0 do continue
		prev := r.calls[i - 1]
		// The timeline never jumps, whatever the grid does.
		step := core.timeline_position_at(&prev.t, &prev.tl[tl.index], prev.frames)
		kit.expect_near(t, f64(call.tl[tl.index].position), f64(step), 1e-9, "timeline continuous")
	}
	testing.expect_value(t, jumped, 1)
	last := r.calls[len(r.calls) - 1]
	kit.expect_near(t, f64(last.t.grid), 1000 + f64(last.frame) / SR * 100 / 60, 1e-9, "grid follows the outside clock")

	transport.set_sync(c, {})
	run(c, &r, 4800)
	testing.expect_value(t, transport.status(c).tempo_bpm, 100) // carries on at the outside tempo
}

// An outside clock that also starts and stops a timeline, as Link does.
Start_Stop_Sync :: struct {
	ask:        transport.Start_Stop, // asked for at the next block, once
	at:         tb.Beats,
	toggles:    u64,      // as last seen
	toggled_at: tb.Beats,
	playing:    bool,
}

start_stop_begin_block :: proc(user: rawptr, b: ^transport.Sync_Block) {
	s := (^Start_Stop_Sync)(user)
	b.ok, b.bpm = true, 120
	b.beat = tb.Beats(f64(b.frame) / b.sample_rate * 2) // grid beat = seconds × 2
	s.toggles, s.toggled_at, s.playing = b.toggles, b.toggled_at, b.playing
	b.start_stop, b.start_stop_at = s.ask, s.at
	s.ask = .None
}

// The sync's starts and stops land on the exact frame of the beat it names,
// whatever the block size, or at once (caught up) when that beat has passed;
// they don't count as local toggles, which it is told of with their beat.
@(test)
sync_starts_and_stops_its_timeline :: proc(t: ^testing.T) {
	for block in ([]int{512, 100, 1}) {
		c := new_clock(120)
		defer transport.destroy(c)
		r: Rec
		defer delete(r.calls)
		tl, _ := transport.add_timeline(c)
		s: Start_Stop_Sync
		transport.set_sync(c, {begin_block = start_stop_begin_block, user = &s, timeline = tl})
		run(c, &r, 4800, block)

		// A start at beat 1.5 (frame 36_000), asked for at frame 4800.
		s.ask, s.at = .Start, 1.5
		run(c, &r, 48_000, block)
		started := find_flag(&r, int(tl.index), .Started)
		if testing.expectf(t, started != nil, "block %d: never started", block) {
			testing.expectf(t, started.frame == 36_000, "block %d: started at frame %d, want 36000", block, started.frame)
			testing.expect_value(t, started.tl[tl.index].position, 0)
		}
		testing.expect_value(t, s.toggles, 0)
		testing.expect(t, s.playing)

		// A stop in the past applies at once, where it was due: at beat 2,
		// the song had played 0.5 beats.
		s.ask, s.at = .Stop, 2
		run(c, &r, 4800, block)
		pos, playing, _ := transport.timeline_status(c, tl)
		testing.expect(t, !playing)
		kit.expect_near(t, f64(pos), 0.5, 1e-9, "stopped where the stop was due")
		testing.expect_value(t, s.toggles, 0)

		// A start in the past catches up.
		clear(&r.calls)
		s.ask, s.at = .Start, 2.2 // the grid is at 2.4 by now
		run(c, &r, block, block)
		pos, playing, _ = transport.timeline_status(c, tl)
		grid := transport.status(c).grid
		testing.expect(t, playing)
		kit.expect_near(t, f64(pos), 0.5 + f64(grid - 2.2), 1e-9, "caught up from the start beat")

		// Local stops and starts are counted, with their beat.
		transport.stop(c, tl, transport.At_Beat(4))
		run(c, &r, 48_000, block)
		testing.expect_value(t, s.toggles, 1)
		kit.expect_near(t, f64(s.toggled_at), 4, 1e-9, "the local stop's beat")
		testing.expect(t, !s.playing)
		transport.play(c, tl)
		run(c, &r, 4800, block)
		testing.expect_value(t, s.toggles, 2)
		testing.expect(t, s.playing)
		transport.set_sync(c, {})
		run(c, &r, block, block)
	}
}
