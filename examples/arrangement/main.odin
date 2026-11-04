/*
An arrangement: three tracks of regions on one song timeline, with a tempo
change, automation lanes, a loop over the second half, and an edit while it
plays. Every region is a player with a placement on the song timeline, and
a track's regions sum into the track's nodes. The song leads the clock, so
its tempo map sets the tempo.

	Drums  | four on the floor (bars 1-4) | with hats (bars 5-8)      |
	Bass   |              | eighths (bars 3-8), filter rising        |
	Pad    |                             | chords (bars 5-8), fade in |

Renders the eight bars and the loop over bars 5-8 once more offline,
printing what plays in each bar, and bounces the result to a WAV file.

	odin run examples/arrangement -collection:fire=f_engine
*/
package arrangement

import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

import "fire:audiofile"
import "fire:clip"
import "fire:core"
import "fire:dsp"
import "fire:graph"
import "fire:stream"
import tb "fire:timebase"
import "fire:transport"

SAMPLE_RATE :: 48_000.0
BLOCK :: 512

// What the app shows of a region; the players hold the real thing.
Region :: struct {
	track, name: string,
	at, length:  tb.Beats,
}

main :: proc() {
	dir, _ := os.make_directory_temp("", "fire_arrangement", context.allocator)
	defer os.remove_all(dir)
	bounce_path, _ := filepath.join({dir, "song.wav"}, context.allocator)
	defer delete(bounce_path)

	// 1. The song: 120 BPM, 132 from bar 5. It leads, so its map is the tempo.
	tempo_map: tb.Tempo_Map
	tb.tempo_map_init(&tempo_map, 120)
	defer tb.tempo_map_destroy(&tempo_map)
	tb.tempo_map_set_tempo(&tempo_map, 16, 132)
	clock, _ := transport.create(transport.default_settings(SAMPLE_RATE))
	defer transport.destroy(clock)
	song, _ := transport.add_timeline(clock, &tempo_map)
	transport.set_leader(clock, song)

	streamer, _ := stream.create(stream.default_settings()) // outlives the graph's players
	defer stream.destroy(streamer)
	settings := graph.default_settings(SAMPLE_RATE, BLOCK)
	settings.input_channels, settings.workers = 0, 0
	g, _ := graph.create(settings)
	defer graph.destroy(g)
	regions: [dynamic]Region
	defer delete(regions)

	// 2. Drums: two audio regions, each a looping placement. The loops were
	//    recorded at 120 BPM and repitch to follow the tempo change.
	drum_players: [2]^clip.Audio_Player
	for name, i in ([]string{"four on the floor", "with hats"}) {
		path, _ := filepath.join({dir, fmt.tprintf("drums_%d.wav", i)}, context.allocator)
		defer delete(path)
		write_drums(path, hats = i == 1)
		src, err := stream.source_open(streamer, path)
		if err != .None {
			fmt.eprintln("source_open:", err)
			return
		}
		loop, _ := clip.audio_clip_create(src, {bpm = 120, mode = .Repitch})
		stream.source_release(src) // the clip holds it
		node, player := clip.audio_player_create(clip.default_audio_player_settings(song, streamer))
		id, _ := graph.add_node(g, node, 0, 2)
		graph.connect(g, id, 0, graph.OUTPUT, 0)
		graph.connect(g, id, 1, graph.OUTPUT, 1)
		region := Region{"Drums", name, tb.Beats(16 * i), 16}
		clip.audio_player_set(player, loop, {at = region.at, length = region.length, loop = true})
		clip.audio_clip_release(loop) // the player holds it
		drum_players[i] = player
		append(&regions, region)
	}

	// 3. Bass: a MIDI region into a synth and filter, and an automation lane
	//    for the filter placed over the whole song.
	bass_synth, _ := graph.add_node(g, dsp.synth_create(8), 0, 1)
	graph.set_param(g, bass_synth, dsp.SYNTH_PARAM_AMP_SUSTAIN, 0) // plucked
	graph.set_param(g, bass_synth, dsp.SYNTH_PARAM_AMP_DECAY, 0.3)
	graph.set_param(g, bass_synth, dsp.SYNTH_PARAM_GAIN_DB, -11)
	bass_filter, _ := graph.add_node(g, dsp.one_pole_create(), 1, 1)
	graph.connect(g, bass_synth, 0, bass_filter, 0)
	graph.connect(g, bass_filter, 0, graph.OUTPUT, 0)
	graph.connect(g, bass_filter, 0, graph.OUTPUT, 1)
	bass_node, bass_player := clip.midi_player_create({timeline = song})
	bass_id, _ := graph.add_node(g, bass_node, 0, 0)
	graph.connect_events(g, bass_id, bass_synth)
	bass := build_bass(transpose = 0)
	bass_region := Region{"Bass", "eighths", 8, 24}
	clip.midi_player_set(bass_player, bass, {at = bass_region.at, length = bass_region.length, loop = true})
	clip.midi_clip_release(bass)
	append(&regions, bass_region)

	cutoff := dsp.ONE_POLE_PARAM_CUTOFF_HZ
	b: clip.Automation_Builder
	clip.automation_builder_init(&b, 32)
	clip.automation_add_point(&b, cutoff, 8, 300, .Curve, tension = 0.4) // opens over bars 3-6
	clip.automation_add_point(&b, cutoff, 24, 5000)
	clip.automation_add_point(&b, cutoff, 28, 5000)
	clip.automation_add_point(&b, cutoff, 32, 800) // and closes a little at the end
	bass_lane, _ := clip.automation_build(&b)
	clip.automation_builder_destroy(&b)
	add_automation(g, song, bass_filter, bass_lane, {})
	append(&regions, Region{"Bass", "filter cutoff (automation)", 0, 32})

	// 4. Pad: chords into a gain, faded in by an automation region in dB.
	pad_synth, _ := graph.add_node(g, dsp.synth_create(8), 0, 1)
	graph.set_param(g, pad_synth, dsp.SYNTH_PARAM_AMP_ATTACK, 0.2) // swells in, holds, fades out
	graph.set_param(g, pad_synth, dsp.SYNTH_PARAM_AMP_RELEASE, 1.5)
	graph.set_param(g, pad_synth, dsp.SYNTH_PARAM_OSC1_SHAPE, f64(dsp.Osc_Shape.Triangle))
	graph.set_param(g, pad_synth, dsp.SYNTH_PARAM_CUTOFF_HZ, 1200)
	graph.set_param(g, pad_synth, dsp.SYNTH_PARAM_GAIN_DB, -14)
	pad_gain, _ := graph.add_node(g, dsp.gain_create(), 1, 1)
	graph.connect(g, pad_synth, 0, pad_gain, 0)
	graph.connect(g, pad_gain, 0, graph.OUTPUT, 0)
	graph.connect(g, pad_gain, 0, graph.OUTPUT, 1)
	pad_node, pad_player := clip.midi_player_create({timeline = song})
	pad_id, _ := graph.add_node(g, pad_node, 0, 0)
	graph.connect_events(g, pad_id, pad_synth)
	chords := build_chords()
	chord_region := Region{"Pad", "chords", 16, 16}
	clip.midi_player_set(pad_player, chords, {at = chord_region.at, length = chord_region.length, loop = true})
	clip.midi_clip_release(chords)
	append(&regions, chord_region)

	clip.automation_builder_init(&b, 16)
	clip.automation_add_point(&b, dsp.GAIN_PARAM_DB, 0, -40) // a straight line in dB is an even fade
	clip.automation_add_point(&b, dsp.GAIN_PARAM_DB, 8, -6)
	fade, _ := clip.automation_build(&b)
	clip.automation_builder_destroy(&b)
	add_automation(g, song, pad_gain, fade, {at = 16, length = 16})
	append(&regions, Region{"Pad", "fade in (automation)", 16, 16})

	graph.commit(g)
	for p in drum_players do for !clip.audio_player_ready(p) do time.sleep(time.Millisecond) // preroll

	fmt.println("regions:")
	for r in regions do fmt.printf("  %-6s %-27s bars %d-%d\n", r.track, r.name, int(r.at / 4) + 1, int((r.at + r.length) / 4))

	// 5. Play from the top, looping bars 5-8, for twelve bars.
	transport.set_loop(clock, song, 16, 32)
	transport.play(clock, song)
	w, _ := audiofile.writer_create(bounce_path, audiofile.default_writer_settings(SAMPLE_RATE, 2))
	left, right: [BLOCK]f32
	bars_played, bar, peak := 0, -1, f32(0)
	edited := false
	for bars_played <= 12 {
		ctx := core.Process_Context{outputs = {left[:], right[:]}, frames = BLOCK}
		transport.process(clock, &ctx, proc(user: rawptr, seg: ^core.Process_Context) {
			graph.process((^graph.Graph)(user), seg)
		}, g)
		audiofile.writer_write(w, {left[:], right[:]}, BLOCK)

		pos, _, _ := transport.timeline_status(clock, song)
		if now := int(pos / 4); now != bar {
			if bar >= 0 do fmt.printf("peak %.2f\n", peak)
			bar, peak = now, 0
			bars_played += 1
			if bars_played <= 12 do print_bar(clock, regions[:], pos, edited)
		}
		for s in left do peak = max(peak, abs(s))

		// An edit while it plays: half a bar before the loop goes round, the
		// bass moves up a fourth. The new clip replaces the old one at the
		// next block.
		if !edited && bars_played == 8 && pos >= 30 {
			bass = build_bass(transpose = 5)
			clip.midi_player_set(bass_player, bass, {at = bass_region.at, length = bass_region.length, loop = true})
			clip.midi_clip_release(bass)
			edited = true
		}
	}
	audiofile.writer_close(w)
	fmt.printf("bounced %.1f s, underruns %d\n", f64(transport.status(clock).frame) / SAMPLE_RATE, stream.stats(streamer).underrun_frames)
}

