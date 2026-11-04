package testkit

import "core:math"

// The test signals for time-stretch reference cases.
Stretch_Signal :: enum i32 {
	Sweep,  // a log sine sweep, 50 Hz to 12 kHz, at −6 dBFS
	Drums,  // synthetic kick, snare and hi-hats at 120 BPM
	Voice,  // a gliding pulse train through three formant resonators (an "ah")
}

// How a reference case drives the stretcher.
Stretch_Mode :: enum i32 {
	Stream,       // output_seek at the start, then process in chunks
	Stream_Flush, // as Stream, then flush the last `flush_frames`
	Stream_Seek,  // as Stream, seeking to `seek_to_in` once `seek_at_out` frames are out
	Exact,        // the whole input to the whole output in one exact() call
}

// One reference case for the time-stretcher: its input, settings and how
// it is driven. The C++ Signalsmith Stretch rendered these into the
// recordings in tests/golden/stretch (before it was removed: see commit
// 33600b9); the pure-Odin port renders the same cases and is compared with
// them.
Stretch_Case :: struct {
	name:               cstring,
	signal:             Stretch_Signal,
	sample_rate:        f32,
	channels:           i32,
	in_frames:          i32,
	out_frames:         i32,          // total output, including any flush
	cheaper:            b32,          // presetCheaper instead of presetDefault
	split:              b32,          // split computation
	rate:               f32,          // input frames per output frame
	transpose:          f32,          // frequency factor; 1 = none
	tonality_limit:     f32,          // as a fraction of the sample rate; 0 = none
	formant:            f32,          // formant factor; 1 = none
	formant_compensate: b32,
	formant_base:       f32,          // Hz; 0 = detect
	freq_map:           i32,          // 0 = none, 1 = `stretch_case_freq_map`
	mode:               Stretch_Mode,
	flush_frames:       i32,
	seek_at_out:        i32,
	seek_to_in:         i32,
	chunks:             [4]i32,       // output frames per process call, repeated; zero entries end the list
	// The largest spectral distance (`spectral_distance`, dB) allowed from the
	// recording: 1.5 × the C++'s own largest distance on Linux, on Windows,
	// or with its input nudged by −100 dBFS, and at least 0.05 dB
	// (tests/golden/stretch/README.md).
	tolerance:          f32,
}

// The custom frequency map case 1 uses (frequencies as fractions of the
// sample rate): unchanged below 0.02, then spread out by 1.25.
stretch_case_freq_map :: proc "contextless" (f: f32) -> f32 {
	return f if f < 0.02 else 0.02 + (f - 0.02) * 1.25
}

