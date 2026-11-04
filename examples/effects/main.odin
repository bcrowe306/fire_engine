/*
Effects from fire:dsp in a graph: noise through a resonant lowpass whose
cutoff sweeps up and back down (an automation ramp, followed exactly), a
parametric EQ, a ping-pong delay (which makes it stereo), a compressor and
a limiter. Renders four seconds offline,
prints the level and the dynamics' gain reduction as the filter opens, the
EQ's curve, and writes a WAV file.

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

	// noise → lowpass (Q 6) → 4-band EQ → ping-pong delay → compressor → limiter
	noise, _ := graph.add_node(g, core.node_make(&noise_vtable, new(Noise), context.allocator), 0, 1)
	filter, _ := graph.add_node(g, dsp.filter_create(.Lowpass), 1, 1)
	eq_node := dsp.eq_create(4)
	eq := (^dsp.Eq)(eq_node.data) // to read its curve below
	e, _ := graph.add_node(g, eq_node, 1, 1)
	graph.connect(g, noise, 0, filter, 0)
	comp_node := dsp.compressor_create()
	comp := (^dsp.Compressor)(comp_node.data) // for its meter
	c, _ := graph.add_node(g, comp_node, 2, 2)
	lim_node := dsp.limiter_create(5)
	lim := (^dsp.Limiter)(lim_node.data)
	l, _ := graph.add_node(g, lim_node, 2, 2)
	d, _ := graph.add_node(g, dsp.delay_create(), 1, 2) // mono in, ping-pong out
	graph.connect(g, filter, 0, e, 0)
	graph.connect(g, e, 0, d, 0)
	for ch in 0 ..< 2 {
		graph.connect(g, d, ch, c, ch)
		graph.connect(g, c, ch, l, ch)
		graph.connect(g, l, ch, graph.OUTPUT, ch)
	}

	graph.set_param(g, filter, dsp.FILTER_PARAM_Q, 6)
	graph.set_param(g, filter, dsp.FILTER_PARAM_CUTOFF_HZ, 150)
	band := dsp.eq_band_param
	graph.set_param(g, e, band(0, .Gain_Db), 4)                    // low shelf at 100 Hz: +4 dB
	graph.set_param(g, e, band(2, .Freq_Hz), 3000)                 // a bell at 3 kHz...
	graph.set_param(g, e, band(2, .Gain_Db), -8)                   // ...cut 8 dB
	graph.set_param(g, e, band(2, .Q), 2)
	graph.set_param(g, e, band(3, .Gain_Db), -3)                   // high shelf at 8 kHz: −3 dB
	graph.set_param(g, d, dsp.DELAY_PARAM_TIME_MS, 300)
	graph.set_param(g, d, dsp.DELAY_PARAM_PING_PONG, 1)
	graph.set_param(g, d, dsp.DELAY_PARAM_FEEDBACK, 45)
	graph.set_param(g, d, dsp.DELAY_PARAM_HIGH_CUT_HZ, 4000)        // darker echoes
	graph.set_param(g, d, dsp.DELAY_PARAM_MIX, 50)
	graph.set_param(g, c, dsp.COMPRESSOR_PARAM_THRESHOLD_DB, -24)  // evens out the sweep...
	graph.set_param(g, c, dsp.COMPRESSOR_PARAM_RATIO, 3)
	graph.set_param(g, c, dsp.COMPRESSOR_PARAM_MAKEUP_DB, 6)
	graph.set_param(g, l, dsp.LIMITER_PARAM_INPUT_DB, 6)           // ...and the limiter makes it loud, safely
	graph.set_param(g, l, dsp.LIMITER_PARAM_CEILING_DB, -1)
	graph.commit(g)

	w, _ := audiofile.writer_create(path, audiofile.default_writer_settings(SAMPLE_RATE, 2))
	left, right: [BLOCK]f32
	frames := int(4 * SAMPLE_RATE)
	sum_l, sum_r, count, peak := 0.0, 0.0, 0, f32(0)
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
		for i in 0 ..< BLOCK {
			sum_l += f64(left[i]) * f64(left[i])
			sum_r += f64(right[i]) * f64(right[i])
			peak = max(peak, abs(left[i]), abs(right[i]))
		}
		count += BLOCK
		if count >= int(SAMPLE_RATE / 2) {
			fmt.printf("%.1f s: L %5.1f dBFS, R %5.1f dBFS RMS; compressor −%.1f dB, limiter −%.1f dB\n", f64(at + BLOCK) / SAMPLE_RATE,
				10 * math.log10(sum_l / f64(count) + 1e-20), 10 * math.log10(sum_r / f64(count) + 1e-20),
				dsp.compressor_gain_reduction_db(comp), dsp.limiter_gain_reduction_db(lim))
			sum_l, sum_r, count = 0, 0, 0
		}
	}
	audiofile.writer_close(w)
	fmt.printf("peak %.2f dBFS (the limiter's ceiling is −1)\n", 20 * math.log10(f64(peak)))

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
