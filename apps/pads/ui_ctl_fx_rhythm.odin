// Rhythm and pitch: Cutter, Stutter, Pitch shift on a controller's display
// (docs/design/push2-devices.md, docs/design/push2-fx-rhythm.md): each its
// picture (ui_fxpic_rhythm.odin) over one bank of knobs, in an effect slot
// or as a Perform effect (Intensity first, on column 0).
//
//	Cutter: Gate (Rate, Duty, Depth); Rate a dropdown of tempo divisions.
//	Stutter: Repeat (Length, a dropdown of divisions); in a slot, the lower
//	row's first button repeats while it's held.
//	Pitch shift: Shift (Pitch in semitones, Window, Mix).
//
// On is Mute + Device, Remove is Delete + Device. In Perform the pictures
// show the effect as it plays at its intensity (where its pad is pressed,
// while held), its own setting faint beside it.
package pads

import "core:fmt"
import "core:math"
import "core:time"

import "app:ui"
import pa "api"
import pm "model"
import im "deps:imgui"
import fc "fire:core"
import "fire:dsp"
import "fire:transport"

// Draws `p` (one of this family's devices): whether it did.
@(private)
fx_panel_rhythm :: proc(p: ^Fx_Panel) -> bool {
	if p.where_ != .Slot || p.twin do return false
	#partial switch p.kind {
	case .Cutter:  rhy_cutter(p)
	case .Stutter: rhy_stutter(p)
	case .Pitch:   rhy_pitch(p)
	case:          return false
	}
	return true
}

// What the panel's pictures are given beside the settings: whether it
// plays, and in Perform its intensity and the slot as it plays at it.
@(private = "file")
Rhy_Now :: struct {
	perform:   bool,
	on:        bool, // a slot on; Perform: held
	intensity: f32,
	eff:       pm.Effect_Slot, // Perform: the slot at its intensity (else the slot)
}

@(private = "file")
rhy_now :: proc(p: ^Fx_Panel) -> (n: Rhy_Now) {
	m := &p.ctx.a.m
	n.on, n.eff = p.s.on, p.s
	if p.t.kind == .Perf {
		k := p.t.index
		n.perform = true
		live := m.engine.perf_live[k]
		n.intensity = clamp(live if live >= 0 else m.project.perf_intensity[k], 0, 1)
		n.eff, _ = pm.perf_effective(&m.project, k, live)
	}
	return
}

// Parameter `id` as it plays now (automation playing: where it has it).
@(private = "file")
rhy_value :: proc(p: ^Fx_Panel, id: fc.Param_Id) -> f32 {
	if v, ok := pm.automated_value(&p.ctx.a.m, fx_auto_target(p.t, id)); ok do return v
	return fx_value(p, id)
}

// The tempo grid now: the bar the transport is in and where in it (stopped:
// the clock's own bar, which the cutter then follows). Playing, the cutter
// counts from the sequencer's timeline (the clock's leader: its beat 0 is
// bar 1), counting in too.
@(private = "file")
rhy_grid :: proc(a: ^App) -> Rhy_Grid {
	m := &a.m
	st := transport.status(a.host.clock)
	bar := max(pm.bar_beats(&m.project), 0.25)
	g := Rhy_Grid{bar = bar, grid = f64(st.grid), bpm = st.tempo_bpm if st.tempo_bpm > 0 else 120}
	// (One reading of the timeline: the bar and the count from the same block.)
	pos, playing := pm.timeline_beat(&m.engine)
	g.count = pos if playing else g.grid
	beat := pm.position_at(&m.engine, pos) if playing else 0
	if playing && beat >= 0 {
		g.playing = true
		g.now = math.mod(beat, bar)
		g.bar_no = int(beat / bar) + 1
		if pos < 0 do g.now = pos - math.floor(pos / bar) * bar // (counting in: its bars)
	} else {
		g.now = g.count - math.floor(g.count / bar) * bar
	}
	return g
}

