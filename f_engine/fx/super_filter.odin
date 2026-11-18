package fx

import "base:intrinsics"
import "core:math"
import "core:mem"

import "fire:core"

// SuperFilter: a filter whose cutoff moves with an LFO and an envelope
// follower, as a graph node. Stereo in and out; added with four inputs,
// inputs 3 and 4 are a sidechain key the envelope follows (else it
// follows its own input).
//
// The signal: the filter (its type, on its circuit, driven) → a soft clip
// (Clip) → the output gain → dry/wet. The cutoff, each frame and each
// side: Freq · 2^(5·(LFO Amount · lfo + Envelope · env)) octaves, clamped
// to 20 Hz..20 kHz. Synced LFO rates, Retrigger and the envelope's S&H
// follow the transport's timeline (`Super_Filter_Settings.timeline`, else
// the leading one).
//
//	node, sf := fx.super_filter_create({})
//	// graph.set_param(g, id, fx.SF_PARAM_LFO_AMOUNT, 0.4)

// SuperFilter's filter types.
Sf_Type :: enum u8 {
	Low,
	High,
	Band,
	Notch,
	Peak,
	Morph,  // low → band → high → notch as Morph goes 0 → 1
	DJ,     // one knob: Freq under its middle a low-pass coming down, over it a high-pass going up, flat between
	Comb,   // a tuned comb: Morph is its feedback, negative to positive
	Vowel,  // formants: Morph moves through the vowels (A O E I), Freq transposes them (1 kHz: as they are)
	Phaser, // all-pass stages: Morph blends their peaks
}

// SuperFilter's circuits: the voicing of the types made of poles (Low,
// High, Band, Notch, Peak, Morph, DJ). Clean is a state-variable filter
// (its 24 dB two in a row); the others saturate.
Sf_Circuit :: enum u8 {Clean, Analog, Dirty, Ladder, Diode}

// Parameter id of SuperFilter's type: a `Sf_Type`.
SF_PARAM_TYPE :: core.Param_Id(1)
// Parameter id of SuperFilter's circuit: a `Sf_Circuit`.
SF_PARAM_CIRCUIT :: core.Param_Id(2)
// Parameter id of SuperFilter's Freq (the cutoff): the cutoff (20..20000).
SF_PARAM_FREQ_HZ :: core.Param_Id(3)
// Parameter id of SuperFilter's Res: 0..1.
SF_PARAM_RESONANCE :: core.Param_Id(4)
// Parameter id of SuperFilter's Morph: 0..1: what it does follows the type.
SF_PARAM_MORPH :: core.Param_Id(5)
// Parameter id of SuperFilter's slope: 0: 12 dB, 1: 24 dB (Low, High, Band, Morph).
SF_PARAM_SLOPE :: core.Param_Id(6)
// Parameter id of SuperFilter's drive: into the circuit (0..24).
SF_PARAM_DRIVE_DB :: core.Param_Id(7)
// Parameter id of SuperFilter's LFO amount: -1..1: ±5 octaves.
SF_PARAM_LFO_AMOUNT :: core.Param_Id(8)
// Parameter id of SuperFilter's LFO rate: in Hz mode (0.01..40).
SF_PARAM_LFO_RATE_HZ :: core.Param_Id(9)
// Parameter id of SuperFilter's LFO rate mode: an `Lfo_Mode`.
SF_PARAM_LFO_MODE :: core.Param_Id(10)
// Parameter id of SuperFilter's LFO division: Sync, Dotted, Triplet: a `TEMPO_RATIOS` index (1..12).
SF_PARAM_LFO_DIVISION :: core.Param_Id(11)
// Parameter id of SuperFilter's LFO length in sixteenths: Sixteenths (1..64).
SF_PARAM_LFO_SIXTEENTHS :: core.Param_Id(12)
// Parameter id of SuperFilter's LFO wave: an `Lfo_Wave`.
SF_PARAM_LFO_WAVE :: core.Param_Id(13)
// Parameter id of SuperFilter's LFO wave morph: 0..1 (0.5 plain).
SF_PARAM_LFO_MORPH :: core.Param_Id(14)
// Parameter id of SuperFilter's LFO stereo way: an `Lfo_Stereo`.
SF_PARAM_LFO_STEREO :: core.Param_Id(15)
// Parameter id of SuperFilter's LFO right-side phase: 0..360.
SF_PARAM_LFO_PHASE_DEG :: core.Param_Id(16)
// Parameter id of SuperFilter's LFO spin: 0..2.
SF_PARAM_LFO_SPIN_HZ :: core.Param_Id(17)
// Parameter id of SuperFilter's LFO phase offset: 0..360.
SF_PARAM_LFO_OFFSET_DEG :: core.Param_Id(18)
// Parameter id of SuperFilter's LFO retrigger: an `Lfo_Retrigger`.
SF_PARAM_LFO_RETRIGGER :: core.Param_Id(19)
// Parameter id of SuperFilter's LFO smoothing: 0..1.
SF_PARAM_LFO_SMOOTH :: core.Param_Id(20)
// Parameter id of SuperFilter's envelope amount: -1..1: ±5 octaves.
SF_PARAM_ENV_AMOUNT :: core.Param_Id(21)
// Parameter id of SuperFilter's envelope attack: 0.1..100.
SF_PARAM_ENV_ATTACK_MS :: core.Param_Id(22)
// Parameter id of SuperFilter's envelope release: 1..3000.
SF_PARAM_ENV_RELEASE_MS :: core.Param_Id(23)
// Parameter id of SuperFilter's envelope hold: 0 or 1.
SF_PARAM_ENV_HOLD :: core.Param_Id(24)
// Parameter id of SuperFilter's envelope sample-and-hold: 0 or 1: sample and hold.
SF_PARAM_ENV_SH :: core.Param_Id(25)
// Parameter id of SuperFilter's envelope sample-and-hold rate: a `TEMPO_RATIOS` index (1..12).
SF_PARAM_ENV_SH_DIVISION :: core.Param_Id(26)
// Parameter id of SuperFilter's key gain: the key into the follower (-24..24).
SF_PARAM_KEY_GAIN_DB :: core.Param_Id(27)
// Parameter id of SuperFilter's clip: 0 or 1.
SF_PARAM_CLIP :: core.Param_Id(28)
// Parameter id of SuperFilter's output gain: -24..24.
SF_PARAM_OUTPUT_DB :: core.Param_Id(29)
// Parameter id of SuperFilter's dry/wet: dry/wet, 0..1.
SF_PARAM_MIX :: core.Param_Id(30)

