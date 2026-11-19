package fx

import "base:intrinsics"
import "base:runtime"
import "core:math"
import "core:mem"
import "core:strings"

import "fire:core"
import "fire:dsp"

// ProEq: an eight-band parametric EQ as a graph node. Stereo in and out.
//
// Each band is a low or high cut (12 to 96 dB an octave), a shelf, a
// bell, a notch, a band-pass or a tilt. Every band is designed to match
// its analog shape up to Nyquist (no cramping: a bell at 16 kHz keeps its
// width), then run as state-variable filters, which stay well behaved
// while their settings move. There is no latency, unless the node is made
// with `oversample` (2×, `Pro_Eq_Settings`).
//
// Two sets of bands, A and B: in Stereo, A filters both sides; in L/R, A
// the left and B the right; in M/S, A the mid and B the side.
//
// Settings move on a 16-frame grid counted from the last reset (smoothed
// between), so the output is the same whatever the blocks.
//
//	node, eq := fx.pro_eq_create({})
//	// graph.set_param(g, id, fx.pro_eq_band_param(0, 2, .Gain_Db), 6)

// The shape of a ProEq band.
Pro_Eq_Type :: enum u8 {
	Low_Cut,    // a high-pass; Slope says how steep
	Low_Shelf,  // Gain below Freq
	Bell,       // Gain around Freq, Q its width
	Notch,      // nothing at Freq, Q its width
	High_Shelf, // Gain above Freq
	High_Cut,   // a low-pass; Slope says how steep
	Band_Pass,  // only around Freq (0 dB at its peak)
	Tilt,       // Gain/2 above Freq, −Gain/2 below (first order)
}

// How steep a ProEq cut is, in dB an octave.
Pro_Eq_Slope :: enum u8 {S12, S24, S36, S48, S96}

// What ProEq's two sets of bands filter.
Pro_Eq_Mode :: enum u8 {
	Stereo,     // A both sides (B unused)
	Left_Right, // A the left, B the right
	Mid_Side,   // A the mid, B the side
}

// A ProEq band's settings, in `pro_eq_band_param` order.
Pro_Eq_Field :: enum u8 {
	On,      // 0 or 1
	Type,    // a `Pro_Eq_Type`
	Slope,   // a `Pro_Eq_Slope` (cuts only)
	Freq_Hz, // 10..22000
	Gain_Db, // −15..15 (shelves, bells, tilt)
	Q,       // 0.1..18
}

// Bands in each of ProEq's sets.
PE_BANDS :: 8
// ProEq's sets of bands (A and B).
PE_SETS :: 2

// Parameter id of ProEq's mode: a `Pro_Eq_Mode`.
PE_PARAM_MODE :: core.Param_Id(1)
// Parameter id of ProEq's Adaptive Q: 0 or 1 (on: a bell narrows as its gain grows).
PE_PARAM_ADAPTIVE_Q :: core.Param_Id(2)
// Parameter id of ProEq's Scale: −2..2, every shelf's, bell's and tilt's gain multiplied by it.
PE_PARAM_SCALE :: core.Param_Id(3)
// Parameter id of ProEq's output gain: dB, −24..24.
PE_PARAM_GAIN_DB :: core.Param_Id(4)
// Parameter id of ProEq's oversampling: 0 or 1. Read when the node is
// made (`Pro_Eq_Settings.oversample`): it sets the node's latency, which a
// graph reads only as it builds, so a change means a new node.
PE_PARAM_OVERSAMPLE :: core.Param_Id(5)

@(private = "file")
PE_FIRST_BAND :: 6

// [rt] The parameter id of set `set`'s (0: A, 1: B) band `band`'s (0..7)
// `field`: 6 + 48 × set + 6 × band + field.
pro_eq_band_param :: proc "contextless" (set, band: int, field: Pro_Eq_Field) -> core.Param_Id {
	return core.Param_Id(PE_FIRST_BAND + 6 * PE_BANDS * set + 6 * band + int(field))
}

// The number of ProEq parameters (ids 1 to this).
PE_PARAMS :: PE_FIRST_BAND - 1 + PE_SETS * PE_BANDS * len(Pro_Eq_Field)

// Parameter table of the ProEq node, as `node_params` returns it, by id
// (id k at index k − 1). Read-only.
pro_eq_params: [PE_PARAMS]core.Param_Info

