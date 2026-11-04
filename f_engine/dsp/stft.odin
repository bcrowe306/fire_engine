package dsp

// Ported from Signalsmith Linear 0.6.4 (`stft.h`), as part of the pure-Odin
// port of Signalsmith Stretch. Original: Copyright (c) 2025 Signalsmith
// Audio, MIT licence:
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
// The full licence is in LICENSE-signalsmith-linear.txt, next to this file.

import "core:math"
import "core:mem"

import "fire:core"

// How an `Stft` lays out its spectrum.
Stft_Spectrum :: enum u8 {
	Packed,   // fft_size/2 bins; bin 0 holds DC (real) and Nyquist (imaginary)
	Half_Bin, // fft_size/2 bins at k + ½ (see `Real_Fft`); suits spectral processing
	Unpacked, // fft_size/2 + 1 bins, Nyquist in its own bin
}

// The window shape `stft_set_interval` builds.
Stft_Window :: enum u8 {
	Keep,   // leave the windows as they are
	Acg,    // approximate confined Gaussian
	Kaiser, // Kaiser, with a bandwidth chosen for the interval
}

// What output is divided by, so that analysis then synthesis gives back the
// input whatever the windows and block positions.
Stft_Normalisation :: enum u8 {
	Round_Trip, // analysis × synthesis windows (the default)
	Synthesis,  // the synthesis window only
	None,       // only the FFT's gain
}

// A short-time Fourier transform for spectral processing: write input,
// analyse a block into spectra, change the spectra, synthesise them back,
// read output. It normalises itself: output is divided by the sum of the
// window products of the blocks that went into it, so analysis then
// synthesis at a steady hop (not only the default interval) reconstructs
// the input exactly, `stft_latency` minus one hop later when output is read
// straight after synthesising. (With uneven hops the gain varies, exactly
// as in Signalsmith Linear.)
//
// Analysis and synthesis can also run in steps (`stft_analyse_steps`), to
// spread their cost. Planar f32; nothing allocates after `stft_init`.
// Fields are internal.
Stft :: struct {
	fft:                Real_Fft,
	kind:               Stft_Spectrum,
	split:              bool,
	analysis_channels:  int,
	synthesis_channels: int,
	input_length:       int,
	block:              int,
	fft_size:           int,
	bins:               int,
	interval:           int,
	analysis_window:    []f32,
	synthesis_window:   []f32,
	analysis_offset:    int,
	synthesis_offset:   int,
	spectra:            []complex64,
	time:               []f32,
	input:              Stft_Input,
	output:             Stft_Output,
	since_analysis:     int,
	since_synthesis:    int,
	norm:               Stft_Normalisation,
}

// An STFT's input history, which can be saved and swapped (as Signalsmith
// Stretch does to re-analyse). Make one with `stft_input_make`. Fields are
// internal.
Stft_Input :: struct {
	pos:    int,
	buffer: []f32,
}

// An STFT's pending output, which can be saved and swapped. Make one with
// `stft_output_make`. Fields are internal.
Stft_Output :: struct {
	pos:             int,
	buffer:          []f32,
	window_products: []f32,
}

// Settings for `stft_init`.
Stft_Settings :: struct {
	in_channels:   int,           // channels analysed
	out_channels:  int,           // channels synthesised
	block:         int,           // block (window) length in samples
	extra_history: int,           // input kept beyond one block, for analysing in the past
	interval:      int,           // default hop; 0 = block/4
	asymmetry:     f64,           // window warp, −1..1; 0 = symmetric
	fft_min_size:  int,           // 0 = block
	spectrum:      Stft_Spectrum,
	split:         bool,          // allow analysing and synthesising in more, smaller steps
}

@(private)
ALMOST_ZERO :: f32(1e-30)

