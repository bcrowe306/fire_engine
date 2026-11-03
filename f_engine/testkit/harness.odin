package testkit

import "base:runtime"
import "core:math"
import "core:slice"
import "core:time"

import "fire:core"
import "fire:rt"
import tb "fire:timebase"

// --- null backend --------------------------------------------------------------
//
// `render` drives a node exactly the way a realtime backend would: prepare once,
// then a sequence of `process` calls with varying block sizes, sample-accurate
// events and a running transport, but offline and as fast as possible.
//
// Every process call runs with:
//   - a trapping allocator as context.allocator and context.temp_allocator
//   - flush-to-zero enabled (as the real audio thread will have)
//   - output buffers pre-filled with NaN, so unwritten samples are detected
//   - timing against the real-time budget of the block

// Every block is `size` frames (must be > 0); the last one may be shorter.
Fixed_Blocks :: struct {
	size: int,
}

// Cycles through `sizes[:count]`. Build with `block_sequence(...)`.
Block_Sequence :: struct {
	sizes: [16]int,
	count: int,
}

// Builds a `Block_Sequence` from 1 to 16 sizes (asserts otherwise). Sizes may be 0.
block_sequence :: proc(sizes: ..int) -> Block_Sequence {
	assert(len(sizes) > 0 && len(sizes) <= 16)
	s := Block_Sequence{count = len(sizes)}
	copy(s.sizes[:], sizes)
	return s
}

// Uniformly random sizes in [min, max] (0 allowed), reproducible from `seed`.
Random_Blocks :: struct {
	seed:     u64,
	min, max: int,
}

// How `render` splits the signal into `process` calls. Every size is clamped to
// [0, max_block] and to the frames remaining.
Block_Pattern :: union {
	Fixed_Blocks,
	Block_Sequence,
	Random_Blocks,
}

// An event at an absolute frame position from the start of the render.
Timed_Event :: struct {
	time:    tb.Sample_Time,
	payload: core.Event_Payload,
}

// Called by `render` after each process call with the context that was just
// processed. Runs outside the trap allocator, so it may allocate.
Block_Hook :: proc(user: rawptr, block_index: int, ctx: ^core.Process_Context)

// Settings for one `render`. Start from `default_render_config` and override fields.
Render_Config :: struct {
	sample_rate:    f64,           // Hz
	max_block:      int,           // largest block passed to process, and the prepare max_block
	out_channels:   int,           // output channel count (input count comes from the input buffer)
	blocks:         Block_Pattern, // nil => Fixed_Blocks{max_block}
	events:         []Timed_Event, // any order; stable-sorted by time
	tail_frames:    int,           // extra frames rendered after the input ends (silent input)
	tempo_bpm:      f64,           // constant tempo for the transport
	tempo_map:      ^tb.Tempo_Map, // overrides tempo_bpm when set
	playing:        bool,          // transport playing flag
	ftz:            bool,          // enable flush-to-zero during process, as on a real audio thread
	max_events_out: int,           // output event capacity per block; extra events count as dropped
	// Called after each process call, outside the trap (it may allocate).
	after_block:    Block_Hook,
	user:           rawptr,        // passed to after_block
}

// 48 kHz, 512-frame max block, stereo out, fixed full-size blocks, playing at
// 120 BPM, flush-to-zero on, room for 4096 output events per block.
default_render_config :: proc() -> Render_Config {
	return Render_Config {
		sample_rate = 48000,
		max_block = 512,
		out_channels = 2,
		tempo_bpm = 120,
		playing = true,
		ftz = true,
		max_events_out = 4096,
	}
}

// Wall-clock time of the node's `process` calls over a render. Indicative only: the
// null backend runs offline, so treat it as a rough budget check.
Timing_Stats :: struct {
	p50_ns, p99_ns, max_ns: i64, // per-call process time percentiles, nanoseconds
	// Worst ratio of process time to the block's real-time duration (1.0 = deadline).
	max_load:               f64,
	total_ns:               i64, // sum of all process calls, nanoseconds
}

