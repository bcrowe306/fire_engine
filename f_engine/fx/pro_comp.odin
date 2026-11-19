package fx

import "base:intrinsics"
import "core:math"
import "core:mem"

import "fire:core"
import "fire:dsp"

// ProComp: a clean compressor as a graph node. Stereo in and out, with an
// optional key (inputs 3 and 4).
//
// Feed-forward and stereo-linked (one gain, from the louder side). It
// detects the peak, the RMS level, or (Expand) the peak for a downward
// expander; its curve is the threshold, the ratio (∞ at the top: a
// limiter, or in Expand a gate) and a quadratic knee. The gain reduction
// moves by its attack and release in dB (Log) or in linear gain (Lin);
// Auto release blends a fast and a slow release by how long it has been
// pressing. Lookahead (`Pro_Comp_Settings`) delays the sound so the
// detector sees it early. Makeup, the output gain and Dry/Wet follow.
//
// The key: its own input mixed with the key (`PC_PARAM_KEY_MIX`, when
// `PC_PARAM_KEYED` says inputs 3 and 4 are wired), its gain, then an EQ.
// Listen puts out what the detector hears.
//
// Every change lands on its exact frame (the continuous ones smoothed
// per frame), so any block size gives the same output.
//
//	node, pc := fx.pro_comp_create({})
//	// graph.set_param(g, id, fx.PC_PARAM_THRESHOLD_DB, -24)

// What ProComp detects.
Pro_Comp_Mode :: enum u8 {Peak, RMS, Expand}

// How long ProComp looks ahead (its latency).
Pro_Comp_Lookahead :: enum u8 {Off, Ms_1, Ms_10}

// The filter on ProComp's key.
Pro_Comp_Eq_Type :: enum u8 {Low_Pass, Band_Pass, High_Pass, Notch, Peak, Low_Shelf, High_Shelf}

// Parameter id of ProComp's threshold: dB, −60..0.
PC_PARAM_THRESHOLD_DB :: core.Param_Id(1)
// Parameter id of ProComp's ratio: 1..100 (100: ∞, a limiter; in Expand, a gate).
PC_PARAM_RATIO :: core.Param_Id(2)
// Parameter id of ProComp's attack: ms, 0.01..1000.
PC_PARAM_ATTACK_MS :: core.Param_Id(3)
// Parameter id of ProComp's release: ms, 1..3000.
PC_PARAM_RELEASE_MS :: core.Param_Id(4)
// Parameter id of ProComp's Auto release: 0 or 1 (on: Release unused).
PC_PARAM_AUTO :: core.Param_Id(5)
// Parameter id of ProComp's knee: dB, 0..18.
PC_PARAM_KNEE_DB :: core.Param_Id(6)
// Parameter id of ProComp's lookahead: a `Pro_Comp_Lookahead`. Read when the
// node is made (`Pro_Comp_Settings.lookahead`): it sets the latency.
PC_PARAM_LOOKAHEAD :: core.Param_Id(7)
// Parameter id of ProComp's mode: a `Pro_Comp_Mode`.
PC_PARAM_MODE :: core.Param_Id(8)
// Parameter id of ProComp's envelope: 0 Lin (in linear gain), 1 Log (in dB).
PC_PARAM_ENV_LOG :: core.Param_Id(9)
// Parameter id of ProComp's Makeup: 0 or 1 (on: up by the reduction at 0 dBFS).
PC_PARAM_MAKEUP :: core.Param_Id(10)
// Parameter id of ProComp's output gain: dB, −36..36.
PC_PARAM_OUTPUT_DB :: core.Param_Id(11)
// Parameter id of ProComp's Dry/Wet: 0..1.
PC_PARAM_MIX :: core.Param_Id(12)
// Parameter id of ProComp's key EQ switch: 0 or 1.
PC_PARAM_EQ_ON :: core.Param_Id(13)
// Parameter id of ProComp's key EQ type: a `Pro_Comp_Eq_Type`.
PC_PARAM_EQ_TYPE :: core.Param_Id(14)
// Parameter id of ProComp's key EQ frequency: Hz, 30..15000.
PC_PARAM_EQ_HZ :: core.Param_Id(15)
// Parameter id of ProComp's key EQ Q: 0.1..12.
PC_PARAM_EQ_Q :: core.Param_Id(16)
// Parameter id of ProComp's key EQ gain (Peak and the shelves): dB, −15..15.
PC_PARAM_EQ_GAIN_DB :: core.Param_Id(17)
// Parameter id of ProComp's key gain: dB, −24..24.
PC_PARAM_KEY_GAIN_DB :: core.Param_Id(18)
// Parameter id of ProComp's key mix: 0 (its own input) .. 1 (the key alone).
PC_PARAM_KEY_MIX :: core.Param_Id(19)
// Parameter id of whether ProComp's key inputs (3 and 4) are wired: 0 or 1
// (the host's to say; off, it detects its own input).
PC_PARAM_KEYED :: core.Param_Id(20)
// Parameter id of ProComp's Listen: 0 or 1 (on: it puts out what its
// detector hears).
PC_PARAM_LISTEN :: core.Param_Id(21)