// Adds an automation player for `lane` on `timeline`, moving `target`'s
// parameters. The player holds the clip, so the caller's reference is released.
add_automation :: proc(g: ^graph.Graph, timeline: core.Timeline_Id, target: graph.Node_Id, lane: ^clip.Automation_Clip, placement: clip.Placement) {
	node, player, _ := clip.automation_player_create({timeline = timeline})
	id, _ := graph.add_node(g, node, 0, 0)
	graph.connect_events(g, id, target)
	clip.automation_player_set(player, lane, placement)
	clip.automation_clip_release(lane)
}

// One line per bar: the tempo and the regions under the song position.
print_bar :: proc(clock: ^transport.Clock, regions: []Region, pos: tb.Beats, edited: bool) {
	names: [dynamic]string
	defer delete(names)
	for r in regions {
		if r.at <= pos && pos < r.at + r.length && !strings.contains(r.name, "automation") {
			append(&names, fmt.tprintf("%s %s", r.track, r.name))
		}
	}
	joined := strings.join(names[:], ", ", context.temp_allocator)
	fmt.printf("bar %d at %.0f BPM: %-52s%s", int(pos / 4) + 1, transport.status(clock).tempo_bpm, joined, "(bass edited) " if edited else "")
}

// --- the clips -----------------------------------------------------------------------------