// The reference cases. Ratios above 2 (and below 0.5) make Signalsmith
// Stretch randomise phases with the C++ standard library's generator, so
// those recordings are only reproducible with the same library (they were
// made with macOS's libc++).
@(rodata)
stretch_reference_cases := [?]Stretch_Case {
	// Time-stretch at the default preset, across ratios.
	{name = "sweep_rate_1",      signal = .Sweep, sample_rate = 48_000, channels = 1, in_frames = 48_000, out_frames = 48_000, rate = 1,    transpose = 1, formant = 1, tolerance = 0.05, chunks = {512, 0, 0, 0}},
	{name = "sweep_rate_0p8",    signal = .Sweep, sample_rate = 48_000, channels = 1, in_frames = 48_000, out_frames = 60_000, rate = 0.8,  transpose = 1, formant = 1, tolerance = 2.13, chunks = {512, 0, 0, 0}},
	{name = "sweep_rate_1p25",   signal = .Sweep, sample_rate = 48_000, channels = 1, in_frames = 48_000, out_frames = 38_400, rate = 1.25, transpose = 1, formant = 1, tolerance = 2.06, chunks = {512, 0, 0, 0}},
	{name = "sweep_rate_0p5",    signal = .Sweep, sample_rate = 48_000, channels = 1, in_frames = 48_000, out_frames = 96_000, rate = 0.5,  transpose = 1, formant = 1, tolerance = 2.28, chunks = {512, 0, 0, 0}},
	{name = "sweep_rate_2",      signal = .Sweep, sample_rate = 48_000, channels = 1, in_frames = 48_000, out_frames = 24_000, rate = 2,    transpose = 1, formant = 1, tolerance = 1.04, chunks = {512, 0, 0, 0}},
	{name = "drums_rate_0p75",   signal = .Drums, sample_rate = 48_000, channels = 1, in_frames = 48_000, out_frames = 64_000, rate = 0.75, transpose = 1, formant = 1, tolerance = 0.05, chunks = {512, 0, 0, 0}},
	{name = "drums_rate_1p5",    signal = .Drums, sample_rate = 48_000, channels = 1, in_frames = 48_000, out_frames = 32_000, rate = 1.5,  transpose = 1, formant = 1, tolerance = 0.05, chunks = {512, 0, 0, 0}},
	// Beyond 2× either way: randomised phases.
	{name = "drums_rate_3_random", signal = .Drums, sample_rate = 48_000, channels = 1, in_frames = 48_000, out_frames = 16_000, rate = 3,  transpose = 1, formant = 1, tolerance = 0.05, chunks = {512, 0, 0, 0}},
	{name = "voice_rate_0p4_random", signal = .Voice, sample_rate = 48_000, channels = 1, in_frames = 48_000, out_frames = 120_000, rate = 0.4, transpose = 1, formant = 1, tolerance = 9.3, chunks = {512, 0, 0, 0}},
	// Pitch.
	{name = "voice_up_7",        signal = .Voice, sample_rate = 48_000, channels = 1, in_frames = 48_000, out_frames = 48_000, rate = 1, transpose = 1.4983070768766815, formant = 1, tolerance = 2.56, chunks = {512, 0, 0, 0}},
	{name = "voice_down_12",     signal = .Voice, sample_rate = 48_000, channels = 1, in_frames = 48_000, out_frames = 48_000, rate = 1, transpose = 0.5, formant = 1, tolerance = 5.02, chunks = {512, 0, 0, 0}},
	{name = "voice_up_7_tonality", signal = .Voice, sample_rate = 48_000, channels = 1, in_frames = 48_000, out_frames = 48_000, rate = 1, transpose = 1.4983070768766815, tonality_limit = 0.08, formant = 1, tolerance = 0.05, chunks = {512, 0, 0, 0}},
	{name = "drums_up_3_slower", signal = .Drums, sample_rate = 48_000, channels = 1, in_frames = 48_000, out_frames = 57_600, rate = 1 / 1.2, transpose = 1.189207115002721, formant = 1, tolerance = 0.14, chunks = {512, 0, 0, 0}},
	// Formants.
	{name = "voice_formant_1p25_compensated", signal = .Voice, sample_rate = 48_000, channels = 1, in_frames = 48_000, out_frames = 48_000, rate = 1, transpose = 1, formant = 1.25, formant_compensate = true, tolerance = 0.05, chunks = {512, 0, 0, 0}},
	{name = "voice_up_7_formant_kept", signal = .Voice, sample_rate = 48_000, channels = 1, in_frames = 48_000, out_frames = 48_000, rate = 1, transpose = 1.4983070768766815, formant = 1 / 1.4983070768766815, formant_compensate = true, tolerance = 0.97, chunks = {512, 0, 0, 0}},
	{name = "voice_formant_base_120", signal = .Voice, sample_rate = 48_000, channels = 1, in_frames = 48_000, out_frames = 48_000, rate = 1, transpose = 1.25, formant = 0.8, formant_compensate = true, formant_base = 120, tolerance = 1.88, chunks = {512, 0, 0, 0}},
	// A custom frequency map.
	{name = "voice_freq_map",    signal = .Voice, sample_rate = 48_000, channels = 1, in_frames = 48_000, out_frames = 48_000, rate = 1, transpose = 1, formant = 1, freq_map = 1, tolerance = 2.72, chunks = {512, 0, 0, 0}},
	// Presets and split computation.
	{name = "drums_cheaper",     signal = .Drums, sample_rate = 48_000, channels = 1, in_frames = 48_000, out_frames = 48_000, cheaper = true, split = true, rate = 1, transpose = 1, formant = 1, tolerance = 0.05, chunks = {512, 0, 0, 0}},
	{name = "sweep_split",       signal = .Sweep, sample_rate = 48_000, channels = 1, in_frames = 48_000, out_frames = 48_000, split = true, rate = 1, transpose = 1, formant = 1, tolerance = 0.05, chunks = {512, 0, 0, 0}},
	{name = "drums_split_0p8",   signal = .Drums, sample_rate = 48_000, channels = 1, in_frames = 48_000, out_frames = 60_000, split = true, rate = 0.8, transpose = 1, formant = 1, tolerance = 0.05, chunks = {512, 0, 0, 0}},
	// Other shapes: stereo, 44.1 kHz, odd chunk sizes.
	{name = "drums_stereo_1p25", signal = .Drums, sample_rate = 48_000, channels = 2, in_frames = 48_000, out_frames = 38_400, rate = 1.25, transpose = 1, formant = 1, tolerance = 0.05, chunks = {512, 0, 0, 0}},
	{name = "voice_44k_0p9",     signal = .Voice, sample_rate = 44_100, channels = 1, in_frames = 44_100, out_frames = 49_000, rate = 0.9, transpose = 1, formant = 1, tolerance = 2.08, chunks = {512, 0, 0, 0}},
	{name = "sweep_odd_chunks",  signal = .Sweep, sample_rate = 48_000, channels = 1, in_frames = 48_000, out_frames = 60_000, rate = 0.8, transpose = 1, formant = 1, tolerance = 2.61, chunks = {1, 333, 4096, 77}},
	// Flush, mid-stream seek, and whole-buffer exact().
	{name = "sweep_flush",       signal = .Sweep, sample_rate = 48_000, channels = 1, in_frames = 48_000, out_frames = 52_000, rate = 1, transpose = 1, formant = 1, mode = .Stream_Flush, flush_frames = 4_000, tolerance = 0.05, chunks = {512, 0, 0, 0}},
	{name = "drums_seek",        signal = .Drums, sample_rate = 48_000, channels = 1, in_frames = 48_000, out_frames = 48_000, rate = 1, transpose = 1, formant = 1, mode = .Stream_Seek, seek_at_out = 24_000, seek_to_in = 6_000, tolerance = 0.05, chunks = {512, 0, 0, 0}},
	{name = "voice_exact_1p5",   signal = .Voice, sample_rate = 48_000, channels = 1, in_frames = 48_000, out_frames = 72_000, rate = 48_000.0 / 72_000, transpose = 1, formant = 1, mode = .Exact, tolerance = 3.51, chunks = {512, 0, 0, 0}},
}

