package pads_model

import "core:fmt"
import "core:strings"

// How the 16 pads play (see `play_mode_note`). The values are saved:
// new modes are appended (the menu orders them as `PLAY_MODES` does).
Play_Mode :: enum u8 {
	Pads,         // each pad plays itself
	Scale,        // the pads are the notes of the project key, played on the selected pad (Keyboard before v41)
	Velocity,     // the pads play the selected pad, softest to loudest
	Chords,       // each pad a chord of the key: degrees across, variations up
	Progressions, // each pad a chord of the progression in use, in its order
}

// The play modes as the menus list them.
PLAY_MODES := [5]Play_Mode{.Pads, .Scale, .Chords, .Progressions, .Velocity}

// Play modes' names, as the UI shows them.
PLAY_MODE_NAMES := [Play_Mode]cstring{.Pads = "Pads", .Scale = "Scale", .Velocity = "Velocity", .Chords = "Chords", .Progressions = "Progressions"}

// Whether mode `m` plays the selected pad's notes from the key (Scale,
// Chords, Progressions): its banks are notes or chords, not pads.
note_mode :: proc "contextless" (m: Play_Mode) -> bool {
	return m == .Scale || m == .Chords || m == .Progressions
}

// The project key's scales. Saved by value: new ones are appended.
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
	Phrygian,
	Lydian,
	Locrian,
	Melodic_Minor,
	Phrygian_Dominant,
	Hungarian_Minor,
	Whole_Tone,
	Diminished_Half_Whole,
	Diminished_Whole_Half,
	In_Sen,
	Hirajoshi,
}

// Scale names, as the UI shows them.
SCALE_NAMES := [Scale]cstring{
	.Chromatic = "Chromatic", .Major = "Major", .Minor = "Minor", .Dorian = "Dorian", .Mixolydian = "Mixolydian",
	.Harmonic_Minor = "Harmonic minor", .Major_Pentatonic = "Major pentatonic", .Minor_Pentatonic = "Minor pentatonic", .Blues = "Blues",
	.Phrygian = "Phrygian", .Lydian = "Lydian", .Locrian = "Locrian", .Melodic_Minor = "Melodic minor",
	.Phrygian_Dominant = "Phrygian dominant", .Hungarian_Minor = "Hungarian minor", .Whole_Tone = "Whole tone",
	.Diminished_Half_Whole = "Diminished (half-whole)", .Diminished_Whole_Half = "Diminished (whole-half)",
	.In_Sen = "Japanese (in-sen)", .Hirajoshi = "Hirajoshi",
}

// The scales as the Key dialog lists them: the common ones first.
SCALE_ORDER := [len(Scale)]Scale{
	.Major, .Minor, .Dorian, .Phrygian, .Lydian, .Mixolydian, .Locrian, .Harmonic_Minor, .Melodic_Minor,
	.Phrygian_Dominant, .Hungarian_Minor, .Major_Pentatonic, .Minor_Pentatonic, .Blues, .Whole_Tone,
	.Diminished_Half_Whole, .Diminished_Whole_Half, .In_Sen, .Hirajoshi, .Chromatic,
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
	@(static, rodata) phrygian := [?]int{0, 1, 3, 5, 7, 8, 10}
	@(static, rodata) lydian := [?]int{0, 2, 4, 6, 7, 9, 11}
	@(static, rodata) locrian := [?]int{0, 1, 3, 5, 6, 8, 10}
	@(static, rodata) melodic := [?]int{0, 2, 3, 5, 7, 9, 11}
	@(static, rodata) phrygian_dom := [?]int{0, 1, 4, 5, 7, 8, 10}
	@(static, rodata) hungarian := [?]int{0, 2, 3, 6, 7, 8, 11}
	@(static, rodata) whole := [?]int{0, 2, 4, 6, 8, 10}
	@(static, rodata) dim_hw := [?]int{0, 1, 3, 4, 6, 7, 9, 10}
	@(static, rodata) dim_wh := [?]int{0, 2, 3, 5, 6, 8, 9, 11}
	@(static, rodata) in_sen := [?]int{0, 1, 5, 7, 10}
	@(static, rodata) hirajoshi := [?]int{0, 2, 3, 7, 8}
	switch s {
	case .Chromatic:             return chromatic[:]
	case .Major:                 return major[:]
	case .Minor:                 return minor[:]
	case .Dorian:                return dorian[:]
	case .Mixolydian:            return mixolydian[:]
	case .Harmonic_Minor:        return harmonic[:]
	case .Major_Pentatonic:      return major_penta[:]
	case .Minor_Pentatonic:      return minor_penta[:]
	case .Blues:                 return blues[:]
	case .Phrygian:              return phrygian[:]
	case .Lydian:                return lydian[:]
	case .Locrian:               return locrian[:]
	case .Melodic_Minor:         return melodic[:]
	case .Phrygian_Dominant:     return phrygian_dom[:]
	case .Hungarian_Minor:       return hungarian[:]
	case .Whole_Tone:            return whole[:]
	case .Diminished_Half_Whole: return dim_hw[:]
	case .Diminished_Whole_Half: return dim_wh[:]
	case .In_Sen:                return in_sen[:]
	case .Hirajoshi:             return hirajoshi[:]
	}
	return chromatic[:]
}

