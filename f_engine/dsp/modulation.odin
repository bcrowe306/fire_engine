package dsp

import "core:math"
import "core:mem"

import "fire:core"

// Parameter ids shared by `Chorus`, `Flanger` and `Phaser`; each node's
// table lists the ones it has.

// Parameter id of the modulation's LFO rate, in Hz.
MOD_PARAM_RATE_HZ :: core.Param_Id(1)
// Parameter id of the modulation depth. Chorus and flanger: how far the
// delay swings, in ms. Phaser: how far the sweep goes, in percent of the
// range from `MOD_PARAM_MIN_HZ` to `MOD_PARAM_MAX_HZ`.
MOD_PARAM_DEPTH :: core.Param_Id(2)
// Parameter id of the chorus's and flanger's base delay, in ms: what the
// LFO swings around.
MOD_PARAM_DELAY_MS :: core.Param_Id(3)
// Parameter id of the flanger's and phaser's feedback, in percent
// (−95..95; negative inverts).
MOD_PARAM_FEEDBACK :: core.Param_Id(4)
// Parameter id of the modulation's mix with the dry signal, in percent.
MOD_PARAM_MIX :: core.Param_Id(5)
// Parameter id of the LFO phase difference between channels, in percent
// of a cycle (0..50; 25 is a quarter cycle, wide stereo).
MOD_PARAM_SPREAD :: core.Param_Id(6)
// Parameter id of the chorus's voices per channel (1..4), and the phaser's
// allpass stages (2..12, even).
MOD_PARAM_VOICES :: core.Param_Id(7)
// Parameter id of the phaser's lowest sweep frequency, in Hz.
MOD_PARAM_MIN_HZ :: core.Param_Id(8)
// Parameter id of the phaser's highest sweep frequency, in Hz.
MOD_PARAM_MAX_HZ :: core.Param_Id(9)

// Parameter table of the `Chorus` node. Read-only.
chorus_params := [?]core.Param_Info {
	{id = MOD_PARAM_RATE_HZ, name = "Rate", unit = .Hertz, min = 0.01, max = 10, default = 0.8, flags = {.Automatable}},
	{id = MOD_PARAM_DEPTH, name = "Depth", unit = .Milliseconds, min = 0, max = 10, default = 3, smoothing = .Linear, smoothing_ms = 50, flags = {.Automatable}},
	{id = MOD_PARAM_DELAY_MS, name = "Delay", unit = .Milliseconds, min = 1, max = 40, default = 12, smoothing = .Linear, smoothing_ms = 50, flags = {.Automatable}},
	{id = MOD_PARAM_MIX, name = "Mix", unit = .Percent, min = 0, max = 100, default = 50, smoothing = .Linear, smoothing_ms = 20, flags = {.Automatable}},
	{id = MOD_PARAM_SPREAD, name = "Spread", unit = .Percent, min = 0, max = 50, default = 25, flags = {.Automatable}},
	{id = MOD_PARAM_VOICES, name = "Voices", min = 1, max = 4, default = 2, flags = {.Automatable, .Stepped}},
}

// Parameter table of the `Flanger` node. Read-only.
flanger_params := [?]core.Param_Info {
	{id = MOD_PARAM_RATE_HZ, name = "Rate", unit = .Hertz, min = 0.01, max = 10, default = 0.25, flags = {.Automatable}},
	{id = MOD_PARAM_DEPTH, name = "Depth", unit = .Milliseconds, min = 0, max = 10, default = 2, smoothing = .Linear, smoothing_ms = 50, flags = {.Automatable}},
	{id = MOD_PARAM_DELAY_MS, name = "Delay", unit = .Milliseconds, min = 0.1, max = 10, default = 1, smoothing = .Linear, smoothing_ms = 50, flags = {.Automatable}},
	{id = MOD_PARAM_FEEDBACK, name = "Feedback", unit = .Percent, min = -95, max = 95, default = 50, smoothing = .Linear, smoothing_ms = 20, flags = {.Automatable}},
	{id = MOD_PARAM_MIX, name = "Mix", unit = .Percent, min = 0, max = 100, default = 50, smoothing = .Linear, smoothing_ms = 20, flags = {.Automatable}},
	{id = MOD_PARAM_SPREAD, name = "Spread", unit = .Percent, min = 0, max = 50, default = 25, flags = {.Automatable}},
}

