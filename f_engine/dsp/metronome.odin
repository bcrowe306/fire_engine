package dsp

import "core:math"
import "core:mem"

import "fire:core"
import tb "fire:timebase"

// Parameter id of the `Metronome`'s level, in dB (-60..6, default -6).
METRONOME_PARAM_LEVEL_DB :: core.Param_Id(1)
// Parameter id of the `Metronome`'s switch: 1 clicks, 0 is silent (default 1).
METRONOME_PARAM_ON :: core.Param_Id(2)
// Parameter id of the `Metronome`'s count-in switch: 1 clicks the beats
// before the timeline's beat 0 (a count-in) even while it is off (default 0).
METRONOME_PARAM_COUNT_IN :: core.Param_Id(3)

// Parameter id of the `Metronome`'s sound: a `Click_Sound` (default Beep).
METRONOME_PARAM_SOUND :: core.Param_Id(4)
// Parameter id of the `Metronome`'s accent: 1 sounds the bar's first beat
// higher (default), 0 every beat alike.
METRONOME_PARAM_ACCENT :: core.Param_Id(5)

// What a metronome clicks with.
Click_Sound :: enum u8 {
	Beep,    // a sine (1 kHz; the accent a fifth up)
	Wood,    // a woodblock: two inharmonic partials, short
	Stick,   // a rim click: a noise burst over a high ping, very short
	Cowbell, // two detuned partials (587 and 845 Hz), ringing longer
}

// Parameter table of the `Metronome` node. Read-only.
metronome_params := [?]core.Param_Info {
	{id = METRONOME_PARAM_LEVEL_DB, name = "Level", unit = .Decibels, min = -60, max = 6, default = -6, flags = {.Automatable}},
	{id = METRONOME_PARAM_ON, name = "On", min = 0, max = 1, default = 1},
	{id = METRONOME_PARAM_COUNT_IN, name = "Count-in", min = 0, max = 1, default = 0},
	{id = METRONOME_PARAM_SOUND, name = "Sound", min = 0, max = f64(max(Click_Sound)), default = 0, flags = {.Stepped}},
	{id = METRONOME_PARAM_ACCENT, name = "Accent", min = 0, max = 1, default = 1, flags = {.Stepped}},
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
// land on their exact frame at any block size. With its count-in switch on,
// the beats before beat 0 click even while it is off.
Metronome :: struct {
	settings: Metronome_Settings,
	rate:     f64,
	phase:    f64, // radians
	step:     f64, // radians per frame of the click sounding
	env:      f64, // current amplitude
	fall:     f64, // per-frame decay factor
	level:    f64, // linear
	on:       bool,
	count_in: bool, // click before beat 0 even while off
	sound:    Click_Sound,
	accent:   bool,
	phase2:   f64, // a second partial's (Wood, Cowbell)
	step2:    f64,
	noise:    u32, // Stick's noise
	hp:       f32, // its high-pass state
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
	m.on, m.accent, m.noise = true, true, 0x9e3779b9
	return core.node_make(&metronome_vtable, m, allocator)
}

// [rt]
@(private)
metronome_process :: proc(self: rawptr, ctx: ^core.Process_Context) {
	m := (^Metronome)(self)
	for e in ctx.events_in {
		if v, _, ok := core.param_event(e.payload, METRONOME_PARAM_LEVEL_DB); ok do m.level = db_to_gain(clamp(v, -60, 6))
		if v, _, ok := core.param_event(e.payload, METRONOME_PARAM_ON); ok do m.on = v >= 0.5
		if v, _, ok := core.param_event(e.payload, METRONOME_PARAM_SOUND); ok do m.sound = Click_Sound(clamp(int(v + 0.5), 0, int(max(Click_Sound))))
		if v, _, ok := core.param_event(e.payload, METRONOME_PARAM_ACCENT); ok do m.accent = v >= 0.5
		if v, _, ok := core.param_event(e.payload, METRONOME_PARAM_COUNT_IN); ok do m.count_in = v >= 0.5
	}
	// Where this call's clicks start.
	starts: [16]int
	accent: [16]bool
	clicks := 0
	t := ctx.transport
	if tl := core.transport_timeline(t, m.settings.timeline); tl != nil && tl.playing && (m.on || m.count_in) {
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
			if !m.on && beat >= 0 do break // only the count-in's clicks
			starts[clicks] = offset
			accent[clicks] = math.mod(math.floor(beat + 1e-6), per_bar) < 0.5
			clicks += 1
		}
	}
	out := ctx.outputs
	next := 0
	for i in 0 ..< ctx.frames {
		if next < clicks && starts[next] == i {
			up := 1.5 if accent[next] && m.accent else 1.0
			// Each sound: its partials' pitches and how fast it dies away.
			hz, hz2, decay_ms := m.settings.hz, 0.0, m.settings.decay_ms
			switch m.sound {
			case .Beep:
			case .Wood:    hz, hz2, decay_ms = 1600, 1600 * 2.76, 14
			case .Stick:   hz, decay_ms = 2400, 7
			case .Cowbell: hz, hz2, decay_ms = 587, 845, 70
			}
			m.step = math.TAU * hz * up / m.rate
			m.step2 = math.TAU * hz2 * up / m.rate
			m.fall = math.exp(-1 / (decay_ms * 0.001 * m.rate / 5))
			m.phase, m.phase2, m.env = 0, 0, 1
			next += 1
		}
		v: f32 = 0
		if m.env > 1e-4 {
			m.phase += m.step // the click's first frame already sounds
			m.phase2 += m.step2
			x: f64
			switch m.sound {
			case .Beep:    x = math.sin(m.phase)
			case .Wood:    x = math.sin(m.phase) * 0.8 + math.sin(m.phase2) * 0.35 * m.env
			case .Stick:
				m.noise ~= m.noise << 13
				m.noise ~= m.noise >> 17
				m.noise ~= m.noise << 5
				n := f32(m.noise >> 8) / 8_388_608 - 1
				m.hp += (n - m.hp) * 0.35 // (what passes the high-pass: the noise less its lows)
				x = f64(n - m.hp) * 0.9 + math.sin(m.phase) * 0.5
			case .Cowbell:
				// Two partials, squared off a little (as the old drum machines'), summed.
				a, b := math.sin(m.phase), math.sin(m.phase2)
				x = (math.tanh(a * 2.5) + math.tanh(b * 2.5)) * 0.4
			}
			v = f32(x * m.env * m.level)
			m.env *= m.fall
		}
		for ch in out do ch[i] = v
	}
}
