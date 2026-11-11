/*
A wavetable synthesizer's parts: wavetables, the oscillator that plays
them with unison and warps, and (in time) its filters, modulators, voice
and node.

A `Wavetable` is up to `WAVE_FRAMES` single-cycle frames of `WAVE_SIZE`
samples, kept as spectra. An oscillator reads a frame through a wave
buffer it rebuilds every few milliseconds (`wave_build`): the frame's
harmonics up to the highest that stays below Nyquist at the note's pitch,
turned back into a wave. So nothing aliases however high it plays, and a
spectral change (a morph) is only a change to those harmonics.

	frames := [][]f32{saw[:], square[:]}
	t, _ := synth.wavetable_make("Saw to square", frames)
	defer synth.wavetable_destroy(t)
*/
package synth

import "core:math"
import "core:mem"
import "core:strings"

import "fire:core"
import "fire:dsp"

// Samples in a wavetable frame (one cycle).
WAVE_SIZE :: 2048

// Bins of a frame's spectrum (`WAVE_SIZE` / 2: the first holds DC and
// Nyquist together, as `dsp.Real_Fft` packs them).
WAVE_BINS :: WAVE_SIZE / 2

// Frames a wavetable can have. A table made from fewer keyframes is
// interpolated out to this many, so a frame position moves smoothly.
WAVE_FRAMES :: 256

// Samples of padding around a wave buffer: one before and two after, so
// a cubic read never has to wrap.
WAVE_PAD :: 3

// A wavetable: `frames` frames (1, or `WAVE_FRAMES`), each a spectrum
// scaled so that an inverse `dsp.Real_Fft` gives the wave back as it was.
// `waves` keeps the frames as samples, for drawing. Made with
// `wavetable_make`; read-only once made, so the audio thread may read it
// while the control thread holds it.
Wavetable :: struct {
	name:    string,
	frames:  int,
	spectra: [][WAVE_BINS]complex64,
	waves:   [][WAVE_SIZE]f32,
}

// Control thread. A wavetable from `keyframes` (each `WAVE_SIZE` samples;
// longer ones are cut, shorter ones padded with zeros). One keyframe
// makes a table of one frame; more are spread evenly across
// `WAVE_FRAMES`, those between them crossfaded. Free with
// `wavetable_destroy`.
wavetable_make :: proc(name: string, keyframes: [][]f32, allocator := context.allocator) -> (t: ^Wavetable, err: core.Error) {
	if len(keyframes) == 0 do return nil, .Invalid_Argument
	t = new(Wavetable, allocator)
	if t == nil do return nil, .Out_Of_Memory
	n := 1 if len(keyframes) == 1 else WAVE_FRAMES
	t.frames = n
	t.name = strings.clone(name, allocator)
	ae: mem.Allocator_Error
	t.waves, ae = make([][WAVE_SIZE]f32, n, allocator)
	if ae == nil do t.spectra, ae = make([][WAVE_BINS]complex64, n, allocator)
	if ae != nil {
		wavetable_destroy(t, allocator)
		return nil, .Out_Of_Memory
	}
	for f in 0 ..< n {
		if n == 1 {
			mix_keyframes(t.waves[0][:], keyframes, 0, 0, 0)
			continue
		}
		// Frame f between keyframes a and a+1, `u` of the way.
		pos := f64(f) / f64(n - 1) * f64(len(keyframes) - 1)
		a := min(int(pos), len(keyframes) - 2)
		mix_keyframes(t.waves[f][:], keyframes, a, a + 1, f32(pos - f64(a)))
	}
	fft: dsp.Real_Fft
	if e := dsp.real_fft_init(&fft, WAVE_SIZE, allocator = context.temp_allocator); e != .None {
		wavetable_destroy(t, allocator)
		return nil, e
	}
	for f in 0 ..< n {
		dsp.real_fft_forward(&fft, t.waves[f][:], t.spectra[f][:])
		for &b in t.spectra[f] do b *= 1.0 / WAVE_SIZE
	}
	return t, .None
}

