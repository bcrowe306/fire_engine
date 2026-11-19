package fx

import "base:intrinsics"
import "core:math"
import "core:mem"

import "fire:core"
import "fire:dsp"

// ProSaturator: a waveshaping saturator as a graph node. Stereo in and out.
//
// The signal: Drive → Color's pre-emphasis (a low shelf and a bell) → the
// curve (one of ten; Tape's treble loss after it), oversampled 2× or 4×
// when made so (`Pro_Saturator_Settings.quality`) → Color's inverse → DC
// (a 10 Hz high-pass) → Output → Dry/Wet (the dry as late as the
// oversampling) → Soft Clip (never past full scale).
//
// Every change lands on its exact frame (Drive, Output, Dry/Wet and the
// Waveshaper's knobs glide per frame), so any block size gives the same
// output.
//
//	node, ps := fx.pro_saturator_create({quality = .X2})
//	// graph.set_param(g, id, fx.PS_PARAM_DRIVE_DB, 12)

// ProSaturator's curves.
Pro_Saturator_Type :: enum u8 {
	Analog_Clip,  // a smooth knee into a hard ceiling
	Soft_Sine,    // a sine's quarter: the gentlest
	Bass_Shaper,  // soft when quiet, harder as it rises
	Medium_Curve, // tanh
	Hard_Curve,   // a steeper knee than tanh
	Sinoid_Fold,  // a sine: past the top, the wave folds back
	Digital_Clip, // a hard clip at ±1
	Tube,         // asymmetric: even harmonics
	Tape,         // soft, its treble lost as it is driven
	Waveshaper,   // built from the Waveshaper's six knobs
}

// ProSaturator's oversampling.
Pro_Saturator_Quality :: enum u8 {Off, X2, X4}

// Parameter id of ProSaturator's type: a `Pro_Saturator_Type`.
PS_PARAM_TYPE :: core.Param_Id(1)
// Parameter id of ProSaturator's drive: dB, −36..36.
PS_PARAM_DRIVE_DB :: core.Param_Id(2)
// Parameter id of ProSaturator's DC filter: 0 or 1.
PS_PARAM_DC :: core.Param_Id(3)
// Parameter id of ProSaturator's Color switch: 0 or 1.
PS_PARAM_COLOR :: core.Param_Id(4)
// Parameter id of Color's Base: −1..1 (a low shelf at 200 Hz, ±12 dB).
PS_PARAM_BASE :: core.Param_Id(5)
// Parameter id of Color's bell frequency: Hz, 30..18000.
PS_PARAM_FREQ_HZ :: core.Param_Id(6)
// Parameter id of Color's bell width: 0..1.
PS_PARAM_WIDTH :: core.Param_Id(7)
// Parameter id of Color's bell depth: −1..1 (±12 dB).
PS_PARAM_DEPTH :: core.Param_Id(8)
// Parameter id of the Waveshaper's drive: 0..1.
PS_PARAM_WS_DRIVE :: core.Param_Id(9)
// Parameter id of the Waveshaper's linear part: −1..1.
PS_PARAM_WS_LIN :: core.Param_Id(10)
// Parameter id of the Waveshaper's cubic part: −1..1.
PS_PARAM_WS_CURVE :: core.Param_Id(11)
// Parameter id of the Waveshaper's damping of small signals: 0..1.
PS_PARAM_WS_DAMP :: core.Param_Id(12)
// Parameter id of the Waveshaper's sine part: −1..1.
PS_PARAM_WS_DEPTH :: core.Param_Id(13)
// Parameter id of the Waveshaper's sine density: 0..1.
PS_PARAM_WS_PERIOD :: core.Param_Id(14)
// Parameter id of ProSaturator's Soft Clip: 0 or 1.
PS_PARAM_SOFT_CLIP :: core.Param_Id(15)
// Parameter id of ProSaturator's output gain: dB, −36..12.
PS_PARAM_OUTPUT_DB :: core.Param_Id(16)
// Parameter id of ProSaturator's Dry/Wet: 0..1.
PS_PARAM_MIX :: core.Param_Id(17)
// Parameter id of ProSaturator's Quality: a `Pro_Saturator_Quality`. Read
// when the node is made (`Pro_Saturator_Settings.quality`): it sets the
// latency.
PS_PARAM_QUALITY :: core.Param_Id(18)

