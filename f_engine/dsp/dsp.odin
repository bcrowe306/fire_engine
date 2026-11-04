/*
DSP building blocks and ready-made nodes.

Every effect comes twice: as plain structs and procedures you can use inside
your own nodes (`svf_design` and `svf_tick`, `biquad_design`, ...), and as
a graph node with stable parameter ids (`filter_create`, `eq_create`, ...).
Primitives marked [rt] are safe on the audio thread.

	// Inside your own node: one coefficient set, a state per channel.
	c := dsp.svf_design(mode = .Lowpass, cutoff_hz = 800, q = 0.707, gain_db = 0, sample_rate = 48_000)
	for &x in channel do x = f32(dsp.svf_tick(&c, &state[ch], f64(x)))

	// As a node in a graph:
	eq, _ := graph.add_node(g, dsp.eq_create(4), 2, 2)
	graph.set_param(g, eq, dsp.eq_band_param(1, .Gain_Db), -6)

Also here: `Smoothed_Value` (parameter smoothing and automation ramps),
`Resampler`, the FFT and STFT, and the `Gain` and `One_Pole_Lowpass` nodes.
See /guides/effects/.
*/
package dsp
