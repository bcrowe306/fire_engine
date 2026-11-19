package fx

import "base:intrinsics"
import "core:math"
import "core:mem"

import "fire:core"
import "fire:dsp"

// ProVerb: an algorithmic room reverb as a graph node. Stereo in and out.
//
// The signal: predelay → an early section (a pattern of taps, each side
// its own in the wide modes, into two short allpass diffusers whose
// delays drift with Early Mod) and, through input diffusers, a late
// feedback delay network (4, 8 or 16 lines as Quality says, mixed by a
// Householder matrix, each line's delay drifting with Late Mod, each
// line's loop through a bass shelf and a treble shelf so the tail lasts
// Decay × Bass Mult below Bass Xover and Decay × High Mult above High
// Xover). Early and late meet by Depth (equal power), then High Cut, then
// Mix against the dry (no latency).
//
// Its twelve modes are its own structures, tuned so their tails sit where
// a reference reverb's measured ones do (`proverb_modes.odin`).
//
// Every change lands on its exact frame; the lines' lengths glide to a
// new size. The output is the same whatever the blocks.
//
//	node, pv, _ := fx.proverb_create({})
//	// graph.set_param(g, id, fx.PV_PARAM_DECAY_S, 4)

// ProVerb's quality: how many late lines, how finely they are read.
Proverb_Quality :: enum u8 {
	Eco,    // 4 lines, two input diffusers: for small machines
	Normal, // 8 lines, cubic reads
	High,   // 16 lines, cubic reads, all four input diffusers
}

// Parameter id of ProVerb's Mix: 0 (dry) .. 1 (wet).
PV_PARAM_MIX :: core.Param_Id(1)
// Parameter id of ProVerb's predelay: ms, 0..500.
PV_PARAM_PREDELAY_MS :: core.Param_Id(2)
// Parameter id of ProVerb's decay (the middle's RT60): s, 0.1..100.
PV_PARAM_DECAY_S :: core.Param_Id(3)
// Parameter id of ProVerb's High Cut: Hz, 100..15000.
PV_PARAM_HIGH_CUT_HZ :: core.Param_Id(4)
// Parameter id of ProVerb's Depth: 0 (early only) .. 1 (late only).
PV_PARAM_DEPTH :: core.Param_Id(5)
// Parameter id of ProVerb's early size: 0..1.
PV_PARAM_EARLY_SIZE :: core.Param_Id(6)
// Parameter id of ProVerb's early cross (its sides mixed): 0..1.
PV_PARAM_EARLY_CROSS :: core.Param_Id(7)
// Parameter id of ProVerb's early modulation rate: Hz, 0.05..5.
PV_PARAM_EARLY_MOD_RATE :: core.Param_Id(8)
// Parameter id of ProVerb's early modulation depth: 0..1.
PV_PARAM_EARLY_MOD_DEPTH :: core.Param_Id(9)
// Parameter id of ProVerb's early send (the early section into the late): 0..1.
PV_PARAM_EARLY_SEND :: core.Param_Id(10)
// Parameter id of ProVerb's late size: 0..1.
PV_PARAM_LATE_SIZE :: core.Param_Id(11)
// Parameter id of ProVerb's late cross (its sides spread into each other): 0..1.
PV_PARAM_LATE_CROSS :: core.Param_Id(12)
// Parameter id of ProVerb's late modulation rate: Hz, 0.05..5.
PV_PARAM_LATE_MOD_RATE :: core.Param_Id(13)
// Parameter id of ProVerb's late modulation depth: 0..1.
PV_PARAM_LATE_MOD_DEPTH :: core.Param_Id(14)
// Parameter id of ProVerb's bass multiplier (the decay below Bass Xover): 0.5..2.
PV_PARAM_BASS_MULT :: core.Param_Id(15)
// Parameter id of ProVerb's bass crossover: Hz, 100..10000.
PV_PARAM_BASS_XOVER_HZ :: core.Param_Id(16)
// Parameter id of ProVerb's high multiplier (the decay above High Xover): 0.1..1.
PV_PARAM_HIGH_MULT :: core.Param_Id(17)
// Parameter id of ProVerb's high crossover: Hz, 100..15000.
PV_PARAM_HIGH_XOVER_HZ :: core.Param_Id(18)
// Parameter id of ProVerb's diffusion (how fast it becomes smooth): 0..1.
PV_PARAM_DIFFUSION :: core.Param_Id(19)
// Parameter id of ProVerb's mode: 0..11.
PV_PARAM_MODE :: core.Param_Id(20)
// Parameter id of ProVerb's Quality: a `Proverb_Quality`. Read when the
// node is made (`Proverb_Settings.quality`): a new node when it changes.
PV_PARAM_QUALITY :: core.Param_Id(21)

