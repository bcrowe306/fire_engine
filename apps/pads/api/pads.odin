package pads_api

import "core:strings"

import pm "../model"

// Pads there are (0 .. PADS-1: eight banks of sixteen).
PADS :: pm.PADS

// What a pad is.
Pad_Kind :: enum i32 {
	Sampler, // plays its sample (its region), pitched by key
	Audio,   // an audio track: records its input, plays its takes
	Slicer,  // its sample sliced, a slice on each key
	Synth,   // the wavetable synth
	Plugin,  // a CLAP instrument
}

// How a pad's sample plays when hit.
Pad_Mode :: enum i32 {
	One_Shot, // to the end, whatever the release
	Gate,     // while held
	Loop,     // loops while held
	Hold,     // loops until hit again (or choked)
}

// When a pad's input is heard.
Monitor :: enum i32 {
	Auto, // an audio track's while armed; any pad's while sampled into
	In,   // always
	Off,  // never
}

// Pad `pad` now (its name: `pad_name`).
Pad_State :: struct {
	used:    bool, // it has a sound (a sample, a synth, a plug-in, takes)
	kind:    Pad_Kind,
	mode:    Pad_Mode,
	color:   i64, // 0xRRGGBB
	volume:  f32, // dB
	pan:     f32, // -1..1
	pitch:   f32, // semitones
	mute:    bool,
	solo:    bool,
	choke:   i64, // its choke group (0: none; 1..6)
	bus:     i64, // where it plays (0: main; 1..16: a bus)
	armed:   bool, // to record (its input, or its MIDI)
	monitor: Monitor,
	frozen:  bool, // it plays its rendering
}

// Pad `pad` now. Not_Found out of 0..PADS-1.
pad_state :: proc(api: ^Api, pad: i64) -> (Pad_State, Result) {
	p, r := pad_of(api, pad)
	if r != .Ok do return {}, r
	m := &api.core.m
	return {
		used = pm.pad_used(&m.project, int(pad)), kind = Pad_Kind(p.kind), mode = Pad_Mode(p.mode), color = i64(p.color),
		volume = p.volume, pan = p.pan, pitch = p.pitch, mute = p.mute, solo = p.solo, choke = i64(p.choke), bus = i64(p.bus),
		armed = pm.track_armed(m, int(pad)), monitor = Monitor(p.monitor), frozen = p.frozen,
	}, .Ok
}

// Pad `pad`'s name: its own, else its sound's ("" for an empty pad).
// Temporary.
pad_name :: proc(api: ^Api, pad: i64) -> (string, Result) {
	p, r := pad_of(api, pad)
	if r != .Ok do return "", r
	return strings.clone(pm.pad_name(p), context.temp_allocator), .Ok
}

// Pad `pad`'s label as the pads show it ("A1"..."H16"). Temporary.
pad_label :: proc(api: ^Api, pad: i64) -> (string, Result) {
	if _, r := pad_of(api, pad); r != .Ok do return "", r
	return pm.pad_label(int(pad)), .Ok
}

// Names pad `pad` (up to 31 bytes; "": its sound's name again), undoably.
pad_set_name :: proc(api: ^Api, pad: i64, name: string) -> Result {
	p, r := pad_of(api, pad)
	if r != .Ok do return r
	if len(name) > 31 do return fail(api, .Invalid_Argument, "a pad's name is up to 31 bytes")
	n := p^
	pm.set_pad_name(&n, name)
	return set_pad(api, pad, .Name, "Rename Pad", n)
}

// Colours pad `pad` (0xRRGGBB), undoably.
pad_set_color :: proc(api: ^Api, pad: i64, color: i64) -> Result {
	p, r := pad_of(api, pad)
	if r != .Ok do return r
	if color < 0 || color > 0xffffff do return fail(api, .Invalid_Argument, "a colour is 0xRRGGBB")
	n := p^
	n.color = u32(color)
	return set_pad(api, pad, .Color, "Set Color", n)
}

// How pad `pad`'s sample plays when hit, undoably.
pad_set_mode :: proc(api: ^Api, pad: i64, mode: Pad_Mode) -> Result {
	p, r := pad_of(api, pad)
	if r != .Ok do return r
	if mode < min(Pad_Mode) || mode > max(Pad_Mode) do return fail(api, .Invalid_Argument, "no such mode")
	n := p^
	n.mode = pm.Pad_Mode(mode)
	return set_pad(api, pad, .Mode, "Set Mode", n)
}

