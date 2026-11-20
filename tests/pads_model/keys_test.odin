package test_pads_model

import "core:os"
import "core:path/filepath"
import "core:testing"

import pm "../../apps/pads/model"
import fc "fire:core"
import kit "fire:testkit"

// The chord's notes as a slice (temporary).
@(private = "file")
notes_of :: proc(c: pm.Chord_Notes) -> []int {
	out := make([]int, c.count, context.temp_allocator)
	for i in 0 ..< c.count do out[i] = c.pitches[i]
	return out
}

@(private = "file")
same :: proc(a: []int, b: []int) -> bool {
	if len(a) != len(b) do return false
	for x, i in a do if b[i] != x do return false
	return true
}

@(test)
a_major_keys_chords_are_its_own_notes :: proc(t: ^testing.T) {
	k := pm.Keys{scale = .Major} // C major
	want := [7]string{"I C", "ii Dm", "iii Em", "IV F", "V G", "vi Am", "vii° Bdim"}
	for w, d in want {
		c := pm.chord_build(k, d, .Triad)
		testing.expectf(t, c.ok, "degree %d makes a triad", d)
		testing.expect_value(t, pm.chord_name(k, c), w)
		for p in notes_of(c.notes) do testing.expectf(t, pm.in_key(k, p), "degree %d: %d in the key", d, p)
	}
	sevenths := [7]string{"Imaj7 Cmaj7", "ii7 Dm7", "iii7 Em7", "IVmaj7 Fmaj7", "V7 G7", "vi7 Am7", "viiø7 Bm7b5"}
	for w, d in sevenths do testing.expect_value(t, pm.chord_name(k, pm.chord_build(k, d, .Seventh)), w)
	testing.expect(t, same(notes_of(pm.chord_build(k, 1, .Seventh).notes), {2, 5, 9, 12}), "Dm7: D F A C")
	testing.expect_value(t, pm.chord_name(k, pm.chord_build(k, 0, .Sus4)), "Isus4 Csus4")
	testing.expect_value(t, pm.chord_name(k, pm.chord_build(k, 1, .Sus2)), "IIsus2 Dsus2")
	testing.expect_value(t, pm.chord_name(k, pm.chord_build(k, 0, .Add9)), "Iadd9 Cadd9")
	testing.expect_value(t, pm.chord_name(k, pm.chord_build(k, 1, .Sixth)), "ii6 Dm6")
	// What the key can't make: E's sus4 needs A (yes) and B (yes); B's sus4
	// needs F# (no). E's add9 needs F# (no).
	testing.expect(t, pm.chord_build(k, 2, .Sus4).ok, "Esus4")
	testing.expect(t, !pm.chord_build(k, 6, .Sus4).ok, "no Bsus4 in C major")
	testing.expect_value(t, pm.chord_name(k, pm.chord_build(k, 2, .Add9)), "–")
	// Past the key's notes: octaves up.
	testing.expect(t, same(notes_of(pm.chord_build(k, 7, .Triad).notes), {12, 16, 19}), "degree 7: C an octave up")
	// The octave moves them all.
	k.octave = -1
	testing.expect(t, same(notes_of(pm.chord_build(k, 0, .Triad).notes), {-12, -8, -5}), "an octave down")
}

