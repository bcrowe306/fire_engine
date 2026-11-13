package pads_model

import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"

import app "app:core"

// How much of a project's cache the project doesn't use now is kept
// (renderings for a warp mode or a comp undone, a tempo played before):
// past this, the oldest go.
CACHE_KEEP_BYTES :: 1 << 30

// Trims project `p`'s cache (`cache/warp`, `cache/comp`): keeps every
// rendering it plays now (its warped pads at the project's tempo and each
// sequence's, its audio parts' comps), and of the rest the newest, up to
// `keep` bytes; removes the others, and what a rendering left half-made.
// Removes an older project's `warped/` and `renders/` (caches nothing
// names now). `cache/recording` is left alone. Call with no rendering
// under way (`engine_clear` / `engine_destroy` first). Returns what was
// removed, in bytes.
cache_trim :: proc(p: ^Project, keep: i64 = CACHE_KEEP_BYTES) -> (removed: i64) {
	if p.dir == "" do return
	for old in ([]string{"warped", "renders"}) {
		d, _ := filepath.join({p.dir, old}, context.temp_allocator)
		if os.is_dir(d) {
			removed += folder_bytes(d)
			os.remove_all(d)
		}
	}
	wanted := cache_wanted(p)
	Spare :: struct { path: string, size: i64, time: time.Time }
	spare := make([dynamic]Spare, context.temp_allocator)
	for f in ([]Project_Folder{.Warp, .Comp}) {
		dir := project_folder(p.dir, f)
		h, err := os.open(dir)
		if err != nil do continue
		infos, _ := os.read_dir(h, -1, context.temp_allocator)
		os.close(h)
		for fi in infos {
			if fi.type == .Directory do continue
			path, _ := filepath.join({dir, fi.name}, context.temp_allocator)
			if strings.has_suffix(fi.name, ".part") { // (a rendering stopped half-way)
				if os.remove(path) == nil do removed += fi.size
				continue
			}
			if path in wanted do continue
			append(&spare, Spare{path, fi.size, fi.modification_time})
		}
	}
	slice.sort_by(spare[:], proc(a, b: Spare) -> bool { return time.diff(b.time, a.time) > 0 }) // newest first (b to a forward: a is newer)
	kept: i64
	for s in spare {
		if kept + s.size <= keep {
			kept += s.size
			continue
		}
		if os.remove(s.path) == nil do removed += s.size
	}
	return
}

// The cache files project `p` plays now (temporary allocator).
@(private)
cache_wanted :: proc(p: ^Project) -> map[string]bool {
	wanted := make(map[string]bool, allocator = context.temp_allocator)
	tempos := make([dynamic]f64, context.temp_allocator)
	append(&tempos, p.bpm)
	for _, slot in p.sequences do if t := sequence_tempo(p, slot); !slice.contains(tempos[:], t) do append(&tempos, t)
	for pad in p.pads {
		if !pad.warp.on do continue
		s := app.store_get(&p.samples, pad.sample)
		if s == nil do continue
		tr := warp_transpose(pad)
		for t in tempos {
			r := warp_ratio(pad, t)
			if r == 1 && tr == 0 do continue
			wanted[warp_path(p, s.path, pad.warp, r, tr)] = true
		}
	}
	for slot in 0 ..< len(p.sequences) do for pad in 0 ..< PADS {
		if p.clips[slot][pad].part == 0 do continue
		wanted[comp_path(p, slot, pad, part_of(p, slot, pad))] = true
	}
	return wanted
}

// The bytes of every file in folder `dir`, its folders' too.
@(private)
folder_bytes :: proc(dir: string) -> (n: i64) {
	h, err := os.open(dir)
	if err != nil do return
	infos, _ := os.read_dir(h, -1, context.temp_allocator)
	os.close(h)
	for fi in infos {
		if fi.type == .Directory {
			sub, _ := filepath.join({dir, fi.name}, context.temp_allocator)
			n += folder_bytes(sub)
		} else do n += fi.size
	}
	return
}
