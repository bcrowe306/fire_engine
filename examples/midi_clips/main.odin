/*
MIDI clips in both styles at once: a bass loop launched on the next bar (as
a clip launcher would), and a chord clip placed in an arrangement. Both
players feed the graph's event output; the program renders four bars
offline, prints the notes as they come out, and saves both clips as a MIDI
file.

	odin run examples/midi_clips -collection:fire=f_engine
*/
package midi_clips

import "core:fmt"
import "core:os"
import "core:path/filepath"

import "fire:clip"
import "fire:core"
import "fire:graph"
import tb "fire:timebase"
import "fire:transport"

SAMPLE_RATE :: 48_000.0
BLOCK :: 512

main :: proc() {
	// 1. Clips: immutable, built once (rebuilt after each edit in an app).
	bass := build_bass()
	defer clip.midi_clip_release(bass)
	chords := build_chords()
	defer clip.midi_clip_release(chords)

	// 2. The clock: an arrangement timeline that leads, and a launcher
	//    timeline for the bass loop.
	clock, _ := transport.create(transport.default_settings(SAMPLE_RATE))
	defer transport.destroy(clock)
	song, _ := transport.add_timeline(clock)
	launcher, _ := transport.add_timeline(clock)
	transport.set_leader(clock, song)

	// 3. A graph with one player per clip, both feeding OUTPUT's events.
	settings := graph.default_settings(SAMPLE_RATE, BLOCK)
	settings.input_channels, settings.output_channels, settings.workers = 0, 0, 0
	g, _ := graph.create(settings)
	defer graph.destroy(g)

	bass_node, bass_player := clip.midi_player_create({timeline = launcher})
	chord_node, chord_player := clip.midi_player_create({timeline = song})
	clip.midi_player_set(bass_player, bass, {loop = true})                      // launcher: loop from the launch
	clip.midi_player_set(chord_player, chords, {at = 4, length = 8, loop = true}) // arrangement: bars 2-3
	b, _ := graph.add_node(g, bass_node, 0, 0)
	c, _ := graph.add_node(g, chord_node, 0, 0)
	graph.connect_events(g, b, graph.OUTPUT)
	graph.connect_events(g, c, graph.OUTPUT)
	graph.commit(g)

	// 4. Play the song now; launch the bass on the next bar after half a beat.
	transport.play(clock, song)
	buf: [256]core.Event
	frames := int(16 * 60 / 120.0 * SAMPLE_RATE) // four bars at 120 BPM
	for at := 0; at < frames; at += BLOCK {
		if at <= 12_000 && 12_000 < at + BLOCK do transport.play(clock, launcher, tb.Quantize.Bar)
		w := core.Event_Writer{buffer = buf[:]}
		ctx := core.Process_Context{frames = BLOCK, events_out = &w}
		transport.process(clock, &ctx, proc(user: rawptr, seg: ^core.Process_Context) {
			graph.process((^graph.Graph)(user), seg)
		}, g)
		for e in core.event_writer_events(&w) {
			if on, ok := e.payload.(core.Note_On); ok {
				beat := f64(at + int(e.offset)) / SAMPLE_RATE * 2 // 120 BPM: 2 beats per second
				fmt.printf("beat %5.2f  note %3d  velocity %.2f\n", beat, on.key, on.velocity)
			}
		}
	}

	// 5. Save both clips as a type 1 MIDI file and read it back.
	dir, _ := os.make_directory_temp("", "fire_midi_clips", context.allocator)
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, "song.mid"}, context.allocator)
	defer delete(path)
	clip.midi_file_write(path, {{"Bass", bass}, {"Chords", chords}})
	mf, err := clip.midi_file_read(path)
	if err != .None {
		fmt.eprintln("midi_file_read:", err)
		return
	}
	defer clip.midi_file_destroy(&mf)
	for t in mf.tracks do fmt.printf("%s: %d notes over %.0f beats\n", t.name, len(t.clip.notes), f64(t.clip.length))
}

// One bar of eighth-note bass, accenting the downbeat.
build_bass :: proc() -> ^clip.Midi_Clip {
	b: clip.Midi_Builder
	clip.midi_builder_init(&b, 4)
	defer clip.midi_builder_destroy(&b)
	for k in 0 ..< 8 {
		clip.add_note(&b, tb.Beats(f64(k) * 0.5), 0.4, 36 if k % 4 != 3 else 43, 1 if k == 0 else 0.7)
	}
	c, _ := clip.midi_build(&b)
	return c
}

// Two bars of chords, each held for a bar, the second bent up into place.
build_chords :: proc() -> ^clip.Midi_Clip {
	b: clip.Midi_Builder
	clip.midi_builder_init(&b, 8)
	defer clip.midi_builder_destroy(&b)
	for key in ([]u8{60, 64, 67}) do clip.add_note(&b, 0, 4, key, 0.6)
	for key in ([]u8{59, 62, 67}) {
		n := clip.add_note(&b, 4, 4, key, 0.6)
		clip.add_expression(&b, n, 0, .Tuning, -1)
		clip.add_expression(&b, n, 0.5, .Tuning, 0)
	}
	c, _ := clip.midi_build(&b)
	return c
}