// Parameter table of the ProComp node, as `node_params` returns it. Read-only.
pro_comp_params := [?]core.Param_Info {
	{id = PC_PARAM_THRESHOLD_DB, name = "Threshold", unit = .Decibels, min = -60, max = 0, default = -18, flags = {.Automatable}},
	{id = PC_PARAM_RATIO, name = "Ratio", unit = .Ratio, min = 1, max = 100, default = 4, flags = {.Automatable}},
	{id = PC_PARAM_ATTACK_MS, name = "Attack", unit = .Milliseconds, min = 0.01, max = 1000, default = 10, flags = {.Automatable}},
	{id = PC_PARAM_RELEASE_MS, name = "Release", unit = .Milliseconds, min = 1, max = 3000, default = 100, flags = {.Automatable}},
	{id = PC_PARAM_AUTO, name = "Auto", min = 0, max = 1, default = 0, flags = {.Automatable, .Stepped}},
	{id = PC_PARAM_KNEE_DB, name = "Knee", unit = .Decibels, min = 0, max = 18, default = 6, flags = {.Automatable}},
	{id = PC_PARAM_LOOKAHEAD, name = "Lookahead", min = 0, max = f64(max(Pro_Comp_Lookahead)), default = 0, flags = {.Stepped}},
	{id = PC_PARAM_MODE, name = "Mode", min = 0, max = f64(max(Pro_Comp_Mode)), default = 0, flags = {.Automatable, .Stepped}},
	{id = PC_PARAM_ENV_LOG, name = "Env", min = 0, max = 1, default = 1, flags = {.Automatable, .Stepped}},
	{id = PC_PARAM_MAKEUP, name = "Makeup", min = 0, max = 1, default = 0, flags = {.Automatable, .Stepped}},
	{id = PC_PARAM_OUTPUT_DB, name = "Output", unit = .Decibels, min = -36, max = 36, default = 0, flags = {.Automatable}},
	{id = PC_PARAM_MIX, name = "Dry/Wet", unit = .Percent, min = 0, max = 1, default = 1, flags = {.Automatable}},
	{id = PC_PARAM_EQ_ON, name = "Key EQ", min = 0, max = 1, default = 0, flags = {.Automatable, .Stepped}},
	{id = PC_PARAM_EQ_TYPE, name = "EQ Type", min = 0, max = f64(max(Pro_Comp_Eq_Type)), default = 1, flags = {.Automatable, .Stepped}},
	{id = PC_PARAM_EQ_HZ, name = "EQ Freq", unit = .Hertz, min = 30, max = 15_000, default = 1000, flags = {.Automatable}},
	{id = PC_PARAM_EQ_Q, name = "EQ Q", min = 0.1, max = 12, default = 0.71, flags = {.Automatable}},
	{id = PC_PARAM_EQ_GAIN_DB, name = "EQ Gain", unit = .Decibels, min = -15, max = 15, default = 0, flags = {.Automatable}},
	{id = PC_PARAM_KEY_GAIN_DB, name = "Key Gain", unit = .Decibels, min = -24, max = 24, default = 0, flags = {.Automatable}},
	{id = PC_PARAM_KEY_MIX, name = "Key Mix", unit = .Percent, min = 0, max = 1, default = 1, flags = {.Automatable}},
	{id = PC_PARAM_KEYED, name = "Keyed", min = 0, max = 1, default = 0, flags = {.Stepped}},
	{id = PC_PARAM_LISTEN, name = "Listen", min = 0, max = 1, default = 0, flags = {.Stepped}},
}

