package dsp

import "core:math"
import "core:mem"

import "fire:core"

/*
Effects for playing live (a sampler's performance pads): a bit-crusher, a
ring modulator, a comb filter, a pitch shifter, a tempo-synced cutter and
a stutter (beat repeat). Stereo (the first two channels; others are
silent). The cutter and the stutter follow the clock's grid through
`Process_Context.transport` (120 BPM without one).
*/

// Most channels the performance effects process.
@(private) PERF_CHANNELS :: 2

// Applies parameter events at their offsets: renders up to each one.
@(private)
Render_Proc :: proc(self: rawptr, ctx: ^core.Process_Context, from, to: int)

// [rt] Runs `render` between the events of `ctx`, each event first given
// to `apply`.
@(private)
run_segments :: proc(self: rawptr, ctx: ^core.Process_Context, apply: proc(self: rawptr, e: core.Event), render: Render_Proc) {
	pos := 0
	for e in ctx.events_in {
		at := clamp(int(e.offset), pos, ctx.frames)
		render(self, ctx, pos, at)
		pos = at
		apply(self, e)
	}
	render(self, ctx, pos, ctx.frames)
	for c in PERF_CHANNELS ..< len(ctx.outputs) do for &v in ctx.outputs[c][:ctx.frames] do v = 0
}

// [rt] Input sample `i` of channel `c` (0 past the inputs).
@(private)
input_at :: #force_inline proc "contextless" (ctx: ^core.Process_Context, c, i: int) -> f32 {
	return ctx.inputs[c][i] if c < len(ctx.inputs) else 0
}

// --- bit-crusher ---------------------------------------------------------------------------

// Parameter id of the bit-crusher's bits: 1..16: the sample's resolution
BITCRUSH_PARAM_BITS :: core.Param_Id(1)
// Parameter id of the bit-crusher's downsample: 1..50: each sample held this many frames
BITCRUSH_PARAM_DOWNSAMPLE :: core.Param_Id(2)
// Parameter id of the bit-crusher's mix: 0..1
BITCRUSH_PARAM_MIX :: core.Param_Id(3)

// Bit-crusher parameters. Read-only.
bitcrush_params := [?]core.Param_Info{
	{id = BITCRUSH_PARAM_BITS, name = "Bits", min = 1, max = 16, default = 8, flags = {.Automatable}},
	{id = BITCRUSH_PARAM_DOWNSAMPLE, name = "Downsample", min = 1, max = 50, default = 4, flags = {.Automatable}},
	{id = BITCRUSH_PARAM_MIX, name = "Mix", unit = .Percent, min = 0, max = 1, default = 1, smoothing = .Linear, smoothing_ms = 15, flags = {.Automatable}},
}

// Fewer bits and a lower sample rate: lo-fi grit.
Bitcrush :: struct {
	bits, downsample: f64,
	mix:   Smoothed_Value,
	held:  [PERF_CHANNELS]f32,
	count: f64,
}

@(private)
bitcrush_vtable := core.Node_VTable {
	prepare = proc(self: rawptr, cfg: core.Prepare_Config, a: mem.Allocator) -> core.Error {
		b := (^Bitcrush)(self)
		smoothed_init_from_param(&b.mix, bitcrush_params[2], cfg.sample_rate)
		smoothed_reset(&b.mix, b.mix.target)
		return .None
	},
	reset = proc(self: rawptr) {
		b := (^Bitcrush)(self)
		b.held, b.count = {}, 0
	},
	process = proc(self: rawptr, ctx: ^core.Process_Context) {
		run_segments(self, ctx, proc(self: rawptr, e: core.Event) {
			b := (^Bitcrush)(self)
			if v, _, ok := core.param_event(e.payload, BITCRUSH_PARAM_BITS); ok do b.bits = clamp(v, 1, 16)
			if v, _, ok := core.param_event(e.payload, BITCRUSH_PARAM_DOWNSAMPLE); ok do b.downsample = clamp(v, 1, 50)
			if v, r, ok := core.param_event(e.payload, BITCRUSH_PARAM_MIX); ok do smoothed_apply(&b.mix, clamp(v, 0, 1), r)
		}, proc(self: rawptr, ctx: ^core.Process_Context, from, to: int) {
			b := (^Bitcrush)(self)
			levels := f32(math.pow(2, b.bits - 1))
			for i in from ..< to {
				b.count += 1
				take := b.count >= b.downsample
				if take do b.count -= b.downsample
				m := f32(smoothed_next(&b.mix))
				for c in 0 ..< min(len(ctx.outputs), PERF_CHANNELS) {
					x := input_at(ctx, c, i)
					if take do b.held[c] = math.round(x * levels) / levels
					ctx.outputs[c][i] = x + (b.held[c] - x) * m
				}
			}
		})
	},
	params  = proc(self: rawptr) -> []core.Param_Info { return bitcrush_params[:] },
	destroy = proc(self: rawptr, a: mem.Allocator) { free((^Bitcrush)(self), a) },
}

