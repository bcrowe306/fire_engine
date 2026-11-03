package test_codecs

import "core:log"
import "core:math"
import "core:path/filepath"
import "core:testing"

import "fire:audiofile"
import "fire:audiofile/codecs"
import kit "fire:testkit"

// The fixtures' signal (see tests/audiofile/fixtures/make_fixtures.sh).
expected :: proc(c, i: int) -> f32 {
	return f32(0.5 * math.sin(2 * math.PI * 441 * f64(c + 1) * f64(i) / 48000))
}

fixture :: proc(name: string) -> string {
	p, _ := filepath.join({#directory, "..", "audiofile", "fixtures", name}, context.temp_allocator)
	return p
}

read_all :: proc(t: ^testing.T, name: string) -> (info: audiofile.Info, chans: [][]f32, ok: bool) {
	r, err := codecs.open(fixture(name))
	if !testing.expectf(t, err == .None, "%s: %v", name, err) do return
	defer audiofile.close(r)
	info = audiofile.info(r)
	chans = make([][]f32, info.channels, context.temp_allocator)
	for &c in chans do c = make([]f32, info.frames, context.temp_allocator)
	n, rerr := audiofile.read(r, chans, int(info.frames))
	testing.expectf(t, rerr == .None && i64(n) == info.frames, "%s: read %d of %d: %v", name, n, info.frames, rerr)
	return info, chans, true
}

@(test)
flac_is_lossless :: proc(t: ^testing.T) {
	info, chans, ok := read_all(t, "flac_i24.flac")
	if !ok do return
	testing.expectf(t, info.format == .Flac && info.channels == 2 && info.sample_rate == 48_000 && info.frames == 1000, "%v", info)
	worst := 0.0
	for ch, c in chans do for s, i in ch do worst = max(worst, abs(f64(s) - f64(expected(c, i))))
	testing.expectf(t, worst < 1e-7, "FLAC differs from the 24-bit source by %v", worst)
}

// Lossy formats: right length, aligned with the source (no encoder delay
// left in), and close to it.
@(test)
lossy_formats_decode_aligned :: proc(t: ^testing.T) {
	Case :: struct {
		file:   string,
		format: audiofile.Format,
		snr_db: f64, // at least
	}
	for tc in ([]Case{{"ogg_q6.ogg", .Ogg_Vorbis, 30}, {"mp3_192k.mp3", .Mp3, 30}}) {
		info, chans := read_all(t, tc.file) or_continue
		testing.expectf(t, info.format == tc.format && info.channels == 2 && info.sample_rate == 48_000, "%s: %v", tc.file, info)
		testing.expectf(t, info.frames == 1000, "%s: %d frames, want 1000 (encoder delay or padding not removed)", tc.file, info.frames)
		ref := make([]f32, len(chans[1]), context.temp_allocator)
		for &s, i in ref do s = expected(1, i)
		lag := kit.estimate_latency(ref, chans[1], 100)
		testing.expectf(t, lag == 0, "%s: decoded audio is %d frames late", tc.file, lag)
		// SNR over the middle (codecs smear the edges).
		sig, noise: f64
		for i in 100 ..< min(900, len(ref)) {
			sig += f64(ref[i]) * f64(ref[i])
			d := f64(chans[1][i]) - f64(ref[i])
			noise += d * d
		}
		snr := 10 * math.log10(sig / max(noise, 1e-30))
		log.infof("%s: SNR %.1f dB", tc.file, snr)
		testing.expectf(t, snr > tc.snr_db, "%s: SNR %.1f dB", tc.file, snr)
	}
}

// Seeking lands on exactly the frame asked for, in every format.
@(test)
seeking_is_exact :: proc(t: ^testing.T) {
	for name in ([]string{"flac_i24.flac", "ogg_q6.ogg", "mp3_192k.mp3", "wav_i24.wav", "aiff_i16.aiff"}) {
		_, all := read_all(t, name) or_continue
		r, _ := codecs.open(fixture(name))
		defer audiofile.close(r)
		buf := [2][]f32{make([]f32, 100, context.temp_allocator), make([]f32, 100, context.temp_allocator)}
		for at in ([]i64{500, 0, 873, 999}) {
			testing.expectf(t, audiofile.seek(r, at) == .None, "%s: seek %d", name, at)
			n, _ := audiofile.read(r, buf[:], 100)
			testing.expectf(t, n == int(min(100, 1000 - at)), "%s: read %d after seeking to %d", name, n, at)
			worst := 0.0
			for i in 0 ..< n do worst = max(worst, abs(f64(buf[0][i]) - f64(all[0][int(at) + i])))
			testing.expectf(t, worst < 1e-6, "%s: after seeking to %d, differs from a straight read by %v", name, at, worst)
		}
		testing.expect_value(t, audiofile.seek(r, 1000), audiofile.Error.None)
		n, _ := audiofile.read(r, buf[:], 100)
		testing.expectf(t, n == 0, "%s: %d frames past the end", name, n)
	}
}

@(test)
unknown_files_are_rejected :: proc(t: ^testing.T) {
	_, err := codecs.open(fixture("make_fixtures.sh"))
	testing.expect_value(t, err, audiofile.Error.Unsupported_Format)
	_, err = codecs.open(fixture("missing.flac"))
	testing.expect_value(t, err, audiofile.Error.Not_Found)
}
