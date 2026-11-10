package dsp

import "core:mem"

import "fire:core"

// Saved-state ID of `gain_create` nodes (see `register_types`).
GAIN_TYPE_ID :: "fire.gain"
// Saved-state ID of `one_pole_create` nodes.
ONE_POLE_TYPE_ID :: "fire.one_pole"
// Saved-state ID of `filter_create` nodes.
FILTER_TYPE_ID :: "fire.filter"
// Saved-state ID of `eq_create` nodes.
EQ_TYPE_ID :: "fire.eq"
// Saved-state ID of chorus, flanger and phaser nodes (the kind is saved).
MODULATION_TYPE_ID :: "fire.modulation"
// Saved-state ID of `reverb_create` nodes.
REVERB_TYPE_ID :: "fire.reverb"
// Saved-state ID of `delay_create` nodes.
DELAY_TYPE_ID :: "fire.delay"
// Saved-state ID of `gate_create` nodes.
GATE_TYPE_ID :: "fire.gate"
// Saved-state ID of `compressor_create` nodes.
COMPRESSOR_TYPE_ID :: "fire.compressor"
// Saved-state ID of `limiter_create` nodes.
LIMITER_TYPE_ID :: "fire.limiter"
// Saved-state ID of `saturation_create` nodes.
SATURATION_TYPE_ID :: "fire.saturation"
// Saved-state ID of `synth_create` nodes.
SYNTH_TYPE_ID :: "fire.synth"
// Saved-state ID of `convolution_create` nodes (the impulse response is saved).
CONVOLUTION_TYPE_ID :: "fire.convolution"

// Registers every node type of this package, so saved state can name them.
// Control thread.
register_types :: proc(reg: ^core.Node_Registry) -> core.Error {
	types := [?]core.Node_Type {
		{id = GAIN_TYPE_ID, load = proc(_: rawptr, r: ^core.State_Reader, v: u32, ctx: ^core.Load_Context, a: mem.Allocator) -> (core.Node, core.Error) {
			return gain_create(a), .None
		}},
		{id = ONE_POLE_TYPE_ID, load = proc(_: rawptr, r: ^core.State_Reader, v: u32, ctx: ^core.Load_Context, a: mem.Allocator) -> (core.Node, core.Error) {
			return one_pole_create(a), .None
		}},
		{id = FILTER_TYPE_ID, load = proc(_: rawptr, r: ^core.State_Reader, v: u32, ctx: ^core.Load_Context, a: mem.Allocator) -> (core.Node, core.Error) {
			mode := core.read_u8(r)
			if int(mode) > int(max(Filter_Mode)) do return {}, .Invalid_Data
			return filter_create(Filter_Mode(mode), a), .None
		}},
		{id = EQ_TYPE_ID, load = proc(_: rawptr, r: ^core.State_Reader, v: u32, ctx: ^core.Load_Context, a: mem.Allocator) -> (core.Node, core.Error) {
			return eq_create(core.read_int(r), a), .None
		}},
		{id = MODULATION_TYPE_ID, load = proc(_: rawptr, r: ^core.State_Reader, v: u32, ctx: ^core.Load_Context, a: mem.Allocator) -> (core.Node, core.Error) {
			switch Mod_Kind(core.read_u8(r)) {
			case .Chorus:  return chorus_create(a), .None
			case .Flanger: return flanger_create(a), .None
			case .Phaser:  return phaser_create(a), .None
			}
			return {}, .Invalid_Data
		}},
		{id = REVERB_TYPE_ID, load = proc(_: rawptr, r: ^core.State_Reader, v: u32, ctx: ^core.Load_Context, a: mem.Allocator) -> (core.Node, core.Error) {
			return reverb_create(a), .None
		}},
		{id = DELAY_TYPE_ID, load = proc(_: rawptr, r: ^core.State_Reader, v: u32, ctx: ^core.Load_Context, a: mem.Allocator) -> (core.Node, core.Error) {
			return delay_create(a), .None
		}},
		{id = GATE_TYPE_ID, load = proc(_: rawptr, r: ^core.State_Reader, v: u32, ctx: ^core.Load_Context, a: mem.Allocator) -> (core.Node, core.Error) {
			return gate_create(a), .None
		}},
		{id = COMPRESSOR_TYPE_ID, load = proc(_: rawptr, r: ^core.State_Reader, v: u32, ctx: ^core.Load_Context, a: mem.Allocator) -> (core.Node, core.Error) {
			return compressor_create(a), .None
		}},
		{id = LIMITER_TYPE_ID, load = proc(_: rawptr, r: ^core.State_Reader, v: u32, ctx: ^core.Load_Context, a: mem.Allocator) -> (core.Node, core.Error) {
			return limiter_create(core.read_f64(r), a), .None
		}},
		{id = SATURATION_TYPE_ID, load = proc(_: rawptr, r: ^core.State_Reader, v: u32, ctx: ^core.Load_Context, a: mem.Allocator) -> (core.Node, core.Error) {
			return saturation_create(core.read_int(r), a), .None
		}},
		{id = SYNTH_TYPE_ID, load = proc(_: rawptr, r: ^core.State_Reader, v: u32, ctx: ^core.Load_Context, a: mem.Allocator) -> (core.Node, core.Error) {
			return synth_create(core.read_int(r), a), .None
		}},
		{id = CONVOLUTION_TYPE_ID, load = load_convolution},
	}
	for t in types do core.register_type(reg, t) or_return
	return .None
}

@(private)
save_filter :: proc(self: rawptr, w: ^core.State_Writer, ctx: ^core.Save_Context) -> core.Error {
	core.write_u8(w, u8((^Filter)(self).mode))
	return .None
}

@(private)
save_eq :: proc(self: rawptr, w: ^core.State_Writer, ctx: ^core.Save_Context) -> core.Error {
	core.write_int(w, len((^Eq)(self).bands))
	return .None
}

@(private)
save_modulation :: proc(self: rawptr, w: ^core.State_Writer, ctx: ^core.Save_Context) -> core.Error {
	core.write_u8(w, u8((^Modulation)(self).kind))
	return .None
}

@(private)
save_limiter :: proc(self: rawptr, w: ^core.State_Writer, ctx: ^core.Save_Context) -> core.Error {
	core.write_f64(w, (^Limiter)(self).lookahead_ms)
	return .None
}

@(private)
save_saturation :: proc(self: rawptr, w: ^core.State_Writer, ctx: ^core.Save_Context) -> core.Error {
	core.write_int(w, (^Saturation)(self).factor)
	return .None
}

@(private)
save_synth :: proc(self: rawptr, w: ^core.State_Writer, ctx: ^core.Save_Context) -> core.Error {
	core.write_int(w, len((^Synth)(self).voices))
	return .None
}

@(private)
save_convolution :: proc(self: rawptr, w: ^core.State_Writer, ctx: ^core.Save_Context) -> core.Error {
	v := (^Convolution)(self)
	core.write_int(w, len(v.ir))
	for ch in v.ir do core.write_f32s(w, ch)
	return .None
}

@(private)
load_convolution :: proc(_: rawptr, r: ^core.State_Reader, version: u32, ctx: ^core.Load_Context, allocator: mem.Allocator) -> (core.Node, core.Error) {
	channels := core.read_int(r)
	if channels <= 0 || channels > core.MAX_CHANNELS do return {}, .Invalid_Data
	ir := make([][]f32, channels, context.temp_allocator)
	defer for ch in ir do delete(ch)
	for &ch in ir do ch = core.read_f32s(r)
	if r.err != .None do return {}, r.err
	return convolution_create(ir, allocator), .None
}
