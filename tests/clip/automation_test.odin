package test_clip

import "core:math"
import "core:testing"

import "fire:clip"
import "fire:core"
import "fire:dsp"
import "fire:graph"
import tb "fire:timebase"
import kit "fire:testkit"
import "fire:transport"

P0 :: core.Param_Id(7)
P1 :: core.Param_Id(9)

Auto_Rig :: struct {
	clock:  ^transport.Clock,
	tl:     core.Timeline_Id,
	node:   core.Node,
	player: ^clip.Automation_Player,
	got:    [dynamic]Got,
	frame:  i64,
	buf:    []core.Event,
	trap:   kit.Trap_Allocator,
}

auto_rig_make :: proc(bpm := 120.0, settings := clip.Automation_Player_Settings{}) -> ^Auto_Rig {
	r := new(Auto_Rig)
	s := transport.default_settings(SR)
	s.bpm = bpm
	r.clock, _ = transport.create(s)
	r.tl, _ = transport.add_timeline(r.clock)
	st := settings
	st.timeline = r.tl
	r.node, r.player, _ = clip.automation_player_create(st)
	core.node_prepare(&r.node, {sample_rate = SR, max_block = 32_768})
	r.buf = make([]core.Event, 8192)
	return r
}

auto_rig_destroy :: proc(r: ^Auto_Rig) {
	core.node_destroy(&r.node)
	transport.destroy(r.clock)
	delete(r.got)
	delete(r.buf)
	free(r)
}

auto_rig_run :: proc(r: ^Auto_Rig, total: int, blocks: []int = {512}) {
	for done, k := 0, 0; done < total; k += 1 {
		n := min(blocks[k % len(blocks)], total - done)
		w := core.Event_Writer{buffer = r.buf}
		ctx := core.Process_Context{frames = n, events_out = &w}
		{
			context.allocator = kit.trap_allocator(&r.trap)
			context.temp_allocator = context.allocator
			transport.process(r.clock, &ctx, proc(user: rawptr, seg: ^core.Process_Context) {
				core.node_process(&(^Auto_Rig)(user).node, seg)
			}, r)
		}
		for e in core.event_writer_events(&w) do append(&r.got, Got{r.frame + i64(e.offset), e.payload})
		r.frame += i64(n)
		done += n
	}
}

// The parameter's value at every frame, as a node using `Smoothed_Value`
// (with no smoothing of its own, so Param_Value jumps) would have it.
values_of :: proc(got: []Got, param: core.Param_Id, frames: int, initial := 0.0) -> []f64 {
	out := make([]f64, frames, context.temp_allocator)
	s: dsp.Smoothed_Value
	dsp.smoothed_init(&s, initial, .None, 0, SR)
	k := 0
	for f in 0 ..< frames {
		for k < len(got) && got[k].frame <= i64(f) {
			if v, ramp, ok := core.param_event(got[k].payload, param); ok do dsp.smoothed_apply(&s, v, ramp)
			k += 1
		}
		out[f] = dsp.smoothed_next(&s)
	}
	return out
}

// The beat at frame `f` at a constant tempo.
beat_at :: proc(f: int, bpm := 120.0) -> f64 {
	return f64(f) * bpm / 60 / SR
}

expect_follows :: proc(t: ^testing.T, values: []f64, want: proc(beat: f64) -> f64, tolerance: f64, what: string, from := 0, bpm := 120.0, loc := #caller_location) {
	worst, at := 0.0, -1
	for v, f in values[from:] {
		e := abs(v - want(beat_at(f + from, bpm)))
		if e > worst do worst, at = e, f + from
	}
	testing.expectf(t, worst <= tolerance, "%s: off the curve by %.3g at frame %d (beat %.4f)", what, worst, at, beat_at(at, bpm), loc = loc)
}