// Control thread. A bit-crusher node.
bitcrush_create :: proc(allocator := context.allocator) -> core.Node {
	b := new(Bitcrush, allocator)
	b.bits, b.downsample = bitcrush_params[0].default, bitcrush_params[1].default
	b.mix.target = 1
	return core.node_make(&bitcrush_vtable, b, allocator)
}

// --- ring modulator ------------------------------------------------------------------------

// Parameter id of the ring modulator's frequency, Hz: 1..5000: the carrier
RING_PARAM_HZ :: core.Param_Id(1)
// Parameter id of the ring modulator's mix: 0..1
RING_PARAM_MIX :: core.Param_Id(2)

// Ring modulator parameters. Read-only.
ring_params := [?]core.Param_Info{
	{id = RING_PARAM_HZ, name = "Frequency", unit = .Hertz, min = 1, max = 5000, default = 440, smoothing = .Linear, smoothing_ms = 20, flags = {.Automatable}},
	{id = RING_PARAM_MIX, name = "Mix", unit = .Percent, min = 0, max = 1, default = 1, smoothing = .Linear, smoothing_ms = 15, flags = {.Automatable}},
}

// Multiplies the input by a sine: metallic, bell-like sidebands.
Ring_Mod :: struct {
	hz, mix: Smoothed_Value,
	phase:   f64,
	rate:    f64,
}

@(private)
ring_vtable := core.Node_VTable {
	prepare = proc(self: rawptr, cfg: core.Prepare_Config, a: mem.Allocator) -> core.Error {
		r := (^Ring_Mod)(self)
		hz, mix := r.hz.target, r.mix.target
		smoothed_init_from_param(&r.hz, ring_params[0], cfg.sample_rate)
		smoothed_init_from_param(&r.mix, ring_params[1], cfg.sample_rate)
		smoothed_reset(&r.hz, hz)
		smoothed_reset(&r.mix, mix)
		r.rate = cfg.sample_rate
		return .None
	},
	reset = proc(self: rawptr) { (^Ring_Mod)(self).phase = 0 },
	process = proc(self: rawptr, ctx: ^core.Process_Context) {
		run_segments(self, ctx, proc(self: rawptr, e: core.Event) {
			r := (^Ring_Mod)(self)
			if v, f, ok := core.param_event(e.payload, RING_PARAM_HZ); ok do smoothed_apply(&r.hz, clamp(v, 1, 5000), f)
			if v, f, ok := core.param_event(e.payload, RING_PARAM_MIX); ok do smoothed_apply(&r.mix, clamp(v, 0, 1), f)
		}, proc(self: rawptr, ctx: ^core.Process_Context, from, to: int) {
			r := (^Ring_Mod)(self)
			for i in from ..< to {
				carrier := f32(math.sin(r.phase))
				r.phase += math.TAU * smoothed_next(&r.hz) / r.rate
				if r.phase > math.TAU do r.phase -= math.TAU
				m := f32(smoothed_next(&r.mix))
				for c in 0 ..< min(len(ctx.outputs), PERF_CHANNELS) {
					x := input_at(ctx, c, i)
					ctx.outputs[c][i] = x + (x * carrier - x) * m
				}
			}
		})
	},
	params  = proc(self: rawptr) -> []core.Param_Info { return ring_params[:] },
	destroy = proc(self: rawptr, a: mem.Allocator) { free((^Ring_Mod)(self), a) },
}