// Parameter table of the ProVerb node, as `node_params` returns it. Read-only.
proverb_params := [?]core.Param_Info {
	{id = PV_PARAM_MIX, name = "Mix", unit = .Percent, min = 0, max = 1, default = 0.35, flags = {.Automatable}},
	{id = PV_PARAM_PREDELAY_MS, name = "Predelay", unit = .Milliseconds, min = 0, max = 500, default = 10, flags = {.Automatable}},
	{id = PV_PARAM_DECAY_S, name = "Decay", unit = .None, /* seconds */ min = 0.1, max = 100, default = 2, flags = {.Automatable}},
	{id = PV_PARAM_HIGH_CUT_HZ, name = "High Cut", unit = .Hertz, min = 100, max = 15_000, default = 8000, flags = {.Automatable}},
	{id = PV_PARAM_DEPTH, name = "Depth", unit = .Percent, min = 0, max = 1, default = 0.5, flags = {.Automatable}},
	{id = PV_PARAM_EARLY_SIZE, name = "Early Size", min = 0, max = 1, default = 0.03, flags = {.Automatable}},
	{id = PV_PARAM_EARLY_CROSS, name = "Early Cross", min = 0, max = 1, default = 0.1, flags = {.Automatable}},
	{id = PV_PARAM_EARLY_MOD_RATE, name = "Early Mod Rate", unit = .Hertz, min = 0.05, max = 5, default = 0.5, flags = {.Automatable}},
	{id = PV_PARAM_EARLY_MOD_DEPTH, name = "Early Mod Depth", min = 0, max = 1, default = 0, flags = {.Automatable}},
	{id = PV_PARAM_EARLY_SEND, name = "Early Send", min = 0, max = 1, default = 0, flags = {.Automatable}},
	{id = PV_PARAM_LATE_SIZE, name = "Late Size", min = 0, max = 1, default = 0.5, flags = {.Automatable}},
	{id = PV_PARAM_LATE_CROSS, name = "Late Cross", min = 0, max = 1, default = 1, flags = {.Automatable}},
	{id = PV_PARAM_LATE_MOD_RATE, name = "Late Mod Rate", unit = .Hertz, min = 0.05, max = 5, default = 0.5, flags = {.Automatable}},
	{id = PV_PARAM_LATE_MOD_DEPTH, name = "Late Mod Depth", min = 0, max = 1, default = 0.5, flags = {.Automatable}},
	{id = PV_PARAM_BASS_MULT, name = "Bass Mult", min = 0.5, max = 2, default = 1, flags = {.Automatable}},
	{id = PV_PARAM_BASS_XOVER_HZ, name = "Bass Xover", unit = .Hertz, min = 100, max = 10_000, default = 1000, flags = {.Automatable}},
	{id = PV_PARAM_HIGH_MULT, name = "High Mult", min = 0.1, max = 1, default = 0.5, flags = {.Automatable}},
	{id = PV_PARAM_HIGH_XOVER_HZ, name = "High Xover", unit = .Hertz, min = 100, max = 15_000, default = 8000, flags = {.Automatable}},
	{id = PV_PARAM_DIFFUSION, name = "Diffusion", min = 0, max = 1, default = 1, flags = {.Automatable}},
	{id = PV_PARAM_MODE, name = "Mode", min = 0, max = 11, default = 0, flags = {.Automatable, .Stepped}},
	{id = PV_PARAM_QUALITY, name = "Quality", min = 0, max = f64(max(Proverb_Quality)), default = 1, flags = {.Stepped}},
}

// The number of ProVerb parameters (ids 1 to this).
PV_PARAMS :: len(proverb_params)

// Settings for `proverb_create`.
Proverb_Settings :: struct {
	quality: Proverb_Quality,
}

// A ProVerb's settings, by parameter id (index 0 unused).
Proverb_Values :: [PV_PARAMS + 1]f32

// ProVerb's settings at their defaults (and Normal quality).
proverb_defaults :: proc "contextless" () -> (v: Proverb_Values) {
	for p in proverb_params do v[p.id] = f32(p.default)
	return
}

// What a ProVerb is doing, for its meters (`proverb_readout`).
Proverb_Readout :: struct {
	in_peak:  f32, // the last block's peak in (linear)
	out_peak: f32, // and out
	tail:     f32, // the wet's RMS over the last block (linear)
}

// Taps in ProVerb's early pattern (each side).
PV_EARLY_TAPS :: 16

// One early reflection as ProVerb makes it: when, and how loud on each
// side (signed).
Proverb_Tap :: struct {
	ms:          f32,
	left, right: f32,
}

@(private = "file") PV_MAX_LINES :: 16
@(private = "file") PV_DIFFUSERS :: 4
// The late lines' lengths against the shortest (sixteen; Eco takes every
// fourth, Normal every other).
@(private = "file") PV_RATIOS := [PV_MAX_LINES]f32{1.000, 1.061, 1.127, 1.193, 1.271, 1.332, 1.396, 1.471, 1.553, 1.627, 1.701, 1.789, 1.873, 1.951, 2.039, 2.131}
// The input diffusers' delays (ms, at size 0.5) and the early diffusers'
// (against the early span).
@(private = "file") PV_DIFF_MS := [PV_DIFFUSERS]f32{1.31, 2.13, 3.37, 4.97}
@(private = "file") PV_EARLY_DIFF := [2]f32{0.053, 0.087}

// The longest anything is: the lines (with room for modulation), the
// predelay, the early section.
@(private = "file") PV_LINE_MAX_S :: 0.3
@(private = "file") PV_PRE_MAX_S :: 0.51
@(private = "file") PV_EARLY_MAX_S :: 0.12

