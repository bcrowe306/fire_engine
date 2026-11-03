/*
Writes a 44.1 kHz recording, reads it back (as any format would be read),
converts it to 48 kHz with the resampler, and saves the result as 16-bit
AIFF. Prints what each file holds.

	odin run examples/audio_files -collection:fire=f_engine
*/
package audio_files

import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"

import "fire:audiofile"
import "fire:audiofile/codecs"
import "fire:dsp"

main :: proc() {
	dir, _ := os.make_directory_temp("", "fire_audio_files", context.allocator)
	defer os.remove_all(dir)
	recording, _ := filepath.join({dir, "recording.wav"}, context.allocator)
	converted, _ := filepath.join({dir, "converted.aiff"}, context.allocator)
	defer delete(recording)
	defer delete(converted)

	// 1. Record two seconds of a stereo chord, 24-bit WAV at 44.1 kHz, as a
	//    disk thread would: block by block.
	{
		w, err := audiofile.writer_create(recording, audiofile.default_writer_settings(44_100, 2))
		if err != .None {
			fmt.eprintln("writer_create:", err)
			return
		}
		left, right: [512]f32
		for at := 0; at < 2 * 44_100; at += 512 {
			for i in 0 ..< 512 {
				t := f64(at + i) / 44_100
				left[i] = f32(0.3 * math.sin(math.TAU * 440 * t))
				right[i] = f32(0.3 * math.sin(math.TAU * 554.37 * t))
			}
			audiofile.writer_write(w, {left[:], right[:]}, 512)
		}
		audiofile.writer_close(w)
	}

	// 2. Read it back. codecs.open reads WAV, AIFF, FLAC, MP3 and Ogg alike.
	r, err := codecs.open(recording)
	if err != .None {
		fmt.eprintln("open:", err)
		return
	}
	defer audiofile.close(r)
	info := audiofile.info(r)
	fmt.printf("%s: %v %v, %d channels, %.0f Hz, %d frames\n", filepath.base(recording), info.format, info.encoding, info.channels, info.sample_rate, info.frames)

	// 3. Convert to 48 kHz: each output frame advances 44100/48000 input frames.
	speed := info.sample_rate / 48_000
	rs: dsp.Resampler
	dsp.resampler_init(&rs, info.channels, .High)
	defer dsp.resampler_destroy(&rs)
	settings := audiofile.default_writer_settings(48_000, info.channels)
	settings.format, settings.encoding = .Aiff, .Int16 // dithered
	w, _ := audiofile.writer_create(converted, settings)

	in_buf: [2][2048]f32 // room for the filter's look-ahead too
	out_buf: [2][1024]f32
	ins := [][]f32{in_buf[0][:], in_buf[1][:]}
	outs := [][]f32{out_buf[0][:], out_buf[1][:]}
	total := int(f64(info.frames) / speed)
	for written := 0; written < total; {
		want := min(len(out_buf[0]), total - written)
		// Read exactly what the resampler needs for `want` more frames
		// (silence past the end of the file).
		need := dsp.resampler_input_needed(&rs, want, speed)
		got, _ := audiofile.read(r, {ins[0][:need], ins[1][:need]}, need)
		for c in 0 ..< 2 do for &s in ins[c][got:need] do s = 0
		_, made := dsp.resampler_process(&rs, {ins[0][:need], ins[1][:need]}, {outs[0][:want], outs[1][:want]}, speed)
		audiofile.writer_write(w, outs, made)
		written += made
	}
	audiofile.writer_close(w)

	// 4. Check the result.
	out, _ := audiofile.open(converted)
	defer audiofile.close(out)
	oi := audiofile.info(out)
	fmt.printf("%s: %v %v, %d channels, %.0f Hz, %d frames (%.3f s)\n", filepath.base(converted), oi.format, oi.encoding, oi.channels, oi.sample_rate, oi.frames, f64(oi.frames) / oi.sample_rate)
}
