/*
A clip launcher: two tracks (audio drums and a MIDI bass) by two scenes.
Every slot has its own timeline, so launching one is locating it to its
start and playing it on the next bar, while the track's other slots stop on
that same bar. Each bass slot also carries an automation clip for the
track's filter, which plays on the slot's timeline as its envelope.

A script launches slots, scenes and stops as a performer would, mid-bar;
the program renders eight bars offline, prints what starts and stops on
which bar, and bounces the result to a WAV file.

	odin run examples/clip_launcher -collection:fire=f_engine
*/
package clip_launcher

import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:path/filepath"
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
BPM :: 120.0
SCENES :: 2

// --- the launcher ------------------------------------------------------------------------

// One cell of the grid: a clip on its own timeline (empty when `name` is "").
Slot :: struct {
	name:        string,
	timeline:    core.Timeline_Id,
	was_playing: bool, // for the log
}

// A column of slots. Only one slot of a track plays at a time.
Track :: struct {
	name:  string,
	slots: [SCENES]Slot,
}

// Launches a slot on the next bar: it starts from its beginning (again, if it
// was already playing) and the track's other slots stop on that bar.
launch :: proc(clock: ^transport.Clock, track: ^Track, scene: int) {
	for &s, i in track.slots {
		if s.name == "" do continue
		if i == scene {
			transport.locate(clock, s.timeline, 0, tb.Quantize.Bar)
			transport.play(clock, s.timeline, tb.Quantize.Bar)
		} else {
			transport.stop(clock, s.timeline, tb.Quantize.Bar)
		}
	}
}

// Launches every track's slot in a row.
launch_scene :: proc(clock: ^transport.Clock, tracks: []Track, scene: int) {
	for &t in tracks do launch(clock, &t, scene)
}

// Stops a track on the next bar.
stop_track :: proc(clock: ^transport.Clock, track: ^Track) {
	for s in track.slots do if s.name != "" do transport.stop(clock, s.timeline, tb.Quantize.Bar)
}

// --- the session ---------------------------------------------------------------------------

