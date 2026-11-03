// Tests of the test framework itself: if these lie, every other test lies.
package test_testkit

import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:testing"

import "fire:core"
import kit "fire:testkit"
import tb "fire:timebase"

SR :: 48000.0

@(test)
wav_round_trip :: proc(t: ^testing.T) {
	b := kit.buffer_make(2, 1000, SR, context.temp_allocator)
	kit.sine(b.channels[0], SR, 440)
	kit.white_noise(b.channels[1], 7)

	dir := kit.artifact_dir("wav_round_trip")
	path, _ := filepath.join({dir, "rt.wav"}, context.temp_allocator)
	testing.expect_value(t, kit.wav_write(path, b), kit.Wav_Error.None)
	r, err := kit.wav_read(path, context.temp_allocator)
	testing.expect_value(t, err, kit.Wav_Error.None)
	testing.expect_value(t, r.sample_rate, SR)
	cmp := kit.compare_buffers(b, r)
	testing.expect(t, !cmp.frame_mismatch && cmp.max_abs_error == 0, "float WAV must round-trip bit-exactly")
	_ = os.remove(path)
}

@(test)
generators_are_deterministic :: proc(t: ^testing.T) {
	a := make([]f32, 4096, context.temp_allocator)
	b := make([]f32, 4096, context.temp_allocator)
	kit.white_noise(a, 1234)
	kit.white_noise(b, 1234)
	testing.expect(t, kit.compare_slices(a, b).max_abs_error == 0)
	kit.white_noise(b, 1235)
	testing.expect(t, kit.compare_slices(a, b).max_abs_error > 0.1)
	kit.expect_near(t, kit.dc_offset(a), 0, 0.03, "white noise mean")
	kit.expect_near(t, kit.rms(a), 1 / math.sqrt(3.0), 0.02, "uniform noise rms")
}

@(test)
fft_finds_sine :: proc(t: ^testing.T) {
	x := make([]f32, 8192, context.temp_allocator)
	bin_hz := 171 * SR / 8192 // on a bin centre, so no scalloping loss
	kit.sine(x, SR, bin_hz, 0.5)
	s := kit.spectrum(x, SR, .Blackman_Harris, context.temp_allocator)
	bin, freq, mag := kit.spectrum_peak(s)
	testing.expect_value(t, bin, 171)
	kit.expect_near(t, freq, bin_hz, 1e-9, "peak frequency")
	kit.expect_near(t, mag, 0.5, 1e-3, "peak magnitude")

	// Off-bin: Blackman-Harris scalloping loss is at most ~0.83 dB.
	kit.sine(x, SR, 171.5 * SR / 8192, 0.5)
	s2 := kit.spectrum(x, SR, .Blackman_Harris, context.temp_allocator)
	_, _, mag2 := kit.spectrum_peak(s2)
	loss := kit.linear_to_db(0.5) - kit.linear_to_db(mag2)
	testing.expectf(t, loss > 0.5 && loss < 0.9, "scalloping loss %.2f dB", loss)
}

@(test)
tone_amplitude_and_thd :: proc(t: ^testing.T) {
	x := make([]f32, 48000, context.temp_allocator)
	kit.sine(x, SR, 997, 0.25)
	kit.expect_near(t, kit.tone_amplitude(x, SR, 997), 0.25, 1e-3, "tone amplitude")
	clean := kit.thd_n_db(x, SR, 997)
	testing.expectf(t, clean < -120, "clean f32 sine THD+N should be < -120 dB, got %.1f", clean)

	for &v in x do v = clamp(v, -0.2, 0.2) // hard clip
	clipped := kit.thd_n_db(x, SR, 997)
	testing.expectf(t, clipped > -40 && clipped < -10, "clipped sine THD+N should be ~-20 dB, got %.1f", clipped)
}

@(test)
latency_estimation :: proc(t: ^testing.T) {
	ref := make([]f32, 4096, context.temp_allocator)
	out := make([]f32, 4096, context.temp_allocator)
	kit.white_noise(ref, 3)
	copy(out[37:], ref[:len(ref) - 37])
	testing.expect_value(t, kit.estimate_latency(ref[:2048], out, 100), 37)
}

