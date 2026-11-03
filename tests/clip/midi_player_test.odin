package test_clip

import "core:fmt"
import "core:math"
import "core:testing"

import "fire:clip"
import "fire:core"
import tb "fire:timebase"
import kit "fire:testkit"
import "fire:transport"

SR :: 48_000.0

// One event the player emitted, at its absolute frame.
Got :: struct {
	frame:   i64,
	payload: core.Event_Payload,
}

Rig :: struct {
	clock:  ^transport.Clock,
	tl:     core.Timeline_Id,
	node:   core.Node,
	player: ^clip.Midi_Player,
	got:    [dynamic]Got,
	frame:  i64,
	buf:    []core.Event,
	trap:   kit.Trap_Allocator,
}

rig_make :: proc(bpm := 120.0, settings := clip.Midi_Player_Settings{}) -> ^Rig {
	r := new(Rig)
	s := transport.default_settings(SR)
	s.bpm = bpm
	r.clock, _ = transport.create(s)
	r.tl, _ = transport.add_timeline(r.clock)
	st := settings
	st.timeline = r.tl
	r.node, r.player = clip.midi_player_create(st)
	core.node_prepare(&r.node, {sample_rate = SR, max_block = 32_768})
	r.buf = make([]core.Event, 4096)
	return r
}

rig_destroy :: proc(r: ^Rig) {
	core.node_destroy(&r.node)
	transport.destroy(r.clock)
	delete(r.got)
	delete(r.buf)
	free(r)
}

// Processes `total` frames in blocks cycling through `blocks`.
rig_run :: proc(r: ^Rig, total: int, blocks: []int = {512}) {
	for done, k := 0, 0; done < total; k += 1 {
		n := min(blocks[k % len(blocks)], total - done)
		w := core.Event_Writer{buffer = r.buf}
		ctx := core.Process_Context{frames = n, events_out = &w}
		{
			context.allocator = kit.trap_allocator(&r.trap)
			context.temp_allocator = context.allocator
			transport.process(r.clock, &ctx, proc(user: rawptr, seg: ^core.Process_Context) {
				core.node_process(&(^Rig)(user).node, seg)
			}, r)
		}
		for e in core.event_writer_events(&w) do append(&r.got, Got{r.frame + i64(e.offset), e.payload})
		r.frame += i64(n)
		done += n
	}
}

// Frame of beat `b` at a constant tempo (the first frame at or after it).
frame_of :: proc(b: f64, bpm := 120.0) -> i64 {
	return i64(math.ceil(b * 60 / bpm * SR - 1e-6))
}

// A readable form of an event, for comparing sequences.
describe :: proc(g: Got) -> string {
	switch e in g.payload {
	case core.Note_On:         return fmt.tprintf("%d on %d", g.frame, e.key)
	case core.Note_Off:        return fmt.tprintf("%d off %d", g.frame, e.key)
	case core.Note_Expression: return fmt.tprintf("%d expr %d %v %v", g.frame, e.key, e.kind, e.value)
	case core.Midi_Raw:        return fmt.tprintf("%d raw %v", g.frame, e.bytes)
	case core.Param_Value:     return fmt.tprintf("%d param", g.frame)
	}
	return ""
}

expect_sequence :: proc(t: ^testing.T, got: []Got, want: []string, what: string, loc := #caller_location) -> bool {
	n := min(len(got), len(want))
	for i in 0 ..< n {
		if d := describe(got[i]); d != want[i] {
			testing.expectf(t, false, "%s: event %d is %q, want %q", what, i, d, want[i], loc = loc)
			return false
		}
	}
	return testing.expectf(t, len(got) == len(want), "%s: %d events, want %d", what, len(got), len(want), loc = loc)
}