// Pad `pad`'s fader (-60..6 dB), undoably (a gesture's moves merge).
pad_set_volume :: proc(api: ^Api, pad: i64, db: f32) -> Result {
	p, r := pad_of(api, pad)
	if r != .Ok do return r
	if !(db >= -60 && db <= 6) do return fail(api, .Invalid_Argument, "a pad's volume is -60..6 dB")
	n := p^
	n.volume = db
	return set_pad(api, pad, .Volume, "Set Volume", n)
}

// Pad `pad`'s pan (-1 left .. 1 right), undoably.
pad_set_pan :: proc(api: ^Api, pad: i64, pan: f32) -> Result {
	p, r := pad_of(api, pad)
	if r != .Ok do return r
	if !(pan >= -1 && pan <= 1) do return fail(api, .Invalid_Argument, "pan is -1..1")
	n := p^
	n.pan = pan
	return set_pad(api, pad, .Pan, "Set Pan", n)
}

// Pad `pad`'s transpose (-24..24 semitones), undoably.
pad_set_pitch :: proc(api: ^Api, pad: i64, semitones: f32) -> Result {
	p, r := pad_of(api, pad)
	if r != .Ok do return r
	if !(semitones >= -24 && semitones <= 24) do return fail(api, .Invalid_Argument, "a pad's pitch is -24..24 semitones")
	n := p^
	n.pitch = semitones
	return set_pad(api, pad, .Pitch, "Set Pitch", n)
}

// Mutes pad `pad` or not, undoably.
pad_set_mute :: proc(api: ^Api, pad: i64, on: bool) -> Result {
	p, r := pad_of(api, pad)
	if r != .Ok do return r
	n := p^
	n.mute = on
	return set_pad(api, pad, .Mute, "Mute", n)
}

// Solos pad `pad` or not, undoably.
pad_set_solo :: proc(api: ^Api, pad: i64, on: bool) -> Result {
	p, r := pad_of(api, pad)
	if r != .Ok do return r
	n := p^
	n.solo = on
	return set_pad(api, pad, .Solo, "Solo", n)
}

// Puts pad `pad` in choke group `group` (1..6; 0: none): a pad of the group
// hit silences the others. Undoably.
pad_set_choke :: proc(api: ^Api, pad: i64, group: i64) -> Result {
	p, r := pad_of(api, pad)
	if r != .Ok do return r
	if group < 0 || group > pm.CHOKE_GROUPS do return fail(api, .Invalid_Argument, "a choke group is 1..6 (0: none)")
	n := p^
	n.choke = u8(group)
	return set_pad(api, pad, .Choke, "Set Choke Group", n)
}

// When pad `pad`'s input is heard, undoably.
pad_set_monitor :: proc(api: ^Api, pad: i64, monitor: Monitor) -> Result {
	p, r := pad_of(api, pad)
	if r != .Ok do return r
	if monitor < min(Monitor) || monitor > max(Monitor) do return fail(api, .Invalid_Argument, "no such monitoring")
	n := p^
	n.monitor = pm.Monitor(monitor)
	return set_pad(api, pad, .Monitor, "Monitor", n)
}

// Makes pad `pad` a `kind`: a sampler (a slicer's slices kept), a slicer
// (of its sample, or empty), the synth, or an audio track. Undoably.
// Unsupported for Plugin (load one: devices).
pad_set_kind :: proc(api: ^Api, pad: i64, kind: Pad_Kind) -> Result {
	p, r := pad_of(api, pad)
	if r != .Ok do return r
	m := &api.core.m
	i := int(pad)
	switch kind {
	case .Sampler:
		if p.kind == .Slicer do pm.make_sampler(m, i)
		else do pm.set_pad_kind(m, i, .Sampler)
	case .Slicer:
		if p.kind == .Slicer do return .Ok
		if p.kind == .Audio do return fail(api, .Unsupported, "an audio track can't be a slicer")
		if pm.pad_used(&m.project, i) do pm.make_slicer(m, i)
		else do pm.empty_slicer(m, i)
	case .Synth:
		if p.kind == .Synth do return .Ok
		if p.kind == .Audio do return fail(api, .Unsupported, "an audio track can't be a synth")
		pm.make_synth(m, i)
	case .Audio:
		pm.set_pad_kind(m, i, .Audio)
	case .Plugin:
		return fail(api, .Unsupported, "a plug-in pad is made by loading a plug-in onto it")
	case:
		return fail(api, .Invalid_Argument, "no such kind")
	}
	edited(api)
	return .Ok
}

// Loads the audio file at `path` onto pad `pad` (a sampler pad's sample),
// undoably. Io_Error if it can't be read.
pad_load_sample :: proc(api: ^Api, pad: i64, path: string) -> Result {
	if _, r := pad_of(api, pad); r != .Ok do return r
	if pm.load_onto_pad(&api.core.m, int(pad), path) != .None do return failf(api, .Io_Error, "could not load ", path)
	edited(api)
	return .Ok
}

