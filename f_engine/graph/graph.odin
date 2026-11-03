/*
Audio graph: nodes connected into a directed acyclic graph, processed once per
audio block on the audio thread and a pool of workers.

Edit the graph on the control thread (`add_node`, `connect`, ...), then
`commit` to compile the edits into a plan the audio thread picks up at its next
block. Call `process` from the audio callback.

	g, _ := graph.create(graph.default_settings(48_000, 512))
	defer graph.destroy(g)

	osc, _ := graph.add_node(g, dsp.gain_create(), 2, 2)
	graph.connect(g, graph.INPUT, 0, osc, 0)
	graph.connect(g, graph.INPUT, 1, osc, 1)
	graph.connect(g, osc, 0, graph.OUTPUT, 0)
	graph.connect(g, osc, 1, graph.OUTPUT, 1)
	graph.commit(g)

	// in the audio callback:
	graph.process(g, &ctx)

See /guides/graph/ for a walk-through and /design/graph/ for how it works.
*/
package graph

import "base:intrinsics"
import "core:mem"

import "fire:core"
import "fire:rt"

// A node in a graph. Stays valid until the node is removed; a removed node's
// ID is rejected rather than reaching another node.
Node_Id :: struct {
	index:      u32,
	generation: u32,
}

// The graph's audio and event input: the device's input channels, and
// incoming events such as MIDI. Connect from it like any node.
INPUT :: Node_Id{0, 1}

// The graph's audio and event output: connect into it to reach the device's
// output channels and the caller's event writer.
OUTPUT :: Node_Id{1, 1}

// Graph-wide settings, fixed for the graph's lifetime. Start from
// `default_settings`.
Settings :: struct {
	sample_rate:          f64,
	max_block:            int,  // largest `frames` `process` will be called with
	input_channels:       int,  // channels on INPUT
	output_channels:      int,  // channels on OUTPUT
	// Worker threads besides the audio thread. -1 = CPU cores − 1; 0 =
	// everything on the audio thread.
	workers:              int,
	// Delay parallel paths so they arrive aligned (see `latency`).
	latency_compensation: bool,
	// Run a block on several threads only when the graph has parallel paths
	// and its nodes take more than this much CPU per block (measured as it
	// runs). Below it, waking workers costs more than it saves. 0 = always
	// when there are parallel paths.
	parallel_min_us:      f64,
	// Installed as context.allocator on worker threads. Nodes must not
	// allocate while processing; the default (zero) is the nil allocator, so
	// an allocation fails instead of hitting the heap. Tests install a
	// trapping allocator here.
	worker_allocator:     mem.Allocator,
	max_events:           int, // events a node may emit per block (more are dropped and counted)
	max_pending_params:   int, // queued parameter changes per node
	param_queue:          int, // parameter changes in flight from the control thread
}

// Stereo in and out, latency compensation on, one worker per core but one.
default_settings :: proc(sample_rate: f64, max_block: int) -> Settings {
	return {
		sample_rate          = sample_rate,
		max_block            = max_block,
		input_channels       = 2,
		output_channels      = 2,
		workers              = -1,
		latency_compensation = true,
		parallel_min_us      = 50,
		max_events           = 1024,
		max_pending_params   = 64,
		param_queue          = 4096,
	}
}

// Counters for things the audio thread had to drop instead of allocating.
Stats :: struct {
	events_dropped: u64, // node output events beyond `max_events`
	params_dropped: u64, // parameter changes for full or unknown nodes
	blocks:         u64,
}

// A graph. Create with `create`; all procs except `process` are control
// thread only. Fields are internal.
Graph :: struct {
	settings:  Settings,
	allocator: mem.Allocator,

	slots:     [dynamic]^Slot, // index = Node_Id.index; never shrinks
	free:      [dynamic]u32,
	conns:     [dynamic]Connection,
	delays:    [dynamic]^Delay_Line,
	silence:   []f32,
	live:      [dynamic]^Plan, // compiled and not yet freed (published, current or retired)
	epoch:     u64,
	latency:   int,

	// Control → audio.
	pending:   ^Plan, // atomic
	params:    rt.Spsc_Queue(Param_Change),
	// Audio → control.
	retired:   rt.Spsc_Queue(^Plan),

	// Audio thread.
	current:     ^Plan,
	sample_time: i64,

	pool:        Pool,

	// Written by the audio thread, read anywhere.
	events_dropped: u64,
	params_dropped: u64,
	blocks:         u64,
}

@(private)
Slot_Kind :: enum u8 {
	Free,
	Node,
	Input,
	Output,
}

