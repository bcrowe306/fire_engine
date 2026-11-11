package synth

import "core:mem"

import "fire:core"
import "fire:fx"

// The synth's effects as nodes of their own, for a track's inserts: one
// effect each, stereo in and out, its parameters the synth's for that
// effect (`effect_param`; all but its switch: a host bypasses the node
// instead), in their plain values. Its delays, chorus, flanger and
// phaser follow the transport's tempo.
//
//	node, fxn := synth.effect_node_create(.Reverb)
//	// graph.set_param(g, id, synth.effect_param(.Reverb, synth.Reverb_Field.Wet), 0.4)

// A synth effect node's state (from `effect_node_create`).
Effect_Node :: struct {
	effect:      fx.Effect,
	values:      [PARAM_SLOTS]f32, // plain values by id (only the effect's are read)
	chain:       fx.Chain, // the one effect's state (for drawing: read while it plays)
	sample_rate: f64,
	bpm:         f64,
	allocator:   mem.Allocator,
}

// Each effect's node parameters (its synth parameters but its switch).
@(private)
effect_node_infos: [fx.Effect][dynamic]core.Param_Info

@(private)
effect_node_vtable := core.Node_VTable {
	prepare = proc(self: rawptr, cfg: core.Prepare_Config, allocator: mem.Allocator) -> core.Error {
		n := (^Effect_Node)(self)
		n.sample_rate = cfg.sample_rate
		fx.chain_destroy(&n.chain, n.allocator)
		return fx.chain_make(&n.chain, cfg.sample_rate, n.allocator, {n.effect})
	},
	process = effect_node_process,
	reset   = proc(self: rawptr) {
		n := (^Effect_Node)(self)
		fx.chain_reset(&n.chain, n.effect)
	},
	params  = proc(self: rawptr) -> []core.Param_Info { return effect_node_infos[(^Effect_Node)(self).effect][:] },
	destroy = proc(self: rawptr, allocator: mem.Allocator) {
		n := (^Effect_Node)(self)
		fx.chain_destroy(&n.chain, n.allocator)
		free(n, n.allocator)
	},
}

// Control thread. A node playing effect `e` at its defaults.
effect_node_create :: proc(e: fx.Effect, allocator := context.allocator) -> (node: core.Node, n: ^Effect_Node) {
	n = new(Effect_Node, allocator)
	n.effect, n.allocator, n.bpm = e, allocator, 120
	for spec in PARAMS do n.values[spec.id] = spec.default
	return core.node_make(&effect_node_vtable, n, allocator), n
}

// The parameters an effect's node has.
effect_node_params :: proc(e: fx.Effect) -> []core.Param_Info {
	return effect_node_infos[e][:]
}

// Which effect a synth parameter id belongs to (false: none).
effect_of_param :: proc "contextless" (id: core.Param_Id) -> (e: fx.Effect, ok: bool) {
	if !is_effect_param(id) do return {}, false
	k := (int(id) - FX_BASE) / FX_STRIDE
	if k < 0 || k >= len(fx.Effect) do return {}, false
	return fx.Effect(k), true
}

@(private)
effect_node_process :: proc(self: rawptr, ctx: ^core.Process_Context) {
	n := (^Effect_Node)(self)
	for ev in ctx.events_in {
		#partial switch v in ev.payload {
		case core.Param_Value:
			if spec := param_spec(v.param); spec != nil do n.values[v.param] = clamp(f32(v.value), spec.min, spec.max)
		case core.Param_Ramp:
			if spec := param_spec(v.param); spec != nil do n.values[v.param] = clamp(f32(v.target), spec.min, spec.max)
		}
	}
	if ctx.transport != nil && ctx.transport.tempo_bpm > 0 do n.bpm = ctx.transport.tempo_bpm
	outs := len(ctx.outputs)
	if outs == 0 do return
	f := ctx.frames
	// In to out (one input: both sides from it; none: silence).
	for ch in 0 ..< outs {
		out := ctx.outputs[ch][:f]
		if len(ctx.inputs) > 0 {
			copy(out, ctx.inputs[min(ch, len(ctx.inputs) - 1)][:f])
		} else {
			for &x in out do x = 0
		}
	}
	if outs < 2 do return
	p := effect_chain_params(n.values[:], fx.CHAIN_ORDER, n.bpm)
	p.on = {n.effect}
	fx.chain_render(&n.chain, &p, ctx.outputs[0][:f], ctx.outputs[1][:f], n.sample_rate)
}

// Fills `effect_node_infos` from `PARAMS` (after the effects' are added).
@(private)
build_effect_node_infos :: proc() {
	for &spec in PARAMS {
		e, ok := effect_of_param(spec.id)
		if !ok || int(spec.id) == int(effect_param(e, Chorus_Field.On)) do continue
		flags := core.Param_Flags{.Automatable}
		if spec.curve == .Indexed do flags += {.Stepped}
		append(&effect_node_infos[e], core.Param_Info{id = spec.id, name = spec.name, unit = spec.unit, min = f64(spec.min), max = f64(spec.max), default = f64(spec.default), flags = flags})
	}
}