main :: proc() {
	dir, _ := os.make_directory_temp("", "fire_clip_launcher", context.allocator)
	defer os.remove_all(dir)
	bounce_path, _ := filepath.join({dir, "launcher.wav"}, context.allocator)
	defer delete(bounce_path)

	// 1. A clock at 120 BPM with no leader: the grid's bars are the launch
	//    quantum. One timeline per slot.
	clock, _ := transport.create(transport.default_settings(SAMPLE_RATE))
	defer transport.destroy(clock)
	tracks := [?]Track {
		{name = "Drums", slots = {{name = "four on the floor"}, {name = "with hats"}}},
		{name = "Bass", slots = {{name = "root"}, {name = "walk + sweep"}}},
	}
	for &t in tracks do for &s in t.slots do s.timeline, _ = transport.add_timeline(clock)
	drums, bass := &tracks[0], &tracks[1]

	streamer, _ := stream.create(stream.default_settings()) // outlives the graph's players
	defer stream.destroy(streamer)
	settings := graph.default_settings(SAMPLE_RATE, BLOCK)
	settings.input_channels, settings.workers = 0, 0
	g, _ := graph.create(settings)
	defer graph.destroy(g)

	// 2. Drums: an audio player per slot, all into OUTPUT (summed there).
	drum_players: [SCENES]^clip.Audio_Player
	for &s, i in drums.slots {
		path, _ := filepath.join({dir, fmt.tprintf("drums_%d.wav", i)}, context.allocator)
		defer delete(path)
		write_drums(path, hats = i == 1)
		src, err := stream.source_open(streamer, path)
		if err != .None {
			fmt.eprintln("source_open:", err)
			return
		}
		loop, _ := clip.audio_clip_create(src, {bpm = BPM, mode = .Repitch})
		stream.source_release(src) // the clip holds it
		node, player := clip.audio_player_create(clip.default_audio_player_settings(s.timeline, streamer))
		id, _ := graph.add_node(g, node, 0, 2)
		graph.connect(g, id, 0, graph.OUTPUT, 0)
		graph.connect(g, id, 1, graph.OUTPUT, 1)
		clip.audio_player_set(player, loop, {loop = true})
		clip.audio_clip_release(loop) // the player holds it
		drum_players[i] = player
	}

	// 3. Bass: one synth and filter for the track. Each slot has a MIDI
	//    player for its notes and an automation player for the filter.
	synth, _ := graph.add_node(g, synth_create(), 0, 1)
	filter, _ := graph.add_node(g, dsp.one_pole_create(), 1, 1)
	graph.connect(g, synth, 0, filter, 0)
	graph.connect(g, filter, 0, graph.OUTPUT, 0)
	graph.connect(g, filter, 0, graph.OUTPUT, 1)
	for s, i in bass.slots {
		notes := build_bass(walk = i == 1)
		node, player := clip.midi_player_create({timeline = s.timeline})
		id, _ := graph.add_node(g, node, 0, 0)
		graph.connect_events(g, id, synth)
		clip.midi_player_set(player, notes, {loop = true})
		clip.midi_clip_release(notes)

		envelope := build_envelope(sweep = i == 1)
		anode, aplayer, _ := clip.automation_player_create({timeline = s.timeline})
		aid, _ := graph.add_node(g, anode, 0, 0)
		graph.connect_events(g, aid, filter)
		clip.automation_player_set(aplayer, envelope, {loop = true})
		clip.automation_clip_release(envelope)
	}
	graph.commit(g)
	for p in drum_players do for !clip.audio_player_ready(p) do time.sleep(time.Millisecond) // preroll

	// 4. The performance: what is pressed, and when (in seconds; a bar is 2 s).
	Press :: struct {
		at:     f64,
		action: enum {Scene, Slot, Stop_Track, Stop_All},
		track:  int,
		scene:  int,
	}
	script := [?]Press {
		{at = 0.0, action = .Scene, scene = 0},
		{at = 3.0, action = .Slot, track = 0, scene = 1}, // mid-bar 2: starts on bar 3
		{at = 7.4, action = .Scene, scene = 1},           // bar 5: drums restart, bass walks
		{at = 11.2, action = .Stop_Track, track = 1},     // bar 7: drums alone
		{at = 13.9, action = .Stop_All},                  // bar 8
	}

	// 5. Render eight bars, logging presses and what they did.
	w, _ := audiofile.writer_create(bounce_path, audiofile.default_writer_settings(SAMPLE_RATE, 2))
	left, right: [BLOCK]f32
	next, peak := 0, f32(0)
	frames := int(8 * 4 * 60 / BPM * SAMPLE_RATE)
	for at := 0; at < frames; at += BLOCK {
		for next < len(script) && int(script[next].at * SAMPLE_RATE) < at + BLOCK {
			p := script[next]
			bar := script[next].at * BPM / 60 / 4 + 1
			switch p.action {
			case .Scene:
				fmt.printf("%4.1f s (bar %.2f): press scene %d\n", p.at, bar, p.scene + 1)
				launch_scene(clock, tracks[:], p.scene)
			case .Slot:
				fmt.printf("%4.1f s (bar %.2f): press %s: %s\n", p.at, bar, tracks[p.track].name, tracks[p.track].slots[p.scene].name)
				launch(clock, &tracks[p.track], p.scene)
			case .Stop_Track:
				fmt.printf("%4.1f s (bar %.2f): stop %s\n", p.at, bar, tracks[p.track].name)
				stop_track(clock, &tracks[p.track])
			case .Stop_All:
				fmt.printf("%4.1f s (bar %.2f): stop all\n", p.at, bar)
				for &t in tracks do stop_track(clock, &t)
			}
			next += 1
		}

		ctx := core.Process_Context{outputs = {left[:], right[:]}, frames = BLOCK}
		transport.process(clock, &ctx, proc(user: rawptr, seg: ^core.Process_Context) {
			graph.process((^graph.Graph)(user), seg)
		}, g)
		for s in left do peak = max(peak, abs(s))
		audiofile.writer_write(w, {left[:], right[:]}, BLOCK)

		// The clock applied quantized commands on the bar inside this block.
		bar := int(transport.status(clock).grid / 4) + 1
		for &t in tracks do for &s in t.slots {
			_, playing, _ := transport.timeline_status(clock, s.timeline)
			if playing != s.was_playing {
				fmt.printf("    bar %d: %s %s %s\n", bar, t.name, s.name, "starts" if playing else "stops")
				s.was_playing = playing
			}
		}
	}
	audiofile.writer_close(w)
	fmt.printf("bounced eight bars, peak %.2f, underruns %d\n", peak, stream.stats(streamer).underrun_frames)
}

