package stretch

import "core:math"

import "fire:dsp"

@(private)
mul :: #force_inline proc "contextless" (a, b: complex64) -> complex64 {
	return complex(real(a) * real(b) - imag(a) * imag(b), real(a) * imag(b) + imag(a) * real(b))
}

// a × conj(b), written out as Signalsmith's _impl::mul<true>.
@(private)
mul_conj :: #force_inline proc "contextless" (a, b: complex64) -> complex64 {
	return complex(real(b) * real(a) + imag(b) * imag(a), real(b) * imag(a) - imag(b) * real(a))
}

@(private)
norm :: #force_inline proc "contextless" (a: complex64) -> f32 {
	return real(a) * real(a) + imag(a) * imag(a)
}

@(private)
polar :: #force_inline proc "contextless" (phase: f32) -> complex64 {
	return complex(math.cos(phase), math.sin(phase))
}

@(private)
band_to_freq :: #force_inline proc "contextless" (s: ^Stretch, b: f32) -> f32 { return dsp.stft_bin_to_freq(&s.stft, b) }
@(private)
freq_to_band :: #force_inline proc "contextless" (s: ^Stretch, f: f32) -> f32 { return dsp.stft_freq_to_bin(&s.stft, f) }

// Band fields by index, zero outside the spectrum, interpolated between.
@(private)
Band_Field :: enum {
	Input,
	Prev_Input,
	Output,
}

@(private)
get_band :: #force_inline proc "contextless" (s: ^Stretch, field: Band_Field, c, index: int) -> complex64 {
	if index < 0 || index >= s.bands do return 0
	b := &s.channel_bands[index + c * s.bands]
	switch field {
	case .Input:      return b.input
	case .Prev_Input: return b.prev_input
	case .Output:     return b.output
	}
	return 0
}

@(private)
get_fractional :: #force_inline proc "contextless" (s: ^Stretch, field: Band_Field, c, low: int, frac: f32) -> complex64 {
	lo := get_band(s, field, c, low)
	hi := get_band(s, field, c, low + 1)
	return lo + (hi - lo) * complex(frac, 0)
}

@(private)
get_fractional_at :: #force_inline proc "contextless" (s: ^Stretch, field: Band_Field, c: int, index: f32) -> complex64 {
	low := int(math.floor(index))
	return get_fractional(s, field, c, low, index - f32(low))
}

@(private)
get_energy :: #force_inline proc "contextless" (s: ^Stretch, c, index: int) -> f32 {
	if index < 0 || index >= s.bands do return 0
	return s.channel_bands[index + c * s.bands].input_energy
}

@(private)
get_energy_fractional :: #force_inline proc "contextless" (s: ^Stretch, c, low: int, frac: f32) -> f32 {
	lo := get_energy(s, c, low)
	hi := get_energy(s, c, low + 1)
	return lo + (hi - lo) * frac
}

@(private)
make_output :: #force_inline proc "contextless" (p: ^Prediction, phase_: complex64) -> complex64 {
	phase := phase_
	phase_norm := norm(phase)
	if phase_norm <= NOISE_FLOOR { // the prediction is too weak: fall back to the input
		phase = p.input
		phase_norm = norm(p.input) + NOISE_FLOOR
	}
	return phase * complex(math.sqrt(p.energy / phase_norm), 0)
}

@(private)
update_process_spectrum_steps :: proc "contextless" (s: ^Stretch) {
	bp := &s.block
	n := 0
	if bp.new_spectrum do n += s.channels
	if bp.mapped_frequencies do n += SMOOTH_ENERGY_STEPS + 1 // and find_peaks
	n += 1 // the output map
	n += s.channels // preliminary phase-vocoder prediction
	n += SPLIT_MAIN_PREDICTION
	if bp.new_spectrum do n += 1 // .input → .prev_input
	if bp.process_formants do n += 3
	s.process_spectrum_steps = n
}