// The number of ProComp parameters (ids 1 to this).
PC_PARAMS :: len(pro_comp_params)

// The ratio at which ProComp's is ∞.
PC_RATIO_INF :: 100

// Settings for `pro_comp_create`.
Pro_Comp_Settings :: struct {
	lookahead: Pro_Comp_Lookahead,
}

// A ProComp's settings, by parameter id (index 0 unused).
Pro_Comp_Values :: [PC_PARAMS + 1]f32

// ProComp's settings at their defaults.
pro_comp_defaults :: proc "contextless" () -> (v: Pro_Comp_Values) {
	for p in pro_comp_params do v[p.id] = f32(p.default)
	return
}

// What a ProComp is doing, for its meters (`pro_comp_readout`).
Pro_Comp_Readout :: struct {
	in_peak:  f32, // the last block's peak in (linear)
	in_rms:   f32, // and its RMS
	level_db: f32, // the detector's loudest in the last block (dB): where the dot sits on the curve
	gr_db:    f32, // the gain reduction then (dB, ≤ 0)
	out_peak: f32, // the last block's peak out (linear)
}

// Frames each entry of ProComp's history covers.
PC_HISTORY_FRAMES :: 256
// Entries ProComp's history keeps (a power of two).
PC_HISTORY :: 1024

// One entry of ProComp's history: over `PC_HISTORY_FRAMES` frames, the
// input's and output's peaks and the deepest gain reduction (dB).
Pro_Comp_Moment :: struct {
	in_db, out_db, gr_db: f32,
}

// The level ProComp's gain reduction stops at (Expand at ∞, a gate).
@(private = "file")
PC_FLOOR_DB :: -80

// A ProComp node's state (from `pro_comp_create`). Fields are internal.
Pro_Comp :: struct {
	settings:    Pro_Comp_Settings,
	values:      Pro_Comp_Values,
	sample_rate: f64,
	late:        int, // the lookahead, in frames
	delay:       [2][]f32, // the sound, waiting out the lookahead
	at:          int,
	frame:       i64,
	rms:         [2]f64, // RMS: each side's power, smoothed
	rms_coeff:   f64,
	env:         f64, // the gain reduction (dB, Log), or the gain (linear, Lin)
	slow:        f64, // Auto: the slow release's reduction (dB)
	coeffs:      [5]f64, // attack, release, Auto's fast and slow releases, the slow stage's attack
	coeffs_for:  [2]f32, // the attack and release they are for
	glide:       [4]f64, // the output gain (linear), Dry/Wet, the key's gain (linear), Makeup's (linear): where they are
	glide_coeff: f64,
	eq:          dsp.Svf_Coeffs,
	eq_for:      [4]f32, // type, freq, Q, gain it is for
	eq_state:    [2]dsp.Svf_State,
	level_db:    f64,
	gr_db:       f64,
	readout:     [5]u32, // atomics: a `Pro_Comp_Readout`'s floats, as bits
	moment:      Pro_Comp_Moment, // the history's entry being gathered (its reduction)
	moment_in:   f32, // and its peaks in and out (linear)
	moment_out:  f32,
	history:     [PC_HISTORY]Pro_Comp_Moment,
	written:     u64, // atomic: entries written so far
	allocator:   mem.Allocator,
}

@(private = "file")
pro_comp_vtable := core.Node_VTable {
	name    = "fire.pro_comp",
	prepare = pro_comp_prepare,
	process = pro_comp_process,
	reset   = proc(self: rawptr) { pro_comp_clear((^Pro_Comp)(self)) },
	release = proc(self: rawptr, allocator: mem.Allocator) {
		n := (^Pro_Comp)(self)
		for &d in n.delay {
			delete(d, allocator)
			d = nil
		}
	},
	params  = proc(self: rawptr) -> []core.Param_Info { return pro_comp_params[:] },
	latency = proc(self: rawptr) -> int { return (^Pro_Comp)(self).late },
	destroy = proc(self: rawptr, allocator: mem.Allocator) { free((^Pro_Comp)(self), allocator) },
}

