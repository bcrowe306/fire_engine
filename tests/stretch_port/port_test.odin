package test_stretch_port

import "core:log"
import "core:math"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"

import "fire:audiofile"
import "fire:stretch"
import kit "fire:testkit"

// Renders a reference case through the Odin port, driving it exactly as
// the C++ was driven to make the recordings.
port_render :: proc(c: ^kit.Stretch_Case, input: [][]f32) -> [][]f32 {
	ch := int(c.channels)
	s: stretch.Stretch
	if c.cheaper {
		stretch.stretch_preset_cheaper(&s, ch, c.sample_rate, bool(c.split), context.temp_allocator)
	} else {
		stretch.stretch_preset_default(&s, ch, c.sample_rate, bool(c.split), context.temp_allocator)
	}
	stretch.stretch_set_transpose_factor(&s, c.transpose, c.tonality_limit)
	if c.freq_map == 1 {
		stretch.stretch_set_freq_map(&s, proc "contextless" (f: f32, user: rawptr) -> f32 { return kit.stretch_case_freq_map(f) })
	}
	stretch.stretch_set_formant_factor(&s, c.formant, bool(c.formant_compensate))
	stretch.stretch_set_formant_base(&s, c.formant_base)

	padded := int(c.in_frames) + int(f32(c.out_frames) * c.rate) + stretch.stretch_output_seek_length(&s, c.rate) + stretch.stretch_seek_length(&s) + 8192
	in_ := make([][]f32, ch, context.temp_allocator)
	out := make([][]f32, ch, context.temp_allocator)
	for k in 0 ..< ch {
		in_[k] = make([]f32, padded, context.temp_allocator)
		copy(in_[k], input[k])
		out[k] = make([]f32, c.out_frames, context.temp_allocator)
	}
	at_in := proc(v: [][]f32, frame: int) -> [][]f32 {
		r := make([][]f32, len(v), context.temp_allocator)
		for k in 0 ..< len(v) do r[k] = v[k][frame:]
		return r
	}
	if c.mode == .Exact {
		stretch.stretch_exact(&s, in_, int(c.in_frames), out, int(c.out_frames))
		return out
	}
	main_out := int(c.out_frames) - (int(c.flush_frames) if c.mode == .Stream_Flush else 0)
	seek_len := stretch.stretch_output_seek_length(&s, c.rate)
	stretch.stretch_output_seek(&s, in_, seek_len)
	in_pos, out_pos, k := seek_len, 0, 0
	in_acc := f64(seek_len)
	sought := false
	nchunks := 0
	for nchunks < 4 && c.chunks[nchunks] > 0 do nchunks += 1
	for out_pos < main_out {
		if c.mode == .Stream_Seek && !sought && out_pos >= int(c.seek_at_out) {
			pre := min(stretch.stretch_seek_length(&s), int(c.seek_to_in))
			stretch.stretch_seek(&s, at_in(in_, int(c.seek_to_in) - pre), pre, f64(c.rate))
			in_pos = int(c.seek_to_in)
			in_acc = f64(in_pos)
			sought = true
		}
		n := int(c.chunks[k % nchunks])
		k += 1
		if c.mode == .Stream_Seek && !sought do n = min(n, int(c.seek_at_out) - out_pos)
		n = min(n, main_out - out_pos)
		in_acc += f64(n) * f64(c.rate)
		n_in := int(math.floor(in_acc)) - in_pos
		stretch.stretch_process(&s, at_in(in_, in_pos), n_in, at_in(out, out_pos), n)
		in_pos += n_in
		out_pos += n
	}
	if c.mode == .Stream_Flush do stretch.stretch_flush(&s, at_in(out, main_out), int(c.flush_frames), c.rate)
	stretch.stretch_destroy(&s)
	return out
}