// Control thread. Allocates and configures an STFT (with an ACG window at
// the default interval, and round-trip normalisation), then resets it. Free
// with `stft_destroy`.
stft_init :: proc(s: ^Stft, settings: Stft_Settings, allocator := context.allocator) -> core.Error {
	st := settings
	s^ = {kind = st.spectrum, split = st.split, analysis_channels = st.in_channels, synthesis_channels = st.out_channels, block = st.block}
	if st.block < 2 || st.in_channels < 0 || st.out_channels < 0 do return .Invalid_Argument
	min_size := st.fft_min_size if st.fft_min_size > 0 else st.block
	s.fft_size = fft_fast_size_above((min_size + 1) / 2) * 2
	real_fft_init(&s.fft, s.fft_size, st.spectrum == .Half_Bin, st.split, allocator) or_return
	s.bins = s.fft_size / 2 + (1 if st.spectrum == .Unpacked else 0)
	s.input_length = s.block + st.extra_history
	ae: mem.Allocator_Error
	alloc :: proc(n: int, a: mem.Allocator, ae: ^mem.Allocator_Error) -> []f32 {
		b, e := make([]f32, n, a)
		if e != nil do ae^ = e
		return b
	}
	s.input.buffer = alloc(s.input_length * st.in_channels, allocator, &ae)
	s.output.buffer = alloc(s.block * st.out_channels, allocator, &ae)
	s.output.window_products = alloc(s.block, allocator, &ae)
	s.time = alloc(max(s.fft_size, s.block), allocator, &ae)
	s.analysis_window = alloc(s.block, allocator, &ae)
	s.synthesis_window = alloc(s.block, allocator, &ae)
	sae: mem.Allocator_Error
	s.spectra, sae = make([]complex64, s.bins * max(st.in_channels, st.out_channels), allocator)
	if ae != nil || sae != nil {
		stft_destroy(s, allocator)
		return .Out_Of_Memory
	}
	stft_set_interval(s, st.interval if st.interval > 0 else st.block / 4, .Acg, st.asymmetry)
	stft_reset(s)
	return .None
}

// Control thread. Frees what `stft_init` allocated.
stft_destroy :: proc(s: ^Stft, allocator := context.allocator) {
	real_fft_destroy(&s.fft, allocator)
	delete(s.input.buffer, allocator)
	delete(s.output.buffer, allocator)
	delete(s.output.window_products, allocator)
	delete(s.time, allocator)
	delete(s.analysis_window, allocator)
	delete(s.synthesis_window, allocator)
	delete(s.spectra, allocator)
	s^ = {}
}

// Control thread. A spare input state the same size as `s`'s, for saving
// and swapping (see `stft_input_copy`, `stft_swap_input`).
stft_input_make :: proc(s: ^Stft, allocator := context.allocator) -> Stft_Input {
	return {pos = s.input.pos, buffer = make([]f32, len(s.input.buffer), allocator)}
}

// Control thread. A spare output state the same size as `s`'s.
stft_output_make :: proc(s: ^Stft, allocator := context.allocator) -> Stft_Output {
	return {pos = s.output.pos, buffer = make([]f32, len(s.output.buffer), allocator), window_products = make([]f32, len(s.output.window_products), allocator)}
}

// Control thread. Frees a spare state from `stft_input_make`.
stft_input_free :: proc(state: ^Stft_Input, allocator := context.allocator) {
	delete(state.buffer, allocator)
	state^ = {}
}

// Control thread. Frees a spare state from `stft_output_make`.
stft_output_free :: proc(state: ^Stft_Output, allocator := context.allocator) {
	delete(state.buffer, allocator)
	delete(state.window_products, allocator)
	state^ = {}
}

// [rt] Copies input state `src` into `dst` (same sizes).
stft_input_copy :: proc "contextless" (dst, src: ^Stft_Input) {
	dst.pos = src.pos
	copy(dst.buffer, src.buffer)
}

// [rt] Copies output state `src` into `dst` (same sizes).
stft_output_copy :: proc "contextless" (dst, src: ^Stft_Output) {
	dst.pos = src.pos
	copy(dst.buffer, src.buffer)
	copy(dst.window_products, src.window_products)
}

// [rt] Exchanges the STFT's input state with `other`.
stft_swap_input :: proc "contextless" (s: ^Stft, other: ^Stft_Input) {
	s.input, other^ = other^, s.input
}

