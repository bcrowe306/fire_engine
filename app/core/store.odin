package app

import "core:slice"

import fc "fire:core"

// A stable name for an entity of the model (a pad, a sequence, an effect
// slot). Never reused within a document, so undo steps, saved files and the
// engine can refer to entities safely. 0 is no entity.
Id :: distinct u64

// Hands out `Id`s. Save `next` with the document so ids stay unique after
// loading.
Ids :: struct {
	next: Id,
}

// A new id.
new_id :: proc(ids: ^Ids) -> Id {
	if ids.next == 0 do ids.next = 1
	id := ids.next
	ids.next += 1
	return id
}

// Entities of one type, by id, in a stable order (the order they were
// added, or `move` set). Pointers from `get` stay valid until the next
// `add` or `remove`.
Store :: struct($T: typeid) {
	items: [dynamic]Item(T),
}

// One entity in a `Store`.
Item :: struct($T: typeid) {
	id:    Id,
	value: T,
}

// Prepares an empty store.
store_init :: proc(s: ^Store($T), allocator := context.allocator) {
	s.items = make([dynamic]Item(T), allocator)
}

// Frees the store (not what its values own).
store_destroy :: proc(s: ^Store($T)) {
	delete(s.items)
	s^ = {}
}

// Adds `value` as `id` at `index` (-1 = the end). False if `id` is taken.
store_add :: proc(s: ^Store($T), id: Id, value: T, index := -1) -> bool {
	if store_index(s, id) >= 0 do return false
	if index < 0 || index >= len(s.items) {
		append(&s.items, Item(T){id, value})
	} else {
		inject_at(&s.items, index, Item(T){id, value})
	}
	return true
}

// Removes `id`; returns its value and position (for undo), or ok = false.
store_remove :: proc(s: ^Store($T), id: Id) -> (value: T, index: int, ok: bool) {
	index = store_index(s, id)
	if index < 0 do return {}, -1, false
	value = s.items[index].value
	ordered_remove(&s.items, index)
	return value, index, true
}

// The value of `id`, or nil.
store_get :: proc(s: ^Store($T), id: Id) -> ^T {
	i := store_index(s, id)
	return &s.items[i].value if i >= 0 else nil
}

// The position of `id`, or -1.
store_index :: proc(s: ^Store($T), id: Id) -> int {
	for it, i in s.items do if it.id == id do return i
	return -1
}

// Moves `id` to position `index`.
store_move :: proc(s: ^Store($T), id: Id, index: int) -> bool {
	from := store_index(s, id)
	if from < 0 do return false
	it := s.items[from]
	ordered_remove(&s.items, from)
	inject_at(&s.items, clamp(index, 0, len(s.items)), it)
	return true
}

// How many entities the store holds.
store_len :: proc(s: ^Store($T)) -> int {
	return len(s.items)
}

// The ids in order (allocated with `allocator`).
store_ids :: proc(s: ^Store($T), allocator := context.allocator) -> []Id {
	out := make([]Id, len(s.items), allocator)
	for it, i in s.items do out[i] = it.id
	return out
}

// Writes the store as a chunk tagged `tag`: each entity's id, then what
// `write` writes for its value. Values are versioned by `version`.
store_save :: proc(w: ^fc.State_Writer, tag: fc.Tag, version: u32, s: ^Store($T), write: proc(w: ^fc.State_Writer, value: ^T)) {
	fc.begin_chunk(w, tag, version)
	fc.write_int(w, len(s.items))
	for &it in s.items {
		fc.write_u64(w, u64(it.id))
		fc.begin_chunk(w, {'I', 'T', 'E', 'M'}, version)
		write(w, &it.value)
		fc.end_chunk(w)
	}
	fc.end_chunk(w)
}

// Reads a store written by `store_save` from chunk `c` into `s` (which
// should be empty). `read` gets each value's reader and the chunk's
// version; it returns false to reject the data. `.Invalid_Data` for a
// malformed chunk or a rejected value.
store_load :: proc(c: fc.Chunk, s: ^Store($T), read: proc(r: ^fc.State_Reader, version: u32, value: ^T) -> bool) -> fc.Error {
	r := fc.chunk_reader(c)
	count := fc.read_int(&r)
	if r.err != .None || count < 0 || count > len(c.data) / 24 do return .Invalid_Data
	reserve(&s.items, count)
	seen := make(map[Id]struct{}, count, context.temp_allocator) // ids are unique; checked in O(n)
	for _ in 0 ..< count {
		id := Id(fc.read_u64(&r))
		ic, ok := fc.read_chunk(&r)
		if !ok || id == 0 || id in seen do return .Invalid_Data
		seen[id] = {}
		v: T
		ir := fc.chunk_reader(ic)
		if !read(&ir, ic.version, &v) || ir.err != .None do return .Invalid_Data
		append(&s.items, Item(T){id, v})
	}
	return r.err
}

// Sorts the store by `less` (a stable sort).
store_sort :: proc(s: ^Store($T), less: proc(a, b: Item(T)) -> bool) {
	slice.stable_sort_by(s.items[:], less)
}

// --- documents -----------------------------------------------------------------------------

// Chunk tag of the part of a document the library keeps (its id counter);
// apps put their own chunks next to it.
DOCUMENT_TAG :: fc.Tag{'A', 'D', 'O', 'C'}

// Writes the library's document state (the id counter) as a DOCUMENT_TAG
// chunk.
document_save :: proc(w: ^fc.State_Writer, ids: ^Ids) {
	fc.begin_chunk(w, DOCUMENT_TAG, 1)
	fc.write_u64(w, u64(ids.next))
	fc.end_chunk(w)
}

// Reads what `document_save` wrote.
document_load :: proc(c: fc.Chunk, ids: ^Ids) -> fc.Error {
	r := fc.chunk_reader(c)
	ids.next = Id(fc.read_u64(&r))
	return r.err
}

_ :: slice.stable_sort_by // used by store_sort (generic)