// Parameter table of the SuperFilter node, as `node_params` returns it.
// Read-only.
super_filter_params := [?]core.Param_Info {
	{id = SF_PARAM_TYPE, name = "Type", min = 0, max = f64(max(Sf_Type)), default = 0, flags = {.Automatable, .Stepped}},
	{id = SF_PARAM_CIRCUIT, name = "Circuit", min = 0, max = f64(max(Sf_Circuit)), default = 1, flags = {.Automatable, .Stepped}},
	{id = SF_PARAM_FREQ_HZ, name = "Freq", unit = .Hertz, min = 20, max = 20000, default = 1000, flags = {.Automatable}},
	{id = SF_PARAM_RESONANCE, name = "Res", unit = .Percent, min = 0, max = 1, default = 0.2, flags = {.Automatable}},
	{id = SF_PARAM_MORPH, name = "Morph", unit = .Percent, min = 0, max = 1, default = 0, flags = {.Automatable}},
	{id = SF_PARAM_SLOPE, name = "Slope", min = 0, max = 1, default = 0, flags = {.Automatable, .Stepped}},
	{id = SF_PARAM_DRIVE_DB, name = "Drive", unit = .Decibels, min = 0, max = 24, default = 0, flags = {.Automatable}},
	{id = SF_PARAM_LFO_AMOUNT, name = "LFO Amount", unit = .Percent, min = -1, max = 1, default = 0, flags = {.Automatable}},
	{id = SF_PARAM_LFO_RATE_HZ, name = "LFO Rate", unit = .Hertz, min = 0.01, max = 40, default = 1, flags = {.Automatable}},
	{id = SF_PARAM_LFO_MODE, name = "LFO Mode", min = 0, max = f64(max(Lfo_Mode)), default = 1, flags = {.Automatable, .Stepped}},
	{id = SF_PARAM_LFO_DIVISION, name = "LFO Division", min = 1, max = 12, default = 8, flags = {.Automatable, .Stepped}},
	{id = SF_PARAM_LFO_SIXTEENTHS, name = "LFO Sixteenths", min = 1, max = 64, default = 4, flags = {.Automatable, .Stepped}},
	{id = SF_PARAM_LFO_WAVE, name = "LFO Wave", min = 0, max = f64(max(Lfo_Wave)), default = 0, flags = {.Automatable, .Stepped}},
	{id = SF_PARAM_LFO_MORPH, name = "LFO Morph", unit = .Percent, min = 0, max = 1, default = 0.5, flags = {.Automatable}},
	{id = SF_PARAM_LFO_STEREO, name = "LFO Stereo", min = 0, max = f64(max(Lfo_Stereo)), default = 0, flags = {.Automatable, .Stepped}},
	{id = SF_PARAM_LFO_PHASE_DEG, name = "LFO Phase", min = 0, max = 360, default = 0, flags = {.Automatable}},
	{id = SF_PARAM_LFO_SPIN_HZ, name = "LFO Spin", unit = .Hertz, min = 0, max = 2, default = 0, flags = {.Automatable}},
	{id = SF_PARAM_LFO_OFFSET_DEG, name = "LFO Offset", min = 0, max = 360, default = 0, flags = {.Automatable}},
	{id = SF_PARAM_LFO_RETRIGGER, name = "LFO Retrigger", min = 0, max = f64(max(Lfo_Retrigger)), default = 0, flags = {.Automatable, .Stepped}},
	{id = SF_PARAM_LFO_SMOOTH, name = "LFO Smooth", unit = .Percent, min = 0, max = 1, default = 0, flags = {.Automatable}},
	{id = SF_PARAM_ENV_AMOUNT, name = "Envelope", unit = .Percent, min = -1, max = 1, default = 0, flags = {.Automatable}},
	{id = SF_PARAM_ENV_ATTACK_MS, name = "Attack", unit = .Milliseconds, min = 0.1, max = 100, default = 1, flags = {.Automatable}},
	{id = SF_PARAM_ENV_RELEASE_MS, name = "Release", unit = .Milliseconds, min = 1, max = 3000, default = 250, flags = {.Automatable}},
	{id = SF_PARAM_ENV_HOLD, name = "Hold", min = 0, max = 1, default = 0, flags = {.Automatable, .Stepped}},
	{id = SF_PARAM_ENV_SH, name = "S&H", min = 0, max = 1, default = 0, flags = {.Automatable, .Stepped}},
	{id = SF_PARAM_ENV_SH_DIVISION, name = "S&H Rate", min = 1, max = 12, default = 10, flags = {.Automatable, .Stepped}},
	{id = SF_PARAM_KEY_GAIN_DB, name = "Key Gain", unit = .Decibels, min = -24, max = 24, default = 0, flags = {.Automatable}},
	{id = SF_PARAM_CLIP, name = "Clip", min = 0, max = 1, default = 1, flags = {.Automatable, .Stepped}},
	{id = SF_PARAM_OUTPUT_DB, name = "Output", unit = .Decibels, min = -24, max = 24, default = 0, flags = {.Automatable}},
	{id = SF_PARAM_MIX, name = "Dry/Wet", unit = .Percent, min = 0, max = 1, default = 1, flags = {.Automatable}},
}

