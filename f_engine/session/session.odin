/*
Saving and loading a whole session: the clock (tempo, meter, timelines and
their tempo maps), the graph (every node, its parameters and its own state,
clips and sample maps included, and every connection), and chunks of the
app's own.

	reg: core.Node_Registry
	core.registry_init(&reg)
	env := session.Environment{players = {streamer = streamer}}
	session.register_builtin(&reg, &env)

	s := session.Session{clock = clock, graph = g}
	session.save(s, "song.fire")
	loaded, err := session.load(s, "song.fire", &reg)
	defer session.loaded_destroy(&loaded)

Files are versioned chunks (see `core.State_Writer`): older engines skip
what they do not know, node types they lack load as placeholders that keep
their data, and audio files are found next to the session file when it
moves with them. Run `tools/session_dump` to print one.

See /guides/sessions/ for a walk-through and /design/session/ for the format.
*/
package session

import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "fire:clap"
import "fire:clip"
import "fire:core"
import "fire:dsp"
import "fire:graph"
import "fire:record"
import "fire:sampler"
import "fire:transport"

// Chunk tag of a whole saved session (the top level of a session file).
SESSION_TAG :: core.Tag{'F', 'S', 'E', 'S'}

// Version of the session chunk this engine writes.
FORMAT_VERSION :: 1

// What a session is made of: the clock its timelines live on and the graph
// its nodes live in. Either may be nil (then it is neither saved nor loaded).
Session :: struct {
	clock: ^transport.Clock,
	graph: ^graph.Graph,
}

// A chunk of the app's own, saved inside the session: its model of tracks,
// names, colours, window layout, anything. Use tags of your own (the
// engine's are listed in /design/session/).
App_Chunk :: struct {
	tag:     core.Tag,
	version: u32,
	data:    []u8,
}

// What the built-in node types need to load (see `register_builtin`).
// Must outlive the registry.
Environment :: struct {
	players:  clip.Player_Env,   // streamer (audio players, samplers) and stretcher
	disk:     ^record.Disk_Writer, // for audio recorders; nil: they load as placeholders
	clap_log: proc(severity: i32, message: string), // hosted plug-ins' log; nil: dropped
}

// Registers every node type the engine provides. Types that need something
// `env` lacks (audio players and samplers without a streamer, audio
// recorders without a disk writer) are left out, so they load as
// placeholders. Control thread.
register_builtin :: proc(reg: ^core.Node_Registry, env: ^Environment) -> core.Error {
	dsp.register_types(reg) or_return
	graph.register_types(reg) or_return
	transport.register_types(reg) or_return
	clip.register_types(reg, &env.players) or_return
	record.register_types(reg, env.disk) or_return
	clap.register_types(reg, env.clap_log) or_return
	if env.players.streamer != nil do sampler.register_types(reg, env.players.streamer) or_return
	return .None
}

// Control thread. The session as bytes: a SESSION_TAG chunk holding the
// clock, the graph and `extra`. File paths are stored relative to `dir`
// too (the directory the bytes will be saved in; "" for none). The bytes
// are allocated with `allocator`.
save_bytes :: proc(s: Session, dir: string = "", extra: []App_Chunk = nil, allocator := context.allocator) -> (data: []u8, err: core.Error) {
	w: core.State_Writer
	core.state_writer_init(&w, context.temp_allocator)
	ctx := core.Save_Context{dir = dir}
	core.begin_chunk(&w, SESSION_TAG, FORMAT_VERSION)
	if s.clock != nil do transport.save(s.clock, &w) or_return
	if s.graph != nil do graph.save(s.graph, &w, &ctx) or_return
	for c in extra do core.write_chunk(&w, c.tag, c.version, c.data)
	core.end_chunk(&w)
	out := core.state_writer_bytes(&w) or_return
	data = make([]u8, len(out), allocator)
	copy(data, out)
	return data, .None
}

// Control thread. Saves the session to `path`, replacing the file only
// once the new one is completely written (a temporary file next to it is
// renamed over it). `.Device_Error` if it cannot be written.
save :: proc(s: Session, path: string, extra: []App_Chunk = nil) -> core.Error {
	dir := filepath.dir(path)
	data := save_bytes(s, dir, extra, context.temp_allocator) or_return
	tmp := strings.concatenate({path, ".tmp"}, context.temp_allocator)
	if os.write_entire_file(tmp, data) != nil {
		os.remove(tmp)
		return .Device_Error
	}
	if os.rename(tmp, path) != nil {
		os.remove(tmp)
		return .Device_Error
	}
	return .None
}

// What `load` restored. Free with `loaded_destroy`.
Loaded :: struct {
	nodes:     graph.Load_Result,       // saved node indices → new IDs, and nodes that became placeholders
	timelines: []core.Timeline_Remap,   // saved timeline IDs → new ones
	extra:     []App_Chunk,             // the app chunks (copies), in file order
	version:   u32,                     // the file's session format version
	allocator: mem.Allocator,
}