@(test)
other_scales_chords_and_names :: proc(t: ^testing.T) {
	// Harmonic minor (A): III is augmented, vii a diminished 7th.
	k := pm.Keys{scale = .Harmonic_Minor, root = 9}
	testing.expect_value(t, pm.chord_name(k, pm.chord_build(k, 2, .Triad)), "III+ Caug")
	testing.expect_value(t, pm.chord_name(k, pm.chord_build(k, 6, .Seventh)), "vii°7 G#dim7")
	testing.expect_value(t, pm.chord_name(k, pm.chord_build(k, 0, .Seventh)), "imaj7 Am(maj7)")
	// Flat keys are spelled with flats: F major's IV, D minor's VI.
	f := pm.Keys{scale = .Major, root = 5}
	testing.expect_value(t, pm.chord_name(f, pm.chord_build(f, 3, .Triad)), "IV Bb")
	testing.expect_value(t, pm.key_name(f), "F major")
	d := pm.Keys{scale = .Minor, root = 2}
	testing.expect_value(t, pm.chord_name(d, pm.chord_build(d, 5, .Triad)), "VI Bb")
	// A major pentatonic has five degrees: D (its second) has no third,
	// so no triad, but a sus4 (D G A); its numerals go by semitones.
	p := pm.Keys{scale = .Major_Pentatonic}
	testing.expect_value(t, pm.scale_size(p.scale), 5)
	testing.expect(t, pm.chord_build(p, 0, .Triad).ok, "C")
	testing.expect(t, !pm.chord_build(p, 1, .Triad).ok, "no D triad")
	testing.expect_value(t, pm.chord_name(p, pm.chord_build(p, 1, .Triad)), "–")
	testing.expect_value(t, pm.chord_name(p, pm.chord_build(p, 1, .Sus4)), "IIsus4 Dsus4")
	testing.expect_value(t, pm.chord_name(p, pm.chord_build(p, 4, .Triad)), "vi Am")
	// Whole tone: augmented triads only.
	w := pm.Keys{scale = .Whole_Tone}
	for d in 0 ..< 6 do testing.expectf(t, pm.chord_build(w, d, .Triad).quality == .Augmented, "whole tone %d: augmented", d)
	// Every scale: every chord made is of the key's own notes.
	for s in pm.Scale do for d in 0 ..< pm.scale_size(s) do for v in pm.Variation {
		key := pm.Keys{scale = s, root = 4}
		c := pm.chord_build(key, d, v)
		if !c.ok do continue
		for x in notes_of(c.notes) do testing.expectf(t, pm.in_key(key, x), "%v degree %d %v: %d in the key", s, d, v, x)
		testing.expectf(t, pm.chord_name(key, c) != "–", "%v degree %d %v named", s, d, v)
	}
	// The scales added keep the old ones' values (saved in old files).
	testing.expect_value(t, int(pm.Scale.Blues), 8)
	testing.expect_value(t, int(pm.Play_Mode.Velocity), 2)
	testing.expect_value(t, len(pm.Scale), 20)
}

@(test)
inversions_spread_and_voice_leading :: proc(t: ^testing.T) {
	k := pm.Keys{scale = .Major}
	first := pm.chord_build(k, 0, .First_Inversion)
	testing.expect(t, same(notes_of(first.notes), {4, 7, 12}), "C/E: E G C")
	testing.expect_value(t, pm.chord_name(k, first), "I/3 C/E")
	second := pm.chord_build(k, 0, .Second_Inversion)
	testing.expect(t, same(notes_of(second.notes), {7, 12, 16}), "C/G: G C E")
	testing.expect_value(t, pm.chord_symbol(k, second), "C/G")
	// Spread: open (the second note up), wide (drop 2).
	c := pm.chord_build(k, 0, .Triad).notes
	testing.expect(t, same(notes_of(pm.spread_chord(c, .Open)), {0, 7, 16}), "open: C G E")
	testing.expect(t, same(notes_of(pm.spread_chord(c, .Drop_2)), {-8, 0, 7}), "drop 2: E C G")
	testing.expect(t, same(notes_of(pm.spread_chord(c, .Close)), {0, 4, 7}), "close")
	// Voice leading: after C, F as C F A (its second inversion); after
	// that, G as B D G; nothing before: as built.
	f := pm.chord_build(k, 3, .Triad).notes
	led := pm.voice_lead(f, c)
	testing.expectf(t, same(notes_of(led), {0, 5, 9}), "F after C: C F A (%v)", notes_of(led))
	g := pm.voice_lead(pm.chord_build(k, 4, .Triad).notes, led)
	testing.expectf(t, same(notes_of(g), {-1, 2, 7}), "G after F: B D G (%v)", notes_of(g))
	testing.expect(t, same(notes_of(pm.voice_lead(f, {})), {5, 9, 12}), "F with none before")
	// chord_voiced: voice leading off plays root position; an inversion
	// variation keeps its inversion either way.
	testing.expect(t, same(notes_of(pm.chord_voiced(k, 3, .Triad, c)), {0, 5, 9}), "voiced, led")
	k.no_voice_leading = true
	testing.expect(t, same(notes_of(pm.chord_voiced(k, 3, .Triad, c)), {5, 9, 12}), "voiced, root position")
	k.no_voice_leading = false
	testing.expect(t, same(notes_of(pm.chord_voiced(k, 0, .First_Inversion, f)), {4, 7, 12}), "an inversion stays")
	testing.expect_value(t, pm.chord_voiced(pm.Keys{scale = .Major_Pentatonic}, 1, .Triad, c).count, 0)
	// A 7th from a triad: still near.
	g7 := pm.voice_lead(pm.chord_build(k, 4, .Seventh).notes, c)
	for p in notes_of(g7) do testing.expectf(t, p >= -5 && p <= 12, "G7 near C (%v)", notes_of(g7))
}

