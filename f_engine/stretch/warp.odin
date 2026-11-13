package stretch

import "core:math"
import "core:mem"

import "fire:core"
import "fire:dsp"

// How `warp` makes a sound longer or shorter (to follow a tempo).
Warp_Mode :: enum u8 {
	Beats,   // cut at its hits (or a grid), each piece at its own speed, moved to its new time: drums and loops; attacks exact
	Tones,   // a spectral stretch of the whole: pitch kept, for tonal sounds (voices, bass, pads)
	Complex, // the spectral stretch started again at each strong hit: full mixes, attacks kept crisp
	Repitch, // played faster or slower: the pitch goes with it (turntable)
}

// Where Beats cuts the sound.
Warp_Grain :: enum u8 {
	Transients, // at its hits
	Sixteenth,  // every 1/16 of its own tempo
	Eighth,
	Quarter,
}

// Settings for `warp`.
Warp_Settings :: struct {
	mode:        Warp_Mode,
	grain:       Warp_Grain, // Beats: where to cut
	beat_frames: f64,        // a beat of the sound, in its frames (for a grid grain); 0 = half a second
	fill_gaps:   bool,       // Beats, made longer: a piece's gap filled by looping its tail (else it fades to silence)
	sensitivity: f64,        // how quiet a hit still cuts (0..1; 0 = 0.5)
	transpose:   f64,        // semitones, its timing kept: Tones and Complex shift the pitch in the stretch; Beats re-pitches each piece where it falls (its hit on time). Not Repitch (pitch and speed are one there)
}

// Control thread. `input` (planar, `sample_rate`) made `ratio` times as long
// (ratio > 1: longer, slower) as `settings.mode` says; the result is
// round(ratio × frames) long, allocated with `allocator` (free each
// channel, then the slice). At ratio 1 Beats gives back its input exactly.
warp :: proc(input: [][]f32, sample_rate: f64, ratio: f64, settings := Warp_Settings{}, allocator := context.allocator) -> (output: [][]f32, err: core.Error) {
	if len(input) == 0 || ratio <= 0 || sample_rate <= 0 do return nil, .Invalid_Argument
	frames := len(input[0])
	out_frames := max(int(math.round(f64(frames) * ratio)), 1)
	aerr: mem.Allocator_Error
	output, aerr = make([][]f32, len(input), allocator)
	if aerr != nil do return nil, .Out_Of_Memory
	for &c in output {
		c, aerr = make([]f32, out_frames, allocator)
		if aerr != nil do return output, .Out_Of_Memory
	}
	if frames == 0 do return
	switch settings.mode {
	case .Repitch: warp_repitch(input, output)
	case .Beats:   warp_beats(input, output, sample_rate, ratio, settings)
	case .Tones:
		if !stretch_whole(input, output, sample_rate, settings.transpose) do warp_beats(input, output, sample_rate, ratio, settings)
	case .Complex: warp_complex(input, output, sample_rate, ratio, settings)
	}
	return
}

// Frees what `warp` returned.
warp_destroy :: proc(output: [][]f32, allocator := context.allocator) {
	for c in output do delete(c, allocator)
	delete(output, allocator)
}

// --- the modes --------------------------------------------------------------------------------

// Played at another speed: each output frame read between input frames
// (cubic, Catmull-Rom).
@(private)
warp_repitch :: proc(input, output: [][]f32) {
	for c in 0 ..< len(input) do resample_cubic(input[c], output[c])
}

// `x` read into all of `y` (as fast as their lengths say), between its
// frames (cubic, Catmull-Rom).
@(private)
resample_cubic :: proc(x, y: []f32) {
	n, m := len(x), len(y)
	if n == 0 || m == 0 do return
	step := f64(n) / f64(m)
	at :: #force_inline proc(x: []f32, i: int) -> f32 { return x[clamp(i, 0, len(x) - 1)] }
	for k in 0 ..< m {
		pos := f64(k) * step
		i := int(pos)
		t := f32(pos - f64(i))
		p0, p1, p2, p3 := at(x, i - 1), at(x, i), at(x, i + 1), at(x, i + 2)
		y[k] = p1 + 0.5 * t * (p2 - p0 + t * (2 * p0 - 5 * p1 + 4 * p2 - p3 + t * (3 * (p1 - p2) + p3 - p0)))
	}
}

