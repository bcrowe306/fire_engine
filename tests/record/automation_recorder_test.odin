package test_record

import "core:testing"

import "fire:clip"
import "fire:core"
import "fire:record"
import tb "fire:timebase"
import kit "fire:testkit"
import "fire:transport"

P :: core.Param_Id(3)

Auto_Rig :: struct {
	clock: ^transport.Clock,
	tl:    core.Timeline_Id,
	node:  core.Node,
	rec:   ^record.Automation_Recorder,
	frame: i64,
	sent:  [dynamic]At, // Param_Values the node passed on
	trap:  kit.Trap_Allocator,
}

auto_rig_make :: proc(mode := record.Write_Mode.Touch) -> ^Auto_Rig {
	r := new(Auto_Rig)
	r.clock, _ = transport.create(transport.default_settings(SR))
	r.tl, _ = transport.add_timeline(r.clock)
	r.node, r.rec, _ = record.automation_recorder_create({timeline = r.tl, mode = mode})
	core.node_prepare(&r.node, {sample_rate = SR, max_block = 32_768})
	return r
}

auto_rig_destroy :: proc(r: ^Auto_Rig) {
	core.node_destroy(&r.node)
	transport.destroy(r.clock)
	delete(r.sent)
	free(r)
}

auto_rig_run :: proc(r: ^Auto_Rig, total: int) {
	buf: [64]core.Event
	for done := 0; done < total; {
		n := min(512, total - done)
		w := core.Event_Writer{buffer = buf[:]}
		ctx := core.Process_Context{frames = n, events_out = &w}
		{
			context.allocator = kit.trap_allocator(&r.trap)
			context.temp_allocator = context.allocator
			transport.process(r.clock, &ctx, proc(user: rawptr, seg: ^core.Process_Context) {
				core.node_process(&(^Auto_Rig)(user).node, seg)
			}, r)
		}
		for e in core.event_writer_events(&w) do append(&r.sent, At{r.frame + i64(e.offset), e.payload})
		r.frame += i64(n)
		done += n
	}
}

auto_takes :: proc(r: ^Auto_Rig) -> [dynamic]record.Automation_Take {
	takes := make([dynamic]record.Automation_Take, context.temp_allocator)
	for take in record.automation_recorder_poll(r.rec) do append(&takes, take)
	return takes
}

auto_takes_free :: proc(takes: []record.Automation_Take) {
	for t in takes do delete(t.points)
}

expect_points :: proc(t: ^testing.T, got: []clip.Automation_Point, want: []clip.Automation_Point, loc := #caller_location) {
	if !testing.expect_value(t, len(got), len(want), loc = loc) do return
	for p, i in got {
		testing.expectf(t, near(p.at, want[i].at) && p.value == want[i].value, "point %d: %v, want %v", i, p, want[i], loc = loc)
	}
}

@(test)
touch_writes_while_held :: proc(t: ^testing.T) {
	r := auto_rig_make()
	defer auto_rig_destroy(r)
	record.automation_recorder_arm(r.rec, true)
	transport.play(r.clock, r.tl)
	auto_rig_run(r, BEAT)
	record.automation_recorder_touch(r.rec, P, 0.2)
	auto_rig_run(r, BEAT / 2)
	record.automation_recorder_set(r.rec, P, 0.6)
	auto_rig_run(r, BEAT / 2)
	record.automation_recorder_release(r.rec, P)
	auto_rig_run(r, BEAT / 2)
	record.automation_recorder_set(r.rec, P, 0.9) // after release: passed on, not written
	auto_rig_run(r, BEAT)
	takes := auto_takes(r)
	defer auto_takes_free(takes[:])
	if !testing.expect_value(t, len(takes), 1) do return
	tk := takes[0]
	testing.expect_value(t, tk.param, P)
	testing.expect(t, near(tk.start, 1) && near(tk.end, 2))
	glide := tb.Beats(0.01 * 2) // 10 ms at 2 beats per second
	expect_points(t, tk.points, {{at = 1, value = 0.2}, {at = 1.5, value = 0.2}, {at = 1.5 + glide, value = 0.6}, {at = 2, value = 0.6}})
	if testing.expect_value(t, len(r.sent), 3) {
		testing.expect_value(t, r.sent[0].frame, i64(BEAT))
		testing.expect_value(t, r.sent[2].payload.(core.Param_Value).value, 0.9)
	}
	testing.expect_value(t, r.trap.violations, 0)
}