read_recording :: proc(t: ^testing.T, c: ^kit.Stretch_Case) -> ([][]f32, bool) {
	path := filepath.join({#directory, "..", "golden", "stretch", strings.concatenate({string(c.name), ".wav"}, context.temp_allocator)}, context.temp_allocator) or_else ""
	r, err := audiofile.open(path)
	if !testing.expectf(t, err == .None, "%s: %v", path, err) do return nil, false
	defer audiofile.close(r)
	info := audiofile.info(r)
	want := make([][]f32, info.channels, context.temp_allocator)
	for &ch in want do ch = make([]f32, info.frames, context.temp_allocator)
	audiofile.read(r, want, int(info.frames))
	return want, true
}

// The Odin port against the C++'s recordings: its first block must match
// (on the Mac that made them), and over the whole recording it must sound the
// same: spectral distance within each case's tolerance, which is set from
// the C++'s own variation (tests/golden/stretch/README.md).
@(test)
port_matches_the_recordings :: proc(t: ^testing.T) {
	for &c in kit.stretch_reference_cases {
		want := read_recording(t, &c) or_continue
		got := port_render(&c, kit.stretch_case_input(c, context.temp_allocator))
		// The first block (before rounding differences can compound), and
		// how long the port stays within −90 dB of the recording.
		first_block := -999.0
		close_for := int(c.out_frames)
		spectral := 0.0
		block := int(c.sample_rate * (0.1 if c.cheaper else 0.12))
		for k in 0 ..< int(c.channels) {
			scale := max(kit.peak(want[k]), 1e-12)
			worst: f32
			for i in 0 ..< min(block, int(c.out_frames)) do worst = max(worst, abs(got[k][i] - want[k][i]))
			first_block = max(first_block, kit.linear_to_db(f64(worst) / scale))
			for i in 0 ..< int(c.out_frames) {
				if f64(abs(got[k][i] - want[k][i])) > scale * 3.2e-5 {
					close_for = min(close_for, i)
					break
				}
			}
			spectral = max(spectral, kit.spectral_distance(want[k], got[k], f64(c.sample_rate)))
		}
		n, _ := kit.count_non_finite(got[0])
		log.infof("%-32s first block %7.1f dB; within −90 dB for %6d of %6d frames; spectra %.3f dB (tolerance %.2f)", c.name, first_block, close_for, c.out_frames, spectral, c.tolerance)
		testing.expectf(t, n == 0, "%s: non-finite output", c.name)
		testing.expectf(t, spectral <= f64(c.tolerance), "%s: spectra differ by %.3f dB (tolerance %.2f)", c.name, spectral, c.tolerance)
		// On the Mac that made the recordings, the first block must match: a
		// porting mistake shows up here as −20 to −40 dB, while rounding stays
		// near −120 dB (−80 dB at most, on a pitch-shifted drum hit).
		if ODIN_OS == .Darwin && ODIN_ARCH == .arm64 do testing.expectf(t, first_block < -70, "%s: first block differs from the recording by %.1f dB", c.name, first_block)
	}
}

// Nothing the audio thread calls allocates: every feature, split or not.
@(test)
port_never_allocates :: proc(t: ^testing.T) {
	input := kit.stretch_case_input({signal = .Voice, sample_rate = 48_000, channels = 2, in_frames = 48_000}, context.temp_allocator)
	out := [2][]f32{make([]f32, 48_000, context.temp_allocator), make([]f32, 48_000, context.temp_allocator)}
	for split in ([]bool{false, true}) {
		s: stretch.Stretch
		stretch.stretch_preset_default(&s, 2, 48_000, split)
		trap: kit.Trap_Allocator
		{
			context.allocator = kit.trap_allocator(&trap)
			context.temp_allocator = context.allocator
			stretch.stretch_set_transpose_semitones(&s, 5, 0.1)
			stretch.stretch_set_formant_semitones(&s, -2, true)
			stretch.stretch_set_formant_base(&s, 0)
			stretch.stretch_output_seek(&s, input, stretch.stretch_output_seek_length(&s, 0.7))
			in_pos := 0
			for at := 0; at + 512 <= 40_000; at += 512 {
				n_in := 358 // a rate of 0.7: past 2× nothing random, but every other path
				ins := [2][]f32{input[0][in_pos:], input[1][in_pos:]}
				outs := [2][]f32{out[0][at:], out[1][at:]}
				stretch.stretch_process(&s, ins[:], n_in, outs[:], 512)
				in_pos = min(in_pos + n_in, 40_000)
			}
			stretch.stretch_seek(&s, input, stretch.stretch_seek_length(&s), 1)
			stretch.stretch_flush(&s, {out[0][:3000], out[1][:3000]}, 3000, 1)
			stretch.stretch_exact(&s, input, 20_000, {out[0][:30_000], out[1][:30_000]}, 30_000)
		}
		testing.expectf(t, trap.violations == 0, "split %v: %d allocations", split, trap.violations)
		n, _ := kit.count_non_finite(out[0])
		testing.expect_value(t, n, 0)
		stretch.stretch_destroy(&s)
	}
}

// Speed next to the C++ (tests/golden/stretch/TIMINGS.md: 70 ms for this on
// the Mac that recorded it). Logged, not asserted.
@(test)
port_speed :: proc(t: ^testing.T) {
	c := kit.Stretch_Case{name = "benchmark", signal = .Drums, sample_rate = 48_000, channels = 2, in_frames = 480_000, out_frames = 480_000, rate = 1, transpose = 1, formant = 1, chunks = {512, 0, 0, 0}}
	input := kit.stretch_case_input(c, context.temp_allocator)
	best := max(f64)
	for _ in 0 ..< 3 {
		start := time.tick_now()
		port_render(&c, input)
		best = min(best, time.duration_seconds(time.tick_since(start)))
	}
	log.infof("10 s of stereo drums at the default preset: %.1f ms (%.0f× real time)", best * 1000, 10 / best)
}