// Every note-off matches an earlier note-on by id, and nothing is left sounding.
expect_balanced :: proc(t: ^testing.T, got: []Got, loc := #caller_location) {
	open := make(map[core.Note_Id]bool, context.temp_allocator)
	for g in got {
		#partial switch e in g.payload {
		case core.Note_On:
			testing.expectf(t, !open[e.id], "note id %d started twice", e.id, loc = loc)
			open[e.id] = true
		case core.Note_Off:
			testing.expectf(t, open[e.id], "note-off for id %d, which is not sounding", e.id, loc = loc)
			delete_key(&open, e.id)
		case core.Note_Expression:
			testing.expectf(t, open[e.id], "expression for id %d, which is not sounding", e.id, loc = loc)
		}
	}
	testing.expectf(t, len(open) == 0, "%d notes left sounding", len(open), loc = loc)
}

// A 4-beat clip: C (0, 1 beat), D (1.5, half a beat), E (3, 2 beats: cut at the loop end).
three_notes :: proc() -> ^clip.Midi_Clip {
	b: clip.Midi_Builder
	clip.midi_builder_init(&b, 4)
	defer clip.midi_builder_destroy(&b)
	clip.add_note(&b, 3, 2, 64, 0.5) // out of order on purpose
	clip.add_note(&b, 0, 1, 60, 1)
	clip.add_note(&b, 1.5, 0.5, 62, 0.75)
	c, _ := clip.midi_build(&b)
	return c
}

loop_events :: proc(loops: int, bpm := 120.0, shift := 0.0) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	for k in 0 ..< loops {
		o := f64(4 * k) + shift
		append(&out,
			fmt.tprintf("%d on 60", frame_of(o, bpm)), fmt.tprintf("%d off 60", frame_of(o + 1, bpm)),
			fmt.tprintf("%d on 62", frame_of(o + 1.5, bpm)), fmt.tprintf("%d off 62", frame_of(o + 2, bpm)),
			fmt.tprintf("%d on 64", frame_of(o + 3, bpm)), fmt.tprintf("%d off 64", frame_of(o + 4, bpm)))
	}
	return out[:]
}

@(test)
loops_on_exact_frames_at_any_block_size :: proc(t: ^testing.T) {
	c := three_notes()
	defer clip.midi_clip_release(c)
	for bpm in ([]f64{120, 117.3}) {
		for blocks in ([][]int{{512}, {1, 7, 333, 4096}, {100}, {24_000}}) {
			r := rig_make(bpm)
			clip.midi_player_set(r.player, c, {loop = true})
			transport.play(r.clock, r.tl)
			rig_run(r, int(frame_of(12, bpm)) - 1, blocks) // three loops, stopping just before the fourth
			transport.stop(r.clock, r.tl)
			rig_run(r, 100)
			want := loop_events(3, bpm)
			want[len(want) - 1] = fmt.tprintf("%d off 64", frame_of(12, bpm) - 1) // ended by the stop, a frame early
			expect_sequence(t, r.got[:], want, fmt.tprintf("%v BPM, blocks %v", bpm, blocks))
			expect_balanced(t, r.got[:])
			testing.expect_value(t, r.trap.violations, 0)
			rig_destroy(r)
		}
	}
}

// Jumping into a note plays it at once; stopping ends everything.
@(test)
notes_in_progress_are_chased :: proc(t: ^testing.T) {
	c := three_notes()
	defer clip.midi_clip_release(c)
	r := rig_make()
	defer rig_destroy(r)
	clip.midi_player_set(r.player, c, {loop = true})
	transport.locate(r.clock, r.tl, 3.5) // inside E
	transport.play(r.clock, r.tl)
	rig_run(r, 24_000) // to beat 4.5
	transport.locate(r.clock, r.tl, 0.25) // inside C
	rig_run(r, 12_000)
	transport.stop(r.clock, r.tl)
	rig_run(r, 100)
	expect_sequence(t, r.got[:], {
		"0 on 64",     // chased at the start
		"12000 off 64", // beat 4: the loop end
		"12000 on 60",
		"24000 off 60", // the locate ends it ...
		"24000 on 60",  // ... and chases C again from 0.25
		"36000 off 60", // stopped (C would end at beat 1 = 18000 frames later)
	}, "chase")
	expect_balanced(t, r.got[:])
}

