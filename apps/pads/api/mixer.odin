package pads_api

import "core:math"
import "core:strings"

import pm "../model"

// Buses there may be (0..BUSES-1). Main is the bus numbered MAIN.
BUSES :: pm.BUSES
// Main, where a bus number is asked for.
MAIN :: pm.BUSES

// Where a pad or a bus plays.
Output_Kind :: enum i32 {
	Main,
	Bus,  // bus `index` (0..15)
	Pair, // the interface's output pair `index` (0: outputs 1/2)
}

// Where a pad or a bus plays.
Output :: struct {
	kind:  Output_Kind,
	index: i64,
}

// The mixer now.
Mixer_State :: struct {
	buses:     i64, // buses in use (0..buses-1)
	total_latency: i64, // frames the whole mix runs behind (compensated)
}

// Bus `bus` (0..buses-1, or MAIN) now (its name: mixer_bus_name).
Bus_State :: struct {
	volume: f32, // dB
	pan:    f32, // -1..1
	mute:   bool,
	solo:   bool, // (main: never)
	group:  bool, // a group: the pads going to it show with it
	folded: bool, // a group whose pads' strips are hidden
	output: Output, // where it goes (main: its own outputs)
	cue_db: f32,  // its send to the cue mix (-60: off)
	cue_pre: bool,
}

// A meter's reading now (linear: 1 is full scale).
Meter :: struct {
	peak_l: f32,
	peak_r: f32,
	rms_l:  f32,
	rms_r:  f32,
}

// Main's loudness (EBU R128) and its stereo.
Loudness :: struct {
	momentary:    f32, // LUFS
	short_term:   f32, // LUFS
	integrated:   f32, // LUFS (since the last reset)
	true_peak_db: f32, // dBTP
	correlation:  f32, // -1..1 (1: mono)
}

// The mixer now.
mixer_state :: proc(api: ^Api) -> (Mixer_State, Result) {
	return {buses = i64(api.core.m.project.bus_count), total_latency = i64(pm.total_latency(&api.core.m.engine))}, .Ok
}

// Bus `bus` (or MAIN) now.
mixer_bus_state :: proc(api: ^Api, bus: i64) -> (Bus_State, Result) {
	if r := bus_ok(api, bus); r != .Ok do return {}, r
	b := pm.bus_of(&api.core.m, int(bus))
	s := Bus_State{volume = b.volume, pan = b.pan, mute = b.mute, solo = b.solo, group = b.group, folded = b.folded, cue_db = pm.send_db(b.cue), cue_pre = b.cue.pre}
	if bus != MAIN do s.output = output_of(int(b.dest))
	return s, .Ok
}

// Bus `bus`'s name ("Bus A", its own, "Main"). Temporary.
mixer_bus_name :: proc(api: ^Api, bus: i64) -> (string, Result) {
	if r := bus_ok(api, bus); r != .Ok do return "", r
	return strings.clone(pm.bus_index_name(&api.core.m.project, int(bus)), context.temp_allocator), .Ok
}

// Adds a bus (after the others, going to main): its number. Busy when
// there are 16.
mixer_add_bus :: proc(api: ^Api) -> (i64, Result) {
	b := pm.add_bus(&api.core.m)
	if b == 0 do return -1, fail(api, .Busy, "there are 16 buses already")
	edited(api)
	return i64(b - 1), .Ok
}

// Deletes bus `bus`: what went to it goes to main, its sends go, the buses
// after it move up. One undo step. Busy for the last bus left.
mixer_delete_bus :: proc(api: ^Api, bus: i64) -> Result {
	if r := bus_ok(api, bus, main_ok = false); r != .Ok do return r
	if api.core.m.project.bus_count <= 1 do return fail(api, .Busy, "a project keeps one bus at least")
	pm.delete_bus(&api.core.m, int(bus) + 1)
	edited(api)
	return .Ok
}

// Names bus `bus` (up to 15 bytes; "": its letter again), undoably.
mixer_rename_bus :: proc(api: ^Api, bus: i64, name: string) -> Result {
	if r := bus_ok(api, bus, main_ok = false); r != .Ok do return r
	if len(strings.trim_space(name)) > 15 do return fail(api, .Invalid_Argument, "a bus's name is up to 15 bytes")
	pm.rename_bus(&api.core.m, int(bus) + 1, name)
	return .Ok
}

// Sends bus `bus` to `output`, undoably. Invalid_Argument if that goes
// round in a loop (to itself, or through buses back to it).
mixer_set_bus_output :: proc(api: ^Api, bus: i64, output: Output) -> Result {
	if r := bus_ok(api, bus, main_ok = false); r != .Ok do return r
	d, r := dest_of(api, output)
	if r != .Ok do return r
	if !pm.set_bus_dest(&api.core.m, int(bus) + 1, d) do return fail(api, .Invalid_Argument, "that would go round in a loop")
	return .Ok
}

