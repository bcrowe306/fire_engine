package testkit

import "core:fmt"
import "core:testing"

import "fire:core"

expect_near :: proc(t: ^testing.T, actual, expected, tolerance: f64, what := "", loc := #caller_location) -> bool {
	ok := abs(actual - expected) <= tolerance
	testing.expectf(t, ok, "%s: got %.9g, expected %.9g ± %.3g (off by %.3g)", what, actual, expected, tolerance, abs(actual - expected), loc = loc)
	return ok
}

// The checks every render must pass: prepared OK, no rt allocations,
// every output sample written and finite, no dropped output events.
expect_clean_render :: proc(t: ^testing.T, r: Render_Report, loc := #caller_location) -> bool {
	ok := true
	if r.prepare_error != .None {
		testing.expectf(t, false, "prepare failed: %v", r.prepare_error, loc = loc)
		return false
	}
	if r.rt_allocations > 0 {
		testing.expectf(t, false, "%d allocation(s) on the audio thread; first at %v", r.rt_allocations, r.first_rt_alloc, loc = loc)
		ok = false
	}
	if r.non_finite > 0 {
		testing.expectf(t, false, "%d non-finite output samples (NaN means unwritten or NaN); first at frame %d", r.non_finite, r.first_non_finite, loc = loc)
		ok = false
	}
	if r.events_dropped > 0 {
		testing.expectf(t, false, "%d output events dropped", r.events_dropped, loc = loc)
		ok = false
	}
	return ok
}

Node_Factory :: struct {
	create: proc(user: rawptr) -> core.Node,
	user:   rawptr,
}

// Renders the same input/events with every pattern in `patterns` (each through a
// fresh node from `factory`) and requires all outputs to match the first within
// `tolerance`. This is the main proof of sample-accurate, block-independent DSP.
expect_block_invariant :: proc(
	t: ^testing.T,
	factory: Node_Factory,
	input: Audio_Buffer,
	cfg: Render_Config,
	patterns: []Block_Pattern,
	tolerance: f64 = 1e-6,
	name := "block_invariance",
	loc := #caller_location,
) -> bool {
	assert(len(patterns) > 0)
	ok := true

	ref_node := factory.create(factory.user)
	defer core.node_destroy(&ref_node)
	c0 := cfg
	c0.blocks = patterns[0]
	reference, r0 := render(&ref_node, input, c0, context.temp_allocator)
	ok &= expect_clean_render(t, r0, loc)

	for pattern in patterns[1:] {
		node := factory.create(factory.user)
		defer core.node_destroy(&node)
		c := cfg
		c.blocks = pattern
		out, r := render(&node, input, c, context.temp_allocator)
		ok &= expect_clean_render(t, r, loc)
		cmp := compare_buffers(reference, out)
		if cmp.frame_mismatch || cmp.max_abs_error > tolerance {
			case_name := fmt.tprintf("%s_%v", name, pattern)
			dump_comparison(case_name, reference, out, cmp)
			testing.expectf(t, false,
				"block pattern %v differs from %v: max_abs=%.3g at ch %d frame %d (tol %.3g). Artifacts: %s",
				pattern, patterns[0], cmp.max_abs_error, cmp.max_error_ch, cmp.max_error_at, tolerance, artifact_dir(case_name), loc = loc)
			ok = false
		}
	}
	return ok
}