// Control thread. A ProComp at its defaults (and `settings.lookahead` as
// its Lookahead). Add it with 2 inputs and 2 outputs, or 4 inputs (the
// last two its key: say so with `PC_PARAM_KEYED`) and 2 outputs.
pro_comp_create :: proc(settings: Pro_Comp_Settings, allocator := context.allocator) -> (node: core.Node, pc: ^Pro_Comp) {
	pc = new(Pro_Comp, allocator)
	pc.settings, pc.allocator = settings, allocator
	pc.values = pro_comp_defaults()
	pc.values[PC_PARAM_LOOKAHEAD] = f32(settings.lookahead)
	return core.node_make(&pro_comp_vtable, pc, allocator), pc
}

// Any thread. What ProComp `pc` is doing (as of its last block).
pro_comp_readout :: proc "contextless" (pc: ^Pro_Comp) -> Pro_Comp_Readout {
	r: [5]f32
	for &v, k in r do v = transmute(f32)intrinsics.atomic_load_explicit(&pc.readout[k], .Relaxed)
	return {in_peak = r[0], in_rms = r[1], level_db = r[2], gr_db = r[3], out_peak = r[4]}
}

// Any thread. ProComp `pc`'s last `len(out)` history entries (at most
// `PC_HISTORY`), oldest first (silence before any), and how many it has
// written in all. A reader racing the audio thread may see an entry
// half-written: it is for drawing.
pro_comp_history :: proc "contextless" (pc: ^Pro_Comp, out: []Pro_Comp_Moment) -> u64 {
	n := min(len(out), PC_HISTORY)
	w := intrinsics.atomic_load(&pc.written)
	for i in 0 ..< n {
		k := i64(w) - i64(n) + i64(i)
		out[i] = pc.history[u64(k) & (PC_HISTORY - 1)] if k >= 0 else {PC_FLOOR_DB, PC_FLOOR_DB, 0}
	}
	return w
}

// [rt] ProComp's static curve at settings `v`: what a steady level `in_db`
// comes out at (before makeup and the output gain).
pro_comp_curve :: proc "contextless" (v: ^Pro_Comp_Values, in_db: f32) -> f32 {
	mode := Pro_Comp_Mode(clamp(int(v[PC_PARAM_MODE] + 0.5), 0, len(Pro_Comp_Mode) - 1))
	return f32(pc_curve(mode, f64(in_db), f64(v[PC_PARAM_THRESHOLD_DB]), f64(v[PC_PARAM_RATIO]), f64(v[PC_PARAM_KNEE_DB])))
}

// [rt] The gain Makeup adds at settings `v` (dB): the reduction the curve
// gives a 0 dBFS level, back.
pro_comp_makeup_db :: proc "contextless" (v: ^Pro_Comp_Values) -> f32 {
	mode := Pro_Comp_Mode(clamp(int(v[PC_PARAM_MODE] + 0.5), 0, len(Pro_Comp_Mode) - 1))
	if mode == .Expand do return 0
	return -f32(pc_curve(mode, 0, f64(v[PC_PARAM_THRESHOLD_DB]), f64(v[PC_PARAM_RATIO]), f64(v[PC_PARAM_KNEE_DB])))
}

// The curve: a compressor's (or Expand's) output level for input `x` (dB).
@(private = "file")
pc_curve :: proc "contextless" (mode: Pro_Comp_Mode, x, t, ratio, knee: f64) -> f64 {
	r := clamp(ratio, 1, PC_RATIO_INF)
	w := max(knee, 0)
	d := x - t
	if mode == .Expand {
		// Downward: below the threshold, down by the ratio (∞: to the floor).
		k := r - 1 if r < PC_RATIO_INF else 1e6
		y: f64
		switch {
		case 2 * d >= w:  y = x
		case 2 * d <= -w: y = x + k * (d + w / 2)
		case:             y = x - k * (d - w / 2) * (d - w / 2) / (2 * w)
		}
		return max(y, x + PC_FLOOR_DB)
	}
	s := 1 / r if r < PC_RATIO_INF else 0 // the slope above
	switch {
	case 2 * d <= -w: return x
	case 2 * d >= w:  return t + d * s
	}
	return x + (s - 1) * (d + w / 2) * (d + w / 2) / (2 * w)
}

