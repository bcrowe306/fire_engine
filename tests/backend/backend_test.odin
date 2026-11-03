package test_backend

import "base:intrinsics"
import "core:math"
import "core:testing"
import "core:time"

import "fire:backend"
import "fire:backend/fake"
import "fire:core"
import "fire:rt"
import kit "fire:testkit"

// --- recorder: a Device_Callback that plays and records by sample_time ---------

Block_Log :: struct {
	frames:      int,
	sample_time: i64,
	callback_ns: u64,
	input_ns:    u64,
	output_ns:   u64,
	xrun:        bool,
	ftz:         bool,
}

Recorder :: struct {
	play:          [][]f32, // per selected output channel, indexed by sample_time
	rec:           [][]f32, // per selected input channel
	log:           []Block_Log,
	logged:        int,
	prepared:      core.Prepare_Config,
	prepare_calls: int,
	release_calls: int,
	prepare_error: core.Error,
	next_time:     i64,
	gaps:          int,
	not_ftz:       int,
	allocate:      bool,
	blocks:        u64, // atomic
}

recorder_make :: proc(ins, outs, frames: int, log_len := 16_384) -> ^Recorder {
	r := new(Recorder, context.temp_allocator)
	r.play = make([][]f32, outs, context.temp_allocator)
	r.rec = make([][]f32, ins, context.temp_allocator)
	for &c in r.play do c = make([]f32, frames, context.temp_allocator)
	for &c in r.rec do c = make([]f32, frames, context.temp_allocator)
	r.log = make([]Block_Log, log_len, context.temp_allocator)
	return r
}

recorder_callback :: proc(r: ^Recorder) -> backend.Device_Callback {
	return {
		prepare = proc(user: rawptr, cfg: core.Prepare_Config) -> core.Error {
			r := (^Recorder)(user)
			r.prepared = cfg
			r.prepare_calls += 1
			return r.prepare_error
		},
		process = recorder_process,
		release = proc(user: rawptr) { (^Recorder)(user).release_calls += 1 },
		user = r,
	}
}

// [rt]
recorder_process :: proc(user: rawptr, b: ^backend.Io_Block) {
	r := (^Recorder)(user)
	if b.sample_time != r.next_time do r.gaps += 1
	r.next_time = b.sample_time + i64(b.frames)
	if !rt.flush_to_zero_enabled() do r.not_ftz += 1
	if r.logged < len(r.log) {
		r.log[r.logged] = {b.frames, b.sample_time, b.callback_ns, b.input_ns, b.output_ns, b.xrun, rt.flush_to_zero_enabled()}
		r.logged += 1
	}
	for out, c in b.outputs {
		for &s, i in out {
			t := int(b.sample_time) + i
			s = c < len(r.play) && t < len(r.play[c]) ? r.play[c][t] : 0
		}
	}
	for input, c in b.inputs {
		for s, i in input {
			t := int(b.sample_time) + i
			if c < len(r.rec) && t < len(r.rec[c]) do r.rec[c][t] = s
		}
	}
	if r.allocate {
		p := new(int)
		free(p)
	}
	intrinsics.atomic_add(&r.blocks, 1)
}

// A device + fake driver pair, opened with the given setup.
Rig :: struct {
	f:   ^fake.Fake,
	dev: backend.Device,
}

rig_open :: proc(t: ^testing.T, rig: ^Rig, cfg: fake.Config, setup: backend.Device_Setup, max_block: int) -> bool {
	rig.f = fake.create(cfg)
	backend.device_init(&rig.dev, fake.driver(rig.f))
	err := backend.device_open(&rig.dev, setup, max_block)
	testing.expect_value(t, err, core.Error.None)
	return err == .None
}

rig_destroy :: proc(rig: ^Rig) {
	backend.device_destroy(&rig.dev)
	backend.driver_destroy(fake.driver(rig.f))
}

stereo :: backend.Channel_Mask{0, 1}

quad_rates := [?]f64{48_000}
quad_sizes := [?]int{64, 256, 1024}
quad_device := [?]fake.Device_Spec {
	{
		id = "fake:quad", name = "Quad", input_channels = 4, output_channels = 4,
		sample_rates = quad_rates[:], buffer_sizes = quad_sizes[:],
		default_sample_rate = 48_000, default_buffer_frames = 256,
	},
}

// --- format conversion -----------------------------------------------------------

lsb :: proc(f: backend.Sample_Format) -> f64 {
	switch f {
	case .F32, .F64:       return 0
	case .I16:             return 1.0 / 32768
	case .I24, .I24_In_32: return 1.0 / 8388608
	case .I32:             return 1.0 / 2147483648
	}
	return 0
}

