// Measures what Synth 1 (fire:synth) costs on this machine, against its
// budget (docs/design/synth.md): eight voices, each with three oscillators
// of four unison voices and two filters, under 25% of one core at 48 kHz,
// 1× oversampling. Other rows take one thing away or change it, to show
// where the time goes.
//
//	odin run tools/synth_bench -collection:fire=f_engine -o:speed -- [block]
//
// Default: 128-frame blocks.
package synth_bench

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:time"

import "fire:core"
import "fire:rt"
import "fire:synth"

SR :: 48_000.0
SECONDS :: 4
NOTES :: 8

// A change to the budget patch.
Setup :: struct {
	name:  string,
	apply: proc(s: ^synth.Synth),
}

main :: proc() {
	block := 128
	if len(os.args) > 1 do block = strconv.parse_int(os.args[1]) or_else 128
	block = clamp(block, 16, 4096)

	saw, _ := synth.builtin_table(.Saw)
	defer synth.wavetable_destroy(saw)

	setups := []Setup {
		{"budget patch", nil},
		{"1 unison voice", proc(s: ^synth.Synth) {for n in 1 ..= 3 do set(s, synth.osc_param(n, .Unison), 1)}},
		{"16 unison voices", proc(s: ^synth.Synth) {for n in 1 ..= 3 do set(s, synth.osc_param(n, .Unison), 16)}},
		{"1 oscillator", proc(s: ^synth.Synth) {set(s, synth.osc_param(2, .On), 0); set(s, synth.osc_param(3, .On), 0)}},
		{"no filters", proc(s: ^synth.Synth) {set(s, synth.filter_param(1, .On), 0); set(s, synth.filter_param(2, .On), 0)}},
		{"1 filter", proc(s: ^synth.Synth) {set(s, synth.filter_param(2, .On), 0)}},
		{"voices only", proc(s: ^synth.Synth) {
			for n in 1 ..= 3 do set(s, synth.osc_param(n, .On), 0)
			set(s, synth.filter_param(1, .On), 0)
			set(s, synth.filter_param(2, .On), 0)
		}},
		{"no oscillators", proc(s: ^synth.Synth) {for n in 1 ..= 3 do set(s, synth.osc_param(n, .On), 0)}},
		{"2x oversampling", proc(s: ^synth.Synth) {set(s, synth.global_param(.Oversampling), 1)}},
	}

	budget := f64(block) / SR * 1e9
	fmt.printf("%s %s, Synth 1, %d notes, %d-frame blocks at %.0f kHz (real time %.0f µs a block)\n",
		ODIN_OS, ODIN_ARCH, NOTES, block, SR / 1000, budget / 1000)
	fmt.printf("budget patch: 3 oscillators × 4 unison voices, 2 filters, 1× (goal: under 25%%)\n\n")
	fmt.printf("%-20s %10s %10s %8s\n", "setup", "median µs", "p99 µs", "% core")
	for c in setups {
		node, s := synth.synth_create()
		patch := synth.patch_default()
		patch.tables = {saw, saw, saw}
		synth.synth_set_patch(s, &patch)
		set(s, synth.global_param(.Polyphony), NOTES)
		for n in 1 ..= 3 {
			set(s, synth.osc_param(n, .On), 1)
			set(s, synth.osc_param(n, .Unison), 4)
		}
		set(s, synth.filter_param(1, .On), 1)
		set(s, synth.filter_param(2, .On), 1)
		set(s, synth.global_param(.Oversampling), 0)
		if c.apply != nil do c.apply(s)
		median, p99 := bench(&node, block)
		core.node_destroy(&node)
		fmt.printf("%-20s %10s %10s %8s\n", c.name, fmt.tprintf("%.2f", median / 1000), fmt.tprintf("%.2f", p99 / 1000), fmt.tprintf("%.2f%%", 100 * median / budget))
	}
}

set :: proc(s: ^synth.Synth, id: core.Param_Id, v: f32) {
	s.values[id] = v
}

// Renders SECONDS of a held eight-note chord in `block`-frame blocks;
// median and 99th percentile time per block, in ns.
bench :: proc(n: ^core.Node, block: int) -> (median, p99: f64) {
	core.node_prepare(n, {sample_rate = SR, max_block = block, in_channels = 0, out_channels = 2})
	out_buf := [2][]f32{make([]f32, block), make([]f32, block)}
	defer {delete(out_buf[0]); delete(out_buf[1])}
	chord: [NOTES]core.Event
	for &e, i in chord do e = {0, core.Note_On{id = core.Note_Id(i + 1), key = u8(40 + 4 * i), velocity = 0.8}}
	blocks := int(SECONDS * SR) / block
	times := make([]f64, blocks)
	defer delete(times)
	_ = rt.enable_flush_to_zero()
	for i in 0 ..< blocks {
		ctx := core.Process_Context{outputs = out_buf[:], frames = block}
		if i == 0 do ctx.events_in = chord[:]
		t0 := time.tick_now()
		core.node_process(n, &ctx)
		times[i] = f64(time.tick_since(t0))
	}
	rest := times[blocks / 10:] // the first tenth warms up
	slice.sort(rest)
	return rest[len(rest) / 2], rest[len(rest) * 99 / 100]
}
