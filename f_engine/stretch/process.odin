package stretch

import "core:math"

import "fire:dsp"

// Audio for the internal procs: channels plus an offset into each (as
// Signalsmith's OffsetIO); nil channels read as silence (its Zeros).
@(private)
Io :: struct {
	channels: [][]f32,
	offset:   int,
}

@(private)
io_get :: #force_inline proc "contextless" (io: Io, c, i: int) -> f32 {
	return io.channels[c][i + io.offset] if io.channels != nil else 0
}

@(private)
io_set :: #force_inline proc "contextless" (io: Io, c, i: int, v: f32) {
	io.channels[c][i + io.offset] = v
}

// [rt] Gives previous input ("pre-roll") so the input position can move
// without interrupting the output: ideally `stretch_seek_length` frames,
// ending where playback continues. `playback_rate` is the rate that
// follows (input frames per output frame).
stretch_seek :: proc "contextless" (s: ^Stretch, input: [][]f32, frames: int, playback_rate: f64) {
	seek(s, {input, 0}, frames, playback_rate)
}

// [rt] Starts over so that the next output begins at `input`'s first frame:
// give `stretch_output_seek_length(rate)` frames; the rate is inferred
// from how many.
stretch_output_seek :: proc "contextless" (s: ^Stretch, input: [][]f32, frames: int) {
	output_seek(s, {input, 0}, frames)
}

// [rt] Consumes `in_frames` frames of `input` and produces `out_frames`
// into `output` (one slice per channel); their ratio is the playback rate.
stretch_process :: proc "contextless" (s: ^Stretch, input: [][]f32, in_frames: int, output: [][]f32, out_frames: int) {
	process(s, {input, 0}, in_frames, {output, 0}, out_frames)
}

// [rt] Reads the remaining output with no more input. Asking for more than
// one interval computes further blocks from silence at `playback_rate`.
stretch_flush :: proc "contextless" (s: ^Stretch, output: [][]f32, frames: int, playback_rate: f32 = 0) {
	flush(s, {output, 0}, frames, playback_rate)
}

// [rt] Stretches a whole buffer at once: `in_frames` of input to exactly
// `out_frames` of output, aligned at both ends. False (and silence) if the
// input is too short for the stretcher's latency.
stretch_exact :: proc "contextless" (s: ^Stretch, input: [][]f32, in_frames: int, output: [][]f32, out_frames: int) -> bool {
	playback_rate := f32(in_frames) / f32(out_frames)
	seek_length := stretch_output_seek_length(s, playback_rate)
	if in_frames < seek_length {
		for c in 0 ..< s.channels do for &v in output[c][:out_frames] do v = 0
		return false
	}
	output_seek(s, {input, 0}, seek_length)
	output_index := int(f32(out_frames) - f32(seek_length) / playback_rate)
	process(s, {input, seek_length}, in_frames - seek_length, {output, 0}, output_index)
	flush(s, {output, output_index}, out_frames - output_index, playback_rate)
	return true
}

// --- internals ---------------------------------------------------------------------------------

@(private)
seek :: proc "contextless" (s: ^Stretch, input: Io, frames: int, playback_rate: f64) {
	tmp := s.tmp_process[:dsp.stft_block(&s.stft) + dsp.stft_interval(&s.stft)]
	for &v in tmp do v = 0
	start := max(0, frames - len(tmp)) // where in the input to start
	pad := len(tmp) + start - frames   // and where it lands in tmp
	total: f32
	for c in 0 ..< s.channels {
		for i in start ..< frames {
			v := io_get(input, c, i)
			total += v * v
			tmp[i - start + pad] = v
		}
		dsp.stft_write_input(&s.stft, c, 0, tmp)
	}
	dsp.stft_move_input(&s.stft, len(tmp))
	if total >= NOISE_FLOOR {
		s.silence_counter = 0
		s.silence_first = true
	}
	s.did_seek = true
	interval := dsp.stft_interval(&s.stft)
	s.seek_time_factor = f32(1 / playback_rate) if playback_rate * f64(interval) > 1 else f32(interval)
}

