/*
Loop recording, offline: a one-bar loop plays three times while a
simulated performer sings on the beats (arriving 480 frames late, as
through an audio interface), plays a keyboard, and moves a filter knob.

- The audio recorder compensates the latency and keeps each pass as a take.
- The MIDI recorder overdubs: each pass is merged into the loop's clip
  when it ends (a live app would also merge `midi_recorder_progress` as
  notes are played, so they sound on the next pass).
- The automation recorder writes the knob into the filter's lane while it
  is held (touch), and the player plays the lane back.

	odin run examples/recording -collection:fire=f_engine
*/
package recording

import "core:fmt"
import "core:math"
import "core:os"

import "fire:audiofile"
import "fire:clip"
import "fire:core"
import "fire:dsp"
import "fire:graph"
import "fire:record"
import "fire:transport"

SAMPLE_RATE :: 48_000.0
BLOCK :: 512
BEAT :: 24_000 // frames per beat at 120 BPM
ROUND_TRIP :: 480 // the interface's latency, as `backend.round_trip_latency_frames` would report it

main :: proc() {
	dir, _ := os.make_directory_temp("", "fire_recording", context.allocator)
	defer os.remove_all(dir)

	// 1. A one-bar loop on the song timeline.
	clock, _ := transport.create(transport.default_settings(SAMPLE_RATE))
	defer transport.destroy(clock)
	song, _ := transport.add_timeline(clock)
	transport.set_loop(clock, song, 0, 4)

	disk, _ := record.disk_writer_create({manual = true}) // offline: written as we go, nothing dropped
	defer record.disk_writer_destroy(disk)
	settings := graph.default_settings(SAMPLE_RATE, BLOCK)
	settings.input_channels, settings.output_channels, settings.workers = 1, 1, 0
	g, _ := graph.create(settings)
	defer graph.destroy(g)

	// 2. Recorders: audio from input 1, MIDI from the input events, and a
	//    writer for a filter's cutoff (the filter's lane plays from a player).
	anode, audio, _ := record.audio_recorder_create(disk, {timeline = song, channels = 1, directory = dir, name = "vocal", latency_frames = ROUND_TRIP})
	a, _ := graph.add_node(g, anode, 1, 0)
	graph.connect(g, graph.INPUT, 0, a, 0)
	mnode, keys, _ := record.midi_recorder_create({timeline = song})
	m, _ := graph.add_node(g, mnode, 0, 0)
	graph.connect_events(g, graph.INPUT, m)
	filter, _ := graph.add_node(g, dsp.one_pole_create(), 1, 1)
	graph.connect(g, graph.INPUT, 0, filter, 0)
	graph.connect(g, filter, 0, graph.OUTPUT, 0)
	wnode, knob, _ := record.automation_recorder_create({timeline = song, mode = .Touch})
	w, _ := graph.add_node(g, wnode, 0, 0)
	graph.connect_events(g, w, filter)
	lnode, lane, _ := clip.automation_player_create({timeline = song})
	l, _ := graph.add_node(g, lnode, 0, 0)
	graph.connect_events(g, l, filter)
	graph.commit(g)

	// 3. The loop's MIDI clip, empty at first, and the overdub base.
	b: clip.Midi_Builder
	clip.midi_builder_init(&b, 4)
	loop_clip, _ := clip.midi_build(&b)
	clip.midi_builder_destroy(&b)
	defer clip.midi_clip_release(loop_clip)
	cutoff: ^clip.Automation_Clip // the filter's lane, once written

	// 4. Three passes. The performer: a burst on every beat, notes on beats
	//    1 and 2 of the first pass and beat 3 of the second, and a knob held
	//    through the third pass's second half.
	record.audio_recorder_arm(audio, true)
	record.midi_recorder_arm(keys, true)
	record.automation_recorder_arm(knob, true)
	transport.play(clock, song)
	transport.stop(clock, song, transport.At_Beat(12))
	notes := []struct{ beat: f64, key: u8 }{{1, 60}, {2, 64}, {7, 67}}
	input: [BLOCK]f32
	out: [BLOCK]f32
	events: [8]core.Event
	for at := 0; at < 13 * BEAT; at += BLOCK {
		n := 0
		for x in notes {
			f := int(x.beat * BEAT)
			if f >= at && f < at + BLOCK {
				events[n] = {offset = u32(f - at), payload = core.Note_On{id = core.NOTE_ID_ANY, key = x.key, velocity = 0.8}}
				n += 1
			}
			if f + BEAT / 2 >= at && f + BEAT / 2 < at + BLOCK {
				events[n] = {offset = u32(f + BEAT / 2 - at), payload = core.Note_Off{id = core.NOTE_ID_ANY, key = x.key}}
				n += 1
			}
		}
		for &s, i in input {
			f := at + i - ROUND_TRIP // heard late, sung on the beat, arriving late again
			s = f32(0.5 * math.sin(math.TAU * 440 * f64(f) / SAMPLE_RATE)) if f >= 0 && f % BEAT < 2400 else 0
		}
		if at <= 10 * BEAT && 10 * BEAT < at + BLOCK {
			clip.automation_player_suspend(lane, dsp.ONE_POLE_PARAM_CUTOFF_HZ)
			record.automation_recorder_touch(knob, dsp.ONE_POLE_PARAM_CUTOFF_HZ, 400)
		}
		if at <= 11 * BEAT && 11 * BEAT < at + BLOCK do record.automation_recorder_set(knob, dsp.ONE_POLE_PARAM_CUTOFF_HZ, 3000)

		ctx := core.Process_Context{inputs = {input[:]}, outputs = {out[:]}, frames = BLOCK, events_in = events[:n]}
		transport.process(clock, &ctx, proc(user: rawptr, seg: ^core.Process_Context) {
			graph.process((^graph.Graph)(user), seg)
		}, g)
		record.disk_writer_service(disk)

		// Overdub: merge each finished pass into the loop.
		for take in record.midi_recorder_poll(keys) do loop_clip = overdub(loop_clip, take)
	}
	record.automation_recorder_release(knob, dsp.ONE_POLE_PARAM_CUTOFF_HZ)

	// 5. What was recorded.
	for t in record.audio_recorder_poll(audio) {
		take := t
		defer record.take_destroy(&take)
		fmt.printf("audio take %d (pass %d): beats %.0f-%.0f, %d frames, first burst at beat %.4f\n",
			take.run, take.pass, f64(take.start), f64(take.start + take.length), take.frames, first_burst(take))
	}
	fmt.printf("loop clip after overdubs: %d notes:", len(loop_clip.notes))
	for n in loop_clip.notes do fmt.printf(" key %d at beat %.2f;", n.key, f64(n.start))
	fmt.println()
	for take in record.automation_recorder_poll(knob) {
		defer delete(take.points)
		merged, _ := clip.automation_merge(cutoff, take.param, take.start, take.end, take.points, length = 4)
		clip.automation_clip_release(cutoff)
		cutoff = merged
		fmt.printf("cutoff written over beats %.2f-%.2f (pass %d), %d points\n", f64(take.start), f64(take.end), take.pass, len(take.points))
	}
	if cutoff != nil {
		ln := clip.automation_lane(cutoff, dsp.ONE_POLE_PARAM_CUTOFF_HZ)
		fmt.printf("the lane: %.0f Hz at beat 2.5, %.0f Hz at beat 3.5\n", clip.automation_value(ln, 2.5), clip.automation_value(ln, 3.5))
		clip.automation_player_set(lane, cutoff, {loop = true})
		clip.automation_player_resume(lane, dsp.ONE_POLE_PARAM_CUTOFF_HZ)
		clip.automation_clip_release(cutoff)
	}
}

// The loop with a take merged in. Takes the caller's reference to `loop`.
overdub :: proc(loop: ^clip.Midi_Clip, take: record.Midi_Take) -> ^clip.Midi_Clip {
	b: clip.Midi_Builder
	clip.midi_builder_init(&b, loop.length)
	defer clip.midi_builder_destroy(&b)
	clip.add_clip(&b, loop)
	clip.add_clip(&b, take.clip, take.start)
	merged, _ := clip.midi_build(&b)
	clip.midi_clip_release(loop)
	clip.midi_clip_release(take.clip)
	return merged
}

// Where in the take its first sound is, in beats from the take's start.
first_burst :: proc(take: record.Take) -> f64 {
	rd, err := audiofile.open(take.path)
	if err != .None do return -1
	defer audiofile.close(rd)
	data := make([]f32, take.frames)
	defer delete(data)
	audiofile.read(rd, {data}, len(data))
	for x, i in data do if abs(x) > 0.01 do return f64(i) / BEAT
	return -1
}
