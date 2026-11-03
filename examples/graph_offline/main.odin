/*
Builds a small graph (low-pass filter → gain) and renders two seconds of a
sawtooth through it offline, with the cutoff and gain automated
sample-accurately. Prints the level of each half second.

	odin run examples/graph_offline -collection:fire=f_engine
*/
package graph_offline

import "core:fmt"
import "core:math"

import "fire:core"
import "fire:dsp"
import "fire:graph"

SAMPLE_RATE :: 48_000.0
BLOCK :: 256

main :: proc() {
	// 1. A graph with one input and one output channel, processed on this
	//    thread only (workers = 0) since we render offline.
	settings := graph.default_settings(SAMPLE_RATE, BLOCK)
	settings.input_channels, settings.output_channels = 1, 1
	settings.workers = 0
	g, err := graph.create(settings)
	if err != .None {
		fmt.eprintln("graph.create:", err)
		return
	}
	defer graph.destroy(g)

	// 2. Nodes: the graph takes ownership and prepares them.
	filter, _ := graph.add_node(g, dsp.one_pole_create(), 1, 1)
	gain, _ := graph.add_node(g, dsp.gain_create(), 1, 1)

	// 3. INPUT → filter → gain → OUTPUT, then commit the edit.
	graph.connect(g, graph.INPUT, 0, filter, 0)
	graph.connect(g, filter, 0, gain, 0)
	graph.connect(g, gain, 0, graph.OUTPUT, 0)
	graph.commit(g)

	// 4. Automation on the graph's clock (frames since processing began).
	graph.set_param(g, filter, dsp.ONE_POLE_PARAM_CUTOFF_HZ, 300, at = 24_000) // at 0.5 s
	graph.set_param(g, gain, dsp.GAIN_PARAM_DB, -12, at = 48_000)              // at 1.0 s
	graph.set_param(g, filter, dsp.ONE_POLE_PARAM_CUTOFF_HZ, 8000, at = 72_000) // at 1.5 s

	// 5. Render block by block, as an audio callback would.
	input, output: [BLOCK]f32
	ins := [][]f32{input[:]}
	outs := [][]f32{output[:]}
	phase := 0.0
	sum_sq := 0.0
	for frame := 0; frame < 2 * int(SAMPLE_RATE); frame += BLOCK {
		for &x in input {
			x = f32(2 * phase - 1) * 0.5 // 110 Hz sawtooth
			phase = math.mod(phase + 110 / SAMPLE_RATE, 1)
		}
		ctx := core.Process_Context{inputs = ins, outputs = outs, frames = BLOCK}
		graph.process(g, &ctx)

		for x in output do sum_sq += f64(x) * f64(x)
		if (frame + BLOCK) % 24_000 < BLOCK {
			rms := math.sqrt(sum_sq / 24_000)
			fmt.printfln("%.1f s  rms %.1f dB", f64(frame + BLOCK) / SAMPLE_RATE, 20 * math.log10(max(rms, 1e-9)))
			sum_sq = 0
		}
	}
}
