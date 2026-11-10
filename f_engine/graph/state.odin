package graph

import "core:mem"
import "core:strings"

import "fire:core"

// Chunk tag of a saved graph: its NODE chunks, then CONN.
GRAPH_TAG :: core.Tag{'G', 'R', 'P', 'H'}
// Chunk tag of one saved node: index, type and channels, then PARM and DATA.
NODE_TAG :: core.Tag{'N', 'O', 'D', 'E'}
// Chunk tag of a node's saved parameter values.
PARAMS_TAG :: core.Tag{'P', 'A', 'R', 'M'}
// Chunk tag of a node's own state; its version is the type's `state_version`.
DATA_TAG :: core.Tag{'D', 'A', 'T', 'A'}
// Chunk tag of a graph's saved connections.
CONNECTIONS_TAG :: core.Tag{'C', 'O', 'N', 'N'}

// ID under which nested graphs (`as_node`) are saved.
GRAPH_TYPE_ID :: "fire.graph"

@(private)
GRAPH_VERSION :: 1

// A node of a saved graph and the ID it has after `load`.
Node_Remap :: struct {
	saved: u32, // the node's index when saved (`Node_Id.index`)
	now:   Node_Id,
}

// A node `load` could not make: kept as a silent placeholder (see
// `is_placeholder`) that saves back exactly what was loaded.
Missing_Node :: struct {
	id:      Node_Id,
	type_id: string, // allocated with the load's allocator
	err:     core.Error, // .Unsupported: no such type registered; else the loader's error
}

// What `load` did. Free with `load_result_destroy`.
Load_Result :: struct {
	nodes:     []Node_Remap,
	missing:   []Missing_Node,
	allocator: mem.Allocator,
}

// Frees what `load` returned.
load_result_destroy :: proc(r: ^Load_Result) {
	for m in r.missing do delete(m.type_id, r.allocator)
	delete(r.nodes, r.allocator)
	delete(r.missing, r.allocator)
	r^ = {}
}

// The ID a saved node has after loading, from `r.nodes`.
remap :: proc(r: Load_Result, saved: u32) -> (Node_Id, bool) {
	for m in r.nodes do if m.saved == saved do return m.now, true
	return {}, false
}

// Control thread. Writes the graph as a GRAPH_TAG chunk: every node (its
// type, channel counts, parameter values and own state) and every
// connection. Parameter values are the last ones `set_param` or
// `set_param_ramp` set; parameters never set are not saved, so they start
// as a freshly made node of the type has them. Values that automation or
// modulation moves are saved as their base. Fails with `.Unsupported` if a
// node's type cannot be saved (no `type_id`), or with the node's own error;
// the writer then holds a partial chunk, so discard it.
save :: proc(g: ^Graph, w: ^core.State_Writer, ctx: ^core.Save_Context) -> core.Error {
	core.begin_chunk(w, GRAPH_TAG, GRAPH_VERSION)
	core.write_int(w, g.settings.input_channels)
	core.write_int(w, g.settings.output_channels)
	for s in g.slots {
		if s.kind != .Node || s.removed do continue
		save_node(s, w, ctx) or_return
	}
	core.begin_chunk(w, CONNECTIONS_TAG, 1)
	core.write_int(w, len(g.conns))
	for c in g.conns {
		core.write_u32(w, c.src)
		core.write_u32(w, c.dst)
		core.write_int(w, c.src_ch)
		core.write_int(w, c.dst_ch)
	}
	core.end_chunk(w)
	core.end_chunk(w)
	return w.err
}