// Control thread. A ring modulator node.
ring_mod_create :: proc(allocator := context.allocator) -> core.Node {
	r := new(Ring_Mod, allocator)
	r.hz.target, r.mix.target = ring_params[0].default, ring_params[1].default
	return core.node_make(&ring_vtable, r, allocator)
}

// --- comb filter ---------------------------------------------------------------------------

// Parameter id of the comb filter's frequency, Hz: 20..5000: the pitch it rings at (its delay is 1/Hz)
COMB_PARAM_HZ :: core.Param_Id(1)
// Parameter id of the comb filter's feedback: -0.98..0.98
COMB_PARAM_FEEDBACK :: core.Param_Id(2)
// Parameter id of the comb filter's mix: 0..1
COMB_PARAM_MIX :: core.Param_Id(3)

// Comb filter parameters. Read-only.
comb_params := [?]core.Param_Info{
	{id = COMB_PARAM_HZ, name = "Frequency", unit = .Hertz, min = 20, max = 5000, default = 220, smoothing = .Linear, smoothing_ms = 30, flags = {.Automatable}},
	{id = COMB_PARAM_FEEDBACK, name = "Feedback", min = -0.98, max = 0.98, default = 0.85, flags = {.Automatable}},
	{id = COMB_PARAM_MIX, name = "Mix", unit = .Percent, min = 0, max = 1, default = 0.6, smoothing = .Linear, smoothing_ms = 15, flags = {.Automatable}},
}

// A feedback comb: a short delay fed back on itself rings at its pitch.
Comb :: struct {
	hz, mix:  Smoothed_Value,
	feedback: f64,
	lines:    [PERF_CHANNELS][]f32,
	pos:      int,
	rate:     f64,
}

@(private)
comb_vtable := core.Node_VTable {
	prepare = proc(self: rawptr, cfg: core.Prepare_Config, a: mem.Allocator) -> core.Error {
		cb := (^Comb)(self)
		hz, mix := cb.hz.target, cb.mix.target
		smoothed_init_from_param(&cb.hz, comb_params[0], cfg.sample_rate)
		smoothed_init_from_param(&cb.mix, comb_params[2], cfg.sample_rate)
		smoothed_reset(&cb.hz, hz)
		smoothed_reset(&cb.mix, mix)
		cb.rate = cfg.sample_rate
		n := int(cfg.sample_rate / 20) + 4
		for &l in cb.lines {
			l = make([]f32, n, a)
			if l == nil do return .Out_Of_Memory
		}
		return .None
	},
	release = proc(self: rawptr, a: mem.Allocator) {
		for &l in (^Comb)(self).lines {
			delete(l, a)
			l = nil
		}
	},
	reset = proc(self: rawptr) {
		cb := (^Comb)(self)
		for l in cb.lines do for &v in l do v = 0
	},
	process = proc(self: rawptr, ctx: ^core.Process_Context) {
		run_segments(self, ctx, proc(self: rawptr, e: core.Event) {
			cb := (^Comb)(self)
			if v, f, ok := core.param_event(e.payload, COMB_PARAM_HZ); ok do smoothed_apply(&cb.hz, clamp(v, 20, 5000), f)
			if v, _, ok := core.param_event(e.payload, COMB_PARAM_FEEDBACK); ok do cb.feedback = clamp(v, -0.98, 0.98)
			if v, f, ok := core.param_event(e.payload, COMB_PARAM_MIX); ok do smoothed_apply(&cb.mix, clamp(v, 0, 1), f)
		}, proc(self: rawptr, ctx: ^core.Process_Context, from, to: int) {
			cb := (^Comb)(self)
			n := len(cb.lines[0])
			fb := f32(cb.feedback)
			for i in from ..< to {
				d := clamp(cb.rate / smoothed_next(&cb.hz), 1, f64(n - 2))
				di := int(d)
				frac := f32(d - f64(di))
				m := f32(smoothed_next(&cb.mix))
				for c in 0 ..< min(len(ctx.outputs), PERF_CHANNELS) {
					l := cb.lines[c]
					a := l[(cb.pos - di + n) % n]
					b := l[(cb.pos - di - 1 + n) % n]
					delayed := a + (b - a) * frac
					x := input_at(ctx, c, i)
					y := x + fb * delayed
					l[cb.pos] = y
					// Scaled so a strong resonance does not get much louder.
					wet := y * (1 - abs(fb)) * 2
					ctx.outputs[c][i] = x + (wet - x) * m
				}
				cb.pos = (cb.pos + 1) % n
			}
		})
	},
	params  = proc(self: rawptr) -> []core.Param_Info { return comb_params[:] },
	destroy = proc(self: rawptr, a: mem.Allocator) { free((^Comb)(self), a) },
}