// The number of SuperFilter parameters (ids 1 to this).
SF_PARAMS :: len(super_filter_params)

// Settings for `super_filter_create`.
Super_Filter_Settings :: struct {
	timeline: core.Timeline_Id, // the timeline synced rates follow (zero: the transport's leader)
}

// What a SuperFilter is doing, for drawing it (`super_filter_readout`).
Super_Filter_Readout :: struct {
	cutoff_hz: [2]f32, // the modulated cutoff, each side, at the end of the last block
	lfo:       [2]f32, // the LFO, each side (-1..1)
	env:       f32,    // the envelope (0..1)
	in_peak:   f32,    // the last block's peak in (linear)
	out_peak:  f32,    // and out
}

// A SuperFilter's settings, by parameter id (index 0 unused).
Super_Filter_Values :: [SF_PARAMS + 1]f32

// SuperFilter's settings at their defaults.
super_filter_defaults :: proc "contextless" () -> (v: Super_Filter_Values) {
	for p in super_filter_params do v[p.id] = f32(p.default)
	return
}

// Control thread. The response of SuperFilter's filter stage at settings
// `v`, unmodulated: its impulse into `out` (an impulse of 0.25: the
// circuits that drive stay near their small-signal selves), with DJ's
// fade, the output gain and Dry/Wet (the clip left out), rendered at
// cutoff `at_hz` (0: its own). Returns its own cutoff (`base_hz`: the
// readout's `cutoff_hz` unmodulated) and the cutoff the shape rendered
// sits at (`anchor_hz`): the response at a modulated cutoff `c` is this
// one moved along the frequencies by `c / anchor_hz` (Vowel's formants
// follow no cutoff: its anchor is its own).
super_filter_impulse :: proc(v: ^Super_Filter_Values, out: []f32, sample_rate: f64, at_hz: f32 = 0) -> (base_hz, anchor_hz: f32) {
	typ := Sf_Type(clamp(int(v[SF_PARAM_TYPE]), 0, len(Sf_Type) - 1))
	freq := clamp(v[SF_PARAM_FREQ_HZ], 20, 20000)
	fp, cascade, dj_wet := sf_filter_params(v, typ, freq)
	base_hz = sf_base_hz(typ, freq)
	at := at_hz if at_hz > 0 else base_hz
	anchor_hz = base_hz if typ == .Vowel else at
	n := len(out)
	if n == 0 do return
	st := new([2]Filter_State, context.temp_allocator)
	cut := make([]f32, n, context.temp_allocator)
	for &c in cut do c = hz_key(at)
	for &x in out do x = 0
	out[0] = 0.25
	if cascade {
		first := fp
		first.resonance = 0
		filter_render_side(&st[1], &first, cut, out, sample_rate)
	}
	filter_render_side(&st[0], &fp, cut, out, sample_rate)
	g := math.pow(10, v[SF_PARAM_OUTPUT_DB] / 20)
	wet, dry := equal_power(clamp(v[SF_PARAM_MIX], 0, 1))
	for &y, i in out {
		x: f32 = 0.25 if i == 0 else 0
		if dj_wet < 1 do y = x + (y - x) * dj_wet
		y = wet * y * g + dry * x
	}
	return
}