// Each band's default type and frequency: a low cut (off), a low shelf,
// four bells, a high shelf, a high cut (off).
@(private = "file")
PE_DEFAULT_TYPE := [PE_BANDS]Pro_Eq_Type{.Low_Cut, .Low_Shelf, .Bell, .Bell, .Bell, .Bell, .High_Shelf, .High_Cut}
@(private = "file")
PE_DEFAULT_HZ := [PE_BANDS]f64{30, 100, 240, 580, 1400, 3300, 8000, 18_000}

@(init, private = "file")
pro_eq_init_params :: proc "contextless" () {
	context = runtime.default_context()
	g := &pro_eq_params
	g[0] = {id = PE_PARAM_MODE, name = "Mode", min = 0, max = f64(max(Pro_Eq_Mode)), default = 0, flags = {.Automatable, .Stepped}}
	g[1] = {id = PE_PARAM_ADAPTIVE_Q, name = "Adaptive Q", min = 0, max = 1, default = 1, flags = {.Automatable, .Stepped}}
	g[2] = {id = PE_PARAM_SCALE, name = "Scale", unit = .Percent, min = -2, max = 2, default = 1, flags = {.Automatable}}
	g[3] = {id = PE_PARAM_GAIN_DB, name = "Gain", unit = .Decibels, min = -24, max = 24, default = 0, flags = {.Automatable}}
	g[4] = {id = PE_PARAM_OVERSAMPLE, name = "Oversampling", min = 0, max = 1, default = 0, flags = {.Stepped}}
	FIELD_NAMES := [Pro_Eq_Field]string{.On = "On", .Type = "Type", .Slope = "Slope", .Freq_Hz = "Freq", .Gain_Db = "Gain", .Q = "Q"}
	DIGITS := [PE_BANDS]string{"1", "2", "3", "4", "5", "6", "7", "8"}
	for set in 0 ..< PE_SETS do for band in 0 ..< PE_BANDS do for f in Pro_Eq_Field {
		id := pro_eq_band_param(set, band, f)
		p := core.Param_Info{id = id, flags = {.Automatable}}
		switch f {
		case .On:      p.max, p.default, p.flags = 1, 0 if band == 0 || band == PE_BANDS - 1 else 1, {.Automatable, .Stepped}
		case .Type:    p.max, p.default, p.flags = f64(max(Pro_Eq_Type)), f64(PE_DEFAULT_TYPE[band]), {.Automatable, .Stepped}
		case .Slope:   p.max, p.default, p.flags = f64(max(Pro_Eq_Slope)), 0, {.Automatable, .Stepped}
		case .Freq_Hz: p.unit, p.min, p.max, p.default = .Hertz, 10, 22_000, PE_DEFAULT_HZ[band]
		case .Gain_Db: p.unit, p.min, p.max = .Decibels, -15, 15
		case .Q:       p.min, p.max, p.default = 0.1, 18, 0.71
		}
		p.name = strings.concatenate({DIGITS[band], " ", FIELD_NAMES[f], " A" if set == 0 else " B"})
		g[id - 1] = p
	}
}

// Settings for `pro_eq_create`.
Pro_Eq_Settings :: struct {
	oversample: bool, // 2×: steep high bands and boosts near Nyquist cleaner, `oversampler_latency` frames late, about twice the work
}

// A ProEq's settings, by parameter id (index 0 unused).
Pro_Eq_Values :: [PE_PARAMS + 1]f32

// ProEq's settings at their defaults.
pro_eq_defaults :: proc "contextless" () -> (v: Pro_Eq_Values) {
	for p in pro_eq_params do v[p.id] = f32(p.default)
	return
}

// What a ProEq is doing, for its meters (`pro_eq_readout`).
Pro_Eq_Readout :: struct {
	in_peak:  f32, // the last block's peak in (linear)
	out_peak: f32, // and out
}

// The most second-order sections a band runs (a 96 dB cut).
@(private = "file")
PE_SECTIONS :: 8

// The frames settings move on (see the package comment).
@(private = "file")
PE_GRID :: 16

// One second-order section, as a state-variable filter (g, k) whose
// high-, band- and low-pass outputs are mixed (c2, c1, c0).
@(private = "file")
Pe_Section :: struct {
	a1, a2, a3: f64,
	k:          f64,
	c0, c1, c2: f64,
}

