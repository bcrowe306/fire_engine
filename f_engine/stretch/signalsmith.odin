package stretch

// Ported from Signalsmith Stretch 1.4.0 (`signalsmith-stretch.h`, by Geraint
// Luff). Original: Copyright (c) 2022 Geraint Luff / Signalsmith Audio Ltd.,
// MIT licence:
//
//   Permission is hereby granted, free of charge, to any person obtaining a
//   copy of this software and associated documentation files (the
//   "Software"), to deal in the Software without restriction, including
//   without limitation the rights to use, copy, modify, merge, publish,
//   distribute, sublicense, and/or sell copies of the Software, and to permit
//   persons to whom the Software is furnished to do so, subject to the
//   following conditions: The above copyright notice and this permission
//   notice shall be included in all copies or substantial portions of the
//   Software. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND.
//
// The structure, names and order of operations follow the original closely,
// so the two can be compared block by block.

import "core:math"
import "core:mem"

import "fire:core"
import "fire:dsp"

// Below this energy the input counts as silence.
@(private)
NOISE_FLOOR :: f32(1e-15)
// Time-stretch ratio beyond which phases are randomised.
@(private)
MAX_CLEAN_STRETCH :: f32(2)
// The main prediction is split into this many steps (it is the heaviest part).
@(private)
SPLIT_MAIN_PREDICTION :: 8
@(private)
SMOOTH_ENERGY_STEPS :: 3

// A frequency map for `stretch_set_freq_map`: input frequency to output
// frequency, both as fractions of the sample rate. Must increase
// monotonically. Called on the audio thread.
Freq_Map :: proc "contextless" (freq: f32, user: rawptr) -> f32

// A time-stretcher and pitch-shifter: Signalsmith Stretch, in Odin.
// Configure with `stretch_preset_default` (or `_cheaper`, or
// `stretch_configure`); free with `stretch_destroy`. Everything after
// configuring is realtime-safe and allocation-free. One thread at a time.
// Fields are internal.
Stretch :: struct {
	allocator:         mem.Allocator,
	split_computation: bool,
	block:             Block_Process,
	silence_counter:   int,
	silence_first:     bool,
	freq_multiplier:   f32,
	freq_tonality_limit: f32,
	freq_map:          Freq_Map,
	freq_map_user:     rawptr,
	formant_compensation: bool,
	formant_multiplier:   f32,
	inv_formant_multiplier: f32,
	stft:              dsp.Stft,
	stashed_input:     dsp.Stft_Input,
	stashed_output:    dsp.Stft_Output,
	tmp_process:       []f32, // block + interval
	tmp_pre_roll:      []f32, // output latency × channels
	channels:          int,
	bands:             int,
	prev_input_offset: int,
	did_seek:          bool,
	seek_time_factor:  f32,
	channel_bands:     []Band,
	rotations:         []complex64, // per band: its phase advance over one interval
	peaks:             []Peak,
	peak_count:        int,
	energy:            []f32,
	smoothed_energy:   []f32,
	output_map:        []Pitch_Map_Point,
	predictions:       []Prediction,
	rng:               Minstd_Rand,
	process_spectrum_steps: int,
	smooth_energy_state: f32,
	freq_estimate_weighted: f32,
	freq_estimate_weight: f32,
	freq_estimate:     f32,
	formant_metric:    []f32,
	formant_base_freq: f32,
}

@(private)
Block_Process :: struct {
	samples_since_last: int,
	steps:              int,
	step:               int,
	new_spectrum:       bool,
	reanalyse_prev:     bool,
	mapped_frequencies: bool,
	process_formants:   bool,
	time_factor:        f32,
}

@(private)
Band :: struct {
	input, prev_input, output: complex64,
	input_energy:              f32,
}

@(private)
Peak :: struct {
	input, output: f32,
}

@(private)
Pitch_Map_Point :: struct {
	input_bin, freq_grad: f32,
}

@(private)
Prediction :: struct {
	energy: f32,
	input:  complex64,
}

// libc++'s std::minstd_rand (its std::default_random_engine), which the
// reference recordings were made with, so randomised stretches match them.
@(private)
Minstd_Rand :: struct {
	x: u64,
}

// --- setup -------------------------------------------------------------------------------------

// Control thread. Configures for `channels` channels at `sample_rate` with
// the default preset: 120 ms blocks every 30 ms. Split computation spreads
// each block's work over the interval, for one interval more output latency.
stretch_preset_default :: proc(s: ^Stretch, channels: int, sample_rate: f32, split := false, allocator := context.allocator) -> core.Error {
	return stretch_configure(s, channels, int(sample_rate * 0.12), int(sample_rate * 0.03), split, allocator)
}