// What `render` observed. Pass it to `expect_clean_render`, then free it with
// `render_report_destroy`.
Render_Report :: struct {
	prepare_error:    core.Error, // non-.None means prepare failed and nothing was rendered
	blocks:           int,        // process calls made (including 0-frame ones)
	frames:           int,        // total frames rendered (input frames + tail_frames)
	min_block_used:   int,
	max_block_used:   int,
	rt_allocations:   int,        // allocation attempts inside process (all were refused)
	first_rt_alloc:   runtime.Source_Code_Location, // call site of the first one
	non_finite:       int, // NaN/Inf in output (includes samples the node never wrote)
	first_non_finite: int, // frame index, -1 if none
	denormals:        int,                  // subnormal output samples
	events_out:       [dynamic]Timed_Event, // events the node wrote, at absolute frames; from render's allocator
	events_dropped:   int,                  // events lost to a full output buffer (see max_events_out)
	timing:           Timing_Stats,
}

// Frees `events_out` and zeroes the report.
render_report_destroy :: proc(r: ^Render_Report) {
	delete(r.events_out)
	r^ = {}
}

// Renders `input.frames + cfg.tail_frames` frames through `node`. The output has
// `cfg.out_channels` channels. The node is prepared here and released at the end;
// the caller still owns (and destroys) it.
render :: proc(node: ^core.Node, input: Audio_Buffer, cfg: Render_Config, allocator := context.allocator) -> (out: Audio_Buffer, report: Render_Report) {
	report.first_non_finite = -1
	report.min_block_used = max(int)
	report.events_out = make([dynamic]Timed_Event, allocator)

	in_ch := len(input.channels)
	total := input.frames + cfg.tail_frames
	out = buffer_make(cfg.out_channels, total, cfg.sample_rate, allocator)

	prep := core.Prepare_Config{cfg.sample_rate, cfg.max_block, in_ch, cfg.out_channels}
	report.prepare_error = core.node_prepare(node, prep)
	if report.prepare_error != .None do return

	// All scratch is allocated up front, like a real engine would in prepare.
	scratch := buffer_make(in_ch, cfg.max_block, cfg.sample_rate, context.temp_allocator)
	in_views := make([][]f32, in_ch, context.temp_allocator)
	out_views := make([][]f32, cfg.out_channels, context.temp_allocator)
	block_events := make([]core.Event, len(cfg.events), context.temp_allocator)
	writer := core.Event_Writer{buffer = make([]core.Event, cfg.max_events_out, context.temp_allocator)}
	durations := make([dynamic]i64, context.temp_allocator)

	events := slice.clone(cfg.events, context.temp_allocator)
	slice.stable_sort_by(events, proc(a, b: Timed_Event) -> bool { return a.time < b.time })
	next_event := 0

	trap: Trap_Allocator
	blocks := cfg.blocks
	if blocks == nil do blocks = Fixed_Blocks{cfg.max_block}
	rng := Rng{}
	if r, ok := blocks.(Random_Blocks); ok do rng.state = r.seed

	transport := core.Transport {
		playing     = cfg.playing,
		sample_rate = cfg.sample_rate,
		meter       = {4, 4},
		tempo_map   = cfg.tempo_map,
	}

	pos := 0
	for block_index := 0; pos < total; block_index += 1 {
		n: int
		switch p in blocks {
		case Fixed_Blocks:
			assert(p.size > 0, "Fixed_Blocks size must be > 0")
			n = p.size
		case Block_Sequence:
			n = p.sizes[block_index % p.count]
		case Random_Blocks:
			n = rng_range(&rng, p.min, p.max)
		}
		n = clamp(n, 0, min(cfg.max_block, total - pos))

		for c in 0 ..< in_ch {
			avail := clamp(input.frames - pos, 0, n)
			copy(scratch.channels[c][:avail], input.channels[c][pos:pos + avail])
			for i in avail ..< n do scratch.channels[c][i] = 0
			in_views[c] = scratch.channels[c][:n]
		}
		for c in 0 ..< cfg.out_channels {
			out_views[c] = out.channels[c][pos:pos + n]
			for &s in out_views[c] do s = math.nan_f32()
		}

		ev_count := 0
		for next_event < len(events) && int(events[next_event].time) < pos + n && n > 0 {
			e := events[next_event]
			block_events[ev_count] = core.Event{u32(max(int(e.time) - pos, 0)), e.payload}
			ev_count += 1
			next_event += 1
		}

		update_transport(&transport, cfg, pos)
		core.event_writer_clear(&writer)
		ctx := core.Process_Context {
			inputs     = in_views,
			outputs    = out_views,
			frames     = n,
			events_in  = block_events[:ev_count],
			events_out = &writer,
			transport  = &transport,
		}

		ns := process_trapped(node, &ctx, &trap, cfg.ftz)
		append(&durations, ns)
		if n > 0 {
			block_ns := f64(n) / cfg.sample_rate * 1e9
			report.timing.max_load = max(report.timing.max_load, f64(ns) / block_ns)
		}

		for e in core.event_writer_events(&writer) {
			append(&report.events_out, Timed_Event{tb.Sample_Time(pos + int(e.offset)), e.payload})
		}
		report.events_dropped += writer.dropped

		if cfg.after_block != nil do cfg.after_block(cfg.user, block_index, &ctx)

		report.blocks += 1
		report.min_block_used = min(report.min_block_used, n)
		report.max_block_used = max(report.max_block_used, n)
		pos += n
	}
	core.node_release(node)

	report.frames = total
	report.rt_allocations = trap.violations
	report.first_rt_alloc = trap.first_loc
	for ch in out.channels {
		count, first := count_non_finite(ch)
		report.non_finite += count
		if first >= 0 && (report.first_non_finite < 0 || first < report.first_non_finite) {
			report.first_non_finite = first
		}
		report.denormals += count_denormals(ch)
	}
	report.timing = timing_stats(durations[:], report.timing.max_load)
	return
}

