package test_stretch

import "core:log"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import "fire:audiofile"
import ss "fire:sys/signalsmith"
import kit "fire:testkit"

// How closely the C++ Signalsmith Stretch reproduces the reference
// recordings (tests/golden/stretch, made on macOS by tools/stretch_golden).
// Its waveforms diverge across compilers and maths libraries (a phase
// vocoder amplifies last-bit rounding: up to −23 dB on Linux and Windows)
// while its spectra don't, so the check is spectral; the logged figures set
// the tolerances the Odin port is held to (see the README there).
@(test)
cpp_reproduces_the_recordings :: proc(t: ^testing.T) {
	for &c in kit.stretch_reference_cases {
		path := filepath.join({#directory, "..", "golden", "stretch", strings.concatenate({string(c.name), ".wav"}, context.temp_allocator)}, context.temp_allocator) or_else ""
		r, err := audiofile.open(path)
		if !testing.expectf(t, err == .None, "%s: %v (run tools/stretch_golden)", path, err) do continue
		info := audiofile.info(r)
		want := make([][]f32, info.channels, context.temp_allocator)
		for &ch in want do ch = make([]f32, info.frames, context.temp_allocator)
		audiofile.read(r, want, int(info.frames))
		audiofile.close(r)
		testing.expectf(t, info.frames == i64(c.out_frames) && info.channels == int(c.channels), "%s: recording has %d × %d frames", c.name, info.channels, info.frames)

		input := kit.stretch_case_input(c, context.temp_allocator)
		got := make([][]f32, c.channels, context.temp_allocator)
		ins := make([][^]f32, c.channels, context.temp_allocator)
		outs := make([][^]f32, c.channels, context.temp_allocator)
		for k in 0 ..< int(c.channels) {
			got[k] = make([]f32, c.out_frames, context.temp_allocator)
			ins[k], outs[k] = raw_data(input[k]), raw_data(got[k])
		}
		ss.test_render(&c, raw_data(ins), raw_data(outs))
		sample, spectral := -999.0, 0.0
		for k in 0 ..< int(c.channels) {
			cmp := kit.compare_slices(want[k], got[k])
			sample = max(sample, kit.linear_to_db(cmp.max_abs_error / max(kit.peak(want[k]), 1e-12)))
			spectral = max(spectral, kit.spectral_distance(want[k], got[k], f64(c.sample_rate)))
		}
		log.infof("%-32s samples %7.1f dB, spectra %.3f dB", c.name, sample, spectral)
		// On the machine that made them, the recordings reproduce exactly.
		if ODIN_OS == .Darwin && ODIN_ARCH == .arm64 do testing.expectf(t, sample < -100, "%s: C++ differs from its recording by %.1f dB", c.name, sample)
		testing.expectf(t, spectral <= f64(c.tolerance), "%s: spectra differ by %.3f dB (tolerance %.2f)", c.name, spectral, c.tolerance)
	}
}
