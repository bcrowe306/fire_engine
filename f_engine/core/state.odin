package core

import "core:encoding/endian"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"

// --- saved state: chunks ---------------------------------------------------------------------
//
// Saved state is a tree of chunks. A chunk is a 16-byte header (a four-byte
// tag, a u32 version, a u64 payload size; little-endian) and a payload of
// values, of child chunks, or of a fixed run of values followed by child
// chunks. Values carry no type tags: the reader of a chunk reads them in the
// order its writer wrote them, as the version says.
//
// Readers stay compatible both ways:
// - an older reader skips child chunks with tags it does not know, and
//   values at the end of a chunk that it does not read;
// - a newer reader checks the version before reading values a later
//   version added.
// So a format grows by appending values to a chunk without children, or by
// adding child chunks, and bumps the chunk's version either way.

// A chunk's four-byte type, such as `Tag{'N', 'O', 'D', 'E'}`.
Tag :: distinct [4]u8

// Size of a chunk header in bytes.
CHUNK_HEADER_SIZE :: 16

// One chunk, as `read_chunk` finds it: its tag, its version and its
// payload (a slice of the reader's data).
Chunk :: struct {
	tag:     Tag,
	version: u32,
	data:    []u8,
}

// Builds a tree of chunks in memory. Initialize with `state_writer_init`;
// write with `begin_chunk`, the `write_*` procs and `end_chunk`; take the
// result with `state_writer_bytes`. A failed allocation is remembered in
// `err` and later writes do nothing. Control thread.
State_Writer :: struct {
	buf:  [dynamic]u8,
	open: [dynamic]int, // offsets of the size fields of chunks begun but not ended
	err:  Error,
}

// Prepares `w` for writing, allocating with `allocator`.
state_writer_init :: proc(w: ^State_Writer, allocator := context.allocator) {
	w^ = {buf = make([dynamic]u8, allocator), open = make([dynamic]int, allocator)}
}

// Frees what `w` allocated, including the bytes `state_writer_bytes`
// returned (clone them first to keep them).
state_writer_destroy :: proc(w: ^State_Writer) {
	delete(w.buf)
	delete(w.open)
	w^ = {}
}

// Everything written so far, or `w.err` if a write failed or a chunk is
// still open (`.Invalid_State`). The bytes belong to the writer.
state_writer_bytes :: proc(w: ^State_Writer) -> ([]u8, Error) {
	if w.err != .None do return nil, w.err
	if len(w.open) > 0 do return nil, .Invalid_State
	return w.buf[:], .None
}

// Starts a chunk inside the current one (or at the top level). Everything
// written until the matching `end_chunk` is its payload.
begin_chunk :: proc(w: ^State_Writer, tag: Tag, version: u32) {
	if w.err != .None do return
	t := tag
	write_raw(w, t[:])
	write_u32(w, version)
	if w.err != .None do return
	if _, err := append(&w.open, len(w.buf)); err != nil {
		w.err = .Out_Of_Memory
		return
	}
	write_u64(w, 0) // the size, filled in by end_chunk
}

// Ends the chunk `begin_chunk` started last.
end_chunk :: proc(w: ^State_Writer) {
	if w.err != .None do return
	if len(w.open) == 0 {
		w.err = .Invalid_State
		return
	}
	at := pop(&w.open)
	endian.put_u64(w.buf[at:at + 8], .Little, u64(len(w.buf) - at - 8))
}

// Writes a whole chunk whose payload is `data` (for state another component
// produced, such as a plug-in's).
write_chunk :: proc(w: ^State_Writer, tag: Tag, version: u32, data: []u8) {
	begin_chunk(w, tag, version)
	write_raw(w, data)
	end_chunk(w)
}

// Writes `data` as it is, with no length: for a payload saved earlier.
write_payload :: proc(w: ^State_Writer, data: []u8) {
	write_raw(w, data)
}

// Writes one byte.
write_u8 :: proc(w: ^State_Writer, v: u8) {
	b := [1]u8{v}
	write_raw(w, b[:])
}