// [rt] Exchanges the STFT's output state with `other`.
stft_swap_output :: proc "contextless" (s: ^Stft, other: ^Stft_Output) {
	s.output, other^ = other^, s.output
}

// [rt] Block length in samples.
stft_block :: proc "contextless" (s: ^Stft) -> int { return s.block }
// [rt] FFT length in samples (≥ the block, unless `fft_min_size` was smaller).
stft_fft_size :: proc "contextless" (s: ^Stft) -> int { return s.fft_size }
// [rt] The default hop between blocks.
stft_interval :: proc "contextless" (s: ^Stft) -> int { return s.interval }
// [rt] Spectrum bins per channel.
stft_bands :: proc "contextless" (s: ^Stft) -> int { return s.bins }
// [rt] Samples from the newest input to the centre of the analysis window.
stft_analysis_latency :: proc "contextless" (s: ^Stft) -> int { return s.block - s.analysis_offset }
// [rt] Samples from the centre of the synthesis window to the output read next.
stft_synthesis_latency :: proc "contextless" (s: ^Stft) -> int { return s.synthesis_offset }
// [rt] Total latency through analysis and synthesis.
stft_latency :: proc "contextless" (s: ^Stft) -> int { return stft_analysis_latency(s) + stft_synthesis_latency(s) }
// [rt] Input written since the last analysis.
stft_samples_since_analysis :: proc "contextless" (s: ^Stft) -> int { return s.since_analysis }
// [rt] Output moved since the last synthesis.
stft_samples_since_synthesis :: proc "contextless" (s: ^Stft) -> int { return s.since_synthesis }

// [rt] A bin's frequency as a fraction of the sample rate.
stft_bin_to_freq :: proc "contextless" (s: ^Stft, bin: f32) -> f32 {
	return (bin + 0.5 if s.kind == .Half_Bin else bin) / f32(s.fft_size)
}

// [rt] The (fractional) bin of a frequency given as a fraction of the sample rate.
stft_freq_to_bin :: proc "contextless" (s: ^Stft, freq: f32) -> f32 {
	return freq * f32(s.fft_size) - 0.5 if s.kind == .Half_Bin else freq * f32(s.fft_size)
}

// [rt] Channel `channel`'s spectrum: `stft_bands` bins, read and written in
// place between analysis and synthesis.
stft_spectrum :: proc "contextless" (s: ^Stft, channel: int) -> []complex64 {
	return s.spectra[channel * s.bins:][:s.bins]
}

// [rt] The analysis window (`stft_block` samples), editable.
stft_analysis_window :: proc "contextless" (s: ^Stft) -> []f32 { return s.analysis_window }
// [rt] The synthesis window, editable.
stft_synthesis_window :: proc "contextless" (s: ^Stft) -> []f32 { return s.synthesis_window }
// [rt] Sets the index of the analysis window's centre.
stft_set_analysis_offset :: proc "contextless" (s: ^Stft, offset: int) { s.analysis_offset = offset }
// [rt] Sets the index of the synthesis window's centre.
stft_set_synthesis_offset :: proc "contextless" (s: ^Stft, offset: int) { s.synthesis_offset = offset }
// [rt] Sets how output is normalised.
stft_set_normalisation :: proc "contextless" (s: ^Stft, mode: Stft_Normalisation) { s.norm = mode }

// [rt] Clears all input and output. `product_weight` scales the initial
// window products (the output's starting normalisation).
stft_reset :: proc "contextless" (s: ^Stft, product_weight: f32 = 1) {
	s.input.pos = s.block
	s.output.pos = 0
	for &v in s.input.buffer do v = 0
	for &v in s.output.buffer do v = 0
	for &v in s.spectra do v = 0
	for &v in s.output.window_products do v = 0
	if s.norm != .None {
		add_window_product(s)
		for i := s.block - s.interval - 1; i >= 0; i -= 1 {
			s.output.window_products[i] += s.output.window_products[i + s.interval]
		}
	}
	for &v in s.output.window_products do v = v * product_weight + ALMOST_ZERO
	stft_move_output(s, s.interval) // ready for the first block at once
}