@(test)
click_detector :: proc(t: ^testing.T) {
	x := make([]f32, 4800, context.temp_allocator)
	kit.sine(x, SR, 440, 0.5)
	bound := kit.sine_curvature_bound(0.5, 440, SR)
	c, _ := kit.max_curvature(x)
	testing.expect(t, c <= bound * 1.01, "clean sine must stay under the bound")
	x[2000] += 0.05
	c2, at := kit.max_curvature(x)
	testing.expect(t, c2 > bound * 10, "a 0.05 step must register as a click")
	testing.expect(t, abs(at - 2000) <= 2)
}

// --- harness / null backend --------------------------------------------------

// A deliberately broken node: allocates in process.
Bad_Alloc :: struct {}

bad_alloc_vtable := core.Node_VTable {
	prepare = proc(self: rawptr, cfg: core.Prepare_Config, a: mem.Allocator) -> core.Error { return .None },
	process = proc(self: rawptr, ctx: ^core.Process_Context) {
		p := new(int) // the trap returns nil
		_ = p
		_ = fmt.tprintf("%d", ctx.frames) // temp allocator is trapped too
		for ch in ctx.outputs do for &s in ch do s = 0
	},
	destroy = proc(self: rawptr, a: mem.Allocator) { free((^Bad_Alloc)(self), a) },
}

@(test)
harness_traps_rt_allocations :: proc(t: ^testing.T) {
	n := core.node_make(&bad_alloc_vtable, new(Bad_Alloc), context.allocator)
	defer core.node_destroy(&n)
	cfg := kit.default_render_config()
	out, r := kit.render(&n, kit.buffer_length_only(2048, SR), cfg, context.temp_allocator)
	defer kit.render_report_destroy(&r)
	_ = out
	testing.expectf(t, r.rt_allocations >= 2 * r.blocks, "expected ≥2 trapped allocations per block, got %d over %d blocks", r.rt_allocations, r.blocks)
	testing.expect(t, r.first_rt_alloc.line > 0, "trap must record the call site")
}

// A broken node that leaves the second half of every block unwritten.
Lazy :: struct {}

lazy_vtable := core.Node_VTable {
	prepare = proc(self: rawptr, cfg: core.Prepare_Config, a: mem.Allocator) -> core.Error { return .None },
	process = proc(self: rawptr, ctx: ^core.Process_Context) {
		for ch in ctx.outputs do for i in 0 ..< ctx.frames / 2 do ch[i] = 0
	},
	destroy = proc(self: rawptr, a: mem.Allocator) { free((^Lazy)(self), a) },
}

@(test)
harness_detects_unwritten_output :: proc(t: ^testing.T) {
	n := core.node_make(&lazy_vtable, new(Lazy), context.allocator)
	defer core.node_destroy(&n)
	_, r := kit.render(&n, kit.buffer_length_only(1024, SR), kit.default_render_config(), context.temp_allocator)
	defer kit.render_report_destroy(&r)
	testing.expect(t, r.non_finite > 0, "unwritten samples must show up as NaN")
	testing.expect_value(t, r.first_non_finite, 256)
}