// Everything a node keeps across plans: the node, its output buffers, its
// input scratch, its event writer and pending parameter changes.
@(private)
Slot :: struct {
	kind:         Slot_Kind,
	generation:   u32,
	index:        u32,
	removed:      bool, // waiting for the plans that still use it to retire
	plan_refs:    int,  // live plans containing this slot
	node:         core.Node,
	in_channels:  int,
	out_channels: int,
	out_storage:  []f32,
	outputs:      [][]f32, // full max_block per channel
	scratch_store: []f32,
	scratch:      [][]f32, // summing space per input channel
	event_buffer: []core.Event,
	events_out:   core.Event_Writer,
	pending:      []Param_Change, // audio thread: sorted by `at`
	pending_len:  int,
}

@(private)
Connection :: struct {
	src, dst:       u32,  // slot indices
	src_ch, dst_ch: int,  // -1 for event connections
}

@(private)
Param_Change :: struct {
	slot:       u32,
	generation: u32,
	param:      core.Param_Id,
	value:      f64,
	at:         i64,
}

// Creates a graph with only INPUT and OUTPUT. Starts the worker threads.
create :: proc(settings: Settings, allocator := context.allocator) -> (g: ^Graph, err: core.Error) {
	if settings.sample_rate <= 0 || settings.max_block <= 0 ||
	   settings.input_channels < 0 || settings.output_channels < 0 ||
	   settings.input_channels > core.MAX_CHANNELS || settings.output_channels > core.MAX_CHANNELS {
		return nil, .Invalid_Argument
	}
	g = new(Graph, allocator)
	g.settings = settings
	if g.settings.max_events <= 0 do g.settings.max_events = 1024
	if g.settings.max_pending_params <= 0 do g.settings.max_pending_params = 64
	if g.settings.param_queue <= 0 do g.settings.param_queue = 4096
	g.allocator = allocator
	g.slots = make([dynamic]^Slot, allocator)
	g.free = make([dynamic]u32, allocator)
	g.conns = make([dynamic]Connection, allocator)
	g.delays = make([dynamic]^Delay_Line, allocator)
	g.live = make([dynamic]^Plan, allocator)
	defer if err != .None {
		destroy(g)
		g = nil
	}
	ok := true
	g.silence, err = alloc_floats(settings.max_block, allocator)
	if err != .None do return
	ok &&= rt.spsc_init(&g.params, g.settings.param_queue, allocator) == nil
	ok &&= rt.spsc_init(&g.retired, 64, allocator) == nil
	if !ok do return g, .Out_Of_Memory
	if _, err = new_slot(g, .Input, {}, 0, settings.input_channels); err != .None do return
	if _, err = new_slot(g, .Output, {}, settings.output_channels, 0); err != .None do return
	if err = pool_start(g); err != .None do return
	err = commit(g)
	return
}

// Stops the workers and frees the graph and every node in it. The audio
// thread must no longer call `process`.
destroy :: proc(g: ^Graph) {
	if g == nil do return
	pool_stop(g)
	for p in g.live do plan_free(g, p)
	clear(&g.live)
	g.current, g.pending = nil, nil
	for s in g.slots do slot_free(g, s)
	for d in g.delays do delay_free(g, d)
	rt.spsc_destroy(&g.params, g.allocator)
	rt.spsc_destroy(&g.retired, g.allocator)
	delete(g.silence, g.allocator)
	delete(g.slots)
	delete(g.free)
	delete(g.conns)
	delete(g.delays)
	delete(g.live)
	free(g, g.allocator)
}

// Adds a node and prepares it for the graph's sample rate and block size with
// `in_channels` inputs and `out_channels` outputs. The graph owns the node
// from here on (it is destroyed with the graph or by `remove_node`). Takes
// effect at the next `commit`.
add_node :: proc(g: ^Graph, node: core.Node, in_channels, out_channels: int) -> (Node_Id, core.Error) {
	if in_channels < 0 || out_channels < 0 || in_channels > core.MAX_CHANNELS || out_channels > core.MAX_CHANNELS {
		return {}, .Invalid_Argument
	}
	if node.vtable == nil do return {}, .Invalid_Argument
	node := node
	cfg := core.Prepare_Config{g.settings.sample_rate, g.settings.max_block, in_channels, out_channels}
	if node.state != .Prepared || node.config != cfg {
		if err := core.node_prepare(&node, cfg, g.allocator); err != .None do return {}, err
	}
	s, err := new_slot(g, .Node, node, in_channels, out_channels)
	if err != .None {
		core.node_destroy(&node)
		return {}, err
	}
	return {s.index, s.generation}, .None
}

// Removes a node and its connections. The node is released and destroyed once
// the audio thread has stopped using it (after a later `commit`). Takes
// effect at the next `commit`.
remove_node :: proc(g: ^Graph, id: Node_Id) -> core.Error {
	s := lookup(g, id) or_return
	if s.kind != .Node do return .Invalid_Argument // INPUT and OUTPUT stay
	for i := len(g.conns) - 1; i >= 0; i -= 1 {
		c := g.conns[i]
		if c.src == s.index || c.dst == s.index do ordered_remove(&g.conns, i)
	}
	s.removed = true
	s.generation += 1 // the ID is now stale
	collect(g)
	if s.plan_refs == 0 do slot_recycle(g, s) // never reached the audio thread
	return .None
}