@(test)
chords_mode_pads_and_snapping :: proc(t: ^testing.T) {
	k := pm.Keys{scale = .Major}
	// Pad 1 (bottom left): I triad; pad 5 (the row above): I 7th; pad 4:
	// IV; bank B's first: V.
	d, v := pm.chords_pad(k, 0, 0)
	testing.expect(t, d == 0 && v == .Triad, "pad 1")
	d, v = pm.chords_pad(k, 0, 4)
	testing.expect(t, d == 0 && v == .Seventh, "pad 5")
	d, v = pm.chords_pad(k, 0, 3)
	testing.expect(t, d == 3 && v == .Triad, "pad 4")
	d, v = pm.chords_pad(k, 1, 15)
	testing.expect(t, d == 7 && v == .Sus2, "bank B, pad 16")
	k.chord_page = 1
	d, v = pm.chords_pad(k, 0, 12)
	testing.expect(t, d == 0 && v == .Second_Inversion, "page 2, pad 13")
	// In key: to the nearest note of the key (a tie: the lower).
	mask := pm.key_mask(pm.Keys{scale = .Major})
	testing.expect_value(t, pm.snap_to_key(mask, 1), 0)
	testing.expect_value(t, pm.snap_to_key(mask, 6), 5)
	testing.expect_value(t, pm.snap_to_key(mask, 7), 7)
	testing.expect_value(t, pm.snap_to_key(mask, 13), 12) // (an octave up too)
	testing.expect_value(t, pm.snap_to_key(mask, -2), -3) // (and down: Bb, between A and B, to A)
	e := pm.key_mask(pm.Keys{scale = .Major, root = 4}) // E major: F#
	testing.expect_value(t, pm.snap_to_key(e, 5), 4)
	testing.expect_value(t, pm.snap_to_key(e, 6), 6)
}

@(test)
progressions_parse_and_the_bank :: proc(t: ^testing.T) {
	p, ok := pm.progression_parse("I V vi IV", "Test")
	testing.expect(t, ok && p.count == 4, "four chords")
	degrees := [4]int{0, 4, 5, 3}
	for c, i in p.chords[:p.count] do testing.expect(t, c.degree == degrees[i] && c.variation == .Triad, "degrees")
	testing.expect_value(t, pm.progression_name(&p), "Test")
	q, _ := pm.progression_parse("ii7 V/3 Isus4 IVadd9 vi6 iii/5 viisus2")
	want := [7]pm.Prog_Chord{{1, .Seventh}, {4, .First_Inversion}, {0, .Sus4}, {3, .Add9}, {5, .Sixth}, {2, .Second_Inversion}, {6, .Sus2}}
	for w, i in want do testing.expectf(t, q.chords[i] == w, "chord %d: %v", i, q.chords[i])
	_, bad := pm.progression_parse("I X IV")
	testing.expect(t, !bad, "X is no numeral")
	_, long := pm.progression_parse("I I I I I I I I I I I I I I I I I")
	testing.expect(t, !long, "17 chords are too many")
	// The bank: about 40, every one parses, names unique, styles known.
	testing.expect(t, len(pm.BUILTIN_PROGRESSIONS) >= 40, "about 40 built in")
	for b, i in pm.BUILTIN_PROGRESSIONS {
		x, good := pm.progression_parse(b.chords, b.name)
		testing.expectf(t, good && x.count >= 2, "%s parses", b.name)
		known := false
		for s in pm.PROGRESSION_STYLES do if s == b.style do known = true
		testing.expectf(t, known, "%s: style %s", b.name, b.style)
		for c, j in pm.BUILTIN_PROGRESSIONS do if j != i do testing.expectf(t, c.name != b.name, "%s twice", b.name)
	}
	// In a key: C major's I V vi IV, and in A minor the same numerals.
	k := pm.Keys{scale = .Major}
	names := [4]string{"I C", "V G", "vi Am", "IV F"}
	for n, i in names do testing.expect_value(t, pm.chord_name(k, pm.progression_chord(k, &p, i)), n)
	am := pm.Keys{scale = .Minor, root = 9}
	testing.expect_value(t, pm.chord_name(am, pm.progression_chord(am, &p, 1)), "v Em")
}