// One bar at 120 BPM: a kick on every beat, with off-beat hats if `hats`.
write_drums :: proc(path: string, hats: bool) {
	frames := int(4 * 60 / 120.0 * SAMPLE_RATE)
	beat := frames / 4
	mono := make([]f32, frames)
	defer delete(mono)
	seed := u32(1)
	for i in 0 ..< frames {
		t := f64(i % beat) / SAMPLE_RATE
		mono[i] = f32(0.7 * math.exp(-t * 18) * math.sin(math.TAU * 50 * t * (1 + 2 * math.exp(-t * 40))))
		if hats && i % beat >= beat / 2 {
			seed = seed * 1664525 + 1013904223 // a little noise
			th := f64(i % beat - beat / 2) / SAMPLE_RATE
			mono[i] += f32(0.25 * math.exp(-th * 60) * (f64(seed >> 8) / f64(1 << 24) * 2 - 1))
		}
	}
	w, _ := audiofile.writer_create(path, audiofile.default_writer_settings(SAMPLE_RATE, 1))
	audiofile.writer_write(w, {mono}, frames)
	audiofile.writer_close(w)
}

// One bar of eighth notes, `transpose` semitones up.
build_bass :: proc(transpose: u8) -> ^clip.Midi_Clip {
	b: clip.Midi_Builder
	clip.midi_builder_init(&b, 4)
	defer clip.midi_builder_destroy(&b)
	keys := [8]u8{36, 36, 48, 36, 36, 46, 36, 43}
	for k, i in keys do clip.add_note(&b, tb.Beats(f64(i) * 0.5), 0.4, k + transpose, 1 if i == 0 else 0.7)
	c, _ := clip.midi_build(&b)
	return c
}

// Two bars: a chord per bar.
build_chords :: proc() -> ^clip.Midi_Clip {
	b: clip.Midi_Builder
	clip.midi_builder_init(&b, 8)
	defer clip.midi_builder_destroy(&b)
	for key in ([]u8{60, 64, 67, 71}) do clip.add_note(&b, 0, 4, key, 0.5)
	for key in ([]u8{57, 60, 64, 67}) do clip.add_note(&b, 4, 4, key, 0.5)
	c, _ := clip.midi_build(&b)
	return c
}