@(test)
latch_writes_until_the_take_ends :: proc(t: ^testing.T) {
	r := auto_rig_make(.Latch)
	defer auto_rig_destroy(r)
	record.automation_recorder_arm(r.rec, true)
	transport.play(r.clock, r.tl)
	transport.stop(r.clock, r.tl, transport.At_Beat(3))
	auto_rig_run(r, BEAT)
	record.automation_recorder_touch(r.rec, P, 0.4)
	auto_rig_run(r, BEAT / 2)
	record.automation_recorder_release(r.rec, P)
	auto_rig_run(r, 3 * BEAT)
	transport.play(r.clock, r.tl) // playing again: the latch ended with the take
	auto_rig_run(r, BEAT)
	transport.stop(r.clock, r.tl)
	auto_rig_run(r, 512)
	takes := auto_takes(r)
	defer auto_takes_free(takes[:])
	if !testing.expect_value(t, len(takes), 1) do return
	testing.expect(t, near(takes[0].start, 1) && near(takes[0].end, 3))
	expect_points(t, takes[0].points, {{at = 1, value = 0.4}, {at = 3, value = 0.4}})
}

@(test)
disarmed_moves_are_passed_on_only :: proc(t: ^testing.T) {
	r := auto_rig_make()
	defer auto_rig_destroy(r)
	transport.play(r.clock, r.tl)
	record.automation_recorder_touch(r.rec, P, 0.5)
	auto_rig_run(r, BEAT)
	record.automation_recorder_release(r.rec, P)
	auto_rig_run(r, BEAT)
	takes := auto_takes(r)
	testing.expect_value(t, len(takes), 0)
	testing.expect_value(t, len(r.sent), 1)
}

@(test)
held_control_writes_every_loop_pass :: proc(t: ^testing.T) {
	r := auto_rig_make()
	defer auto_rig_destroy(r)
	record.automation_recorder_arm(r.rec, true)
	transport.set_loop(r.clock, r.tl, 0, 2)
	transport.play(r.clock, r.tl)
	auto_rig_run(r, BEAT)
	record.automation_recorder_touch(r.rec, P, 0.3)
	auto_rig_run(r, 2 * BEAT) // past the wrap at beat 2
	record.automation_recorder_release(r.rec, P)
	auto_rig_run(r, BEAT)
	takes := auto_takes(r)
	defer auto_takes_free(takes[:])
	if !testing.expect_value(t, len(takes), 2) do return
	testing.expect_value(t, takes[0].pass, 0)
	testing.expect(t, near(takes[0].start, 1) && near(takes[0].end, 2))
	testing.expect_value(t, takes[1].pass, 1)
	testing.expect(t, near(takes[1].start, 0) && near(takes[1].end, 1))
	expect_points(t, takes[1].points, {{at = 0, value = 0.3}, {at = 1, value = 0.3}})
}

@(test)
merge_replaces_the_written_range :: proc(t: ^testing.T) {
	b: clip.Automation_Builder
	clip.automation_builder_init(&b, 8)
	clip.automation_add_point(&b, P, 0, 0)
	clip.automation_add_point(&b, P, 8, 1)
	clip.automation_add_point(&b, P + 1, 0, 7) // another lane, untouched
	base, _ := clip.automation_build(&b)
	clip.automation_builder_destroy(&b)
	defer clip.automation_clip_release(base)

	merged, err := clip.automation_merge(base, P, 2, 4, {{at = 2, value = 0.5}, {at = 4, value = 0.5}})
	if !testing.expect_value(t, err, core.Error.None) do return
	defer clip.automation_clip_release(merged)
	l := clip.automation_lane(merged, P)
	testing.expect(t, abs(clip.automation_value(l, 1) - 0.125) < 1e-12)
	testing.expect(t, abs(clip.automation_value(l, 3) - 0.5) < 1e-12)
	testing.expect(t, abs(clip.automation_value(l, 4) - 0.5) < 1e-12)     // the jump back is after the range
	testing.expect(t, abs(clip.automation_value(l, 4.5) - 0.5625) < 1e-12) // the old line again
	testing.expect(t, abs(clip.automation_value(l, 2 - 1e-9) - 0.25) < 1e-6)
	testing.expect_value(t, clip.automation_value(clip.automation_lane(merged, P + 1), 5), 7)

	fresh, _ := clip.automation_merge(nil, P, 1, 2, {{at = 1, value = 3}, {at = 2, value = 4}}, length = 4)
	defer clip.automation_clip_release(fresh)
	testing.expect(t, abs(clip.automation_value(clip.automation_lane(fresh, P), 1.5) - 3.5) < 1e-12)
}