@(test)
progression_files_round_trip :: proc(t: ^testing.T) {
	dir, _ := filepath.join({kit.artifacts_root(), "pads_model", "progressions"}, context.temp_allocator)
	os.remove_all(dir)
	p, _ := pm.progression_parse("ii7 V7 I7 vi", "Mine")
	p.chords[3].variation = .First_Inversion
	path, err := pm.progression_save(&p, dir, "Late: Night")
	testing.expect_value(t, err, fc.Error.None)
	names := pm.progression_list(dir)
	testing.expect(t, len(names) == 1 && names[0] == "Late- Night", "listed by its file's name")
	back, rerr := pm.progression_read(path)
	testing.expect_value(t, rerr, fc.Error.None)
	testing.expect_value(t, pm.progression_name(&back), "Late: Night")
	testing.expect_value(t, back.count, 4)
	for c, i in p.chords[:p.count] do testing.expect(t, back.chords[i] == c, "chords")
	_, missing := pm.progression_read("/no/such/file.fprog")
	testing.expect(t, missing != .None, "a missing file")
	_, empty := pm.progression_save(&p, dir, "  ")
	testing.expect_value(t, empty, fc.Error.Invalid_Argument)
}

@(test)
the_key_voicing_and_progression_are_saved :: proc(t: ^testing.T) {
	r := rig_make(t, "keys_save")
	defer rig_destroy(r)
	m := &r.m
	testing.expect_value(t, pm.model_new(m, r.dir), fc.Error.None)
	v := &m.project.view
	v.play_mode = .Progressions
	v.keys = {scale = .Hirajoshi, root = 7, octave = 2, no_voice_leading = true, spread = .Drop_2, strum_ms = 35, chord_page = 1, layout = .Chromatic}
	v.progression, _ = pm.progression_parse("vi IV I V", "Back Porch")
	m.project.pads[2].midi_fx.arp_in_key = true
	testing.expect_value(t, pm.model_save(m), fc.Error.None)
	r2 := rig_make(t, "keys_save_2")
	defer rig_destroy(r2)
	testing.expect_value(t, pm.model_load(&r2.m, m.project.dir), fc.Error.None)
	w := r2.m.project.view
	testing.expect_value(t, w.play_mode, pm.Play_Mode.Progressions)
	testing.expect_value(t, w.keys, v.keys)
	testing.expect_value(t, pm.progression_name(&w.progression), "Back Porch")
	testing.expect_value(t, w.progression.count, 4)
	testing.expect_value(t, w.progression.chords[0].degree, 5)
	testing.expect(t, r2.m.project.pads[2].midi_fx.arp_in_key && !r2.m.project.pads[1].midi_fx.arp_in_key, "pad 3's arpeggiator In key")
}

