package synth

import "core:math"

import "fire:core"

// The wavetables the synth has built in. Each is generated here, from
// shapes and additive recipes; none is copied from anywhere.
Builtin_Table :: enum u8 {
	Basic_Shapes,  // sine, triangle, saw, square, then a narrow pulse
	Saw,
	Sine,
	Square_Pwm,    // a square narrowing to a thin pulse
	Harmonic_Sweep, // a sine gaining harmonics one octave at a time, up to a full saw
	Vowels,        // a buzz through the formants of a, e, i, o, u
	Sync_Saw,      // a saw hard-synced from 1× to 8× its rate
	Drawbars,      // organ registrations, flute to full
}

// The names `builtin_table` gives its tables.
BUILTIN_NAMES := [Builtin_Table]string {
	.Basic_Shapes   = "Basic Shapes",
	.Saw            = "Saw",
	.Sine           = "Sine",
	.Square_Pwm     = "Square PWM",
	.Harmonic_Sweep = "Harmonic Sweep",
	.Vowels         = "Vowels",
	.Sync_Saw       = "Sync Saw",
	.Drawbars       = "Drawbars",
}

// Control thread. Makes built-in table `which` (free with
// `wavetable_destroy`).
builtin_table :: proc(which: Builtin_Table, allocator := context.allocator) -> (^Wavetable, core.Error) {
	tmp := context.temp_allocator
	frame :: proc(allocator := context.temp_allocator) -> []f32 { return make([]f32, WAVE_SIZE, allocator) }
	keys := make([dynamic][]f32, tmp)
	switch which {
	case .Saw:
		append(&keys, shape_frame(.Saw))
	case .Sine:
		append(&keys, shape_frame(.Sine))
	case .Basic_Shapes:
		for s in Shape do append(&keys, shape_frame(s))
	case .Square_Pwm:
		for k in 0 ..< 8 {
			f := frame()
			width := 0.5 - 0.45 * f64(k) / 7
			for &v, i in f do v = 1 if f64(i) / WAVE_SIZE < width else -1
			remove_dc(f)
			append(&keys, f)
		}
	case .Harmonic_Sweep:
		// Harmonics up to 1, 2, 4 ... 512, each 1/n, so the last is a saw.
		for k in 0 ..= 9 {
			top := 1 << uint(k)
			amps := make([]f64, top + 1, tmp)
			for h in 1 ..= top do amps[h] = 1 / f64(h)
			append(&keys, additive(amps))
		}
	case .Vowels:
		// A 110 Hz buzz (harmonic n at 110·n Hz) shaped by each vowel's
		// three formants (centre Hz, width Hz, gain).
		Formant :: struct { f, bw, g: f64 }
		vowels := [5][3]Formant {
			{{800, 80, 1}, {1150, 90, 0.5}, {2900, 120, 0.25}},   // a
			{{400, 60, 1}, {1600, 80, 0.3}, {2700, 120, 0.2}},    // e
			{{270, 60, 1}, {2300, 100, 0.25}, {3000, 120, 0.2}},  // i
			{{450, 70, 1}, {800, 80, 0.4}, {2830, 100, 0.15}},    // o
			{{325, 50, 1}, {700, 60, 0.3}, {2530, 170, 0.1}},     // u
		}
		for v in vowels {
			amps := make([]f64, 200, tmp)
			for h in 1 ..< len(amps) {
				hz := 110 * f64(h)
				a := 0.0
				for fm in v {
					d := (hz - fm.f) / fm.bw
					a += fm.g / (1 + d * d)
				}
				amps[h] = a / math.sqrt(f64(h))
			}
			append(&keys, additive(amps))
		}
	case .Sync_Saw:
		for k in 0 ..< 16 {
			ratio := 1 + 7 * f64(k) / 15
			f := frame()
			for &v, i in f {
				p := math.mod(f64(i) / WAVE_SIZE * ratio, 1)
				v = f32(1 - 2 * p)
			}
			remove_dc(f)
			append(&keys, f)
		}
	case .Drawbars:
		// Registrations over the footages 16', 8', 5 1/3', 4', 2 2/3', 2',
		// 1 3/5', 1 1/3', 1' (harmonics 1, 2, 3, 4, 6, 8, 10, 12, 16 of 16').
		feet := [9]int{1, 2, 3, 4, 6, 8, 10, 12, 16}
		settings := [6][9]f64 {
			{0, 8, 0, 0, 0, 0, 0, 0, 0}, // flute
			{8, 8, 0, 0, 0, 0, 0, 0, 0},
			{8, 8, 8, 0, 0, 0, 0, 0, 0},
			{8, 8, 8, 8, 0, 0, 0, 0, 0},
			{8, 8, 8, 8, 8, 8, 0, 0, 0},
			{8, 8, 8, 8, 8, 8, 8, 8, 8}, // full
		}
		for s in settings {
			amps := make([]f64, 17, tmp)
			for d, i in s do amps[feet[i]] = math.pow(10, (d - 8) * 3 / 20) if d > 0 else 0
			append(&keys, additive(amps))
		}
	}
	return wavetable_make(BUILTIN_NAMES[which], keys[:], allocator)
}

// The basic shapes a frame can be.
@(private)
Shape :: enum u8 {Sine, Triangle, Saw, Square, Pulse}

// One frame of a basic shape, peak 1 (temporary allocator).
@(private)
shape_frame :: proc(s: Shape) -> []f32 {
	f := make([]f32, WAVE_SIZE, context.temp_allocator)
	for &v, i in f {
		p := f64(i) / WAVE_SIZE
		switch s {
		case .Sine:     v = f32(math.sin(math.TAU * p))
		case .Triangle: v = f32(1 - 4 * abs(math.mod(p + 0.25, 1) - 0.5))
		case .Saw:      v = f32(1 - 2 * math.mod(p + 0.5, 1)) // falls through zero mid-cycle, like a sine starts
		case .Square:   v = 1 if p < 0.5 else -1
		case .Pulse:    v = 1 if p < 0.125 else -1
		}
	}
	remove_dc(f)
	return f
}

// A frame of sines: harmonic h at amplitude `amps[h]` (h ≥ 1), all
// starting in phase, scaled to peak 1 (temporary allocator).
@(private)
additive :: proc(amps: []f64) -> []f32 {
	f := make([]f32, WAVE_SIZE, context.temp_allocator)
	for h in 1 ..< min(len(amps), WAVE_SIZE / 2) do if amps[h] != 0 {
		for &v, i in f do v += f32(amps[h] * math.sin(math.TAU * f64(h) * f64(i) / WAVE_SIZE))
	}
	peak: f32 = 0
	for v in f do peak = max(peak, abs(v))
	if peak > 0 do for &v in f do v /= peak
	return f
}

// Takes a frame's mean out (so a shape has no DC), then scales it to
// peak 1.
@(private)
remove_dc :: proc(f: []f32) {
	mean: f64 = 0
	for v in f do mean += f64(v)
	mean /= f64(len(f))
	peak: f32 = 0
	for &v in f {
		v -= f32(mean)
		peak = max(peak, abs(v))
	}
	if peak > 0 do for &v in f do v /= peak
}