// One channel's state of a section.
@(private = "file")
Pe_State :: struct {
	ic1, ic2: f64,
}

// A band's design: its sections, and the biquads they came from (for
// drawing its response).
@(private = "file")
Pe_Design :: struct {
	n:      int,
	bq:     [PE_SECTIONS]dsp.Biquad_Coeffs,
	svf:    [PE_SECTIONS]Pe_Section,
	active: bool, // on and not flat
}

// A band as it moves: its smoothed settings (Freq and Q in octaves).
@(private = "file")
Pe_Band :: struct {
	freq_oct, gain_db, q_oct: f64,
	kind:                     [4]f32, // on, type, slope, adaptive Q: what the design was made for
	design:                   Pe_Design,
	state:                    [PE_SECTIONS][2]Pe_State,
	was_active:               bool,
}

// A ProEq node's state (from `pro_eq_create`). Fields are internal.
Pro_Eq :: struct {
	settings:    Pro_Eq_Settings,
	values:      Pro_Eq_Values,
	sample_rate: f64, // the rate the bands run at (twice the graph's when oversampling)
	alpha:       f64, // smoothing per grid step
	frame:       i64, // frames since the last reset
	bands:       [PE_SETS][PE_BANDS]Pe_Band,
	scale:       f64,
	out_db:      f64,
	gain_from:   f64, // the output gain (linear) at the last grid point but one, and at the last
	gain_to:     f64,
	mode:        Pro_Eq_Mode,
	settled:     bool, // past the first grid point since the reset (before it, settings jump)
	audition:    i32, // atomic: set × 8 + band, or −1
	heard:       i32, // the band the audition filter is designed for (−1: none)
	hear:        Pe_Design,
	hear_state:  [PE_SECTIONS][2]Pe_State,
	os:          [2]dsp.Oversampler,
	work:        [2][2 * PE_GRID]f64,
	readout:     [2]u32, // atomics: in and out peaks, as bits
	input:       dsp.Tap, // what came in (the sides averaged), for its spectrum (`pro_eq_read_input`)
	allocator:   mem.Allocator,
}

@(private = "file")
pro_eq_vtable := core.Node_VTable {
	name    = "fire.pro_eq",
	prepare = pro_eq_prepare,
	process = pro_eq_process,
	reset   = proc(self: rawptr) { pro_eq_clear((^Pro_Eq)(self)) },
	params  = proc(self: rawptr) -> []core.Param_Info { return pro_eq_params[:] },
	latency = proc(self: rawptr) -> int {
		n := (^Pro_Eq)(self)
		return dsp.oversampler_latency(&n.os[0]) if n.settings.oversample else 0
	},
	destroy = proc(self: rawptr, allocator: mem.Allocator) {
		n := (^Pro_Eq)(self)
		if n.settings.oversample do for &o in n.os do dsp.oversampler_destroy(&o, n.allocator)
		free(n, allocator)
	},
}

// Control thread. A ProEq at its defaults (and `settings.oversample` as
// its Oversampling). Add it to a graph with 2 inputs and 2 outputs (1
// input: both sides from it).
pro_eq_create :: proc(settings: Pro_Eq_Settings, allocator := context.allocator) -> (node: core.Node, eq: ^Pro_Eq, err: core.Error) {
	eq = new(Pro_Eq, allocator)
	eq.settings, eq.allocator = settings, allocator
	eq.values = pro_eq_defaults()
	eq.values[PE_PARAM_OVERSAMPLE] = 1 if settings.oversample else 0
	eq.audition, eq.heard = -1, -1
	if settings.oversample {
		for &o in eq.os {
			if e := dsp.oversampler_init(&o, 2, PE_GRID, allocator); e != .None {
				for &p in eq.os do dsp.oversampler_destroy(&p, allocator)
				free(eq, allocator)
				return {}, nil, e
			}
		}
	}
	return core.node_make(&pro_eq_vtable, eq, allocator), eq, .None
}

// Any thread. What ProEq `eq` is doing (as of its last block).
pro_eq_readout :: proc "contextless" (eq: ^Pro_Eq) -> Pro_Eq_Readout {
	r: [2]f32
	for &v, k in r do v = transmute(f32)intrinsics.atomic_load_explicit(&eq.readout[k], .Relaxed)
	return {in_peak = r[0], out_peak = r[1]}
}