// How a chord's notes are spread over the octaves (after voice leading).
Spread :: enum u8 {
	Close,  // as built: within an octave or so
	Open,   // the second note from the bottom an octave up
	Drop_2, // wide: the second note from the top an octave down
}

// Spread names, as the UI shows them.
SPREAD_NAMES := [Spread]cstring{.Close = "Close", .Open = "Open", .Drop_2 = "Wide (drop 2)"}

// Strum's most, between two notes of a chord.
MAX_STRUM_MS :: 100

// The project key (a root and a scale) and how the note modes play it:
// Scale's octave, the chords' voicing. Saved with the project.
Keys :: struct {
	scale:  Scale,
	root:   int, // 0..11, semitones above C
	octave: int, // -3..3
	no_voice_leading: bool,   // voice leading off (on by default): chords in root position, or the inversion they name
	spread:           Spread,
	strum_ms:         f32,    // 0..MAX_STRUM_MS between a chord's notes, low note first
	chord_page:       int,    // Chords mode: the variations the window's 4 rows show (0: triad to sus2, 1: add9 to 2nd inversion)
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

// Whether `pitch` (semitones from the pad's own note, which is a C) is in
// the key.
in_key :: proc "contextless" (k: Keys, pitch: int) -> bool {
	pc := ((pitch - k.root) % 12 + 12) % 12
	for s in scale_steps(k.scale) do if s == pc do return true
	return false
}

// The key's notes as a mask of pitch classes from C (bit 0 C ... bit 11 B).
key_mask :: proc "contextless" (k: Keys) -> u16 {
	m: u16
	for s in scale_steps(k.scale) do m |= 1 << u16((s + k.root) % 12)
	return m
}

// [rt] `pitch` (from the pad's own note, a C) moved to the nearest note of
// the key whose pitch classes are `mask` (a tie: the lower). Any pitch if
// the mask is empty.
snap_to_key :: proc "contextless" (mask: u16, pitch: int) -> int {
	if mask == 0 do return pitch
	pc :: proc "contextless" (p: int) -> u16 { return u16((p % 12 + 12) % 12) }
	for d in 0 ..= 6 {
		if mask & (1 << pc(pitch - d)) != 0 do return pitch - d
		if mask & (1 << pc(pitch + d)) != 0 do return pitch + d
	}
	return pitch
}

// The pitch Scale mode's pad `pad` (a degree: 0 the key's root) plays.
keyboard_pitch :: proc "contextless" (k: Keys, pad: int) -> int {
	return degree_pitch(k, pad)
}

// Velocity mode: pad `k`'s velocity (the bottom-left softest, the top-right
// loudest).
velocity_of_pad :: proc "contextless" (pad: int) -> f32 {
	return f32(pad + 1) / 16
}

// ---------------------------------------------------------------------------
// Chords

// The chords each degree of the key has, as Chords mode's rows (from the
// bottom). Saved by value in progressions.
Variation :: enum u8 {
	Triad,
	Seventh,
	Sus4,
	Sus2,
	Add9,
	Sixth,
	First_Inversion,  // the triad, its third in the bass
	Second_Inversion, // the triad, its fifth in the bass
}

// Variation names, as the UI shows them.
VARIATION_NAMES := [Variation]cstring{
	.Triad = "Triad", .Seventh = "7th", .Sus4 = "sus4", .Sus2 = "sus2", .Add9 = "add9", .Sixth = "6th",
	.First_Inversion = "1st inversion", .Second_Inversion = "2nd inversion",
}

// The most notes a chord has (a 7th or add9: four; room for a bass note).
MAX_CHORD_NOTES :: 6

// A chord's notes: semitones from the pad's own note, low to high.
Chord_Notes :: struct {
	pitches: [MAX_CHORD_NOTES]int,
	count:   int,
}

// The notes of `c`, as a slice of it.
chord_slice :: proc(c: ^Chord_Notes) -> []int { return c.pitches[:c.count] }

// A triad's kind.
Quality :: enum u8 {
	Major,
	Minor,
	Diminished,
	Augmented,
	Sus4,
	Sus2,
}

// A chord of the key as built: its notes in root position (or the
// inversion its variation names), and what it is, for its name.
Chord :: struct {
	notes:     Chord_Notes,
	ok:        bool,    // the key has the notes it needs (else none: "–")
	root:      int,     // the root's pitch (from the pad's own note)
	quality:   Quality,
	seventh:   int,     // its seventh's semitones above the root (9, 10, 11), or 0
	added:     int,     // an added note's semitones above the root (9: a 6th, 14: a 9th), or 0
	inversion: int,     // 0, 1 (third in the bass), 2 (fifth in the bass)
	degree:    int,     // the degree it is built on (0 the root)
	variation: Variation,
}

// Chord `v` on degree `degree` of key `k` (0 the root; past the key's
// notes, octaves up), made of the key's own notes. A third, fifth, seventh
// or added note the key doesn't have: not ok.
chord_build :: proc(k: Keys, degree: int, v: Variation) -> (c: Chord) {
	c.degree, c.variation = degree, v
	root := degree_pitch(k, degree)
	c.root = root
	has :: proc(k: Keys, root, semis: int) -> bool { return in_key(k, root + semis) }
	pick :: proc(k: Keys, root: int, choices: []int) -> int {
		for x in choices do if has(k, root, x) do return x
		return -1
	}
	add :: proc(c: ^Chord, p: int) {
		c.notes.pitches[c.notes.count] = p
		c.notes.count += 1
	}
	// A 7-note key stacks its own thirds (degree + 2, + 4, + 6: a harmonic
	// minor's G# B D F, not G# C E); others look for the intervals among
	// their notes.
	seven := scale_size(k.scale) == 7
	step :: proc(k: Keys, degree, root, by: int) -> int { return degree_pitch(k, degree + by) - root }
	only :: proc(got, want: int) -> int { return got if got == want else -1 }
	third, fifth := -1, -1
	switch v {
	case .Sus4:
		third, fifth = pick(k, root, []int{5}), pick(k, root, []int{7})
		if seven do third, fifth = only(step(k, degree, root, 3), 5), only(step(k, degree, root, 4), 7)
		c.quality = .Sus4
	case .Sus2:
		third, fifth = pick(k, root, []int{2}), pick(k, root, []int{7})
		if seven do third, fifth = only(step(k, degree, root, 1), 2), only(step(k, degree, root, 4), 7)
		c.quality = .Sus2
	case .Triad, .Seventh, .Add9, .Sixth, .First_Inversion, .Second_Inversion:
		if seven {
			third, fifth = step(k, degree, root, 2), step(k, degree, root, 4)
		} else {
			third = pick(k, root, []int{4, 3})
			if third == 4 do fifth = pick(k, root, []int{7, 8})
			if third == 3 do fifth = pick(k, root, []int{7, 6})
		}
		switch {
		case third == 4 && fifth == 7: c.quality = .Major
		case third == 4 && fifth == 8: c.quality = .Augmented
		case third == 3 && fifth == 7: c.quality = .Minor
		case third == 3 && fifth == 6: c.quality = .Diminished
		case: third = -1 // (no triad of ours: a 7-note key's odd third or fifth)
		}
	}
	if third < 0 || fifth < 0 do return
	add(&c, root)
	add(&c, root + third)
	add(&c, root + fifth)
	#partial switch v {
	case .Seventh:
		choices: []int
		#partial switch c.quality {
		case .Diminished: choices = []int{10, 9}
		case .Augmented:  choices = []int{11, 10}
		case:             choices = []int{10, 11}
		}
		c.seventh = pick(k, root, choices)
		if seven do c.seventh = step(k, degree, root, 6)
		if c.seventh < 9 || c.seventh > 11 do return
		add(&c, root + c.seventh)
	case .Add9:
		if !has(k, root, 14) do return
		c.added = 14
		add(&c, root + 14)
	case .Sixth:
		if (c.quality != .Major && c.quality != .Minor) || !has(k, root, 9) do return
		c.added = 9
		add(&c, root + 9)
	case .First_Inversion:
		c.inversion = 1
		c.notes.pitches[0] += 12
	case .Second_Inversion:
		c.inversion = 2
		c.notes.pitches[0] += 12
		c.notes.pitches[1] += 12
	}
	sort_chord(&c.notes)
	c.ok = true
	return
}

