package synth

import "core:math"
import "core:mem"
import "core:strings"

import "fire:core"

// Halvings of a `Sample` kept, each half the length of the one before,
// for playing fast without aliasing.
SAMPLE_LEVELS :: 8

// Samples of padding after each level's end (and its wrap), for a cubic
// read.
@(private)
SAMPLE_PAD :: 4

// A sound the sample oscillator plays: one or two channels at `rate`,
// with copies at half, a quarter ... of the length (each low-passed
// first), so that played above its own rate it reads the copy whose
// rate the pitch needs. Made with `sample_make`; read-only once made.
Sample :: struct {
	name:   string,
	rate:   f64,
	frames: int,
	levels: [SAMPLE_LEVELS][2][]f32, // [level][channel]; a mono sample's right is its left
	count:  int,                     // levels made
}

// Noise colours the sample oscillator has built in (a second of each,
// generated).
Builtin_Noise :: enum u8 {White, Pink, Brown}

// The names `builtin_noise` gives its samples.
BUILTIN_NOISE_NAMES := [Builtin_Noise]string{.White = "White Noise", .Pink = "Pink Noise", .Brown = "Brown Noise"}

// Control thread. A sample from `channels` (one or two, equal length)
// at `rate`. Free with `sample_destroy`.
sample_make :: proc(name: string, channels: [][]f32, rate: f64, allocator := context.allocator) -> (s: ^Sample, err: core.Error) {
	if len(channels) == 0 || len(channels[0]) == 0 do return nil, .Invalid_Argument
	s = new(Sample, allocator)
	if s == nil do return nil, .Out_Of_Memory
	s.name = strings.clone(name, allocator)
	s.rate = rate
	s.frames = len(channels[0])
	n := s.frames
	for level in 0 ..< SAMPLE_LEVELS {
		if n < 16 && level > 0 do break
		for ch in 0 ..< 2 {
			buf, ae := make([]f32, n + SAMPLE_PAD, allocator)
			if ae != nil {
				sample_destroy(s, allocator)
				return nil, .Out_Of_Memory
			}
			s.levels[level][ch] = buf
			if level == 0 {
				src := channels[min(ch, len(channels) - 1)]
				copy(buf, src[:min(len(src), n)])
			} else {
				halve(s.levels[level - 1][ch][:n * 2], buf[:n])
			}
			for k in 0 ..< SAMPLE_PAD do buf[n + k] = buf[k % n] // wraps, for a loop
		}
		s.count = level + 1
		n /= 2
	}
	return s, .None
}

// Half of `src` into `dst` (len(src)/2): low-passed below the new
// Nyquist by a short windowed-sinc half-band, then every other sample.
@(private)
halve :: proc(src, dst: []f32) {
	TAPS :: [?]f32{-0.0165, 0, 0.0525, 0, -0.1202, 0, 0.3136, 0.5, 0.3136, 0, -0.1202, 0, 0.0525, 0, -0.0165}
	taps := TAPS
	half := len(taps) / 2
	for &v, i in dst {
		acc: f32 = 0
		c := 2 * i
		for t, k in taps do if t != 0 {
			j := c + k - half
			if j >= 0 && j < len(src) do acc += t * src[j]
		}
		v = acc
	}
}

// Control thread. Frees a sample from `sample_make`.
sample_destroy :: proc(s: ^Sample, allocator := context.allocator) {
	if s == nil do return
	for level in s.levels do for ch in level do delete(ch, allocator)
	delete(s.name, allocator)
	free(s, allocator)
}

// Control thread. Built-in noise `which`: a second at 44.1 kHz, peak 0.9.
builtin_noise :: proc(which: Builtin_Noise, allocator := context.allocator) -> (^Sample, core.Error) {
	N :: 44_100
	x := make([]f32, N, context.temp_allocator)
	rng: u32 = 0x9e3779b9
	white :: proc(rng: ^u32) -> f32 { return f32(next_random(rng)) / 2147483648.0 - 1 }
	switch which {
	case .White:
		for &v in x do v = white(&rng)
	case .Pink: // Paul Kellet's economy filter on white noise
		b0, b1, b2: f32
		for &v in x {
			w := white(&rng)
			b0 = 0.99765 * b0 + w * 0.0990460
			b1 = 0.96300 * b1 + w * 0.2965164
			b2 = 0.57000 * b2 + w * 1.0526913
			v = b0 + b1 + b2 + w * 0.1848
		}
	case .Brown: // integrated white noise, leaking back to the middle
		acc: f32
		for &v in x {
			acc = acc * 0.998 + white(&rng) * 0.05
			v = acc
		}
	}
	mean: f64
	for v in x do mean += f64(v)
	mean /= N
	peak: f32
	for &v in x {
		v -= f32(mean)
		peak = max(peak, abs(v))
	}
	for &v in x do v *= 0.9 / peak
	return sample_make(BUILTIN_NOISE_NAMES[which], {x}, 44_100, allocator)
}