// Parameter table of the ProSaturator node, as `node_params` returns it. Read-only.
pro_saturator_params := [?]core.Param_Info {
	{id = PS_PARAM_TYPE, name = "Type", min = 0, max = f64(max(Pro_Saturator_Type)), default = 0, flags = {.Automatable, .Stepped}},
	{id = PS_PARAM_DRIVE_DB, name = "Drive", unit = .Decibels, min = -36, max = 36, default = 0, flags = {.Automatable}},
	{id = PS_PARAM_DC, name = "DC", min = 0, max = 1, default = 1, flags = {.Automatable, .Stepped}},
	{id = PS_PARAM_COLOR, name = "Color", min = 0, max = 1, default = 0, flags = {.Automatable, .Stepped}},
	{id = PS_PARAM_BASE, name = "Base", min = -1, max = 1, default = 0, flags = {.Automatable}},
	{id = PS_PARAM_FREQ_HZ, name = "Freq", unit = .Hertz, min = 30, max = 18_000, default = 1000, flags = {.Automatable}},
	{id = PS_PARAM_WIDTH, name = "Width", unit = .Percent, min = 0, max = 1, default = 0.3, flags = {.Automatable}},
	{id = PS_PARAM_DEPTH, name = "Depth", min = -1, max = 1, default = 0, flags = {.Automatable}},
	{id = PS_PARAM_WS_DRIVE, name = "WS Drive", unit = .Percent, min = 0, max = 1, default = 0.5, flags = {.Automatable}},
	{id = PS_PARAM_WS_LIN, name = "WS Lin", min = -1, max = 1, default = 0.5, flags = {.Automatable}},
	{id = PS_PARAM_WS_CURVE, name = "WS Curve", min = -1, max = 1, default = 0.05, flags = {.Automatable}},
	{id = PS_PARAM_WS_DAMP, name = "WS Damp", unit = .Percent, min = 0, max = 1, default = 0, flags = {.Automatable}},
	{id = PS_PARAM_WS_DEPTH, name = "WS Depth", min = -1, max = 1, default = 0, flags = {.Automatable}},
	{id = PS_PARAM_WS_PERIOD, name = "WS Period", unit = .Percent, min = 0, max = 1, default = 0, flags = {.Automatable}},
	{id = PS_PARAM_SOFT_CLIP, name = "Soft Clip", min = 0, max = 1, default = 0, flags = {.Automatable, .Stepped}},
	{id = PS_PARAM_OUTPUT_DB, name = "Output", unit = .Decibels, min = -36, max = 12, default = 0, flags = {.Automatable}},
	{id = PS_PARAM_MIX, name = "Dry/Wet", unit = .Percent, min = 0, max = 1, default = 1, flags = {.Automatable}},
	{id = PS_PARAM_QUALITY, name = "Quality", min = 0, max = f64(max(Pro_Saturator_Quality)), default = 0, flags = {.Stepped}},
}

// The number of ProSaturator parameters (ids 1 to this).
PS_PARAMS :: len(pro_saturator_params)

// Settings for `pro_saturator_create`.
Pro_Saturator_Settings :: struct {
	quality: Pro_Saturator_Quality,
}

// A ProSaturator's settings, by parameter id (index 0 unused).
Pro_Saturator_Values :: [PS_PARAMS + 1]f32

// ProSaturator's settings at their defaults.
pro_saturator_defaults :: proc "contextless" () -> (v: Pro_Saturator_Values) {
	for p in pro_saturator_params do v[p.id] = f32(p.default)
	return
}