// [rt] Sets the default hop, and (unless `.Keep`) rebuilds both windows for
// it. Windows are made in f64. With no asymmetry, the windows are scaled for
// perfect reconstruction at this hop.
stft_set_interval :: proc "contextless" (s: ^Stft, interval: int, shape := Stft_Window.Keep, asymmetry: f64 = 0) {
	s.interval = interval
	if shape == .Keep do return
	bandwidth := f64(s.block) / f64(interval)
	switch shape {
	case .Keep:
	case .Acg:
		acg_fill(s.synthesis_window, bandwidth, asymmetry, false)
	case .Kaiser:
		kaiser_fill(s.synthesis_window, kaiser_bandwidth_to_beta(bandwidth, true), asymmetry, true)
	}
	s.analysis_offset = s.block / 2
	s.synthesis_offset = s.block / 2
	if s.analysis_channels == 0 {
		for &v in s.analysis_window do v = 1
	} else if asymmetry == 0 {
		force_perfect_reconstruction(s.synthesis_window, interval)
		copy(s.analysis_window, s.synthesis_window)
	} else {
		for i in 0 ..< s.block do s.analysis_window[i] = s.synthesis_window[s.block - 1 - i]
	}
	// The offsets go to each window's peak.
	for i in 0 ..< s.block {
		if s.analysis_window[i] > s.analysis_window[s.analysis_offset] do s.analysis_offset = i
		if s.synthesis_window[i] > s.synthesis_window[s.synthesis_offset] do s.synthesis_offset = i
	}
}

// [rt] Writes `samples` into channel `channel`'s input, `offset` samples
// after the current input position (which doesn't move).
stft_write_input :: proc "contextless" (s: ^Stft, channel, offset: int, samples: []f32) {
	buffer := s.input.buffer[channel * s.input_length:][:s.input_length]
	pos := (s.input.pos + offset) % s.input_length
	for v in samples {
		buffer[pos] = v
		pos += 1
		if pos == s.input_length do pos = 0
	}
}

// [rt] Moves the input position on by `samples` (optionally clearing what
// it moves over first).
stft_move_input :: proc "contextless" (s: ^Stft, samples: int, clear := false) {
	if clear {
		for c in 0 ..< s.analysis_channels {
			buffer := s.input.buffer[c * s.input_length:][:s.input_length]
			pos := s.input.pos
			for _ in 0 ..< samples {
				buffer[pos] = 0
				pos += 1
				if pos == s.input_length do pos = 0
			}
		}
	}
	s.input.pos = (s.input.pos + samples) % s.input_length
	s.since_analysis += samples
}

// [rt] Reads `len(out)` samples of channel `channel`'s output, starting
// `offset` samples ahead, normalised.
stft_read_output :: proc "contextless" (s: ^Stft, channel, offset: int, out: []f32) {
	buffer := s.output.buffer[channel * s.block:][:s.block]
	pos := (s.output.pos + offset) % s.block
	for &v in out {
		v = buffer[pos] / s.output.window_products[pos]
		pos += 1
		if pos == s.block do pos = 0
	}
}

// [rt] Adds `samples` (already normalised) into channel `channel`'s output,
// `offset` samples ahead (at most one block).
stft_add_output :: proc "contextless" (s: ^Stft, channel, offset: int, samples: []f32) {
	buffer := s.output.buffer[channel * s.block:][:s.block]
	pos := (s.output.pos + offset) % s.block
	for v in samples[:min(len(samples), s.block)] {
		buffer[pos] += v * s.output.window_products[pos]
		pos += 1
		if pos == s.block do pos = 0
	}
}

// [rt] Like `stft_add_output`, but replacing what was there.
stft_replace_output :: proc "contextless" (s: ^Stft, channel, offset: int, samples: []f32) {
	buffer := s.output.buffer[channel * s.block:][:s.block]
	pos := (s.output.pos + offset) % s.block
	for v in samples[:min(len(samples), s.block)] {
		buffer[pos] = v * s.output.window_products[pos]
		pos += 1
		if pos == s.block do pos = 0
	}
}

