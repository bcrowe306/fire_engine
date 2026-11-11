package pads_model

// How the 16 pads play (see `play_mode_note`).
Play_Mode :: enum u8 {
	Pads,     // each pad plays itself
	Keyboard, // the pads are the notes of a scale, played on the selected pad
	Velocity, // the pads play the selected pad, softest to loudest
}

// Scales for keyboard mode.
Scale :: enum u8 {
	Chromatic,
	Major,
	Minor,
	Dorian,
	Mixolydian,
	Harmonic_Minor,
	Major_Pentatonic,
	Minor_Pentatonic,
	Blues,
}

// Scale names, as the UI shows them.
SCALE_NAMES := [Scale]cstring{
	.Chromatic = "Chromatic", .Major = "Major", .Minor = "Minor", .Dorian = "Dorian", .Mixolydian = "Mixolydian",
	.Harmonic_Minor = "Harmonic minor", .Major_Pentatonic = "Major pentatonic", .Minor_Pentatonic = "Minor pentatonic", .Blues = "Blues",
}

// The scale's steps within an octave, in semitones from the root.
scale_steps :: proc "contextless" (s: Scale) -> []int {
	@(static, rodata) chromatic := [?]int{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11}
	@(static, rodata) major := [?]int{0, 2, 4, 5, 7, 9, 11}
	@(static, rodata) minor := [?]int{0, 2, 3, 5, 7, 8, 10}
	@(static, rodata) dorian := [?]int{0, 2, 3, 5, 7, 9, 10}
	@(static, rodata) mixolydian := [?]int{0, 2, 4, 5, 7, 9, 10}
	@(static, rodata) harmonic := [?]int{0, 2, 3, 5, 7, 8, 11}
	@(static, rodata) major_penta := [?]int{0, 2, 4, 7, 9}
	@(static, rodata) minor_penta := [?]int{0, 3, 5, 7, 10}
	@(static, rodata) blues := [?]int{0, 3, 5, 6, 7, 10}
	switch s {
	case .Chromatic:        return chromatic[:]
	case .Major:            return major[:]
	case .Minor:            return minor[:]
	case .Dorian:           return dorian[:]
	case .Mixolydian:       return mixolydian[:]
	case .Harmonic_Minor:   return harmonic[:]
	case .Major_Pentatonic: return major_penta[:]
	case .Minor_Pentatonic: return minor_penta[:]
	case .Blues:            return blues[:]
	}
	return chromatic[:]
}

// Chords keyboard mode can play on every pad: stacked thirds of the scale.
Chord :: enum u8 {
	Off,     // one note
	Triad,   // root, third, fifth (of the scale: diatonic)
	Seventh, // and the seventh
	Power,   // root and fifth
}

// Chord names, as the UI shows them.
CHORD_NAMES := [Chord]cstring{.Off = "Single notes", .Triad = "Triads", .Seventh = "Sevenths", .Power = "Power chords"}

// Keyboard mode's layout: a scale from a root, starting `octave` octaves
// from the pad's own pitch, chords or single notes.
Keys :: struct {
	scale:  Scale,
	root:   int, // 0..11, semitones above C
	octave: int, // -3..3
	chord:  Chord,
}

// Notes an octave of `s` has.
scale_size :: proc "contextless" (s: Scale) -> int { return len(scale_steps(s)) }

// The pitch (semitones from the pad's own) of scale degree `degree` (0 =
// the root; 7 in a 7-note scale is the root an octave up).
degree_pitch :: proc "contextless" (k: Keys, degree: int) -> int {
	steps := scale_steps(k.scale)
	n := len(steps)
	oct := degree / n if degree >= 0 else (degree - n + 1) / n
	d := degree - oct * n
	return k.root + steps[d] + 12 * (oct + k.octave)
}

// The pitches pad `k` (0..15, numbered from the bottom left as the grid
// is: pad 1 the lowest) plays in keyboard mode: one, or a chord.
keyboard_pitches :: proc(k: Keys, pad: int, out: ^[4]int) -> []int {
	degree := pad
	switch k.chord {
	case .Off:
		out[0] = degree_pitch(k, degree)
		return out[:1]
	case .Triad:
		for i in 0 ..< 3 do out[i] = degree_pitch(k, degree + 2 * i)
		return out[:3]
	case .Seventh:
		for i in 0 ..< 4 do out[i] = degree_pitch(k, degree + 2 * i)
		return out[:4]
	case .Power:
		out[0] = degree_pitch(k, degree)
		out[1] = degree_pitch(k, degree + (4 if len(scale_steps(k.scale)) >= 7 else 3))
		if k.scale == .Chromatic do out[1] = out[0] + 7
		return out[:2]
	}
	return out[:0]
}

// Velocity mode: pad `k`'s velocity (the bottom-left softest, the top-right
// loudest).
velocity_of_pad :: proc "contextless" (pad: int) -> f32 {
	return f32(pad + 1) / 16
}