// A delay line: a power-of-two ring.
@(private = "file")
Pv_Line :: struct {
	buf:  []f32,
	mask: int,
}

// A first-order filter (b0 + b1 z⁻¹) / (1 + a1 z⁻¹) and its last input and output.
@(private = "file")
Pv_First :: struct {
	b0, b1, a1: f32,
	x1, y1:     f32,
}

// A ProVerb node's state (from `proverb_create`). Fields are internal.
Proverb :: struct {
	settings:    Proverb_Settings,
	values:      Proverb_Values,
	sample_rate: f64,
	lines_n:     int,
	at:          int, // the write position, shared by every ring
	lines:       [PV_MAX_LINES]Pv_Line,
	length:      [PV_MAX_LINES]f32, // each line's length now (frames, gliding)
	target:      [PV_MAX_LINES]f32, // and where it is going
	gain:        [PV_MAX_LINES]f32, // each line's loop gain (the middle's)
	low:         [PV_MAX_LINES]Pv_First, // each line's bass shelf
	high:        [PV_MAX_LINES]Pv_First, // and treble shelf
	phase:       [PV_MAX_LINES]f64, // each line's modulation, 0..1
	rate_mul:    [PV_MAX_LINES]f32,
	mod_frames:  f32, // the late modulation's depth (frames)
	pre:         [2]Pv_Line,
	early:       [2]Pv_Line,
	diff:        [2][PV_DIFFUSERS]Pv_Line, // the input diffusers, each side
	diff_len:    [PV_DIFFUSERS]int,
	diff_gain:   f32,
	ediff:       [2][2]Pv_Line, // the early diffusers
	ediff_len:   [2]f32,
	ediff_gain:  f32,
	ephase:      f64,
	taps:        [2][PV_EARLY_TAPS]Proverb_Tap, // the early pattern, as frames and gains
	tap_frames:  [2][PV_EARLY_TAPS]int,
	cut:         [2]dsp.Biquad_State,
	cut_c:       dsp.Biquad_Coeffs,
	in_w:        [2][PV_MAX_LINES]f32, // how each side feeds each line
	out_w:       [2][PV_MAX_LINES]f32, // how each line feeds each side
	fast_onset:  f32, // modes whose tail arrives at once: the diffusers' output straight in
	early_g:     f32,
	late_g:      f32,
	glide_coeff: f32,
	settled:     bool, // past the first frame since a reset (before it, lengths jump)
	dirty:       bool, // the settings changed: work the derived ones out again
	readout:     [3]u32, // atomics: a `Proverb_Readout`'s floats, as bits
	wet:         dsp.Tap, // the wet, for the display
	allocator:   mem.Allocator,
}

@(private = "file")
proverb_vtable := core.Node_VTable {
	name    = "fire.proverb",
	prepare = proverb_prepare,
	process = proverb_process,
	reset   = proc(self: rawptr) { pv_clear((^Proverb)(self)) },
	release = proc(self: rawptr, allocator: mem.Allocator) { pv_free((^Proverb)(self), allocator) },
	params  = proc(self: rawptr) -> []core.Param_Info { return proverb_params[:] },
	destroy = proc(self: rawptr, allocator: mem.Allocator) {
		n := (^Proverb)(self)
		pv_free(n, allocator)
		free(n, allocator)
	},
}

// Control thread. A ProVerb at its defaults (and `settings.quality` as its
// Quality). Add it with 2 inputs and 2 outputs (1 input: both sides).
proverb_create :: proc(settings: Proverb_Settings, allocator := context.allocator) -> (node: core.Node, pv: ^Proverb, err: core.Error) {
	pv = new(Proverb, allocator)
	pv.settings, pv.allocator = settings, allocator
	pv.values = proverb_defaults()
	pv.values[PV_PARAM_QUALITY] = f32(settings.quality)
	switch settings.quality {
	case .Eco:    pv.lines_n = 4
	case .Normal: pv.lines_n = 8
	case .High:   pv.lines_n = 16
	}
	return core.node_make(&proverb_vtable, pv, allocator), pv, .None
}

// Any thread. What ProVerb `pv` is doing (as of its last block).
proverb_readout :: proc "contextless" (pv: ^Proverb) -> Proverb_Readout {
	r: [3]f32
	for &v, k in r do v = transmute(f32)intrinsics.atomic_load_explicit(&pv.readout[k], .Relaxed)
	return {in_peak = r[0], out_peak = r[1], tail = r[2]}
}

// Any thread. The last `len(out)` frames of ProVerb `pv`'s wet (the sides
// averaged; at most `dsp.TAP_FRAMES`), oldest first, for a picture of the
// tail.
proverb_read_wet :: proc "contextless" (pv: ^Proverb, out: []f32) -> u64 {
	return dsp.tap_read(&pv.wet, out)
}

