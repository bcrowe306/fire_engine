package test_graph

import "base:intrinsics"
import "core:log"
import "core:math"
import "core:mem"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

import "fire:core"
import "fire:graph"
import kit "fire:testkit"

// Held by each test here that runs graph workers flat out, so the test
// runner (which runs tests in parallel) never runs two at once. On a
// 2-core machine two of them, each with a spinning audio thread and
// elevated workers, starve each other: the control thread's 200 µs sleeps
// took 0.8 s, an audio thread stalled for over 10 s, and the speed-up
// measured 0.84×.
cpu_heavy: sync.Mutex

// Builds the same random DAG for the same seed: scale and delay nodes, mono
// and stereo, each input channel fed by 1–3 earlier nodes, several feeding
// OUTPUT.
build_random :: proc(g: ^graph.Graph, seed: u64, count: int) {
	rng := kit.Rng{state = seed}
	Built :: struct {
		id:       graph.Node_Id,
		channels: int,
	}
	nodes := make([dynamic]Built, context.temp_allocator)
	append(&nodes, Built{graph.INPUT, 2})
	for _ in 0 ..< count {
		ch := kit.rng_range(&rng, 1, 2)
		node: core.Node
		if kit.rng_range(&rng, 0, 9) < 3 {
			node = delay(kit.rng_range(&rng, 1, 50))
		} else {
			node = scale(f32(kit.rng_next_f64(&rng) * 2 - 1))
		}
		id, err := graph.add_node(g, node, ch, ch)
		assert(err == .None)
		for c in 0 ..< ch {
			for _ in 0 ..< kit.rng_range(&rng, 1, 3) {
				src := nodes[kit.rng_range(&rng, 0, len(nodes) - 1)]
				graph.connect(g, src.id, kit.rng_range(&rng, 0, src.channels - 1), id, c) // duplicates are refused; fine
			}
		}
		append(&nodes, Built{id, ch})
	}
	for k in 0 ..< 8 {
		src := nodes[len(nodes) - 1 - k]
		graph.connect(g, src.id, 0, graph.OUTPUT, k % 2)
	}
	err := graph.commit(g)
	assert(err == .None)
}

// The same graph gives bit-identical output for any number of workers:
// summing and event merging run in a fixed order, not in thread order.
@(test)
output_is_identical_for_any_thread_count :: proc(t: ^testing.T) {
	sync.guard(&cpu_heavy)
	testing.set_fail_timeout(t, 60 * time.Second)
	in_ := noise(2, 20_000, 9)
	reference: kit.Audio_Buffer
	for seed in ([]u64{1, 2, 3}) {
		for workers, k in ([]int{0, 1, 3, 7}) {
			trap: kit.Trap_Allocator
			st := graph.default_settings(SR, MAX_BLOCK)
			st.workers = workers
			st.parallel_min_us = 0 // always parallel when the graph allows it
			st.worker_allocator = kit.trap_allocator(&trap)
			g, err := graph.create(st)
			testing.expect_value(t, err, core.Error.None)
			build_random(g, seed, 80)
			out := render(t, g, in_, render_cfg())
			graph.destroy(g)
			testing.expectf(t, trap.violations == 0, "seed %d, %d workers: %d allocations on workers", seed, workers, trap.violations)
			testing.expectf(t, kit.peak(out.channels[0]) > 0, "seed %d: silent output", seed)
			if k == 0 {
				reference = out
				continue
			}
			cmp := kit.compare_buffers(reference, out)
			testing.expectf(t, cmp.max_abs_error == 0, "seed %d, %d workers: differs from single-threaded by %v at %d", seed, workers, cmp.max_abs_error, cmp.max_error_at)
		}
	}
}

Stress :: struct {
	g:        ^graph.Graph,
	stop:     bool, // atomic
	blocks:   int, // atomic
	bad:      int,  // non-finite samples
	trap:     kit.Trap_Allocator,
}

