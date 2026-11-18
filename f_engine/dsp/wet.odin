package dsp

import "core:mem"

import "fire:core"

// Parameter id of a `Wet` node's mix: 0 is the input untouched, 1 the
// effect alone (default 1). Chosen out of the way of the effect's own ids.
WET_PARAM_MIX :: core.Param_Id(0x7F00)

// How long the mix takes to move, in milliseconds.
WET_FADE_MS :: 15.0

// Most channels a `Wet` node runs its effect on.
WET_MAX_CHANNELS :: 8

// Wraps an effect node with a dry/wet mix, so it can be switched in and out
// (or blended) without clicks: `WET_PARAM_MIX` fades between the input and
// the effect's output. Every other parameter event goes to the effect.
// While fully dry the effect is not run (it costs nothing), and it is reset
// when it is switched back in, so it starts clean (no old echoes). The dry
// signal is delayed by the effect's latency, so a late effect (a limiter's
// lookahead, a plug-in) fades without combing and stays in time switched
// off.
Wet :: struct {
	inner:    core.Node,
	mix:      Smoothed_Value,
	params:   []core.Param_Info, // the effect's, then the mix
	scratch:  [WET_MAX_CHANNELS][]f32,
	forward:  []core.Event,
	idle:     bool, // fully dry: the effect is not running
	delay:    [WET_MAX_CHANNELS][]f32, // the dry signal's delay line (the effect's latency), or nil
	dry:      [WET_MAX_CHANNELS][]f32, // the dry signal, delayed (max_block)
	at:       int, // where the delay lines write next
}

@(private)
wet_vtable := core.Node_VTable {
	name = "fire.wet",
	prepare = wet_prepare,
	release = proc(self: rawptr, a: mem.Allocator) {
		w := (^Wet)(self)
		core.node_release(&w.inner)
		for &s in w.scratch {
			delete(s, a)
			s = nil
		}
		delete(w.forward, a)
		w.forward = nil
		for c in 0 ..< WET_MAX_CHANNELS {
			delete(w.delay[c], a)
			delete(w.dry[c], a)
			w.delay[c], w.dry[c] = nil, nil
		}
	},
	reset = proc(self: rawptr) {
		w := (^Wet)(self)
		core.node_reset(&w.inner)
		for d in w.delay do for &v in d do v = 0
		smoothed_reset(&w.mix, w.mix.target)
	},
	process = wet_process,
	params  = proc(self: rawptr) -> []core.Param_Info { return (^Wet)(self).params },
	latency = proc(self: rawptr) -> int { return core.node_latency(&(^Wet)(self).inner) },
	destroy = proc(self: rawptr, a: mem.Allocator) {
		w := (^Wet)(self)
		core.node_destroy(&w.inner)
		delete(w.params, a)
		free(w, a)
	},
}

// Control thread. Wraps `inner` (which the wrapper now owns) with a mix,
// starting at `mix` (0..1).
wet_create :: proc(inner: core.Node, mix: f64 = 1, allocator := context.allocator) -> core.Node {
	w := new(Wet, allocator)
	w.inner = inner
	own := core.node_params(&w.inner)
	w.params = make([]core.Param_Info, len(own) + 1, allocator)
	copy(w.params, own)
	w.params[len(own)] = {id = WET_PARAM_MIX, name = "Mix", unit = .Percent, min = 0, max = 1, default = 1, smoothing = .Linear, smoothing_ms = WET_FADE_MS, flags = {.Automatable}}
	w.mix.target, w.mix.current = clamp(mix, 0, 1), clamp(mix, 0, 1)
	return core.node_make(&wet_vtable, w, allocator)
}

@(private)
wet_prepare :: proc(self: rawptr, cfg: core.Prepare_Config, a: mem.Allocator) -> core.Error {
	w := (^Wet)(self)
	core.node_prepare(&w.inner, cfg, a) or_return
	for c in 0 ..< min(cfg.out_channels, WET_MAX_CHANNELS) {
		w.scratch[c] = make([]f32, cfg.max_block, a)
		if w.scratch[c] == nil && cfg.max_block > 0 do return .Out_Of_Memory
	}
	w.forward = make([]core.Event, 1024, a)
	if lat := core.node_latency(&w.inner); lat > 0 {
		for c in 0 ..< min(max(cfg.in_channels, cfg.out_channels), WET_MAX_CHANNELS) {
			w.delay[c] = make([]f32, lat, a)
			w.dry[c] = make([]f32, cfg.max_block, a)
			if w.delay[c] == nil || (w.dry[c] == nil && cfg.max_block > 0) do return .Out_Of_Memory
		}
	}
	w.at = 0
	m := w.mix.target
	smoothed_init(&w.mix, m, .Linear, WET_FADE_MS, cfg.sample_rate)
	w.idle = m == 0
	return .None
}

