package test_audiofile

import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:testing"

import "fire:audiofile"
import kit "fire:testkit"

// The fixtures' signal: channel c, frame i (see fixtures/make_fixtures.sh).
expected :: proc(c, i: int) -> f32 {
	return f32(0.5 * math.sin(2 * math.PI * 441 * f64(c + 1) * f64(i) / 48000))
}

// A scratch path for one test's file.
temp_path :: proc(name: string) -> string {
	dir := os.get_env("FIRE_ARTIFACTS_DIR", context.temp_allocator)
	if dir == "" do dir = "."
	_ = os.make_directory_all(join({dir, "audiofile"}))
	return join({dir, "audiofile", name})
}

// A fixture's path (tests run from the repository root).
fixture :: proc(name: string) -> string {
	return join({#directory, "fixtures", name})
}

join :: proc(parts: []string) -> string {
	p, _ := filepath.join(parts, context.temp_allocator)
	return p
}

read_all :: proc(t: ^testing.T, path: string) -> (info: audiofile.Info, chans: [][]f32, ok: bool) {
	r, err := audiofile.open(path)
	if !testing.expectf(t, err == .None, "%s: open failed: %v", path, err) do return
	defer audiofile.close(r)
	info = audiofile.info(r)
	chans = make([][]f32, info.channels, context.temp_allocator)
	for &c in chans do c = make([]f32, info.frames, context.temp_allocator)
	n, rerr := audiofile.read(r, chans, int(info.frames))
	testing.expectf(t, rerr == .None && i64(n) == info.frames, "%s: read %d of %d frames: %v", path, n, info.frames, rerr)
	return info, chans, true
}

@(test)
reads_files_made_by_other_tools :: proc(t: ^testing.T) {
	Case :: struct {
		file:     string,
		format:   audiofile.Format,
		encoding: audiofile.Sample_Format,
		channels: int,
		tol:      f64, // quantization of the stored encoding (the source was 24-bit)
	}
	cases := []Case{
		{"wav_u8.wav", .Wav, .Int8, 2, 1.0 / 128},
		{"wav_i16.wav", .Wav, .Int16, 2, 1.0 / 32768},
		{"wav_i24.wav", .Wav, .Int24, 2, 1e-7},
		{"wav_i32.wav", .Wav, .Int32, 2, 1e-7},
		{"wav_f32.wav", .Wav, .Float32, 2, 1e-7},
		{"wav_f64.wav", .Wav, .Float64, 2, 1e-7},
		{"wav_i24_4ch.wav", .Wav, .Int24, 4, 1e-7},
		{"aiff_i8.aiff", .Aiff, .Int8, 2, 1.0 / 128},
		{"aiff_i16.aiff", .Aiff, .Int16, 2, 1.0 / 32768},
		{"aiff_i24.aiff", .Aiff, .Int24, 2, 1e-7},
		{"aifc_f32.aifc", .Aiff, .Float32, 2, 1e-7},
		{"aifc_f64.aifc", .Aiff, .Float64, 2, 1e-7},
	}
	for tc in cases {
		info, chans := read_all(t, fixture(tc.file)) or_continue
		testing.expectf(t, info.format == tc.format && info.encoding == tc.encoding && info.channels == tc.channels,
			"%s: got %v %v %d channels", tc.file, info.format, info.encoding, info.channels)
		testing.expectf(t, info.sample_rate == 48000 && info.frames == 1000 && !info.recovered,
			"%s: %v Hz, %d frames, recovered %v", tc.file, info.sample_rate, info.frames, info.recovered)
		worst := 0.0
		for ch, c in chans do for s, i in ch do worst = max(worst, abs(f64(s) - f64(expected(c, i))))
		testing.expectf(t, worst <= tc.tol * 1.01, "%s: off by %v (allowed %v)", tc.file, worst, tc.tol)
	}
}

@(test)
round_trips_every_writable_encoding :: proc(t: ^testing.T) {
	src: [3][]f32
	for &c, k in src {
		c = make([]f32, 70_001, context.temp_allocator) // spans several scratch buffers; odd length
		kit.white_noise(c, u64(k + 1), 0.9)
	}
	src[0][5] = 1.5 // clipped by integer encodings
	src[1][6] = -1.5
	Case :: struct {
		format:   audiofile.Format,
		encoding: audiofile.Sample_Format,
		channels: int,
		tol:      f64,
	}
	cases := []Case{
		{.Wav, .Int16, 1, 2.0 / 32768}, // ±1 LSB of dither plus rounding
		{.Wav, .Int24, 1, 0.5 / 8388608},
		{.Wav, .Int24, 3, 0.5 / 8388608}, // WAVE_FORMAT_EXTENSIBLE
		{.Wav, .Int32, 2, 1.2e-7}, // f32 holds 24 bits of a 32-bit sample
		{.Wav, .Float32, 2, 0},
		{.Wav, .Float64, 3, 0},
		{.Aiff, .Int16, 2, 2.0 / 32768},
		{.Aiff, .Int24, 1, 0.5 / 8388608},
		{.Aiff, .Int32, 3, 1.2e-7},
		{.Aiff, .Float32, 2, 0},
		{.Aiff, .Float64, 1, 0},
	}
	for tc in cases {
		path := temp_path(fmt.tprintf("rt_%v_%v_%d", tc.format, tc.encoding, tc.channels))
		s := audiofile.default_writer_settings(44_100, tc.channels)
		s.format, s.encoding = tc.format, tc.encoding
		w, err := audiofile.writer_create(path, s)
		if !testing.expectf(t, err == .None, "%v: %v", tc, err) do continue
		// Uneven writes: the file must not depend on how writing was split.
		for at := 0; at < 70_001; {
			n := min(70_001 - at, 1 + (at * 7919) % 9000)
			ins := make([][]f32, tc.channels, context.temp_allocator)
			for &c, k in ins do c = src[k][at:]
			testing.expect_value(t, audiofile.writer_write(w, ins, n), audiofile.Error.None)
			at += n
		}
		testing.expect_value(t, audiofile.writer_close(w), audiofile.Error.None)

		info, chans := read_all(t, path) or_continue
		testing.expectf(t, info.format == tc.format && info.encoding == tc.encoding && info.channels == tc.channels &&
			info.sample_rate == 44_100 && info.frames == 70_001 && !info.recovered, "%v: read back as %v", tc, info)
		worst, at := 0.0, 0
		for ch, c in chans {
			for x, i in ch {
				want := f64(src[c][i])
				if tc.encoding != .Float32 && tc.encoding != .Float64 do want = clamp(want, -1, 1 - 1.0 / 8388608)
				if d := abs(f64(x) - want); d > worst do worst, at = d, i
			}
		}
		testing.expectf(t, worst <= tc.tol + 1e-12, "%v: off by %v at frame %d", tc, worst, at)
	}
}

@(test)
seek_and_partial_reads :: proc(t: ^testing.T) {
	r, err := audiofile.open(fixture("wav_i24.wav"))
	if !testing.expect_value(t, err, audiofile.Error.None) do return
	defer audiofile.close(r)
	buf := [2][]f32{make([]f32, 300, context.temp_allocator), make([]f32, 300, context.temp_allocator)}
	for at in ([]i64{0, 999, 500, 1, 700}) {
		testing.expect_value(t, audiofile.seek(r, at), audiofile.Error.None)
		n, _ := audiofile.read(r, buf[:], 300)
		testing.expect_value(t, n, int(min(300, 1000 - at)))
		for i in 0 ..< n do kit.expect_near(t, f64(buf[1][i]), f64(expected(1, int(at) + i)), 1e-6, "after seek")
		testing.expect_value(t, audiofile.position(r), at + i64(n))
	}
	n, _ := audiofile.read(r, buf[:], 300) // at the end
	testing.expect_value(t, n, 0)
	testing.expect_value(t, audiofile.seek(r, 1001), audiofile.Error.Invalid_Argument)
	// Fewer output slices than channels: the rest are skipped.
	audiofile.seek(r, 10)
	n, _ = audiofile.read(r, buf[:1], 5)
	testing.expect_value(t, n, 5)
	kit.expect_near(t, f64(buf[0][0]), f64(expected(0, 10)), 1e-6, "channel 0 only")
}

// A recording interrupted before `writer_close` still opens, with everything
// that reached the disk.
@(test)
unfinished_files_are_recovered :: proc(t: ^testing.T) {
	for format in ([]audiofile.Format{.Wav, .Aiff}) {
		for interval in ([]i64{0, 1000}) {
			path := temp_path(fmt.tprintf("crash_%v_%d", format, interval))
			s := audiofile.default_writer_settings(48_000, 2)
			s.format, s.header_interval = format, interval
			w, _ := audiofile.writer_create(path, s)
			ch := make([]f32, 2500, context.temp_allocator)
			kit.sine(ch, 48_000, 441, 0.5)
			// Header updates come after a write passes the interval: at 2000
			// frames with an interval of 1000, never with 0.
			for at := 0; at < 2500; at += 500 do audiofile.writer_write(w, {ch[at:], ch[at:]}, 500)

			// The writer is still open, as if the process had died.
			info, chans, ok := read_all(t, path)
			if ok {
				testing.expectf(t, info.frames == 2500, "%v interval %d: %d frames", format, interval, info.frames)
				testing.expectf(t, info.recovered, "%v interval %d: not flagged as recovered", format, interval)
				kit.expect_near(t, f64(chans[1][2499]), f64(ch[2499]), 1e-6, "last frame")
			}
			audiofile.writer_close(w)
			info, _ = read_all(t, path) or_continue
			testing.expectf(t, info.frames == 2500 && !info.recovered, "%v after close: %v", format, info)
		}
	}
}

// Past the RIFF size limit a WAV becomes RF64 in place (the limit is lowered
// here so the test needn't write 4 GB).
@(test)
wav_turns_into_rf64 :: proc(t: ^testing.T) {
	path := temp_path("rf64.wav")
	s := audiofile.default_writer_settings(48_000, 2)
	s.encoding = .Float32
	s.rf64_threshold = 10_000
	s.header_interval = 512
	w, _ := audiofile.writer_create(path, s)
	ch := make([]f32, 4000, context.temp_allocator)
	kit.white_noise(ch, 3, 0.5)
	for i := 0; i < 4000; i += 500 do audiofile.writer_write(w, {ch[i:], ch[i:]}, 500)
	testing.expect_value(t, audiofile.writer_close(w), audiofile.Error.None)

	data, _ := os.read_entire_file(path, context.temp_allocator)
	testing.expect_value(t, string(data[0:4]), "RF64")
	testing.expect_value(t, string(data[12:16]), "ds64")
	info, chans, ok := read_all(t, path)
	if !ok do return
	testing.expectf(t, info.frames == 4000 && !info.recovered, "read back %v", info)
	testing.expect_value(t, kit.compare_slices(ch, chans[1]).max_abs_error, 0)
}

@(test)
bad_files_fail_cleanly :: proc(t: ^testing.T) {
	_, err := audiofile.open(fixture("no_such_file.wav"))
	testing.expect_value(t, err, audiofile.Error.Not_Found)
	_, err = audiofile.open(fixture("make_fixtures.sh"))
	testing.expect_value(t, err, audiofile.Error.Unsupported_Format)
	// A header cut short.
	data, _ := os.read_entire_file(fixture("wav_i16.wav"), context.temp_allocator)
	path := temp_path("cut.wav")
	_ = os.write_entire_file(path, data[:30])
	_, err = audiofile.open(path)
	testing.expect_value(t, err, audiofile.Error.Corrupt)
	s := audiofile.default_writer_settings(48_000.5, 2)
	_, err = audiofile.writer_create(temp_path("bad.wav"), s)
	testing.expect_value(t, err, audiofile.Error.Invalid_Argument)
}