@(test)
convert_round_trip_all_formats :: proc(t: ^testing.T) {
	N :: 4096
	src := make([]f32, N, context.temp_allocator)
	back := make([]f32, N, context.temp_allocator)
	raw := make([]u8, N * 8 * 3, context.temp_allocator) // room for stride 3 samples of 8 bytes
	kit.white_noise(src, 7, 0.99)
	src[0], src[1], src[2] = 1, -1, 0

	for format in backend.Sample_Format {
		bytes := backend.sample_format_bytes(format)
		for stride in ([]int{bytes, bytes * 3}) {
			backend.write_samples(src, raw_data(raw), stride, format)
			backend.read_samples(back, raw_data(raw), stride, format)
			tol := lsb(format) * 0.5 + 1e-7
			// +1.0 is above the largest integer code, so it clips to 1 - lsb.
			worst := 0.0
			for i in 1 ..< N do worst = max(worst, abs(f64(src[i]) - f64(back[i])))
			testing.expectf(t, worst <= tol, "%v stride %d: max error %v > %v", format, stride, worst, tol)
			testing.expectf(t, abs(f64(back[0]) - 1) <= lsb(format), "%v: +1 read back as %v", format, back[0])
		}
	}
}

@(test)
convert_integer_clipping_and_nan :: proc(t: ^testing.T) {
	raw: [16]u8
	backend.write_samples([]f32{1.5}, &raw, 2, .I16)
	testing.expect_value(t, (^i16)(&raw)^, max(i16))
	backend.write_samples([]f32{-1.5}, &raw, 2, .I16)
	testing.expect_value(t, (^i16)(&raw)^, min(i16))
	backend.write_samples([]f32{-2}, &raw, 4, .I32)
	testing.expect_value(t, (^i32)(&raw)^, min(i32))
	backend.write_samples([]f32{math.nan_f32()}, &raw, 4, .I32)
	testing.expect_value(t, (^i32)(&raw)^, 0)
}

@(test)
convert_i24_byte_layout :: proc(t: ^testing.T) {
	raw: [3]u8
	backend.write_samples([]f32{0.5}, &raw, 3, .I24)
	testing.expect_value(t, raw, [3]u8{0x00, 0x00, 0x40})
	backend.write_samples([]f32{-1}, &raw, 3, .I24)
	testing.expect_value(t, raw, [3]u8{0x00, 0x00, 0x80})

	out: [1]f32
	raw = {0xFF, 0xFF, 0xFF} // -1 LSB
	backend.read_samples(out[:], &raw, 3, .I24)
	testing.expect_value(t, out[0], f32(-1.0 / 8388608))

	word: u32 = 0x00_40_00_00 // I24_In_32: +0.5, upper byte ignored on read
	backend.read_samples(out[:], &word, 4, .I24_In_32)
	testing.expect_value(t, out[0], 0.5)
}

// --- shared layer ----------------------------------------------------------------

@(test)
jittery_callbacks_are_split_into_max_block :: proc(t: ^testing.T) {
	MAX_BLOCK :: 256
	cfg := fake.default_config()
	cfg.jitter_min, cfg.jitter_max, cfg.seed = 1, 2048, 42
	cfg.output_latency_frames = 100
	cfg.input_latency_frames = 30
	rig: Rig
	if !rig_open(t, &rig, cfg, {input_channels = stereo, output_channels = stereo}, MAX_BLOCK) do return
	defer rig_destroy(&rig)

	r := recorder_make(2, 2, 0)
	testing.expect_value(t, backend.device_start(&rig.dev, recorder_callback(r)), core.Error.None)
	testing.expect_value(t, r.prepared, core.Prepare_Config{48_000, MAX_BLOCK, 2, 2})

	total := fake.run(rig.f, 400)
	stats := backend.device_stats(&rig.dev)
	testing.expect_value(t, stats.callbacks, 400)
	testing.expect_value(t, stats.frames, u64(total))
	testing.expect_value(t, r.gaps, 0)
	testing.expect_value(t, r.next_time, i64(total))
	testing.expect(t, stats.blocks > stats.callbacks, "large callbacks must be split")
	testing.expect_value(t, r.not_ftz, 0)

	sizes_seen_small, sizes_seen_full := false, false
	ns :: 1e9 / 48_000.0
	for b in r.log[:r.logged] {
		testing.expectf(t, b.frames >= 1 && b.frames <= MAX_BLOCK, "block of %d frames", b.frames)
		sizes_seen_small ||= b.frames < MAX_BLOCK
		sizes_seen_full ||= b.frames == MAX_BLOCK
		// Manual mode uses a synthetic clock: frame 0 at start_ns.
		want_out := f64(cfg.start_ns) + f64(b.sample_time + 100) * ns
		want_in := f64(cfg.start_ns) + f64(b.sample_time - 30) * ns
		testing.expectf(t, abs(f64(b.output_ns) - want_out) <= 2, "output_ns %v want %v", b.output_ns, want_out)
		testing.expectf(t, abs(f64(b.input_ns) - want_in) <= 2, "input_ns %v want %v", b.input_ns, want_in)
		testing.expect(t, b.callback_ns <= b.output_ns)
	}
	testing.expect(t, sizes_seen_small && sizes_seen_full)
	backend.device_stop(&rig.dev)
	testing.expect_value(t, r.release_calls, 1)
}