@(private = "file")
pro_comp_prepare :: proc(self: rawptr, cfg: core.Prepare_Config, allocator: mem.Allocator) -> core.Error {
	n := (^Pro_Comp)(self)
	n.sample_rate = cfg.sample_rate
	ms := [Pro_Comp_Lookahead]f64{.Off = 0, .Ms_1 = 1, .Ms_10 = 10}
	n.late = int(math.round(ms[n.settings.lookahead] * cfg.sample_rate / 1000))
	for &d in n.delay {
		if len(d) >= n.late + 1 do continue
		delete(d, allocator)
		ae: mem.Allocator_Error
		d, ae = make([]f32, n.late + 1, allocator)
		if ae != nil do return .Out_Of_Memory
	}
	n.rms_coeff = math.exp(-1 / (0.010 * cfg.sample_rate))
	n.glide_coeff = math.exp(-1 / (0.010 * cfg.sample_rate))
	pro_comp_clear(n)
	return .None
}

// [rt] Back to silence, the gains where they are going.
@(private = "file")
pro_comp_clear :: proc "contextless" (n: ^Pro_Comp) {
	for d in n.delay do for &x in d do x = 0
	n.at, n.frame = 0, 0
	n.rms, n.eq_state = {}, {}
	n.env = 1 if n.values[PC_PARAM_ENV_LOG] < 0.5 else 0
	n.slow, n.level_db, n.gr_db = 0, PC_FLOOR_DB, 0
	n.glide = {pc_out_gain(n), f64(n.values[PC_PARAM_MIX]), math.pow(10, f64(n.values[PC_PARAM_KEY_GAIN_DB]) / 20), pc_makeup(n)}
	n.coeffs_for, n.eq_for = {-1, -1}, {-1, -1, -1, -1}
	n.moment = {PC_FLOOR_DB, PC_FLOOR_DB, 0}
	n.moment_in, n.moment_out = 0, 0
}

// The output gain (linear).
@(private = "file")
pc_out_gain :: proc "contextless" (n: ^Pro_Comp) -> f64 {
	return math.pow(10, f64(n.values[PC_PARAM_OUTPUT_DB]) / 20)
}

// Makeup's gain (linear; 1 when off), on the compressed signal only.
@(private = "file")
pc_makeup :: proc "contextless" (n: ^Pro_Comp) -> f64 {
	if n.values[PC_PARAM_MAKEUP] < 0.5 do return 1
	return math.pow(10, f64(pro_comp_makeup_db(&n.values)) / 20)
}

@(private = "file")
pro_comp_process :: proc(self: rawptr, ctx: ^core.Process_Context) {
	n := (^Pro_Comp)(self)
	f := ctx.frames
	if len(ctx.outputs) < 2 || f < 0 || len(n.delay[0]) == 0 do return
	in_ := [2][]f32{pc_input(ctx, 0, f), pc_input(ctx, 1, f)}
	key := in_
	if len(ctx.inputs) >= 4 do key = {ctx.inputs[2][:f], ctx.inputs[3][:f]}
	out := [2][]f32{ctx.outputs[0][:f], ctx.outputs[1][:f]}
	// Split at the changes, each on its frame.
	pk_in, sum2, pk_out: f64
	n.level_db = PC_FLOOR_DB
	at := 0
	for e in ctx.events_in {
		to := clamp(int(e.offset), at, f)
		pc_render(n, in_, key, out, at, to, &pk_in, &sum2, &pk_out)
		at = to
		pc_event(n, e.payload)
	}
	pc_render(n, in_, key, out, at, f, &pk_in, &sum2, &pk_out)
	if f > 0 {
		r := [5]f32{f32(pk_in), f32(math.sqrt(sum2 / f64(2 * f))), f32(n.level_db), f32(n.gr_db), f32(pk_out)}
		for v, k in r do intrinsics.atomic_store_explicit(&n.readout[k], transmute(u32)v, .Relaxed)
	}
}

// [rt] Input `ch` (one input: both sides from it; none: silence, the
// output's own buffer zeroed).
@(private = "file")
pc_input :: proc "contextless" (ctx: ^core.Process_Context, ch, f: int) -> []f32 {
	if len(ctx.inputs) == 0 {
		o := ctx.outputs[ch][:f]
		for &x in o do x = 0
		return o
	}
	return ctx.inputs[min(ch, len(ctx.inputs) - 1)][:f]
}