// Sends pad `pad` to `output` (main, a bus, an output pair), undoably.
mixer_set_pad_output :: proc(api: ^Api, pad: i64, output: Output) -> Result {
	if _, r := pad_of(api, pad); r != .Ok do return r
	d, r := dest_of(api, output)
	if r != .Ok do return r
	pm.set_pad_bus(&api.core.m, int(pad), d)
	return .Ok
}

// Where pad `pad` plays.
mixer_pad_output :: proc(api: ^Api, pad: i64) -> (Output, Result) {
	p, r := pad_of(api, pad)
	if r != .Ok do return {}, r
	return output_of(int(p.bus)), .Ok
}

// Mutes bus `bus` (or MAIN) or not, undoably.
mixer_set_bus_mute :: proc(api: ^Api, bus: i64, on: bool) -> Result {
	if r := bus_ok(api, bus); r != .Ok do return r
	b := pm.bus_of(&api.core.m, int(bus))^
	b.mute = on
	pm.set_bus(&api.core.m, int(bus), 1, "Mute", b)
	edited(api)
	return .Ok
}

// Solos bus `bus` or not, undoably. Unsupported for main.
mixer_set_bus_solo :: proc(api: ^Api, bus: i64, on: bool) -> Result {
	if r := bus_ok(api, bus); r != .Ok do return r
	if bus == MAIN do return fail(api, .Unsupported, "main isn't soloed")
	b := pm.bus_of(&api.core.m, int(bus))^
	b.solo = on
	pm.set_bus(&api.core.m, int(bus), 1, "Solo", b)
	edited(api)
	return .Ok
}

// Sets bus `bus`'s (or MAIN's) fader (-60..6 dB): param_set on its Volume.
mixer_set_bus_volume :: proc(api: ^Api, bus: i64, db: f32) -> Result {
	if r := bus_ok(api, bus); r != .Ok do return r
	return param_set(api, bus_ref(bus, .Volume), f64(db))
}

// Sets bus `bus`'s (or MAIN's) pan (-1..1): param_set on its Pan.
mixer_set_bus_pan :: proc(api: ^Api, bus: i64, pan: f32) -> Result {
	if r := bus_ok(api, bus); r != .Ok do return r
	return param_set(api, bus_ref(bus, .Pan), f64(pan))
}

// Groups pads `pads` under a new group bus named `name` ("": "Group N"),
// going where the first went: the bus. One undo step. Busy when there are
// 16 buses.
mixer_group_pads :: proc(api: ^Api, pads: []i64, name: string) -> (i64, Result) {
	if len(pads) == 0 do return -1, fail(api, .Invalid_Argument, "no pads to group")
	ps := make([]int, len(pads), context.temp_allocator)
	for p, k in pads {
		if _, r := pad_of(api, p); r != .Ok do return -1, r
		ps[k] = int(p)
	}
	b := pm.group_pads(&api.core.m, ps, name)
	if b == 0 do return -1, fail(api, .Busy, "there are 16 buses already")
	edited(api)
	return i64(b - 1), .Ok
}

// Ungroups group bus `bus`: its pads go where it went, and it goes. One
// undo step. Invalid_Argument for a bus that isn't a group.
mixer_ungroup :: proc(api: ^Api, bus: i64) -> Result {
	if r := bus_ok(api, bus, main_ok = false); r != .Ok do return r
	if !api.core.m.project.buses[bus].group do return fail(api, .Invalid_Argument, "that bus isn't a group")
	pm.ungroup(&api.core.m, int(bus) + 1)
	edited(api)
	return .Ok
}

// Folds group bus `bus`'s pads away in the Mixer, or shows them (a view:
// saved, not undone).
mixer_set_group_folded :: proc(api: ^Api, bus: i64, folded: bool) -> Result {
	if r := bus_ok(api, bus, main_ok = false); r != .Ok do return r
	if !api.core.m.project.buses[bus].group do return fail(api, .Invalid_Argument, "that bus isn't a group")
	pm.set_group_folded(&api.core.m, int(bus) + 1, folded)
	return .Ok
}

// Sets pad `pad`'s send to the cue mix (a performer's headphones): `db`
// (-60: off; up to 6), before its fader (`pre`) or after. Undoably.
mixer_set_pad_cue :: proc(api: ^Api, pad: i64, db: f32, pre: bool) -> Result {
	if _, r := pad_of(api, pad); r != .Ok do return r
	if !(db >= pm.SEND_MIN_DB && db <= 6) do return fail(api, .Invalid_Argument, "a cue send is -60..6 dB")
	pm.set_pad_cue(&api.core.m, int(pad), {level = pm.send_level(db), pre = pre})
	edited(api)
	return .Ok
}