// Where to cut: at the hits (always at 0), or on a grid of the sound's
// own beats.
@(private)
warp_cuts :: proc(input: [][]f32, sample_rate: f64, s: Warp_Settings, sensitivity, min_gap_ms: f64, allocator: mem.Allocator) -> []i64 {
	frames := len(input[0])
	if s.grain != .Transients {
		beat := s.beat_frames if s.beat_frames > 0 else sample_rate * 0.5
		of := [Warp_Grain]f64{.Transients = 1, .Sixteenth = 0.25, .Eighth = 0.5, .Quarter = 1}
		every := beat * of[s.grain]
		every = max(every, 64)
		cuts := make([dynamic]i64, allocator)
		for x := 0.0; x < f64(frames); x += every do append(&cuts, i64(math.round(x)))
		return cuts[:]
	}
	mono := make([]f32, frames, context.temp_allocator)
	for c in input do for v, i in c do mono[i] += v / f32(len(input))
	onsets, err := dsp.detect_onsets(mono, sample_rate, {sensitivity = sensitivity, min_gap_ms = min_gap_ms}, allocator)
	if err != .None || len(onsets) == 0 || onsets[0] != 0 {
		cuts := make([dynamic]i64, allocator)
		append(&cuts, 0)
		if err == .None do for o in onsets do if o > 0 do append(&cuts, o)
		delete(onsets, allocator)
		return cuts[:]
	}
	return onsets
}

// Beats: each piece between cuts copied whole to where its start falls
// now. Made shorter, a piece is cut off (faded out); made longer, it is
// followed by silence (faded) or its tail looped (`fill_gaps`). Nothing
// is resampled, so attacks are exact.
@(private)
warp_beats :: proc(input, output: [][]f32, sample_rate, ratio: f64, s: Warp_Settings) {
	frames, out_frames := len(input[0]), len(output[0])
	sens := s.sensitivity if s.sensitivity > 0 else 0.5
	cuts := warp_cuts(input, sample_rate, s, sens, 40, context.temp_allocator)
	fade := max(int(sample_rate * 0.004), 1) // a cut or a gap: 4 ms, no click
	// Transposed: each piece played faster or slower where it falls (its
	// start, its hit, on time; the rest as a piece made shorter or longer).
	speed := math.pow(2, s.transpose / 12)
	src := make([][]f32, len(input), context.temp_allocator)
	for k in 0 ..< len(cuts) {
		a := int(cuts[k])
		b := frames if k + 1 == len(cuts) else int(cuts[k + 1])
		if b <= a do continue
		d := int(math.round(f64(a) * ratio))
		e := out_frames if k + 1 == len(cuts) else int(math.round(f64(b) * ratio))
		e = min(e, out_frames)
		if e <= d do continue
		piece := b - a
		for c in 0 ..< len(input) do src[c] = input[c][a:b]
		if s.transpose != 0 {
			piece = max(int(math.round(f64(b - a) / speed)), 1)
			for c in 0 ..< len(input) {
				src[c] = make([]f32, piece, context.temp_allocator)
				resample_cubic(input[c][a:b], src[c])
			}
		}
		room := e - d
		n := min(piece, room)
		for c in 0 ..< len(input) do copy(output[c][d:d + n], src[c][:n])
		if room == piece do continue
		if room < piece { // cut short: fade out its end
			f := min(fade, n)
			for c in 0 ..< len(input) do for i in 0 ..< f do output[c][d + n - f + i] *= 1 - f32(i + 1) / f32(f)
			continue
		}
		// Longer: a gap after it.
		if !s.fill_gaps || piece < 4 * fade {
			f := min(fade, n)
			for c in 0 ..< len(input) do for i in 0 ..< f do output[c][d + n - f + i] *= 1 - f32(i + 1) / f32(f)
			continue
		}
		// Its tail looped (crossfaded) until the next piece.
		tail := clamp(piece / 3, 2 * fade, int(sample_rate * 0.08))
		at := d + n
		for at < e {
			for c in 0 ..< len(input) {
				src := src[c][piece - tail:piece]
				for i in 0 ..< tail {
					if at + i >= e do break
					w := f32(1)
					if i < fade do w = f32(i + 1) / f32(fade)
					output[c][at + i] = output[c][at + i] * (1 - w) + src[i] * w
				}
			}
			at += tail - fade
		}
		f := min(fade, e - d)
		for c in 0 ..< len(input) do for i in 0 ..< f do output[c][e - f + i] *= 1 - f32(i + 1) / f32(f)
	}
}

