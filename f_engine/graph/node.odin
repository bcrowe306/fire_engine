package graph

import "core:mem"

import "fire:core"

// Wraps a graph as a `core.Node`, so a whole graph can be nested inside
// another graph or rendered by `testkit.render`. The node owns the graph:
// destroying the node destroys the graph. Its inputs and outputs are INPUT's
// and OUTPUT's channels; preparing it with any other sample rate, channel
// counts or a larger block fails with .Invalid_Argument.
//
//	inner, _ := graph.create(settings)
//	// ... build `inner` and commit ...
//	id, _ := graph.add_node(outer, graph.as_node(inner), 2, 2)
as_node :: proc(g: ^Graph) -> core.Node {
	return core.node_make(&graph_node_vtable, g, g.allocator)
}

@(private)
graph_node_vtable := core.Node_VTable {
	prepare = proc(self: rawptr, cfg: core.Prepare_Config, allocator: mem.Allocator) -> core.Error {
		g := (^Graph)(self)
		st := g.settings
		if cfg.sample_rate != st.sample_rate || cfg.max_block > st.max_block ||
		   cfg.in_channels != st.input_channels || cfg.out_channels != st.output_channels {
			return .Invalid_Argument
		}
		return .None
	},
	process = proc(self: rawptr, ctx: ^core.Process_Context) {
		process((^Graph)(self), ctx)
	},
	// [rt] Resets every node in the current plan.
	reset = proc(self: rawptr) {
		g := (^Graph)(self)
		if g.current == nil do return
		for pn in g.current.nodes do if pn.slot.kind == .Node do core.node_reset(&pn.slot.node)
	},
	release = proc(self: rawptr, allocator: mem.Allocator) {},
	params  = proc(self: rawptr) -> []core.Param_Info { return nil },
	destroy = proc(self: rawptr, allocator: mem.Allocator) { destroy((^Graph)(self)) },
	latency = proc(self: rawptr) -> int { return (^Graph)(self).latency },
	type_id = GRAPH_TYPE_ID,
	state_version = GRAPH_VERSION,
	save    = save_graph_node,
}