// Writes `v` as one byte, 0 or 1.
write_bool :: proc(w: ^State_Writer, v: bool) {
	write_u8(w, 1 if v else 0)
}

// Writes a little-endian u32.
write_u32 :: proc(w: ^State_Writer, v: u32) {
	b: [4]u8
	endian.put_u32(b[:], .Little, v)
	write_raw(w, b[:])
}

// Writes a little-endian u64.
write_u64 :: proc(w: ^State_Writer, v: u64) {
	b: [8]u8
	endian.put_u64(b[:], .Little, v)
	write_raw(w, b[:])
}

// Writes a little-endian i64.
write_i64 :: proc(w: ^State_Writer, v: i64) {
	write_u64(w, u64(v))
}

// Writes `v` as a little-endian i64 (sizes and counts).
write_int :: proc(w: ^State_Writer, v: int) {
	write_u64(w, u64(i64(v)))
}

// Writes an IEEE 754 f64, little-endian.
write_f64 :: proc(w: ^State_Writer, v: f64) {
	write_u64(w, transmute(u64)v)
}

// Writes an IEEE 754 f32, little-endian.
write_f32 :: proc(w: ^State_Writer, v: f32) {
	write_u32(w, transmute(u32)v)
}

// Writes a length (u64) and then the bytes.
write_bytes :: proc(w: ^State_Writer, data: []u8) {
	write_u64(w, u64(len(data)))
	write_raw(w, data)
}

// Writes a string as `write_bytes` does (UTF-8, no terminator).
write_string :: proc(w: ^State_Writer, s: string) {
	write_bytes(w, transmute([]u8)s)
}

// Writes a count (u64) and then the samples as f32s.
write_f32s :: proc(w: ^State_Writer, samples: []f32) {
	write_u64(w, u64(len(samples)))
	when ODIN_ENDIAN == .Little {
		write_raw(w, mem.slice_to_bytes(samples))
	} else {
		for s in samples do write_f32(w, s)
	}
}

@(private)
write_raw :: proc(w: ^State_Writer, data: []u8) {
	if w.err != .None || len(data) == 0 do return
	if _, err := append(&w.buf, ..data); err != nil do w.err = .Out_Of_Memory
}

// Reads values and chunks from a payload (or a whole saved buffer), in
// order. Reading past the end, or a malformed chunk, sets `err` to
// `.Invalid_Data`; from then on every read returns zero. Never allocates
// unless a proc says so. Any thread.
State_Reader :: struct {
	data: []u8,
	pos:  int,
	err:  Error,
}

// A reader over `data` (a saved buffer, or a chunk's payload).
state_reader :: proc "contextless" (data: []u8) -> State_Reader {
	return {data = data}
}

// A reader over the payload of `c`.
chunk_reader :: proc "contextless" (c: Chunk) -> State_Reader {
	return {data = c.data}
}

// Reads the chunk at the reader's position and moves past it. `ok` is false
// at the end of the data (no error) or for a malformed chunk (`err` set).
read_chunk :: proc "contextless" (r: ^State_Reader) -> (c: Chunk, ok: bool) {
	if r.err != .None || r.pos >= len(r.data) do return {}, false
	if len(r.data) - r.pos < CHUNK_HEADER_SIZE {
		r.err = .Invalid_Data
		return {}, false
	}
	copy(c.tag[:], r.data[r.pos:r.pos + 4])
	c.version = endian.unchecked_get_u32le(r.data[r.pos + 4:])
	size := endian.unchecked_get_u64le(r.data[r.pos + 8:])
	start := r.pos + CHUNK_HEADER_SIZE
	if size > u64(len(r.data) - start) {
		r.err = .Invalid_Data
		return {}, false
	}
	c.data = r.data[start:start + int(size)]
	r.pos = start + int(size)
	return c, true
}