// [rt] The decay time (s) ProVerb at settings `v` gives frequency `hz`:
// its middle line's loop, shelves and all, at `sample_rate`.
proverb_rt60 :: proc "contextless" (v: ^Proverb_Values, hz, sample_rate: f64) -> f64 {
	m := &PV_MODES[clamp(int(v[PV_PARAM_MODE] + 0.5), 0, 11)]
	d := f64(pv_line_ms(v, m) * PV_RATIOS[7]) / 1000 // (the middle line's length, s)
	g, lo, hi := pv_loop(v, m, d, sample_rate)
	w := 2 * math.PI * hz / sample_rate
	resp :: proc "contextless" (f: Pv_First, w: f64) -> f64 {
		z := complex(math.cos(w), -math.sin(w))
		return abs((complex(f64(f.b0), 0) + complex(f64(f.b1), 0) * z) / (1 + complex(f64(f.a1), 0) * z))
	}
	mag := f64(g) * resp(lo, w) * resp(hi, w)
	if mag >= 1 do return 1e9
	return -3 * d / math.log10(max(mag, 1e-12))
}

// [rt] ProVerb's early pattern at settings `v` into `out` (each side's
// taps: times in ms after the predelay, gains signed), as the node makes
// it.
proverb_early_taps :: proc "contextless" (v: ^Proverb_Values, out: ^[PV_EARLY_TAPS]Proverb_Tap) {
	mode := clamp(int(v[PV_PARAM_MODE] + 0.5), 0, 11)
	span := pv_early_span_ms(v)
	l, r := pv_pattern(mode, 0, span), pv_pattern(mode, 1, span)
	for k in 0 ..< PV_EARLY_TAPS do out[k] = {ms = l[k].ms, left = l[k].left, right = r[k].left}
}

// The early span (ms) for Early Size.
@(private = "file")
pv_early_span_ms :: proc "contextless" (v: ^Proverb_Values) -> f32 {
	return 6 + 90 * math.sqrt(clamp(v[PV_PARAM_EARLY_SIZE], 0, 1))
}

// The shortest late line's length (ms): its first arrival grows with Late
// Size (5.7 to 57 ms in the first mode), as the mode places it; never under
// 8 ms (a mode that arrives sooner adds the diffusers' output at once).
@(private = "file")
pv_line_ms :: proc "contextless" (v: ^Proverb_Values, m: ^Pv_Mode) -> f32 {
	return max((5.7 + 51.3 * clamp(v[PV_PARAM_LATE_SIZE], 0, 1)) * clamp(m.first, 0.5, 2), 8)
}

// A mode's early pattern on one side (its seed): `PV_EARLY_TAPS` taps
// spread over `span` ms, denser and quieter toward the end, signs mixed.
@(private = "file")
pv_pattern :: proc "contextless" (mode, side: int, span: f32) -> (taps: [PV_EARLY_TAPS]Proverb_Tap) {
	s := u32(0x9E3779B9) ~ u32(mode * 7919 + side * 104729 + 1)
	rnd :: #force_inline proc "contextless" (s: ^u32) -> f32 {
		s^ ~= s^ << 13
		s^ ~= s^ >> 17
		s^ ~= s^ << 5
		return f32(s^ & 0xFFFFFF) / f32(0x1000000)
	}
	energy: f32 = 0
	for &t, k in taps {
		u := (f32(k) + 0.25 + 0.5 * rnd(&s)) / PV_EARLY_TAPS
		t.ms = 0.05 * span + 0.95 * span * math.pow(u, 0.8)
		g := (1 - 0.55 * u) * (0.6 + 0.4 * rnd(&s))
		if rnd(&s) < 0.4 do g = -g
		t.left = g
		energy += g * g
	}
	norm := 1 / math.sqrt(max(energy, 1e-6))
	for &t in taps do t.left *= norm
	return
}

// The loop of a line `d` seconds long: its middle gain and its two shelves
// (the bass's down to Bass Xover, the treble's up from High Xover), so the
// decay is Decay × the multipliers × the mode's own.
@(private = "file")
pv_loop :: proc "contextless" (v: ^Proverb_Values, m: ^Pv_Mode, d, sr: f64) -> (g: f32, lo, hi: Pv_First) {
	rt := max(f64(v[PV_PARAM_DECAY_S]) * f64(m.mid), 0.05)
	rt_lo := max(rt * f64(v[PV_PARAM_BASS_MULT]) * f64(m.bass), 0.05)
	rt_hi := max(rt * f64(v[PV_PARAM_HIGH_MULT]) * f64(m.high), 0.02)
	gain :: #force_inline proc "contextless" (d, rt: f64) -> f64 { return math.pow(10, -3 * d / rt) }
	gm := gain(d, rt)
	G_lo := gain(d, rt_lo) / gm
	G_hi := gain(d, rt_hi) / gm
	k_lo := math.tan(math.PI * clamp(f64(v[PV_PARAM_BASS_XOVER_HZ]), 20, 0.45 * sr) / sr)
	k_hi := math.tan(math.PI * clamp(1.4 * f64(v[PV_PARAM_HIGH_XOVER_HZ]), 20, 0.45 * sr) / sr) // (its corner a little above: the treble loss as gentle as measured)
	// Low shelf: G at DC, 1 above; high shelf: 1 at DC, G at Nyquist (first order, bilinear).
	lo = {b0 = f32((1 + G_lo * k_lo) / (1 + k_lo)), b1 = f32((G_lo * k_lo - 1) / (1 + k_lo)), a1 = f32((k_lo - 1) / (1 + k_lo))}
	hi = {b0 = f32((G_hi + k_hi) / (1 + k_hi)), b1 = f32((k_hi - G_hi) / (1 + k_hi)), a1 = f32((k_hi - 1) / (1 + k_hi))}
	return f32(gm), lo, hi
}