// What a ProSaturator is doing, for its meters (`pro_saturator_readout`).
Pro_Saturator_Readout :: struct {
	in_peak:  f32, // the last block's peak into the curve (after Drive; linear)
	out_peak: f32, // and out
}

// Points ProSaturator's signal ring keeps (a power of two), one every
// `PS_SIGNAL_EVERY` frames.
PS_SIGNAL :: 256
// Frames between the signal ring's points.
PS_SIGNAL_EVERY :: 8

// Frames ProSaturator works in at a time (its oversamplers' block).
@(private = "file")
PS_CHUNK :: 64

// The Waveshaper's knobs, as they glide.
@(private = "file")
Ps_Shape :: struct {
	drive, lin, curve, damp, depth, period: f64,
}

// A ProSaturator node's state (from `pro_saturator_create`). Fields are internal.
Pro_Saturator :: struct {
	settings:    Pro_Saturator_Settings,
	values:      Pro_Saturator_Values,
	sample_rate: f64,
	frame:       i64,
	os:          [2]dsp.Oversampler,
	late:        int,
	dry:         [2][]f32, // the dry, waiting out the oversampling
	at:          int,
	glide:       [3]f64, // Drive, Output (linear), Dry/Wet: where they are
	shape:       Ps_Shape,
	glide_coeff: f64,
	pre, post:   [2]dsp.Svf_Coeffs, // Color: its shelf and bell, and their inverses
	color_for:   [4]f32,
	pre_state:   [2][2]dsp.Svf_State, // [stage][side]
	post_state:  [2][2]dsp.Svf_State,
	tape:        [2]f64, // Tape's low-pass, each side
	dc:          [2][2]f64, // the DC filter: its last input and output, each side
	dc_coeff:    f64,
	readout:     [2]u32, // atomics: the peaks in and out, as bits
	signal:      [PS_SIGNAL]f32, // what went into the curve (before Drive), one in PS_SIGNAL_EVERY
	written:     u64, // atomic: signal points written so far
	input:       dsp.Tap, // what came in, and what went out, for the harmonics
	output:      dsp.Tap,
	allocator:   mem.Allocator,
}

@(private = "file")
pro_saturator_vtable := core.Node_VTable {
	name    = "fire.pro_saturator",
	prepare = pro_saturator_prepare,
	process = pro_saturator_process,
	reset   = proc(self: rawptr) { ps_clear((^Pro_Saturator)(self)) },
	release = proc(self: rawptr, allocator: mem.Allocator) {
		n := (^Pro_Saturator)(self)
		for &d in n.dry {
			delete(d, allocator)
			d = nil
		}
	},
	params  = proc(self: rawptr) -> []core.Param_Info { return pro_saturator_params[:] },
	latency = proc(self: rawptr) -> int { return (^Pro_Saturator)(self).late },
	destroy = proc(self: rawptr, allocator: mem.Allocator) {
		n := (^Pro_Saturator)(self)
		if n.settings.quality != .Off do for &o in n.os do dsp.oversampler_destroy(&o, n.allocator)
		free(n, allocator)
	},
}

// Control thread. A ProSaturator at its defaults (and `settings.quality`
// as its Quality). Add it with 2 inputs and 2 outputs.
pro_saturator_create :: proc(settings: Pro_Saturator_Settings, allocator := context.allocator) -> (node: core.Node, ps: ^Pro_Saturator, err: core.Error) {
	ps = new(Pro_Saturator, allocator)
	ps.settings, ps.allocator = settings, allocator
	ps.values = pro_saturator_defaults()
	ps.values[PS_PARAM_QUALITY] = f32(settings.quality)
	if settings.quality != .Off {
		factor := 2 if settings.quality == .X2 else 4
		for &o in ps.os {
			if e := dsp.oversampler_init(&o, factor, PS_CHUNK, allocator); e != .None {
				for &p in ps.os do dsp.oversampler_destroy(&p, allocator)
				free(ps, allocator)
				return {}, nil, e
			}
		}
		ps.late = dsp.oversampler_latency(&ps.os[0])
	}
	return core.node_make(&pro_saturator_vtable, ps, allocator), ps, .None
}