Loop_Case :: struct {
	in_format, out_format: backend.Sample_Format,
	plane_channels:        int,
	quad:                  bool,
}

@(test)
loopback_round_trip_formats_and_layouts :: proc(t: ^testing.T) {
	LATENCY :: 1500
	FRAMES :: 60_000
	cases := []Loop_Case {
		{.F32, .F32, 0, false},
		{.I16, .I16, 1, false},
		{.I24, .I24, 0, false},
		{.F64, .I32, 1, false},
		{.I24_In_32, .F32, 2, true},
		{.I16, .I24, 3, true}, // planes of 3 + 1 channels
	}
	for lc in cases {
		cfg := fake.default_config()
		cfg.input_format, cfg.output_format = lc.in_format, lc.out_format
		cfg.input_plane_channels, cfg.output_plane_channels = lc.plane_channels, lc.plane_channels
		cfg.jitter_min, cfg.jitter_max, cfg.seed = 1, 1024, 9
		cfg.loopback_latency = LATENCY
		channels := 2
		mask := stereo
		if lc.quad {
			cfg.devices = quad_device[:]
			channels, mask = 4, {0, 1, 2, 3}
		}
		rig: Rig
		if !rig_open(t, &rig, cfg, {input_channels = mask, output_channels = mask}, 128) do return
		defer rig_destroy(&rig)

		r := recorder_make(channels, channels, FRAMES)
		for c in 0 ..< channels do kit.white_noise(r.play[c], u64(100 + c), 0.5)
		testing.expect_value(t, backend.device_start(&rig.dev, recorder_callback(r)), core.Error.None)
		for r.next_time < FRAMES do fake.run(rig.f, 1)

		tol := max(lsb(lc.in_format), lsb(lc.out_format)) + 1e-7
		for c in 0 ..< channels {
			n := FRAMES - LATENCY
			cmp := kit.compare_slices(r.play[c][:n], r.rec[c][LATENCY:][:n])
			testing.expectf(t, cmp.max_abs_error <= tol, "%v ch%d: error %v at %d", lc, c, cmp.max_abs_error, cmp.max_error_at)
			testing.expect_value(t, kit.estimate_latency(r.play[c][:8192], r.rec[c][:8192], 4096), LATENCY)
			for s in r.rec[c][:LATENCY] do if s != 0 {
				testing.expectf(t, false, "%v ch%d: input before latency not silent", lc, c)
				break
			}
		}
	}
}

@(test)
channel_selection_maps_and_silences_unselected :: proc(t: ^testing.T) {
	cfg := fake.default_config()
	cfg.devices = quad_device[:]
	cfg.output_plane_channels = 0 // one interleaved plane: ch0 ch1 ch2 ch3
	cfg.loopback_latency = 1024
	rig: Rig
	setup := backend.Device_Setup{input_channels = {1, 3}, output_channels = {1, 3}}
	if !rig_open(t, &rig, cfg, setup, 256) do return
	defer rig_destroy(&rig)

	r := recorder_make(2, 2, 8192)
	for &s in r.play[0] do s = 0.25
	for &s in r.play[1] do s = 0.75
	testing.expect_value(t, backend.device_start(&rig.dev, recorder_callback(r)), core.Error.None)
	testing.expect_value(t, r.prepared.in_channels, 2)
	testing.expect_value(t, r.prepared.out_channels, 2)
	fake.run(rig.f, 8)

	planes, frames := fake.last_output(rig.f)
	testing.expect_value(t, len(planes), 1)
	native := ([^]f32)(planes[0].data)[:frames * 4]
	for i in 0 ..< frames {
		got := native[i * 4:][:4]
		if got[0] != 0 || got[1] != 0.25 || got[2] != 0 || got[3] != 0.75 {
			testing.expectf(t, false, "frame %d: device outputs %v, want [0 0.25 0 0.75]", i, got)
			break
		}
	}
	// Device input 1 and 3 loop back from device outputs 1 and 3.
	testing.expect_value(t, r.rec[0][1024], 0.25)
	testing.expect_value(t, r.rec[1][1024], 0.75)
	testing.expect_value(t, r.rec[0][1023], 0)
}

