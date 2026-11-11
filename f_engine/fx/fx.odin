/*
Effects and filters, as units to run on stereo buffers (and nodes to put
in a graph): the eight filter models a synth voice has (`filter_render`),
and the effects a synth chains after its voices: chorus, a three-band
compressor, delay, distortion, EQ, a filter, flanger, phaser and reverb.
Each takes its settings as a plain struct and glides between renders,
so they can be modulated, and allocates nothing while it runs (the delay
lines are in its state, made with the effect).

	state: fx.Distortion
	p := fx.DISTORTION_DEFAULTS
	p.drive_db = 12
	fx.distortion_render(&state, &p, left, right, sample_rate)
*/
package fx