// Clears pad `pad` (its sound, its settings), undoably.
pad_clear :: proc(api: ^Api, pad: i64) -> Result {
	if _, r := pad_of(api, pad); r != .Ok do return r
	pm.clear_pad(&api.core.m, int(pad))
	edited(api)
	return .Ok
}

// Copies pad `pad` onto the next empty pad after it: which one. Not_Found
// if none is empty.
pad_duplicate :: proc(api: ^Api, pad: i64) -> (i64, Result) {
	if _, r := pad_of(api, pad); r != .Ok do return -1, r
	to := pm.duplicate_pad(&api.core.m, int(pad))
	if to < 0 do return -1, fail(api, .Not_Found, "no empty pad after it")
	edited(api)
	return i64(to), .Ok
}

// Copies pad `from` onto pad `to` (all of it: its sound and settings),
// undoably.
pad_copy_to :: proc(api: ^Api, from, to: i64) -> Result {
	p, r := pad_of(api, from)
	if r != .Ok do return r
	if _, r2 := pad_of(api, to); r2 != .Ok do return r2
	return set_pad(api, to, .Whole, "Paste Pad", p^)
}

// Plays pad `pad` (`on`) or lets it go, at `velocity` (0..1], as a hit
// on it does (its mode, its choke group).
pad_play :: proc(api: ^Api, pad: i64, on: bool, velocity: f32 = 1) -> Result {
	if _, r := pad_of(api, pad); r != .Ok do return r
	if on && !(velocity > 0 && velocity <= 1) do return fail(api, .Invalid_Argument, "velocity is 0..1")
	pm.hit(&api.core.m.engine, int(pad), on, velocity)
	return .Ok
}

// Arms pad `pad` to record (or not): an audio track records its input, any
// other pad what its MIDI input plays.
pad_set_armed :: proc(api: ^Api, pad: i64, on: bool) -> Result {
	if _, r := pad_of(api, pad); r != .Ok do return r
	pm.arm_track(&api.core.m, int(pad), on)
	return .Ok
}

// Where a pad's audio input comes from.
Input_From :: enum i32 {
	Interface, // the interface's input channels
	Pad,       // another track's output (after its fader)
	Bus,       // a bus's output
	Main,      // main's output (all that's heard, but the click)
	None,      // nothing: it records and monitors nothing
}

// A pad's audio input: what an audio track records, and a sample is
// recorded from.
Pad_Input :: struct {
	from:    Input_From,
	channel: i64,  // Interface: its first channel (0: input 1)
	stereo:  bool, // Interface: it and the next (1/2, 3/4...)
	source:  i64,  // Pad: the pad; Bus: the bus
}

// Pad `pad`'s audio input.
pad_input :: proc(api: ^Api, pad: i64) -> (Pad_Input, Result) {
	p, r := pad_of(api, pad)
	if r != .Ok do return {}, r
	x := p.input
	return {from = Input_From(x.from), channel = i64(x.channel), stereo = x.stereo, source = i64(x.source)}, .Ok
}

// Sets pad `pad`'s audio input, undoably.
pad_set_input :: proc(api: ^Api, pad: i64, input: Pad_Input) -> Result {
	p, r := pad_of(api, pad)
	if r != .Ok do return r
	x := input
	if x.from < min(Input_From) || x.from > max(Input_From) || x.channel < 0 || x.channel > 63 do return fail(api, .Invalid_Argument, "no such input, or a channel 0..63")
	if x.from == .Pad && (x.source < 0 || x.source >= PADS || x.source == pad) do return fail(api, .Invalid_Argument, "another pad 0..127")
	if x.from == .Bus && (x.source < 0 || x.source >= pm.BUSES) do return fail(api, .Invalid_Argument, "a bus 0..15")
	n := p^
	n.input = {from = pm.Input_From(x.from), channel = u8(x.channel), stereo = x.stereo, source = u8(x.source)}
	return set_pad(api, pad, .Input, "Set Input", n)
}

@(private)
pad_of :: proc(api: ^Api, pad: i64) -> (^pm.Pad, Result) {
	if pad < 0 || pad >= PADS do return nil, fail(api, .Not_Found, "a pad is 0..127")
	return &api.core.m.project.pads[pad], .Ok
}

@(private)
set_pad :: proc(api: ^Api, pad: i64, field: pm.Pad_Field, name: string, n: pm.Pad) -> Result {
	pm.set_pad(&api.core.m, int(pad), field, name, n)
	edited(api)
	return .Ok
}
