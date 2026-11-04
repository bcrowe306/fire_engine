/*
Effects from fire:dsp in a graph: noise through a resonant lowpass whose
cutoff sweeps up and back down (an automation ramp, followed exactly), then
a parametric EQ. Renders four seconds offline, prints the EQ's curve and
the output level as the filter opens, and writes a WAV file.

	odin run examples/effects -collection:fire=f_engine
*/
package effects

import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:path/filepath"

import "fire:audiofile"
import "fire:core"
import "fire:dsp"
import "fire:graph"

SAMPLE_RATE :: 48_000.0
BLOCK :: 512

main :: proc() {
	dir, _ := os.make_directory_temp("", "fire_effects", context.allocator)
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, "effects.wav"}, context.allocator)
	defer delete(path)

	settings := graph.default_settings(SAMPLE_RATE, BLOCK)
	settings.input_channels, settings.workers = 0, 0
	g, _ := graph.create(settings)
	defer graph.destroy(g)

	// noise → lowpass (Q 6) → 4-band EQ → stereo out
	noise, _ := graph.add_node(g, core.node_make(&noise_vtable, new(Noise), context.allocator), 0, 1)
	filter, _ := graph.add_node(g, dsp.filter_create(.Lowpass), 1, 1)
	eq_node := dsp.eq_create(4)
	eq := (^dsp.Eq)(eq_node.data) // to read its curve below
	e, _ := graph.add_node(g, eq_node, 1, 1)
	graph.connect(g, noise, 0, filter, 0)
	graph.connect(g, filter, 0, e, 0)
	graph.connect(g, e, 0, graph.OUTPUT, 0)
	graph.connect(g, e, 0, graph.OUTPUT, 1)

	graph.set_param(g, filter, dsp.FILTER_PARAM_Q, 6)
	graph.set_param(g, filter, dsp.FILTER_PARAM_CUTOFF_HZ, 150)
	band := dsp.eq_band_param
	graph.set_param(g, e, band(0, .Gain_Db), 4)                    // low shelf at 100 Hz: +4 dB
	graph.set_param(g, e, band(2, .Freq_Hz), 3000)                 // a bell at 3 kHz...
	graph.set_param(g, e, band(2, .Gain_Db), -8)                   // ...cut 8 dB
	graph.set_param(g, e, band(2, .Q), 2)
	graph.set_param(g, e, band(3, .Gain_Db), -3)                   // high shelf at 8 kHz: −3 dB
	graph.commit(g)

	w, _ := audiofile.writer_create(path, audiofile.default_writer_settings(SAMPLE_RATE, 2))
	left, right: [BLOCK]f32
	frames := int(4 * SAMPLE_RATE)
	sum, count := 0.0, 0
	for at := 0; at < frames; at += BLOCK {
		// The sweep: up to 8 kHz over 2 s, then back down over 1.5 s, as
		// ramps the filter follows sample by sample.
		if at == 0 do graph.set_param_ramp(g, filter, dsp.FILTER_PARAM_CUTOFF_HZ, 8000, int(2 * SAMPLE_RATE))
		if at <= int(2.25 * SAMPLE_RATE) && int(2.25 * SAMPLE_RATE) < at + BLOCK {
			graph.set_param_ramp(g, filter, dsp.FILTER_PARAM_CUTOFF_HZ, 150, int(1.5 * SAMPLE_RATE))
		}
		ctx := core.Process_Context{outputs = {left[:], right[:]}, frames = BLOCK}
		graph.process(g, &ctx)
		audiofile.writer_write(w, {left[:], right[:]}, BLOCK)
		for s in left do sum += f64(s) * f64(s)
		count += BLOCK
		if count >= int(SAMPLE_RATE / 2) {
			fmt.printf("%.1f s: %5.1f dBFS\n", f64(at + BLOCK) / SAMPLE_RATE, 10 * math.log10(sum / f64(count) + 1e-20))
			sum, count = 0, 0
		}
	}
	audiofile.writer_close(w)

	fmt.print("EQ curve:")
	for f in ([]f64{50, 100, 300, 1000, 3000, 8000, 16000}) do fmt.printf("  %.0f Hz %+.1f dB", f, 20 * math.log10(dsp.eq_response(eq, f)))
	fmt.println()
}

// White noise at −12 dBFS.
Noise :: struct {
	seed: u32,
}

noise_vtable := core.Node_VTable {
	prepare = proc(self: rawptr, cfg: core.Prepare_Config, a: mem.Allocator) -> core.Error {
		(^Noise)(self).seed = 1
		return .None
	},
	process = proc(self: rawptr, ctx: ^core.Process_Context) {
		n := (^Noise)(self)
		for &x in ctx.outputs[0] {
			n.seed = n.seed * 1664525 + 1013904223
			x = 0.25 * (f32(n.seed >> 8) / f32(1 << 24) * 2 - 1)
		}
	},
	destroy = proc(self: rawptr, a: mem.Allocator) { free(self, a) },
}