@(private)
save_node :: proc(s: ^Slot, w: ^core.State_Writer, ctx: ^core.Save_Context) -> core.Error {
	n := &s.node
	type_id, version := n.vtable.type_id, n.vtable.state_version
	ph := placeholder_of(n)
	if ph != nil do type_id, version = ph.type_id, ph.version
	if type_id == "" do return .Unsupported
	core.begin_chunk(w, NODE_TAG, 1)
	core.write_u32(w, s.index)
	core.write_string(w, type_id)
	core.write_int(w, s.in_channels)
	core.write_int(w, s.out_channels)

	core.begin_chunk(w, PARAMS_TAG, 1)
	if ph != nil {
		core.write_int(w, len(ph.params))
		for v in ph.params {
			core.write_u32(w, u32(v.param))
			core.write_f64(w, v.value)
		}
	} else {
		// Only values that were set: the others stay as the node is made.
		core.write_int(w, len(s.values))
		for v in s.values {
			core.write_u32(w, u32(v.param))
			core.write_f64(w, v.value)
		}
	}
	core.end_chunk(w)

	core.begin_chunk(w, DATA_TAG, version)
	if ph != nil {
		core.write_payload(w, ph.data)
	} else {
		core.node_save(n, w, ctx) or_return
	}
	core.end_chunk(w)
	core.end_chunk(w)
	return w.err
}

// Control thread. Adds the nodes and connections of a GRAPH_TAG chunk to
// `g` (usually empty but for INPUT and OUTPUT) and commits them all at once,
// so a running graph switches in one block. Node types come from
// `ctx.registry`; a node whose type is not registered, or whose loader
// fails, becomes a silent placeholder that keeps its saved state (listed in
// `Load_Result.missing`). Loaded nodes start at their saved parameter
// values without smoothing. Connections to channels a graph lacks are
// skipped. With `commit_now` false, the caller commits (to make other edits
// in the same switch). On failure nothing loaded stays in the graph.
// `.Invalid_Data` for a malformed chunk.
load :: proc(g: ^Graph, c: core.Chunk, ctx: ^core.Load_Context, allocator := context.allocator, commit_now := true) -> (result: Load_Result, err: core.Error) {
	if c.tag != GRAPH_TAG do return {}, .Invalid_Data
	nodes := make([dynamic]Node_Remap, allocator)
	missing := make([dynamic]Missing_Node, allocator)
	err = load_nodes(g, c, ctx, &nodes, &missing, allocator)
	if err == .None && commit_now do err = commit(g)
	result = {nodes = nodes[:], missing = missing[:], allocator = allocator}
	if err != .None {
		for m in nodes do remove_node(g, m.now)
		load_result_destroy(&result)
	}
	return
}

@(private)
load_nodes :: proc(g: ^Graph, c: core.Chunk, ctx: ^core.Load_Context, nodes: ^[dynamic]Node_Remap, missing: ^[dynamic]Missing_Node, allocator: mem.Allocator) -> core.Error {
	lctx := ctx^
	lctx.sample_rate, lctx.max_block = g.settings.sample_rate, g.settings.max_block
	r := core.chunk_reader(c)
	_ = core.read_int(&r) // channel counts when saved: the graph keeps its own
	_ = core.read_int(&r)
	for !core.reader_done(&r) {
		ch, _ := core.read_chunk(&r)
		switch ch.tag {
		case NODE_TAG:
			m, saved, e := load_node(g, ch, &lctx, allocator)
			if e != .None do return e
			append(nodes, Node_Remap{saved, m.id})
			if m.type_id != "" do append(missing, m)
		case CONNECTIONS_TAG:
			load_connections(g, ch, nodes[:]) or_return
		}
	}
	return r.err
}

