package test_pads_model

import "core:fmt"
import "core:testing"

import "fire:clip"

import pm "../../apps/pads/model"

// Switching "at once" between two sequences of a lane, over and over at
// all sorts of places, with and without Continue: each one launched plays
// on (eighths in both: a bar after the switch has its 8 hits, give or take
// the one under the switch). (A plan placed at an odd beat once made no
// clip at all: its loop ran a hair past its segments' end.)
@(test)
switching_at_once_keeps_playing :: proc(t: ^testing.T) {
	for cont in ([]bool{false, true}) {
		r := blips(t, fmt.tprintf("launch_now_%v", cont))
		defer rig_destroy(r)
		m := &r.m
		for b in 0 ..< 8 {
			pm.add_note(m, 0, {start = f64(b) * 0.5, length = 0.1, pad = 0, velocity = 1})
			pm.add_note(m, 8, {start = f64(b) * 0.5, length = 0.1, pad = 0, velocity = 1}) // sequence 9: lane 1 again
		}
		pm.set_launch_continue(m, cont)
		m.project.switch_at = .Now
		pm.launch_slot(m, 0)
		render_synced(r, 4800, 512)
		slot := 0
		for k in 0 ..< 24 {
			render_synced(r, 512 * (1 + (k * 7) % 23), 512) // somewhere else each time
			slot = 8 if slot == 0 else 0
			pm.launch_slot(m, slot)
			out := render_synced(r, 96_000, 512) // a bar at 120
			got := len(onsets(out[0][:], 0.02))
			testing.expectf(t, got >= 7, "continue %v, switch %d to %d: %d hits in the bar after it", cont, k, slot + 1, got)
		}
	}
}

// A plan's clip is made wherever the plan is placed: its loop never ends
// past it.
@(test)
a_plan_at_any_beat_makes_its_clip :: proc(t: ^testing.T) {
	r := blips(t, "plan_any_beat")
	defer rig_destroy(r)
	m := &r.m
	pm.add_note(m, 0, {start = 0, length = 0.1, pad = 0, velocity = 1})
	l: pm.Launcher
	for &c in l.cols do c.slot = -1
	for k in 0 ..< 400 {
		at := f64(k) * 0.0371
		l.cols[0] = {slot = 0, since = at, next = -1}
		pl := pm.plan_launch(&m.project, &l, at)
		c := pm.plan_clip(&m.project, pl)
		testing.expectf(t, c != nil, "a clip for a plan at beat %v (loop %v..%v)", at, pl.loop_start, pl.loop_end)
		if c == nil do break
		clip.midi_clip_release(c)
	}
}
