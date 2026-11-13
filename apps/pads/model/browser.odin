package pads_model

import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"

// Audio files the browser lists (by extension, any case).
AUDIO_EXTS := []string{".wav", ".aif", ".aiff", ".flac", ".mp3", ".ogg"}

// A favourite: a folder the browser has a tab for. `project` follows the
// open project's samples folder (its path is not kept).
Favorite :: struct {
	name:    string,
	path:    string,
	project: bool,
}

// A file or folder in the browser.
Browser_Entry :: struct {
	name:   string,
	path:   string,
	is_dir: bool,
	depth:  int, // in the tree: 0 under the root
}

// The sample browser, headless: favourites (its tabs), a tree of folders
// from a root with back, forward and up, the rows as shown (for the
// keyboard), the selection, and a search through every folder under the
// folder shown (on its own thread). Strings it holds are its own.
Browser :: struct {
	favorites: [dynamic]Favorite,
	tab:       int,
	root:      string, // the folder the tree shows
	back:      [dynamic]string,
	forward:   [dynamic]string,
	expanded:  map[string]bool, // folders open in the tree (by path)
	listings:  map[string][]Browser_Entry, // folders read (cleared by `browser_refresh`)
	rows:      [dynamic]Browser_Entry, // the tree as shown (views of `listings`)
	rows_dirty: bool,
	selected:  string, // the selected row's path ("" = none)
	project_dir: string, // where the project tab points (its samples folder)
	search:    Search,
}

// A search: file names containing `query` (any case) under `root`, found
// on a thread. Read `results` under `lock`.
Search :: struct {
	query:   string,
	root:    string,
	lock:    sync.Mutex,
	results: [dynamic]Browser_Entry, // name relative to root, path absolute
	scanned: int,  // folders and files looked at (atomic)
	done:    bool, // atomic
	cancel:  bool, // atomic
	worker:  ^thread.Thread,
}

// Most results a search keeps.
SEARCH_MAX_RESULTS :: 2000
// Most files and folders a search looks at.
SEARCH_MAX_SCANNED :: 300_000

// The user's documents folder (the default tab), or their home.
documents_dir :: proc(allocator := context.allocator) -> string {
	home := os.get_env("HOME", context.temp_allocator)
	if home == "" do home = os.get_env("USERPROFILE", context.temp_allocator)
	docs, _ := filepath.join({home, "Documents"}, context.temp_allocator)
	return strings.clone(docs if os.is_dir(docs) else home, allocator)
}

// Starts a browser: the favourites in `favorites_file` (one per line,
// "name<TAB>path"; "<project>" as the path is the project's samples), or
// Documents and the project's samples if there are none.
browser_init :: proc(b: ^Browser, favorites_file := "") {
	b.favorites = make([dynamic]Favorite)
	b.expanded = make(map[string]bool)
	b.listings = make(map[string][]Browser_Entry)
	if favorites_file != "" do favorites_load(b, favorites_file)
	if len(b.favorites) == 0 {
		append(&b.favorites, Favorite{name = strings.clone("Documents"), path = documents_dir()})
		append(&b.favorites, Favorite{name = strings.clone("Project"), project = true})
	}
	browser_set_tab(b, 0)
}

// Frees the browser (stopping a search).
browser_destroy :: proc(b: ^Browser) {
	search_stop(&b.search)
	for f in b.favorites do favorite_free(f)
	delete(b.favorites)
	clear_history(b)
	delete(b.back)
	delete(b.forward)
	browser_refresh(b)
	delete(b.listings)
	for k in b.expanded do delete(k)
	delete(b.expanded)
	delete(b.rows)
	delete(b.root)
	delete(b.selected)
	delete(b.project_dir)
}

@(private)
favorite_free :: proc(f: Favorite) {
	delete(f.name)
	delete(f.path)
}

@(private)
clear_history :: proc(b: ^Browser) {
	for s in b.back do delete(s)
	for s in b.forward do delete(s)
	clear(&b.back)
	clear(&b.forward)
}

// Where favourite `i` points (the project's samples folder for the
// project tab), or "".
favorite_dir :: proc(b: ^Browser, i: int) -> string {
	if i < 0 || i >= len(b.favorites) do return ""
	f := b.favorites[i]
	if f.project {
		if b.project_dir == "" do return ""
		return project_samples_root(b.project_dir)
	}
	return f.path
}