// Any thread. Auditions set `set`'s band `band` of ProEq `eq`: the output
// is only what the band touches (a band-pass at its Freq and Q; at a cut's
// corner, a shelf's middle) until it is called with `band` −1.
pro_eq_audition :: proc "contextless" (eq: ^Pro_Eq, set, band: int) {
	v: i32 = -1
	if band >= 0 && band < PE_BANDS && set >= 0 && set < PE_SETS do v = i32(set * PE_BANDS + band)
	intrinsics.atomic_store_explicit(&eq.audition, v, .Relaxed)
}

// Any thread. The band ProEq `eq` is auditioning (`pro_eq_audition`), or
// −1 for none.
pro_eq_auditioning :: proc "contextless" (eq: ^Pro_Eq) -> (set, band: int) {
	v := intrinsics.atomic_load_explicit(&eq.audition, .Relaxed)
	if v < 0 do return -1, -1
	return int(v) / PE_BANDS, int(v) % PE_BANDS
}

// Any thread. The last `len(out)` frames ProEq `eq` took in (the sides
// averaged, at most `dsp.TAP_FRAMES`), oldest first, for a spectrum of its
// input; as `dsp.tap_read`.
pro_eq_read_input :: proc "contextless" (eq: ^Pro_Eq, out: []f32) -> u64 {
	return dsp.tap_read(&eq.input, out)
}

// Control thread. Set `set`'s response at settings `v`, in dB, at each
// frequency of `hz` into `out_db` (as long as `hz`): every band on (Scale
// and Adaptive Q as `v` says, the output gain left out), or band `band`
// alone. As the node runs it at `sample_rate` (doubled when `v` says
// oversampling).
pro_eq_curve :: proc(v: ^Pro_Eq_Values, set: int, sample_rate: f64, hz: []f32, out_db: []f32, band := -1) {
	sr := sample_rate * (2 if v[PE_PARAM_OVERSAMPLE] >= 0.5 else 1)
	designs: [PE_BANDS]Pe_Design
	for &d, b in designs {
		if band >= 0 && b != band do continue
		f := pe_fields(v, set, b)
		pe_design(&d, f.on, f.type, f.slope, f.freq, f.gain * f64(v[PE_PARAM_SCALE]), f.q, v[PE_PARAM_ADAPTIVE_Q] >= 0.5, sr)
	}
	for f, i in hz {
		if i >= len(out_db) do break
		w := 2 * math.PI * f64(f) / sr
		z1 := complex(math.cos(w), -math.sin(w))
		z2 := z1 * z1
		g := 1.0
		for &d in designs do if d.active {
			for c in d.bq[:d.n] {
				h := (complex(c.b0, 0) + complex(c.b1, 0) * z1 + complex(c.b2, 0) * z2) / (1 + complex(c.a1, 0) * z1 + complex(c.a2, 0) * z2)
				g *= abs(h)
			}
		}
		out_db[i] = f32(20 * math.log10(max(g, 1e-9)))
	}
}

// A band's settings, read from values.
@(private = "file")
Pe_Fields :: struct {
	on:                bool,
	type:              Pro_Eq_Type,
	slope:             Pro_Eq_Slope,
	freq, gain, q:     f64,
}

@(private = "file")
pe_fields :: proc "contextless" (v: ^Pro_Eq_Values, set, band: int) -> Pe_Fields {
	at :: #force_inline proc "contextless" (v: ^Pro_Eq_Values, set, band: int, f: Pro_Eq_Field) -> f32 { return v[pro_eq_band_param(set, band, f)] }
	return {
		on    = at(v, set, band, .On) >= 0.5,
		type  = Pro_Eq_Type(clamp(int(at(v, set, band, .Type) + 0.5), 0, len(Pro_Eq_Type) - 1)),
		slope = Pro_Eq_Slope(clamp(int(at(v, set, band, .Slope) + 0.5), 0, len(Pro_Eq_Slope) - 1)),
		freq  = f64(clamp(at(v, set, band, .Freq_Hz), 10, 22_000)),
		gain  = f64(clamp(at(v, set, band, .Gain_Db), -15, 15)),
		q     = f64(clamp(at(v, set, band, .Q), 0.1, 18)),
	}
}