// Parameter table of the `Phaser` node. Read-only.
phaser_params := [?]core.Param_Info {
	{id = MOD_PARAM_RATE_HZ, name = "Rate", unit = .Hertz, min = 0.01, max = 10, default = 0.5, flags = {.Automatable}},
	{id = MOD_PARAM_DEPTH, name = "Depth", unit = .Percent, min = 0, max = 100, default = 100, smoothing = .Linear, smoothing_ms = 50, flags = {.Automatable}},
	{id = MOD_PARAM_FEEDBACK, name = "Feedback", unit = .Percent, min = -95, max = 95, default = 0, smoothing = .Linear, smoothing_ms = 20, flags = {.Automatable}},
	{id = MOD_PARAM_MIX, name = "Mix", unit = .Percent, min = 0, max = 100, default = 50, smoothing = .Linear, smoothing_ms = 20, flags = {.Automatable}},
	{id = MOD_PARAM_SPREAD, name = "Spread", unit = .Percent, min = 0, max = 50, default = 25, flags = {.Automatable}},
	{id = MOD_PARAM_VOICES, name = "Stages", min = 2, max = 12, default = 4, flags = {.Automatable, .Stepped}},
	{id = MOD_PARAM_MIN_HZ, name = "Min", unit = .Hertz, min = 20, max = 5000, default = 200, flags = {.Automatable}},
	{id = MOD_PARAM_MAX_HZ, name = "Max", unit = .Hertz, min = 100, max = 20000, default = 3000, flags = {.Automatable}},
}

// Most voices per channel of a `Chorus`.
MOD_MAX_VOICES :: 4
// Most stages of a `Phaser`.
PHASER_MAX_STAGES :: 12
// Most channels the modulation nodes process (the rest are silent).
MOD_MAX_CHANNELS :: 8

@(private)
Mod_Kind :: enum u8 {Chorus, Flanger, Phaser}

// A chorus, flanger or phaser node (`chorus_create`, `flanger_create`,
// `phaser_create`). Each channel has its own LFO phase, `spread` apart.
// Fields are internal.
Modulation :: struct {
	kind:          Mod_Kind,
	rate_hz:       f64,
	spread:        f64, // cycles
	voices:        int, // chorus voices, or phaser stages
	min_hz, max_hz: f64,
	depth, delay:  Smoothed_Value, // ms (phaser: depth in percent)
	feedback, mix: Smoothed_Value, // percent
	phase:         f64, // the first channel's LFO, 0..1
	lines:         []Delay_Line, // chorus and flanger, per channel
	last:          [MOD_MAX_CHANNELS]f64, // flanger and phaser: feedback, the last output of the effect
	stages:        [MOD_MAX_CHANNELS][PHASER_MAX_STAGES]f64, // phaser allpass states
	channels:      int,
	sample_rate:   f64,
}

@(private)
modulation_vtable := core.Node_VTable {
	prepare = modulation_prepare,
	process = modulation_process,
	reset   = proc(self: rawptr) {
		m := (^Modulation)(self)
		for &l in m.lines do delay_line_clear(&l)
		m.last, m.stages, m.phase = {}, {}, 0
	},
	release = modulation_release,
	params  = proc(self: rawptr) -> []core.Param_Info {
		switch (^Modulation)(self).kind {
		case .Chorus:  return chorus_params[:]
		case .Flanger: return flanger_params[:]
		case .Phaser:  return phaser_params[:]
		}
		return nil
	},
	destroy = proc(self: rawptr, allocator: mem.Allocator) { free((^Modulation)(self), allocator) },
}