// An arrangement placement: from beat 8 for 6 beats, starting 0.5 into the
// clip (C is chased at the region start), no loop; E is cut at the clip end.
@(test)
arrangement_placement :: proc(t: ^testing.T) {
	c := three_notes()
	defer clip.midi_clip_release(c)
	r := rig_make()
	defer rig_destroy(r)
	clip.midi_player_set(r.player, c, {at = 8, length = 6, offset = 0.5})
	transport.play(r.clock, r.tl)
	rig_run(r, int(frame_of(16)))
	expect_sequence(t, r.got[:], {
		fmt.tprintf("%d on 60", frame_of(8)), fmt.tprintf("%d off 60", frame_of(8.5)),
		fmt.tprintf("%d on 62", frame_of(9)), fmt.tprintf("%d off 62", frame_of(9.5)),
		fmt.tprintf("%d on 64", frame_of(10.5)), fmt.tprintf("%d off 64", frame_of(11.5)), // clip end
	}, "placement")
	expect_balanced(t, r.got[:])
}

// Looping inside a placed region, ending mid-loop at the region end.
@(test)
looping_region_is_cut_at_its_end :: proc(t: ^testing.T) {
	c := three_notes()
	defer clip.midi_clip_release(c)
	r := rig_make()
	defer rig_destroy(r)
	clip.midi_player_set(r.player, c, {at = 2, length = 7.25, loop = true}) // to beat 9.25
	transport.play(r.clock, r.tl)
	rig_run(r, int(frame_of(12)))
	// Two loops from beat 2; the third would start at beat 10, after the
	// region ends at 9.25.
	want := loop_events(2, 120, 2)
	want[len(want) - 1] = fmt.tprintf("%d off 64", frame_of(9.25)) // cut at the region end
	expect_sequence(t, r.got[:], want, "region")
	expect_balanced(t, r.got[:])
}

@(test)
expression_and_controllers :: proc(t: ^testing.T) {
	b: clip.Midi_Builder
	clip.midi_builder_init(&b, 2)
	n := clip.add_note(&b, 0, 1, 60, 1)
	clip.add_expression(&b, n, 0.5, .Tuning, 2)
	clip.add_expression(&b, n, 0.25, .Volume, 0.5)
	clip.add_expression(&b, n, 1.5, .Volume, 0.1) // after the note ends: never sent
	clip.add_controller(&b, 1, {0xB0, 74, 100})
	c, _ := clip.midi_build(&b)
	clip.midi_builder_destroy(&b)
	defer clip.midi_clip_release(c)

	r := rig_make()
	defer rig_destroy(r)
	clip.midi_player_set(r.player, c, {loop = true})
	transport.play(r.clock, r.tl)
	rig_run(r, int(frame_of(2)) - 1)
	transport.locate(r.clock, r.tl, 0.75) // chase: the latest Volume and Tuning come with it
	rig_run(r, 1000)
	transport.stop(r.clock, r.tl)
	rig_run(r, 10)
	expect_sequence(t, r.got[:], {
		"0 on 60",
		"6000 expr 60 Volume 0.5",
		"12000 expr 60 Tuning 2",
		"24000 off 60",
		"24000 raw [176, 74, 100]",
		"47999 on 60", // the locate lands on the next block's first frame
		"47999 expr 60 Volume 0.5",
		"47999 expr 60 Tuning 2",
		"48999 off 60",
	}, "expression")
	expect_balanced(t, r.got[:])
}