// Tells the browser where the open project is (its tab follows it).
browser_set_project :: proc(b: ^Browser, project_dir: string) {
	if b.project_dir == project_dir do return
	delete(b.project_dir)
	b.project_dir = strings.clone(project_dir)
	if b.tab >= 0 && b.tab < len(b.favorites) && b.favorites[b.tab].project do browser_set_tab(b, b.tab)
}

// Shows favourite `i`: its folder is the root, with a fresh history.
browser_set_tab :: proc(b: ^Browser, i: int) {
	if len(b.favorites) == 0 do return
	b.tab = clamp(i, 0, len(b.favorites) - 1)
	clear_history(b)
	set_root(b, favorite_dir(b, b.tab))
}

@(private)
set_root :: proc(b: ^Browser, dir: string) {
	if dir == b.root do return
	next := strings.clone(dir)
	delete(b.root)
	b.root = next
	b.rows_dirty = true
	if b.search.query != "" do browser_search(b, strings.clone(b.search.query, context.temp_allocator)) // the new folder's
}

// Opens folder `dir` as the root (its parent goes on the back list).
browser_go :: proc(b: ^Browser, dir: string) {
	if dir == "" || dir == b.root do return
	append(&b.back, strings.clone(b.root))
	for s in b.forward do delete(s)
	clear(&b.forward)
	set_root(b, dir)
}

// The folder above the root (owned by the temporary allocator), or "" at
// the top of the file system.
parent_of :: proc(dir: string) -> string {
	d := strings.trim_right(dir, "/\\")
	if d == "" do return ""
	parent := filepath.dir(d) // a view of `d`: copied before anything frees it
	if parent == "" || parent == "." || parent == d do return ""
	return strings.clone(parent, context.temp_allocator)
}

// Up a folder (onto the back list). False at the top.
browser_up :: proc(b: ^Browser) -> bool {
	parent := parent_of(b.root)
	if parent == "" do return false
	browser_go(b, parent)
	return true
}

// Back to where the root was before. False if there is nowhere.
browser_back :: proc(b: ^Browser) -> bool {
	if len(b.back) == 0 do return false
	prev := pop(&b.back)
	append(&b.forward, strings.clone(b.root))
	set_root(b, prev)
	delete(prev)
	return true
}

// Forward again (after back). False if there is nowhere.
browser_forward :: proc(b: ^Browser) -> bool {
	if len(b.forward) == 0 do return false
	next := pop(&b.forward)
	append(&b.back, strings.clone(b.root))
	set_root(b, next)
	delete(next)
	return true
}

// The root's path as clickable parts, from the top of the file system:
// each part's name and the folder it opens (temporary allocator).
browser_crumbs :: proc(b: ^Browser) -> []Browser_Entry {
	parts := make([dynamic]Browser_Entry, context.temp_allocator)
	at := b.root
	for at != "" && len(parts) < 64 {
		name := filepath.base(at)
		if name == "" || name == "/" || name == "\\" do name = at
		inject_at(&parts, 0, Browser_Entry{name = name, path = at, is_dir = true})
		at = parent_of(at)
	}
	return parts[:]
}

// A folder's subfolders and audio files, folders first, by name (any
// case). Symbolic links to folders count as folders. Read once and kept
// until `browser_refresh`; nil if it can't be read.
browser_list :: proc(b: ^Browser, dir: string) -> []Browser_Entry {
	if l, ok := b.listings[dir]; ok do return l
	l := list_dir(dir)
	b.listings[strings.clone(dir)] = l
	return l
}

@(private)
list_dir :: proc(dir: string, allocator := context.allocator) -> []Browser_Entry {
	infos, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil do return nil
	out := make([dynamic]Browser_Entry, allocator)
	for fi in infos {
		if strings.has_prefix(fi.name, ".") do continue
		full, _ := filepath.join({dir, fi.name}, context.temp_allocator)
		is_dir := fi.type == .Directory
		if fi.type == .Symlink do is_dir = os.is_dir(full) // follow links to folders
		if !is_dir && !is_listed(fi.name) do continue
		append(&out, Browser_Entry{name = strings.clone(fi.name, allocator), path = strings.clone(full, allocator), is_dir = is_dir})
	}
	slice.sort_by(out[:], proc(x, y: Browser_Entry) -> bool {
		if x.is_dir != y.is_dir do return x.is_dir
		return strings.to_lower(x.name, context.temp_allocator) < strings.to_lower(y.name, context.temp_allocator)
	})
	return out[:]
}

// Whether the browser lists a file: a sound, or a MIDI file (to drag onto
// a pad or the sequence).
is_listed :: proc(name: string) -> bool {
	return is_audio(name) || is_midi(name)
}