// Any thread. What ProSaturator `ps` is doing (as of its last block).
pro_saturator_readout :: proc "contextless" (ps: ^Pro_Saturator) -> Pro_Saturator_Readout {
	r: [2]f32
	for &v, k in r do v = transmute(f32)intrinsics.atomic_load_explicit(&ps.readout[k], .Relaxed)
	return {in_peak = r[0], out_peak = r[1]}
}

// Any thread. The last `len(out)` points of what went into ProSaturator
// `ps`'s curve (before Drive, the left side; at most `PS_SIGNAL`, one
// every `PS_SIGNAL_EVERY` frames), oldest first, and how many it has
// written in all.
pro_saturator_signal :: proc "contextless" (ps: ^Pro_Saturator, out: []f32) -> u64 {
	n := min(len(out), PS_SIGNAL)
	w := intrinsics.atomic_load(&ps.written)
	for i in 0 ..< n {
		k := i64(w) - i64(n) + i64(i)
		out[i] = ps.signal[u64(k) & (PS_SIGNAL - 1)] if k >= 0 else 0
	}
	return w
}

// Any thread. The last `len(input)` and `len(output)` frames ProSaturator
// `ps` took in and put out (the sides averaged; at most `dsp.TAP_FRAMES`),
// for the harmonics it adds.
pro_saturator_read_taps :: proc "contextless" (ps: ^Pro_Saturator, input, output: []f32) {
	dsp.tap_read(&ps.input, input)
	dsp.tap_read(&ps.output, output)
}

// [rt] ProSaturator's curve at settings `v` for an input `x` (before Drive:
// the curve as drawn steepens with Drive), without Color, Tape's filter,
// DC or Soft Clip.
pro_saturator_curve :: proc "contextless" (v: ^Pro_Saturator_Values, x: f32) -> f32 {
	typ := Pro_Saturator_Type(clamp(int(v[PS_PARAM_TYPE] + 0.5), 0, len(Pro_Saturator_Type) - 1))
	sh := Ps_Shape{f64(v[PS_PARAM_WS_DRIVE]), f64(v[PS_PARAM_WS_LIN]), f64(v[PS_PARAM_WS_CURVE]), f64(v[PS_PARAM_WS_DAMP]), f64(v[PS_PARAM_WS_DEPTH]), f64(v[PS_PARAM_WS_PERIOD])}
	return f32(ps_curve(typ, f64(x) * math.pow(10, f64(v[PS_PARAM_DRIVE_DB]) / 20), &sh))
}

// Control thread. Color's pre-emphasis at settings `v`, in dB at `hz` (0
// when Color is off), as the node runs it at `sample_rate`.
pro_saturator_color_response :: proc "contextless" (v: ^Pro_Saturator_Values, hz, sample_rate: f64) -> f32 {
	if v[PS_PARAM_COLOR] < 0.5 do return 0
	c := ps_color_design(v, sample_rate, 1)
	g := 1.0
	for &k in c {
		m, _ := dsp.svf_response(&k, hz, sample_rate)
		g *= m
	}
	return f32(20 * math.log10(max(g, 1e-9)))
}

