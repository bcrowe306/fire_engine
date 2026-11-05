package test_dsp

import "core:testing"

import "fire:core"
import "fire:dsp"
import kit "fire:testkit"

// Signalsmith Stretch's configuration at 48 kHz: 120 ms blocks every 30 ms,
// a Kaiser window, an extra interval (+1) of input history.
stretch_like :: proc(spectrum: dsp.Stft_Spectrum, split := false, channels := 2) -> dsp.Stft_Settings {
	return {in_channels = channels, out_channels = channels, block = 5760, extra_history = 1441, interval = 1440, spectrum = spectrum, split = split}
}

// Runs input through write → analyse → synthesise → read at a fixed hop,
// returning channel 0's output. `modify` may change the spectra in between.
round_trip :: proc(s: ^dsp.Stft, input: [][]f32, hop: int, split := false) -> []f32 {
	frames := len(input[0])
	out := make([]f32, frames, context.temp_allocator)
	for at := 0; at + hop <= frames; at += hop {
		for ch, c in input do dsp.stft_write_input(s, c, 0, ch[at:at + hop])
		dsp.stft_move_input(s, hop)
		if split {
			for step in 0 ..< dsp.stft_analyse_steps(s) do dsp.stft_analyse_step(s, step)
			for step in 0 ..< dsp.stft_synthesise_steps(s) do dsp.stft_synthesise_step(s, step)
		} else {
			dsp.stft_analyse(s)
			dsp.stft_synthesise(s)
		}
		dsp.stft_read_output(s, 0, 0, out[at:at + hop])
		dsp.stft_move_output(s, hop)
	}
	return out
}

noise_channels :: proc(channels, frames: int) -> [][]f32 {
	x := make([][]f32, channels, context.temp_allocator)
	for &c, i in x {
		c = make([]f32, frames, context.temp_allocator)
		kit.white_noise(c, u64(i + 1), 0.5)
	}
	return x
}

// Analysis then synthesis with no change gives back the input exactly,
// delayed by the STFT's latency, for every spectrum layout.
@(test)
stft_reconstructs_its_input :: proc(t: ^testing.T) {
	x := noise_channels(2, 48_000 * 2)
	for kind in dsp.Stft_Spectrum {
		for split in ([]bool{false, true}) {
			s: dsp.Stft
			testing.expect_value(t, dsp.stft_init(&s, stretch_like(kind, split)), core.Error.None)
			dsp.stft_set_interval(&s, 1440, .Kaiser)
			y := round_trip(&s, x, 1440, split)
			// The lag from a 4096-frame excerpt past the start-up: the search
			// costs excerpt × lag range, far too slow over the whole signal.
			lag := kit.estimate_latency(x[0][10_000:][:4096], y[10_000:], 20_000)
			// Only whole hops are processed: compare up to the last one written.
			written := len(y) / 1440 * 1440
			worst := 0.0
			for i in 10_000 ..< written - lag do worst = max(worst, abs(f64(y[i + lag]) - f64(x[0][i])))
			testing.expectf(t, worst < 1e-5, "%v split %v: off by %v (latency %d)", kind, split, worst, lag)
			// Reading straight after synthesising saves one hop of latency.
			testing.expectf(t, lag == dsp.stft_latency(&s) - 1440, "%v: latency %d, stft_latency − hop says %d", kind, lag, dsp.stft_latency(&s) - 1440)
			dsp.stft_destroy(&s)
		}
	}
}

// Split computation gives exactly the same output as doing it at once.
@(test)
stft_steps_match_one_shot :: proc(t: ^testing.T) {
	x := noise_channels(2, 30_000)
	for kind in dsp.Stft_Spectrum {
		a, b: dsp.Stft
		dsp.stft_init(&a, stretch_like(kind, false))
		dsp.stft_init(&b, stretch_like(kind, true))
		ya := round_trip(&a, x, 1440, false)
		yb := round_trip(&b, x, 1440, true)
		testing.expectf(t, kit.compare_slices(ya, yb).max_abs_error == 0, "%v: split differs", kind)
		dsp.stft_destroy(&a)
		dsp.stft_destroy(&b)
	}
}