// The colour of the family's pictures (as Perform's pads have them).
@(private = "file")
rhy_color :: proc(p: ^Fx_Panel) -> ui.Color {
	return fx_kind_color(p.kind)
}

// Parameter `id` on `bank`'s column `col`: as `fx_knob`'s (undo,
// automation), reading as `shown` says and in whole `step`s if given.
@(private = "file")
rhy_knob :: proc(p: ^Fx_Panel, bank, col: int, id: fc.Param_Id, label: string, shown: proc(v: f32) -> cstring, step: f32 = 0) {
	info, ok := fx_param_info(p, id)
	if !ok do return
	tag := fmt.ctprintf("%s##rhy%d", label, int(id))
	if !ctl_knob(p.ctx, fx_index(p, bank, col), p.banks * 8, tag, p.plot) do return
	a := p.ctx.a
	v := fx_value(p, id)
	knob_target(a, fx_auto_target(p.t, id))
	e := ui.knob(tag, &v, f32(info.min), f32(info.max), f32(info.default), "%.2f", shown_value = shown(v), step = step)
	knob_target(a, {})
	control_effect_param(a, p.t, i64(id), clamp(f64(v), info.min, info.max), e.changed, e.ended)
}

// A length in beats (`id`) on `bank`'s column `col` as a dropdown of tempo
// divisions: longer to the right (`longer`), else faster to the right.
@(private = "file")
rhy_division_knob :: proc(p: ^Fx_Panel, bank, col: int, id: fc.Param_Id, label: string, longer: bool) {
	n := len(RHY_DIVISIONS)
	names := make([]string, n, context.temp_allocator)
	for k in 0 ..< n do names[k] = RHY_DIVISION_NAMES[n - 1 - k if longer else k]
	cur := rhy_division(fx_value(p, id))
	if longer do cur = n - 1 - cur
	if j := fx_choice(p, bank, col, label, names, cur); j >= 0 {
		k := n - 1 - j if longer else j
		control_effect_param(p.ctx.a, p.t, i64(id), f64(RHY_DIVISIONS[k]), true, true)
	}
}

@(private = "file")
rhy_percent :: proc(v: f32) -> cstring { return fmt.ctprintf("%.0f %%", v * 100) }

// Where the picture goes: the cursor at its top left.
@(private = "file")
rhy_plot_pos :: proc() {
	im.SetCursorPos({0, CTL_PLOT_Y})
}

// --- Cutter ------------------------------------------------------------------------------------

@(private = "file")
rhy_cutter :: proc(p: ^Fx_Panel) {
	n := rhy_now(p)
	fx_banks(p, "Gate")
	pic := Rhy_Cutter_Picture {
		beats = rhy_value(p, dsp.CUTTER_PARAM_BEATS), duty = rhy_value(p, dsp.CUTTER_PARAM_DUTY), depth = rhy_value(p, dsp.CUTTER_PARAM_DEPTH),
		on = n.on, perform = n.perform, intensity = n.intensity, grid = rhy_grid(p.ctx.a), color = rhy_color(p),
	}
	if n.perform {
		pic.own_beats = pic.beats
		pic.beats = pm.slot_value(n.eff, dsp.CUTTER_PARAM_BEATS, pic.beats)
	}
	rhy_plot_pos()
	rhy_cutter_picture(pic, p.plot)
	p.ctx.a.ctl.cutter_bar = {pic.grid.count - pic.grid.now, pic.grid.count, pic.grid.grid}
	rhy_division_knob(p, 0, 0, dsp.CUTTER_PARAM_BEATS, "Rate", longer = false)
	rhy_knob(p, 0, 1, dsp.CUTTER_PARAM_DUTY, "Duty", rhy_percent)
	rhy_knob(p, 0, 2, dsp.CUTTER_PARAM_DEPTH, "Depth", rhy_percent)
}

// --- Stutter -----------------------------------------------------------------------------------