// 0 → 1 over beats 0..4, back to 0.25 at 8, linear.
tent :: proc() -> ^clip.Automation_Clip {
	b: clip.Automation_Builder
	clip.automation_builder_init(&b, 8)
	defer clip.automation_builder_destroy(&b)
	clip.automation_add_point(&b, P0, 4, 1) // out of order on purpose
	clip.automation_add_point(&b, P0, 0, 0)
	clip.automation_add_point(&b, P0, 8, 0.25)
	c, err := clip.automation_build(&b)
	assert(err == .None)
	return c
}

tent_at :: proc(beat: f64) -> f64 {
	if beat <= 4 do return beat / 4
	if beat <= 8 do return 1 - 0.75 * (beat - 4) / 4
	return 0.25
}

// Linear segments are followed to the frame, at any block size, with one
// ramp per block, and nothing allocates.
@(test)
linear_automation_follows_the_curve :: proc(t: ^testing.T) {
	c := tent()
	defer clip.automation_clip_release(c)
	total := int(frame_of(9))
	runs: [2][]f64
	for blocks, k in ([][]int{{512}, {64, 333, 1000, 7}}) {
		r := auto_rig_make()
		defer auto_rig_destroy(r)
		clip.automation_player_set(r.player, c, {})
		transport.play(r.clock, r.tl)
		auto_rig_run(r, total, blocks)
		testing.expect_value(t, r.trap.violations, 0)
		runs[k] = values_of(r.got[:], P0, total)
		expect_follows(t, runs[k], tent_at, 1e-9, "tent")
		if k == 0 {
			ramps := 0
			for g in r.got do if _, ok := g.payload.(core.Param_Ramp); ok do ramps += 1
			testing.expectf(t, ramps <= total / 512 + 4, "%d ramps for %d blocks", ramps, total / 512)
		}
	}
	worst: f64
	for v, i in runs[0] do worst = max(worst, abs(v - runs[1][i]))
	testing.expectf(t, worst < 1e-12, "block sizes change the values by %.3g", worst)
}

// Steps jump on the first frame at or after their point, exactly.
@(test)
steps_land_on_their_frame :: proc(t: ^testing.T) {
	b: clip.Automation_Builder
	clip.automation_builder_init(&b, 4)
	defer clip.automation_builder_destroy(&b)
	clip.automation_add_point(&b, P0, 0, 0.1, .Step)
	clip.automation_add_point(&b, P0, 1.5, 0.9, .Step)
	clip.automation_add_point(&b, P0, 3, 0.4, .Step)
	c, _ := clip.automation_build(&b)
	defer clip.automation_clip_release(c)
	r := auto_rig_make()
	defer auto_rig_destroy(r)
	clip.automation_player_set(r.player, c, {})
	transport.play(r.clock, r.tl)
	auto_rig_run(r, int(frame_of(4)), {333})
	v := values_of(r.got[:], P0, int(frame_of(4)))
	f1, f3 := frame_of(1.5), frame_of(3)
	testing.expect_value(t, v[0], 0.1)
	testing.expect_value(t, v[f1 - 1], 0.1)
	testing.expect_value(t, v[f1], 0.9)
	testing.expect_value(t, v[f3 - 1], 0.9)
	testing.expect_value(t, v[f3], 0.4)
}

// A curved segment stays within a small error of its shape, and bends the
// way its tension says.
@(test)
curved_segments_follow_their_shape :: proc(t: ^testing.T) {
	b: clip.Automation_Builder
	clip.automation_builder_init(&b, 4)
	defer clip.automation_builder_destroy(&b)
	clip.automation_add_point(&b, P0, 0, 0, .Curve, 0.7)
	clip.automation_add_point(&b, P0, 4, 1)
	clip.automation_add_point(&b, P1, 0, 1, .Curve, -0.7)
	clip.automation_add_point(&b, P1, 4, 0)
	c, _ := clip.automation_build(&b)
	defer clip.automation_clip_release(c)
	r := auto_rig_make()
	defer auto_rig_destroy(r)
	clip.automation_player_set(r.player, c, {})
	transport.play(r.clock, r.tl)
	total := int(frame_of(4))
	auto_rig_run(r, total, {512})
	slow := values_of(r.got[:], P0, total)
	fast := values_of(r.got[:], P1, total, 1)
	expect_follows(t, slow, proc(beat: f64) -> f64 { return (math.exp(5.6 * beat / 4) - 1) / (math.exp(5.6) - 1) }, 1e-4, "tension 0.7")
	expect_follows(t, fast, proc(beat: f64) -> f64 { return 1 - (math.exp(-5.6 * beat / 4) - 1) / (math.exp(-5.6) - 1) }, 1e-4, "tension -0.7")
	mid := int(frame_of(2))
	testing.expectf(t, slow[mid] < 0.25, "positive tension starts slowly: %v at the middle", slow[mid])
	testing.expectf(t, fast[mid] < 0.25, "negative tension falls quickly: %v at the middle", fast[mid])
}

