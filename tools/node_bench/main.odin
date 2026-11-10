// Measures what the engine's nodes cost on this machine: each node, and a
// whole mix of tracks, rendered at a given block size, reported as time per
// block and as a share of the real-time budget. For sizing a project on
// small machines (a Raspberry Pi) before building it.
//
//	odin run tools/node_bench -collection:fire=f_engine -o:speed -- [block] [tracks]
//
// Defaults: 64-frame blocks at 48 kHz, 16 tracks.
package node_bench

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:time"

import "fire:core"
import "fire:dsp"
import "fire:graph"
import "fire:rt"

SR :: 48_000.0
SECONDS :: 4

Case :: struct {
	name:  string,
	make:  proc() -> core.Node,
	ins:   int,
	notes: bool, // send it a chord
}

main :: proc() {
	block := 64
	tracks := 16
	if len(os.args) > 1 do block = strconv.parse_int(os.args[1]) or_else 64
	if len(os.args) > 2 do tracks = strconv.parse_int(os.args[2]) or_else 16
	block = clamp(block, 16, 4096)
	ir := make([]f32, int(SR)) // a one-second impulse response
	for &x, i in ir do x = f32(0.5) / f32(1 + i)
	@(static) ir_channels: [2][]f32
	ir_channels = {ir, ir}

	cases := []Case {
		{"gain", proc() -> core.Node { return dsp.gain_create() }, 2, false},
		{"filter", proc() -> core.Node { return dsp.filter_create() }, 2, false},
		{"eq (4 bands)", proc() -> core.Node { return dsp.eq_create(4) }, 2, false},
		{"compressor", proc() -> core.Node { return dsp.compressor_create() }, 2, false},
		{"limiter", proc() -> core.Node { return dsp.limiter_create() }, 2, false},
		{"gate", proc() -> core.Node { return dsp.gate_create() }, 2, false},
		{"delay", proc() -> core.Node { return dsp.delay_create() }, 2, false},
		{"chorus", proc() -> core.Node { return dsp.chorus_create() }, 2, false},
		{"phaser", proc() -> core.Node { return dsp.phaser_create() }, 2, false},
		{"reverb", proc() -> core.Node { return dsp.reverb_create() }, 2, false},
		{"saturation (4x)", proc() -> core.Node { return dsp.saturation_create(4) }, 2, false},
		{"convolution (1 s)", proc() -> core.Node { return dsp.convolution_create(ir_channels[:]) }, 2, false},
		{"synth (8 notes)", proc() -> core.Node { return dsp.synth_create(16) }, 0, true},
	}
	budget := f64(block) / SR * 1e9
	fmt.printf("%s %s, %d-frame blocks at %.0f kHz (budget %.0f µs)\n", ODIN_OS, ODIN_ARCH, block, SR / 1000, budget / 1000)
	fmt.printf("%-20s %10s %10s %8s\n", "node", "median µs", "p99 µs", "% budget")
	for c in cases {
		n := c.make()
		median, p99 := bench_node(&n, c.ins, block, c.notes)
		core.node_destroy(&n)
		row(c.name, median, p99, budget)
		fmt.println()
	}

	// A mix: per track a synth, EQ, compressor and gain; reverb and limiter
	// on the master. Run on every core but one, as an app would.
	st := graph.default_settings(SR, block)
	st.input_channels = 0
	g, _ := graph.create(st)
	defer graph.destroy(g)
	master, _ := graph.add_node(g, dsp.limiter_create(), 2, 2)
	verb, _ := graph.add_node(g, dsp.reverb_create(), 2, 2)
	for _ in 0 ..< tracks {
		syn, _ := graph.add_node(g, dsp.synth_create(16), 0, 2)
		eq, _ := graph.add_node(g, dsp.eq_create(4), 2, 2)
		comp, _ := graph.add_node(g, dsp.compressor_create(), 2, 2)
		gain, _ := graph.add_node(g, dsp.gain_create(), 2, 2)
		graph.connect_events(g, graph.INPUT, syn)
		for ch in 0 ..< 2 {
			graph.connect(g, syn, ch, eq, ch)
			graph.connect(g, eq, ch, comp, ch)
			graph.connect(g, comp, ch, gain, ch)
			graph.connect(g, gain, ch, verb, ch)
		}
	}
	for ch in 0 ..< 2 {
		graph.connect(g, verb, ch, master, ch)
		graph.connect(g, master, ch, graph.OUTPUT, ch)
	}
	graph.commit(g)
	mix := graph.as_node(g)
	median, p99 := bench_node(&mix, 0, block, true)
	row("mix", median, p99, budget)
	fmt.printf("  (%d tracks of synth, eq, compressor, gain; reverb and limiter)\n", tracks)
}

// Renders SECONDS of audio in `block`-frame blocks; median and 99th
// percentile time per block, in ns.
bench_node :: proc(n: ^core.Node, ins, block: int, notes: bool) -> (median, p99: f64) {
	core.node_prepare(n, {sample_rate = SR, max_block = block, in_channels = ins, out_channels = 2})
	in_buf := make([][]f32, ins)
	for &b, i in in_buf {
		b = make([]f32, block)
		for &x, k in b do x = f32(0.25) * f32((k * 7919 + i * 31) % 200 - 100) / 100 // noise-ish
	}
	out_buf := [2][]f32{make([]f32, block), make([]f32, block)}
	chord: [8]core.Event
	for &e, i in chord do e = {0, core.Note_On{id = core.Note_Id(i + 1), key = u8(48 + 3 * i), velocity = 0.7}}
	blocks := int(SECONDS * SR) / block
	times := make([]f64, blocks)
	defer delete(times)
	_ = rt.enable_flush_to_zero()
	for i in 0 ..< blocks {
		ctx := core.Process_Context{inputs = in_buf, outputs = out_buf[:], frames = block}
		if notes && i == 0 do ctx.events_in = chord[:]
		t0 := time.tick_now()
		core.node_process(n, &ctx)
		times[i] = f64(time.tick_since(t0))
	}
	slice.sort(times[blocks / 10:]) // the first tenth warms up
	rest := times[blocks / 10:]
	return rest[len(rest) / 2], rest[len(rest) * 99 / 100]
}

row :: proc(name: string, median, p99, budget: f64) {
	fmt.printf("%-20s %10s %10s %8s", name,
		fmt.tprintf("%.2f", median / 1000), fmt.tprintf("%.2f", p99 / 1000), fmt.tprintf("%.2f%%", 100 * median / budget))
}