// Sorts a chord's notes low to high.
@(private)
sort_chord :: proc "contextless" (n: ^Chord_Notes) {
	for i in 1 ..< n.count {
		x := n.pitches[i]
		j := i
		for j > 0 && n.pitches[j - 1] > x {
			n.pitches[j] = n.pitches[j - 1]
			j -= 1
		}
		n.pitches[j] = x
	}
}

// How far chord `a` is from chord `b`: each note's distance to the other's
// nearest, both ways (so a triad and a 7th compare too).
@(private)
chord_distance :: proc "contextless" (a, b: Chord_Notes) -> int {
	near :: proc "contextless" (p: int, to: Chord_Notes) -> int {
		best := max(int)
		for i in 0 ..< to.count do best = min(best, abs(p - to.pitches[i]))
		return best
	}
	d := 0
	for i in 0 ..< a.count do d += near(a.pitches[i], b)
	for i in 0 ..< b.count do d += near(b.pitches[i], a)
	return d
}

// Voice leading: of chord `c`'s inversions (each within an octave of where
// it was built), the closest to `prev`, the chord played before. `c` as it
// is when there was none.
voice_lead :: proc "contextless" (c: Chord_Notes, prev: Chord_Notes) -> Chord_Notes {
	if prev.count == 0 || c.count < 2 do return c
	best := c
	best_d := chord_distance(c, prev)
	low := c.pitches[0]
	centre :: proc "contextless" (n: Chord_Notes) -> int {
		s := 0
		for i in 0 ..< n.count do s += n.pitches[i]
		return s
	}
	for inv in 0 ..< c.count do for shift in ([3]int{-12, 0, 12}) {
		x: Chord_Notes
		x.count = c.count
		for i in 0 ..< c.count {
			k := (i + inv) % c.count
			x.pitches[i] = c.pitches[k] + (12 if i + inv >= c.count else 0) + shift
		}
		sort_chord(&x)
		if abs(x.pitches[0] - low) > 12 do continue
		d := chord_distance(x, prev)
		if d < best_d || (d == best_d && abs(centre(x) - centre(c)) < abs(centre(best) - centre(c))) {
			best, best_d = x, d
		}
	}
	return best
}