// Control thread. A chorus node: up to 4 voices per channel, each a copy
// delayed by `delay` ± `depth` ms on its own LFO phase, mixed with the dry
// signal. Free it with `core.node_destroy`.
chorus_create :: proc(allocator := context.allocator) -> core.Node {
	return modulation_make(.Chorus, chorus_params[:], allocator)
}

// Control thread. A flanger node: a short delay swept by an LFO, mixed with
// the dry signal into moving comb-filter notches; feedback sharpens them.
flanger_create :: proc(allocator := context.allocator) -> core.Node {
	return modulation_make(.Flanger, flanger_params[:], allocator)
}

// Control thread. A phaser node: a chain of first-order allpass filters
// (TPT, so sweeping is smooth) whose frequency an LFO sweeps on a log
// scale between `min` and `max`, mixed with the dry signal. Every two
// stages make one notch; at 50% mix the notches are complete.
phaser_create :: proc(allocator := context.allocator) -> core.Node {
	return modulation_make(.Phaser, phaser_params[:], allocator)
}

@(private)
modulation_make :: proc(kind: Mod_Kind, params: []core.Param_Info, allocator: mem.Allocator) -> core.Node {
	m := new(Modulation, allocator)
	m.kind = kind
	for p in params {
		switch p.id {
		case MOD_PARAM_RATE_HZ: m.rate_hz = p.default
		case MOD_PARAM_SPREAD:  m.spread = p.default * 0.01
		case MOD_PARAM_VOICES:  m.voices = int(p.default)
		case MOD_PARAM_MIN_HZ:  m.min_hz = p.default
		case MOD_PARAM_MAX_HZ:  m.max_hz = p.default
		}
	}
	return core.node_make(&modulation_vtable, m, allocator)
}

@(private)
modulation_prepare :: proc(self: rawptr, cfg: core.Prepare_Config, allocator: mem.Allocator) -> core.Error {
	m := (^Modulation)(self)
	m.sample_rate, m.channels = cfg.sample_rate, min(cfg.out_channels, MOD_MAX_CHANNELS)
	table := modulation_vtable.params(m)
	for p in table {
		switch p.id {
		case MOD_PARAM_DEPTH:    smoothed_init_from_param(&m.depth, p, cfg.sample_rate)
		case MOD_PARAM_DELAY_MS: smoothed_init_from_param(&m.delay, p, cfg.sample_rate)
		case MOD_PARAM_FEEDBACK: smoothed_init_from_param(&m.feedback, p, cfg.sample_rate)
		case MOD_PARAM_MIX:      smoothed_init_from_param(&m.mix, p, cfg.sample_rate)
		}
	}
	if m.kind == .Phaser do return .None
	err: mem.Allocator_Error
	m.lines, err = make([]Delay_Line, m.channels, allocator)
	if err != nil do return .Out_Of_Memory
	for &l in m.lines {
		if delay_line_init(&l, int(0.06 * cfg.sample_rate), allocator) != .None { // 40 + 10 ms and room
			modulation_release(m, allocator)
			return .Out_Of_Memory
		}
	}
	return .None
}

@(private)
modulation_release :: proc(self: rawptr, allocator: mem.Allocator) {
	m := (^Modulation)(self)
	for &l in m.lines do delay_line_destroy(&l, allocator)
	delete(m.lines, allocator)
	m.lines = nil
}