@(private)
process_spectrum :: proc "contextless" (s: ^Stretch, step_: int) {
	st := &s.stft
	bp := &s.block
	step := step_
	interval := dsp.stft_interval(st)
	time_factor := bp.time_factor

	smoothing_bins := f32(dsp.stft_fft_size(st)) / f32(interval)
	long_vertical_step := int(math.round(smoothing_bins))
	time_factor = max(time_factor, 1 / MAX_CLEAN_STRETCH)
	random_time_factor := time_factor > MAX_CLEAN_STRETCH
	dist_a := MAX_CLEAN_STRETCH * 2 * f32(int(random_time_factor)) - time_factor
	dist_b := time_factor

	if bp.new_spectrum {
		if step < s.channels {
			rot := polar(band_to_freq(s, 0) * f32(interval) * f32(2 * math.PI))
			freq_step := band_to_freq(s, 1) - band_to_freq(s, 0)
			rot_step := polar(freq_step * f32(interval) * f32(2 * math.PI))
			for &bin in bands_for(s, step) {
				bin.output = mul(bin.output, rot)
				bin.prev_input = mul(bin.prev_input, rot)
				rot = mul(rot, rot_step)
			}
			return
		}
		step -= s.channels
	}
	if bp.mapped_frequencies {
		if step < SMOOTH_ENERGY_STEPS {
			smooth_energy(s, step, smoothing_bins)
			return
		}
		step -= SMOOTH_ENERGY_STEPS
		if step == 0 {
			find_peaks(s)
			return
		}
		step -= 1
	}
	if step == 0 {
		if bp.mapped_frequencies {
			update_output_map(s)
		} else { // not pitch-shifting: no peaks needed
			for c in 0 ..< s.channels do for &b in bands_for(s, c) do b.input_energy = norm(b.input)
			for &m, b in s.output_map do m = {f32(b), 1}
		}
		return
	}
	step -= 1
	if bp.process_formants {
		if step < 3 {
			update_formants(s, step)
			return
		}
		step -= 3
	}
	// Preliminary output prediction from the phase vocoder.
	if step < s.channels {
		c := step
		bins := bands_for(s, c)
		preds := s.predictions[c * s.bands:][:s.bands]
		for b in 0 ..< s.bands {
			mp := s.output_map[b]
			low := int(math.floor(mp.input_bin))
			frac := mp.input_bin - f32(low)
			pred := &preds[b]
			prev_energy := pred.energy
			pred.energy = get_energy_fractional(s, c, low, frac)
			pred.energy *= max(0, mp.freq_grad) // scale the energy by the local stretch
			pred.input = get_fractional(s, .Input, c, low, frac)
			out := &bins[b]
			prev_input := get_fractional(s, .Prev_Input, c, low, frac)
			freq_twist := mul_conj(pred.input, prev_input)
			phase := mul(out.output, freq_twist)
			out.output = phase / complex(max(prev_energy, pred.energy) + NOISE_FLOOR, 0)
		}
		return
	}
	step -= s.channels

	if step < SPLIT_MAIN_PREDICTION {
		// Re-predict using phase differences between frequencies.
		start := s.bands * step / SPLIT_MAIN_PREDICTION
		end := s.bands * (step + 1) / SPLIT_MAIN_PREDICTION
		for b in start ..< end {
			// The loudest channel leads.
			max_channel := 0
			max_energy := s.predictions[b].energy
			for c in 1 ..< s.channels {
				e := s.predictions[c * s.bands + b].energy
				if e > max_energy do max_channel, max_energy = c, e
			}
			preds := s.predictions[max_channel * s.bands:][:s.bands]
			pred := &preds[b]
			bins := bands_for(s, max_channel)
			out := &bins[b]
			phase: complex64
			mp := s.output_map[b]

			if b > 0 { // upwards vertical steps
				btf := uniform(&s.rng, dist_a, dist_b) if random_time_factor else time_factor
				down_input := get_fractional_at(s, .Input, max_channel, mp.input_bin - btf)
				short_twist := mul_conj(pred.input, down_input)
				phase += mul(bins[b - 1].output, short_twist)
				if b >= long_vertical_step {
					long_down := get_fractional_at(s, .Input, max_channel, mp.input_bin - f32(long_vertical_step) * btf)
					long_twist := mul_conj(pred.input, long_down)
					phase += mul(bins[b - long_vertical_step].output, long_twist)
				}
			}
			if b < s.bands - 1 { // downwards vertical steps
				up_pred := &preds[b + 1]
				up_mp := s.output_map[b + 1]
				btf := uniform(&s.rng, dist_a, dist_b) if random_time_factor else time_factor
				down_input := get_fractional_at(s, .Input, max_channel, up_mp.input_bin - btf)
				short_twist := mul_conj(up_pred.input, down_input)
				phase += mul_conj(bins[b + 1].output, short_twist)
				if b < s.bands - long_vertical_step {
					long_up_pred := &preds[b + long_vertical_step]
					long_up_mp := s.output_map[b + long_vertical_step]
					long_down := get_fractional_at(s, .Input, max_channel, long_up_mp.input_bin - f32(long_vertical_step) * btf)
					long_twist := mul_conj(long_up_pred.input, long_down)
					phase += mul_conj(bins[b + long_vertical_step].output, long_twist)
				}
			}
			out.output = make_output(pred, phase)

			// Every other channel is locked in phase to it.
			for c in 0 ..< s.channels {
				if c == max_channel do continue
				channel_bin := &s.channel_bands[c * s.bands + b]
				channel_pred := &s.predictions[c * s.bands + b]
				channel_twist := mul_conj(channel_pred.input, pred.input)
				channel_phase := mul(out.output, channel_twist)
				channel_bin.output = make_output(channel_pred, channel_phase)
			}
		}
		return
	}
	step -= SPLIT_MAIN_PREDICTION

	if bp.new_spectrum && step == 0 {
		for &bin in s.channel_bands do bin.prev_input = bin.input
	}
}