// A SuperFilter node's state (from `super_filter_create`). Fields are
// internal.
Super_Filter :: struct {
	settings:    Super_Filter_Settings,
	values:      Super_Filter_Values,
	sample_rate: f64,
	frame:       i64, // frames taken in since the last reset (its 32-frame pieces line up with these)
	fill:        int, // frames of the piece being gathered
	gathered:    [4][PIECE]f32, // the piece coming in: left, right, key left, key right
	done:        [2][PIECE]f32, // the last piece, filtered: what goes out while the next comes in
	piece_clock: Beat_Clock, // the clock at the gathered piece's first frame
	lfo:         Lfo,
	follower:    Follower,
	filters:     ^[2][2]Filter_State, // a side each; the second for Clean at 24 dB
	scratch:     [8][]f32, // lfo l, lfo r, env, cut l, cut r, dry l, dry r, key
	glide:       [3]f32, // freq (a key), output gain, mix: where the last frame left them
	glide_set:   bool,
	readout:     [7]u32, // atomics: a `Super_Filter_Readout`'s floats, as bits
	pending:     [64]Sf_Change, // changes waiting for their piece (oldest first)
	pending_n:   int,
	allocator:   mem.Allocator,
}

// A parameter change and the frame (since reset) it takes effect at: the
// start of the piece it falls in, or the next, so it lands in the same
// place whatever the blocks.
@(private = "file")
Sf_Change :: struct {
	at:    i64,
	id:    core.Param_Id,
	value: f32,
}

// The frames the cutoff is filtered in: short enough that a fast LFO's
// curve is followed (the filter works its coefficients out at each
// piece's ends). Each piece is gathered whole before it is filtered, so
// any block size gives the same result: the node is late by one piece
// (its `latency`).
@(private = "file")
PIECE :: 32

@(private = "file")
super_filter_vtable := core.Node_VTable {
	name    = "fire.super_filter",
	prepare = super_filter_prepare,
	process = super_filter_process,
	reset   = proc(self: rawptr) {
		n := (^Super_Filter)(self)
		super_filter_clear(n)
	},
	release = proc(self: rawptr, allocator: mem.Allocator) {
		n := (^Super_Filter)(self)
		for s in n.scratch do delete(s, allocator)
		n.scratch = {}
		free(n.filters, allocator)
		n.filters = nil
	},
	params  = proc(self: rawptr) -> []core.Param_Info { return super_filter_params[:] },
	latency = proc(self: rawptr) -> int { return PIECE },
	destroy = proc(self: rawptr, allocator: mem.Allocator) { free((^Super_Filter)(self), allocator) },
}

// Control thread. A SuperFilter at its defaults. Add it to a graph with 2
// inputs and 2 outputs, or 4 inputs (the last two a sidechain key) and 2
// outputs.
super_filter_create :: proc(settings: Super_Filter_Settings, allocator := context.allocator) -> (node: core.Node, sf: ^Super_Filter) {
	sf = new(Super_Filter, allocator)
	sf.settings, sf.allocator = settings, allocator
	for p in super_filter_params do sf.values[p.id] = f32(p.default)
	return core.node_make(&super_filter_vtable, sf, allocator), sf
}

// Any thread. What SuperFilter `sf` is doing (as of its last block).
super_filter_readout :: proc "contextless" (sf: ^Super_Filter) -> Super_Filter_Readout {
	r: [7]f32
	for &v, k in r do v = transmute(f32)intrinsics.atomic_load_explicit(&sf.readout[k], .Relaxed)
	return {cutoff_hz = {r[0], r[1]}, lfo = {r[2], r[3]}, env = r[4], in_peak = r[5], out_peak = r[6]}
}