@(private = "file")
pv_ring :: proc(seconds, sr: f64, allocator: mem.Allocator) -> (l: Pv_Line, err: core.Error) {
	n := 1
	for n < int(seconds * sr) + 4 do n <<= 1
	ae: mem.Allocator_Error
	l.buf, ae = make([]f32, n, allocator)
	if ae != nil do return {}, .Out_Of_Memory
	l.mask = n - 1
	return l, .None
}

@(private = "file")
pv_free :: proc(n: ^Proverb, allocator: mem.Allocator) {
	del :: proc(l: ^Pv_Line, a: mem.Allocator) {
		delete(l.buf, a)
		l^ = {}
	}
	for &l in n.lines do del(&l, allocator)
	for &l in n.pre do del(&l, allocator)
	for &l in n.early do del(&l, allocator)
	for &side in n.diff do for &l in side do del(&l, allocator)
	for &side in n.ediff do for &l in side do del(&l, allocator)
}

@(private = "file")
proverb_prepare :: proc(self: rawptr, cfg: core.Prepare_Config, allocator: mem.Allocator) -> core.Error {
	n := (^Proverb)(self)
	pv_free(n, allocator)
	n.sample_rate = cfg.sample_rate
	sr := cfg.sample_rate
	for k in 0 ..< n.lines_n do n.lines[k] = pv_ring(PV_LINE_MAX_S, sr, allocator) or_return
	for ch in 0 ..< 2 {
		n.pre[ch] = pv_ring(PV_PRE_MAX_S, sr, allocator) or_return
		n.early[ch] = pv_ring(PV_EARLY_MAX_S, sr, allocator) or_return
		for k in 0 ..< PV_DIFFUSERS do n.diff[ch][k] = pv_ring(0.02, sr, allocator) or_return
		for k in 0 ..< 2 do n.ediff[ch][k] = pv_ring(0.02, sr, allocator) or_return
	}
	n.glide_coeff = f32(math.exp(-1 / (0.05 * sr)))
	// Each line's modulation runs at its own rate about the set one, its
	// phase spread.
	for k in 0 ..< PV_MAX_LINES do n.rate_mul[k] = 0.83 + 0.37 * f32(k % 7) / 6
	pv_clear(n)
	return .None
}

// [rt] Back to silence.
@(private = "file")
pv_clear :: proc "contextless" (n: ^Proverb) {
	clear :: proc "contextless" (l: ^Pv_Line) { for &x in l.buf do x = 0 }
	for k in 0 ..< n.lines_n do clear(&n.lines[k])
	for ch in 0 ..< 2 {
		clear(&n.pre[ch])
		clear(&n.early[ch])
		for k in 0 ..< PV_DIFFUSERS do clear(&n.diff[ch][k])
		for k in 0 ..< 2 do clear(&n.ediff[ch][k])
	}
	for &f in n.low do f.x1, f.y1 = 0, 0
	for &f in n.high do f.x1, f.y1 = 0, 0
	for k in 0 ..< PV_MAX_LINES do n.phase[k] = f64(k) / PV_MAX_LINES
	n.ephase = 0
	n.cut = {}
	n.at = 0
	n.settled, n.dirty = false, true
}