// Energy summed over channels, and a smoothed copy (two passes, down then up).
@(private)
smooth_energy :: proc "contextless" (s: ^Stretch, step: int, smoothing_bins: f32) {
	slew := 1 / (1 + smoothing_bins * 0.5)
	if step == 0 {
		for &e in s.energy do e = 0
		for c in 0 ..< s.channels {
			for &bin, b in bands_for(s, c) {
				e := norm(bin.input)
				bin.input_energy = e // used to interpolate prediction energy
				s.energy[b] += e
			}
		}
		copy(s.smoothed_energy, s.energy)
		s.smooth_energy_state = 0
		return
	}
	e := s.smooth_energy_state
	for b := s.bands - 1; b >= 0; b -= 1 {
		e += (s.smoothed_energy[b] - e) * slew
		s.smoothed_energy[b] = e
	}
	for b in 0 ..< s.bands {
		e += (s.smoothed_energy[b] - e) * slew
		s.smoothed_energy[b] = e
	}
	s.smooth_energy_state = e
}

@(private)
map_freq :: #force_inline proc "contextless" (s: ^Stretch, freq: f32) -> f32 {
	if s.freq_map != nil do return s.freq_map(freq, s.freq_map_user)
	if freq > s.freq_tonality_limit do return freq + (s.freq_multiplier - 1) * s.freq_tonality_limit
	return freq * s.freq_multiplier
}

// Spectral peaks from the energy across all channels.
@(private)
find_peaks :: proc "contextless" (s: ^Stretch) {
	s.peak_count = 0
	start := 0
	for start < s.bands {
		if s.energy[start] > s.smoothed_energy[start] {
			end := start
			band_sum, energy_sum: f32
			for end < s.bands && s.energy[end] > s.smoothed_energy[end] {
				band_sum += f32(end) * s.energy[end]
				energy_sum += s.energy[end]
				end += 1
			}
			avg_band := band_sum / energy_sum
			avg_freq := band_to_freq(s, avg_band)
			if s.peak_count < len(s.peaks) {
				s.peaks[s.peak_count] = {avg_band, freq_to_band(s, map_freq(s, avg_freq))}
				s.peak_count += 1
			}
			start = end
		}
		start += 1
	}
}

@(private)
update_output_map :: proc "contextless" (s: ^Stretch) {
	peaks := s.peaks[:s.peak_count]
	if len(peaks) == 0 {
		for &m, b in s.output_map do m = {f32(b), 1}
		return
	}
	bottom := peaks[0].input - peaks[0].output
	for b in 0 ..< min(s.bands, int(math.ceil(peaks[0].output))) do s.output_map[b] = {f32(b) + bottom, 1}
	// Smooth (cubic) interpolation between peaks.
	for p in 1 ..< len(peaks) {
		prev, next := peaks[p - 1], peaks[p]
		range_scale := 1 / (next.output - prev.output)
		out_offset := prev.input - prev.output
		out_scale := next.input - next.output - prev.input + prev.output
		grad_scale := out_scale * range_scale
		start := max(0, int(math.ceil(prev.output)))
		end := min(s.bands, int(math.ceil(next.output)))
		for b in start ..< end {
			r := (f32(b) - prev.output) * range_scale
			h := r * r * (3 - 2 * r)
			out_b := f32(b) + out_offset + h * out_scale
			grad_h := 6 * r * (1 - r)
			grad_b := 1 + grad_h * grad_scale
			s.output_map[b] = {out_b, grad_b}
		}
	}
	top := peaks[len(peaks) - 1].input - peaks[len(peaks) - 1].output
	for b in max(0, int(peaks[len(peaks) - 1].output)) ..< s.bands do s.output_map[b] = {f32(b) + top, 1}
}