@(private = "file")
super_filter_prepare :: proc(self: rawptr, cfg: core.Prepare_Config, allocator: mem.Allocator) -> core.Error {
	n := (^Super_Filter)(self)
	n.sample_rate = cfg.sample_rate
	if n.filters == nil {
		ae: mem.Allocator_Error
		n.filters, ae = new([2][2]Filter_State, allocator)
		if ae != nil do return .Out_Of_Memory
	}
	for &s in n.scratch {
		if len(s) >= PIECE do continue
		ae: mem.Allocator_Error
		s, ae = make([]f32, PIECE, allocator)
		if ae != nil do return .Out_Of_Memory
	}
	super_filter_clear(n)
	return .None
}

// [rt] Back to silence: the filters, the LFO, the follower.
@(private = "file")
super_filter_clear :: proc "contextless" (n: ^Super_Filter) {
	if n.filters != nil do n.filters^ = {}
	seed := n.lfo.seed
	n.lfo = {seed = seed}
	n.follower = {}
	n.frame, n.glide_set, n.fill = 0, false, 0
	n.gathered, n.done = {}, {}
	for c in n.pending[:n.pending_n] do n.values[c.id] = c.value
	n.pending_n = 0
}

@(private = "file")
super_filter_process :: proc(self: rawptr, ctx: ^core.Process_Context) {
	n := (^Super_Filter)(self)
	for ev in ctx.events_in {
		id, value, _, ok := sf_param_event(ev.payload)
		if !ok || int(id) < 1 || int(id) > SF_PARAMS do continue
		info := super_filter_params[id - 1]
		at := n.frame + i64(ev.offset)
		at = (at + PIECE - 1) / PIECE * PIECE // (on the pieces' grid: block sizes don't move it)
		ch := Sf_Change{at, id, f32(clamp(value, info.min, info.max))}
		if n.pending_n == len(n.pending) { // (full: the oldest now)
			n.values[n.pending[0].id] = n.pending[0].value
			copy(n.pending[:], n.pending[1:])
			n.pending_n -= 1
		}
		n.pending[n.pending_n] = ch
		n.pending_n += 1
	}
	f := ctx.frames
	if len(ctx.outputs) < 2 || f <= 0 || n.filters == nil do return
	in_l, in_r := sf_input(ctx, 0, f), sf_input(ctx, 1, f)
	key_l, key_r := in_l, in_r
	if len(ctx.inputs) >= 4 do key_l, key_r = ctx.inputs[2][:f], ctx.inputs[3][:f]
	out := [2][]f32{ctx.outputs[0][:f], ctx.outputs[1][:f]}
	// The transport: where the timeline is and how fast it moves.
	tr := ctx.transport
	tl: ^core.Timeline_State
	if tr != nil {
		tl = core.transport_timeline(tr, n.settings.timeline)
		if tl == nil do tl = core.transport_timeline(tr, tr.leader)
	}
	// Gathered a piece at a time, each filtered whole once it is in; out
	// goes the piece before it, frame for frame.
	ins := [4][]f32{in_l, in_r, key_l, key_r}
	peak_in, peak_out: f32
	filtered := false
	for at := 0; at < f; {
		if n.fill == 0 do n.piece_clock = sf_clock(tr, tl, at, n.sample_rate)
		m := min(f - at, PIECE - n.fill)
		for ch in 0 ..< 4 do copy(n.gathered[ch][n.fill:n.fill + m], ins[ch][at:at + m])
		for ch in 0 ..< 2 do copy(out[ch][at:at + m], n.done[ch][n.fill:n.fill + m])
		n.fill += m
		n.frame += i64(m)
		at += m
		if n.fill < PIECE do continue
		n.fill = 0
		sf_apply(n, n.frame - PIECE) // (the changes due by the piece's first frame)
		g := &n.gathered
		pk_in, pk_out := sf_piece(n, n.piece_clock, {g[0][:], g[1][:]}, {g[2][:], g[3][:]}, {n.done[0][:], n.done[1][:]})
		peak_in, peak_out = max(peak_in, pk_in), max(peak_out, pk_out)
		filtered = true
	}
	if filtered {
		sf_publish(n, 5, peak_in)
		sf_publish(n, 6, peak_out)
	}
}

// [rt] Applies the pending changes due by frame `upto`, in order.
@(private = "file")
sf_apply :: proc "contextless" (n: ^Super_Filter, upto: i64) {
	k := 0
	for c in n.pending[:n.pending_n] {
		if c.at <= upto {
			n.values[c.id] = c.value
		} else {
			n.pending[k] = c
			k += 1
		}
	}
	n.pending_n = k
}

// [rt] Input `ch` (one input: both sides from it; none: silence, the
// output's own buffer zeroed).
@(private = "file")
sf_input :: proc "contextless" (ctx: ^core.Process_Context, ch, f: int) -> []f32 {
	if len(ctx.inputs) == 0 {
		o := ctx.outputs[ch][:f]
		for &x in o do x = 0
		return o
	}
	return ctx.inputs[min(ch, len(ctx.inputs) - 1)][:f]
}