// Tones: the whole stretched in one go (120 ms blocks every 30 ms). False
// if it is too short for that.
@(private)
stretch_whole :: proc(input, output: [][]f32, sample_rate: f64, transpose := 0.0) -> bool {
	s: Stretch
	if stretch_preset_default(&s, len(input), f32(sample_rate), allocator = context.temp_allocator) != .None do return false
	defer stretch_destroy(&s)
	if transpose != 0 do stretch_set_transpose_semitones(&s, f32(transpose))
	return stretch_exact(&s, input, len(input[0]), output, len(output[0]))
}

// Complex: cut at the strong hits only, each piece stretched on its own
// (so every hit starts a fresh stretch: crisp, on time), pieces too short
// to stretch copied as Beats does; a short crossfade where they meet.
@(private)
warp_complex :: proc(input, output: [][]f32, sample_rate, ratio: f64, s: Warp_Settings) {
	frames, out_frames := len(input[0]), len(output[0])
	sens := s.sensitivity if s.sensitivity > 0 else 0.5
	strong := s
	strong.grain = .Transients
	cuts := warp_cuts(input, sample_rate, strong, sens * 0.6, 180, context.temp_allocator)
	st: Stretch
	ok := stretch_preset_default(&st, len(input), f32(sample_rate), allocator = context.temp_allocator) == .None
	defer if ok do stretch_destroy(&st)
	xf := max(int(sample_rate * 0.003), 1)
	piece_out := make([][]f32, len(input), context.temp_allocator)
	piece_in := make([][]f32, len(input), context.temp_allocator)
	for k in 0 ..< len(cuts) {
		a := int(cuts[k])
		b := frames if k + 1 == len(cuts) else int(cuts[k + 1])
		d := int(math.round(f64(a) * ratio))
		e := out_frames if k + 1 == len(cuts) else min(int(math.round(f64(b) * ratio)), out_frames)
		if b <= a || e <= d do continue
		for c in 0 ..< len(input) {
			piece_in[c] = input[c][a:b]
			piece_out[c] = make([]f32, e - d, context.temp_allocator)
		}
		done := false
		if ok {
			stretch_reset(&st)
			if s.transpose != 0 do stretch_set_transpose_semitones(&st, f32(s.transpose))
			done = stretch_exact(&st, piece_in, b - a, piece_out, e - d)
		}
		if !done { // too short to stretch: as Beats
			one := Warp_Settings{mode = .Beats, grain = .Quarter, beat_frames = f64(b - a), fill_gaps = s.fill_gaps, transpose = s.transpose}
			warp_beats(piece_in, piece_out, sample_rate, f64(e - d) / f64(b - a), one)
		}
		// Into place: a short crossfade from what is there (the last piece's end).
		for c in 0 ..< len(input) {
			for i in 0 ..< e - d {
				v := piece_out[c][i]
				if k > 0 && i < xf {
					w := f32(i + 1) / f32(xf)
					output[c][d + i] = output[c][d + i] * (1 - w) + v * w
				} else {
					output[c][d + i] = v
				}
			}
		}
	}
}