@(private)
output_seek :: proc "contextless" (s: ^Stretch, input: Io, frames: int) {
	stretch_reset(s)
	latency := stretch_output_latency(s)
	surplus := max(frames - stretch_input_latency(s), 0)
	playback_rate := f32(surplus) / f32(latency)
	seek_samples := frames - surplus
	seek(s, input, seek_samples, f64(playback_rate))

	// Use the surplus input to make pre-roll output, then reverse and negate
	// it into the output: the next output then starts at the input's start.
	pre := s.tmp_pre_roll[:latency * s.channels]
	views: [MAX_CHANNELS][]f32
	for c in 0 ..< s.channels do views[c] = pre[c * latency:][:latency]
	process(s, {input.channels, input.offset + seek_samples}, surplus, {views[:s.channels], 0}, latency)
	for &v in pre do v = -v
	for c in 0 ..< s.channels {
		ch := views[c]
		for i in 0 ..< latency / 2 do ch[i], ch[latency - 1 - i] = ch[latency - 1 - i], ch[i]
		dsp.stft_add_output(&s.stft, c, 0, ch)
	}
}

@(private)
flush :: proc "contextless" (s: ^Stretch, output: Io, frames: int, playback_rate: f32) {
	interval := dsp.stft_interval(&s.stft)
	output_block := max(0, frames - interval)
	if output_block > 0 do process(s, {nil, 0}, int(f32(output_block) * playback_rate), output, output_block)
	tail := frames - output_block // at most one interval
	tmp := s.tmp_process[:tail]
	dsp.stft_finish_output(&s.stft, 1)
	for c in 0 ..< s.channels {
		dsp.stft_read_output(&s.stft, c, 0, tmp)
		for i in 0 ..< tail do io_set(output, c, output_block + i, tmp[i])
		dsp.stft_read_output(&s.stft, c, tail, tmp)
		for i in 0 ..< tail {
			k := output_block + tail - 1 - i
			io_set(output, c, k, io_get(output, c, k) - tmp[i])
		}
	}
	dsp.stft_reset(&s.stft, 0.1)
	// So the next block starts fresh.
	for &b in s.channel_bands do b.prev_input, b.output = 0, 0
}

@(private)
process :: proc "contextless" (s: ^Stretch, input: Io, in_frames: int, output: Io, out_frames: int) {
	st := &s.stft
	interval := dsp.stft_interval(st)
	prev_copied := 0
	copy_input :: proc "contextless" (s: ^Stretch, input: Io, to_index: int, prev_copied: ^int) {
		length := min(dsp.stft_block(&s.stft) + dsp.stft_interval(&s.stft), to_index - prev_copied^)
		tmp := s.tmp_process[:max(length, 0)]
		offset := to_index - length
		for c in 0 ..< s.channels {
			for i in 0 ..< len(tmp) do tmp[i] = io_get(input, c, i + offset)
			dsp.stft_write_input(&s.stft, c, 0, tmp)
		}
		dsp.stft_move_input(&s.stft, len(tmp))
		prev_copied^ = to_index
	}

	total: f32
	for c in 0 ..< s.channels {
		for i in 0 ..< in_frames {
			v := io_get(input, c, i)
			total += v * v
		}
	}
	if total < NOISE_FLOOR {
		if s.silence_counter >= 2 * dsp.stft_block(st) {
			if s.silence_first { // the first block of silence
				s.silence_first = false
				s.block = {samples_since_last = max(int)} // C++'s `blockProcess = {}` restores this default
				for &b in s.channel_bands {
					b.input, b.prev_input, b.output = 0, 0, 0
					b.input_energy = 0
				}
			}
			if in_frames > 0 { // copy the input through, wrapping if needed
				for i in 0 ..< out_frames {
					for c in 0 ..< s.channels do io_set(output, c, i, io_get(input, c, i % in_frames))
				}
			} else {
				for c in 0 ..< s.channels do for i in 0 ..< out_frames do io_set(output, c, i, 0)
			}
			copy_input(s, input, in_frames, &prev_copied) // keep the history
			return
		}
		s.silence_counter += in_frames
	} else {
		s.silence_counter = 0
		s.silence_first = true
	}

	for out_index in 0 ..< out_frames {
		bp := &s.block
		new_block := bp.samples_since_last >= interval
		if new_block {
			bp.step, bp.steps, bp.samples_since_last = 0, 0, 0
			// Where in the input this spectrum comes from.
			input_offset := int(math.round(f32(out_index) * f32(in_frames) / f32(out_frames)))
			input_interval := input_offset - s.prev_input_offset
			s.prev_input_offset = input_offset

			copy_input(s, input, input_offset, &prev_copied)
			dsp.stft_input_copy(&s.stashed_input, &st.input) // analysed later
			if s.split_computation {
				dsp.stft_output_copy(&s.stashed_output, &st.output) // read from this meanwhile
				dsp.stft_move_output(st, interval) // the synthesis lands one interval ahead
			}
			bp.new_spectrum = s.did_seek || input_interval > 0
			bp.mapped_frequencies = s.freq_map != nil || s.freq_multiplier != 1
			if bp.new_spectrum {
				// The previous input must be one interval back (give or take a sample).
				bp.reanalyse_prev = s.did_seek || abs(input_interval - interval) > 1
				if bp.reanalyse_prev do bp.steps += dsp.stft_analyse_steps(st) + 1
				bp.steps += dsp.stft_analyse_steps(st) + 1
			}
			bp.process_formants = s.formant_multiplier != 1 || (s.formant_compensation && bp.mapped_frequencies)
			bp.time_factor = s.seek_time_factor if s.did_seek else f32(interval) / f32(max(1, input_interval))
			s.did_seek = false
			update_process_spectrum_steps(s)
			bp.steps += s.process_spectrum_steps
			bp.steps += dsp.stft_synthesise_steps(st) + 1
		}

		process_to := bp.steps if new_block else 0
		if s.split_computation {
			ratio := f32(bp.samples_since_last + 1) / f32(interval)
			process_to = min(bp.steps, int((f32(bp.steps) + 0.999) * ratio))
		}
		for bp.step < process_to {
			step := bp.step
			bp.step += 1
			run_step(s, step)
		}

		bp.samples_since_last += 1
		if s.split_computation do dsp.stft_swap_output(st, &s.stashed_output)
		for c in 0 ..< s.channels {
			v: [1]f32
			dsp.stft_read_output(st, c, 0, v[:])
			io_set(output, c, out_index, v[0])
		}
		dsp.stft_move_output(st, 1)
		if s.split_computation do dsp.stft_swap_output(st, &s.stashed_output)
	}
	copy_input(s, input, in_frames, &prev_copied)
	s.prev_input_offset -= in_frames
}