// When the stutter shown started repeating (grid beats), to draw its
// copies from there.
@(private = "file")
rhy_repeat: struct {
	t:     pm.Fx_Target,
	on:    bool,
	since: f64,
}

@(private = "file")
rhy_stutter :: proc(p: ^Fx_Panel) {
	a := p.ctx.a
	n := rhy_now(p)
	fx_banks(p, "Repeat")
	g := rhy_grid(a)
	R := &rhy_repeat
	if R.t != p.t do R^ = {t = p.t}
	if n.on && !R.on do R.since = g.grid
	R.on = n.on
	pic := Rhy_Stutter_Picture {
		beats = rhy_value(p, dsp.STUTTER_PARAM_BEATS), active = n.on, since = R.since,
		perform = n.perform, intensity = n.intensity, grid = g, color = rhy_color(p),
	}
	if n.perform {
		pic.own_beats = pic.beats
		pic.beats = pm.slot_value(n.eff, dsp.STUTTER_PARAM_BEATS, pic.beats)
	}
	rhy_plot_pos()
	rhy_stutter_picture(pic, p.plot)
	rhy_division_knob(p, 0, 0, dsp.STUTTER_PARAM_BEATS, "Length", longer = true)
	// A slot's: repeats while held (its On, as Mute + Device sets it).
	if !n.perform {
		pressed, released := ctl_button(p.ctx, 0, "Repeat (hold)", p.s.on, p.full)
		if pressed && !p.s.on do pa.effect_set_on(&a.api, slot_ref(p.t), true)
		if released && p.s.on do pa.effect_set_on(&a.api, slot_ref(p.t), false)
	}
}

// --- Pitch shift -------------------------------------------------------------------------------

// The read heads' phase as drawn (slowed to be seen: they cross over tens
// of times a second), and when.
@(private = "file")
rhy_heads: struct {
	phase: f32,
	last:  time.Tick,
}

@(private = "file")
rhy_pitch :: proc(p: ^Fx_Panel) {
	n := rhy_now(p)
	fx_banks(p, "Shift")
	pic := Rhy_Pitch_Picture {
		semitones = rhy_value(p, dsp.PITCH_PARAM_SEMITONES), window_ms = rhy_value(p, dsp.PITCH_PARAM_WINDOW_MS), mix = rhy_value(p, dsp.PITCH_PARAM_MIX),
		on = n.on, perform = n.perform, intensity = n.intensity, color = rhy_color(p),
	}
	if n.perform {
		pic.own = pic.semitones
		pic.semitones = pm.slot_value(n.eff, dsp.PITCH_PARAM_SEMITONES, pic.semitones)
	}
	// The heads move through their window at (1 - ratio) / window a second
	// (backwards, shifting up); drawn a twentieth as fast, at most 1.5 a second.
	H := &rhy_heads
	dt: f32 = 0
	if H.last != {} do dt = f32(time.duration_seconds(time.tick_since(H.last)))
	H.last = time.tick_now()
	ratio := math.pow(2, pic.semitones / 12)
	rate := clamp((1 - ratio) / max(pic.window_ms * 0.001, 0.02) * 0.05, -1.5, 1.5)
	if !pic.on do rate = 0
	H.phase += rate * min(dt, 0.1)
	H.phase -= math.floor(H.phase)
	pic.phase = H.phase
	rhy_plot_pos()
	rhy_pitch_picture(pic, p.plot)
	rhy_knob(p, 0, 0, dsp.PITCH_PARAM_SEMITONES, "Pitch", proc(v: f32) -> cstring { return fmt.ctprintf("%+.0f st", v) }, step = 1)
	rhy_knob(p, 0, 1, dsp.PITCH_PARAM_WINDOW_MS, "Window", proc(v: f32) -> cstring { return fmt.ctprintf("%.0f ms", v) })
	rhy_knob(p, 0, 2, dsp.PITCH_PARAM_MIX, "Mix", rhy_percent)
}