// Chord `c` spread as `s` says.
spread_chord :: proc "contextless" (c: Chord_Notes, s: Spread) -> Chord_Notes {
	x := c
	if x.count < 3 do return x
	switch s {
	case .Close:
	case .Open:   x.pitches[1] += 12
	case .Drop_2: x.pitches[x.count - 2] -= 12
	}
	sort_chord(&x)
	return x
}

// Chord `v` on degree `degree` as key `k` plays it: voice-led from `prev`
// (unless voice leading is off, or the variation names an inversion), then
// spread. Its notes' count is 0 if the key can't make it.
chord_voiced :: proc(k: Keys, degree: int, v: Variation, prev: Chord_Notes) -> Chord_Notes {
	c := chord_build(k, degree, v)
	if !c.ok do return {}
	n := c.notes
	if !k.no_voice_leading && v != .First_Inversion && v != .Second_Inversion do n = voice_lead(n, prev)
	return spread_chord(n, k.spread)
}

// Note names with sharps, from C.
NOTE_SHARPS := [12]string{"C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"}
// Note names with flats, from C.
NOTE_FLATS := [12]string{"C", "Db", "D", "Eb", "E", "F", "Gb", "G", "Ab", "A", "Bb", "B"}

// Whether key `k` is spelled with flats (F, Bb, Eb, Ab, Db major, and the
// minor keys that share their notes).
key_flats :: proc "contextless" (k: Keys) -> bool {
	steps := scale_steps(k.scale)
	major := false
	for s in steps do if s == 4 do major = true
	rel := k.root if major || k.scale == .Chromatic else (k.root + 3) % 12
	return rel == 5 || rel == 10 || rel == 3 || rel == 8 || rel == 1
}

// The name of pitch class `pc` (0 = C) as key `k` spells it.
note_in_key :: proc(k: Keys, pc: int) -> string {
	x := (pc % 12 + 12) % 12
	return NOTE_FLATS[x] if key_flats(k) else NOTE_SHARPS[x]
}

// The key's name, "C major" (temporary allocator).
key_name :: proc(k: Keys) -> string {
	return fmt.tprintf("%s %s", note_in_key(k, k.root), strings.to_lower(string(SCALE_NAMES[k.scale]), context.temp_allocator))
}