// A looping clip jumps back at each wrap, on the wrap's frame.
@(test)
looped_automation_wraps :: proc(t: ^testing.T) {
	b: clip.Automation_Builder
	clip.automation_builder_init(&b, 2)
	defer clip.automation_builder_destroy(&b)
	clip.automation_add_point(&b, P0, 0, 0)
	clip.automation_add_point(&b, P0, 2, 1)
	c, _ := clip.automation_build(&b)
	defer clip.automation_clip_release(c)
	r := auto_rig_make()
	defer auto_rig_destroy(r)
	clip.automation_player_set(r.player, c, {loop = true})
	transport.play(r.clock, r.tl)
	total := int(frame_of(7))
	auto_rig_run(r, total, {500})
	v := values_of(r.got[:], P0, total)
	expect_follows(t, v, proc(beat: f64) -> f64 { return math.mod(beat, 2) / 2 }, 1e-9, "sawtooth")
	for k in 1 ..= 3 {
		w := frame_of(f64(2 * k))
		testing.expectf(t, v[w] == 0 && v[w - 1] > 0.99, "wrap %d: %v then %v", k, v[w - 1], v[w])
	}
}

// Placed at beat 4 for 4 beats from clip beat 1: nothing before, the clip
// within, the last value held after.
@(test)
placed_automation_stays_in_its_region :: proc(t: ^testing.T) {
	c := tent()
	defer clip.automation_clip_release(c)
	r := auto_rig_make()
	defer auto_rig_destroy(r)
	clip.automation_player_set(r.player, c, {at = 4, length = 4, offset = 1})
	transport.play(r.clock, r.tl)
	total := int(frame_of(10))
	auto_rig_run(r, total, {512})
	testing.expect(t, len(r.got) > 0 && r.got[0].frame == frame_of(4))
	for g in r.got do testing.expectf(t, g.frame < frame_of(8), "an event at frame %d, after the region", g.frame)
	v := values_of(r.got[:], P0, total, -1)
	testing.expect_value(t, v[frame_of(4) - 1], -1) // untouched before
	expect_follows(t, v[:frame_of(8)], proc(beat: f64) -> f64 { return tent_at(beat - 3) if beat >= 4 else -1 }, 1e-9, "inside")
	testing.expectf(t, abs(v[total - 1] - tent_at(5)) < 1e-4, "held at %v, want about %v", v[total - 1], tent_at(5))
}

// After a tempo change the curve still lands on its beats.
@(test)
automation_follows_tempo_changes :: proc(t: ^testing.T) {
	c := tent()
	defer clip.automation_clip_release(c)
	r := auto_rig_make()
	defer auto_rig_destroy(r)
	m: tb.Tempo_Map
	tb.tempo_map_init(&m, 120)
	defer tb.tempo_map_destroy(&m)
	tb.tempo_map_set_tempo(&m, 2, 80)
	transport.set_tempo_map(r.clock, r.tl, &m)
	transport.set_leader(r.clock, r.tl)
	clip.automation_player_set(r.player, c, {})
	transport.play(r.clock, r.tl)
	total := int(tb.beats_to_samples(&m, 8, SR))
	auto_rig_run(r, total, {512})
	v := values_of(r.got[:], P0, total)
	worst: f64
	for f in 0 ..< total do worst = max(worst, abs(v[f] - tent_at(f64(tb.samples_to_beats(&m, tb.Sample_Time(f), SR)))))
	testing.expectf(t, worst < 1e-6, "off the curve by %.3g", worst)
}