// [rt] A parameter change, into the values.
@(private = "file")
pc_event :: proc "contextless" (n: ^Pro_Comp, p: core.Event_Payload) {
	id: core.Param_Id
	value: f64
	#partial switch e in p {
	case core.Param_Value: id, value = e.param, e.value
	case core.Param_Ramp:  id, value = e.param, e.target
	case: return
	}
	if int(id) < 1 || int(id) > PC_PARAMS || id == PC_PARAM_LOOKAHEAD do return
	info := &pro_comp_params[id - 1]
	was_log := n.values[PC_PARAM_ENV_LOG] >= 0.5
	n.values[id] = f32(clamp(value, info.min, info.max))
	if id == PC_PARAM_ENV_LOG && (n.values[id] >= 0.5) != was_log {
		// The envelope in the other domain, where it was.
		if was_log do n.env = math.pow(10, n.env / 20)
		else do n.env = 20 * math.log10(max(n.env, 1e-6))
	}
}

// [rt] Frames `from`..`to`: detect, follow, apply.
@(private = "file")
pc_render :: proc "contextless" (n: ^Pro_Comp, in_, key, out: [2][]f32, from, to: int, pk_in, sum2, pk_out: ^f64) #no_bounds_check {
	if to <= from do return
	v := &n.values
	sr := n.sample_rate
	// Times (in coefficients), as set.
	if n.coeffs_for != {v[PC_PARAM_ATTACK_MS], v[PC_PARAM_RELEASE_MS]} {
		n.coeffs_for = {v[PC_PARAM_ATTACK_MS], v[PC_PARAM_RELEASE_MS]}
		tc :: proc "contextless" (ms, sr: f64) -> f64 { return math.exp(-1 / max(ms * 0.001 * sr, 1e-3)) }
		n.coeffs = {tc(f64(v[PC_PARAM_ATTACK_MS]), sr), tc(f64(v[PC_PARAM_RELEASE_MS]), sr), tc(60, sr), tc(1500, sr), tc(300, sr)}
	}
	// The key's EQ, as set.
	eq_on := v[PC_PARAM_EQ_ON] >= 0.5
	if eq_on && n.eq_for != {v[PC_PARAM_EQ_TYPE], v[PC_PARAM_EQ_HZ], v[PC_PARAM_EQ_Q], v[PC_PARAM_EQ_GAIN_DB]} {
		n.eq_for = {v[PC_PARAM_EQ_TYPE], v[PC_PARAM_EQ_HZ], v[PC_PARAM_EQ_Q], v[PC_PARAM_EQ_GAIN_DB]}
		modes := [Pro_Comp_Eq_Type]dsp.Filter_Mode{.Low_Pass = .Lowpass, .Band_Pass = .Bandpass, .High_Pass = .Highpass, .Notch = .Notch, .Peak = .Bell, .Low_Shelf = .Low_Shelf, .High_Shelf = .High_Shelf}
		typ := Pro_Comp_Eq_Type(clamp(int(v[PC_PARAM_EQ_TYPE] + 0.5), 0, len(Pro_Comp_Eq_Type) - 1))
		n.eq = dsp.svf_design(modes[typ], f64(v[PC_PARAM_EQ_HZ]), f64(v[PC_PARAM_EQ_Q]), f64(v[PC_PARAM_EQ_GAIN_DB]), sr)
	}
	mode := Pro_Comp_Mode(clamp(int(v[PC_PARAM_MODE] + 0.5), 0, len(Pro_Comp_Mode) - 1))
	t, ratio, knee := f64(v[PC_PARAM_THRESHOLD_DB]), f64(v[PC_PARAM_RATIO]), f64(v[PC_PARAM_KNEE_DB])
	log_env := v[PC_PARAM_ENV_LOG] >= 0.5
	auto := v[PC_PARAM_AUTO] >= 0.5
	keyed := v[PC_PARAM_KEYED] >= 0.5
	key_mix := f64(v[PC_PARAM_KEY_MIX]) if keyed else 0
	listen := v[PC_PARAM_LISTEN] >= 0.5
	targets := [4]f64{pc_out_gain(n), f64(v[PC_PARAM_MIX]), math.pow(10, f64(v[PC_PARAM_KEY_GAIN_DB]) / 20), pc_makeup(n)}
	if n.frame == 0 do n.glide = targets // (before any sound: they jump)
	gc := n.glide_coeff
	a_c, r_c, fast_c, slow_c, hold_c := n.coeffs[0], n.coeffs[1], n.coeffs[2], n.coeffs[3], n.coeffs[4]
	if mode == .Expand {
		// (An expander's attack is its opening, its release its closing:
		// the reduction deepening is its release.)
		a_c, r_c = r_c, a_c
		fast_c = r_c
	}
	L := len(n.delay[0])
	for i in from ..< to {
		for &g, k in n.glide {
			g = targets[k] + (g - targets[k]) * gc
			if abs(g - targets[k]) < 1e-9 do g = targets[k]
		}
		// What the detector hears.
		det: [2]f64
		for ch in 0 ..< 2 {
			x := f64(in_[ch][i])
			d := (x + (f64(key[ch][i]) - x) * key_mix) * n.glide[2]
			if eq_on do d = dsp.svf_tick(&n.eq, &n.eq_state[ch], d)
			det[ch] = d
			pk_in^ = max(pk_in^, abs(x))
			sum2^ += x * x
		}
		level: f64
		if mode == .RMS {
			for ch in 0 ..< 2 do n.rms[ch] = det[ch] * det[ch] + (n.rms[ch] - det[ch] * det[ch]) * n.rms_coeff
			level = math.sqrt(max(n.rms[0], n.rms[1]))
		} else {
			level = max(abs(det[0]), abs(det[1]))
		}
		ldb := 20 * math.log10(max(level, 1e-6))
		target := pc_curve(mode, ldb, t, ratio, knee) - ldb // (≤ 0)
		// Follow it.
		gr: f64
		if log_env {
			if target < n.env {
				n.env = target + (n.env - target) * a_c
			} else if auto {
				n.env = target + (n.env - target) * fast_c
			} else {
				n.env = target + (n.env - target) * r_c
			}
			gr = n.env
			if auto {
				// The slow stage follows the fast one down slowly and back slowly: a long squeeze holds, a click lets go.
				n.slow = n.env + (n.slow - n.env) * (slow_c if n.env > n.slow else hold_c)
				gr = min(n.env, n.slow)
			}
		} else {
			tg := math.pow(10, target / 20)
			c := a_c if tg < n.env else (fast_c if auto else r_c)
			n.env = tg + (n.env - tg) * c
			gr = 20 * math.log10(max(n.env, 1e-6))
			if auto {
				n.slow = gr + (n.slow - gr) * (slow_c if gr > n.slow else hold_c)
				gr = min(gr, n.slow)
			}
		}
		gr = max(gr, PC_FLOOR_DB)
		n.level_db, n.gr_db = max(n.level_db, ldb), gr
		g := math.pow(10, gr / 20)
		// The sound, out of its lookahead, through the gain.
		mix := n.glide[1]
		for ch in 0 ..< 2 {
			n.delay[ch][n.at] = in_[ch][i]
			dry := f64(n.delay[ch][(n.at + 1) % L]) if L > 1 else f64(in_[ch][i])
			y := (dry * g * n.glide[3] * mix + dry * (1 - mix)) * n.glide[0]
			if listen do y = det[ch]
			out[ch][i] = f32(y)
			pk_out^ = max(pk_out^, abs(y))
		}
		n.at = (n.at + 1) % L
		// The history.
		n.moment_in = max(n.moment_in, abs(in_[0][i]), abs(in_[1][i]))
		n.moment_out = max(n.moment_out, abs(out[0][i]), abs(out[1][i]))
		n.moment.gr_db = min(n.moment.gr_db, f32(gr))
		n.frame += 1
		if n.frame % PC_HISTORY_FRAMES == 0 {
			w := intrinsics.atomic_load(&n.written)
			n.moment.in_db = f32(20 * math.log10(max(f64(n.moment_in), 1e-4)))
			n.moment.out_db = f32(20 * math.log10(max(f64(n.moment_out), 1e-4)))
			n.history[w & (PC_HISTORY - 1)] = n.moment
			n.moment_in, n.moment_out = 0, 0
			intrinsics.atomic_store(&n.written, w + 1)
			n.moment = {PC_FLOOR_DB, PC_FLOOR_DB, 0}
		}
	}
}