// Control thread. Configures the cheaper preset: 100 ms blocks every 40 ms,
// split computation on by default.
stretch_preset_cheaper :: proc(s: ^Stretch, channels: int, sample_rate: f32, split := true, allocator := context.allocator) -> core.Error {
	return stretch_configure(s, channels, int(sample_rate * 0.1), int(sample_rate * 0.04), split, allocator)
}

// Control thread. Configures with explicit block and interval lengths (in
// samples). Frees any previous configuration. Seeded as the reference
// recordings were (the seed only matters for stretches beyond 2×).
stretch_configure :: proc(s: ^Stretch, channels, block_samples, interval_samples: int, split := false, allocator := context.allocator) -> core.Error {
	if s.allocator.procedure != nil do stretch_destroy(s)
	if channels < 1 || block_samples < 2 || interval_samples < 1 do return .Invalid_Argument
	s^ = {
		allocator = allocator, split_computation = split, silence_first = true,
		freq_multiplier = 1, freq_tonality_limit = 0.5, formant_multiplier = 1, inv_formant_multiplier = 1,
		channels = channels, prev_input_offset = -1, seek_time_factor = 1,
	}
	s.rng = minstd_seed(0x5eed)
	dsp.stft_init(&s.stft, {in_channels = channels, out_channels = channels, block = block_samples, extra_history = interval_samples + 1, spectrum = .Half_Bin}, allocator) or_return
	dsp.stft_set_interval(&s.stft, interval_samples, .Kaiser)
	dsp.stft_reset(&s.stft, 0.1)
	s.stashed_input = dsp.stft_input_make(&s.stft, allocator)
	s.stashed_output = dsp.stft_output_make(&s.stft, allocator)
	dsp.stft_input_copy(&s.stashed_input, &s.stft.input)
	dsp.stft_output_copy(&s.stashed_output, &s.stft.output)

	s.bands = dsp.stft_bands(&s.stft)
	s.block = {samples_since_last = max(int)}
	ae: mem.Allocator_Error
	e1, e2, e3, e4, e5, e6, e7, e8, e9, e10: mem.Allocator_Error
	s.channel_bands, e1 = make([]Band, s.bands * channels, allocator)
	s.peaks, e2 = make([]Peak, s.bands / 2 + 1, allocator) // peaks are runs of bands: at most one per two
	s.energy, e3 = make([]f32, s.bands, allocator)
	s.smoothed_energy, e4 = make([]f32, s.bands, allocator)
	s.output_map, e5 = make([]Pitch_Map_Point, s.bands, allocator)
	s.predictions, e6 = make([]Prediction, channels * s.bands, allocator)
	s.formant_metric, e7 = make([]f32, s.bands + 2, allocator)
	s.tmp_process, e8 = make([]f32, block_samples + interval_samples, allocator)
	s.tmp_pre_roll, e9 = make([]f32, stretch_output_latency(s) * channels, allocator)
	s.rotations, e10 = make([]complex64, s.bands, allocator)
	for e in ([]mem.Allocator_Error{e1, e2, e3, e4, e5, e6, e7, e8, e9, e10}) do if e != nil do ae = e
	if ae != nil || s.stashed_input.buffer == nil || s.stashed_output.buffer == nil {
		stretch_destroy(s)
		return .Out_Of_Memory
	}
	// As Signalsmith steps them each block, rot ← rot × rot_step from band 0,
	// so the values are the same.
	rot := polar(band_to_freq(s, 0) * f32(interval_samples) * f32(2 * math.PI))
	rot_step := polar((band_to_freq(s, 1) - band_to_freq(s, 0)) * f32(interval_samples) * f32(2 * math.PI))
	for &r in s.rotations {
		r = rot
		rot = mul(rot, rot_step)
	}
	return .None
}

// Control thread. Frees what configuring allocated.
stretch_destroy :: proc(s: ^Stretch) {
	a := s.allocator
	if a.procedure == nil do return
	dsp.stft_destroy(&s.stft, a)
	dsp.stft_input_free(&s.stashed_input, a)
	dsp.stft_output_free(&s.stashed_output, a)
	delete(s.channel_bands, a)
	delete(s.rotations, a)
	delete(s.peaks, a)
	delete(s.energy, a)
	delete(s.smoothed_energy, a)
	delete(s.output_map, a)
	delete(s.predictions, a)
	delete(s.formant_metric, a)
	delete(s.tmp_process, a)
	delete(s.tmp_pre_roll, a)
	s^ = {}
}

