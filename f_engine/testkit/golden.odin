package testkit

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

// Artifacts (actual/expected/diff WAVs + info) go here on failure.
// Override with FIRE_ARTIFACTS_DIR. Render plots with: python3 scripts/plot.py <dir>
artifacts_root :: proc() -> string {
	if v, ok := os.lookup_env("FIRE_ARTIFACTS_DIR", context.temp_allocator); ok && v != "" do return v
	return ".test_artifacts"
}

update_golden_requested :: proc() -> bool {
	v, ok := os.lookup_env("FIRE_UPDATE_GOLDEN", context.temp_allocator)
	return ok && v != "" && v != "0"
}

// Creates `<artifacts>/<name>/` and returns its path (temp-allocated).
artifact_dir :: proc(name: string) -> string {
	dir, _ := filepath.join({artifacts_root(), name}, context.temp_allocator)
	_ = os.make_directory_all(dir)
	return dir
}

// Writes `<artifacts>/<name>/<label>.wav`. Handy for dumping intermediate signals.
write_artifact :: proc(name, label: string, b: Audio_Buffer) {
	dir := artifact_dir(name)
	path, _ := filepath.join({dir, strings.concatenate({label, ".wav"}, context.temp_allocator)}, context.temp_allocator)
	_ = wav_write(path, b)
}

write_artifact_note :: proc(name, text: string) {
	dir := artifact_dir(name)
	path, _ := filepath.join({dir, "info.txt"}, context.temp_allocator)
	_ = os.write_entire_file(path, text)
}

// Compares `actual` against `<golden_dir>/<name>.wav` with an absolute
// per-sample tolerance. With FIRE_UPDATE_GOLDEN=1, the golden file is (re)written
// and the test passes. A missing golden file fails unless updating.
expect_golden :: proc(t: ^testing.T, golden_dir, name: string, actual: Audio_Buffer, tolerance: f64 = 1e-5, loc := #caller_location) -> bool {
	path, _ := filepath.join({golden_dir, strings.concatenate({name, ".wav"}, context.temp_allocator)}, context.temp_allocator)

	if update_golden_requested() {
		_ = os.make_directory_all(golden_dir)
		if wav_write(path, actual) != .None {
			testing.expectf(t, false, "could not write golden %s", path, loc = loc)
			return false
		}
		return true
	}

	expected, err := wav_read(path, context.temp_allocator)
	if err != .None {
		write_artifact(name, "actual", actual)
		testing.expectf(t, false, "golden %s unreadable (%v). Run with FIRE_UPDATE_GOLDEN=1 to create it; candidate written to %s", path, err, artifact_dir(name), loc = loc)
		return false
	}

	r := compare_buffers(expected, actual)
	if !r.frame_mismatch && r.max_abs_error <= tolerance do return true

	dump_comparison(name, expected, actual, r)
	testing.expectf(t, false,
		"golden %s mismatch: max_abs=%.3g (tol %.3g) at ch %d frame %d, rms err %.1f dB, frame/channel mismatch=%v. Artifacts: %s  (python3 scripts/plot.py %s)",
		name, r.max_abs_error, tolerance, r.max_error_ch, r.max_error_at, r.error_db, r.frame_mismatch,
		artifact_dir(name), artifact_dir(name), loc = loc)
	return false
}

// Writes expected/actual/diff WAVs and an info note for a failed comparison.
dump_comparison :: proc(name: string, expected, actual: Audio_Buffer, r: Compare_Result) {
	write_artifact(name, "expected", expected)
	write_artifact(name, "actual", actual)
	if len(expected.channels) == len(actual.channels) {
		frames := min(expected.frames, actual.frames)
		diff := buffer_make(len(actual.channels), frames, actual.sample_rate, context.temp_allocator)
		for c in 0 ..< len(actual.channels) {
			for i in 0 ..< frames do diff.channels[c][i] = actual.channels[c][i] - expected.channels[c][i]
		}
		write_artifact(name, "diff", diff)
	}
	write_artifact_note(name, fmt.tprintf(
		"max_abs_error=%g\nmax_error_ch=%d\nmax_error_at=%d\nrms_error=%g\nerror_db=%g\nframe_mismatch=%v\n",
		r.max_abs_error, r.max_error_ch, r.max_error_at, r.rms_error, r.error_db, r.frame_mismatch))
}