// Whether a file is a MIDI file (by its name).
is_midi :: proc(name: string) -> bool {
	ext := strings.to_lower(filepath.ext(name), context.temp_allocator)
	return ext == ".mid" || ext == ".midi"
}

// Whether `name` is an audio file (by its name).
is_audio :: proc(name: string) -> bool {
	ext := strings.to_lower(filepath.ext(name), context.temp_allocator)
	return slice.contains(AUDIO_EXTS, ext)
}

// Forgets every folder read (they are read again when shown).
browser_refresh :: proc(b: ^Browser) {
	for k, l in b.listings {
		for e in l {
			delete(e.name)
			delete(e.path)
		}
		delete(l)
		delete(k)
	}
	clear(&b.listings)
	b.rows_dirty = true
}

// Opens or closes folder `dir` in the tree.
browser_toggle :: proc(b: ^Browser, dir: string) {
	browser_expand(b, dir, !b.expanded[dir])
}

// Opens (or closes) folder `dir` in the tree.
browser_expand :: proc(b: ^Browser, dir: string, open: bool) {
	if open == b.expanded[dir] do return
	if open {
		b.expanded[strings.clone(dir)] = true
	} else if k, _, ok := map_entry_key(&b.expanded, dir); ok {
		delete_key(&b.expanded, dir)
		delete(k)
	}
	b.rows_dirty = true
}

@(private)
map_entry_key :: proc(m: ^map[string]bool, key: string) -> (k: string, v: bool, ok: bool) {
	for kk, vv in m do if kk == key do return kk, vv, true
	return
}

// The tree as shown, top to bottom: the root's entries, and inside each
// open folder its own (indented).
browser_rows :: proc(b: ^Browser) -> []Browser_Entry {
	if !b.rows_dirty do return b.rows[:]
	clear(&b.rows)
	add :: proc(b: ^Browser, dir: string, depth: int) {
		if depth > 32 do return
		for e in browser_list(b, dir) {
			row := e
			row.depth = depth
			append(&b.rows, row)
			if e.is_dir && b.expanded[e.path] do add(b, e.path, depth + 1)
		}
	}
	if b.root != "" do add(b, b.root, 0)
	b.rows_dirty = false
	return b.rows[:]
}

// Selects the row with path `path` ("" for none).
browser_select :: proc(b: ^Browser, path: string) {
	if path == b.selected do return
	next := strings.clone(path)
	delete(b.selected)
	b.selected = next
}

// Moves the selection `delta` rows in `rows` (the tree, or a search's
// results) and returns the newly selected row; the first row if none was.
browser_step :: proc(b: ^Browser, rows: []Browser_Entry, delta: int) -> (Browser_Entry, bool) {
	if len(rows) == 0 do return {}, false
	at := -1
	for r, i in rows do if r.path == b.selected {
		at = i
		break
	}
	next := 0 if at < 0 else clamp(at + delta, 0, len(rows) - 1)
	browser_select(b, rows[next].path)
	return rows[next], true
}

// --- favourites ----------------------------------------------------------------------------

// Adds folder `path` as a favourite named `name` (its folder's name if
// ""), unless it is one already. Returns its tab.
favorite_add :: proc(b: ^Browser, path: string, name := "") -> int {
	for f, i in b.favorites do if !f.project && f.path == path do return i
	n := name if name != "" else filepath.base(path)
	append(&b.favorites, Favorite{name = strings.clone(n), path = strings.clone(path)})
	return len(b.favorites) - 1
}

// Removes favourite `i` (the last one stays).
favorite_remove :: proc(b: ^Browser, i: int) {
	if i < 0 || i >= len(b.favorites) || len(b.favorites) <= 1 do return
	favorite_free(b.favorites[i])
	ordered_remove(&b.favorites, i)
	if b.tab >= len(b.favorites) || b.tab == i do browser_set_tab(b, min(b.tab, len(b.favorites) - 1))
	else if b.tab > i do b.tab -= 1
}

// Renames favourite `i`.
favorite_rename :: proc(b: ^Browser, i: int, name: string) {
	if i < 0 || i >= len(b.favorites) || name == "" do return
	delete(b.favorites[i].name)
	b.favorites[i].name = strings.clone(name)
}

// Moves favourite `from` to place `to` (the shown tab moves with it).
favorite_move :: proc(b: ^Browser, from, to: int) {
	n := len(b.favorites)
	if from < 0 || from >= n || to < 0 || to >= n || from == to do return
	f := b.favorites[from]
	ordered_remove(&b.favorites, from)
	inject_at(&b.favorites, to, f)
	if b.tab == from do b.tab = to
	else if from < b.tab && to >= b.tab do b.tab -= 1
	else if from > b.tab && to <= b.tab do b.tab += 1
}

