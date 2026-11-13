package pads_model

import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

import app "app:core"

// What Clean Up Project would move to the Trash (`unused_files`).
Unused_Kind :: enum u8 {
	Unused,    // a file in the project's samples folders no sample of the project is
	Undo_Only, // a sample nothing plays now (replaced, deleted): only undoing would bring it back
	Cache,     // the cache: renderings, made again when needed
}

// A file (or the cache folder) Clean Up offers.
Unused_File :: struct {
	path:   string, // (temporary allocator)
	size:   i64,
	kind:   Unused_Kind,
	sample: app.Id, // Undo_Only: its sample
}

// The samples project `p` plays now: its pads', synths' and wavetables',
// its audio tracks' clips and parts' takes, its freezes'; and `extra`
// (what the app holds, its clipboard). Temporary allocator.
samples_in_use :: proc(p: ^Project, extra: []app.Id = nil) -> map[app.Id]bool {
	used := make(map[app.Id]bool, allocator = context.temp_allocator)
	add :: proc(used: ^map[app.Id]bool, id: app.Id) { if id != 0 do used[id] = true }
	for pad in p.pads {
		add(&used, pad.sample)
		for t in pad.synth.tables do add(&used, t.sample)
	}
	for it in p.wave_docs.items do add(&used, it.value.sample)
	clip :: proc(p: ^Project, used: ^map[app.Id]bool, c: Clip) {
		add(used, c.sample)
		if x := app.store_get(&p.parts, c.part); x != nil && c.part != 0 do for t in x.takes[:x.take_count] do add(used, t)
	}
	for slot in 0 ..< SLOTS do for pad in 0 ..< PADS {
		clip(p, &used, p.clips[slot][pad])
		clip(p, &used, p.freezes[slot][pad])
	}
	for id in extra do add(&used, id)
	return used
}

// What Clean Up Project offers, biggest first: files in the project's
// `Samples/` (and an older project's `samples/`) that no sample of it
// is; the files of samples nothing plays now (`extra`: ids the app still
// holds); the cache, if there is one. Temporary allocator.
unused_files :: proc(m: ^Model, extra: []app.Id = nil) -> []Unused_File {
	p := &m.project
	out := make([dynamic]Unused_File, context.temp_allocator)
	known := make(map[string]app.Id, allocator = context.temp_allocator)
	for &it in p.samples.items do known[strings.to_lower(stored_path(p.dir, it.value.path), context.temp_allocator)] = it.id // (case aside: Samples/x and samples/x may be one file)
	used := samples_in_use(p, extra)
	// (Its folders as the folder lists them: where names' case doesn't
	// count, Samples and an older samples are one folder, listed once.)
	if h, err := os.open(p.dir); err == nil {
		infos, _ := os.read_dir(h, -1, context.temp_allocator)
		os.close(h)
		for fi in infos do if fi.type == .Directory && (fi.name == SAMPLES_FOLDER || fi.name == "samples") {
			dir, _ := filepath.join({p.dir, fi.name}, context.temp_allocator)
			walk_files(dir, &out, known, p.dir)
		}
	}
	for &it in p.samples.items {
		if it.id in used || !strings.has_prefix(it.value.path, p.dir) do continue // (a file outside the project isn't its to remove)
		fi, err := os.stat(it.value.path, context.temp_allocator)
		if err != nil do continue
		append(&out, Unused_File{strings.clone(it.value.path, context.temp_allocator), fi.size, .Undo_Only, it.id})
	}
	cache, _ := filepath.join({p.dir, CACHE_FOLDER}, context.temp_allocator)
	if os.is_dir(cache) {
		if n := folder_bytes(cache); n > 0 do append(&out, Unused_File{cache, n, .Cache, 0})
	}
	slice.sort_by(out[:], proc(a, b: Unused_File) -> bool { return a.size > b.size })
	return out[:]
}

@(private)
walk_files :: proc(dir: string, out: ^[dynamic]Unused_File, known: map[string]app.Id, project: string) {
	h, err := os.open(dir)
	if err != nil do return
	infos, _ := os.read_dir(h, -1, context.temp_allocator)
	os.close(h)
	for fi in infos {
		path, _ := filepath.join({dir, fi.name}, context.temp_allocator)
		if fi.type == .Directory {
			walk_files(path, out, known, project)
			continue
		}
		if strings.has_prefix(fi.name, ".") || strings.to_lower(stored_path(project, path), context.temp_allocator) in known do continue // (.DS_Store and the like aren't the project's)
		append(out, Unused_File{path, fi.size, .Unused, 0})
	}
}

// Moves `files` (from `unused_files`) to the Trash with `trash`
// (`app.move_to_trash`), then saves the project so its file agrees with
// its folder. A sample only undoing used leaves the project with its
// file, and the undo history is forgotten (it could bring it back); for
// the others, what can be redone is (an import undone). Returns how many
// went and their bytes.
clean_up :: proc(m: ^Model, files: []Unused_File, trash: proc(path: string) -> bool) -> (moved: int, bytes: i64) {
	p := &m.project
	forgot := false
	if len(files) == 0 do return
	mark_all_sources_stale(&m.engine) // (every file let go first, renderings under way finished: a file open can't go everywhere)
	for f in files {
		if !trash(f.path) do continue
		moved += 1
		bytes += f.size
		if f.kind == .Undo_Only {
			app.store_remove(&p.samples, f.sample)
			forgot = true
		}
	}
	if moved == 0 do return
	if forgot do app.history_clear(&m.history)
	else do app.history_clear_redo(&m.history)
	model_save(m)
	return
}