// Routes output channel `src_channel` of `src` into input channel
// `dst_channel` of `dst`. Several connections into one input channel are
// summed. Fails with .Invalid_Argument for unknown nodes or channels, and
// .Invalid_State if the connection would create a cycle or already exists.
// Takes effect at the next `commit`.
connect :: proc(g: ^Graph, src: Node_Id, src_channel: int, dst: Node_Id, dst_channel: int) -> core.Error {
	a := lookup(g, src) or_return
	b := lookup(g, dst) or_return
	if src_channel < 0 || src_channel >= a.out_channels || dst_channel < 0 || dst_channel >= b.in_channels do return .Invalid_Argument
	return add_connection(g, {a.index, b.index, src_channel, dst_channel})
}

// Removes a connection made with `connect`. Takes effect at the next `commit`.
disconnect :: proc(g: ^Graph, src: Node_Id, src_channel: int, dst: Node_Id, dst_channel: int) -> core.Error {
	a := lookup(g, src) or_return
	b := lookup(g, dst) or_return
	return remove_connection(g, {a.index, b.index, src_channel, dst_channel})
}

// Routes the events `src` emits (notes, MIDI, parameter values) into `dst`'s
// event input. Events from several sources are merged in time order. From
// INPUT: the events passed to `process`; into OUTPUT: the caller's event
// writer. Takes effect at the next `commit`.
connect_events :: proc(g: ^Graph, src: Node_Id, dst: Node_Id) -> core.Error {
	a := lookup(g, src) or_return
	b := lookup(g, dst) or_return
	if a.kind == .Output || b.kind == .Input do return .Invalid_Argument
	return add_connection(g, {a.index, b.index, -1, -1})
}

// Removes an event connection. Takes effect at the next `commit`.
disconnect_events :: proc(g: ^Graph, src: Node_Id, dst: Node_Id) -> core.Error {
	a := lookup(g, src) or_return
	b := lookup(g, dst) or_return
	return remove_connection(g, {a.index, b.index, -1, -1})
}

// Compiles the current nodes and connections into a plan and hands it to the
// audio thread, which switches to it at the start of its next block. Also
// frees plans (and removed nodes) the audio thread has finished with.
commit :: proc(g: ^Graph) -> core.Error {
	collect(g)
	p := plan_compile(g) or_return
	append(&g.live, p)
	if old := intrinsics.atomic_exchange_explicit(&g.pending, p, .Acq_Rel); old != nil {
		// Never adopted by the audio thread: nobody else can see it.
		plan_release(g, old)
	}
	return .None
}

// Frees plans the audio thread has retired, and nodes removed since. `commit`
// does this too; call it after removing nodes if no commit follows soon.
collect :: proc(g: ^Graph) {
	for p in rt.spsc_pop(&g.retired) do plan_release(g, p)
}

// Changes a parameter of a node, sample-accurately: the node receives a
// `core.Param_Value` event at `at`, a time on the graph's clock (frames since
// the graph started processing, see `time`). `at = 0` or a time already past
// means the start of the next block. Control thread only (one producer).
set_param :: proc(g: ^Graph, id: Node_Id, param: core.Param_Id, value: f64, at: i64 = 0) -> core.Error {
	s := lookup(g, id) or_return
	if s.kind != .Node do return .Invalid_Argument
	if !rt.spsc_push(&g.params, Param_Change{s.index, s.generation, param, value, at}) {
		return .Out_Of_Memory // queue full: the audio thread is not running or far behind
	}
	return .None
}

// The node behind an ID, for reading its state or calling its own API from
// the control thread. Nil for unknown IDs, INPUT and OUTPUT.
get_node :: proc(g: ^Graph, id: Node_Id) -> ^core.Node {
	s, err := lookup(g, id)
	if err != .None || s.kind != .Node do return nil
	return &s.node
}

// Frames by which OUTPUT lags INPUT after latency compensation, as of the
// last `commit`.
latency :: proc(g: ^Graph) -> int {
	return g.latency
}

// The graph's clock: frames processed since the first `process` call. Read on
// the control thread it is approximate (the audio thread may be mid-block).
time :: proc "contextless" (g: ^Graph) -> i64 {
	return intrinsics.atomic_load_explicit(&g.sample_time, .Relaxed)
}