// Control thread. A comb filter node.
comb_create :: proc(allocator := context.allocator) -> core.Node {
	cb := new(Comb, allocator)
	cb.hz.target, cb.feedback, cb.mix.target = comb_params[0].default, comb_params[1].default, comb_params[2].default
	return core.node_make(&comb_vtable, cb, allocator)
}

// --- pitch shifter -------------------------------------------------------------------------

// Parameter id of the pitch shifter's semitones: -24..24
PITCH_PARAM_SEMITONES :: core.Param_Id(1)
// Parameter id of the pitch shifter's window, ms: 20..100: grain length (shorter: tighter, grainier)
PITCH_PARAM_WINDOW_MS :: core.Param_Id(2)
// Parameter id of the pitch shifter's mix: 0..1
PITCH_PARAM_MIX :: core.Param_Id(3)

// Pitch shifter parameters. Read-only.
pitch_params := [?]core.Param_Info{
	{id = PITCH_PARAM_SEMITONES, name = "Pitch", unit = .Semitones, min = -24, max = 24, default = 12, smoothing = .Linear, smoothing_ms = 30, flags = {.Automatable}},
	{id = PITCH_PARAM_WINDOW_MS, name = "Window", unit = .Milliseconds, min = 20, max = 100, default = 40, flags = {.Automatable}},
	{id = PITCH_PARAM_MIX, name = "Mix", unit = .Percent, min = 0, max = 1, default = 1, smoothing = .Linear, smoothing_ms = 15, flags = {.Automatable}},
}

// Shifts pitch without changing length: two read heads sweep a short
// delay line at the new speed, half a window apart, each faded in and out
// so their jumps back are never heard.
Pitch_Shift :: struct {
	semis, mix: Smoothed_Value,
	window_ms:  f64,
	lines:      [PERF_CHANNELS][]f32,
	pos:        int,
	phase:      f64, // 0..1 through the window
	rate:       f64,
}