@(test)
realtime_path_does_not_allocate :: proc(t: ^testing.T) {
	cfg := fake.default_config()
	cfg.jitter_min, cfg.jitter_max = 1, 2048
	cfg.loopback_latency = 2048
	cfg.input_format, cfg.output_format = .I24, .I16
	rig: Rig
	if !rig_open(t, &rig, cfg, {input_channels = stereo, output_channels = stereo}, 64) do return
	defer rig_destroy(&rig)

	trap: kit.Trap_Allocator
	rig.dev.rt_allocator = kit.trap_allocator(&trap)
	r := recorder_make(2, 2, 4096)
	testing.expect_value(t, backend.device_start(&rig.dev, recorder_callback(r)), core.Error.None)
	fake.run(rig.f, 200)
	testing.expect_value(t, trap.violations, 0)

	// The trap is really installed: an allocating callback is caught.
	r.allocate = true
	fake.run(rig.f, 1)
	testing.expect(t, trap.violations > 0, "allocation in the callback was not trapped")
}

@(test)
xrun_is_flagged_once_and_reported :: proc(t: ^testing.T) {
	rig: Rig
	if !rig_open(t, &rig, fake.default_config(), {output_channels = stereo}, 512) do return
	defer rig_destroy(&rig)
	r := recorder_make(0, 2, 0)
	testing.expect_value(t, backend.device_start(&rig.dev, recorder_callback(r)), core.Error.None)

	fake.run(rig.f, 5)
	_, any_event := backend.device_poll_event(&rig.dev)
	testing.expect(t, !any_event)

	fake.inject_xrun(rig.f)
	fake.run(rig.f, 5)
	flagged := 0
	for b, i in r.log[:r.logged] do if b.xrun {
		flagged += 1
		testing.expect_value(t, i, 5)
	}
	testing.expect_value(t, flagged, 1)

	e, ok := backend.device_poll_event(&rig.dev)
	testing.expect(t, ok)
	testing.expect_value(t, e.kind, backend.Device_Event_Kind.Xrun)
	testing.expect_value(t, e.count, 1)
	_, ok = backend.device_poll_event(&rig.dev)
	testing.expect(t, !ok)
	testing.expect_value(t, backend.device_stats(&rig.dev).xruns, 1)
}

@(test)
unplug_stops_callbacks_and_reports_loss :: proc(t: ^testing.T) {
	rig: Rig
	setup := backend.Device_Setup{output_channels = stereo}
	if !rig_open(t, &rig, fake.default_config(), setup, 512) do return
	defer rig_destroy(&rig)
	r := recorder_make(0, 2, 0)
	testing.expect_value(t, backend.device_start(&rig.dev, recorder_callback(r)), core.Error.None)
	fake.run(rig.f, 3)

	fake.unplug(rig.f)
	testing.expect_value(t, fake.run(rig.f, 3), 0)
	kinds: [dynamic]backend.Device_Event_Kind
	kinds.allocator = context.temp_allocator
	for e in backend.device_poll_event(&rig.dev) do append(&kinds, e.kind)
	testing.expect_value(t, len(kinds), 2)
	if len(kinds) == 2 {
		testing.expect_value(t, kinds[0], backend.Device_Event_Kind.Device_Lost)
		testing.expect_value(t, kinds[1], backend.Device_Event_Kind.Devices_Changed)
	}

	// The application recovers on the control thread: stop, close, reopen.
	backend.device_close(&rig.dev)
	testing.expect_value(t, r.release_calls, 1)
	testing.expect_value(t, backend.device_open(&rig.dev, setup, 512), core.Error.None)
	testing.expect_value(t, backend.device_start(&rig.dev, recorder_callback(r)), core.Error.None)
	testing.expect(t, fake.run(rig.f, 2) > 0)
}

@(test)
format_change_is_reported :: proc(t: ^testing.T) {
	rig: Rig
	if !rig_open(t, &rig, fake.default_config(), {output_channels = stereo}, 512) do return
	defer rig_destroy(&rig)
	fake.change_format(rig.f)
	e, ok := backend.device_poll_event(&rig.dev)
	testing.expect(t, ok)
	testing.expect_value(t, e.kind, backend.Device_Event_Kind.Format_Changed)
}