// One thread processes blocks nonstop (as an audio callback would) while the
// control thread adds, removes, reconnects and commits. Plans are swapped,
// retired and freed under load; nothing may crash, allocate on the audio side
// or produce non-finite output.
@(test)
live_edits_under_load :: proc(t: ^testing.T) {
	sync.guard(&cpu_heavy)
	testing.set_fail_timeout(t, 120 * time.Second)
	st := graph.default_settings(SR, 128)
	st.workers = 3
	st.parallel_min_us = 0
	// On the heap: if the runner ever stops this test (a timeout), the audio
	// thread and workers keep running, and must not be left pointing into
	// this thread's stack.
	s := new(Stress)
	defer free(s)
	st.worker_allocator = kit.trap_allocator(&s.trap)
	g, err := graph.create(st)
	testing.expect_value(t, err, core.Error.None)
	s.g = g
	build_random(g, 42, 40)

	audio := thread.create_and_start_with_data(s, proc(data: rawptr) {
		s := (^Stress)(data)
		context.allocator = kit.trap_allocator(&s.trap)
		context.temp_allocator = context.allocator
		input := [2][128]f32{}
		output := [2][128]f32{}
		ins := [2][]f32{input[0][:], input[1][:]}
		outs := [2][]f32{output[0][:], output[1][:]}
		for c in 0 ..< 2 do for &x, i in input[c] do x = f32(math.sin(f64(i) * 0.1))
		for !intrinsics.atomic_load(&s.stop) {
			ctx := core.Process_Context{inputs = ins[:], outputs = outs[:], frames = 128}
			graph.process(s.g, &ctx)
			for o in outs do for x in o do if math.is_nan(x) || math.is_inf(x) do s.bad += 1
			intrinsics.atomic_add(&s.blocks, 1)
		}
	})

	rng := kit.Rng{state = 7}
	ids := make([dynamic]graph.Node_Id, context.temp_allocator)
	// Up to 300 edits, for at most 30 s. Between edits the control thread
	// waits (briefly) for the audio thread to process a block, so it meets
	// each plan. It spins rather than sleeps or yields: on a loaded machine
	// with long scheduler quanta (Windows Server), giving up the CPU can cost
	// most of a second each time.
	start := time.tick_now()
	edits := 0
	for edit in 0 ..< 300 {
		if time.tick_since(start) > 30 * time.Second do break
		edits += 1
		switch kit.rng_range(&rng, 0, 2) {
		case 0: // add a node in series with something
			id, _ := graph.add_node(g, scale(0.5), 2, 2)
			append(&ids, id)
			graph.connect(g, graph.INPUT, 0, id, 0)
			graph.connect(g, id, 0, graph.OUTPUT, edit % 2)
		case 1: // remove one we added
			if len(ids) > 0 {
				k := kit.rng_range(&rng, 0, len(ids) - 1)
				graph.remove_node(g, ids[k])
				unordered_remove(&ids, k)
			}
		case 2: // rewire
			if len(ids) > 1 {
				graph.connect(g, ids[0], 1, ids[len(ids) - 1], 1)
			}
		}
		b0 := intrinsics.atomic_load(&s.blocks)
		testing.expect_value(t, graph.commit(g), core.Error.None)
		w := time.tick_now()
		for intrinsics.atomic_load(&s.blocks) == b0 && time.tick_since(w) < 2 * time.Millisecond do intrinsics.cpu_relax()
	}
	time.sleep(20 * time.Millisecond)
	intrinsics.atomic_store(&s.stop, true)
	thread.join(audio)
	thread.destroy(audio)
	graph.destroy(g)

	log.infof("%d blocks processed during %d edits", s.blocks, edits)
	testing.expectf(t, edits >= 50, "only %d edits in 30 s", edits)
	testing.expect(t, s.blocks > 100, "the audio thread barely ran")
	testing.expect_value(t, s.bad, 0)
	testing.expect_value(t, s.trap.violations, 0)
}

// --- a measurable parallel workload ------------------------------------------------------

// Burns a fixed amount of CPU per sample (a stand-in for a heavy plugin).
busy_vtable := core.Node_VTable {
	prepare = proc(self: rawptr, cfg: core.Prepare_Config, a: mem.Allocator) -> core.Error { return .None },
	process = proc(self: rawptr, ctx: ^core.Process_Context) {
		for out, c in ctx.outputs {
			for &s, i in out {
				x := ctx.inputs[c][i]
				for _ in 0 ..< 200 do x = x * 0.999 + 0.0001
				s = x
			}
		}
	},
	destroy = proc(self: rawptr, a: mem.Allocator) {},
}

render_parallel :: proc(t: ^testing.T, workers: int) -> (kit.Audio_Buffer, time.Duration) {
	st := graph.default_settings(SR, 512)
	st.workers = workers
	g, _ := graph.create(st)
	defer graph.destroy(g)
	for chain in 0 ..< 16 {
		prev := graph.INPUT
		for _ in 0 ..< 4 {
			id, _ := graph.add_node(g, core.node_make(&busy_vtable, nil, context.allocator), 1, 1)
			graph.connect(g, prev, 0, id, 0)
			prev = id
		}
		graph.connect(g, prev, 0, graph.OUTPUT, chain % 2)
	}
	graph.commit(g)
	cfg := render_cfg()
	cfg.max_block = 512
	cfg.blocks = kit.Fixed_Blocks{512}
	start := time.tick_now()
	n := graph.as_node(g)
	out, report := kit.render(&n, noise(2, 48_000, 11), cfg, context.temp_allocator)
	kit.render_report_destroy(&report)
	return out, time.tick_since(start)
}

// 16 independent chains of heavy nodes: with default settings the graph
// measures its work, switches to parallel by itself, and finishes sooner with
// identical output.
@(test)
parallel_chains_speed_up :: proc(t: ^testing.T) {
	sync.guard(&cpu_heavy)
	testing.set_fail_timeout(t, 120 * time.Second)
	single, t1 := render_parallel(t, 0)
	multi, tn := render_parallel(t, -1)
	testing.expect_value(t, kit.compare_buffers(single, multi).max_abs_error, 0)
	log.infof("16 chains × 4 heavy nodes, 1 s of audio: single-threaded %v, all cores %v (×%.2f)", t1, tn, f64(t1) / f64(tn))
}