// [rt] Moves the output position on by `samples`, clearing what it passes.
stft_move_output :: proc "contextless" (s: ^Stft, samples: int) {
	if samples == 1 {
		for c in 0 ..< s.synthesis_channels do s.output.buffer[s.output.pos + c * s.block] = 0
		s.output.window_products[s.output.pos] = ALMOST_ZERO
		s.output.pos += 1
		if s.output.pos >= s.block do s.output.pos = 0
		return
	}
	for c in 0 ..< s.synthesis_channels {
		buffer := s.output.buffer[c * s.block:][:s.block]
		pos := s.output.pos
		for _ in 0 ..< samples {
			buffer[pos] = 0
			pos += 1
			if pos == s.block do pos = 0
		}
	}
	pos := s.output.pos
	for _ in 0 ..< samples {
		s.output.window_products[pos] = ALMOST_ZERO
		pos += 1
		if pos == s.block do pos = 0
	}
	s.output.pos = (s.output.pos + samples) % s.block
	s.since_synthesis += samples
}

// [rt] When no more synthesis is coming, lets the output taper to zero with
// the windows rather than being scaled up as if blocks were just far apart.
// Applies from `offset` samples ahead; `strength` 0..1.
stft_finish_output :: proc "contextless" (s: ^Stft, strength: f32 = 1, offset := 0) {
	max_product: f32
	pos := (s.output.pos + offset) % s.block
	for _ in offset ..< s.block {
		wp := &s.output.window_products[pos]
		max_product = max(wp^, max_product)
		wp^ += (max_product - wp^) * strength
		pos += 1
		if pos == s.block do pos = 0
	}
}

// [rt] Analyses the latest block of input (or one ending `samples_in_past`
// samples ago) into every channel's spectrum.
stft_analyse :: proc "contextless" (s: ^Stft, samples_in_past := 0) {
	for step in 0 ..< stft_analyse_steps(s) do stft_analyse_step(s, step, samples_in_past)
}

// [rt] Steps an analysis takes (one per channel, or more with `split`).
stft_analyse_steps :: proc "contextless" (s: ^Stft) -> int {
	return s.analysis_channels * (real_fft_steps(&s.fft) + 1) if s.split else s.analysis_channels
}

// [rt] Step `step` of an analysis; run all of them in order.
stft_analyse_step :: proc "contextless" (s: ^Stft, step: int, samples_in_past := 0) {
	fft_steps := real_fft_steps(&s.fft) if s.split else 0
	channel := step / (fft_steps + 1)
	local := step - channel * (fft_steps + 1) // step within this channel
	if local == 0 {
		// Windowed input, rotated so the window's centre is at time 0.
		start := (s.input_length * 2 + s.input.pos - s.block - samples_in_past) % s.input_length
		s.since_analysis = samples_in_past
		size := len(s.time) // not the FFT size, so an undersized FFT works
		buffer := s.input.buffer[channel * s.input_length:][:s.input_length]
		// In runs where neither the ring buffer wraps nor the window's
		// centre is crossed, so the loops vectorise.
		pos := start
		for i := 0; i < s.block; {
			n := min(s.input_length - pos, (s.analysis_offset if i < s.analysis_offset else s.block) - i)
			src, win := buffer[pos:][:n], s.analysis_window[i:][:n]
			if i < s.analysis_offset {
				dst := s.time[i + size - s.analysis_offset:][:n]
				if s.kind == .Half_Bin { // the half-bin spectrum wraps with a sign change
					for k in 0 ..< n do #no_bounds_check dst[k] = src[k] * -win[k]
				} else {
					for k in 0 ..< n do #no_bounds_check dst[k] = src[k] * win[k]
				}
			} else {
				dst := s.time[i - s.analysis_offset:][:n]
				for k in 0 ..< n do #no_bounds_check dst[k] = src[k] * win[k]
			}
			i += n
			pos += n
			if pos == s.input_length do pos = 0
		}
		if s.fft_size >= s.block {
			for i in s.block - s.analysis_offset ..< s.fft_size - s.analysis_offset do s.time[i] = 0
		} else { // undersized FFT: fold the start of the window forwards
			delta := s.block - s.fft_size
			for i in s.fft_size - s.analysis_offset ..< s.block - s.analysis_offset do s.time[i] += s.time[delta + i]
			for i in s.block - s.analysis_offset ..< s.fft_size do s.time[i] = s.time[delta + i]
		}
		if s.split do return
	} else if !s.split {
		return
	}
	spec := stft_spectrum(s, channel)
	if s.split {
		fft_step := local - 1
		real_fft_forward_step(&s.fft, fft_step, s.time[:s.fft_size], spec[:s.fft_size / 2])
		if s.kind == .Unpacked && fft_step == real_fft_steps(&s.fft) - 1 do unpack_nyquist(s, spec)
	} else {
		real_fft_forward(&s.fft, s.time[:s.fft_size], spec[:s.fft_size / 2])
		if s.kind == .Unpacked do unpack_nyquist(s, spec)
	}
}