// While stopped, a locate (or a new clip) sends the value at the new
// position, smoothed as a node's own change would be.
@(test)
stopped_locates_send_the_value :: proc(t: ^testing.T) {
	c := tent()
	defer clip.automation_clip_release(c)
	r := auto_rig_make()
	defer auto_rig_destroy(r)
	clip.automation_player_set(r.player, c, {})
	auto_rig_run(r, 1024)
	testing.expect_value(t, len(r.got), 1) // the value at beat 0, once
	transport.locate(r.clock, r.tl, 6)
	auto_rig_run(r, 1024)
	testing.expect_value(t, len(r.got), 2)
	if len(r.got) == 2 {
		pv, ok := r.got[1].payload.(core.Param_Value)
		testing.expectf(t, ok && abs(pv.value - tent_at(6)) < 1e-12, "sent %v", r.got[1].payload)
	}
}

// A suspended lane sends nothing (the other lanes carry on); resumed, it
// glides back to the curve and follows it again.
@(test)
suspended_lanes_hand_over_and_glide_back :: proc(t: ^testing.T) {
	b: clip.Automation_Builder
	clip.automation_builder_init(&b, 16)
	defer clip.automation_builder_destroy(&b)
	clip.automation_add_point(&b, P0, 0, 0)
	clip.automation_add_point(&b, P0, 16, 1)
	clip.automation_add_point(&b, P1, 0, 1)
	clip.automation_add_point(&b, P1, 16, 0)
	c, _ := clip.automation_build(&b)
	defer clip.automation_clip_release(c)
	r := auto_rig_make()
	defer auto_rig_destroy(r)
	clip.automation_player_set(r.player, c, {})
	transport.play(r.clock, r.tl)
	auto_rig_run(r, 10 * 512)
	clip.automation_player_suspend(r.player, P0)
	suspended_from := r.frame
	auto_rig_run(r, 40 * 512)
	resumed_at := r.frame
	clip.automation_player_resume(r.player, P0, 50)
	auto_rig_run(r, 40 * 512)
	for g in r.got {
		if _, _, ok := core.param_event(g.payload, P0); ok {
			testing.expectf(t, g.frame < suspended_from || g.frame >= resumed_at, "P0 sent at frame %d while suspended", g.frame)
		}
	}
	total := int(r.frame)
	other := values_of(r.got[:], P1, total, 1)
	expect_follows(t, other, proc(beat: f64) -> f64 { return 1 - beat / 16 }, 1e-9, "the other lane")
	// Say the user held P0 at 0.9 meanwhile: the glide starts there.
	got := make([dynamic]Got, context.temp_allocator)
	append(&got, Got{resumed_at, core.Param_Value{P0, 0.9}})
	for g in r.got do if g.frame >= resumed_at do append(&got, g)
	v := values_of(got[:], P0, total)
	glide := int(0.05 * SR)
	testing.expectf(t, abs(v[resumed_at] - 0.9) < 1e-9, "glide starts at %v", v[resumed_at])
	expect_follows(t, v, proc(beat: f64) -> f64 { return beat / 16 }, 1e-6, "after the glide", from = int(resumed_at) + glide)
}