// [rt] The settings' derived values, worked out again: the lines' lengths
// and loops, the diffusers, the early pattern, the weights, the levels.
@(private = "file")
pv_derive :: proc "contextless" (n: ^Proverb) {
	v := &n.values
	sr := n.sample_rate
	mi := clamp(int(v[PV_PARAM_MODE] + 0.5), 0, 11)
	m := &PV_MODES[mi]
	N := n.lines_n
	step := PV_MAX_LINES / N
	base := pv_line_ms(v, m)
	for k in 0 ..< N {
		ratio := PV_RATIOS[k * step] * (1 + 0.013 * f32((k * 5 + mi * 3) % 7 - 3)) // (each mode's lines a little its own)
		n.target[k] = base * ratio * f32(sr) / 1000
		if !n.settled do n.length[k] = n.target[k]
		n.gain[k], n.low[k].b0, n.low[k].b1, n.low[k].a1 = 0, 0, 0, 0
		g, lo, hi := pv_loop(v, m, f64(n.target[k]) / sr, sr)
		n.gain[k] = g
		n.low[k].b0, n.low[k].b1, n.low[k].a1 = lo.b0, lo.b1, lo.a1
		n.high[k].b0, n.high[k].b1, n.high[k].a1 = hi.b0, hi.b1, hi.a1
	}
	// Late Mod Depth as a pitch deviation (squared: fine at the bottom),
	// its delay swing whatever the rate: deviation / (2π rate).
	dmd := clamp(v[PV_PARAM_LATE_MOD_DEPTH], 0, 1)
	dev := 0.0018 * dmd * dmd * m.mod
	n.mod_frames = clamp(dev / (2 * math.PI * clamp(v[PV_PARAM_LATE_MOD_RATE], 0.05, 5)), 0, 0.012) * f32(sr)
	// The input diffusers (fewer for Eco; gentler where the mode builds slowly).
	size := 0.5 + clamp(v[PV_PARAM_LATE_SIZE], 0, 1)
	for k in 0 ..< PV_DIFFUSERS do n.diff_len[k] = max(int(PV_DIFF_MS[k] * size * f32(sr) / 1000), 1)
	n.diff_gain = clamp(v[PV_PARAM_DIFFUSION], 0, 1) * (0.3 if m.slow else 0.6)
	n.fast_onset = 0.2 if m.first < 0.5 else 0
	// The early section.
	span := pv_early_span_ms(v)
	for side in 0 ..< 2 {
		p := pv_pattern(mi, side, span) // (each side its own first reflections, in every mode)
		for t, k in p {
			n.taps[side][k] = t
			n.tap_frames[side][k] = clamp(int(t.ms * f32(sr) / 1000), 1, len(n.early[side].buf) - 2)
		}
	}
	for k in 0 ..< 2 do n.ediff_len[k] = max(PV_EARLY_DIFF[k] * span * f32(sr) / 1000, 1)
	n.ediff_gain = (0.6 + 0.3 * clamp(v[PV_PARAM_EARLY_SIZE], 0, 1)) * clamp(v[PV_PARAM_DIFFUSION], 0, 1)
	// How each side feeds the lines (Late Cross: apart at 0, together at 1),
	// and how the lines come out (orthogonal signs: the sides uncorrelated).
	cross := clamp(v[PV_PARAM_LATE_CROSS], 0, 1)
	norm := 1 / math.sqrt(f32(N))
	for k in 0 ..< N {
		mine: f32 = 1 if k % 2 == 0 else 0
		sign: f32 = 1 if (k / 2) % 2 == 0 else -1
		n.in_w[0][k] = sign * (mine + (1 - mine) * cross) * norm
		n.in_w[1][k] = sign * ((1 - mine) + mine * cross) * norm * (1 if k % 3 != 1 else -1)
		// (Two rows of a Hadamard matrix: orthogonal.)
		n.out_w[0][k] = (1 if k & 1 == 0 else -1) * norm
		n.out_w[1][k] = (1 if k & 2 == 0 else -1) * norm
	}
	// Levels: early and late each about as loud as the other alone, as the
	// mode has them.
	esize := clamp(v[PV_PARAM_EARLY_SIZE], 0, 1)
	n.early_g = 0.93 * (1 + 3 * esize) * math.pow(10, m.early_db / 20) // (a bigger early space is louder, as it rings longer)
	n.late_g = 1.4 * math.pow(10, m.late_db / 20) * math.pow(base / 30.3, 0.45) // (short lines pass more in the first second: as loud as the first mode's)
	n.cut_c = dsp.biquad_design(.Lowpass, f64(clamp(v[PV_PARAM_HIGH_CUT_HZ], 100, 15_000)), 0.707, 0, sr)
	n.dirty = false
}

@(private = "file")
proverb_process :: proc(self: rawptr, ctx: ^core.Process_Context) {
	n := (^Proverb)(self)
	f := ctx.frames
	if len(ctx.outputs) < 2 || f < 0 || len(n.pre[0].buf) == 0 do return
	in_ := [2][]f32{pv_input(ctx, 0, f), pv_input(ctx, 1, f)}
	out := [2][]f32{ctx.outputs[0][:f], ctx.outputs[1][:f]}
	pk_in, pk_out: f32
	sum2: f64
	at := 0
	for e in ctx.events_in {
		to := clamp(int(e.offset), at, f)
		pv_render(n, in_, out, at, to, &pk_in, &pk_out, &sum2)
		at = to
		pv_event(n, e.payload)
	}
	pv_render(n, in_, out, at, f, &pk_in, &pk_out, &sum2)
	if f > 0 {
		r := [3]f32{pk_in, pk_out, f32(math.sqrt(sum2 / f64(f)))}
		for x, k in r do intrinsics.atomic_store_explicit(&n.readout[k], transmute(u32)x, .Relaxed)
	}
}

// [rt] Input `ch` (one input: both sides from it; none: silence, the
// output's own buffer zeroed).
@(private = "file")
pv_input :: proc "contextless" (ctx: ^core.Process_Context, ch, f: int) -> []f32 {
	if len(ctx.inputs) == 0 {
		o := ctx.outputs[ch][:f]
		for &x in o do x = 0
		return o
	}
	return ctx.inputs[min(ch, len(ctx.inputs) - 1)][:f]
}

// [rt] A parameter change, into the values.
@(private = "file")
pv_event :: proc "contextless" (n: ^Proverb, p: core.Event_Payload) {
	id: core.Param_Id
	value: f64
	#partial switch e in p {
	case core.Param_Value: id, value = e.param, e.value
	case core.Param_Ramp:  id, value = e.param, e.target
	case: return
	}
	if int(id) < 1 || int(id) > PV_PARAMS || id == PV_PARAM_QUALITY do return
	info := &proverb_params[id - 1]
	n.values[id] = f32(clamp(value, info.min, info.max))
	n.dirty = true
}

