package synth

import "core:math"
import "core:strings"

import "fire:core"
import "fire:dsp"

// A wavetable as an editor keeps it: up to `TABLE_KEYS` keyframes, each
// at a frame of the table and made one of four ways (a drawn wave, line
// shapes, harmonics or a slice of audio), and how the frames between
// them blend. `table_doc_build` makes the `Wavetable` an oscillator
// plays.
//
//	doc := synth.table_doc_default() // a sine at frame 0, a saw at the end
//	doc.keys[1].levels[2] = 0        // the saw without its third harmonic
//	t, _ := synth.table_doc_build("Mine", &doc, nil)
//	defer synth.wavetable_destroy(t)

// The most keyframes a table has.
TABLE_KEYS :: 16
// Points a drawn keyframe has across its cycle.
DRAW_POINTS :: 256
// The most points a line-shape keyframe has.
LINE_POINTS :: 32
// Harmonics a harmonics keyframe sets.
TABLE_HARMONICS :: 64

// How a keyframe is made.
Key_Source :: enum u8 {
	Draw,      // `draw`: the cycle as drawn, a point each 1/256th
	Lines,     // `points`: joined by curves (each its `powers`)
	Harmonics, // `levels` and `phases` of harmonics 1 .. 64
	Audio,     // a cycle of the table's audio, from `audio_at` on
}

// How the frames between keyframes are made.
Table_Blend :: enum u8 {
	Crossfade, // a mix of the two keyframes' waves
	Spectral,  // each harmonic's level and phase glided apart
}

// A keyframe.
Table_Key :: struct {
	position:    int, // its frame (0 ..< WAVE_FRAMES)
	source:      Key_Source,
	draw:        [DRAW_POINTS]f32, // -1..1
	points:      [LINE_POINTS][2]f32, // x 0..1 (rising), y -1..1
	powers:      [LINE_POINTS]f32, // the curve from each point to the next
	point_count: int,
	levels:      [TABLE_HARMONICS]f32, // 0..1
	phases:      [TABLE_HARMONICS]f32, // 0..1 (of a cycle)
	audio_at:    f32, // 0..1: where in the audio its cycle starts
}

// A wavetable to edit: its keyframes (`count` of them, in `keys`) and its
// blend.
Table_Doc :: struct {
	keys:  [TABLE_KEYS]Table_Key,
	count: int,
	blend: Table_Blend,
}

// A keyframe made `source` way, with every way's data set to something
// to start from: a sine (drawn, as lines, as its first harmonic).
table_key_default :: proc(source: Key_Source, position := 0) -> (k: Table_Key) {
	k.position = position
	k.source = source
	for &v, i in k.draw do v = math.sin(math.TAU * f32(i) / DRAW_POINTS)
	k.points[0], k.points[1], k.points[2], k.points[3], k.points[4] = {0, 0}, {0.25, 1}, {0.5, 0}, {0.75, -1}, {1, 0}
	k.powers[0], k.powers[1], k.powers[2], k.powers[3] = -1.5, 1.5, -1.5, 1.5
	k.point_count = 5
	k.levels[0] = 1
	return
}

// A table to start editing: a sine at the first frame, a saw (its 64
// harmonics) at the last, spectrally blended.
table_doc_default :: proc() -> (d: Table_Doc) {
	d.keys[0] = table_key_default(.Harmonics, 0)
	d.keys[1] = table_key_default(.Harmonics, WAVE_FRAMES - 1)
	for h in 0 ..< TABLE_HARMONICS do d.keys[1].levels[h] = 1 / f32(h + 1)
	d.count = 2
	d.blend = .Spectral
	return
}

// Keyframe `k` as a cycle into `out` (`WAVE_SIZE`); `audio` is the
// table's sound (mono), for an audio keyframe.
table_key_render :: proc(k: ^Table_Key, audio: []f32, out: []f32) {
	n := len(out)
	switch k.source {
	case .Draw:
		for &v, i in out {
			x := f32(i) * DRAW_POINTS / f32(n)
			j := int(x)
			t := x - f32(j)
			v = k.draw[j % DRAW_POINTS] + (k.draw[(j + 1) % DRAW_POINTS] - k.draw[j % DRAW_POINTS]) * t
		}
	case .Lines:
		c := clamp(k.point_count, 1, LINE_POINTS)
		for &v, i in out {
			x := f32(i) / f32(n)
			// The segment it is in (past the last point: from it to the first, a cycle on).
			seg := c - 1
			for p in 0 ..< c - 1 do if x < k.points[p + 1][0] {
				seg = p
				break
			}
			if x < k.points[0][0] do seg = c - 1
			a := k.points[seg]
			b := k.points[(seg + 1) % c]
			bx := b[0] if seg + 1 < c else b[0] + 1
			ax := a[0] if !(seg == c - 1 && x < k.points[0][0]) else a[0] - 1
			span := bx - ax
			t := clamp((x - ax) / span, 0, 1) if span > 1e-6 else 0
			v = a[1] + (b[1] - a[1]) * power_scale(t, k.powers[seg])
		}
	case .Harmonics:
		for &v in out do v = 0
		peak: f32 = 0
		for h in 0 ..< TABLE_HARMONICS {
			lv := k.levels[h]
			if lv <= 0 do continue
			ph := k.phases[h] * math.TAU
			step := math.TAU * f32(h + 1) / f32(n)
			for &v, i in out do v += lv * math.sin(step * f32(i) + ph)
		}
		for v in out do peak = max(peak, abs(v))
		if peak > 1 do for &v in out do v /= peak
	case .Audio:
		if len(audio) == 0 {
			for &v in out do v = 0
			return
		}
		if len(audio) < n { // shorter than a cycle: stretched into one
			for &v, i in out {
				x := f64(i) * f64(len(audio)) / f64(n)
				j := int(x)
				v = audio[j] + (audio[(j + 1) % len(audio)] - audio[j]) * f32(x - f64(j))
			}
			return
		}
		at := int(clamp(k.audio_at, 0, 1) * f32(len(audio) - n))
		copy(out, audio[at:at + n])
	}
}