// Frees what `load` returned.
loaded_destroy :: proc(l: ^Loaded) {
	graph.load_result_destroy(&l.nodes)
	delete(l.timelines, l.allocator)
	for c in l.extra do delete(c.data, l.allocator)
	delete(l.extra, l.allocator)
	l^ = {}
}

// The saved node's ID after loading (`saved` is its `Node_Id.index` when
// it was saved).
node :: proc(l: Loaded, saved: u32) -> (graph.Node_Id, bool) {
	return graph.remap(l.nodes, saved)
}

// The saved timeline's ID after loading.
timeline :: proc(l: Loaded, saved: core.Timeline_Id) -> (core.Timeline_Id, bool) {
	for m in l.timelines do if m.saved == saved do return m.now, true
	return {}, false
}

// The first app chunk tagged `tag`.
find_extra :: proc(l: Loaded, tag: core.Tag) -> (App_Chunk, bool) {
	for c in l.extra do if c.tag == tag do return c, true
	return {}, false
}

// Control thread. Replaces what the session holds with what `data` (from
// `save_bytes`) describes. The new timelines and nodes are made alongside
// the old ones, then the old ones go and the graph switches over in one
// block, so a running engine keeps playing (the clock needs room for both
// sets of timelines meanwhile). If anything fails, the session is left as
// it was. Timelines load stopped. `dir` is where relative file paths are
// looked for. `.Invalid_Data` for data that is not a session or is
// malformed; `.Unsupported` for a newer major format.
load_bytes :: proc(s: Session, data: []u8, reg: ^core.Node_Registry, dir: string = "", allocator := context.allocator) -> (l: Loaded, err: core.Error) {
	r := core.state_reader(data)
	top, ok := core.read_chunk(&r)
	if !ok || top.tag != SESSION_TAG do return {}, .Invalid_Data
	if top.version > FORMAT_VERSION do return {}, .Unsupported // versions add, never change, until a major break
	l.version, l.allocator = top.version, allocator

	old_nodes := graph.nodes(s.graph, context.temp_allocator) if s.graph != nil else nil
	old_lines := make([dynamic]core.Timeline_Id, context.temp_allocator)
	if s.clock != nil {
		for used, i in s.clock.in_use do if used do append(&old_lines, core.Timeline_Id{u32(i), s.clock.generations[i]})
	}

	extra := make([dynamic]App_Chunk, allocator)
	fail :: proc(s: Session, l: ^Loaded, extra: ^[dynamic]App_Chunk, err: core.Error) -> (Loaded, core.Error) {
		for c in extra do delete(c.data, l.allocator)
		delete(extra^)
		for m in l.timelines do transport.remove_timeline(s.clock, m.now)
		delete(l.timelines, l.allocator)
		return {}, err
	}
	cr := core.chunk_reader(top)
	graph_chunk: core.Chunk
	has_graph := false
	for !core.reader_done(&cr) {
		c, _ := core.read_chunk(&cr)
		switch c.tag {
		case transport.CLOCK_TAG:
			if s.clock == nil || l.timelines != nil do continue
			l.timelines, err = transport.load(s.clock, c, allocator)
			if err != .None do return fail(s, &l, &extra, err)
		case graph.GRAPH_TAG:
			graph_chunk, has_graph = c, true // after the clock, whatever the order
		case:
			copied := make([]u8, len(c.data), allocator)
			copy(copied, c.data)
			append(&extra, App_Chunk{c.tag, c.version, copied})
		}
	}
	if cr.err != .None do return fail(s, &l, &extra, .Invalid_Data)
	if has_graph && s.graph != nil {
		ctx := core.Load_Context{dir = dir, timelines = l.timelines, registry = reg, allocator = allocator}
		l.nodes, err = graph.load(s.graph, graph_chunk, &ctx, allocator, commit_now = false)
		if err != .None do return fail(s, &l, &extra, err)
	}
	l.extra = extra[:]

	// Everything loaded: drop the old session and switch in one commit.
	if s.graph != nil {
		for id in old_nodes do graph.remove_node(s.graph, id)
		graph.commit(s.graph)
	}
	if s.clock != nil {
		for id in old_lines do transport.remove_timeline(s.clock, id)
	}
	return l, .None
}

// Control thread. Loads a session file saved by `save` (see `load_bytes`),
// finding audio files next to it when they moved with it. `.Device_Error`
// if it cannot be read.
load :: proc(s: Session, path: string, reg: ^core.Node_Registry, allocator := context.allocator) -> (Loaded, core.Error) {
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil do return {}, .Device_Error
	return load_bytes(s, data, reg, filepath.dir(path), allocator)
}

// Control thread. Empties the session: removes every node (committed at
// once) and every timeline.
clear :: proc(s: Session) -> core.Error {
	if s.graph != nil {
		for id in graph.nodes(s.graph, context.temp_allocator) do graph.remove_node(s.graph, id)
		graph.commit(s.graph) or_return
	}
	if s.clock != nil do transport.clear(s.clock) or_return
	return .None
}