@(private = "file")
pro_eq_prepare :: proc(self: rawptr, cfg: core.Prepare_Config, allocator: mem.Allocator) -> core.Error {
	n := (^Pro_Eq)(self)
	n.sample_rate = cfg.sample_rate * (2 if n.settings.oversample else 1)
	n.alpha = 1 - math.exp(-f64(PE_GRID) / (0.012 * cfg.sample_rate)) // (12 ms)
	pro_eq_clear(n)
	return .None
}

// [rt] Back to silence, the settings where they are going.
@(private = "file")
pro_eq_clear :: proc "contextless" (n: ^Pro_Eq) {
	n.frame, n.settled = 0, false
	for &set in n.bands do for &b in set {
		b.state = {}
		b.kind = {-1, -1, -1, -1} // (designed afresh at the first grid point)
	}
	n.hear_state, n.heard = {}, -1
	if n.settings.oversample do for &o in n.os do dsp.oversampler_reset(&o)
}

@(private = "file")
pro_eq_process :: proc(self: rawptr, ctx: ^core.Process_Context) {
	n := (^Pro_Eq)(self)
	f := ctx.frames
	if len(ctx.outputs) < 2 || f < 0 do return
	in_l, in_r := pe_input(ctx, 0, f), pe_input(ctx, 1, f)
	out := [2][]f32{ctx.outputs[0][:f], ctx.outputs[1][:f]}
	w := intrinsics.atomic_load(&n.input.write)
	for i in 0 ..< f do n.input.ring[(w + u64(i)) & (dsp.TAP_FRAMES - 1)] = (in_l[i] + in_r[i]) * 0.5
	intrinsics.atomic_store(&n.input.write, w + u64(f))
	evs := ctx.events_in
	next_ev := 0
	peak_in, peak_out: f32
	for at := 0; at < f; {
		frame := n.frame + i64(at)
		pos := int(frame % PE_GRID)
		if pos == 0 {
			for next_ev < len(evs) && int(evs[next_ev].offset) <= at {
				pe_event(n, evs[next_ev].payload)
				next_ev += 1
			}
			pe_step(n)
		}
		m := min(f - at, PE_GRID - pos)
		for i in at ..< at + m do peak_in = max(peak_in, abs(in_l[i]), abs(in_r[i]))
		pe_chunk(n, {in_l[at:at + m], in_r[at:at + m]}, {out[0][at:at + m], out[1][at:at + m]}, pos)
		for i in at ..< at + m do peak_out = max(peak_out, abs(out[0][i]), abs(out[1][i]))
		at += m
	}
	for next_ev < len(evs) { // (due at the next grid point, in a later block)
		pe_event(n, evs[next_ev].payload)
		next_ev += 1
	}
	n.frame += i64(f)
	if f > 0 {
		intrinsics.atomic_store_explicit(&n.readout[0], transmute(u32)peak_in, .Relaxed)
		intrinsics.atomic_store_explicit(&n.readout[1], transmute(u32)peak_out, .Relaxed)
	}
}

// [rt] Input `ch` (one input: both sides from it; none: silence, the
// output's own buffer zeroed).
@(private = "file")
pe_input :: proc "contextless" (ctx: ^core.Process_Context, ch, f: int) -> []f32 {
	if len(ctx.inputs) == 0 {
		o := ctx.outputs[ch][:f]
		for &x in o do x = 0
		return o
	}
	return ctx.inputs[min(ch, len(ctx.inputs) - 1)][:f]
}

// [rt] A parameter change, into the values (read at the next grid point).
@(private = "file")
pe_event :: proc "contextless" (n: ^Pro_Eq, p: core.Event_Payload) {
	id: core.Param_Id
	value: f64
	#partial switch e in p {
	case core.Param_Value: id, value = e.param, e.value
	case core.Param_Ramp:  id, value = e.param, e.target
	case: return
	}
	if int(id) < 1 || int(id) > PE_PARAMS || id == PE_PARAM_OVERSAMPLE do return
	info := &pro_eq_params[id - 1]
	n.values[id] = f32(clamp(value, info.min, info.max))
}