// [rt]
@(private)
wet_process :: proc(self: rawptr, ctx: ^core.Process_Context) {
	w := (^Wet)(self)
	// The mix is ours, applied on its frame; everything else goes to the
	// effect.
	mix_events: [32]core.Event
	nm, n := 0, 0
	for e in ctx.events_in {
		if _, _, ok := core.param_event(e.payload, WET_PARAM_MIX); ok {
			if nm < len(mix_events) {
				mix_events[nm] = e
				nm += 1
			}
		} else if n < len(w.forward) {
			w.forward[n] = e
			n += 1
		}
	}
	// The dry signal: the input, or (a late effect) the input as late.
	dry: [WET_MAX_CHANNELS][]f32
	nd := min(len(ctx.inputs), WET_MAX_CHANNELS)
	for c in 0 ..< nd do dry[c] = ctx.inputs[c][:ctx.frames]
	if lat := len(w.delay[0]); lat > 0 {
		for c in 0 ..< nd do if len(w.delay[c]) == lat && len(w.dry[c]) >= ctx.frames {
			d, o, at := w.delay[c], w.dry[c][:ctx.frames], w.at
			for x, i in ctx.inputs[c][:ctx.frames] {
				o[i] = d[at]
				d[at] = x
				at += 1
				if at == lat do at = 0
			}
			dry[c] = o
		}
		w.at = (w.at + ctx.frames) % lat
	}
	// Idle, the effect starts again (clean) on the frame the mix opens.
	from := 0
	if w.idle {
		from = ctx.frames
		for e in mix_events[:nm] {
			if v, _, _ := core.param_event(e.payload, WET_PARAM_MIX); v > 0 {
				from = int(e.offset)
				break
			}
		}
		for c in 0 ..< len(ctx.outputs) {
			out := ctx.outputs[c][:from]
			if c < nd do copy(out, dry[c][:from])
			else do for &v in out do v = 0
		}
		if from == ctx.frames do return
		core.node_reset(&w.inner)
		w.idle = false
	}
	channels := min(len(ctx.outputs), WET_MAX_CHANNELS)
	frames := ctx.frames - from
	views: [WET_MAX_CHANNELS][]f32
	ins: [WET_MAX_CHANNELS][]f32
	for c in 0 ..< channels do views[c] = w.scratch[c][:frames]
	for c in 0 ..< min(len(ctx.inputs), WET_MAX_CHANNELS) do ins[c] = ctx.inputs[c][from:ctx.frames]
	// The effect's events, from `from` on (earlier ones at its first frame).
	for &e in w.forward[:n] do e.offset = u32(max(int(e.offset) - from, 0))
	sub := ctx^
	sub.inputs = ins[:min(len(ctx.inputs), WET_MAX_CHANNELS)]
	sub.outputs = views[:channels]
	sub.frames = frames
	sub.events_in = w.forward[:n]
	core.node_process(&w.inner, &sub)
	k := 0
	for i in from ..< ctx.frames {
		for k < nm && int(mix_events[k].offset) <= i {
			v, r, _ := core.param_event(mix_events[k].payload, WET_PARAM_MIX)
			smoothed_apply(&w.mix, clamp(v, 0, 1), r)
			k += 1
		}
		m := f32(smoothed_next(&w.mix))
		for c in 0 ..< channels {
			d: f32 = dry[c][i] if c < nd else 0
			ctx.outputs[c][i] = d + (views[c][i - from] - d) * m
		}
	}
	for c in channels ..< len(ctx.outputs) do for &v in ctx.outputs[c][:ctx.frames] do v = 0
	if w.mix.current == 0 && w.mix.target == 0 do w.idle = true
}
