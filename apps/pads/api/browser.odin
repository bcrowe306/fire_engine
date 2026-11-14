package pads_api

import "core:os"
import "core:path/filepath"
import "core:strings"

import pm "../model"

// The Library's browser now.
Browser_State :: struct {
	tab:         i64,  // the favourite shown (browser_favorite_name)
	favorites:   i64,  // its favourites (the project's folder among them)
	rows:        i64,  // the folder tree as shown (browser_row)
	can_back:    bool,
	can_forward: bool,
	results:     i64,  // a search's results so far (browser_result)
	searching:   bool, // a search is under way
	previewing:  bool, // a file is being previewed
}

// A row of the browser's tree, or a search result.
Browser_Row :: struct {
	is_dir: bool,
	depth:  i64, // in the tree: 0 under the root
}

// Preview settings: it plays a file chosen (auto), stretched to the tempo
// (sync), at `volume_db`.
Preview_Settings :: struct {
	auto_play: bool,
	sync:      bool,
	volume_db: f32, // -60..6
}

// The browser now.
browser_state :: proc(api: ^Api) -> (Browser_State, Result) {
	b := &api.core.browser
	return {
		tab = i64(b.tab), favorites = i64(len(b.favorites)), rows = i64(len(pm.browser_rows(b))), can_back = len(b.back) > 0, can_forward = len(b.forward) > 0,
		results = i64(len(pm.search_results(&b.search))), searching = b.search.query != "" && !pm.search_done(&b.search), previewing = pm.preview_playing(&api.core.m.engine),
	}, .Ok
}

// The folder the tree shows. Temporary.
browser_folder :: proc(api: ^Api) -> (string, Result) {
	return api.core.browser.root, .Ok
}

// The selected file or folder ("" none). Temporary.
browser_selected :: proc(api: ^Api) -> (string, Result) {
	return api.core.browser.selected, .Ok
}

// Shows folder `dir` (the one before goes on the back list). Not_Found if
// it isn't a folder.
browser_go :: proc(api: ^Api, dir: string) -> Result {
	if !is_dir(dir) do return fail(api, .Not_Found, "no such folder")
	pm.browser_go(&api.core.browser, dir)
	return .Ok
}

// Up a folder. Not_Found at the top.
browser_up :: proc(api: ^Api) -> Result {
	if !pm.browser_up(&api.core.browser) do return fail(api, .Not_Found, "at the top")
	return .Ok
}

// Back to the folder before. Not_Found with none.
browser_back :: proc(api: ^Api) -> Result {
	if !pm.browser_back(&api.core.browser) do return fail(api, .Not_Found, "nothing to go back to")
	return .Ok
}

// Forward again. Not_Found with none.
browser_forward :: proc(api: ^Api) -> Result {
	if !pm.browser_forward(&api.core.browser) do return fail(api, .Not_Found, "nothing to go forward to")
	return .Ok
}

// Reads the folders again.
browser_refresh :: proc(api: ^Api) -> Result {
	pm.browser_refresh(&api.core.browser)
	return .Ok
}

// Row `index` of the tree as shown.
browser_row :: proc(api: ^Api, index: i64) -> (Browser_Row, Result) {
	rows := pm.browser_rows(&api.core.browser)
	if index < 0 || index >= i64(len(rows)) do return {}, fail(api, .Not_Found, "no such row")
	return {is_dir = rows[index].is_dir, depth = i64(rows[index].depth)}, .Ok
}

// Row `index`'s name. Temporary.
browser_row_name :: proc(api: ^Api, index: i64) -> (string, Result) {
	rows := pm.browser_rows(&api.core.browser)
	if index < 0 || index >= i64(len(rows)) do return "", fail(api, .Not_Found, "no such row")
	return rows[index].name, .Ok
}

// Row `index`'s path. Temporary.
browser_row_path :: proc(api: ^Api, index: i64) -> (string, Result) {
	rows := pm.browser_rows(&api.core.browser)
	if index < 0 || index >= i64(len(rows)) do return "", fail(api, .Not_Found, "no such row")
	return rows[index].path, .Ok
}

// Opens (or closes) folder `dir` in the tree.
browser_expand :: proc(api: ^Api, dir: string, open: bool) -> Result {
	if !is_dir(dir) do return fail(api, .Not_Found, "no such folder")
	pm.browser_expand(&api.core.browser, dir, open)
	return .Ok
}

// Opens folder `dir` in the tree if closed, closes it if open.
browser_toggle :: proc(api: ^Api, dir: string) -> Result {
	if !is_dir(dir) do return fail(api, .Not_Found, "no such folder")
	pm.browser_toggle(&api.core.browser, dir)
	return .Ok
}

// Selects the file or folder at `path` (with auto preview on, a file plays).
browser_select :: proc(api: ^Api, path: string) -> Result {
	pm.browser_select(&api.core.browser, path)
	return .Ok
}

