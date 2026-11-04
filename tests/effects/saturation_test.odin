package test_effects

import "core:testing"

import "fire:core"
import "fire:dsp"
import kit "fire:testkit"

@(test)
oversampler_round_trip_is_a_pure_delay :: proc(t: ^testing.T) {
	for factor in ([]int{2, 4, 8}) {
		for hz in ([]f64{1000, 15_000}) {
			x := make([]f32, 20_000, context.temp_allocator)
			kit.sine(x, SR, hz, 0.5)
			outs: [2][]f32
			for chunks, k in ([2][]int{{512}, {1, 7, 64, 300}}) {
				o: dsp.Oversampler
				if !testing.expect_value(t, dsp.oversampler_init(&o, factor, 512), core.Error.None) do return
				defer dsp.oversampler_destroy(&o)
				outs[k] = make([]f32, len(x), context.temp_allocator)
				for at, c := 0, 0; at < len(x); c += 1 {
					n := min(chunks[c % len(chunks)], len(x) - at)
					high := dsp.oversampler_up(&o, x[at:][:n])
					dsp.oversampler_down(&o, high, outs[k][at:][:n])
					at += n
				}
				lat := dsp.oversampler_latency(&o)
				diff := kit.compare_slices(outs[k][lat + 2000:], x[2000:len(x) - lat])
				tolerance := 1e-4 if hz < 10_000 else 2e-3
				testing.expectf(t, diff.max_abs_error < tolerance, "%d× at %.0f Hz: off by %v after a %d-frame delay", factor, hz, diff.max_abs_error, lat)
			}
			testing.expect_value(t, kit.compare_slices(outs[0], outs[1]).max_abs_error, 0) // chunking doesn't matter
		}
	}
}

@(test)
oversampled_clipping_aliases_far_less :: proc(t: ^testing.T) {
	f0 := 6317.0
	n := 1 << 15
	x := make([]f32, n + 4096, context.temp_allocator)
	kit.sine(x, SR, f0, 0.9)
	db: [2]f64
	for factor, k in ([2]int{1, 4}) {
		node := dsp.saturation_create(factor)
		defer core.node_destroy(&node)
		input := kit.buffer_make(1, len(x), SR, context.temp_allocator)
		copy(input.channels[0], x)
		cfg := kit.default_render_config()
		cfg.out_channels = 1
		cfg.events = {{0, core.Param_Value{dsp.SATURATION_PARAM_SHAPE, f64(dsp.Saturation_Shape.Hard)}}, {0, core.Param_Ramp{dsp.SATURATION_PARAM_DRIVE_DB, 12, 0}}}
		out, r := kit.render(&node, input, cfg, context.temp_allocator)
		defer kit.render_report_destroy(&r)
		kit.expect_clean_render(t, r)
		db[k] = alias_db(out.channels[0][4096:], f0)
	}
	testing.expectf(t, db[1] < db[0] - 20, "aliasing: 1× %.1f dB, 4× %.1f dB", db[0], db[1])
}

@(test)
saturation_curves_and_dry_path :: proc(t: ^testing.T) {
	for shape in dsp.Saturation_Shape {
		if shape != .Fold do kit.expect_near(t, dsp.saturate(shape, 1e-4) / 1e-4, 1, 1e-3, "unity slope at 0")
		testing.expect(t, abs(dsp.saturate(shape, 50)) <= 1.0001)
	}
	// At 0% mix the node is the input, delayed by its latency exactly.
	node := dsp.saturation_create(4)
	defer core.node_destroy(&node)
	input := kit.buffer_make(2, 20_000, SR, context.temp_allocator)
	kit.white_noise(input.channels[0], 61, 0.5)
	kit.white_noise(input.channels[1], 62, 0.5)
	cfg := kit.default_render_config()
	cfg.events = {{0, core.Param_Ramp{dsp.SATURATION_PARAM_MIX, 0, 0}}}
	out, r := kit.render(&node, input, cfg, context.temp_allocator)
	defer kit.render_report_destroy(&r)
	lat := core.node_latency(&node)
	testing.expect(t, lat > 0)
	testing.expect_value(t, kit.compare_slices(out.channels[0][lat:], input.channels[0][:20_000 - lat]).max_abs_error, 0)
}

@(test)
tube_saturation_has_no_dc :: proc(t: ^testing.T) {
	node := dsp.saturation_create(2)
	defer core.node_destroy(&node)
	input := kit.buffer_make(1, 96_000, SR, context.temp_allocator)
	kit.sine(input.channels[0], SR, 220, 0.8)
	cfg := kit.default_render_config()
	cfg.out_channels = 1
	cfg.events = {{0, core.Param_Value{dsp.SATURATION_PARAM_SHAPE, f64(dsp.Saturation_Shape.Tube)}}, {0, core.Param_Ramp{dsp.SATURATION_PARAM_DRIVE_DB, 18, 0}}}
	out, r := kit.render(&node, input, cfg, context.temp_allocator)
	defer kit.render_report_destroy(&r)
	kit.expect_clean_render(t, r)
	testing.expectf(t, abs(kit.dc_offset(out.channels[0][48_000:])) < 1e-3, "DC %v", kit.dc_offset(out.channels[0][48_000:]))
}

@(test)
saturation_is_block_invariant :: proc(t: ^testing.T) {
	input := kit.buffer_make(2, 20_000, SR, context.temp_allocator)
	kit.white_noise(input.channels[0], 71, 0.7)
	kit.white_noise(input.channels[1], 72, 0.7)
	cfg := kit.default_render_config()
	cfg.events = {{3_000, core.Param_Ramp{dsp.SATURATION_PARAM_DRIVE_DB, 24, 5000}}, {9_000, core.Param_Value{dsp.SATURATION_PARAM_SHAPE, f64(dsp.Saturation_Shape.Fold)}}, {14_000, core.Param_Value{dsp.SATURATION_PARAM_MIX, 50}}}
	patterns := kit.standard_block_patterns(cfg.max_block)
	for factor in ([]int{1, 4}) {
		f := new_clone(factor, context.temp_allocator)
		factory := kit.Node_Factory{create = proc(user: rawptr) -> core.Node { return dsp.saturation_create((^int)(user)^) }, user = f}
		kit.expect_block_invariant(t, factory, input, cfg, patterns[:], 0, "saturation")
	}
}