@(private)
pitch_vtable := core.Node_VTable {
	prepare = proc(self: rawptr, cfg: core.Prepare_Config, a: mem.Allocator) -> core.Error {
		p := (^Pitch_Shift)(self)
		s, mix := p.semis.target, p.mix.target
		smoothed_init_from_param(&p.semis, pitch_params[0], cfg.sample_rate)
		smoothed_init_from_param(&p.mix, pitch_params[2], cfg.sample_rate)
		smoothed_reset(&p.semis, s)
		smoothed_reset(&p.mix, mix)
		p.rate = cfg.sample_rate
		n := int(cfg.sample_rate * 0.11) + 4
		for &l in p.lines {
			l = make([]f32, n, a)
			if l == nil do return .Out_Of_Memory
		}
		return .None
	},
	release = proc(self: rawptr, a: mem.Allocator) {
		for &l in (^Pitch_Shift)(self).lines {
			delete(l, a)
			l = nil
		}
	},
	reset = proc(self: rawptr) {
		p := (^Pitch_Shift)(self)
		for l in p.lines do for &v in l do v = 0
		p.phase = 0
	},
	process = proc(self: rawptr, ctx: ^core.Process_Context) {
		run_segments(self, ctx, proc(self: rawptr, e: core.Event) {
			p := (^Pitch_Shift)(self)
			if v, f, ok := core.param_event(e.payload, PITCH_PARAM_SEMITONES); ok do smoothed_apply(&p.semis, clamp(v, -24, 24), f)
			if v, _, ok := core.param_event(e.payload, PITCH_PARAM_WINDOW_MS); ok do p.window_ms = clamp(v, 20, 100)
			if v, f, ok := core.param_event(e.payload, PITCH_PARAM_MIX); ok do smoothed_apply(&p.mix, clamp(v, 0, 1), f)
		}, proc(self: rawptr, ctx: ^core.Process_Context, from, to: int) {
			p := (^Pitch_Shift)(self)
			n := len(p.lines[0])
			w := p.window_ms * 0.001 * p.rate
			read :: #force_inline proc "contextless" (l: []f32, pos: int, d: f64) -> f32 {
				n := len(l)
				di := int(d)
				frac := f32(d - f64(di))
				a := l[(pos - di + 2 * n) % n]
				b := l[(pos - di - 1 + 2 * n) % n]
				return a + (b - a) * frac
			}
			for i in from ..< to {
				ratio := math.pow(2, smoothed_next(&p.semis) / 12)
				// The delay shrinks (ratio > 1) or grows by 1 - ratio a frame.
				p.phase -= (ratio - 1) / w
				p.phase -= math.floor(p.phase)
				ph2 := p.phase + 0.5
				ph2 -= math.floor(ph2)
				g1 := f32(math.sin(math.PI * p.phase))
				g2 := f32(math.sin(math.PI * ph2))
				m := f32(smoothed_next(&p.mix))
				for c in 0 ..< min(len(ctx.outputs), PERF_CHANNELS) {
					l := p.lines[c]
					x := input_at(ctx, c, i)
					l[p.pos] = x
					wet := read(l, p.pos, 1 + p.phase * w) * g1 + read(l, p.pos, 1 + ph2 * w) * g2
					ctx.outputs[c][i] = x + (wet - x) * m
				}
				p.pos = (p.pos + 1) % n
			}
		})
	},
	params  = proc(self: rawptr) -> []core.Param_Info { return pitch_params[:] },
	destroy = proc(self: rawptr, a: mem.Allocator) { free((^Pitch_Shift)(self), a) },
}

// Control thread. A pitch shifter node.
pitch_shift_create :: proc(allocator := context.allocator) -> core.Node {
	p := new(Pitch_Shift, allocator)
	p.semis.target, p.window_ms, p.mix.target = pitch_params[0].default, pitch_params[1].default, pitch_params[2].default
	return core.node_make(&pitch_vtable, p, allocator)
}

// --- cutter --------------------------------------------------------------------------------

// Parameter id of the cutter's beats: 1/32..1: one gate cycle, in beats
CUTTER_PARAM_BEATS :: core.Param_Id(1)
// Parameter id of the cutter's duty: 0.05..0.95: how much of the cycle is open
CUTTER_PARAM_DUTY :: core.Param_Id(2)
// Parameter id of the cutter's depth: 0..1: how far it closes
CUTTER_PARAM_DEPTH :: core.Param_Id(3)

// Cutter parameters. Read-only.
cutter_params := [?]core.Param_Info{
	{id = CUTTER_PARAM_BEATS, name = "Rate", min = 1.0 / 32, max = 1, default = 0.25, flags = {.Automatable}},
	{id = CUTTER_PARAM_DUTY, name = "Duty", min = 0.05, max = 0.95, default = 0.5, flags = {.Automatable}},
	{id = CUTTER_PARAM_DEPTH, name = "Depth", min = 0, max = 1, default = 1, flags = {.Automatable}},
}