// Reads chunks until one tagged `tag` (skipping others). `ok` is false if
// there is none before the end.
find_chunk :: proc "contextless" (r: ^State_Reader, tag: Tag) -> (c: Chunk, ok: bool) {
	for {
		c = read_chunk(r) or_return
		if c.tag == tag do return c, true
	}
}

// Whether the reader is at the end of its data (or failed).
reader_done :: proc "contextless" (r: ^State_Reader) -> bool {
	return r.err != .None || r.pos >= len(r.data)
}

// Reads one byte.
read_u8 :: proc "contextless" (r: ^State_Reader) -> u8 {
	b := read_raw(r, 1)
	return b[0] if b != nil else 0
}

// Reads a byte written by `write_bool`.
read_bool :: proc "contextless" (r: ^State_Reader) -> bool {
	return read_u8(r) != 0
}

// Reads a little-endian u32.
read_u32 :: proc "contextless" (r: ^State_Reader) -> u32 {
	b := read_raw(r, 4)
	return endian.unchecked_get_u32le(b) if b != nil else 0
}

// Reads a little-endian u64.
read_u64 :: proc "contextless" (r: ^State_Reader) -> u64 {
	b := read_raw(r, 8)
	return endian.unchecked_get_u64le(b) if b != nil else 0
}

// Reads a little-endian i64.
read_i64 :: proc "contextless" (r: ^State_Reader) -> i64 {
	return i64(read_u64(r))
}

// Reads an i64 written by `write_int`, as an int.
read_int :: proc "contextless" (r: ^State_Reader) -> int {
	return int(read_i64(r))
}

// Reads an f64.
read_f64 :: proc "contextless" (r: ^State_Reader) -> f64 {
	return transmute(f64)read_u64(r)
}

// Reads an f32.
read_f32 :: proc "contextless" (r: ^State_Reader) -> f32 {
	return transmute(f32)read_u32(r)
}

// Reads bytes written by `write_bytes`: a slice of the reader's data (copy
// it to keep it past the data's lifetime).
read_bytes :: proc "contextless" (r: ^State_Reader) -> []u8 {
	n := read_u64(r)
	if r.err != .None do return nil
	if n > u64(len(r.data) - r.pos) {
		r.err = .Invalid_Data
		return nil
	}
	return read_raw(r, int(n))
}

// Reads a string written by `write_string`: a view of the reader's data
// (clone it to keep it).
read_string :: proc "contextless" (r: ^State_Reader) -> string {
	return string(read_bytes(r))
}

// Reads samples written by `write_f32s` into a new slice from `allocator`.
// Nil when there are none or on error (`r.err`; `.Out_Of_Memory` if the
// allocation failed).
read_f32s :: proc(r: ^State_Reader, allocator := context.allocator) -> []f32 {
	n := read_u64(r)
	if r.err != .None || n == 0 do return nil
	if n > u64(len(r.data) - r.pos) / 4 {
		r.err = .Invalid_Data
		return nil
	}
	out, err := make([]f32, int(n), allocator)
	if err != nil {
		r.err = .Out_Of_Memory
		return nil
	}
	b := read_raw(r, int(n) * 4)
	for &s, i in out do s = transmute(f32)endian.unchecked_get_u32le(b[4 * i:])
	return out
}

@(private)
read_raw :: proc "contextless" (r: ^State_Reader, n: int) -> []u8 {
	if r.err != .None do return nil
	if n > len(r.data) - r.pos {
		r.err = .Invalid_Data
		r.pos = len(r.data)
		return nil
	}
	b := r.data[r.pos:r.pos + n]
	r.pos += n
	return b
}

@(private)
native_separators :: proc(path: string) -> string {
	p, _ := filepath.replace_separators(path, os.Path_Separator, context.temp_allocator)
	return p
}

// --- saved state: node types -----------------------------------------------------------------

// What node `save` procs get: where the saved state will live, so file
// paths can be stored relative to it (see `write_path`).
Save_Context :: struct {
	dir: string, // directory of the file being saved; "" = paths stay as given
}

