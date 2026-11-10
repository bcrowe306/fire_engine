package dsp

import "core:math"
import "core:mem"

import "fire:core"
import tb "fire:timebase"

// Parameter id of the `Metronome`'s level, in dB (-60..6, default -6).
METRONOME_PARAM_LEVEL_DB :: core.Param_Id(1)
// Parameter id of the `Metronome`'s switch: 1 clicks, 0 is silent (default 1).
METRONOME_PARAM_ON :: core.Param_Id(2)

// Parameter table of the `Metronome` node. Read-only.
metronome_params := [?]core.Param_Info {
	{id = METRONOME_PARAM_LEVEL_DB, name = "Level", unit = .Decibels, min = -60, max = 6, default = -6, flags = {.Automatable}},
	{id = METRONOME_PARAM_ON, name = "On", min = 0, max = 1, default = 1},
}

// Settings for `metronome_create`.
Metronome_Settings :: struct {
	timeline: core.Timeline_Id, // the timeline whose beats it clicks while it plays
	hz:       f64,              // the click's pitch; 0 = 1000 Hz (the bar's first beat: 1.5 times higher)
	decay_ms: f64,              // how long a click rings; 0 = 25 ms
}

// A click on every beat of a timeline while it plays, higher on the first
// beat of each bar (bars from the clock's meter, counted from the
// timeline's beat 0). Mono into every output channel; no inputs. Clicks
// land on their exact frame at any block size.
Metronome :: struct {
	settings: Metronome_Settings,
	rate:     f64,
	phase:    f64, // radians
	step:     f64, // radians per frame of the click sounding
	env:      f64, // current amplitude
	fall:     f64, // per-frame decay factor
	level:    f64, // linear
	on:       bool,
}

@(private)
metronome_vtable := core.Node_VTable {
	prepare = proc(self: rawptr, cfg: core.Prepare_Config, a: mem.Allocator) -> core.Error {
		m := (^Metronome)(self)
		m.rate = cfg.sample_rate
		m.fall = math.exp(-1 / (m.settings.decay_ms * 0.001 * cfg.sample_rate / 5)) // -43 dB by decay_ms
		m.env = 0
		return .None
	},
	process = metronome_process,
	reset   = proc(self: rawptr) { (^Metronome)(self).env = 0 },
	params  = proc(self: rawptr) -> []core.Param_Info { return metronome_params[:] },
	destroy = proc(self: rawptr, a: mem.Allocator) { free((^Metronome)(self), a) },
}

// Control thread. A metronome node (0 inputs; give it 1 or 2 outputs).
metronome_create :: proc(settings: Metronome_Settings, allocator := context.allocator) -> core.Node {
	m := new(Metronome, allocator)
	m.settings = settings
	if m.settings.hz <= 0 do m.settings.hz = 1000
	if m.settings.decay_ms <= 0 do m.settings.decay_ms = 25
	m.level = db_to_gain(metronome_params[0].default)
	m.on = true
	return core.node_make(&metronome_vtable, m, allocator)
}

// [rt]
@(private)
metronome_process :: proc(self: rawptr, ctx: ^core.Process_Context) {
	m := (^Metronome)(self)
	for e in ctx.events_in {
		if v, _, ok := core.param_event(e.payload, METRONOME_PARAM_LEVEL_DB); ok do m.level = db_to_gain(clamp(v, -60, 6))
		if v, _, ok := core.param_event(e.payload, METRONOME_PARAM_ON); ok do m.on = v >= 0.5
	}
	// Where this call's clicks start.
	starts: [16]int
	accent: [16]bool
	clicks := 0
	t := ctx.transport
	if tl := core.transport_timeline(t, m.settings.timeline); tl != nil && tl.playing && m.on {
		per_bar := 4.0
		if t.meter.denominator > 0 do per_bar = f64(t.meter.numerator) * 4 / f64(t.meter.denominator)
		first := core.timeline_next_multiple(t, tl, 1)
		if .Started in tl.flags || .Jumped in tl.flags { // a beat exactly where it starts clicks too
			first = tb.Beats(math.ceil(f64(tl.position) - 1e-9))
		}
		for b := first; clicks < len(starts); b += 1 {
			offset := core.timeline_offset_of(t, tl, b)
			if offset >= ctx.frames do break
			beat := f64(b)
			starts[clicks] = offset
			accent[clicks] = math.mod(math.floor(beat + 1e-6), per_bar) < 0.5
			clicks += 1
		}
	}
	out := ctx.outputs
	next := 0
	for i in 0 ..< ctx.frames {
		if next < clicks && starts[next] == i {
			hz := m.settings.hz * (1.5 if accent[next] else 1)
			m.step = math.TAU * hz / m.rate
			m.phase, m.env = 0, 1
			next += 1
		}
		v: f32 = 0
		if m.env > 1e-4 {
			m.phase += m.step // the click's first frame already sounds
			v = f32(math.sin(m.phase) * m.env * m.level)
			m.env *= m.fall
		}
		for ch in out do ch[i] = v
	}
}