// A trance gate on the beat grid: open for the first `duty` of every cycle
// of `beats`, closed (by `depth`) for the rest, with edges of a couple of
// milliseconds so it never clicks.
Cutter :: struct {
	beats, duty, depth: f64,
	gain:  f64, // smoothed gate gain
	coef:  f64, // one-pole step for the edges
	beat:  f64, // own clock without a transport
	rate:  f64,
}

@(private)
cutter_vtable := core.Node_VTable {
	prepare = proc(self: rawptr, cfg: core.Prepare_Config, a: mem.Allocator) -> core.Error {
		ct := (^Cutter)(self)
		ct.rate = cfg.sample_rate
		ct.coef = 1 - math.exp(-1 / (0.002 * cfg.sample_rate))
		ct.gain = 1
		return .None
	},
	reset = proc(self: rawptr) {
		ct := (^Cutter)(self)
		ct.gain, ct.beat = 1, 0
	},
	process = proc(self: rawptr, ctx: ^core.Process_Context) {
		run_segments(self, ctx, proc(self: rawptr, e: core.Event) {
			ct := (^Cutter)(self)
			if v, _, ok := core.param_event(e.payload, CUTTER_PARAM_BEATS); ok do ct.beats = clamp(v, 1.0 / 32, 1)
			if v, _, ok := core.param_event(e.payload, CUTTER_PARAM_DUTY); ok do ct.duty = clamp(v, 0.05, 0.95)
			if v, _, ok := core.param_event(e.payload, CUTTER_PARAM_DEPTH); ok do ct.depth = clamp(v, 0, 1)
		}, proc(self: rawptr, ctx: ^core.Process_Context, from, to: int) {
			ct := (^Cutter)(self)
			t := ctx.transport
			for i in from ..< to {
				beat: f64
				if t != nil {
					beat = f64(core.transport_grid_at(t, i))
				} else {
					beat = ct.beat
					ct.beat += 2 / ct.rate // 120 BPM
				}
				// A hair's tolerance, so an edge on a frame falls the same
				// way at any block size.
				cycle := beat / ct.beats + 1e-7
				open := cycle - math.floor(cycle) < ct.duty
				target := 1.0 if open else 1 - ct.depth
				ct.gain += (target - ct.gain) * ct.coef
				g := f32(ct.gain)
				for c in 0 ..< min(len(ctx.outputs), PERF_CHANNELS) do ctx.outputs[c][i] = input_at(ctx, c, i) * g
			}
		})
	},
	params  = proc(self: rawptr) -> []core.Param_Info { return cutter_params[:] },
	destroy = proc(self: rawptr, a: mem.Allocator) { free((^Cutter)(self), a) },
}

// Control thread. A cutter node.
cutter_create :: proc(allocator := context.allocator) -> core.Node {
	ct := new(Cutter, allocator)
	ct.beats, ct.duty, ct.depth = cutter_params[0].default, cutter_params[1].default, cutter_params[2].default
	return core.node_make(&cutter_vtable, ct, allocator)
}

// --- stutter -------------------------------------------------------------------------------

// Parameter id of the stutter's beats: 1/32..1: the slice repeated, in beats
STUTTER_PARAM_BEATS :: core.Param_Id(1)
// Parameter id of the stutter's active: 1 repeats, 0 plays the input (stepped)
STUTTER_PARAM_ACTIVE :: core.Param_Id(2)

// Stutter parameters. Read-only.
stutter_params := [?]core.Param_Info{
	{id = STUTTER_PARAM_BEATS, name = "Length", min = 1.0 / 32, max = 1, default = 0.25, flags = {.Automatable}},
	{id = STUTTER_PARAM_ACTIVE, name = "Active", min = 0, max = 1, default = 0, flags = {.Automatable, .Stepped}},
}