// The builder sorts points per lane and rejects bad clips.
@(test)
automation_clips_build :: proc(t: ^testing.T) {
	b: clip.Automation_Builder
	clip.automation_builder_init(&b, 4)
	defer clip.automation_builder_destroy(&b)
	clip.automation_add_point(&b, P1, 2, 5)
	clip.automation_add_point(&b, P0, 1, 1)
	clip.automation_add_point(&b, P1, 0, 3)
	clip.automation_add_point(&b, P0, 1, 2) // a jump at beat 1
	c, err := clip.automation_build(&b)
	testing.expect_value(t, err, core.Error.None)
	defer clip.automation_clip_release(c)
	testing.expect_value(t, len(c.lanes), 2)
	l0, l1 := clip.automation_lane(c, P0), clip.automation_lane(c, P1)
	testing.expect(t, l0 != nil && l1 != nil && len(l0.points) == 2 && len(l1.points) == 2)
	testing.expect_value(t, clip.automation_value(l0, 1), 2) // after the jump
	testing.expect_value(t, clip.automation_value(l0, 0.5), 1) // before the first point: its value
	testing.expect_value(t, clip.automation_value(l1, 1), 4)
	testing.expect(t, clip.automation_lane(c, 99) == nil)

	clip.automation_set_loop(&b, 3, 3)
	_, err = clip.automation_build(&b)
	testing.expect_value(t, err, core.Error.Invalid_Argument)
	clip.automation_set_loop(&b, 0, 4)
	clip.automation_add_point(&b, P0, 2, math.nan_f64())
	_, err = clip.automation_build(&b)
	testing.expect_value(t, err, core.Error.Invalid_Argument)
}

// Through a graph: the player event-connected to a gain stage fades a DC
// input exactly along the curve (linear in dB), whatever the block size.
@(test)
automation_drives_a_gain_through_the_graph :: proc(t: ^testing.T) {
	b: clip.Automation_Builder
	clip.automation_builder_init(&b, 4)
	defer clip.automation_builder_destroy(&b)
	clip.automation_add_point(&b, dsp.GAIN_PARAM_DB, 1, 0)
	clip.automation_add_point(&b, dsp.GAIN_PARAM_DB, 3, -40)
	c, _ := clip.automation_build(&b)
	defer clip.automation_clip_release(c)

	Rig :: struct {
		g:   ^graph.Graph,
		out: [dynamic]f32,
	}
	total := int(frame_of(4))
	runs: [2][]f32
	for blocks, k in ([][]int{{256}, {100, 1024, 37}}) {
		cs := transport.default_settings(SR)
		cs.bpm = 120
		clock, _ := transport.create(cs)
		defer transport.destroy(clock)
		tl, _ := transport.add_timeline(clock)
		g, _ := graph.create(graph.default_settings(SR, 1024))
		defer graph.destroy(g)
		node, player, _ := clip.automation_player_create({timeline = tl})
		auto, _ := graph.add_node(g, node, 0, 0)
		gain, _ := graph.add_node(g, dsp.gain_create(), 1, 1)
		graph.connect(g, graph.INPUT, 0, gain, 0)
		graph.connect(g, gain, 0, graph.OUTPUT, 0)
		graph.connect_events(g, auto, gain)
		graph.commit(g)
		clip.automation_player_set(player, c, {})
		transport.play(clock, tl)
		r := Rig{g = g}
		defer delete(r.out)
		ones: [1024]f32
		for &v in ones do v = 1
		out: [1024]f32
		for done, i := 0, 0; done < total; i += 1 {
			n := min(blocks[i % len(blocks)], total - done)
			ctx := core.Process_Context{inputs = {ones[:n]}, outputs = {out[:n]}, frames = n}
			transport.process(clock, &ctx, proc(user: rawptr, seg: ^core.Process_Context) {
				graph.process((^Rig)(user).g, seg)
			}, &r)
			append(&r.out, ..out[:n])
			done += n
		}
		runs[k] = make([]f32, total, context.temp_allocator)
		copy(runs[k], r.out[:])
	}
	worst := 0.0
	for v, f in runs[0] {
		beat := beat_at(f)
		db := 0.0 if beat <= 1 else (-40 if beat >= 3 else -20 * (beat - 1))
		worst = max(worst, abs(f64(v) - math.pow(10, db / 20)))
	}
	testing.expectf(t, worst < 1e-5, "off the fade by %.3g", worst)
	testing.expect_value(t, runs[0][frame_of(1) - 1], 1)
	testing.expectf(t, abs(f64(runs[0][total - 1]) - 0.01) < 1e-6, "ends at %v", runs[0][total - 1])
	diff: f32
	for v, i in runs[0] do diff = max(diff, abs(v - runs[1][i]))
	testing.expectf(t, diff < 1e-6, "block sizes change the output by %.3g", diff)
}