// [rt] The clock `at` frames into the block (no transport: stopped at
// 120 BPM).
@(private = "file")
sf_clock :: proc "contextless" (tr: ^core.Transport, tl: ^core.Timeline_State, at: int, sample_rate: f64) -> Beat_Clock {
	if tr == nil do return {beats_per_frame = 2 / sample_rate, bar_beats = 4}
	bpm := core.transport_tempo_at(tr, at)
	if bpm <= 0 do bpm = 120
	c := Beat_Clock{beats_per_frame = bpm / 60 / sample_rate, bar_beats = 4}
	if tr.meter.numerator > 0 && tr.meter.denominator > 0 do c.bar_beats = f64(tr.meter.numerator) * 4 / f64(tr.meter.denominator)
	if tl != nil {
		c.playing = tl.playing
		c.beat = f64(core.timeline_position_at(tr, tl, at))
		c.beats_per_frame *= tl.rate if tl.playing && tl.rate > 0 else 1
		c.started = at == 0 && .Started in tl.flags
	}
	return c
}

// [rt] One piece (at most `PIECE` frames, within one of its slots): the
// LFO, the follower, the cutoffs, the filter, the output stage. Returns
// the peaks in and out.
@(private = "file")
sf_piece :: proc "contextless" (n: ^Super_Filter, clk: Beat_Clock, in_, key, out: [2][]f32) -> (peak_in, peak_out: f32) #no_bounds_check {
	m := len(in_[0])
	v := &n.values
	sr := n.sample_rate
	s := &n.scratch
	lfo := [2][]f32{s[0][:m], s[1][:m]}
	env, cut_l, cut_r, dry_l, dry_r, keyb := s[2][:m], s[3][:m], s[4][:m], s[5][:m], s[6][:m], s[7][:m]
	// The dry, kept (the output may be the input).
	copy(dry_l, in_[0])
	copy(dry_r, in_[1])
	for i in 0 ..< m do peak_in = max(peak_in, abs(dry_l[i]), abs(dry_r[i]))
	// The LFO.
	lp := Lfo_Params {
		wave = Lfo_Wave(clamp(int(v[SF_PARAM_LFO_WAVE]), 0, len(Lfo_Wave) - 1)),
		morph = v[SF_PARAM_LFO_MORPH],
		mode = Lfo_Mode(clamp(int(v[SF_PARAM_LFO_MODE]), 0, len(Lfo_Mode) - 1)),
		hz = v[SF_PARAM_LFO_RATE_HZ],
		division = int(v[SF_PARAM_LFO_DIVISION]),
		sixteenths = int(v[SF_PARAM_LFO_SIXTEENTHS]),
		stereo = Lfo_Stereo(clamp(int(v[SF_PARAM_LFO_STEREO]), 0, len(Lfo_Stereo) - 1)),
		phase_deg = v[SF_PARAM_LFO_PHASE_DEG],
		spin_hz = v[SF_PARAM_LFO_SPIN_HZ],
		offset_deg = v[SF_PARAM_LFO_OFFSET_DEG],
		retrigger = Lfo_Retrigger(clamp(int(v[SF_PARAM_LFO_RETRIGGER]), 0, len(Lfo_Retrigger) - 1)),
		smooth = v[SF_PARAM_LFO_SMOOTH],
	}
	lfo_render(&n.lfo, &lp, clk, lfo, sr)
	// The follower, on the key at its gain.
	fp := Follower_Params {
		attack_ms = v[SF_PARAM_ENV_ATTACK_MS],
		release_ms = v[SF_PARAM_ENV_RELEASE_MS],
		hold = v[SF_PARAM_ENV_HOLD] >= 0.5,
		sample_hold = v[SF_PARAM_ENV_SH] >= 0.5,
		division = int(v[SF_PARAM_ENV_SH_DIVISION]),
	}
	kg := math.pow(10, v[SF_PARAM_KEY_GAIN_DB] / 20)
	for i in 0 ..< m do keyb[i] = max(abs(key[0][i]), abs(key[1][i])) * kg
	follower_render(&n.follower, &fp, clk, {keyb, nil}, env, sr)
	// The cutoffs: the base (DJ: from its knob's place) moved in octaves.
	typ := Sf_Type(clamp(int(v[SF_PARAM_TYPE]), 0, len(Sf_Type) - 1))
	freq := clamp(v[SF_PARAM_FREQ_HZ], 20, 20000)
	fp_, cascade, dj_wet := sf_filter_params(&n.values, typ, freq)
	base := hz_key(sf_base_hz(typ, freq))
	if !n.glide_set {
		n.glide = {base, math.pow(10, v[SF_PARAM_OUTPUT_DB] / 20), v[SF_PARAM_MIX]}
		n.glide_set = true
	}
	la, ea := v[SF_PARAM_LFO_AMOUNT] * 60, v[SF_PARAM_ENV_AMOUNT] * 60 // (5 octaves: 60 semitones)
	lo_key, hi_key := hz_key(20), hz_key(20000)
	b0, db := n.glide[0], (base - n.glide[0]) / f32(m)
	for i in 0 ..< m {
		b := b0 + db * f32(i + 1)
		e := ea * env[i]
		cut_l[i] = clamp(b + la * lfo[0][i] + e, lo_key, hi_key)
		cut_r[i] = clamp(b + la * lfo[1][i] + e, lo_key, hi_key)
	}
	n.glide[0] = base
	// The filter, each side at its own cutoffs (Clean at 24 dB: twice).
	cuts := [2][]f32{cut_l, cut_r}
	for side in 0 ..< 2 {
		buf := out[side]
		copy(buf, dry_l if side == 0 else dry_r)
		sp := fp_
		// (The formants don't follow a cutoff: the modulation transposes them.)
		if typ == .Vowel do sp.formant_transpose = clamp(fp_.formant_transpose + cuts[side][m - 1] - base, -48, 48)
		if cascade {
			first := sp
			first.resonance = 0
			filter_render_side(&n.filters[side][1], &first, cuts[side], buf, sr)
		}
		filter_render_side(&n.filters[side][0], &sp, cuts[side], buf, sr)
	}
	// The output stage: DJ's middle (flat), the clip, the gain, dry/wet.
	clip := v[SF_PARAM_CLIP] >= 0.5
	g0, dg := n.glide[1], (math.pow(10, v[SF_PARAM_OUTPUT_DB] / 20) - n.glide[1]) / f32(m)
	w0, dw := n.glide[2], (v[SF_PARAM_MIX] - n.glide[2]) / f32(m)
	for i in 0 ..< m {
		g := g0 + dg * f32(i + 1)
		wet, dry := equal_power(w0 + dw * f32(i + 1))
		for side in 0 ..< 2 {
			x := (dry_l if side == 0 else dry_r)[i]
			y := out[side][i]
			if dj_wet < 1 do y = x + (y - x) * dj_wet
			if clip do y = soft_clip(y)
			y = wet * y * g + dry * x
			out[side][i] = y
			peak_out = max(peak_out, abs(y))
		}
	}
	n.glide[1], n.glide[2] = g0 + dg * f32(m), w0 + dw * f32(m)
	sf_publish(n, 0, key_to_hz(cut_l[m - 1]))
	sf_publish(n, 1, key_to_hz(cut_r[m - 1]))
	sf_publish(n, 2, lfo[0][m - 1])
	sf_publish(n, 3, lfo[1][m - 1])
	sf_publish(n, 4, env[m - 1])
	return
}