// Beat repeat: it always listens to the last few seconds; switched on, it
// loops the slice of `beats` that just went by, until switched off. Each
// repeat is faded at its ends, and switching crossfades, so it never clicks.
Stutter :: struct {
	beats:    f64,
	active:   bool,
	ring:     [PERF_CHANNELS][]f32,
	pos:      int,  // write position
	start:    int,  // the slice: its first frame in the ring
	length:   int,  // its frames
	play:     int,  // frames into the slice
	mix:      f64,  // 0 = input, 1 = the slice (crossfaded)
	step:     f64,
	edge:     int,  // fade length at a repeat's ends
	rate:     f64,
}

@(private)
stutter_vtable := core.Node_VTable {
	prepare = proc(self: rawptr, cfg: core.Prepare_Config, a: mem.Allocator) -> core.Error {
		s := (^Stutter)(self)
		s.rate = cfg.sample_rate
		n := int(cfg.sample_rate * 4) // 4 s: a beat at 15 BPM
		for &r in s.ring {
			r = make([]f32, n, a)
			if r == nil do return .Out_Of_Memory
		}
		s.step = 1 / (0.005 * cfg.sample_rate)
		s.edge = max(int(0.002 * cfg.sample_rate), 1)
		return .None
	},
	release = proc(self: rawptr, a: mem.Allocator) {
		for &r in (^Stutter)(self).ring {
			delete(r, a)
			r = nil
		}
	},
	reset = proc(self: rawptr) {
		s := (^Stutter)(self)
		for r in s.ring do for &v in r do v = 0
		s.active, s.mix, s.play = false, 0, 0
	},
	process = proc(self: rawptr, ctx: ^core.Process_Context) {
		run_segments(self, ctx, proc(self: rawptr, e: core.Event) {
			s := (^Stutter)(self)
			if v, _, ok := core.param_event(e.payload, STUTTER_PARAM_BEATS); ok do s.beats = clamp(v, 1.0 / 32, 1)
			if v, _, ok := core.param_event(e.payload, STUTTER_PARAM_ACTIVE); ok {
				on := v >= 0.5
				if on && !s.active do s.length = -1 // take the slice at the next frame
				s.active = on
			}
		}, proc(self: rawptr, ctx: ^core.Process_Context, from, to: int) {
			s := (^Stutter)(self)
			n := len(s.ring[0])
			for i in from ..< to {
				if s.length < 0 {
					bpm := ctx.transport.tempo_bpm if ctx.transport != nil && ctx.transport.tempo_bpm > 0 else 120
					s.length = clamp(int(s.beats * 60 / bpm * s.rate), 2 * s.edge + 1, n - 1)
					s.start = (s.pos - s.length + n) % n
					s.play = 0
				}
				target := 1.0 if s.active else 0.0
				if s.mix < target do s.mix = min(s.mix + s.step, 1)
				if s.mix > target do s.mix = max(s.mix - s.step, 0)
				// The slice's window, ms: faded in and out at each repeat.
				win: f32 = 1
				if s.play < s.edge do win = f32(s.play) / f32(s.edge)
				else if s.length - s.play <= s.edge do win = f32(s.length - s.play) / f32(s.edge)
				m := f32(s.mix)
				for c in 0 ..< min(len(ctx.outputs), PERF_CHANNELS) {
					x := input_at(ctx, c, i)
					r := s.ring[c]
					y: f32 = 0
					if s.length > 0 do y = r[(s.start + s.play) % n] * win
					// Keep listening while not repeating (repeating, the
					// slice must stay as it was).
					if !s.active do r[s.pos] = x
					ctx.outputs[c][i] = x + (y - x) * m
				}
				if s.active || s.mix > 0 {
					if s.length > 0 do s.play = (s.play + 1) % s.length
				}
				if !s.active do s.pos = (s.pos + 1) % n
			}
		})
	},
	params  = proc(self: rawptr) -> []core.Param_Info { return stutter_params[:] },
	destroy = proc(self: rawptr, a: mem.Allocator) { free((^Stutter)(self), a) },
}

// Control thread. A stutter node.
stutter_create :: proc(allocator := context.allocator) -> core.Node {
	s := new(Stutter, allocator)
	s.beats = stutter_params[0].default
	return core.node_make(&stutter_vtable, s, allocator)
}