// What the sample oscillator plays for one render.
Sample_Params :: struct {
	sample:       ^Sample,
	keytrack:     bool, // the note sets its rate (C3, 60, plays it as recorded); off, it plays at its own rate
	transpose:    f32,  // semitones
	level:        f32,  // amplitude (already squared)
	pan:          f32,
	loop:         bool,
	bounce:       bool, // with loop: forwards, then backwards, and again
	random_phase: bool, // a note starts it somewhere at random
}

// The sample oscillator of one voice. Zero it, then `sample_osc_start`.
Sample_Osc :: struct {
	pos:      f64,  // where it reads, in frames of the sample
	backward: bool, // bouncing back
	done:     bool, // played to its end (not looping)
	pan:      [2]f32,
	last_pan: [2]f32,
	started:  bool,
}

// [rt] A note starts it (at its start, or at random).
sample_osc_start :: proc "contextless" (o: ^Sample_Osc, p: ^Sample_Params, seed: u32) {
	o^ = {}
	if p.random_phase && p.sample != nil {
		rng := seed * 2654435761 + 12345
		o.pos = f64(next_random(&rng)) / 4294967296.0 * f64(p.sample.frames)
	}
}

// [rt] Renders the sample oscillator: `note` is the note's pitch as a
// key (fractional, glide in it) at the render's end; it writes (not adds)
// its stereo output, and `raw` (before level and pan; may be nil).
sample_osc_render :: proc "contextless" (o: ^Sample_Osc, p: ^Sample_Params, note: f32, out_l, out_r: []f32, raw: ^[2][]f32, sample_rate: f64) #no_bounds_check {
	n := len(out_l)
	pan := clamp(p.pan, -1, 1)
	o.pan = {math.sin((1 - pan) * math.PI / 4) * math.SQRT_TWO, math.sin((1 + pan) * math.PI / 4) * math.SQRT_TWO}
	if !o.started {
		o.last_pan = o.pan
		o.started = true
	}
	s := p.sample
	if s == nil || o.done {
		for i in 0 ..< n do out_l[i], out_r[i] = 0, 0
		if raw != nil do for i in 0 ..< n do raw[0][i], raw[1][i] = 0, 0
		return
	}
	semis := f64(p.transpose)
	if p.keytrack do semis += f64(note) - 60
	speed := math.pow(2, semis / 12) * s.rate / sample_rate // frames of the sample a frame
	// The level whose rate keeps the pitch at no more than one of its
	// frames a frame.
	level := 0
	for level + 1 < s.count && speed / f64(int(1) << uint(level)) > 1 do level += 1
	scale := f64(int(1) << uint(level))
	frames := f64(s.frames)
	inv := 1 / f32(max(n, 1))
	for i in 0 ..< n {
		// Read both channels at the position, on its level.
		x := o.pos / scale
		j := int(x)
		t := f32(x - f64(j))
		l := cubic(s.levels[level][0], j, t)
		r := cubic(s.levels[level][1], j, t)
		if raw != nil do raw[0][i], raw[1][i] = l, r
		u := f32(i + 1) * inv
		out_l[i] = l * (o.last_pan[0] + (o.pan[0] - o.last_pan[0]) * u) * p.level
		out_r[i] = r * (o.last_pan[1] + (o.pan[1] - o.last_pan[1]) * u) * p.level
		// Move on: forwards, or back when bouncing; loop or stop at the end.
		o.pos += -speed if o.backward else speed
		if o.pos >= frames {
			switch {
			case p.loop && p.bounce:
				o.pos = 2 * frames - o.pos - 1
				o.backward = true
			case p.loop:
				o.pos = math.mod(o.pos, frames)
			case:
				o.done = true
				for k in i + 1 ..< n do out_l[k], out_r[k] = 0, 0
				if raw != nil do for k in i + 1 ..< n do raw[0][k], raw[1][k] = 0, 0
				break
			}
		} else if o.pos < 0 {
			o.pos = -o.pos
			o.backward = false
		}
		if o.done do break
	}
	o.last_pan = o.pan
}

// [rt] A Catmull-Rom read of `buf` between samples j and j+1 (j may be
// the last: the padding wraps).
@(private)
cubic :: #force_inline proc "contextless" (buf: []f32, j: int, t: f32) -> f32 #no_bounds_check {
	n := len(buf) - SAMPLE_PAD
	i := clamp(j, 0, n - 1)
	p0 := buf[i - 1] if i > 0 else buf[n - 1]
	p1, p2, p3 := buf[i], buf[i + 1], buf[i + 2]
	return p1 + 0.5 * t * (p2 - p0 + t * (2 * p0 - 5 * p1 + 4 * p2 - p3 + t * (3 * (p1 - p2) + p3 - p0)))
}

_ :: mem.Allocator