// [rt] A delay line read `d` frames back (fractional: cubic, or linear).
@(private = "file")
pv_read :: #force_inline proc "contextless" (l: ^Pv_Line, at: int, d: f32, cubic: bool) -> f32 #no_bounds_check {
	i := int(d)
	fr := d - f32(i)
	p := at - i
	a := l.buf[p & l.mask]
	b := l.buf[(p - 1) & l.mask]
	if !cubic do return a + (b - a) * fr
	z := l.buf[(p + 1) & l.mask]
	c := l.buf[(p - 2) & l.mask]
	// (Hermite, through z a b c.)
	c0 := a
	c1 := 0.5 * (b - z)
	c2 := z - 2.5 * a + 2 * b - 0.5 * c
	c3 := 0.5 * (c - z) + 1.5 * (a - b)
	return ((c3 * fr + c2) * fr + c1) * fr + c0
}

// [rt] Frames `from`..`to`.
@(private = "file")
pv_render :: proc "contextless" (n: ^Proverb, in_, out: [2][]f32, from, to: int, pk_in, pk_out: ^f32, sum2: ^f64) #no_bounds_check {
	if to <= from do return
	if n.dirty do pv_derive(n)
	n.settled = true
	v := &n.values
	sr := f32(n.sample_rate)
	N := n.lines_n
	cubic := true // (linear reads lose treble every pass round the loop: even Eco reads cubic, its four lines cheap)
	mix := clamp(v[PV_PARAM_MIX], 0, 1)
	depth := clamp(v[PV_PARAM_DEPTH], 0, 1)
	eg := math.cos(depth * math.PI / 2) * n.early_g
	lg := math.sin(depth * math.PI / 2) * n.late_g
	send := clamp(v[PV_PARAM_EARLY_SEND], 0, 1) * 4 // (the early, louder into the late than out)
	ecross := clamp(v[PV_PARAM_EARLY_CROSS], 0, 1) * 0.5
	pre := clamp(v[PV_PARAM_PREDELAY_MS], 0, 500) * sr / 1000
	pre_i := clamp(int(pre), 0, len(n.pre[0].buf) - 2)
	rate := f64(clamp(v[PV_PARAM_LATE_MOD_RATE], 0.05, 5)) / f64(sr)
	erate := f64(clamp(v[PV_PARAM_EARLY_MOD_RATE], 0.05, 5)) / f64(sr)
	edepth := clamp(v[PV_PARAM_EARLY_MOD_DEPTH], 0, 1) * 0.0005 * sr
	ndiff := 2 if n.settings.quality == .Eco else PV_DIFFUSERS
	gc := n.glide_coeff
	for i in from ..< to {
		at := n.at
		// Predelay.
		x: [2]f32
		for ch in 0 ..< 2 {
			s := in_[ch][i]
			pk_in^ = max(pk_in^, abs(s))
			n.pre[ch].buf[at & n.pre[ch].mask] = s
			x[ch] = n.pre[ch].buf[(at - pre_i) & n.pre[ch].mask]
		}
		// The early section: its taps, then two diffusers (drifting).
		n.ephase += erate
		if n.ephase >= 1 do n.ephase -= 1
		esw := f32(math.sin(2 * math.PI * n.ephase))
		e: [2]f32
		for ch in 0 ..< 2 {
			l := &n.early[ch]
			l.buf[at & l.mask] = x[ch]
			acc: f32 = 0
			for k in 0 ..< PV_EARLY_TAPS do acc += n.taps[ch][k].left * l.buf[(at - n.tap_frames[ch][k]) & l.mask]
			for k in 0 ..< 2 {
				dl := &n.ediff[ch][k]
				d := clamp(n.ediff_len[k] + esw * edepth * (1 if k == 0 else -1), 1, f32(len(dl.buf) - 3))
				delayed := pv_read(dl, at - 1, d - 1, false)
				w := acc + n.ediff_gain * delayed
				dl.buf[at & dl.mask] = w
				acc = delayed - n.ediff_gain * w
			}
			e[ch] = acc
		}
		e[0], e[1] = e[0] + (e[1] - e[0]) * ecross, e[1] + (e[0] - e[1]) * ecross
		// Into the late network: the predelayed sound (and the early, sent), diffused.
		u, onset: [2]f32
		for ch in 0 ..< 2 {
			s := x[ch] + send * e[ch]
			if n.diff_gain > 0.01 {
				for k in 0 ..< ndiff {
					dl := &n.diff[ch][k]
					delayed := dl.buf[(at - n.diff_len[k]) & dl.mask]
					w := s + n.diff_gain * delayed
					dl.buf[at & dl.mask] = w
					s = delayed - n.diff_gain * w
					onset[ch] = delayed // (the last diffuser's delayed part: the fast modes' onset, a little after the sound)
				}
			} else {
				onset[ch] = s
			}
			u[ch] = s
		}
		// The lines: read (drifting), through their loops, mixed (Householder), written back.
		y: [PV_MAX_LINES]f32
		sum: f32 = 0
		for k in 0 ..< N {
			n.length[k] = n.target[k] + (n.length[k] - n.target[k]) * gc
			n.phase[k] += rate * f64(n.rate_mul[k])
			if n.phase[k] >= 1 do n.phase[k] -= 1
			d := n.length[k] + n.mod_frames * (1 + f32(math.sin(2 * math.PI * n.phase[k])))
			r := pv_read(&n.lines[k], at - 1, d - 1, cubic)
			lo := &n.low[k]
			a := lo.b0 * r + lo.b1 * lo.x1 - lo.a1 * lo.y1
			lo.x1, lo.y1 = r, a
			hi := &n.high[k]
			b := hi.b0 * a + hi.b1 * hi.x1 - hi.a1 * hi.y1
			hi.x1, hi.y1 = a, b
			y[k] = n.gain[k] * b
			sum += y[k]
		}
		h := sum * 2 / f32(N)
		late: [2]f32
		for k in 0 ..< N {
			fb := y[k] - h + u[0] * n.in_w[0][k] + u[1] * n.in_w[1][k]
			n.lines[k].buf[at & n.lines[k].mask] = fb
			late[0] += y[k] * n.out_w[0][k]
			late[1] += y[k] * n.out_w[1][k]
		}
		if n.fast_onset > 0 do late[0], late[1] = late[0] + onset[0] * n.fast_onset, late[1] + onset[1] * n.fast_onset
		// Early and late by Depth, High Cut, Mix.
		w_avg: f32 = 0
		for ch in 0 ..< 2 {
			wet := eg * e[ch] + lg * late[ch]
			wet = f32(dsp.biquad_tick(&n.cut_c, &n.cut[ch], f64(wet)))
			w_avg += wet * 0.5
			sum2^ += f64(wet) * f64(wet) * 0.5
			y_out := in_[ch][i] + (wet - in_[ch][i]) * mix
			if mix >= 1 do y_out = wet
			out[ch][i] = y_out
			pk_out^ = max(pk_out^, abs(y_out))
		}
		wp := intrinsics.atomic_load(&n.wet.write)
		n.wet.ring[wp & (dsp.TAP_FRAMES - 1)] = w_avg
		intrinsics.atomic_store(&n.wet.write, wp + 1)
		n.at = at + 1
	}
}