// The input for a reference case: `c.channels` channels of `c.in_frames`
// frames (channel 1 of a stereo case is the signal delayed by 7 ms at 70%).
// Deterministic. Allocates with `allocator`.
stretch_case_input :: proc(c: Stretch_Case, allocator := context.allocator) -> [][]f32 {
	sr := f64(c.sample_rate)
	n := int(c.in_frames)
	out := make([][]f32, c.channels, allocator)
	for &ch in out do ch = make([]f32, n, allocator)
	x := out[0]
	switch c.signal {
	case .Sweep:
		log_sweep(x, sr, 50, 12_000, 0.5)
	case .Drums:
		rng := Rng{state = 0xD2}
		beat := int(sr * 0.5)
		for i in 0 ..< n {
			t := f64(i % beat) / sr                     // since the beat
			h := f64(i % (beat / 2)) / sr               // since the half beat
			kick := 0.7 * math.exp(-t * 14) * math.sin(math.TAU * (45 * t + 60 * (1 - math.exp(-t * 30)) / 30))
			hat := 0.15 * math.exp(-h * 90) * (rng_next_f64(&rng) * 2 - 1)
			snare: f64
			if (i / beat) % 2 == 1 do snare = math.exp(-t * 25) * (0.3 * (rng_next_f64(&rng) * 2 - 1) + 0.2 * math.sin(math.TAU * 180 * t))
			x[i] = f32(kick + hat + snare)
		}
	case .Voice:
		// A sawtooth gliding 110 → 165 Hz, through resonators at 700, 1200
		// and 2600 Hz (an "ah"), each a two-pole filter.
		formants := [3]f64{700, 1200, 2600}
		gains := [3]f64{1, 0.6, 0.25}
		state: [3][2]f64
		phase := 0.0
		for i in 0 ..< n {
			f0 := 110 + 55 * f64(i) / f64(n)
			phase += f0 / sr
			phase -= math.floor(phase)
			src := 2 * phase - 1
			y := 0.0
			for f, k in formants {
				r := math.exp(-math.PI * 90 / sr) // 90 Hz bandwidth
				a1 := 2 * r * math.cos(math.TAU * f / sr)
				v := src * (1 - r) + a1 * state[k][0] - r * r * state[k][1]
				state[k][1], state[k][0] = state[k][0], v
				y += v * gains[k]
			}
			x[i] = f32(0.4 * y)
		}
	}
	if c.channels > 1 {
		delay := int(sr * 0.007)
		for i in 0 ..< n do out[1][i] = 0.7 * x[i - delay] if i >= delay else 0
	}
	return out
}