// [rt] Synthesises every channel's spectrum and adds the result to the
// output at the current position.
stft_synthesise :: proc "contextless" (s: ^Stft) {
	for step in 0 ..< stft_synthesise_steps(s) do stft_synthesise_step(s, step)
}

// [rt] Steps a synthesis takes.
stft_synthesise_steps :: proc "contextless" (s: ^Stft) -> int {
	return s.synthesis_channels * (real_fft_steps(&s.fft) + 1) + 1 if s.split else s.synthesis_channels
}

// [rt] Step `step` of a synthesis; run all of them in order.
stft_synthesise_step :: proc "contextless" (s: ^Stft, step: int) {
	step := step
	if step == 0 { // add this block's share of the normalisation
		add_window_product(s)
		if s.split do return
	}
	if s.split do step -= 1
	fft_steps := real_fft_steps(&s.fft) if s.split else 0
	channel := step / (fft_steps + 1)
	step -= channel * (fft_steps + 1)
	spec := stft_spectrum(s, channel)
	if s.kind == .Unpacked && step == 0 do spec[0] = complex(real(spec[0]), real(spec[s.bins - 1])) // re-pack
	if s.split {
		if step < fft_steps {
			real_fft_inverse_step(&s.fft, step, spec[:s.fft_size / 2], s.time[:s.fft_size])
			return
		}
	} else {
		real_fft_inverse(&s.fft, spec[:s.fft_size / 2], s.time[:s.fft_size])
	}
	// Window and add into the output, un-rotating around the window's centre.
	buffer := s.output.buffer[channel * s.block:][:s.block]
	pos := s.output.pos
	for i := 0; i < s.block; { // in runs, as in stft_analyse_step
		n := min(s.block - pos, (s.synthesis_offset if i < s.synthesis_offset else s.block) - i)
		dst, win := buffer[pos:][:n], s.synthesis_window[i:][:n]
		if i < s.synthesis_offset {
			src := s.time[i + s.fft_size - s.synthesis_offset:][:n]
			if s.kind == .Half_Bin {
				for k in 0 ..< n do #no_bounds_check dst[k] += src[k] * -win[k]
			} else {
				for k in 0 ..< n do #no_bounds_check dst[k] += src[k] * win[k]
			}
		} else {
			src := s.time[i - s.synthesis_offset:][:n]
			for k in 0 ..< n do #no_bounds_check dst[k] += src[k] * win[k]
		}
		i += n
		pos += n
		if pos == s.block do pos = 0
	}
}

// --- internals ---------------------------------------------------------------------------------

@(private)
unpack_nyquist :: proc "contextless" (s: ^Stft, spec: []complex64) {
	spec[s.bins - 1] = complex(imag(spec[0]), 0)
	spec[0] = complex(real(spec[0]), 0)
}

