package test_record

import "core:testing"

import "fire:clip"
import "fire:core"
import "fire:record"
import tb "fire:timebase"
import kit "fire:testkit"
import "fire:transport"

// An event to send at a clock frame.
At :: struct {
	frame:   i64,
	payload: core.Event_Payload,
}

Midi_Rig :: struct {
	clock: ^transport.Clock,
	tl:    core.Timeline_Id,
	node:  core.Node,
	rec:   ^record.Midi_Recorder,
	frame: i64,
	trap:  kit.Trap_Allocator,
}

midi_rig_make :: proc(latency := 0) -> ^Midi_Rig {
	r := new(Midi_Rig)
	r.clock, _ = transport.create(transport.default_settings(SR))
	r.tl, _ = transport.add_timeline(r.clock)
	r.node, r.rec, _ = record.midi_recorder_create({timeline = r.tl, latency_frames = latency})
	core.node_prepare(&r.node, {sample_rate = SR, max_block = 32_768})
	return r
}

midi_rig_destroy :: proc(r: ^Midi_Rig) {
	core.node_destroy(&r.node)
	transport.destroy(r.clock)
	free(r)
}

// Runs `total` frames, sending `events` (sorted by frame) as they fall due.
midi_rig_run :: proc(r: ^Midi_Rig, total: int, events: []At, blocks: []int = {512}) {
	buf: [64]core.Event
	k := 0
	for done, b := 0, 0; done < total; b += 1 {
		n := min(blocks[b % len(blocks)], total - done)
		count := 0
		for k < len(events) && events[k].frame < r.frame + i64(n) {
			if events[k].frame >= r.frame {
				buf[count] = {offset = u32(events[k].frame - r.frame), payload = events[k].payload}
				count += 1
			}
			k += 1
		}
		ctx := core.Process_Context{frames = n, events_in = buf[:count]}
		{
			context.allocator = kit.trap_allocator(&r.trap)
			context.temp_allocator = context.allocator
			transport.process(r.clock, &ctx, proc(user: rawptr, seg: ^core.Process_Context) {
				core.node_process(&(^Midi_Rig)(user).node, seg)
			}, r)
		}
		r.frame += i64(n)
		done += n
	}
}

midi_takes :: proc(r: ^Midi_Rig) -> [dynamic]record.Midi_Take {
	takes := make([dynamic]record.Midi_Take, context.temp_allocator)
	for take in record.midi_recorder_poll(r.rec) do append(&takes, take)
	return takes
}

midi_takes_release :: proc(takes: []record.Midi_Take) {
	for t in takes do clip.midi_clip_release(t.clip)
}

on :: proc(frame: i64, key: u8, velocity: f32 = 0.8) -> At {
	return {frame, core.Note_On{id = core.NOTE_ID_ANY, key = key, velocity = velocity}}
}

off :: proc(frame: i64, key: u8) -> At {
	return {frame, core.Note_Off{id = core.NOTE_ID_ANY, key = key, velocity = 0.25}}
}

near :: proc(a, b: tb.Beats) -> bool {
	return abs(f64(a - b)) < 1e-9
}

@(test)
notes_land_on_their_beats_at_any_block_size :: proc(t: ^testing.T) {
	for p in ([][]int{{512}, {1, 999, 64}, {7000}}) {
		r := midi_rig_make(latency = 240)
		defer midi_rig_destroy(r)
		record.midi_recorder_arm(r.rec, true)
		transport.play(r.clock, r.tl)
		transport.stop(r.clock, r.tl, transport.At_Beat(4))
		events := []At {
			on(BEAT / 2 + 240, 60), // played on beat 0.5, arriving 240 frames late
			{BEAT + 240, core.Midi_Raw{bytes = {0xB0, 74, 99}}},
			{BEAT + 600, core.Note_Expression{id = core.NOTE_ID_ANY, key = 60, kind = .Tuning, value = 2}},
			off(BEAT * 3 / 2 + 240, 60),
		}
		midi_rig_run(r, 5 * BEAT, events, p)
		takes := midi_takes(r)
		defer midi_takes_release(takes[:])
		if !testing.expect_value(t, len(takes), 1) do continue
		tk := takes[0]
		testing.expect_value(t, tk.start, tb.Beats(0))
		testing.expect(t, near(tk.length, 4))
		c := tk.clip
		if !testing.expect_value(t, len(c.notes), 1) do continue
		n := c.notes[0]
		testing.expect(t, near(n.start, 0.5) && near(n.length, 1))
		testing.expect_value(t, n.key, u8(60))
		testing.expect_value(t, n.velocity, f32(0.8))
		testing.expect_value(t, n.release, f32(0.25))
		testing.expect_value(t, n.expression[1], 1)
		testing.expect(t, near(c.expression[n.expression[0]].at, tb.Beats(f64(360) / BEAT + 0.5)))
		testing.expect_value(t, len(c.controllers), 1)
		testing.expect(t, near(c.controllers[0].at, 1))
		testing.expect_value(t, r.trap.violations, 0)
	}
}