// Counters for events and parameter changes the audio thread dropped.
stats :: proc "contextless" (g: ^Graph) -> Stats {
	return {
		events_dropped = intrinsics.atomic_load_explicit(&g.events_dropped, .Relaxed),
		params_dropped = intrinsics.atomic_load_explicit(&g.params_dropped, .Relaxed),
		blocks         = intrinsics.atomic_load_explicit(&g.blocks, .Relaxed),
	}
}

// --- internals ------------------------------------------------------------------------

@(private)
lookup :: proc(g: ^Graph, id: Node_Id) -> (^Slot, core.Error) {
	if int(id.index) >= len(g.slots) do return nil, .Invalid_Argument
	s := g.slots[id.index]
	if s.kind == .Free || s.removed || s.generation != id.generation do return nil, .Invalid_Argument
	return s, .None
}

@(private)
new_slot :: proc(g: ^Graph, kind: Slot_Kind, node: core.Node, in_channels, out_channels: int) -> (s: ^Slot, err: core.Error) {
	index: u32
	if len(g.free) > 0 {
		index = pop(&g.free)
		s = g.slots[index]
	} else {
		s = new(Slot, g.allocator)
		if s == nil do return nil, .Out_Of_Memory
		index = u32(len(g.slots))
		append(&g.slots, s)
		s.generation = 1
	}
	generation := s.generation
	s^ = {kind = kind, generation = generation, index = index, node = node, in_channels = in_channels, out_channels = out_channels}
	defer if err != .None {
		slot_free_buffers(g, s)
		s.kind = .Free
		append(&g.free, index)
	}
	mb := g.settings.max_block
	s.out_storage = alloc_floats(out_channels * mb, g.allocator) or_return
	s.scratch_store = alloc_floats(in_channels * mb, g.allocator) or_return
	s.outputs = make([][]f32, out_channels, g.allocator)
	s.scratch = make([][]f32, in_channels, g.allocator)
	s.event_buffer = make([]core.Event, g.settings.max_events, g.allocator)
	s.pending = make([]Param_Change, g.settings.max_pending_params, g.allocator)
	if (out_channels > 0 && s.outputs == nil) || (in_channels > 0 && s.scratch == nil) || s.event_buffer == nil || s.pending == nil {
		return s, .Out_Of_Memory
	}
	for c in 0 ..< out_channels do s.outputs[c] = s.out_storage[c * mb:][:mb]
	for c in 0 ..< in_channels do s.scratch[c] = s.scratch_store[c * mb:][:mb]
	s.events_out = {buffer = s.event_buffer}
	return s, .None
}

// Releases the node and buffers of a slot no plan uses any more.
@(private)
slot_free :: proc(g: ^Graph, s: ^Slot) {
	if s.kind == .Node do core.node_destroy(&s.node)
	slot_free_buffers(g, s)
	free(s, g.allocator)
}

@(private)
slot_free_buffers :: proc(g: ^Graph, s: ^Slot) {
	delete(s.out_storage, g.allocator)
	delete(s.scratch_store, g.allocator)
	delete(s.outputs, g.allocator)
	delete(s.scratch, g.allocator)
	delete(s.event_buffer, g.allocator)
	delete(s.pending, g.allocator)
}

// A removed slot whose last plan is gone: destroy the node, reuse the index.
@(private)
slot_recycle :: proc(g: ^Graph, s: ^Slot) {
	if s.kind == .Node do core.node_destroy(&s.node)
	slot_free_buffers(g, s)
	generation := s.generation
	s^ = {kind = .Free, generation = generation, index = s.index}
	append(&g.free, s.index)
}

@(private)
add_connection :: proc(g: ^Graph, c: Connection) -> core.Error {
	for e in g.conns do if e == c do return .Invalid_State
	if c.src == c.dst || reaches(g, c.dst, c.src) do return .Invalid_State // would close a cycle
	append(&g.conns, c)
	return .None
}

@(private)
remove_connection :: proc(g: ^Graph, c: Connection) -> core.Error {
	for e, i in g.conns do if e == c {
		ordered_remove(&g.conns, i)
		return .None
	}
	return .Invalid_Argument
}

// Whether `to` is downstream of `from` (depth-first over connections).
@(private)
reaches :: proc(g: ^Graph, from, to: u32) -> bool {
	seen := make([]bool, len(g.slots), context.temp_allocator)
	stack := make([dynamic]u32, context.temp_allocator)
	append(&stack, from)
	for len(stack) > 0 {
		n := pop(&stack)
		if n == to do return true
		if seen[n] do continue
		seen[n] = true
		for c in g.conns do if c.src == n && !seen[c.dst] do append(&stack, c.dst)
	}
	return false
}

@(private)
alloc_floats :: proc(n: int, allocator: mem.Allocator) -> ([]f32, core.Error) {
	if n == 0 do return nil, .None
	s, err := make([]f32, n, allocator)
	return s, .None if err == nil else .Out_Of_Memory
}