// Writes into `out` keyframe `a` crossfaded `u` of the way to keyframe `b`.
@(private)
mix_keyframes :: proc(out: []f32, keys: [][]f32, a, b: int, u: f32) {
	for &v, i in out {
		x := keys[a][i] if i < len(keys[a]) else 0
		y := keys[b][i] if i < len(keys[b]) else 0
		v = x + (y - x) * u
	}
}

// Control thread. Frees a wavetable from `wavetable_make`.
wavetable_destroy :: proc(t: ^Wavetable, allocator := context.allocator) {
	if t == nil do return
	delete(t.name, allocator)
	delete(t.waves, allocator)
	delete(t.spectra, allocator)
	free(t, allocator)
}

// [rt] The frame a position `pos` (0..1 across the table) plays.
wave_frame_at :: proc "contextless" (t: ^Wavetable, pos: f32) -> int {
	if t == nil || t.frames <= 1 do return 0
	return clamp(int(clamp(pos, 0, 1) * f32(t.frames - 1) + 0.5), 0, t.frames - 1)
}

// [rt] The most harmonics a wave can keep at `phase_inc` (cycles per
// sample) without any reaching Nyquist. Above 44.1 kHz it keeps no more
// than it would at the nearest lower rate of 44.1 kHz × a power of two,
// so a higher rate doesn't add harmonics nobody hears.
wave_harmonics :: proc "contextless" (phase_inc: f64, sample_rate: f64) -> int {
	inc := abs(phase_inc)
	mult := 1
	for f64(mult * 2) * 44_100 <= sample_rate do mult *= 2
	inc *= f64(mult)
	if inc <= 0 do return WAVE_BINS - 1
	return clamp(int(0.5 / inc), 0, WAVE_BINS - 1)
}

// [rt] Builds a wave buffer from frame `frame` of `t` keeping harmonics
// 1 ..= `harmonics` (and DC): `out` is `WAVE_SIZE + WAVE_PAD` samples, the
// wave at out[1 ..= WAVE_SIZE] with its ends wrapped around it. `spectrum`
// is `WAVE_BINS` of scratch. With no table, the buffer is silent.
wave_build :: proc "contextless" (fft: ^dsp.Real_Fft, t: ^Wavetable, frame: int, harmonics: int, spectrum: []complex64, out: []f32) #no_bounds_check {
	if t == nil || t.frames == 0 {
		for &v in out[:WAVE_SIZE + WAVE_PAD] do v = 0
		return
	}
	src := &t.spectra[clamp(frame, 0, t.frames - 1)]
	h := clamp(harmonics, 0, WAVE_BINS - 1)
	spectrum[0] = complex(real(src[0]), 0) // DC kept, Nyquist dropped
	for k in 1 ..= h do spectrum[k] = src[k]
	for k in h + 1 ..< WAVE_BINS do spectrum[k] = 0
	dsp.real_fft_inverse(fft, spectrum[:WAVE_BINS], out[1:WAVE_SIZE + 1])
	out[0] = out[WAVE_SIZE]
	out[WAVE_SIZE + 1] = out[1]
	out[WAVE_SIZE + 2] = out[2]
}

// [rt] The wave buffer `buf` (as `wave_build` makes it) read at `phase`
// (0..1), with a Catmull-Rom cubic between samples.
wave_read :: #force_inline proc "contextless" (buf: []f32, phase: f32) -> f32 #no_bounds_check {
	x := phase * WAVE_SIZE
	i := int(x)
	t := x - f32(i)
	i = i & (WAVE_SIZE - 1)
	p0, p1, p2, p3 := buf[i], buf[i + 1], buf[i + 2], buf[i + 3]
	return p1 + 0.5 * t * (p2 - p0 + t * (2 * p0 - 5 * p1 + 4 * p2 - p3 + t * (3 * (p1 - p2) + p3 - p0)))
}

_ :: math.PI