// Whether `dir` is a favourite.
is_favorite :: proc(b: ^Browser, dir: string) -> bool {
	for f in b.favorites do if !f.project && f.path == dir do return true
	return false
}

// Reads favourites from `path` (replacing any). False if there is no file.
favorites_load :: proc(b: ^Browser, path: string) -> bool {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return false
	for f in b.favorites do favorite_free(f)
	clear(&b.favorites)
	for line in strings.split_lines(string(data), context.temp_allocator) {
		l := strings.trim_right(line, "\r")
		tab := strings.index_byte(l, '\t')
		if tab <= 0 do continue
		name, dir := l[:tab], l[tab + 1:]
		if dir == "<project>" {
			append(&b.favorites, Favorite{name = strings.clone(name), project = true})
		} else if dir != "" {
			append(&b.favorites, Favorite{name = strings.clone(name), path = strings.clone(dir)})
		}
	}
	return true
}

// Writes the favourites to `path`.
favorites_save :: proc(b: ^Browser, path: string) -> bool {
	sb := strings.builder_make(context.temp_allocator)
	for f in b.favorites {
		strings.write_string(&sb, f.name)
		strings.write_byte(&sb, '\t')
		strings.write_string(&sb, "<project>" if f.project else f.path)
		strings.write_byte(&sb, '\n')
	}
	return os.write_entire_file(path, sb.buf[:]) == nil
}

// --- search --------------------------------------------------------------------------------

// Searches every folder under the one shown for file names containing
// `query` (any case); "" stops searching. The results fill in as it goes.
browser_search :: proc(b: ^Browser, query: string) {
	s := &b.search
	root := b.root
	if query == s.query && root == s.root && s.worker != nil do return
	search_stop(s)
	if query == "" || root == "" do return
	s.query = strings.clone(query)
	s.root = strings.clone(root)
	s.worker = thread.create_and_start_with_poly_data(s, search_run)
}

// Stops a search and frees its results.
search_stop :: proc(s: ^Search) {
	if s.worker != nil {
		sync.atomic_store(&s.cancel, true)
		thread.join(s.worker)
		thread.destroy(s.worker)
	}
	for r in s.results {
		delete(r.name)
		delete(r.path)
	}
	delete(s.results)
	delete(s.query)
	delete(s.root)
	s^ = {}
}

// Whether the search has finished (or stopped at its limits).
search_done :: proc(s: ^Search) -> bool {
	return sync.atomic_load(&s.done)
}

// A copy of the results so far (temporary allocator; the strings are the
// search's, valid until it stops).
search_results :: proc(s: ^Search) -> []Browser_Entry {
	sync.guard(&s.lock)
	return slice.clone(s.results[:], context.temp_allocator)
}

// [search thread] Walks the folders under the root, breadth first.
@(private)
search_run :: proc(s: ^Search) {
	defer sync.atomic_store(&s.done, true)
	needle := strings.to_lower(s.query)
	defer delete(needle)
	queue := make([dynamic]string)
	defer {
		for q in queue do delete(q)
		delete(queue)
	}
	append(&queue, strings.clone(s.root))
	found := 0
	for len(queue) > 0 && !sync.atomic_load(&s.cancel) {
		dir := pop_front(&queue)
		defer delete(dir)
		infos, err := os.read_all_directory_by_path(dir, context.allocator)
		if err != nil do continue
		defer os.file_info_slice_delete(infos, context.allocator)
		for fi in infos {
			if sync.atomic_add(&s.scanned, 1) >= SEARCH_MAX_SCANNED do return
			if strings.has_prefix(fi.name, ".") do continue
			full, _ := filepath.join({dir, fi.name})
			is_dir := fi.type == .Directory || (fi.type == .Symlink && os.is_dir(full))
			if is_dir && fi.type == .Directory { // links aren't followed: no loops
				append(&queue, full)
				continue
			}
			lower := strings.to_lower(fi.name, context.temp_allocator)
			if is_dir || !is_listed(fi.name) || !strings.contains(lower, needle) {
				delete(full)
				continue
			}
			rel, _ := filepath.rel(s.root, full)
			sync.guard(&s.lock)
			append(&s.results, Browser_Entry{name = rel, path = full})
			found += 1
			if found >= SEARCH_MAX_RESULTS do return
		}
		free_all(context.temp_allocator)
	}
}