@(test)
probe_sees_sample_accurate_events_under_any_block_pattern :: proc(t: ^testing.T) {
	times := []int{0, 1, 511, 512, 513, 1000, 1000, 4095}
	events := make([]kit.Timed_Event, len(times), context.temp_allocator)
	for tm, i in times do events[i] = {tb.Sample_Time(tm), core.Param_Value{1, f64(i)}}

	for pattern in kit.standard_block_patterns(512) {
		n, p := kit.probe_create(allocator = context.allocator)
		defer kit.probe_destroy(&n, p)

		input := kit.buffer_make(1, 4096, SR, context.temp_allocator)
		kit.white_noise(input.channels[0], 9)
		cfg := kit.default_render_config()
		cfg.out_channels = 1
		cfg.blocks = pattern
		cfg.events = events
		out, r := kit.render(&n, input, cfg, context.temp_allocator)
		defer kit.render_report_destroy(&r)

		kit.expect_clean_render(t, r)
		testing.expect_value(t, p.unsorted_events, 0)
		testing.expect_value(t, p.out_of_range, 0)
		got := kit.probe_events(p)
		if !testing.expectf(t, len(got) == len(times), "pattern %v: %d events delivered, want %d", pattern, len(got), len(times)) do continue
		for e, i in got {
			testing.expectf(t, int(e.absolute) == times[i], "pattern %v: event %d at %d, want %d", pattern, i, e.absolute, times[i])
			pv := e.payload.(core.Param_Value)
			testing.expect_value(t, pv.value, f64(i)) // stable order for same-time events
		}
		// Pass-through must be exact regardless of blocking.
		testing.expect_value(t, kit.compare_buffers(input, out).max_abs_error, 0)
		// Transport sample_pos must equal the running frame count.
		running := 0
		for blk in kit.probe_blocks(p) {
			testing.expect_value(t, int(blk.transport.frame), running)
			running += blk.frames
		}
		testing.expect_value(t, running, 4096)
	}
}

@(test)
random_blocks_cover_edge_sizes :: proc(t: ^testing.T) {
	n, p := kit.probe_create(allocator = context.allocator)
	defer kit.probe_destroy(&n, p)
	cfg := kit.default_render_config()
	cfg.blocks = kit.Random_Blocks{seed = 1, min = 0, max = 64}
	cfg.max_block = 64
	_, r := kit.render(&n, kit.buffer_length_only(48000, SR), cfg, context.temp_allocator)
	defer kit.render_report_destroy(&r)
	testing.expect_value(t, r.min_block_used, 0)
	testing.expect_value(t, r.max_block_used, 64)
}

// A broken node that applies parameter events at the start of the block instead
// of at their offset. The block-invariance check must be able to see this.
Quantized_Gain :: struct {
	gain: f32,
}

quantized_vtable := core.Node_VTable {
	prepare = proc(self: rawptr, cfg: core.Prepare_Config, a: mem.Allocator) -> core.Error {
		(^Quantized_Gain)(self).gain = 1
		return .None
	},
	process = proc(self: rawptr, ctx: ^core.Process_Context) {
		q := (^Quantized_Gain)(self)
		for e in ctx.events_in do if pv, ok := e.payload.(core.Param_Value); ok do q.gain = f32(pv.value)
		for ch, c in ctx.outputs do for i in 0 ..< ctx.frames do ch[i] = ctx.inputs[c][i] * q.gain
	},
	destroy = proc(self: rawptr, a: mem.Allocator) { free((^Quantized_Gain)(self), a) },
}

@(test)
block_invariance_detects_non_sample_accurate_node :: proc(t: ^testing.T) {
	input := kit.buffer_make(1, 4096, SR, context.temp_allocator)
	kit.dc(input.channels[0], 1)
	cfg := kit.default_render_config()
	cfg.out_channels = 1
	cfg.events = {{1000, core.Param_Value{1, 0.5}}}

	outs: [2]kit.Audio_Buffer
	for pattern, i in ([]kit.Block_Pattern{kit.Fixed_Blocks{1}, kit.Fixed_Blocks{512}}) {
		n := core.node_make(&quantized_vtable, new(Quantized_Gain), context.allocator)
		defer core.node_destroy(&n)
		c := cfg
		c.blocks = pattern
		r: kit.Render_Report
		outs[i], r = kit.render(&n, input, c, context.temp_allocator)
		kit.expect_clean_render(t, r)
		kit.render_report_destroy(&r)
	}
	cmp := kit.compare_buffers(outs[0], outs[1])
	testing.expectf(t, cmp.max_abs_error == 0.5 && cmp.max_error_at == 512, "expected the 512-block render to apply the event early at frame 512, got err %v at %d", cmp.max_abs_error, cmp.max_error_at)
}