// A chord's symbol, "Dm7" (temporary allocator; "–" for none).
chord_symbol :: proc(k: Keys, c: Chord) -> string {
	if !c.ok do return "–"
	root := note_in_key(k, c.root)
	q: string
	switch c.quality {
	case .Major:      q = ""
	case .Minor:      q = "m"
	case .Diminished: q = "dim"
	case .Augmented:  q = "aug"
	case .Sus4:       q = "sus4"
	case .Sus2:       q = "sus2"
	}
	#partial switch c.variation {
	case .Seventh:
		switch {
		case c.quality == .Major && c.seventh == 11:      q = "maj7"
		case c.quality == .Major:                         q = "7"
		case c.quality == .Minor && c.seventh == 11:      q = "m(maj7)"
		case c.quality == .Minor:                         q = "m7"
		case c.quality == .Diminished && c.seventh == 9:  q = "dim7"
		case c.quality == .Diminished:                    q = "m7b5"
		case c.quality == .Augmented && c.seventh == 11:  q = "maj7#5"
		case c.quality == .Augmented:                     q = "7#5"
		}
	case .Add9:
		q = fmt.tprintf("%sadd9", q) if c.quality == .Major || c.quality == .Minor else fmt.tprintf("%s(add9)", q)
	case .Sixth:
		q = fmt.tprintf("%s6", q)
	case .First_Inversion, .Second_Inversion:
		bass := c.notes.pitches[0]
		return fmt.tprintf("%s%s/%s", root, q, note_in_key(k, bass))
	}
	return fmt.tprintf("%s%s", root, q)
}

// A chord's roman numeral in key `k`, "ii7" (temporary allocator). By the
// key's degrees in a 7-note key, else by semitones from its root (bIII...);
// lower case for minor and diminished chords.
chord_numeral :: proc(k: Keys, c: Chord) -> string {
	@(static, rodata) ROMAN := [7]string{"I", "II", "III", "IV", "V", "VI", "VII"}
	@(static, rodata) BY_SEMITONE := [12]string{"I", "bII", "II", "bIII", "III", "IV", "#IV", "V", "bVI", "VI", "bVII", "VII"}
	n := scale_size(k.scale)
	base: string
	if n == 7 {
		base = ROMAN[(c.degree % 7 + 7) % 7]
	} else {
		base = BY_SEMITONE[((c.root - k.root) % 12 + 12) % 12]
	}
	if c.ok && (c.quality == .Minor || c.quality == .Diminished) do base = strings.to_lower(base, context.temp_allocator)
	if !c.ok do return base
	mark := ""
	if c.quality == .Diminished do mark = "°"
	if c.quality == .Augmented do mark = "+"
	suffix := ""
	#partial switch c.variation {
	case .Seventh:
		switch {
		case c.quality == .Diminished && c.seventh == 10: mark, suffix = "ø", "7"
		case c.seventh == 11:                             suffix = "maj7"
		case:                                             suffix = "7"
		}
	case .Sus4:             suffix = "sus4"
	case .Sus2:             suffix = "sus2"
	case .Add9:             suffix = "add9"
	case .Sixth:            suffix = "6"
	case .First_Inversion:  suffix = "/3"
	case .Second_Inversion: suffix = "/5"
	}
	return fmt.tprintf("%s%s%s", base, mark, suffix)
}

// A chord's name as the pads show it: its numeral and its symbol, "ii7
// Dm7" (temporary allocator; "–" if the key can't make it).
chord_name :: proc(k: Keys, c: Chord) -> string {
	if !c.ok do return "–"
	return fmt.tprintf("%s %s", chord_numeral(k, c), chord_symbol(k, c))
}

// Chords mode's pad `pad` (0..15, the bottom left first) in bank `bank`:
// its degree (four a bank, across) and variation (up, four a page).
chords_pad :: proc "contextless" (k: Keys, bank, pad: int) -> (degree: int, v: Variation) {
	degree = bank * 4 + pad % 4
	row := clamp(k.chord_page, 0, 1) * 4 + pad / 4
	return degree, Variation(clamp(row, 0, int(max(Variation))))
}

// MIDI key `key`'s name, "C3" for 60 (temporary allocator).
midi_note_name :: proc(key: int) -> string {
	k := clamp(key, 0, 127)
	return fmt.tprintf("%s%d", NOTE_SHARPS[k % 12], k / 12 - 2)
}
