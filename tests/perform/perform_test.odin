package test_perform

import "core:fmt"
import "core:testing"

import "fire:core"
import "fire:perform"
import kit "fire:testkit"
import tb "fire:timebase"

STEP :: 6000 // a 1/16 at 120 BPM and 48 kHz

on :: proc(frame: i64, key: u8, vel: f32 = 0.8) -> kit.Timed_Event {
	return {time = tb.Sample_Time(frame), payload = core.Note_On{id = core.NOTE_ID_ANY, key = key, velocity = vel}}
}
off :: proc(frame: i64, key: u8) -> kit.Timed_Event {
	return {time = tb.Sample_Time(frame), payload = core.Note_Off{id = core.NOTE_ID_ANY, key = key}}
}

Made :: struct {
	frame: i64,
	key:   u8,
	on:    bool,
}

// Renders `events` through a node for `frames` frames; the notes it made.
run :: proc(t: ^testing.T, node: ^core.Node, events: []kit.Timed_Event, frames: int, blocks: kit.Block_Pattern = nil) -> [dynamic]Made {
	cfg := kit.default_render_config()
	cfg.out_channels = 0
	cfg.events = events
	cfg.tail_frames = frames
	cfg.blocks = blocks
	_, r := kit.render(node, kit.buffer_make(0, 0, 48_000, context.temp_allocator), cfg, context.temp_allocator)
	kit.expect_clean_render(t, r)
	made := make([dynamic]Made, context.temp_allocator)
	for e in r.events_out {
		#partial switch v in e.payload {
		case core.Note_On:  append(&made, Made{i64(e.time), v.key, true})
		case core.Note_Off: append(&made, Made{i64(e.time), v.key, false})
		}
	}
	return made
}

ons :: proc(made: []Made) -> (frames: [dynamic]i64, keys: [dynamic]u8) {
	frames = make([dynamic]i64, context.temp_allocator)
	keys = make([dynamic]u8, context.temp_allocator)
	for m in made do if m.on {
		append(&frames, m.frame)
		append(&keys, m.key)
	}
	return
}

balanced :: proc(t: ^testing.T, made: []Made, loc := #caller_location) {
	depth := 0
	for m in made {
		depth += 1 if m.on else -1
		testing.expectf(t, depth >= 0 && depth <= 1, "one note at a time (%v)", made, loc = loc)
	}
	testing.expectf(t, depth == 0, "every note ends", loc = loc)
}

// (At 1/16 unless `s` says otherwise: the tests count in 1/16 steps.)
arp :: proc(t: ^testing.T, s: perform.Arp_Settings, events: []kit.Timed_Event, frames: int, blocks: kit.Block_Pattern = nil) -> [dynamic]Made {
	st := s
	if st.rate == .Quarter do st.rate = .Sixteenth
	node, _ := perform.arp_node_create(st)
	defer core.node_destroy(&node)
	return run(t, &node, events, frames, blocks)
}

chord :: proc(release: i64) -> []kit.Timed_Event {
	ev := make([]kit.Timed_Event, 6, context.temp_allocator)
	ev[0], ev[1], ev[2] = on(0, 60), on(0, 64), on(0, 67)
	ev[3], ev[4], ev[5] = off(release, 60), off(release, 64), off(release, 67)
	return ev
}

@(test)
arp_walks_the_chord_on_the_grid :: proc(t: ^testing.T) {
	made := arp(t, {mode = .Up, rate = .Sixteenth}, chord(8 * STEP - 1), 10 * STEP)
	frames, keys := ons(made[:])
	testing.expectf(t, len(keys) == 8, "8 steps (%v)", keys)
	want := []u8{60, 64, 67, 60, 64, 67, 60, 64}
	for k, i in want do if i < len(keys) {
		testing.expect_value(t, keys[i], k)
		testing.expect_value(t, frames[i], i64(i * STEP))
	}
	balanced(t, made[:])
	// Gate 0.5: each note ends halfway through its step.
	for m in made do if !m.on do testing.expectf(t, m.frame % STEP == STEP / 2 || m.frame == 8 * STEP - 1, "note-off at %d", m.frame)
}

@(test)
arp_modes_and_octaves :: proc(t: ^testing.T) {
	check :: proc(t: ^testing.T, s: perform.Arp_Settings, events: []kit.Timed_Event, want: []u8, loc := #caller_location) {
		made := arp(t, s, events, len(want) * STEP + STEP / 2)
		_, keys := ons(made[:])
		testing.expectf(t, fmt.tprint(keys[:len(want)] if len(keys) >= len(want) else keys[:]) == fmt.tprint(want), "%v: %v (want %v)", s.mode, keys, want, loc = loc)
	}
	long := chord(100 * STEP)
	check(t, {mode = .Down}, long, {67, 64, 60, 67, 64, 60})
	check(t, {mode = .Up, octaves = 2}, long, {60, 64, 67, 72, 76, 79, 60})
	check(t, {mode = .Up_Down}, long, {60, 64, 67, 64, 60, 64, 67})
	played := []kit.Timed_Event{on(0, 67), on(10, 60), on(20, 64), off(100 * STEP, 67), off(100 * STEP, 60), off(100 * STEP, 64)}
	check(t, {mode = .As_Played}, played, {67, 60, 64, 67})
	// Random: only held keys, the same every time with one seed.
	a := arp(t, {mode = .Random, seed = 3}, long, 32 * STEP)
	b := arp(t, {mode = .Random, seed = 3}, long, 32 * STEP)
	_, ka := ons(a[:])
	_, kb := ons(b[:])
	testing.expect(t, fmt.tprint(ka) == fmt.tprint(kb), "repeatable")
	for k in ka do testing.expect(t, k == 60 || k == 64 || k == 67, "a held key")
}