// The curves: `x` (after Drive) to its output.
@(private = "file")
ps_curve :: proc "contextless" (typ: Pro_Saturator_Type, x: f64, sh: ^Ps_Shape) -> f64 {
	knee :: #force_inline proc "contextless" (x, p: f64) -> f64 { return x / math.pow(1 + math.pow(abs(x), p), 1 / p) }
	switch typ {
	case .Analog_Clip:  return knee(x, 6)
	case .Soft_Sine:    return math.sin(clamp(x, -math.PI / 2, math.PI / 2))
	case .Bass_Shaper:  return math.tanh(x + 0.35 * x * x * x)
	case .Medium_Curve: return math.tanh(x)
	case .Hard_Curve:   return knee(x, 2.5)
	case .Sinoid_Fold:  return math.sin(x)
	case .Digital_Clip: return clamp(x, -1, 1)
	case .Tube:
		B :: 0.25 // (the bias: the halves clip apart)
		return (math.tanh(x + B) - math.tanh(B)) / (1 - math.tanh(B) * math.tanh(B))
	case .Tape:         return x / math.sqrt(1 + x * x)
	case .Waveshaper:
		u := x * (0.5 + 4 * sh.drive)
		y := sh.lin * u + sh.curve * u * u * u + sh.depth * math.sin(math.PI * u * (1 + 15 * sh.period))
		if sh.damp > 0 {
			d := sh.damp * sh.damp * 0.25
			y *= u * u / (u * u + d)
		}
		return clamp(y, -4, 4)
	}
	return x
}

// Color's shelf and bell at settings `v` (`sign` 1: the pre-emphasis;
// −1: its inverse).
@(private = "file")
ps_color_design :: proc "contextless" (v: ^Pro_Saturator_Values, sr, sign: f64) -> [2]dsp.Svf_Coeffs {
	q := 0.4 + (1 - f64(v[PS_PARAM_WIDTH])) * 6 // (wide at 1, narrow at 0)
	return {
		dsp.svf_design(.Low_Shelf, 200, 0.707, sign * 12 * f64(v[PS_PARAM_BASE]), sr),
		dsp.svf_design(.Bell, f64(v[PS_PARAM_FREQ_HZ]), q, sign * 12 * f64(v[PS_PARAM_DEPTH]), sr),
	}
}

@(private = "file")
pro_saturator_prepare :: proc(self: rawptr, cfg: core.Prepare_Config, allocator: mem.Allocator) -> core.Error {
	n := (^Pro_Saturator)(self)
	n.sample_rate = cfg.sample_rate
	for &d in n.dry {
		if len(d) >= n.late + 1 do continue
		delete(d, allocator)
		ae: mem.Allocator_Error
		d, ae = make([]f32, n.late + 1, allocator)
		if ae != nil do return .Out_Of_Memory
	}
	n.glide_coeff = math.exp(-1 / (0.010 * cfg.sample_rate))
	n.dc_coeff = math.exp(-2 * math.PI * 10 / cfg.sample_rate)
	ps_clear(n)
	return .None
}

// [rt] Back to silence.
@(private = "file")
ps_clear :: proc "contextless" (n: ^Pro_Saturator) {
	for d in n.dry do for &x in d do x = 0
	n.at, n.frame = 0, 0
	n.pre_state, n.post_state, n.tape, n.dc = {}, {}, {}, {}
	n.color_for = {-9, -9, -9, -9}
	if n.settings.quality != .Off do for &o in n.os do dsp.oversampler_reset(&o)
}

@(private = "file")
pro_saturator_process :: proc(self: rawptr, ctx: ^core.Process_Context) {
	n := (^Pro_Saturator)(self)
	f := ctx.frames
	if len(ctx.outputs) < 2 || f < 0 || len(n.dry[0]) == 0 do return
	in_ := [2][]f32{ps_input(ctx, 0, f), ps_input(ctx, 1, f)}
	out := [2][]f32{ctx.outputs[0][:f], ctx.outputs[1][:f]}
	// What came in, for the harmonics (before the output may overwrite it).
	w := intrinsics.atomic_load(&n.input.write)
	for i in 0 ..< f do n.input.ring[(w + u64(i)) & (dsp.TAP_FRAMES - 1)] = (in_[0][i] + in_[1][i]) * 0.5
	intrinsics.atomic_store(&n.input.write, w + u64(f))
	pk_in, pk_out: f32
	at := 0
	for e in ctx.events_in {
		to := clamp(int(e.offset), at, f)
		ps_render(n, in_, out, at, to, &pk_in, &pk_out)
		at = to
		ps_event(n, e.payload)
	}
	ps_render(n, in_, out, at, f, &pk_in, &pk_out)
	w = intrinsics.atomic_load(&n.output.write)
	for i in 0 ..< f do n.output.ring[(w + u64(i)) & (dsp.TAP_FRAMES - 1)] = (out[0][i] + out[1][i]) * 0.5
	intrinsics.atomic_store(&n.output.write, w + u64(f))
	if f > 0 {
		intrinsics.atomic_store_explicit(&n.readout[0], transmute(u32)pk_in, .Relaxed)
		intrinsics.atomic_store_explicit(&n.readout[1], transmute(u32)pk_out, .Relaxed)
	}
}