// --- the clips -----------------------------------------------------------------------------

// One bar at 120 BPM: a kick on every beat, with off-beat hats if `hats`.
write_drums :: proc(path: string, hats: bool) {
	frames := int(4 * 60 / BPM * SAMPLE_RATE)
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

// One bar of eighth notes: on the root, or walking up the scale.
build_bass :: proc(walk: bool) -> ^clip.Midi_Clip {
	b: clip.Midi_Builder
	clip.midi_builder_init(&b, 4)
	defer clip.midi_builder_destroy(&b)
	keys := [8]u8{36, 36, 36, 36, 36, 36, 36, 43}
	if walk do keys = {36, 38, 40, 43, 45, 43, 40, 38}
	for k, i in keys do clip.add_note(&b, tb.Beats(f64(i) * 0.5), 0.4, k, 1 if i == 0 else 0.7)
	c, _ := clip.midi_build(&b)
	return c
}

// The filter's envelope for a bass slot: steady and dark, or a two-bar
// sweep up and back down.
build_envelope :: proc(sweep: bool) -> ^clip.Automation_Clip {
	b: clip.Automation_Builder
	clip.automation_builder_init(&b, 8 if sweep else 4)
	defer clip.automation_builder_destroy(&b)
	cutoff := dsp.ONE_POLE_PARAM_CUTOFF_HZ
	if sweep {
		clip.automation_add_point(&b, cutoff, 0, 200, .Curve, tension = 0.5)
		clip.automation_add_point(&b, cutoff, 4, 4000)
		clip.automation_add_point(&b, cutoff, 8, 200)
	} else {
		clip.automation_add_point(&b, cutoff, 0, 600)
	}
	c, _ := clip.automation_build(&b)
	return c
}

// --- a small synth -------------------------------------------------------------------------

// Eight voices of a decaying sawtooth: just enough to hear the bass clips.
Synth :: struct {
	voices:      [8]Voice,
	sample_rate: f64,
}

Voice :: struct {
	id:    core.Note_Id,
	key:   u8,
	phase: f64,
	step:  f64, // cycles per frame
	level: f64, // velocity times the envelope
	decay: f64, // per-frame multiplier
}

synth_vtable := core.Node_VTable {
	prepare = proc(self: rawptr, cfg: core.Prepare_Config, a: mem.Allocator) -> core.Error {
		s := (^Synth)(self)
		s^ = {sample_rate = cfg.sample_rate}
		return .None
	},
	process = synth_process,
	reset   = proc(self: rawptr) { s := (^Synth)(self); s.voices = {} },
	destroy = proc(self: rawptr, a: mem.Allocator) { free(self, a) },
}

synth_create :: proc() -> core.Node {
	return core.node_make(&synth_vtable, new(Synth), context.allocator)
}

// [rt]
synth_process :: proc(self: rawptr, ctx: ^core.Process_Context) {
	s := (^Synth)(self)
	out := ctx.outputs[0]
	pos := 0
	for e in ctx.events_in {
		synth_render(s, out[pos:e.offset])
		pos = int(e.offset)
		#partial switch v in e.payload {
		case core.Note_On:
			quietest := 0
			for voice, i in s.voices do if voice.level < s.voices[quietest].level do quietest = i
			s.voices[quietest] = {
				id    = v.id,
				key   = v.key,
				step  = 440 * math.pow(2, (f64(v.key) - 69) / 12) / s.sample_rate,
				level = 0.3 * f64(v.velocity),
				decay = math.exp(-3 / s.sample_rate), // a third of a second
			}
		case core.Note_Off:
			for &voice in s.voices {
				if voice.level > 0 && (voice.id == v.id || (v.id == core.NOTE_ID_ANY && voice.key == v.key)) {
					voice.decay = math.exp(-60 / s.sample_rate) // a quick release
				}
			}
		}
	}
	synth_render(s, out[pos:ctx.frames])
}

// [rt]
synth_render :: proc(s: ^Synth, out: []f32) {
	for &x in out do x = 0
	for &v in s.voices {
		if v.level < 1e-4 {
			v.level = 0
			continue
		}
		for &x in out {
			x += f32(v.level * (2 * v.phase - 1))
			v.phase += v.step
			if v.phase >= 1 do v.phase -= 1
			v.level *= v.decay
		}
	}
}
