package test_clip

import "core:os"
import "core:path/filepath"
import "core:testing"

import "fire:clip"
import tb "fire:timebase"
import kit "fire:testkit"

// A type 1 file written by hand, byte by byte: 96 ticks per quarter; a
// conductor track (120 BPM in 3/4, then 60 BPM at beat 4) and a track
// "Bass" using running status, a note-on with velocity 0 as a note-off, a
// controller and a pitch bend.
HAND_MADE := []u8{
	'M', 'T', 'h', 'd', 0, 0, 0, 6, 0, 1, 0, 2, 0, 96,
	'M', 'T', 'r', 'k', 0, 0, 0, 27,
	0x00, 0xFF, 0x51, 3, 0x07, 0xA1, 0x20, // 500 000 µs per quarter
	0x00, 0xFF, 0x58, 4, 3, 2, 24, 8,      // 3/4
	0x83, 0x00, 0xFF, 0x51, 3, 0x0F, 0x42, 0x40, // tick 384: 1 000 000 µs
	0x00, 0xFF, 0x2F, 0,
	'M', 'T', 'r', 'k', 0, 0, 0, 36,
	0x00, 0xFF, 0x03, 4, 'B', 'a', 's', 's',
	0x00, 0xE0, 0x00, 0x50, // pitch bend
	0x00, 0x90, 60, 100,    // C on
	0x30, 0xB0, 7, 100,     // tick 48: volume
	0x30, 0x90, 60, 0,      // tick 96: C off (note-on, velocity 0)
	0x00, 62, 90,           // running status: D on
	0x60, 0x80, 62, 64,     // tick 192: D off, release 64
	0x81, 0x40, 0xFF, 0x2F, 0, // tick 384: end of track
}

@(test)
reads_a_hand_made_file :: proc(t: ^testing.T) {
	mf, err := clip.midi_file_parse(HAND_MADE)
	if !testing.expect_value(t, err, clip.File_Error.None) do return
	defer clip.midi_file_destroy(&mf)
	testing.expect_value(t, mf.ppq, 96)
	if !testing.expect_value(t, len(mf.tracks), 1) do return
	tr := mf.tracks[0]
	testing.expect_value(t, tr.name, "Bass")
	c := tr.clip
	testing.expect_value(t, c.length, tb.Beats(6)) // 4 beats, rounded up to two 3/4 bars
	if testing.expect_value(t, len(c.notes), 2) {
		testing.expect_value(t, c.notes[0].key, 60)
		testing.expect_value(t, c.notes[0].start, tb.Beats(0))
		testing.expect_value(t, c.notes[0].length, tb.Beats(1))
		kit.expect_near(t, f64(c.notes[0].velocity), 100.0 / 127, 1e-6, "velocity")
		testing.expect_value(t, c.notes[1].key, 62)
		testing.expect_value(t, c.notes[1].start, tb.Beats(1))
		testing.expect_value(t, c.notes[1].length, tb.Beats(1))
		kit.expect_near(t, f64(c.notes[1].release), 64.0 / 127, 1e-6, "release")
	}
	if testing.expect_value(t, len(c.controllers), 2) {
		testing.expect_value(t, c.controllers[0].bytes, [3]u8{0xE0, 0x00, 0x50})
		testing.expect_value(t, c.controllers[1].at, tb.Beats(0.5))
		testing.expect_value(t, c.controllers[1].bytes, [3]u8{0xB0, 7, 100})
	}
	testing.expect_value(t, tb.tempo_at(&mf.tempo_map, 2), 120)
	testing.expect_value(t, tb.tempo_at(&mf.tempo_map, 5), 60)
	meter, _, _ := tb.meter_at_beat(&mf.tempo_map, 1)
	testing.expect_value(t, meter, tb.Meter{3, 4})
}

@(test)
write_then_read :: proc(t: ^testing.T) {
	b: clip.Midi_Builder
	clip.midi_builder_init(&b, 8)
	clip.add_note(&b, 0.25, 0.5, 64, 0.5, channel = 3, release = 0.25)
	clip.add_note(&b, 1, 2.75, 40, 1)
	clip.add_note(&b, 1, 0.125, 41, 0.01) // velocity rounds up to 1/127, never 0
	clip.add_controller(&b, 3.5, {0xB3, 1, 64})
	clip.add_controller(&b, 4, {0xC0, 5, 0}) // program change: two bytes on the wire
	c, _ := clip.midi_build(&b)
	clip.midi_builder_destroy(&b)
	defer clip.midi_clip_release(c)

	m: tb.Tempo_Map
	tb.tempo_map_init(&m, 100, {7, 8})
	defer tb.tempo_map_destroy(&m)
	tb.tempo_map_set_tempo(&m, 3.5, 140)
	tb.tempo_map_set_meter(&m, 2, {4, 4})

	dir := os.get_env("FIRE_ARTIFACTS_DIR", context.temp_allocator)
	if dir == "" do dir = "."
	_ = os.make_directory_all(dir)
	path, _ := filepath.join({dir, "round_trip.mid"}, context.temp_allocator)
	testing.expect_value(t, clip.midi_file_write(path, {{"Keys", c}}, &m), clip.File_Error.None)

	mf, err := clip.midi_file_read(path)
	if !testing.expect_value(t, err, clip.File_Error.None) do return
	defer clip.midi_file_destroy(&mf)
	if !testing.expect_value(t, len(mf.tracks), 1) do return
	testing.expect_value(t, mf.tracks[0].name, "Keys")
	got := mf.tracks[0].clip
	if testing.expect_value(t, len(got.notes), 3) {
		for n, i in got.notes {
			want := c.notes[i]
			testing.expectf(t, n.key == want.key && n.channel == want.channel && n.start == want.start && n.length == want.length,
				"note %d: %v, want %v", i, n, want)
			kit.expect_near(t, f64(n.velocity), f64(want.velocity), 1.0 / 127, "velocity")
		}
		kit.expect_near(t, f64(got.notes[0].release), 0.25, 1.0 / 127, "release")
	}
	if testing.expect_value(t, len(got.controllers), 2) {
		testing.expect_value(t, got.controllers[0], c.controllers[0])
		testing.expect_value(t, got.controllers[1], c.controllers[1])
	}
	testing.expect_value(t, tb.tempo_at(&mf.tempo_map, 1), 100)
	// MIDI files store whole microseconds per beat: 140 BPM is 428 571 µs.
	kit.expect_near(t, tb.tempo_at(&mf.tempo_map, 4), 140, 1e-3, "tempo after the change")
	meter, _, _ := tb.meter_at_beat(&mf.tempo_map, 1)
	testing.expect_value(t, meter, tb.Meter{7, 8})
	meter, _, _ = tb.meter_at_beat(&mf.tempo_map, 8)
	testing.expect_value(t, meter, tb.Meter{4, 4})
}

@(test)
bad_midi_files :: proc(t: ^testing.T) {
	_, err := clip.midi_file_parse({'R', 'I', 'F', 'F', 0, 0, 0, 0})
	testing.expect_value(t, err, clip.File_Error.Corrupt)
	_, err = clip.midi_file_parse(HAND_MADE[:40]) // cut short
	testing.expect_value(t, err, clip.File_Error.Corrupt)
	smpte := make([]u8, len(HAND_MADE), context.temp_allocator)
	copy(smpte, HAND_MADE)
	smpte[12] = 0xE7 // -25 fps
	_, err = clip.midi_file_parse(smpte)
	testing.expect_value(t, err, clip.File_Error.Unsupported)
	_, err = clip.midi_file_read("no/such/file.mid")
	testing.expect_value(t, err, clip.File_Error.Not_Found)
}