// A steady hop other than the default still reconstructs at unity gain
// (the window products are summed from the blocks actually synthesised).
@(test)
stft_other_hops_keep_unity_gain :: proc(t: ^testing.T) {
	for hop in ([]int{720, 1800}) {
		s: dsp.Stft
		dsp.stft_init(&s, stretch_like(.Half_Bin, channels = 1))
		dsp.stft_set_interval(&s, 1440, .Kaiser)
		x := make([]f32, 48_000 * 2, context.temp_allocator)
		kit.sine(x, 48_000, 440, 0.5)
		y := round_trip(&s, {x}, hop)
		written := len(y) / hop * hop
		amp := kit.tone_amplitude(y[20_000:written], 48_000, 440)
		testing.expectf(t, abs(kit.linear_to_db(amp / 0.5)) < 0.05, "hop %d: gain %.3f dB", hop, kit.linear_to_db(amp / 0.5))
		dsp.stft_destroy(&s)
	}
}

// A tone centred on a bin peaks in that bin; bin_to_freq and freq_to_bin agree.
@(test)
stft_bins :: proc(t: ^testing.T) {
	for kind in ([]dsp.Stft_Spectrum{.Packed, .Half_Bin}) {
		s: dsp.Stft
		dsp.stft_init(&s, stretch_like(kind, channels = 1))
		bin := 200
		freq := f64(dsp.stft_bin_to_freq(&s, f32(bin))) * 48_000
		x := make([]f32, dsp.stft_block(&s), context.temp_allocator)
		kit.sine(x, 48_000, freq, 1)
		dsp.stft_write_input(&s, 0, 0, x)
		dsp.stft_move_input(&s, len(x))
		dsp.stft_analyse(&s)
		spec := dsp.stft_spectrum(&s, 0)
		best := 0
		for v, i in spec do if abs(v) > abs(spec[best]) do best = i
		testing.expectf(t, best == bin, "%v: peak in bin %d, want %d", kind, best, bin)
		testing.expect(t, abs(dsp.stft_freq_to_bin(&s, dsp.stft_bin_to_freq(&s, 37.25)) - 37.25) < 1e-4)
		dsp.stft_destroy(&s)
	}
}

@(test)
stft_never_allocates :: proc(t: ^testing.T) {
	s: dsp.Stft
	dsp.stft_init(&s, stretch_like(.Half_Bin, true))
	defer dsp.stft_destroy(&s)
	stash_in := dsp.stft_input_make(&s)
	stash_out := dsp.stft_output_make(&s)
	defer dsp.stft_input_free(&stash_in)
	defer dsp.stft_output_free(&stash_out)
	x := noise_channels(2, 20_000)
	trap: kit.Trap_Allocator
	{
		context.allocator = kit.trap_allocator(&trap)
		context.temp_allocator = context.allocator
		dsp.stft_set_interval(&s, 1440, .Kaiser)
		dsp.stft_reset(&s)
		buf: [1440]f32
		for at := 0; at + 1440 <= 20_000; at += 1440 {
			for c in 0 ..< 2 do dsp.stft_write_input(&s, c, 0, x[c][at:at + 1440])
			dsp.stft_move_input(&s, 1440)
			dsp.stft_input_copy(&stash_in, &s.input)
			dsp.stft_swap_input(&s, &stash_in)
			for step in 0 ..< dsp.stft_analyse_steps(&s) do dsp.stft_analyse_step(&s, step, 1440)
			dsp.stft_swap_input(&s, &stash_in)
			dsp.stft_output_copy(&stash_out, &s.output)
			dsp.stft_synthesise(&s)
			dsp.stft_read_output(&s, 0, 0, buf[:])
			dsp.stft_add_output(&s, 1, 0, buf[:100])
			dsp.stft_move_output(&s, 1440)
			dsp.stft_finish_output(&s, 0.5)
		}
	}
	testing.expect_value(t, trap.violations, 0)
}