// [rt] One grid point: the smoothed settings a step on (or there, before
// the first), each band designed again where it changed.
@(private = "file")
pe_step :: proc "contextless" (n: ^Pro_Eq) {
	v := &n.values
	a := n.alpha if n.settled else 1
	glide :: #force_inline proc "contextless" (x: ^f64, to, a, snap: f64) -> bool {
		if x^ == to do return false
		x^ += (to - x^) * a
		if abs(to - x^) < snap do x^ = to
		return true
	}
	n.mode = Pro_Eq_Mode(clamp(int(v[PE_PARAM_MODE] + 0.5), 0, len(Pro_Eq_Mode) - 1))
	scale_moved := glide(&n.scale, f64(v[PE_PARAM_SCALE]), a, 1e-4)
	glide(&n.out_db, f64(v[PE_PARAM_GAIN_DB]), a, 1e-3)
	n.gain_from = n.gain_to if n.settled else math.pow(10, n.out_db / 20)
	n.gain_to = math.pow(10, n.out_db / 20)
	adaptive := v[PE_PARAM_ADAPTIVE_Q] >= 0.5
	sets := 1 if n.mode == .Stereo else 2
	if sets == 1 do for &b in n.bands[1] do b.kind = {-1, -1, -1, -1} // (unused: back, it starts where it is set, clean)
	for s in 0 ..< sets do for &b, k in n.bands[s] {
		f := pe_fields(v, s, k)
		kind := [4]f32{f32(int(f.on)), f32(f.type), f32(f.slope), f32(int(adaptive))}
		ba := a if b.kind[0] >= 0 else 1
		if b.kind[0] < 0 do b.state = {}
		moved := glide(&b.freq_oct, math.log2(f.freq), ba, 5e-4)
		moved |= glide(&b.gain_db, f.gain, ba, 1e-3)
		moved |= glide(&b.q_oct, math.log2(f.q), ba, 5e-4)
		if !moved && !scale_moved && kind == b.kind do continue
		if kind != b.kind && b.kind[2] != kind[2] do b.state = {} // (a new number of sections: they start clean)
		b.kind = kind
		pe_design(&b.design, f.on, f.type, f.slope, pe_exp2(b.freq_oct), b.gain_db * n.scale, pe_exp2(b.q_oct), adaptive, n.sample_rate)
		if b.design.active && !b.was_active do b.state = {} // (coming back: clean)
		b.was_active = b.design.active
	}
	// The audition: a band-pass where the band is.
	h := intrinsics.atomic_load_explicit(&n.audition, .Relaxed)
	if h >= 0 {
		s, k := int(h) / PE_BANDS, int(h) % PE_BANDS
		b := &n.bands[min(s, sets - 1)][k]
		if h != n.heard do n.hear_state = {}
		f := pe_fields(v, s, k)
		q := pe_exp2(b.q_oct)
		#partial switch f.type {
		case .Low_Cut, .High_Cut, .Low_Shelf, .High_Shelf, .Tilt: q = 0.71
		}
		pe_design(&n.hear, true, .Band_Pass, .S12, pe_exp2(b.freq_oct), 0, max(q, 0.3), false, n.sample_rate)
	}
	n.heard = h
	n.settled = true
}

// [rt] Up to a grid step of frames, `pos` frames past its grid point.
@(private = "file")
pe_chunk :: proc "contextless" (n: ^Pro_Eq, in_: [2][]f32, out: [2][]f32, pos: int) #no_bounds_check {
	m := len(in_[0])
	if m == 0 do return
	ms := n.mode == .Mid_Side
	up := 2 if n.settings.oversample else 1
	// Into the work buffers (encoded for M/S; raised for oversampling).
	tmp: [2][PE_GRID]f32
	for i in 0 ..< m {
		l, r := in_[0][i], in_[1][i]
		if ms do l, r = (l + r) * 0.5, (l - r) * 0.5
		tmp[0][i], tmp[1][i] = l, r
	}
	for ch in 0 ..< 2 {
		w := &n.work[ch]
		if up == 2 {
			hi := dsp.oversampler_up(&n.os[ch], tmp[ch][:m])
			for x, i in hi do w[i] = f64(x)
		} else {
			for i in 0 ..< m do w[i] = f64(tmp[ch][i])
		}
	}
	frames := m * up
	if n.heard >= 0 {
		for ch in 0 ..< 2 do pe_run(&n.hear, &n.hear_state, ch, n.work[ch][:frames])
	} else {
		for &b in n.bands[0] do if b.design.active {
			pe_run(&b.design, &b.state, 0, n.work[0][:frames])
			if n.mode == .Stereo do pe_run(&b.design, &b.state, 1, n.work[1][:frames])
		}
		if n.mode != .Stereo do for &b in n.bands[1] do if b.design.active do pe_run(&b.design, &b.state, 1, n.work[1][:frames])
	}
	// Back down, decoded, through the output gain.
	for ch in 0 ..< 2 {
		w := &n.work[ch]
		if up == 2 {
			hi: [2 * PE_GRID]f32
			for i in 0 ..< frames do hi[i] = f32(w[i])
			dsp.oversampler_down(&n.os[ch], hi[:frames], tmp[ch][:m])
		} else {
			for i in 0 ..< m do tmp[ch][i] = f32(w[i])
		}
	}
	d := n.gain_to - n.gain_from
	for i in 0 ..< m {
		l, r := tmp[0][i], tmp[1][i]
		if ms do l, r = l + r, l - r
		g := f32(n.gain_from + d * f64(pos + i + 1) / PE_GRID)
		out[0][i], out[1][i] = l * g, r * g
	}
}