@(test)
loop_passes_are_takes_that_overdub :: proc(t: ^testing.T) {
	r := midi_rig_make()
	defer midi_rig_destroy(r)
	record.midi_recorder_arm(r.rec, true)
	transport.set_loop(r.clock, r.tl, 0, 4)
	transport.play(r.clock, r.tl)
	transport.stop(r.clock, r.tl, transport.At_Beat(8))
	events := []At {
		on(1 * BEAT, 60), off(2 * BEAT, 60),          // pass 0
		on(3.5 * BEAT, 64), off(4.5 * BEAT, 64),      // held across the wrap: cut at the loop end
		on(6 * BEAT, 67), off(7 * BEAT, 67),          // pass 1
	}
	midi_rig_run(r, 9 * BEAT, events, {500})
	takes := midi_takes(r)
	defer midi_takes_release(takes[:])
	if !testing.expect_value(t, len(takes), 2) do return
	testing.expect_value(t, takes[0].pass, 0)
	testing.expect_value(t, takes[1].pass, 1)
	testing.expect_value(t, takes[1].run, takes[0].run)
	testing.expect_value(t, len(takes[0].clip.notes), 2)
	testing.expect(t, near(takes[0].clip.notes[1].length, 0.5))
	testing.expect_value(t, len(takes[1].clip.notes), 1)
	testing.expect(t, near(takes[1].clip.notes[0].start, 2))

	// Overdub: every pass merged into one loop.
	b: clip.Midi_Builder
	clip.midi_builder_init(&b, 4)
	defer clip.midi_builder_destroy(&b)
	for tk in takes do clip.add_clip(&b, tk.clip, tk.start)
	merged, _ := clip.midi_build(&b)
	defer clip.midi_clip_release(merged)
	keys: [dynamic]u8
	defer delete(keys)
	for n in merged.notes do append(&keys, n.key)
	testing.expect_value(t, len(keys), 3)
	testing.expect(t, keys[0] == 60 && keys[1] == 67 && keys[2] == 64) // by start: 1, 2, 3.5
}

@(test)
progress_shows_finished_notes_as_they_come :: proc(t: ^testing.T) {
	r := midi_rig_make()
	defer midi_rig_destroy(r)
	record.midi_recorder_arm(r.rec, true)
	transport.play(r.clock, r.tl)
	midi_rig_run(r, 2 * BEAT, {on(BEAT / 2, 60), off(BEAT, 60), on(BEAT + 100, 62)})
	p, ok := record.midi_recorder_progress(r.rec)
	if testing.expect(t, ok) {
		testing.expect_value(t, len(p.clip.notes), 1) // the held one isn't there yet
		clip.midi_clip_release(p.clip)
	}
	_, again := record.midi_recorder_progress(r.rec)
	testing.expect(t, !again) // nothing new
	transport.stop(r.clock, r.tl)
	midi_rig_run(r, 512, {})
	takes := midi_takes(r)
	defer midi_takes_release(takes[:])
	if testing.expect_value(t, len(takes), 1) do testing.expect_value(t, len(takes[0].clip.notes), 2)
}

@(test)
punch_keeps_only_notes_inside :: proc(t: ^testing.T) {
	r := midi_rig_make()
	defer midi_rig_destroy(r)
	record.midi_recorder_arm(r.rec, true)
	record.midi_recorder_set_punch(r.rec, 2, 4)
	transport.play(r.clock, r.tl)
	events := []At{on(BEAT, 60), off(BEAT + 10, 60), on(3 * BEAT, 62), off(3 * BEAT + 10, 62), on(5 * BEAT, 64), off(5 * BEAT + 10, 64)}
	midi_rig_run(r, 6 * BEAT, events)
	takes := midi_takes(r)
	defer midi_takes_release(takes[:])
	if !testing.expect_value(t, len(takes), 1) do return
	testing.expect_value(t, takes[0].start, tb.Beats(2))
	testing.expect_value(t, takes[0].length, tb.Beats(2))
	if testing.expect_value(t, len(takes[0].clip.notes), 1) {
		testing.expect(t, near(takes[0].clip.notes[0].start, 1)) // beat 3, from the take's start
	}
}