@(test)
arp_latch_keeps_playing_and_a_new_chord_replaces_it :: proc(t: ^testing.T) {
	events := []kit.Timed_Event{
		on(0, 60), on(0, 64), off(STEP, 60), off(STEP, 64), // let go after one step
		on(6 * STEP + 100, 70), off(7 * STEP, 70),           // a new "chord": 70 alone
	}
	made := arp(t, {mode = .Up, latch = true}, events, 10 * STEP)
	_, keys := ons(made[:])
	testing.expectf(t, len(keys) >= 9, "keeps playing after release (%v)", keys)
	if len(keys) >= 9 {
		testing.expect(t, keys[0] == 60 && keys[1] == 64 && keys[4] == 60 && keys[5] == 64, "the latched notes")
		testing.expectf(t, keys[7] == 70 && keys[8] == 70, "replaced by the new key (%v)", keys)
	}
	// Latched, it still plays when the render ends: one note at a time.
	depth := 0
	for m in made do depth += 1 if m.on else -1
	testing.expect(t, depth == 0 || depth == 1, "one note at a time")
}

@(test)
arp_and_repeat_are_block_size_invariant_and_allocation_free :: proc(t: ^testing.T) {
	ev := chord(9 * STEP + 77)
	ref := arp(t, {mode = .Up_Down, octaves = 2, gate = 0.3}, ev, 12 * STEP)
	for b in ([]kit.Block_Pattern{kit.Fixed_Blocks{1}, kit.Fixed_Blocks{37}, kit.Random_Blocks{seed = 5, min = 0, max = 512}}) {
		got := arp(t, {mode = .Up_Down, octaves = 2, gate = 0.3}, ev, 12 * STEP, b)
		testing.expectf(t, fmt.tprint(got) == fmt.tprint(ref), "arp, blocks %v", b)
	}
	rep :: proc(t: ^testing.T, ev: []kit.Timed_Event, b: kit.Block_Pattern) -> [dynamic]Made {
		node, _ := perform.repeat_node_create({rate = .Eighth})
		defer core.node_destroy(&node)
		return run(t, &node, ev, 12 * STEP, b)
	}
	rref := rep(t, ev, nil)
	for b in ([]kit.Block_Pattern{kit.Fixed_Blocks{1}, kit.Random_Blocks{seed = 9, min = 0, max = 300}}) {
		got := rep(t, ev, b)
		testing.expectf(t, fmt.tprint(got) == fmt.tprint(rref), "repeat, blocks %v", b)
	}
}

@(test)
repeat_plays_at_once_then_every_step :: proc(t: ^testing.T) {
	node, _ := perform.repeat_node_create({rate = .Sixteenth})
	defer core.node_destroy(&node)
	made := run(t, &node, {on(1000, 36, 0.9), off(4 * STEP + 500, 36)}, 6 * STEP)
	frames, keys := ons(made[:])
	want := []i64{1000, STEP, 2 * STEP, 3 * STEP, 4 * STEP}
	testing.expectf(t, fmt.tprint(frames) == fmt.tprint(want), "repeats at %v (want %v)", frames, want)
	for k in keys do testing.expect_value(t, k, 36)
	balanced(t, made[:])
	// The first note ends before the first repeat.
	testing.expectf(t, len(made) > 1 && !made[1].on && made[1].frame <= STEP, "%v", made[:2])
}

@(test)
without_a_transport_events_pass_through :: proc(t: ^testing.T) {
	a: perform.Arp
	perform.arp_init(&a, {})
	buf: [8]core.Event
	w := core.Event_Writer{buffer = buf[:]}
	ev := []core.Event{{0, core.Note_On{key = 60, velocity = 1}}, {10, core.Midi_Raw{bytes = {0xB0, 1, 2}}}}
	perform.arp_process(&a, nil, 64, ev, &w)
	testing.expect_value(t, len(core.event_writer_events(&w)), 2)
	// Controllers pass through with a transport too.
	node, _ := perform.arp_node_create({})
	defer core.node_destroy(&node)
	cfg := kit.default_render_config()
	cfg.out_channels = 0
	cfg.tail_frames = 1000
	cfg.events = {{time = 5, payload = core.Midi_Raw{bytes = {0xB0, 1, 2}}}}
	_, r := kit.render(&node, kit.buffer_make(0, 0, 48_000, context.temp_allocator), cfg, context.temp_allocator)
	testing.expect_value(t, len(r.events_out), 1)
}