// A new clip swapped in while playing: sounding notes finish, the new
// clip's notes follow, and the old clip is freed (the tracking allocator
// would report it otherwise).
@(test)
editing_while_playing :: proc(t: ^testing.T) {
	r := rig_make()
	defer rig_destroy(r)
	c1 := three_notes()
	clip.midi_player_set(r.player, c1, {loop = true})
	clip.midi_clip_release(c1)
	transport.play(r.clock, r.tl)
	rig_run(r, 30_000) // C has played; D is due at 36000

	b: clip.Midi_Builder
	clip.midi_builder_init(&b, 4)
	clip.add_note(&b, 1.5, 0.5, 72, 1) // D up an octave
	c2, _ := clip.midi_build(&b)
	clip.midi_builder_destroy(&b)
	clip.midi_player_set(r.player, c2, {loop = true})
	clip.midi_clip_release(c2)
	rig_run(r, 30_000)
	transport.stop(r.clock, r.tl)
	rig_run(r, 10)
	expect_sequence(t, r.got[:], {"0 on 60", "24000 off 60", "36000 on 72", "48000 off 72"}, "edit")
	expect_balanced(t, r.got[:])
}

// At rate 2 the timeline runs twice as fast through the clip.
@(test)
timeline_rate :: proc(t: ^testing.T) {
	c := three_notes()
	defer clip.midi_clip_release(c)
	r := rig_make()
	defer rig_destroy(r)
	clip.midi_player_set(r.player, c, {loop = true})
	transport.set_rate(r.clock, r.tl, 2)
	transport.play(r.clock, r.tl)
	rig_run(r, int(frame_of(2)) - 1)
	transport.stop(r.clock, r.tl)
	rig_run(r, 10)
	expect_sequence(t, r.got[:], {
		"0 on 60", "12000 off 60", "18000 on 62", "24000 off 62", "36000 on 64", "47999 off 64",
	}, "rate 2")
}

@(test)
bad_clips_are_rejected :: proc(t: ^testing.T) {
	b: clip.Midi_Builder
	clip.midi_builder_init(&b, 0)
	defer clip.midi_builder_destroy(&b)
	_, err := clip.midi_build(&b)
	testing.expect_value(t, err, core.Error.Invalid_Argument)
	b.length = 4
	clip.set_loop(&b, 3, 2)
	_, err = clip.midi_build(&b)
	testing.expect_value(t, err, core.Error.Invalid_Argument)
}

// An awkward loop (3.3 beats at 117.3 BPM, notes ending exactly where the
// next begins) for a minute: every block pattern gives the same events, and
// every loop plays all its notes exactly once.
@(test)
awkward_loops_are_block_size_invariant :: proc(t: ^testing.T) {
	b: clip.Midi_Builder
	clip.midi_builder_init(&b, 3.3)
	for k in 0 ..< 3 do clip.add_note(&b, tb.Beats(1.1 * f64(k)), 1.1, u8(60 + k), 1)
	c, _ := clip.midi_build(&b)
	clip.midi_builder_destroy(&b)
	defer clip.midi_clip_release(c)

	run :: proc(c: ^clip.Midi_Clip, blocks: []int) -> [dynamic]string {
		r := rig_make(117.3)
		defer rig_destroy(r)
		clip.midi_player_set(r.player, c, {loop = true})
		transport.play(r.clock, r.tl)
		rig_run(r, 60 * 48_000, blocks)
		out := make([dynamic]string)
		for g in r.got do append(&out, describe(g))
		return out
	}
	ref := run(c, {512})
	defer delete(ref)
	ons := 0
	for e in ref do if len(e) > 4 && e[len(e) - 5:len(e) - 3] == "on" do ons += 1
	beats := 60 * 117.3 / 60
	testing.expectf(t, ons == int(math.ceil(beats / 1.1 - 1e-9)), "%d notes in %v beats", ons, beats)
	for blocks in ([][]int{{1, 7, 333, 4096}, {100}, {24_000}, {13}}) {
		got := run(c, blocks)
		defer delete(got)
		n := min(len(got), len(ref))
		same := len(got) == len(ref)
		for i in 0 ..< n do if got[i] != ref[i] {
			testing.expectf(t, false, "blocks %v: event %d is %q, with 512-frame blocks %q", blocks, i, got[i], ref[i])
			same = false
			break
		}
		testing.expectf(t, same, "blocks %v: %d events, with 512-frame blocks %d", blocks, len(got), len(ref))
	}
}