// Shows favourite `index`'s folder (a fresh history).
browser_set_tab :: proc(api: ^Api, index: i64) -> Result {
	if index < 0 || index >= i64(len(api.core.browser.favorites)) do return fail(api, .Not_Found, "no such favourite")
	pm.browser_set_tab(&api.core.browser, int(index))
	return .Ok
}

// Favourite `index`'s name. Temporary.
browser_favorite_name :: proc(api: ^Api, index: i64) -> (string, Result) {
	f := api.core.browser.favorites
	if index < 0 || index >= i64(len(f)) do return "", fail(api, .Not_Found, "no such favourite")
	return f[index].name, .Ok
}

// Favourite `index`'s folder. Temporary.
browser_favorite_folder :: proc(api: ^Api, index: i64) -> (string, Result) {
	if index < 0 || index >= i64(len(api.core.browser.favorites)) do return "", fail(api, .Not_Found, "no such favourite")
	return pm.favorite_dir(&api.core.browser, int(index)), .Ok
}

// Adds folder `dir` to the favourites as `name` ("": the folder's): its
// index. Saved with the preferences.
browser_add_favorite :: proc(api: ^Api, dir: string, name: string) -> (i64, Result) {
	if !is_dir(dir) do return -1, fail(api, .Not_Found, "no such folder")
	i := pm.favorite_add(&api.core.browser, dir, name)
	favorites_save(api)
	return i64(i), .Ok
}

// Removes favourite `index` (not the project's).
browser_remove_favorite :: proc(api: ^Api, index: i64) -> Result {
	f := api.core.browser.favorites
	if index < 0 || index >= i64(len(f)) do return fail(api, .Not_Found, "no such favourite")
	if f[index].project do return fail(api, .Unsupported, "the project's folder stays")
	pm.favorite_remove(&api.core.browser, int(index))
	favorites_save(api)
	return .Ok
}

// Renames favourite `index`.
browser_rename_favorite :: proc(api: ^Api, index: i64, name: string) -> Result {
	if index < 0 || index >= i64(len(api.core.browser.favorites)) do return fail(api, .Not_Found, "no such favourite")
	if strings.trim_space(name) == "" do return fail(api, .Invalid_Argument, "a name")
	pm.favorite_rename(&api.core.browser, int(index), name)
	favorites_save(api)
	return .Ok
}

// Moves favourite `from` to `to` (their order as shown).
browser_move_favorite :: proc(api: ^Api, from, to: i64) -> Result {
	n := i64(len(api.core.browser.favorites))
	if from < 0 || from >= n || to < 0 || to >= n do return fail(api, .Not_Found, "no such favourite")
	pm.favorite_move(&api.core.browser, int(from), int(to))
	favorites_save(api)
	return .Ok
}

// Searches every folder under the one shown for names with `query` in
// them (on its own thread: results come as it goes; "" stops).
browser_search :: proc(api: ^Api, query: string) -> Result {
	pm.browser_search(&api.core.browser, query)
	return .Ok
}

// Search result `index`.
browser_result :: proc(api: ^Api, index: i64) -> (Browser_Row, Result) {
	rs := pm.search_results(&api.core.browser.search)
	if index < 0 || index >= i64(len(rs)) do return {}, fail(api, .Not_Found, "no such result")
	return {is_dir = rs[index].is_dir}, .Ok
}

// Search result `index`'s path. Temporary.
browser_result_path :: proc(api: ^Api, index: i64) -> (string, Result) {
	rs := pm.search_results(&api.core.browser.search)
	if index < 0 || index >= i64(len(rs)) do return "", fail(api, .Not_Found, "no such result")
	return rs[index].path, .Ok
}

// Previews the audio file at `path` (as the browser does: with sync, at the
// tempo). Not a change to the project.
browser_preview :: proc(api: ^Api, path: string) -> Result {
	if path == "" do return fail(api, .Invalid_Argument, "no file")
	pm.preview_play(&api.core.m.engine, path)
	return .Ok
}

// Stops the preview.
browser_preview_stop :: proc(api: ^Api) -> Result {
	pm.preview_stop(&api.core.m.engine)
	return .Ok
}

// How the preview plays.
browser_preview_settings :: proc(api: ^Api) -> (Preview_Settings, Result) {
	pv := &api.core.m.engine.preview
	return {auto_play = pv.auto_play, sync = pv.sync, volume_db = pv.volume}, .Ok
}

// Sets how the preview plays.
browser_set_preview_settings :: proc(api: ^Api, s: Preview_Settings) -> Result {
	if !(s.volume_db >= -60 && s.volume_db <= 6) do return fail(api, .Invalid_Argument, "the volume is -60..6 dB")
	pv := &api.core.m.engine.preview
	pv.auto_play, pv.sync, pv.volume = s.auto_play, s.sync, s.volume_db
	return .Ok
}

@(private)
favorites_save :: proc(api: ^Api) {
	if api.core.files.folders.prefs == "" do return
	p, _ := filepath.join({api.core.files.folders.prefs, "favorites.txt"}, context.temp_allocator)
	pm.favorites_save(&api.core.browser, p)
}

@(private)
is_dir :: proc(path: string) -> bool {
	return os.is_dir(path)
}