// Sets bus `bus`'s send to the cue mix (as `mixer_set_pad_cue`). Not main.
mixer_set_bus_cue :: proc(api: ^Api, bus: i64, db: f32, pre: bool) -> Result {
	if r := bus_ok(api, bus, main_ok = false); r != .Ok do return r
	if !(db >= pm.SEND_MIN_DB && db <= 6) do return fail(api, .Invalid_Argument, "a cue send is -60..6 dB")
	pm.set_bus_cue(&api.core.m, int(bus), {level = pm.send_level(db), pre = pre})
	edited(api)
	return .Ok
}

// Pad `pad`'s meter now (after its fader). Poll it: it isn't reported.
mixer_pad_meter :: proc(api: ^Api, pad: i64) -> (Meter, Result) {
	if _, r := pad_of(api, pad); r != .Ok do return {}, r
	pk, rms := pm.pad_level(&api.core.m.engine, int(pad))
	return meter(pk, rms), .Ok
}

// Bus `bus`'s (or MAIN's) meter now.
mixer_bus_meter :: proc(api: ^Api, bus: i64) -> (Meter, Result) {
	if r := bus_ok(api, bus); r != .Ok do return {}, r
	pk, rms := pm.bus_level(&api.core.m.engine, int(bus))
	return meter(pk, rms), .Ok
}

// The cue mix's meter now.
mixer_cue_meter :: proc(api: ^Api) -> (Meter, Result) {
	pk, rms := pm.cue_level(&api.core.m.engine)
	return meter(pk, rms), .Ok
}

// The interface's input pair `pair`'s meter now (0: inputs 1/2).
mixer_input_meter :: proc(api: ^Api, pair: i64) -> (Meter, Result) {
	if pair < 0 || pair >= pm.MAX_INPUTS / 2 do return {}, fail(api, .Not_Found, "an input pair is 0..15")
	pk, rms := pm.input_level(&api.core.m.engine, int(pair))
	return meter(pk, rms), .Ok
}

// Main's loudness and stereo now.
mixer_loudness :: proc(api: ^Api) -> (Loudness, Result) {
	e := &api.core.m.engine
	mo, st, it, tp := pm.main_loudness(e)
	c, _ := pm.main_stereo(e, nil)
	return {momentary = mo, short_term = st, integrated = it, true_peak_db = f32(20 * math.log10(max(f64(tp), 1e-9))), correlation = c}, .Ok
}

// Starts main's integrated loudness and true peak again.
mixer_loudness_reset :: proc(api: ^Api) -> Result {
	pm.main_loudness_reset(&api.core.m.engine)
	return .Ok
}

// Frames pad `pad`'s inserts delay it (the others are delayed to match).
mixer_pad_latency :: proc(api: ^Api, pad: i64) -> (i64, Result) {
	if _, r := pad_of(api, pad); r != .Ok do return 0, r
	return i64(pm.track_latency(&api.core.m.engine, int(pad))), .Ok
}

@(private)
bus_ok :: proc(api: ^Api, bus: i64, main_ok := true) -> Result {
	if bus == MAIN {
		if !main_ok do return fail(api, .Unsupported, "not for main")
		return .Ok
	}
	if bus < 0 || bus >= i64(api.core.m.project.bus_count) do return fail(api, .Not_Found, "no such bus (0..buses-1, or MAIN)")
	return .Ok
}

@(private)
bus_ref :: proc(bus: i64, d: Device) -> Param_Ref {
	if bus == MAIN do return {track = .Main, device = d}
	return {track = .Bus, index = bus, device = d}
}

// The model's route number for `o` (0 main, 1..16 a bus, OUT_DEST + k a pair).
@(private)
dest_of :: proc(api: ^Api, o: Output) -> (int, Result) {
	switch o.kind {
	case .Main: return 0, .Ok
	case .Bus:
		if o.index < 0 || o.index >= i64(api.core.m.project.bus_count) do return 0, fail(api, .Not_Found, "no such bus")
		return int(o.index) + 1, .Ok
	case .Pair:
		if o.index < 0 || o.index >= pm.OUT_PAIRS do return 0, fail(api, .Not_Found, "an output pair is 0..31")
		return pm.out_dest(int(o.index)), .Ok
	}
	return 0, fail(api, .Invalid_Argument, "no such output")
}

@(private)
output_of :: proc(d: int) -> Output {
	if pm.is_out_dest(d) do return {kind = .Pair, index = i64(d - pm.OUT_DEST)}
	if d >= 1 && d <= pm.BUSES do return {kind = .Bus, index = i64(d - 1)}
	return {kind = .Main}
}

@(private)
meter :: proc(pk, rms: [2]f32) -> Meter {
	return {peak_l = pk[0], peak_r = pk[1], rms_l = rms[0], rms_r = rms[1]}
}