// Mapping formants the way map_freq maps frequencies, inverted.
@(private)
inv_map_formant :: #force_inline proc "contextless" (s: ^Stretch, freq: f32) -> f32 {
	if freq * s.inv_formant_multiplier > s.freq_tonality_limit do return freq + (1 - s.formant_multiplier) * s.freq_tonality_limit
	return freq * s.inv_formant_multiplier
}

@(private)
estimate_frequency :: proc "contextless" (s: ^Stretch) -> f32 {
	fm := s.formant_metric
	// The three highest local peaks of the input.
	peak := [3]int{0, 0, 0}
	for b in 1 ..< s.bands - 1 {
		e := fm[b]
		if e < fm[b - 1] || e <= fm[b + 1] do continue // local maxima only
		if e > fm[peak[0]] {
			if e > fm[peak[1]] {
				if e > fm[peak[2]] {
					peak = {peak[1], peak[2], b}
				} else {
					peak = {peak[1], b, peak[2]}
				}
			} else {
				peak[0] = b
			}
		}
	}
	// A very rough pitch estimate.
	estimate := peak[2]
	if fm[peak[1]] > fm[peak[2]] * 0.1 {
		diff := abs(estimate - peak[1])
		if diff > estimate / 8 && diff < estimate * 7 / 8 do estimate = estimate % diff
		if fm[peak[0]] > fm[peak[2]] * 0.01 {
			diff = abs(estimate - peak[0])
			if diff > estimate / 8 && diff < estimate * 7 / 8 do estimate = estimate % diff
		}
	}
	weight := fm[peak[2]]
	// Smoothed over blocks.
	s.freq_estimate_weighted += (f32(estimate) * weight - s.freq_estimate_weighted) * 0.25
	s.freq_estimate_weight += (weight - s.freq_estimate_weight) * 0.25
	return s.freq_estimate_weighted / (s.freq_estimate_weight + 1e-30)
}

@(private)
update_formants :: proc "contextless" (s: ^Stretch, step: int) {
	fm := s.formant_metric
	switch step {
	case 0:
		for &e in fm do e = 0
		for c in 0 ..< s.channels do for bin, b in bands_for(s, c) do fm[b] += bin.input_energy
		s.freq_estimate = freq_to_band(s, s.formant_base_freq)
		if s.formant_base_freq <= 0 do s.freq_estimate = estimate_frequency(s)
	case 1:
		decay := 1 - 1 / (s.freq_estimate * 0.5 + 1)
		e: f32
		for _ in 0 ..< 2 {
			for b := s.bands - 1; b >= 0; b -= 1 {
				e = max(fm[b], e * decay)
				fm[b] = e
			}
			for b in 0 ..< s.bands {
				e = max(fm[b], e * decay)
				fm[b] = e
			}
		}
		decay = 1 / decay
		for _ in 0 ..< 2 {
			for b := s.bands - 1; b >= 0; b -= 1 {
				e = min(fm[b], e * decay)
				fm[b] = e
			}
			for b in 0 ..< s.bands {
				e = min(fm[b], e * decay)
				fm[b] = e
			}
		}
	case:
		get_formant :: proc "contextless" (s: ^Stretch, band_: f32) -> f32 {
			if band_ < 0 do return 0
			band := min(band_, f32(s.bands))
			floor_band := int(math.floor(band))
			frac := band - f32(floor_band)
			lo, hi := s.formant_metric[floor_band], s.formant_metric[floor_band + 1]
			return lo + (hi - lo) * frac
		}
		for b in 0 ..< s.bands {
			input_f := band_to_freq(s, f32(b))
			output_f := map_freq(s, input_f) if s.formant_compensation else input_f
			output_f = inv_map_formant(s, output_f)
			input_e := fm[b]
			target_e := get_formant(s, freq_to_band(s, output_f))
			ratio := target_e / (input_e + 1e-30)
			// This decides the output energy.
			for c in 0 ..< s.channels do s.channel_bands[c * s.bands + b].input_energy *= ratio
		}
	}
}