@(private)
load_node :: proc(g: ^Graph, c: core.Chunk, ctx: ^core.Load_Context, allocator: mem.Allocator) -> (m: Missing_Node, saved: u32, err: core.Error) {
	r := core.chunk_reader(c)
	saved = core.read_u32(&r)
	type_id := core.read_string(&r)
	in_ch := core.read_int(&r)
	out_ch := core.read_int(&r)
	if r.err != .None || in_ch < 0 || out_ch < 0 || in_ch > core.MAX_CHANNELS || out_ch > core.MAX_CHANNELS {
		return {}, 0, .Invalid_Data
	}
	params: []core.Param_Value
	data: core.Chunk
	has_data := false
	for !core.reader_done(&r) {
		ch, _ := core.read_chunk(&r)
		switch ch.tag {
		case PARAMS_TAG:
			pr := core.chunk_reader(ch)
			count := core.read_int(&pr)
			if count < 0 || count > len(ch.data) / 12 do return {}, 0, .Invalid_Data
			params = make([]core.Param_Value, count, context.temp_allocator)
			for &v in params do v = {core.Param_Id(core.read_u32(&pr)), core.read_f64(&pr)}
			if pr.err != .None do return {}, 0, .Invalid_Data
		case DATA_TAG:
			data, has_data = ch, true
		}
	}
	if r.err != .None do return {}, 0, .Invalid_Data

	node: core.Node
	failure := core.Error.Unsupported
	if t, ok := core.find_type(ctx.registry, type_id); ok {
		dr := core.chunk_reader(data)
		node, failure = t.load(t.data, &dr, data.version, ctx, g.allocator)
		if failure == .None && dr.err != .None {
			core.node_destroy(&node)
			failure = dr.err
		}
	}
	if failure != .None {
		node = make_placeholder(type_id, data.version if has_data else 0, data.data, params, in_ch, out_ch, g.allocator) or_return
	}
	id, e := add_node(g, node, in_ch, out_ch)
	if e != .None && failure == .None {
		// The real node would not prepare at these settings: keep its data.
		failure = e
		node = make_placeholder(type_id, data.version, data.data, params, in_ch, out_ch, g.allocator) or_return
		id, e = add_node(g, node, in_ch, out_ch)
	}
	if e != .None do return {}, 0, e

	s := g.slots[id.index]
	if failure != .None {
		m = {id = id, type_id = strings.clone(type_id, allocator), err = failure}
		return m, saved, .None
	}
	// Starting values for the parameters this node still has.
	known := core.node_params(&s.node)
	initial := make([dynamic]core.Param_Value, g.allocator)
	for v in params {
		if _, ok := core.find_param(known, v.param); !ok do continue
		append(&initial, v)
		remember_value(s, v.param, v.value)
	}
	s.initial = initial[:]
	return {id = id}, saved, .None
}

@(private)
load_connections :: proc(g: ^Graph, c: core.Chunk, nodes: []Node_Remap) -> core.Error {
	r := core.chunk_reader(c)
	count := core.read_int(&r)
	if count < 0 || count > len(c.data) / 24 do return .Invalid_Data
	id :: proc(nodes: []Node_Remap, index: u32) -> (Node_Id, bool) {
		if index == INPUT.index do return INPUT, true
		if index == OUTPUT.index do return OUTPUT, true
		for m in nodes do if m.saved == index do return m.now, true
		return {}, false
	}
	for _ in 0 ..< count {
		src_index, dst_index := core.read_u32(&r), core.read_u32(&r)
		src_ch, dst_ch := core.read_int(&r), core.read_int(&r)
		if r.err != .None do return .Invalid_Data
		src, ok_src := id(nodes, src_index)
		dst, ok_dst := id(nodes, dst_index)
		if !ok_src || !ok_dst do continue // a node that was not saved: drop its connections
		if src_ch < 0 && dst_ch < 0 {
			connect_events(g, src, dst)
		} else {
			connect(g, src, src_ch, dst, dst_ch) // fails harmlessly for channels the graph lacks
		}
	}
	return .None
}

// The nodes in the graph (not INPUT and OUTPUT), in index order. Control
// thread; the slice is allocated with `allocator`.
nodes :: proc(g: ^Graph, allocator := context.allocator) -> []Node_Id {
	out := make([dynamic]Node_Id, allocator)
	for s in g.slots do if s.kind == .Node && !s.removed do append(&out, Node_Id{s.index, s.generation})
	return out[:]
}

// Whether `id` is a placeholder for a node `load` could not make.
is_placeholder :: proc(g: ^Graph, id: Node_Id) -> bool {
	s, err := lookup(g, id)
	return err == .None && s.kind == .Node && placeholder_of(&s.node) != nil
}