// Adds a block's analysis × synthesis window product (times the FFT's gain)
// to the normalisation at the output position.
@(private)
add_window_product :: proc "contextless" (s: ^Stft) {
	s.since_synthesis = 0
	shift := s.synthesis_offset - s.analysis_offset
	w_min := max(0, shift)
	w_max := min(s.block, s.block + shift)
	scaling := f32(s.fft_size)
	pos := (s.output.pos + w_min) % s.block
	for i in w_min ..< w_max {
		wp := &s.output.window_products[pos]
		switch s.norm {
		case .Round_Trip: wp^ += s.analysis_window[i - shift] * s.synthesis_window[i] * scaling
		case .Synthesis:  wp^ += s.synthesis_window[i] * scaling
		case .None:       wp^ = scaling
		}
		pos += 1
		if pos == s.block do pos = 0
	}
}

@(private)
kaiser_bessel0 :: proc "contextless" (x: f64) -> f64 {
	result, term, m := 0.0, 1.0, 0.0
	for term > 1e-4 {
		result += term
		m += 1
		term *= (x * x) / (4 * m * m)
	}
	return result
}

@(private)
kaiser_bandwidth_to_beta :: proc "contextless" (bandwidth: f64, heuristic_optimal: bool) -> f64 {
	b := bandwidth
	if heuristic_optimal { // from a numerical search (Signalsmith's)
		b = b + 8 / ((b + 3) * (b + 3)) + 0.25 * max(3 - b, 0)
	}
	b = max(b, 2)
	return math.sqrt(b * b * 0.25 - 1) * math.PI
}

@(private)
kaiser_fill :: proc "contextless" (data: []f32, beta, warp: f64, for_synthesis: bool) {
	size := len(data)
	inv_b0 := 1 / kaiser_bessel0(beta)
	offset := 1 if size & 1 == 1 else (0 if for_synthesis else 2)
	for i in 0 ..< size {
		r := f64(2 * i + offset) / f64(size) - 1
		r = (r + warp) / (1 + r * warp)
		data[i] = f32(kaiser_bessel0(beta * math.sqrt(1 - r * r)) * inv_b0)
	}
	warp_vertically(data, warp)
}

// Approximate confined Gaussian window.
@(private)
acg_fill :: proc "contextless" (data: []f32, bandwidth, warp: f64, for_synthesis: bool) {
	sigma := 0.3 / math.sqrt(bandwidth)
	factor := 0.0625 / (sigma * sigma)
	gaussian :: proc "contextless" (x, factor: f64) -> f64 { return math.exp(-x * x * factor) }
	size := len(data)
	offset_scale := gaussian(1, factor) / (gaussian(3, factor) + gaussian(-1, factor))
	norm := 1 / (gaussian(0, factor) - 2 * offset_scale * gaussian(2, factor))
	offset := 1 if size & 1 == 1 else (0 if for_synthesis else 2)
	for i in 0 ..< size {
		r := f64(2 * i + offset) / f64(size) - 1
		r = (r + warp) / (1 + r * warp)
		data[i] = f32(norm * (gaussian(r, factor) - offset_scale * (gaussian(r - 2, factor) + gaussian(r + 2, factor))))
	}
	warp_vertically(data, warp)
}

// With asymmetry, widen the window vertically again.
@(private)
warp_vertically :: proc "contextless" (data: []f32, warp: f64) {
	if warp == 0 do return
	for &v in data do v = f32(f64(v) * math.sqrt((warp + 1) / (1 + warp * (2 * f64(v) - 1))))
}

// Scales the window so that its squares, summed at every hop, are 1.
@(private)
force_perfect_reconstruction :: proc "contextless" (data: []f32, interval: int) {
	for i in 0 ..< interval {
		sum2: f64
		for k := i; k < len(data); k += interval do sum2 += f64(data[k]) * f64(data[k])
		factor := 1 / math.sqrt(sum2)
		for k := i; k < len(data); k += interval do data[k] = f32(f64(data[k]) * factor)
	}
}
