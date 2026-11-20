package pads_api

import "core:fmt"
import "core:path/filepath"
import "core:strings"

import pc "../core"
import pm "../model"

// How the pads play. (Values kept: new modes are appended.)
Play_Mode :: enum i32 {
	Pads,         // each pad its own sound
	Scale,        // the pads are the project key's notes, played on the selected pad (Keyboard before)
	Velocity,     // the pads play the selected pad, softest to loudest
	Chords,       // each pad a chord of the key on the selected pad: degrees across, variations up
	Progressions, // each pad a chord of the progression in use, in its order
}

// The project key's scales (values kept: new ones are appended).
Scale :: enum i32 {
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

// Scale mode's chords, as `perform_set_keys` and `Perform_State` had them
// (Keyboard mode's setting before Chords mode): Off is Scale mode, any
// other Chords mode.
Chord :: enum i32 {
	Off,   // one note
	Triad,
	Seventh,
	Power,
}

// The chords each degree of the key has (Chords mode's rows, from the
// bottom).
Variation :: enum i32 {
	Triad,
	Seventh,
	Sus4,
	Sus2,
	Add9,
	Sixth,
	First_Inversion,  // the triad, its third in the bass
	Second_Inversion, // the triad, its fifth in the bass
}

// How a chord's notes are spread.
Spread :: enum i32 {
	Close,  // as built
	Open,   // the second note from the bottom an octave up
	Drop_2, // wide: the second note from the top an octave down
}

// How the pads play now.
Perform_State :: struct {
	play_mode: Play_Mode,
	bank:      i64, // 0..7 (A..H; Scale: a range of notes; Chords: of degrees, four a bank)
	selected:  i64, // the selected pad: what the note modes and Velocity play, the keys play, the editors show
	scale:     Scale,
	root:      i64, // 0..11, semitones above C
	octave:    i64, // -3..3
	chord:     Chord, // Triad in Chords mode, else Off (see `Chord`)
	chord_page: i64, // Chords mode: 0 the rows triad..sus2, 1 add9..2nd inversion
}

// How the pads play now.
perform_state :: proc(api: ^Api) -> (Perform_State, Result) {
	c := api.core
	k := c.keys
	return {play_mode = Play_Mode(c.play_mode), bank = i64(c.bank), selected = i64(c.selected), scale = Scale(k.scale), root = i64(k.root), octave = i64(k.octave), chord = .Triad if c.play_mode == .Chords else .Off, chord_page = i64(k.chord_page)}, .Ok
}

// Whether the toolbar's note repeat is on (every pad held repeats at its
// rate and gate: the settings "note_repeat.rate" and "note_repeat.gate").
perform_note_repeat :: proc(api: ^Api) -> (bool, Result) {
	return api.core.m.engine.repeat_all, .Ok
}

// Turns the toolbar's note repeat on or off (a controller's Repeat: held,
// on while it is; Shift + Repeat latches it).
perform_set_note_repeat :: proc(api: ^Api, on: bool) -> Result {
	api.core.m.engine.repeat_all = on
	return .Ok
}

// Plays the pads as `mode` (the pads held let go first; Scale opens on
// the bank holding the pad's own note, Chords and Progressions on bank A;
// Progressions with no progression in use takes the bank's first).
perform_set_play_mode :: proc(api: ^Api, mode: Play_Mode) -> Result {
	if mode < min(Play_Mode) || mode > max(Play_Mode) do return fail(api, .Invalid_Argument, "no such play mode")
	pc.set_play_mode(api.core, pm.Play_Mode(mode))
	return .Ok
}

// Shows bank `bank` (0..7) of the pads.
perform_set_bank :: proc(api: ^Api, bank: i64) -> Result {
	if bank < 0 || bank >= pm.BANKS do return fail(api, .Invalid_Argument, "a bank is 0..7")
	api.core.bank = int(bank)
	return .Ok
}

// Chords mode's rows: `page` 0 the triads, 7ths, sus4s and sus2s (from the
// bottom), 1 the add9s, 6ths, first and second inversions. Saved with the
// project.
perform_set_chord_page :: proc(api: ^Api, page: i64) -> Result {
	if page < 0 || page > 1 do return fail(api, .Invalid_Argument, "the page is 0 or 1")
	api.core.keys.chord_page = int(page)
	return .Ok
}

// Selects pad `pad` (in Pads mode, its bank shown).
perform_select_pad :: proc(api: ^Api, pad: i64) -> Result {
	if _, r := pad_of(api, pad); r != .Ok do return r
	c := api.core
	c.selected = int(pad)
	if !pm.note_mode(c.play_mode) do c.bank = int(pad) / pm.PADS_PER_BANK
	return .Ok
}

// Every pad hit at full velocity (a controller's Accent: the window's and
// MIDI's hits alike, recorded so too), or as played. Not saved.
perform_set_accent :: proc(api: ^Api, on: bool) -> Result {
	pm.set_accent(&api.core.m.engine, on)
	return .Ok
}

// Whether every pad hit plays at full velocity.
perform_accent :: proc(api: ^Api) -> (bool, Result) {
	return pm.accent_on(&api.core.m.engine), .Ok
}

// The project key's scale and root (0..11), Scale mode's octave (-3..3),
// and `chord`: Off plays Chords mode as Scale, any other Scale mode as
// Chords (what Keyboard mode's chords became); else the mode stays. Saved
// with the project (not an edit). See `key_set`.
perform_set_keys :: proc(api: ^Api, scale: Scale, root: i64, octave: i64, chord: Chord) -> Result {
	if scale < min(Scale) || scale > max(Scale) || chord < min(Chord) || chord > max(Chord) do return fail(api, .Invalid_Argument, "no such scale or chord")
	if root < 0 || root > 11 || octave < -3 || octave > 3 do return fail(api, .Invalid_Argument, "the root is 0..11, the octave -3..3")
	c := api.core
	c.keys.scale, c.keys.root, c.keys.octave = pm.Scale(scale), int(root), int(octave)
	if chord == .Off && c.play_mode == .Chords do pc.set_play_mode(c, .Scale)
	if chord != .Off && c.play_mode == .Scale do pc.set_play_mode(c, .Chords)
	return .Ok
}

// One of the note modes' keys: what pressing it plays.
Perform_Key :: struct {
	pitch:    i64,  // semitones from the selected pad's own note (a chord's lowest; a slicer's: its slice)
	root:     bool, // the key's root (a chord: built on it; a slicer's: its first slice)
	playable: bool, // within what a pad can be pitched to, and a chord the key can make (else it plays nothing)
	count:    i64,  // notes it plays (a chord's several)
	chord:    bool, // a chord of Chords or Progressions mode
}

// The note modes' key `key` (0..127: 0 the shown bank's first pad, 16 the
// next bank's first...): what it plays on the selected pad in the play
// mode now (Scale's note, Chords' or Progressions' chord; Pads and
// Velocity: as Scale).
perform_key :: proc(api: ^Api, key: i64) -> (Perform_Key, Result) {
	if key < 0 || key >= PADS do return {}, fail(api, .Invalid_Argument, "a key is 0..127")
	k := pc.keyboard_notes(api.core, int(key))
	ps := pm.chord_slice(&k.notes)
	return {pitch = i64(ps[0]) if len(ps) > 0 else 0, root = pc.keyboard_root(api.core, int(key)), playable = pc.keyboard_in_range(ps), count = i64(len(ps)), chord = k.chords}, .Ok
}

// What the note modes' key `key` shows: a note ("C3"), a slice ("Slice
// 2"), or a chord ("ii7 Dm7"; "–" if the key can't make it). Temporary.
perform_key_name :: proc(api: ^Api, key: i64) -> (string, Result) {
	if key < 0 || key >= PADS do return "", fail(api, .Invalid_Argument, "a key is 0..127")
	k := pc.keyboard_notes(api.core, int(key))
	if k.slice do return fmt.tprintf("Slice %d", k.notes.pitches[0] + 1), .Ok
	return pc.key_label(api.core, k, pm.midi_note_name), .Ok
}

// Plays the note modes' key `key` (as `perform_key` counts them) on the
// selected pad, at `velocity` (0..1], or lets it go (`on` false), as
// pressing that pad of Pads' grid does: a chord's notes strummed as the
// key's voicing says. A key out of the pad's range plays nothing. What a
// key played is what its release ends, whatever changed between.
perform_play_key :: proc(api: ^Api, key: i64, on: bool, velocity: f32 = 1) -> Result {
	if key < 0 || key >= PADS do return fail(api, .Invalid_Argument, "a key is 0..127")
	if on && !(velocity > 0 && velocity <= 1) do return fail(api, .Invalid_Argument, "velocity is 0..1")
	c := api.core
	h := &api.keys_held[key]
	if h.count > 0 { // (pressed again before its release: that one ends first)
		pc.play_pitches(c, h.pad, h.pitches[:h.count], false, 0, h.strum_ms)
		h^ = {}
	}
	if !on do return .Ok
	k := pc.keyboard_notes(c, int(key))
	ps := pm.chord_slice(&k.notes)
	if !pc.keyboard_in_range(ps) do return .Ok
	h.pad = c.selected
	for p, i in ps do h.pitches[i] = i8(clamp(p, -48, 48))
	h.count = len(ps)
	h.strum_ms = c.keys.strum_ms if k.chords else 0
	pc.play_pitches(c, h.pad, h.pitches[:h.count], true, velocity, h.strum_ms)
	pc.key_played(c, h.pad, k)
	return .Ok
}

// The project key and how the chords play it.
Key_Info :: struct {
	root:          i64,  // 0..11, semitones above C
	scale:         Scale,
	octave:        i64,  // Scale mode's: -3..3
	notes:         i64,  // the scale's notes an octave (its degrees)
	voice_leading: bool, // each chord's inversion the closest to the one before
	spread:        Spread,
	strum_ms:      f64,  // 0..100 between a chord's notes, low first
}

// The project key now.
key_state :: proc(api: ^Api) -> (Key_Info, Result) {
	k := api.core.keys
	return {root = i64(k.root), scale = Scale(k.scale), octave = i64(k.octave), notes = i64(pm.scale_size(k.scale)), voice_leading = !k.no_voice_leading, spread = Spread(k.spread), strum_ms = f64(k.strum_ms)}, .Ok
}

// Sets the project key: its root (0..11, semitones above C) and scale.
// Saved with the project (not an edit); the Key topic reports it.
key_set :: proc(api: ^Api, root: i64, scale: Scale) -> Result {
	if scale < min(Scale) || scale > max(Scale) do return fail(api, .Invalid_Argument, "no such scale")
	if root < 0 || root > 11 do return fail(api, .Invalid_Argument, "the root is 0..11")
	api.core.keys.root, api.core.keys.scale = int(root), pm.Scale(scale)
	return .Ok
}

// Scale mode's octave, -3..3 (Chords and Progressions too: where their
// chords are built).
key_set_octave :: proc(api: ^Api, octave: i64) -> Result {
	if octave < -3 || octave > 3 do return fail(api, .Invalid_Argument, "the octave is -3..3")
	api.core.keys.octave = int(octave)
	return .Ok
}

// How Chords and Progressions voice their chords: voice leading (each
// chord's inversion the closest to the chord the pad played before),
// the spread, and the strum (0..100 ms between notes, low first).
key_set_voicing :: proc(api: ^Api, voice_leading: bool, spread: Spread, strum_ms: f64) -> Result {
	if spread < min(Spread) || spread > max(Spread) do return fail(api, .Invalid_Argument, "no such spread")
	if !(strum_ms >= 0 && strum_ms <= pm.MAX_STRUM_MS) do return fail(api, .Invalid_Argument, "the strum is 0..100 ms")
	k := &api.core.keys
	k.no_voice_leading, k.spread, k.strum_ms = !voice_leading, pm.Spread(spread), f32(strum_ms)
	api.core.voicing = {}
	return .Ok
}

// The project key's name: "C major", "F# dorian". Temporary.
key_name :: proc(api: ^Api) -> (string, Result) {
	return pm.key_name(api.core.keys), .Ok
}

// Scale `scale`'s name, as the window shows it.
key_scale_name :: proc(api: ^Api, scale: Scale) -> (string, Result) {
	if scale < min(Scale) || scale > max(Scale) do return "", fail(api, .Invalid_Argument, "no such scale")
	return string(pm.SCALE_NAMES[pm.Scale(scale)]), .Ok
}

// Whether `pitch` (semitones from a pad's own note, which is a C) is in the
// project key (the piano roll shades those rows).
key_has :: proc(api: ^Api, pitch: i64) -> (bool, Result) {
	return pm.in_key(api.core.keys, int(pitch)), .Ok
}

// A chord of the key, as built (before voice leading and spread).
Key_Chord :: struct {
	ok:    bool, // the key has its notes (else it is none: "–")
	root:  i64,  // its root's pitch, from a pad's own note
	count: i64,  // its notes
}

// Chord `variation` on degree `degree` (0 the key's root; past its notes,
// octaves up) of the project key, made of the key's own notes.
key_chord :: proc(api: ^Api, degree: i64, variation: Variation) -> (Key_Chord, Result) {
	if degree < 0 || degree > 48 || variation < min(Variation) || variation > max(Variation) do return {}, fail(api, .Invalid_Argument, "a degree is 0..48, and a variation one of Variation")
	c := pm.chord_build(api.core.keys, int(degree), pm.Variation(variation))
	return {ok = c.ok, root = i64(c.root), count = i64(c.notes.count)}, .Ok
}

// Note `index` (0 the lowest) of `key_chord(degree, variation)`: its pitch
// from a pad's own note.
key_chord_note :: proc(api: ^Api, degree: i64, variation: Variation, index: i64) -> (i64, Result) {
	if degree < 0 || degree > 48 || variation < min(Variation) || variation > max(Variation) do return 0, fail(api, .Invalid_Argument, "a degree is 0..48, and a variation one of Variation")
	c := pm.chord_build(api.core.keys, int(degree), pm.Variation(variation))
	if index < 0 || int(index) >= c.notes.count do return 0, fail(api, .Not_Found, "the chord has no such note")
	return i64(c.notes.pitches[index]), .Ok
}

// The name of `key_chord(degree, variation)`: its numeral and symbol,
// "ii7 Dm7" ("–" if the key can't make it). Temporary.
key_chord_name :: proc(api: ^Api, degree: i64, variation: Variation) -> (string, Result) {
	if degree < 0 || degree > 48 || variation < min(Variation) || variation > max(Variation) do return "", fail(api, .Invalid_Argument, "a degree is 0..48, and a variation one of Variation")
	return pm.chord_name(api.core.keys, pm.chord_build(api.core.keys, int(degree), pm.Variation(variation))), .Ok
}

// The progression in use (Progressions mode's), saved with the project.
Progression_State :: struct {
	count: i64, // its chords
	max:   i64, // the most it can have (16)
}

// The progression in use.
progression_state :: proc(api: ^Api) -> (Progression_State, Result) {
	return {count = i64(api.core.progression.count), max = pm.PROGRESSION_CHORDS}, .Ok
}

// The progression in use's name. Temporary.
progression_name :: proc(api: ^Api) -> (string, Result) {
	return strings.clone(pm.progression_name(&api.core.progression), context.temp_allocator), .Ok
}

// Names the progression in use.
progression_set_name :: proc(api: ^Api, name: string) -> Result {
	pm.progression_set_name(&api.core.progression, strings.trim_space(name))
	return .Ok
}

// The progression's numerals, "I V vi IV" (as the bank writes them, in
// lower case where the key's triad there is minor or diminished; the
// variations marked 7, sus4, sus2, add9, 6, /3, /5). Temporary.
progression_numerals :: proc(api: ^Api) -> (string, Result) {
	p := &api.core.progression
	b := strings.builder_make(context.temp_allocator)
	for c, i in p.chords[:p.count] {
		if i > 0 do strings.write_byte(&b, ' ')
		strings.write_string(&b, prog_numeral(api.core.keys, c))
	}
	return strings.to_string(b), .Ok
}

// A chord of a progression.
Progression_Chord :: struct {
	degree:    i64, // 0 the key's root; past its notes, octaves up
	variation: Variation,
}

// Chord `index` of the progression in use.
progression_chord :: proc(api: ^Api, index: i64) -> (Progression_Chord, Result) {
	p := &api.core.progression
	if index < 0 || int(index) >= p.count do return {}, fail(api, .Not_Found, "the progression has no such chord")
	c := p.chords[index]
	return {degree = i64(c.degree), variation = Variation(c.variation)}, .Ok
}

// Chord `index` of the progression in use as the key makes it, "ii7 Dm7"
// ("–" if it can't). Temporary.
progression_chord_name :: proc(api: ^Api, index: i64) -> (string, Result) {
	p := &api.core.progression
	if index < 0 || int(index) >= p.count do return "", fail(api, .Not_Found, "the progression has no such chord")
	return pm.chord_name(api.core.keys, pm.progression_chord(api.core.keys, p, int(index))), .Ok
}

// Puts a chord (`degree` 0..48 of the key, `variation`) into the
// progression in use at `index` (0..its count: the count adds it at the
// end). Unsupported when it has the most it can.
progression_insert :: proc(api: ^Api, index: i64, degree: i64, variation: Variation) -> Result {
	p := &api.core.progression
	if index < 0 || int(index) > p.count do return fail(api, .Invalid_Argument, "index is 0..the count")
	if degree < 0 || degree > 48 || variation < min(Variation) || variation > max(Variation) do return fail(api, .Invalid_Argument, "a degree is 0..48, and a variation one of Variation")
	if p.count >= pm.PROGRESSION_CHORDS do return fail(api, .Unsupported, "a progression has 16 chords at most")
	for i := p.count; i > int(index); i -= 1 do p.chords[i] = p.chords[i - 1]
	p.chords[index] = {int(degree), pm.Variation(variation)}
	p.count += 1
	return .Ok
}

// Changes chord `index` of the progression in use.
progression_set_chord :: proc(api: ^Api, index: i64, degree: i64, variation: Variation) -> Result {
	p := &api.core.progression
	if index < 0 || int(index) >= p.count do return fail(api, .Not_Found, "the progression has no such chord")
	if degree < 0 || degree > 48 || variation < min(Variation) || variation > max(Variation) do return fail(api, .Invalid_Argument, "a degree is 0..48, and a variation one of Variation")
	p.chords[index] = {int(degree), pm.Variation(variation)}
	return .Ok
}

// Takes chord `index` out of the progression in use.
progression_remove :: proc(api: ^Api, index: i64) -> Result {
	p := &api.core.progression
	if index < 0 || int(index) >= p.count do return fail(api, .Not_Found, "the progression has no such chord")
	for i in int(index) ..< p.count - 1 do p.chords[i] = p.chords[i + 1]
	p.count -= 1
	p.chords[p.count] = {}
	return .Ok
}

// Moves chord `from` of the progression in use to `to` (the others close
// up around it).
progression_move :: proc(api: ^Api, from: i64, to: i64) -> Result {
	p := &api.core.progression
	if from < 0 || int(from) >= p.count || to < 0 || int(to) >= p.count do return fail(api, .Not_Found, "the progression has no such chord")
	x := p.chords[from]
	if from < to {
		for i in int(from) ..< int(to) do p.chords[i] = p.chords[i + 1]
	} else {
		for i := int(from); i > int(to); i -= 1 do p.chords[i] = p.chords[i - 1]
	}
	p.chords[to] = x
	return .Ok
}

// The built-in progressions: how many.
progression_bank_count :: proc(api: ^Api) -> (i64, Result) {
	return len(pm.BUILTIN_PROGRESSIONS), .Ok
}

// Built-in progression `index`'s name.
progression_bank_name :: proc(api: ^Api, index: i64) -> (string, Result) {
	if index < 0 || index >= len(pm.BUILTIN_PROGRESSIONS) do return "", fail(api, .Not_Found, "no such progression in the bank")
	return pm.BUILTIN_PROGRESSIONS[index].name, .Ok
}

// Built-in progression `index`'s style ("Pop", "Jazz", "Dark"...).
progression_bank_style :: proc(api: ^Api, index: i64) -> (string, Result) {
	if index < 0 || index >= len(pm.BUILTIN_PROGRESSIONS) do return "", fail(api, .Not_Found, "no such progression in the bank")
	return pm.BUILTIN_PROGRESSIONS[index].style, .Ok
}

// Built-in progression `index`'s numerals ("I V vi IV").
progression_bank_numerals :: proc(api: ^Api, index: i64) -> (string, Result) {
	if index < 0 || index >= len(pm.BUILTIN_PROGRESSIONS) do return "", fail(api, .Not_Found, "no such progression in the bank")
	return pm.BUILTIN_PROGRESSIONS[index].chords, .Ok
}

// Uses built-in progression `index` (a copy: editing it leaves the bank as
// it is).
progression_use_bank :: proc(api: ^Api, index: i64) -> Result {
	if index < 0 || index >= len(pm.BUILTIN_PROGRESSIONS) do return fail(api, .Not_Found, "no such progression in the bank")
	api.core.progression = pm.progression_builtin(int(index))
	api.core.voicing = {}
	return .Ok
}

// The folder your progressions are saved in (the settings folder's
// Presets/Progressions). Temporary.
@(private)
progressions_folder :: proc(api: ^Api) -> string {
	p, _ := filepath.join({api.core.files.folders.settings, "Presets", "Progressions"}, context.temp_allocator)
	return p
}

// Your progressions (saved with `progression_save`): how many.
progression_mine_count :: proc(api: ^Api) -> (i64, Result) {
	return i64(len(pm.progression_list(progressions_folder(api)))), .Ok
}

// Your progression `index` (in name order): its name. Temporary.
progression_mine_name :: proc(api: ^Api, index: i64) -> (string, Result) {
	names := pm.progression_list(progressions_folder(api))
	if index < 0 || int(index) >= len(names) do return "", fail(api, .Not_Found, "no such progression of yours")
	return names[index], .Ok
}

// Uses your progression `name`. Not_Found if there is none; Io_Error if
// it can't be read.
progression_use_mine :: proc(api: ^Api, name: string) -> Result {
	found := false
	for n in pm.progression_list(progressions_folder(api)) do if n == name do found = true
	if !found do return failf(api, .Not_Found, "no progression of yours is called ", name)
	path, _ := filepath.join({progressions_folder(api), strings.concatenate({pm.safe_name(name), pm.PROGRESSION_EXT}, context.temp_allocator)}, context.temp_allocator)
	p, err := pm.progression_read(path)
	if err != .None do return failf(api, .Io_Error, "could not read the progression ", path)
	api.core.progression = p
	api.core.voicing = {}
	return .Ok
}

// Saves the progression in use as yours, called `name` (it is named so
// too): the file's path (in the settings folder; one of the same name is
// replaced). Temporary.
progression_save :: proc(api: ^Api, name: string) -> (string, Result) {
	n := strings.trim_space(name)
	if n == "" do return "", fail(api, .Invalid_Argument, "a progression needs a name")
	if api.core.progression.count == 0 do return "", fail(api, .Invalid_Argument, "the progression has no chords")
	path, err := pm.progression_save(&api.core.progression, progressions_folder(api), n)
	if err != .None do return "", fail(api, .Io_Error, "could not save the progression there")
	pm.progression_set_name(&api.core.progression, n)
	return strings.clone(path, context.temp_allocator), .Ok
}

// A progression chord's numeral as the bank writes it: "ii7", "V/3" (in
// key `k`: lower case where its triad is minor or diminished).
@(private)
prog_numeral :: proc(k: pm.Keys, c: pm.Prog_Chord) -> string {
	@(static, rodata) ROMAN := [7]string{"I", "II", "III", "IV", "V", "VI", "VII"}
	@(static, rodata) MARK := [pm.Variation]string{.Triad = "", .Seventh = "7", .Sus4 = "sus4", .Sus2 = "sus2", .Add9 = "add9", .Sixth = "6", .First_Inversion = "/3", .Second_Inversion = "/5"}
	base := ROMAN[c.degree % 7]
	q := pm.chord_build(k, c.degree, .Triad)
	if q.ok && (q.quality == .Minor || q.quality == .Diminished) do base = strings.to_lower(base, context.temp_allocator)
	return fmt.tprintf("%s%s", base, MARK[c.variation])
}