// [rt] Clears all audio state (not the settings).
stretch_reset :: proc "contextless" (s: ^Stretch) {
	dsp.stft_reset(&s.stft, 0.1)
	dsp.stft_input_copy(&s.stashed_input, &s.stft.input)
	dsp.stft_output_copy(&s.stashed_output, &s.stft.output)
	s.prev_input_offset = -1
	for &b in s.channel_bands do b = {}
	s.silence_counter = 0
	s.did_seek = false
	s.block = {samples_since_last = max(int)}
	s.freq_estimate_weighted, s.freq_estimate_weight = 0, 0
}

// [rt] Input frames ahead of the position being processed.
stretch_input_latency :: proc "contextless" (s: ^Stretch) -> int {
	return dsp.stft_analysis_latency(&s.stft)
}

// [rt] Output frames by which output trails the position being processed.
stretch_output_latency :: proc "contextless" (s: ^Stretch) -> int {
	return dsp.stft_synthesis_latency(&s.stft) + (dsp.stft_interval(&s.stft) if s.split_computation else 0)
}

// [rt] Block length in samples.
stretch_block_samples :: proc "contextless" (s: ^Stretch) -> int { return dsp.stft_block(&s.stft) }
// [rt] Interval between blocks in samples.
stretch_interval_samples :: proc "contextless" (s: ^Stretch) -> int { return dsp.stft_interval(&s.stft) }

// [rt] Transposes by `multiplier` (2 = an octave up). Above `tonality_limit`
// (a fraction of the sample rate; 0 = none) frequencies are shifted rather
// than scaled, which keeps more of the timbre. Replaces any frequency map.
stretch_set_transpose_factor :: proc "contextless" (s: ^Stretch, multiplier: f32, tonality_limit: f32 = 0) {
	s.freq_multiplier = multiplier
	s.freq_tonality_limit = tonality_limit / math.sqrt(multiplier) if tonality_limit > 0 else 1 // between the input's and output's limits
	s.freq_map = nil
}

// [rt] Transposes by `semitones` (see `stretch_set_transpose_factor`).
stretch_set_transpose_semitones :: proc "contextless" (s: ^Stretch, semitones: f32, tonality_limit: f32 = 0) {
	stretch_set_transpose_factor(s, math.pow(2, semitones / 12), tonality_limit)
}

// [rt] Uses a custom frequency map instead of a transpose factor.
stretch_set_freq_map :: proc "contextless" (s: ^Stretch, freq_map: Freq_Map, user: rawptr = nil) {
	s.freq_map, s.freq_map_user = freq_map, user
}

// [rt] Scales the spectral envelope (formants) by `multiplier`. With
// `compensate_pitch`, formants also undo the transpose, so a pitch shift
// keeps the voice's character.
stretch_set_formant_factor :: proc "contextless" (s: ^Stretch, multiplier: f32, compensate_pitch := false) {
	s.formant_multiplier = multiplier
	s.inv_formant_multiplier = 1 / multiplier
	s.formant_compensation = compensate_pitch
}

// [rt] As `stretch_set_formant_factor`, in semitones.
stretch_set_formant_semitones :: proc "contextless" (s: ^Stretch, semitones: f32, compensate_pitch := false) {
	stretch_set_formant_factor(s, math.pow(2, semitones / 12), compensate_pitch)
}

// [rt] A rough fundamental frequency for formant analysis, as a fraction of
// the sample rate (like `Freq_Map`'s); 0 = estimate it from the input.
stretch_set_formant_base :: proc "contextless" (s: ^Stretch, base_freq: f32 = 0) {
	s.formant_base_freq = base_freq
}

// [rt] How much input `stretch_seek` should ideally be given.
stretch_seek_length :: proc "contextless" (s: ^Stretch) -> int {
	return stretch_block_samples(s) + stretch_interval_samples(s)
}

// [rt] How much input `stretch_output_seek` should be given at `playback_rate`.
stretch_output_seek_length :: proc "contextless" (s: ^Stretch, playback_rate: f32) -> int {
	return int(f32(stretch_input_latency(s)) + playback_rate * f32(stretch_output_latency(s)))
}

// --- random numbers (libc++'s, see Minstd_Rand) -------------------------------------------------

@(private)
minstd_seed :: proc "contextless" (seed: u64) -> Minstd_Rand {
	x := seed % 2147483647
	return {x = 1 if x == 0 else x}
}

// libc++: uniform_real_distribution<float>(a, b) with generate_canonical<float, 24>:
// one draw (log2 of the engine's range is 30 ≥ 24 bits), divided by the range as a float.
@(private)
uniform :: proc "contextless" (r: ^Minstd_Rand, a, b: f32) -> f32 {
	r.x = r.x * 48271 % 2147483647
	range := f32(2147483646 - 1) + 1
	canonical := f32(r.x - 1) / range
	return (b - a) * canonical + a
}