// [rt] Runs design `d`'s sections over channel `ch`'s work buffer.
@(private = "file")
pe_run :: proc "contextless" (d: ^Pe_Design, state: ^[PE_SECTIONS][2]Pe_State, ch: int, buf: []f64) #no_bounds_check {
	for k in 0 ..< d.n {
		c := d.svf[k]
		st := state[k][ch]
		for &x in buf {
			v3 := x - st.ic2
			v1 := c.a1 * st.ic1 + c.a2 * v3
			v2 := st.ic2 + c.a2 * st.ic1 + c.a3 * v3
			st.ic1 = 2 * v1 - st.ic1
			st.ic2 = 2 * v2 - st.ic2
			x = c.c2 * (x - c.k * v1 - v2) + c.c1 * v1 + c.c0 * v2
		}
		state[k][ch] = st
	}
}

// [rt] Designs a band: its sections at `sample_rate`, each matching its
// analog shape's magnitude at DC, at Nyquist and at the band's frequency
// (Vicanek's matched second-order design), then turned into a
// state-variable filter. Flat (a gain shape at 0 dB) or off: not active.
@(private = "file")
pe_design :: proc "contextless" (d: ^Pe_Design, on: bool, type: Pro_Eq_Type, slope: Pro_Eq_Slope, freq, gain_db, q: f64, adaptive: bool, sample_rate: f64) {
	d.n, d.active = 0, false
	if !on do return
	#partial switch type {
	case .Low_Shelf, .Bell, .High_Shelf, .Tilt: if abs(gain_db) < 1e-6 do return
	}
	w0 := 2 * math.PI * min(freq, 0.49 * sample_rate) / sample_rate
	add :: proc "contextless" (d: ^Pe_Design, bq: dsp.Biquad_Coeffs) {
		d.bq[d.n] = bq
		d.svf[d.n] = pe_svf(bq)
		d.n += 1
	}
	A := math.pow(10, gain_db / 40)
	switch type {
	case .Low_Cut, .High_Cut:
		sections := [Pro_Eq_Slope]int{.S12 = 1, .S24 = 2, .S36 = 3, .S48 = 4, .S96 = 8}
		ns := sections[slope]
		order := 2 * ns
		for k in 1 ..= ns {
			qk := 1 / (2 * math.sin(math.PI * f64(2 * k - 1) / f64(2 * order))) // Butterworth
			if k == 1 do qk *= q / math.SQRT_TWO * 2 // (the steepest section carries the band's Q: 0.71 flat)
			if type == .Low_Cut do add(d, pe_matched(1, 0, 0, w0, qk, w0))
			else do add(d, pe_matched(0, 0, w0 * w0, w0, qk, w0))
		}
	case .Bell:
		qq := q
		if adaptive do qq *= 1 + abs(gain_db) / 24
		add(d, pe_matched(1, A * w0 / qq, w0 * w0, w0, A * qq, w0))
	case .Notch:     add(d, pe_matched(1, 0, w0 * w0, w0, q, w0))
	case .Band_Pass: add(d, pe_matched(0, w0 / q, 0, w0, q, w0))
	case .Low_Shelf:
		sa := math.sqrt(A)
		add(d, pe_matched(1, sa * w0 / q, A * w0 * w0, w0 / sa, q, w0))
	case .High_Shelf:
		sa := math.sqrt(A)
		add(d, pe_matched(A * A, A * sa * w0 / q, A * w0 * w0, w0 * sa, q, w0))
	case .Tilt:
		add(d, pe_tilt(A, w0))
	}
	d.active = d.n > 0
}