// Separate proc so the context override is scoped to exactly one process call.
@(private)
process_trapped :: proc(node: ^core.Node, ctx: ^core.Process_Context, trap: ^Trap_Allocator, ftz: bool) -> i64 {
	fp: rt.FP_State
	if ftz do fp = rt.enable_flush_to_zero()
	defer if ftz do rt.restore_fp_state(fp)

	context.allocator = trap_allocator(trap)
	context.temp_allocator = trap_allocator(trap)

	start := time.tick_now()
	core.node_process(node, ctx)
	return time.duration_nanoseconds(time.tick_since(start))
}

@(private)
update_transport :: proc(t: ^core.Transport, cfg: Render_Config, pos: int) {
	t.sample_pos = tb.Sample_Time(pos)
	if cfg.tempo_map != nil {
		t.beat_pos = tb.samples_to_beats(cfg.tempo_map, t.sample_pos, cfg.sample_rate)
		t.tempo_bpm = tb.tempo_at(cfg.tempo_map, t.beat_pos)
		meter, _, _ := tb.meter_at_beat(cfg.tempo_map, t.beat_pos)
		t.meter = meter
		bbt := tb.beats_to_bbt(cfg.tempo_map, t.beat_pos)
		t.bar_start = tb.bbt_to_beats(cfg.tempo_map, {bbt.bar, 0, 0})
	} else {
		t.tempo_bpm = cfg.tempo_bpm
		t.beat_pos = tb.seconds_to_beats_at(tb.samples_to_seconds(t.sample_pos, cfg.sample_rate), cfg.tempo_bpm)
		t.bar_start = tb.Beats(math.floor(f64(t.beat_pos) / 4) * 4)
	}
}

@(private)
timing_stats :: proc(durations: []i64, max_load: f64) -> Timing_Stats {
	s := Timing_Stats{max_load = max_load}
	if len(durations) == 0 do return s
	for d in durations do s.total_ns += d
	slice.sort(durations)
	s.p50_ns = durations[len(durations) / 2]
	s.p99_ns = durations[min(len(durations) - 1, len(durations) * 99 / 100)]
	s.max_ns = durations[len(durations) - 1]
	return s
}

// The block-size patterns every DSP test should survive.
standard_block_patterns :: proc(max_block: int) -> [5]Block_Pattern {
	return {
		Fixed_Blocks{max_block},
		Fixed_Blocks{1},
		Fixed_Blocks{7},
		block_sequence(max_block, 1, 0, max_block / 2, 3),
		Random_Blocks{seed = 0xF1DE, min = 0, max = max_block},
	}
}