// [rt] The filter settings type `typ` makes (on the circuit, at the
// resonance, morph, slope and drive), whether Clean at 24 dB runs twice,
// and how much of the filter DJ lets through (0 at its middle: flat).
@(private = "file")
sf_filter_params :: proc "contextless" (v: ^Super_Filter_Values, typ: Sf_Type, freq: f32) -> (p: Filter_Params, cascade: bool, dj_wet: f32) {
	circuit := Sf_Circuit(clamp(int(v[SF_PARAM_CIRCUIT]), 0, len(Sf_Circuit) - 1))
	res := clamp(v[SF_PARAM_RESONANCE], 0, 1)
	morph := clamp(v[SF_PARAM_MORPH], 0, 1)
	steep := v[SF_PARAM_SLOPE] >= 0.5
	if !super_filter_circuit_has(circuit, typ) do circuit = .Analog
	p = FILTER_DEFAULTS
	p.model = SF_MODELS[circuit]
	p.resonance, p.drive_db, p.mix = res, clamp(v[SF_PARAM_DRIVE_DB], 0, 24), 1
	p.style = .Db24 if steep && circuit != .Clean else .Db12
	cascade = steep && circuit == .Clean
	dj_wet = 1
	if circuit == .Diode { // (a low-pass always, 24 dB)
		p.style, p.blend = .Db12, 0
		return
	}
	switch typ {
	case .Low:  p.blend = 0
	case .Band: p.blend = 1
	case .High: p.blend = 2
	case .Notch:
		p.style, p.blend, cascade = .Notch_Pass_Swap, 1, false
	case .Peak:
		p.style, p.blend, cascade = .Band_Peak_Notch, 1, false
	case .Morph:
		// Low → band → high over the first two thirds, then high → notch.
		if morph <= 2.0 / 3 {
			p.blend = morph * 3
		} else {
			p.style, p.blend, cascade = .Notch_Pass_Swap, 3 - (morph - 2.0 / 3) * 3, false
		}
	case .DJ:
		pos := sf_dj_pos(freq)
		p.blend = 0 if pos < 0.5 else 2
		dj_wet = clamp(abs(pos - 0.5) / 0.02, 0, 1) // (the middle: flat, faded in either side)
	case .Comb:
		p.model, p.style, cascade = .Comb, Filter_Style(0), false
		p.resonance, p.blend = morph, 1
	case .Vowel:
		p.model, p.style, cascade = .Formant, Filter_Style(0), false
		x, y := sf_vowel_xy(morph)
		p.formant_x, p.formant_y = x, y
		p.formant_transpose = clamp(12 * math.log2(freq / 1000), -24, 24)
		p.formant_resonance = 0.3 + 0.7 * res
	case .Phaser:
		p.model, p.style, cascade = .Phaser, .Db12, false
		p.blend = morph * 2
	}
	return
}