// One step of a block's work: analyse (the past input, then the new),
// process the spectrum, write it back, synthesise.
@(private)
run_step :: proc "contextless" (s: ^Stretch, step_: int) {
	st := &s.stft
	bp := &s.block
	step := step_
	analyse := dsp.stft_analyse_steps(st)
	if bp.new_spectrum {
		if bp.reanalyse_prev {
			if step < analyse { // analyse the past input
				dsp.stft_swap_input(st, &s.stashed_input)
				dsp.stft_analyse_step(st, step, dsp.stft_interval(st))
				dsp.stft_swap_input(st, &s.stashed_input)
				return
			}
			step -= analyse
			if step < 1 {
				for c in 0 ..< s.channels {
					spec := dsp.stft_spectrum(st, c)
					for &b, i in bands_for(s, c) do b.prev_input = spec[i]
				}
				return
			}
			step -= 1
		}
		if step < analyse { // analyse the latest (stashed) input
			dsp.stft_swap_input(st, &s.stashed_input)
			dsp.stft_analyse_step(st, step)
			dsp.stft_swap_input(st, &s.stashed_input)
			return
		}
		step -= analyse
		if step < 1 {
			for c in 0 ..< s.channels {
				spec := dsp.stft_spectrum(st, c)
				for &b, i in bands_for(s, c) do b.input = spec[i]
			}
			return
		}
		step -= 1
	}
	if step < s.process_spectrum_steps {
		process_spectrum(s, step)
		return
	}
	step -= s.process_spectrum_steps
	if step < 1 {
		for c in 0 ..< s.channels {
			spec := dsp.stft_spectrum(st, c)
			for b, i in bands_for(s, c) do spec[i] = b.output
		}
		return
	}
	step -= 1
	if step < dsp.stft_synthesise_steps(st) do dsp.stft_synthesise_step(st, step)
}

@(private)
bands_for :: #force_inline proc "contextless" (s: ^Stretch, c: int) -> []Band {
	return s.channel_bands[c * s.bands:][:s.bands]
}