// Control thread. The wavetable `d` makes, called `name`: one frame for
// one keyframe, else `WAVE_FRAMES` with each keyframe at its frame (the
// first held back to frame 0, the last on to the end) and those between
// blended. `audio` (mono) is what audio keyframes slice. Free with
// `wavetable_destroy`.
table_doc_build :: proc(name: string, d: ^Table_Doc, audio: []f32, allocator := context.allocator) -> (t: ^Wavetable, err: core.Error) {
	count := clamp(d.count, 1, TABLE_KEYS)
	// The keyframes in frame order.
	order: [TABLE_KEYS]int
	for i in 0 ..< count do order[i] = i
	for i in 1 ..< count {
		j := i
		for j > 0 && d.keys[order[j]].position < d.keys[order[j - 1]].position {
			order[j], order[j - 1] = order[j - 1], order[j]
			j -= 1
		}
	}
	waves := make([][WAVE_SIZE]f32, count, context.temp_allocator)
	for i in 0 ..< count do table_key_render(&d.keys[order[i]], audio, waves[i][:])
	n := 1 if count == 1 else WAVE_FRAMES
	t = new(Wavetable, allocator)
	t.name = strings.clone(name, allocator)
	t.frames = n
	t.waves = make([][WAVE_SIZE]f32, n, allocator)
	t.spectra = make([][WAVE_BINS]complex64, n, allocator)
	fft: dsp.Real_Fft
	dsp.real_fft_init(&fft, WAVE_SIZE, allocator = context.temp_allocator) or_return
	if n == 1 {
		t.waves[0] = waves[0]
		dsp.real_fft_forward(&fft, t.waves[0][:], t.spectra[0][:])
		for &b in t.spectra[0] do b *= 1.0 / WAVE_SIZE
		return t, .None
	}
	specs := make([][WAVE_BINS]complex64, count, context.temp_allocator)
	for i in 0 ..< count {
		dsp.real_fft_forward(&fft, waves[i][:], specs[i][:])
		for &b in specs[i] do b *= 1.0 / WAVE_SIZE
	}
	for f in 0 ..< n {
		// The keyframes either side (the same one, before the first or after the last).
		hi := 0
		for hi < count && clamp(d.keys[order[hi]].position, 0, n - 1) < f do hi += 1
		lo := max(hi - 1, 0)
		hi = min(hi, count - 1)
		pa := clamp(d.keys[order[lo]].position, 0, n - 1)
		pb := clamp(d.keys[order[hi]].position, 0, n - 1)
		u: f32 = 0
		if pb > pa do u = clamp(f32(f - pa) / f32(pb - pa), 0, 1)
		if f >= pb do u = 1
		if f <= pa do u = 0
		switch d.blend {
		case .Crossfade:
			for s in 0 ..< WAVE_SIZE do t.waves[f][s] = waves[lo][s] + (waves[hi][s] - waves[lo][s]) * u
			dsp.real_fft_forward(&fft, t.waves[f][:], t.spectra[f][:])
			for &b in t.spectra[f] do b *= 1.0 / WAVE_SIZE
		case .Spectral:
			for k in 0 ..< WAVE_BINS {
				a, b := specs[lo][k], specs[hi][k]
				ma, mb := abs(a), abs(b)
				// Phases glided the short way round (a silent one takes the other's).
				fa := math.atan2(imag(a), real(a)) if ma > 1e-9 else math.atan2(imag(b), real(b))
				fb := math.atan2(imag(b), real(b)) if mb > 1e-9 else fa
				turn := fb - fa
				turn -= math.TAU * math.round(turn / math.TAU)
				m := ma + (mb - ma) * u
				ph := fa + turn * u
				t.spectra[f][k] = complex(m * math.cos(ph), m * math.sin(ph))
			}
			t.spectra[f][0] = complex(real(specs[lo][0]) + (real(specs[hi][0]) - real(specs[lo][0])) * u, 0)
			spec := t.spectra[f] // (stored as an inverse gives the wave straight back)
			dsp.real_fft_inverse(&fft, spec[:], t.waves[f][:])
		}
	}
	return t, .None
}