// A project from before the project key (v40): Keyboard mode with its
// chords on (D dorian, an octave down) opens in Chords mode, its key the
// project key, voice leading on.
@(test)
an_old_keyboard_project_opens_in_chords_mode :: proc(t: ^testing.T) {
	r := rig_make(t, "keys_v40")
	defer rig_destroy(r)
	dir, _ := filepath.join({r.dir, "Old.pads"}, context.temp_allocator)
	testing.expect_value(t, os.make_directory(dir), nil)
	file, _ := filepath.join({dir, "project.fire"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(file, #load("fixtures/keyboard_v40.pads/project.fire")) == nil, "the fixture copied")
	testing.expect_value(t, pm.model_load(&r.m, dir), fc.Error.None)
	v := r.m.project.view
	testing.expect_value(t, v.play_mode, pm.Play_Mode.Chords)
	testing.expect(t, v.keys.scale == .Dorian && v.keys.root == 2 && v.keys.octave == -1, "the key kept")
	testing.expect(t, !v.keys.no_voice_leading && v.keys.spread == .Close && v.keys.strum_ms == 0, "voicing: the defaults")
	testing.expect_value(t, v.selected, 3)
	testing.expect_value(t, v.progression.count, 0)
}

// Strum: a chord's notes come through the router a strum apart (in
// frames, low note first), the same at any block size, without
// allocating; their note-offs keep the order.
@(test)
strum_offsets_a_chords_notes_by_frames :: proc(t: ^testing.T) {
	Run :: struct { frame: i64, on: bool }
	run :: proc(t: ^testing.T, blocks: kit.Block_Pattern) -> [dynamic]Run {
		node, r := pm.router_create()
		defer fc.node_destroy(&node)
		r.midi_out[0] = {on = true, channel = 0, key = 36}
		r.out_port[0] = 0
		// C E G, 20 ms apart; let go 50 ms after.
		for p, i in ([3]i8{0, 4, 7}) {
			pm.router_push(r, {pad = 0, on = true, velocity = 1, pitch = p, keyboard = true, delay_ms = 20 * f32(i)})
		}
		for p, i in ([3]i8{0, 4, 7}) {
			pm.router_push(r, {pad = 0, on = false, pitch = p, keyboard = true, delay_ms = 50 + 20 * f32(i)})
		}
		cfg := kit.default_render_config()
		cfg.out_channels = 0
		cfg.tail_frames = 6000
		cfg.blocks = blocks
		_, rep := kit.render(&node, kit.buffer_make(0, 0, 48_000, context.temp_allocator), cfg, context.temp_allocator)
		kit.expect_clean_render(t, rep)
		testing.expect_value(t, rep.rt_allocations, 0)
		out := make([dynamic]Run, context.temp_allocator)
		for e in rep.events_out {
			if m, ok := e.payload.(fc.Midi_Raw); ok do append(&out, Run{i64(e.time), m.bytes[0] & 0xF0 == 0x90})
		}
		return out
	}
	want := [6]Run{{0, true}, {960, true}, {1920, true}, {2400, false}, {3360, false}, {4320, false}}
	for blocks in ([]kit.Block_Pattern{kit.Fixed_Blocks{512}, kit.Fixed_Blocks{1}, kit.Fixed_Blocks{37}, kit.Random_Blocks{seed = 7, min = 0, max = 512}}) {
		got := run(t, blocks)
		testing.expectf(t, len(got) == len(want), "%v: six notes (%v)", blocks, got[:])
		if len(got) != len(want) do continue
		for w, i in want do testing.expectf(t, got[i] == w, "%v: note %d at %v (want %v)", blocks, i, got[i], w)
	}
}

// A strummed chord recorded: each note where it sounded, a strum apart.
@(test)
a_strummed_chord_records_with_its_offsets :: proc(t: ^testing.T) {
	r := blips(t, "keys_strum_rec")
	defer rig_destroy(r)
	m := &r.m
	c: pm.Capture
	defer pm.capture_destroy(&c)
	pm.capture_arm(m, &c, true)
	pm.play(&m.engine)
	render(r, 24_000) // beat 1 (120 bpm)
	for p, i in ([3]i8{0, 4, 7}) do pm.hit(&m.engine, 0, true, 0.8, p, keyboard = true, delay_ms = 25 * f32(i))
	render(r, 12_000)
	for p, i in ([3]i8{0, 4, 7}) do pm.hit(&m.engine, 0, false, 0, p, keyboard = true, delay_ms = 25 * f32(i))
	render(r, 12_000)
	pm.capture_poll(m, &c)
	pm.capture_arm(m, &c, false)
	s := pm.current_sequence(m)
	testing.expectf(t, len(s.notes) == 3, "three notes (%v)", s.notes)
	if len(s.notes) != 3 do return
	starts: [3]f64
	for n in s.notes do starts[clamp((int(n.pitch) + 1) / 4, 0, 2)] = n.start
	// 25 ms is 0.05 of a beat at 120 bpm.
	testing.expectf(t, abs(starts[1] - starts[0] - 0.05) < 0.003 && abs(starts[2] - starts[1] - 0.05) < 0.003, "a strum apart (%v)", starts)
}
