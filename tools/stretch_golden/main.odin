/*
Records Signalsmith Stretch's C++ output for every reference case
(testkit.stretch_reference_cases) into tests/golden/stretch/<name>.wav
(32-bit float), and its speed into tests/golden/stretch/TIMINGS.md. Run once,
before the C++ is removed; the pure-Odin port is then tested against these.

	./scripts/stretch.sh
	odin run tools/stretch_golden -collection:fire=f_engine -o:speed -- "<machine description>"
*/
package stretch_golden

import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

import "fire:audiofile"
import ss "fire:sys/signalsmith"
import kit "fire:testkit"

main :: proc() {
	machine := os.args[1] if len(os.args) > 1 else "unknown machine"
	dir := filepath.join({#directory, "..", "..", "tests", "golden", "stretch"}, context.allocator) or_else ""
	_ = os.make_directory_all(dir)

	report := strings.builder_make()
	fmt.sbprintf(&report, "---\ntitle: Signalsmith Stretch reference timings\ndescription: Speed of the C++ Signalsmith Stretch 1.4.0 on the reference cases, the baseline for the Odin port.\n---\n\n")
	fmt.sbprintf(&report, "Recorded by `tools/stretch_golden` on %s, %v/%v, %s.\n", machine, ODIN_OS, ODIN_ARCH, time_now())
	fmt.sbprintf(&report, "The C++ was built by `scripts/stretch.sh` (CMake Release). Times are the best of 3 runs.\n\n")
	fmt.sbprintf(&report, "| Case | Channels | Output (s) | CPU (ms) | × real time |\n|---|---|---|---|---|\n")

	failed := false
	for &c in kit.stretch_reference_cases {
		input := kit.stretch_case_input(c)
		a := render_best(&c, input, 3)
		b := render_best(&c, input, 1)
		for ch, k in a.out do for v, i in ch {
			if v != b.out[k][i] {
				fmt.eprintfln("%s: two runs differ (frame %d): not deterministic", c.name, i)
				failed = true
				break
			}
			if math.is_nan(v) || math.is_inf(v) {
				fmt.eprintfln("%s: non-finite output at frame %d", c.name, i)
				failed = true
				break
			}
		}
		path := filepath.join({dir, strings.concatenate({string(c.name), ".wav"})}) or_else ""
		settings := audiofile.default_writer_settings(f64(c.sample_rate), int(c.channels))
		settings.encoding = .Float32 // exact, and outputs can exceed full scale
		w, err := audiofile.writer_create(path, settings)
		if err != .None {
			fmt.eprintfln("%s: %v", path, err)
			os.exit(1)
		}
		audiofile.writer_write(w, a.out, int(c.out_frames))
		audiofile.writer_close(w)
		seconds := f64(c.out_frames) / f64(c.sample_rate)
		fmt.sbprintf(&report, "| `%s` | %d | %.2f | %.2f | %.0f |\n", c.name, c.channels, seconds, a.seconds * 1000, seconds / a.seconds)
		fmt.printfln("%-32s peak %.3f  %.2f ms", c.name, peak(a.out), a.seconds * 1000)
	}

	// A longer, realistic load: 10 s of stereo drums at the default preset.
	bench := kit.Stretch_Case{name = "benchmark", signal = .Drums, sample_rate = 48_000, channels = 2, in_frames = 480_000, out_frames = 480_000, rate = 1, transpose = 1, formant = 1, chunks = {512, 0, 0, 0}}
	r := render_best(&bench, kit.stretch_case_input(bench), 3)
	fmt.sbprintf(&report, "\n**Benchmark:** 10 s of stereo drums at 48 kHz, default preset, rate 1, 512-frame chunks: %.1f ms of CPU (%.0f× real time, %.2f%% of one core).\n", r.seconds * 1000, 10 / r.seconds, r.seconds / 10 * 100)
	fmt.printfln("benchmark: %.1f ms for 10 s stereo", r.seconds * 1000)

	report_path := filepath.join({dir, "TIMINGS.md"}) or_else ""
	_ = os.write_entire_file(report_path, transmute([]u8)strings.to_string(report))
	if failed do os.exit(1)
}

Rendered :: struct {
	out:     [][]f32,
	seconds: f64,
}

// Renders a case `runs` times; keeps the last output and the fastest time.
render_best :: proc(c: ^kit.Stretch_Case, input: [][]f32, runs: int) -> (r: Rendered) {
	r.out = make([][]f32, c.channels)
	for &ch in r.out do ch = make([]f32, c.out_frames)
	ins := make([][^]f32, c.channels)
	outs := make([][^]f32, c.channels)
	for k in 0 ..< int(c.channels) {
		ins[k] = raw_data(input[k])
		outs[k] = raw_data(r.out[k])
	}
	r.seconds = math.F64_MAX
	for _ in 0 ..< runs {
		for ch in r.out do for &v in ch do v = 0
		r.seconds = min(r.seconds, ss.test_render(c, raw_data(ins), raw_data(outs)))
	}
	return
}

peak :: proc(chans: [][]f32) -> f32 {
	p: f32
	for ch in chans do for v in ch do p = max(p, abs(v))
	return p
}

time_now :: proc() -> string {
	y, mo, d := time.date(time.now())
	return fmt.tprintf("%d-%02d-%02d", y, int(mo), d)
}