// [rt] The analog section (n2 s² + n1 s + n0) / (s² + (wp/Qp) s + wp²)
// (s in radians a sample) as a digital biquad: its poles matched (the
// analog poles' impulse response), its magnitude matched at DC, Nyquist
// and `wm`.
@(private = "file")
pe_matched :: proc "contextless" (n2, n1, n0, wp, qp, wm: f64) -> dsp.Biquad_Coeffs {
	mag2 :: #force_inline proc "contextless" (n2, n1, n0, wp, qp, w: f64) -> f64 {
		nr, ni := n0 - n2 * w * w, n1 * w
		dr, di := wp * wp - w * w, wp * w / qp
		return (nr * nr + ni * ni) / max(dr * dr + di * di, 1e-300)
	}
	// The poles.
	p := min(wp, 0.98 * math.PI)
	zeta := 1 / (2 * qp)
	a1, a2: f64
	e := math.exp(-zeta * p)
	if zeta <= 1 do a1 = -2 * e * math.cos(p * math.sqrt(1 - zeta * zeta))
	else do a1 = -2 * e * math.cosh(p * math.sqrt(zeta * zeta - 1))
	a2 = e * e
	// The zeros, by magnitude: |B|² = B0 φ0 + B1 φ1 + B2 φ2.
	A0, A1, A2 := (1 + a1 + a2) * (1 + a1 + a2), (1 - a1 + a2) * (1 - a1 + a2), -4 * a2
	B0 := mag2(n2, n1, n0, wp, qp, 0) * A0
	B1 := mag2(n2, n1, n0, wp, qp, math.PI) * A1
	m := clamp(wm, 1e-4, 0.9 * math.PI)
	s := math.sin(m / 2)
	f1 := s * s
	f0 := 1 - f1
	f2 := 4 * f0 * f1
	B2 := (mag2(n2, n1, n0, wp, qp, m) * (A0 * f0 + A1 * f1 + A2 * f2) - B0 * f0 - B1 * f1) / f2
	r0, r1 := math.sqrt(B0), math.sqrt(B1)
	W := 0.5 * (r0 + r1)
	b0 := 0.5 * (W + math.sqrt(max(W * W + B2, 0)))
	b1 := 0.5 * (r0 - r1)
	b2 := -B2 / (4 * b0) if b0 > 1e-300 else 0
	return {b0, b1, b2, a1, a2}
}

// [rt] A first-order tilt through `w0` (A² = its gain): (A s + w0) /
// (s + A w0), its pole matched, its magnitude at DC and Nyquist.
@(private = "file")
pe_tilt :: proc "contextless" (A, w0: f64) -> dsp.Biquad_Coeffs {
	p := math.exp(-A * w0)
	wn := math.PI
	hn := math.sqrt((A * A * wn * wn + w0 * w0) / (wn * wn + A * A * w0 * w0))
	sum := (1 / A) * (1 - p)
	dif := hn * (1 + p)
	return {(sum + dif) / 2, (sum - dif) / 2, 0, -p, 0}
}

// [rt] Biquad `c` as a state-variable filter with the same response: its
// poles as the SVF's g and k (the bilinear map run backwards), its zeros
// as the mix of the SVF's high-, band- and low-pass outputs.
@(private = "file")
pe_svf :: proc "contextless" (c: dsp.Biquad_Coeffs) -> Pe_Section {
	lo, hi := 1 + c.a1 + c.a2, 1 - c.a1 + c.a2
	g := math.sqrt(max(lo, 1e-300) / max(hi, 1e-300))
	a0 := 4 / hi
	k := 2 * (1 - c.a2) / (hi * g)
	s: Pe_Section
	s.k = k
	s.a1 = 1 / (1 + g * (g + k))
	s.a2 = g * s.a1
	s.a3 = g * s.a2
	s.c2 = a0 * (c.b0 - c.b1 + c.b2) / 4
	s.c1 = a0 * (c.b0 - c.b2) / (2 * g)
	s.c0 = a0 * (c.b0 + c.b1 + c.b2) / (4 * g * g)
	return s
}

@(private = "file")
pe_exp2 :: #force_inline proc "contextless" (x: f64) -> f64 { return math.pow(2, x) }