// Control thread. A reference room reverb's settings (its parameters, by
// their names, each 0..1, as ValhallaRoom's presets and host interface
// have them) as ProVerb's, each in ProVerb's own range: what's missing
// stays at ProVerb's default. The ranges are inferred from the reference's
// panel (docs/design/proverb.md); its Type picks ProVerb's mode tuned
// against it.
proverb_reference_values :: proc(p: map[string]f64) -> Proverb_Values {
	v := proverb_defaults()
	get :: proc(p: map[string]f64, k: string, d: f64) -> f64 { return clamp(p[k], 0, 1) if k in p else d }
	v[PV_PARAM_MIX] = f32(get(p, "mix", 1))
	v[PV_PARAM_PREDELAY_MS] = f32(get(p, "predelay", 0.02) * 500)
	v[PV_PARAM_DECAY_S] = f32(0.1 + 99.9 * get(p, "decay", 0.019019))
	v[PV_PARAM_HIGH_CUT_HZ] = f32(100 + 14_900 * get(p, "HighCut", 0.5302))
	v[PV_PARAM_DEPTH] = f32(get(p, "earlyLateMix", 0.5))
	v[PV_PARAM_EARLY_SIZE] = f32(get(p, "earlySize", 0.029))
	v[PV_PARAM_EARLY_CROSS] = f32(get(p, "earlyCross", 0.1))
	v[PV_PARAM_EARLY_MOD_RATE] = f32(clamp(5.5 * get(p, "earlyModRate", 0.0909), 0.05, 5))
	v[PV_PARAM_EARLY_MOD_DEPTH] = f32(get(p, "earlyModDepth", 0))
	v[PV_PARAM_EARLY_SEND] = f32(get(p, "earlySend", 0))
	v[PV_PARAM_LATE_SIZE] = f32(get(p, "lateSize", 0.5))
	v[PV_PARAM_LATE_CROSS] = f32(get(p, "lateCross", 1))
	v[PV_PARAM_LATE_MOD_RATE] = f32(clamp(5.5 * get(p, "lateModRate", 0.0909), 0.05, 5))
	v[PV_PARAM_LATE_MOD_DEPTH] = f32(get(p, "lateModDepth", 0.5))
	v[PV_PARAM_BASS_MULT] = f32(0.5 + 1.5 * get(p, "RTBassMultiply", 0.3333))
	v[PV_PARAM_BASS_XOVER_HZ] = f32(100 + 9900 * get(p, "RTXover", 0.0909))
	v[PV_PARAM_HIGH_MULT] = f32(0.1 + 0.9 * get(p, "RTHighMultiply", 0.4444))
	v[PV_PARAM_HIGH_XOVER_HZ] = f32(100 + 14_900 * get(p, "RTHighXover", 0.5302))
	v[PV_PARAM_DIFFUSION] = f32(get(p, "diffusion", 1))
	v[PV_PARAM_MODE] = f32(clamp(int(get(p, "type", 1.0 / 12) * 12 + 1e-6) - 1, 0, 11)) // (its Type 0 and 1 the same: its first mode)
	return v
}