// [rt]
@(private)
modulation_process :: proc(self: rawptr, ctx: ^core.Process_Context) {
	m := (^Modulation)(self)
	pos := 0
	for e in ctx.events_in {
		modulation_render(m, ctx, pos, int(e.offset))
		pos = int(e.offset)
		id, value, frames, ok := any_param(e.payload)
		if !ok do continue
		switch id {
		case MOD_PARAM_RATE_HZ:  m.rate_hz = clamp(value, 0.01, 10)
		case MOD_PARAM_DEPTH:    smoothed_apply(&m.depth, clamp(value, 0, 100 if m.kind == .Phaser else 10), frames)
		case MOD_PARAM_DELAY_MS: smoothed_apply(&m.delay, clamp(value, 0.1, 40), frames)
		case MOD_PARAM_FEEDBACK: smoothed_apply(&m.feedback, clamp(value, -95, 95), frames)
		case MOD_PARAM_MIX:      smoothed_apply(&m.mix, clamp(value, 0, 100), frames)
		case MOD_PARAM_SPREAD:   m.spread = clamp(value, 0, 50) * 0.01
		case MOD_PARAM_VOICES:
			if m.kind == .Phaser {
				m.voices = clamp(int(value + 0.5) / 2 * 2, 2, PHASER_MAX_STAGES)
			} else {
				m.voices = clamp(int(value + 0.5), 1, MOD_MAX_VOICES)
			}
		case MOD_PARAM_MIN_HZ: m.min_hz = clamp(value, 20, 5000)
		case MOD_PARAM_MAX_HZ: m.max_hz = clamp(value, 100, 20000)
		}
	}
	modulation_render(m, ctx, pos, ctx.frames)
}

// [rt]
@(private)
modulation_render :: proc(m: ^Modulation, ctx: ^core.Process_Context, from, to: int) {
	outs := min(len(ctx.outputs), m.channels)
	ins := min(len(ctx.inputs), outs)
	step := m.rate_hz / m.sample_rate
	ms := m.sample_rate * 0.001
	for i in from ..< to {
		depth := smoothed_next(&m.depth)
		mix := smoothed_next(&m.mix) * 0.01
		delay := smoothed_next(&m.delay) if m.kind != .Phaser else 0
		fb := smoothed_next(&m.feedback) * 0.01 if m.kind != .Chorus else 0
		for c in 0 ..< outs {
			x := f64(ctx.inputs[c][i]) if c < ins else 0
			phase := m.phase + f64(c) * m.spread
			wet: f64
			switch m.kind {
			case .Chorus:
				// Voices evenly spaced in phase; their average is the wet signal.
				delay_line_write(&m.lines[c], f32(x))
				for v in 0 ..< m.voices {
					lfo := math.sin(math.TAU * (phase + f64(v) / f64(m.voices)))
					wet += f64(delay_line_read(&m.lines[c], (delay + depth * lfo) * ms, .Cubic))
				}
				wet /= f64(m.voices)
			case .Flanger:
				// The LFO swings the delay from `delay` to `delay + 2 depth`.
				lfo := 0.5 - 0.5 * math.cos(math.TAU * phase)
				delay_line_write(&m.lines[c], f32(x + fb * m.last[c]))
				wet = f64(delay_line_read(&m.lines[c], (delay + 2 * depth * lfo) * ms, .Cubic))
				m.last[c] = wet
			case .Phaser:
				// The allpass frequency moves on a log scale.
				lfo := 0.5 - 0.5 * math.cos(math.TAU * phase)
				hz := m.min_hz * math.pow(m.max_hz / m.min_hz, lfo * depth * 0.01)
				g := math.tan(math.PI * min(hz, m.sample_rate * 0.49) / m.sample_rate)
				gg := g / (1 + g)
				y := x + fb * m.last[c]
				for k in 0 ..< m.voices {
					s := &m.stages[c][k]
					v := (y - s^) * gg
					low := v + s^
					s^ = low + v
					y = 2 * low - y // allpass = 2 × lowpass − input
				}
				m.last[c] = y
				wet = y
			}
			ctx.outputs[c][i] = f32((1 - mix) * x + mix * wet)
		}
		m.phase += step
		if m.phase >= 1 do m.phase -= 1
	}
	for c in outs ..< len(ctx.outputs) do for i in from ..< to do ctx.outputs[c][i] = 0
}