// Whether circuit `c` makes type `t`. Diode makes Low only (it is a
// four-pole low-pass, whatever its blend); Comb, Vowel and Phaser have no
// circuit (any is "yes"). A type a circuit doesn't make plays on Analog.
super_filter_circuit_has :: proc "contextless" (c: Sf_Circuit, t: Sf_Type) -> bool {
	if c != .Diode do return true
	#partial switch t {
	case .Low, .Comb, .Vowel, .Phaser: return true
	}
	return false
}

// Whether the slope (12 or 24 dB) means anything for type `t` on circuit
// `c`: Low, High, Band and Morph, but not on Diode (24 dB always).
super_filter_has_slope :: proc "contextless" (c: Sf_Circuit, t: Sf_Type) -> bool {
	#partial switch t {
	case .Low, .High, .Band, .Morph: return c != .Diode || !super_filter_circuit_has(c, t)
	}
	return false
}

// The `fx` filter model each circuit is.
@(private = "file")
SF_MODELS := [Sf_Circuit]Filter_Model{.Clean = .Digital, .Analog = .Analog, .Dirty = .Dirty, .Ladder = .Ladder, .Diode = .Diode}

// [rt] Where Freq sits along its knob (0..1, log from 20 Hz to 20 kHz):
// DJ's position.
@(private = "file")
sf_dj_pos :: #force_inline proc "contextless" (freq: f32) -> f32 {
	return clamp(math.log2(freq / 20) / math.log2(f32(1000)), 0, 1)
}

// [rt] The cutoff a type works from: Freq; DJ's from its knob's place
// (under the middle a low-pass from 20 kHz down to 20 Hz, over it a
// high-pass from 20 Hz up); Vowel's formants are set by their own (its
// cutoff unused, held at 1 kHz).
@(private = "file")
sf_base_hz :: proc "contextless" (typ: Sf_Type, freq: f32) -> f32 {
	#partial switch typ {
	case .DJ:
		pos := sf_dj_pos(freq)
		return 20 * math.pow(f32(1000), 1 - pos * 2) if pos < 0.5 else 20 * math.pow(f32(1000), (pos - 0.5) * 2)
	case .Vowel:
		return 1000
	}
	return freq
}

// [rt] The formant corners' place for Morph (0..1): A (0,0) → O (1,0) →
// E (1,1) → I (0,1).
@(private = "file")
sf_vowel_xy :: proc "contextless" (m: f32) -> (x, y: f32) {
	t := clamp(m, 0, 1) * 3
	switch {
	case t < 1: return t, 0
	case t < 2: return 1, t - 1
	}
	return 3 - t, 1
}

// [rt] A soft clip: straight to half scale, then bent smoothly to full
// scale and no further.
@(private = "file")
soft_clip :: #force_inline proc "contextless" (x: f32) -> f32 {
	a := abs(x)
	if a <= 0.5 do return x
	y := 0.5 + 0.5 * fast_tanh((a - 0.5) * 2)
	return y if x > 0 else -y
}

// [rt] Stores readout float `k`.
@(private = "file")
sf_publish :: #force_inline proc "contextless" (n: ^Super_Filter, k: int, v: f32) {
	intrinsics.atomic_store_explicit(&n.readout[k], transmute(u32)v, .Relaxed)
}

// [rt] A parameter change in an event (a value, or a ramp's target).
@(private = "file")
sf_param_event :: proc "contextless" (p: core.Event_Payload) -> (id: core.Param_Id, value: f64, ramp_frames: int, ok: bool) {
	#partial switch e in p {
	case core.Param_Value: return e.param, e.value, 0, true
	case core.Param_Ramp:  return e.param, e.target, 0, true
	}
	return
}