// A saved timeline ID and the ID it has after loading.
Timeline_Remap :: struct {
	saved, now: Timeline_Id,
}

// What node loaders get: how to find files and timelines saved alongside.
Load_Context :: struct {
	dir:       string, // directory of the file being loaded; "" = none
	timelines: []Timeline_Remap, // timelines restored before the nodes
	registry:  ^Node_Registry,   // for nodes that hold other nodes
	allocator: mem.Allocator,    // for anything kept past the load
	// The graph being loaded into (set by `graph.load`).
	sample_rate: f64,
	max_block:   int,
}

// Makes a node again from what its `Node_VTable.save` wrote: `r` reads the
// node's own chunk (`version` is that chunk's version) and `data` is what
// the type was registered with (a streamer, a plug-in host...). Control
// thread. Returns the node unprepared, as its `*_create` proc would.
Node_Loader :: proc(data: rawptr, r: ^State_Reader, version: u32, ctx: ^Load_Context, allocator: mem.Allocator) -> (Node, Error)

// A node type that saved state can name. `id` is stable forever once
// shipped and matches the vtable's `type_id`.
Node_Type :: struct {
	id:   string,
	load: Node_Loader,
	data: rawptr,
}

// The node types a load can make, by ID. Initialize with `registry_init`;
// each package registers its own types (`dsp.register_types`, ...), and
// apps add theirs with `register_type`. Control thread.
Node_Registry :: struct {
	types: map[string]Node_Type,
}

// Prepares an empty registry.
registry_init :: proc(reg: ^Node_Registry, allocator := context.allocator) {
	reg.types = make(map[string]Node_Type, allocator)
}

// Frees the registry (not what types were registered with).
registry_destroy :: proc(reg: ^Node_Registry) {
	delete(reg.types)
	reg^ = {}
}

// Adds `t`, replacing any type registered with the same ID. `t.id` must
// outlive the registry (a constant, typically).
register_type :: proc(reg: ^Node_Registry, t: Node_Type) -> Error {
	if t.id == "" || t.load == nil do return .Invalid_Argument
	reg.types[t.id] = t
	return .None
}

// The type registered as `id`.
find_type :: proc(reg: ^Node_Registry, id: string) -> (Node_Type, bool) {
	if reg == nil do return {}, false
	t, ok := reg.types[id]
	return t, ok
}

// The ID a loaded timeline has now (`saved` itself when the load did not
// restore that timeline).
load_timeline :: proc(ctx: ^Load_Context, saved: Timeline_Id) -> Timeline_Id {
	if ctx != nil do for m in ctx.timelines do if m.saved == saved do return m.now
	return saved
}

// Writes a file path so it can be found again if the saved state moves with
// its files: the path as given (made absolute), and relative to `ctx.dir`.
write_path :: proc(w: ^State_Writer, ctx: ^Save_Context, path: string) {
	abs, rel := path, ""
	if a, err := filepath.abs(path, context.temp_allocator); err == nil do abs = a
	if ctx != nil && ctx.dir != "" {
		if r, err := filepath.rel(ctx.dir, abs, context.temp_allocator); err == nil do rel = r
	}
	write_string(w, abs)
	if rel != "" do rel, _ = filepath.replace_separators(rel, '/', context.temp_allocator)
	write_string(w, rel)
}

// Reads a path written by `write_path`: the relative path under `ctx.dir`
// if that file exists, else the absolute one. Allocated with `allocator`.
read_path :: proc(r: ^State_Reader, ctx: ^Load_Context, allocator := context.allocator) -> string {
	abs := read_string(r)
	rel := read_string(r)
	if r.err != .None do return ""
	if rel != "" && ctx != nil && ctx.dir != "" {
		p, err := filepath.join({ctx.dir, native_separators(rel)}, allocator)
		if err == nil {
			if os.exists(p) do return p
			delete(p, allocator)
		}
	}
	s, _ := strings.clone(abs, allocator)
	return s
}