// --- placeholder ---------------------------------------------------------------------------

// Stands in for a node of an unknown type: silent, no parameters, and saves
// back the type, parameter values and state it was loaded with.
@(private)
Placeholder :: struct {
	type_id: string,
	version: u32,
	data:    []u8,
	params:  []core.Param_Value,
}

@(private)
placeholder_vtable := core.Node_VTable {
	prepare = proc(self: rawptr, cfg: core.Prepare_Config, allocator: mem.Allocator) -> core.Error { return .None },
	process = proc(self: rawptr, ctx: ^core.Process_Context) {
		for out in ctx.outputs do for &x in out do x = 0
	},
	release = proc(self: rawptr, allocator: mem.Allocator) {},
	destroy = proc(self: rawptr, allocator: mem.Allocator) {
		p := (^Placeholder)(self)
		delete(p.type_id, allocator)
		delete(p.data, allocator)
		delete(p.params, allocator)
		free(p, allocator)
	},
}

@(private)
make_placeholder :: proc(type_id: string, version: u32, data: []u8, params: []core.Param_Value, in_ch, out_ch: int, allocator: mem.Allocator) -> (core.Node, core.Error) {
	p := new(Placeholder, allocator)
	if p == nil do return {}, .Out_Of_Memory
	p.type_id = strings.clone(type_id, allocator)
	p.version = version
	p.data = make([]u8, len(data), allocator)
	copy(p.data, data)
	p.params = make([]core.Param_Value, len(params), allocator)
	copy(p.params, params)
	return core.node_make(&placeholder_vtable, p, allocator), .None
}

@(private)
placeholder_of :: proc(n: ^core.Node) -> ^Placeholder {
	return (^Placeholder)(n.data) if n.vtable == &placeholder_vtable else nil
}

// --- nested graphs -------------------------------------------------------------------------

// Registers the node types this package provides (nested graphs, as made
// by `as_node`), so saved state can name them.
register_types :: proc(reg: ^core.Node_Registry) -> core.Error {
	return core.register_type(reg, {id = GRAPH_TYPE_ID, load = load_graph_node})
}

@(private)
save_graph_node :: proc(self: rawptr, w: ^core.State_Writer, ctx: ^core.Save_Context) -> core.Error {
	g := (^Graph)(self)
	st := g.settings
	core.write_int(w, st.input_channels)
	core.write_int(w, st.output_channels)
	core.write_int(w, st.workers)
	core.write_bool(w, st.latency_compensation)
	core.write_f64(w, st.parallel_min_us)
	core.write_int(w, st.max_events)
	core.write_int(w, st.max_pending_params)
	core.write_int(w, st.param_queue)
	return save(g, w, ctx)
}

@(private)
load_graph_node :: proc(data: rawptr, r: ^core.State_Reader, version: u32, ctx: ^core.Load_Context, allocator: mem.Allocator) -> (core.Node, core.Error) {
	if ctx.sample_rate <= 0 || ctx.max_block <= 0 do return {}, .Invalid_Argument
	st := default_settings(ctx.sample_rate, ctx.max_block)
	st.input_channels = core.read_int(r)
	st.output_channels = core.read_int(r)
	st.workers = core.read_int(r)
	st.latency_compensation = core.read_bool(r)
	st.parallel_min_us = core.read_f64(r)
	st.max_events = core.read_int(r)
	st.max_pending_params = core.read_int(r)
	st.param_queue = core.read_int(r)
	c, ok := core.find_chunk(r, GRAPH_TAG)
	if r.err != .None || !ok do return {}, .Invalid_Data
	inner, cerr := create(st, allocator)
	if cerr != .None do return {}, cerr
	res, err := load(inner, c, ctx, ctx.allocator)
	load_result_destroy(&res) // inner IDs: list them with `nodes`
	if err != .None {
		destroy(inner)
		return {}, err
	}
	return as_node(inner), .None
}