// [rt] Input `ch` (one input: both sides from it; none: silence, the
// output's own buffer zeroed).
@(private = "file")
ps_input :: proc "contextless" (ctx: ^core.Process_Context, ch, f: int) -> []f32 {
	if len(ctx.inputs) == 0 {
		o := ctx.outputs[ch][:f]
		for &x in o do x = 0
		return o
	}
	return ctx.inputs[min(ch, len(ctx.inputs) - 1)][:f]
}

// [rt] A parameter change, into the values.
@(private = "file")
ps_event :: proc "contextless" (n: ^Pro_Saturator, p: core.Event_Payload) {
	id: core.Param_Id
	value: f64
	#partial switch e in p {
	case core.Param_Value: id, value = e.param, e.value
	case core.Param_Ramp:  id, value = e.param, e.target
	case: return
	}
	if int(id) < 1 || int(id) > PS_PARAMS || id == PS_PARAM_QUALITY do return
	info := &pro_saturator_params[id - 1]
	n.values[id] = f32(clamp(value, info.min, info.max))
}

// [rt] Frames `from`..`to`, a chunk at a time.
@(private = "file")
ps_render :: proc "contextless" (n: ^Pro_Saturator, in_, out: [2][]f32, from, to: int, pk_in, pk_out: ^f32) #no_bounds_check {
	if to <= from do return
	v := &n.values
	sr := n.sample_rate
	typ := Pro_Saturator_Type(clamp(int(v[PS_PARAM_TYPE] + 0.5), 0, len(Pro_Saturator_Type) - 1))
	color := v[PS_PARAM_COLOR] >= 0.5
	if color && n.color_for != {v[PS_PARAM_BASE], v[PS_PARAM_FREQ_HZ], v[PS_PARAM_WIDTH], v[PS_PARAM_DEPTH]} {
		n.color_for = {v[PS_PARAM_BASE], v[PS_PARAM_FREQ_HZ], v[PS_PARAM_WIDTH], v[PS_PARAM_DEPTH]}
		n.pre = ps_color_design(v, sr, 1)
		n.post = ps_color_design(v, sr, -1)
	}
	targets := [3]f64{math.pow(10, f64(v[PS_PARAM_DRIVE_DB]) / 20), math.pow(10, f64(v[PS_PARAM_OUTPUT_DB]) / 20), f64(v[PS_PARAM_MIX])}
	shape := Ps_Shape{f64(v[PS_PARAM_WS_DRIVE]), f64(v[PS_PARAM_WS_LIN]), f64(v[PS_PARAM_WS_CURVE]), f64(v[PS_PARAM_WS_DAMP]), f64(v[PS_PARAM_WS_DEPTH]), f64(v[PS_PARAM_WS_PERIOD])}
	if n.frame == 0 && from == 0 do n.glide, n.shape = targets, shape // (before any sound: they jump)
	gc := n.glide_coeff
	factor := 1
	switch n.settings.quality {
	case .Off: factor = 1
	case .X2:  factor = 2
	case .X4:  factor = 4
	}
	// Tape's corner: lower as it is driven (at the curve's rate).
	tape_hz := clamp(18_000 / (1 + max(f64(v[PS_PARAM_DRIVE_DB]), 0) / 6), 2500, 18_000)
	tape_a := 1 - math.exp(-2 * math.PI * tape_hz / (sr * f64(factor)))
	dc_on := v[PS_PARAM_DC] >= 0.5
	soft := v[PS_PARAM_SOFT_CLIP] >= 0.5
	L := len(n.dry[0])
	for at := from; at < to; {
		m := min(to - at, PS_CHUNK)
		// Drive and Color's pre-emphasis, frame by frame (Drive gliding);
		// the dry kept back.
		buf: [2][PS_CHUNK]f32
		drives: [PS_CHUNK]f64
		mixes, outs: [PS_CHUNK]f64
		shapes: [PS_CHUNK]Ps_Shape
		for i in 0 ..< m {
			for &g, k in n.glide {
				g = targets[k] + (g - targets[k]) * gc
				if abs(g - targets[k]) < 1e-9 do g = targets[k]
			}
			s := &n.shape
			s.drive = shape.drive + (s.drive - shape.drive) * gc
			s.lin = shape.lin + (s.lin - shape.lin) * gc
			s.curve = shape.curve + (s.curve - shape.curve) * gc
			s.damp = shape.damp + (s.damp - shape.damp) * gc
			s.depth = shape.depth + (s.depth - shape.depth) * gc
			s.period = shape.period + (s.period - shape.period) * gc
			drives[i], outs[i], mixes[i], shapes[i] = n.glide[0], n.glide[1], n.glide[2], n.shape
			for ch in 0 ..< 2 {
				x := f64(in_[ch][at + i])
				if color {
					x = dsp.svf_tick(&n.pre[0], &n.pre_state[0][ch], x)
					x = dsp.svf_tick(&n.pre[1], &n.pre_state[1][ch], x)
				}
				if ch == 0 && (n.frame + i64(i)) % PS_SIGNAL_EVERY == 0 {
					w := intrinsics.atomic_load(&n.written)
					n.signal[w & (PS_SIGNAL - 1)] = f32(x)
					intrinsics.atomic_store(&n.written, w + 1)
				}
				y := x * drives[i]
				pk_in^ = max(pk_in^, f32(abs(y)))
				buf[ch][i] = f32(y)
			}
		}
		// The curve (and Tape's filter), at the curve's rate.
		for ch in 0 ..< 2 {
			hi := buf[ch][:m]
			if factor > 1 do hi = dsp.oversampler_up(&n.os[ch], buf[ch][:m])
			for &x, j in hi {
				y := ps_curve(typ, f64(x), &shapes[j / factor])
				if typ == .Tape {
					n.tape[ch] += (y - n.tape[ch]) * tape_a
					y = n.tape[ch]
				}
				x = f32(y)
			}
			if factor > 1 do dsp.oversampler_down(&n.os[ch], hi, buf[ch][:m])
		}
		// Color's inverse, DC, Output, Dry/Wet, Soft Clip.
		for i in 0 ..< m {
			for ch in 0 ..< 2 {
				y := f64(buf[ch][i])
				if color {
					y = dsp.svf_tick(&n.post[1], &n.post_state[1][ch], y)
					y = dsp.svf_tick(&n.post[0], &n.post_state[0][ch], y)
				}
				if dc_on {
					d := &n.dc[ch]
					hp := y - d[0] + n.dc_coeff * d[1]
					d[0], d[1] = y, hp
					y = hp
				}
				y *= outs[i]
				n.dry[ch][n.at] = in_[ch][at + i]
				dry := f64(n.dry[ch][(n.at + 1) % L]) if L > 1 else f64(in_[ch][at + i])
				y = dry + (y - dry) * mixes[i]
				if soft {
					a := abs(y)
					if a > 0.8 do y = math.sign(y) * (0.8 + 0.2 * math.tanh((a - 0.8) / 0.2))
				}
				out[ch][at + i] = f32(y)
				pk_out^ = max(pk_out^, f32(abs(y)))
			}
			n.at = (n.at + 1) % L
		}
		n.frame += i64(m)
		at += m
	}
}
