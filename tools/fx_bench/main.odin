// Measures each effect of fire:fx (Synth 1's chain, and Pads' inserts and
// bus effects, which are the same) alone at its defaults: the time of a
// 256-frame stereo block at 48 kHz, and its share of the block's budget
// (5333 µs), the best of five runs.
//
//	odin run tools/fx_bench -collection:fire=f_engine -o:speed -- [block] [varied]
//
// "varied": other settings than the defaults (hotter, more voices, other
// styles), for comparing outputs (the hash) across a change.
package fx_bench

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:time"

import "fire:fx"
import "fire:rt"

SR :: 48_000.0
SECONDS :: 4

main :: proc() {
	block := 256
	if len(os.args) > 1 do block = strconv.parse_int(os.args[1]) or_else 256
	block = clamp(block, 16, 4096)
	varied := len(os.args) > 2 && os.args[2] == "varied"
	rt.enable_flush_to_zero()

	// A busy input: noise and a saw, the same each run.
	n := int(SR) * SECONDS
	src := [2][]f32{make([]f32, n), make([]f32, n)}
	seed: u32 = 1
	for i in 0 ..< n {
		seed = seed * 1664525 + 1013904223
		noise := f32(seed >> 8) / f32(1 << 24) - 0.5
		saw := f32(i % 218) / 109 - 1
		hot: f32 = 4 if varied && i % 48_000 > 40_000 else 1 // (into clipping, now and then)
		src[0][i] = (0.3 * noise + 0.3 * saw) * hot
		src[1][i] = (0.3 * noise - 0.3 * saw) * hot
	}
	l, r := make([]f32, block), make([]f32, block)
	budget := 1e6 * f64(block) / SR

	fmt.printfln("%d-frame blocks at %.0f Hz (budget %.0f µs)", block, SR, budget)
	fmt.printfln("%-12s %10s %10s %8s  %s", "effect", "median µs", "p99 µs", "budget", "output hash (5 runs)")
	for e in fx.Effect {
		// The best of five runs (a fresh chain each): the median block, and
		// the 99th percentile.
		med, p99 := max(f64), max(f64)
		hash: u64 = 14695981039346656037 // FNV-1a of the output's bits: the same sound, exactly
		for _ in 0 ..< 5 {
			c: fx.Chain
			fx.chain_make(&c, SR)
			defer fx.chain_destroy(&c)
			p := fx.CHAIN_DEFAULTS
			p.on = {e}
			if varied do vary(&p)
			times := make([dynamic]f64, 0, n / block)
			defer delete(times)
			for at := 0; at + block <= n; at += block {
				copy(l, src[0][at:at + block])
				copy(r, src[1][at:at + block])
				t0 := time.tick_now()
				fx.chain_render(&c, &p, l, r, SR)
				append(&times, f64(time.tick_since(t0)) / 1000)
				for x in l do hash = (hash ~ u64(transmute(u32)x)) * 1099511628211
				for x in r do hash = (hash ~ u64(transmute(u32)x)) * 1099511628211
			}
			slice.sort(times[:])
			med = min(med, times[len(times) / 2])
			p99 = min(p99, times[len(times) * 99 / 100])
		}
		fmt.printfln("%-12v %10s %10s %7s%%  %16x", e, fmt.tprintf("%.1f", med), fmt.tprintf("%.1f", p99), fmt.tprintf("%.2f", 100 * med / budget), hash)
	}
}

// Settings other than the defaults.
vary :: proc(p: ^fx.Chain_Params) {
	p.chorus.voices, p.chorus.feedback, p.chorus.depth, p.chorus.hz = 3, -0.8, 0.9, 2
	p.compressor.mix = 0.7
	p.delay.style, p.delay.feedback, p.delay.hz = .Ping_Pong, 0.9, {7, 3}
	p.distortion.type, p.distortion.drive_db, p.distortion.order = .Sine_Fold, 12, .Pre
	p.filter.filter.resonance = 0.9
	p.flanger.feedback, p.flanger.hz = -0.9, 1.5
	p.phaser.feedback, p.phaser.blend, p.phaser.hz, p.phaser.offset = 0.95, 2, 3, 0.7
	p.reverb.size, p.reverb.decay, p.reverb.chorus, p.reverb.chorus_hz, p.reverb.delay = 1, 8, 1, 3, 0.05
}