@(test)
threaded_start_stop_cycles :: proc(t: ^testing.T) {
	// A crash on the driver thread must fail the test, not hang the run.
	testing.set_fail_timeout(t, 30 * time.Second)
	cfg := fake.default_config()
	cfg.threaded = true
	cfg.jitter_min, cfg.jitter_max = 1, 512
	rig: Rig
	if !rig_open(t, &rig, cfg, {input_channels = stereo, output_channels = stereo}, 128) do return
	defer rig_destroy(&rig)

	r := recorder_make(0, 0, 0, 0)
	for cycle in 0 ..< 20 {
		r.next_time = 0
		testing.expect_value(t, backend.device_start(&rig.dev, recorder_callback(r)), core.Error.None)
		deadline := time.tick_now()
		for fake.callback_count(rig.f) < 50 {
			if time.tick_since(deadline) > 5 * time.Second {
				testing.expectf(t, false, "cycle %d: callbacks stalled", cycle)
				backend.device_stop(&rig.dev)
				return
			}
			time.sleep(100 * time.Microsecond)
		}
		backend.device_stop(&rig.dev)
		after_stop := intrinsics.atomic_load(&r.blocks)
		time.sleep(2 * time.Millisecond)
		testing.expectf(t, intrinsics.atomic_load(&r.blocks) == after_stop, "cycle %d: callback ran after stop", cycle)
	}
	testing.expect_value(t, r.gaps, 0)
	testing.expect_value(t, r.prepare_calls, 20)
	testing.expect_value(t, r.release_calls, 20)
}

@(test)
lifecycle_errors :: proc(t: ^testing.T) {
	f := fake.create(fake.default_config())
	defer backend.driver_destroy(fake.driver(f))
	dev: backend.Device
	backend.device_init(&dev, fake.driver(f))
	defer backend.device_destroy(&dev)
	r := recorder_make(2, 2, 0)

	infos, err := backend.driver_enumerate(fake.driver(f))
	testing.expect_value(t, err, core.Error.None)
	testing.expect_value(t, len(infos), 1)
	if len(infos) == 1 {
		testing.expect_value(t, infos[0].id, "fake:default")
		testing.expect(t, infos[0].is_default_output)
	}
	backend.device_infos_destroy(infos)

	testing.expect_value(t, backend.device_start(&dev, recorder_callback(r)), core.Error.Invalid_State)
	testing.expect_value(t, backend.device_open(&dev, {}, 256), core.Error.Invalid_Argument)
	testing.expect_value(t, backend.device_open(&dev, {output_channels = stereo}, 0), core.Error.Invalid_Argument)
	testing.expect_value(t, backend.device_open(&dev, {output_channels = stereo, sample_rate = 12_345}, 256), core.Error.Unsupported)
	testing.expect_value(t, backend.device_open(&dev, {output_channels = stereo, buffer_frames = 100}, 256), core.Error.Unsupported)
	testing.expect_value(t, backend.device_open(&dev, {output_channels = {5}}, 256), core.Error.Invalid_Argument)
	testing.expect_value(t, backend.device_open(&dev, {output_device_id = "nope", output_channels = stereo}, 256), core.Error.Invalid_Argument)
	split := backend.Device_Setup{input_device_id = "a", output_device_id = "b", input_channels = stereo, output_channels = stereo}
	testing.expect_value(t, backend.device_open(&dev, split, 256), core.Error.Unsupported)
	testing.expect_value(t, dev.state, backend.Device_State.Closed)

	testing.expect_value(t, backend.device_open(&dev, {output_channels = stereo}, 256), core.Error.None)
	testing.expect_value(t, backend.device_open(&dev, {output_channels = stereo}, 256), core.Error.Invalid_State)
	testing.expect_value(t, backend.device_start(&dev, {}), core.Error.Invalid_Argument)

	// A failing prepare keeps the driver stopped.
	r.prepare_error = .Out_Of_Memory
	testing.expect_value(t, backend.device_start(&dev, recorder_callback(r)), core.Error.Out_Of_Memory)
	testing.expect_value(t, dev.state, backend.Device_State.Open)
	testing.expect_value(t, fake.run(f, 4), 0)
	testing.expect_value(t, r.release_calls, 0)

	r.prepare_error = .None
	testing.expect_value(t, backend.device_start(&dev, recorder_callback(r)), core.Error.None)
	testing.expect_value(t, backend.device_start(&dev, recorder_callback(r)), core.Error.Invalid_State)
	backend.device_close(&dev) // stops first
	testing.expect_value(t, r.release_calls, 1)
	testing.expect_value(t, dev.state, backend.Device_State.Closed)
}
