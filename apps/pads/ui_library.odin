// The Library's model, the window's and a controller's alike: its
// categories (the favourites, the files and drives, the projects, recent
// ones and templates, the instruments, synth presets, effects and
// plug-ins), each one's items, and what each item can do (onto the
// selected pad, or with Shift the next empty one: as a sampler, a slicer,
// slices onto pads, a synth's sample oscillator; a folder as the bank's
// kit; a device loaded; a project opened...).
package pads

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"

import "app:ui"
import pa "api"
import pm "model"
import im "deps:imgui"

// What a category lists.
Lib_Kind :: enum {
	Manage, // this project: save, save as, rename, new, a template, clean up, export
	Favorite,
	Files,
	Drives,
	Projects,
	Recent,
	Templates,
	Instruments,
	Presets,
	Effects,
	Plugins,
}

// A category: its kind (a favourite: which), name and icon.
Lib_Cat :: struct {
	kind: Lib_Kind,
	fav:  int,
	name: string,
	icon: string,
}

// What an item is.
Item_Kind :: enum {
	Folder,
	Audio,
	Midi,
	Instrument, // an instrument or a synth preset (its device code)
	Effect,     // an effect or an effect plug-in (its device code)
	Project,
	Template,
	Command, // this project's (its code: "save", "save_as"...)
	Other,
}

// An item in the list: a file or folder (its path), a device (its code),
// a project or a template.
Lib_Item :: struct {
	name:  string,
	path:  string,
	kind:  Item_Kind,
	depth: int,
	code:  string,
	info:  string,
	fold:  int, // an effect with presets: 1 its presets folded, 2 shown (0: none)
	fx:    pm.Effect_Kind, // which effect (an effect's row or one of its presets)
}

// What an item's button does.
Lib_Act :: enum {
	None,
	Open,       // a folder: into it
	Favorite,   // a folder: a favourite (a tab)
	Kit,        // a folder: its samples onto the bank's empty pads
	Sampler,    // a sample onto the pad as a sampler
	Slicer,     // ... into a slicer (sliced at its hits)
	Slices,     // ... sliced, each slice onto an empty pad
	Synth_Osc,  // ... into a synth's sample oscillator
	Next_Empty, // the item's first action, onto the next empty pad
	Notes,      // a MIDI file: its notes onto the pad
	Load,       // an instrument or preset onto the pad
	Insert,     // an effect into the pad's first empty insert
	Open_Project,
	From_Template,
	Run, // a command (its name the button's)
	Presets, // an effect's presets: shown under it, or folded away
}

LIB_ACT_NAMES := [Lib_Act]string{
	.None = "", .Open = "Open", .Favorite = ui.ICON_STAR + " Favourite", .Kit = "Kit " + ui.ICON_ARROW_RIGHT + " Bank",
	.Sampler = "Sampler", .Slicer = "Slicer", .Slices = "Slices " + ui.ICON_ARROW_RIGHT + " Pads", .Synth_Osc = "Synth Osc",
	.Next_Empty = "Next Empty", .Notes = "Notes", .Load = "Load", .Insert = "Insert",
	.Open_Project = "Open", .From_Template = "New", .Run = "", .Presets = "Presets",
}

// An action's button label (a command's: its own name).
lib_act_label :: proc(act: Lib_Act, it: Lib_Item) -> string {
	return it.name if act == .Run else LIB_ACT_NAMES[act]
}

// The Library's own state: the category shown, each list category's
// selected item, the last load action (Shift + a grid pad repeats it).
Lib_State :: struct {
	cat:  int,
	sel:  [Lib_Kind]int,
	last: Lib_Act,
	fx_slot: [2]int, // browsing from an effect slot (`fx_replace`): its pad and slot, an effect loaded replaces it
	fx_replace: bool,
	open:       bit_set[pm.Effect_Kind], // the effects whose presets show (folded, the rest)
	shift:      bool, // a controller's Shift held (in its browser): loads go onto the next empty pad
	save_as_open: bool, // the Save As by name dialog
	save_as_name: [64]u8,
}

// The categories: each favourite (the project's first), Files (home),
// Drives, Projects, Recent, Templates, then the devices.
lib_categories :: proc(a: ^App) -> []Lib_Cat {
	out := make([dynamic]Lib_Cat, context.temp_allocator)
	for f, k in a.browser.favorites do append(&out, Lib_Cat{.Favorite, k, f.name, ui.ICON_FOLDER if !f.project else ui.ICON_LIBRARY})
	append(&out, Lib_Cat{.Files, 0, "Files", ui.ICON_FOLDER_OPEN})
	if drives_root() != "" do append(&out, Lib_Cat{.Drives, 0, "Drives", ui.ICON_FOLDER})
	append(&out, Lib_Cat{.Manage, 0, "This Project", ui.ICON_SAVE})
	append(&out, Lib_Cat{.Projects, 0, "Projects", ui.ICON_FILE_PLUS})
	append(&out, Lib_Cat{.Recent, 0, "Recent", ui.ICON_FILE_PLUS})
	append(&out, Lib_Cat{.Templates, 0, "Templates", ui.ICON_FILE_PLUS})
	append(&out, Lib_Cat{.Instruments, 0, "Instruments", ui.ICON_BLOCKS})
	append(&out, Lib_Cat{.Presets, 0, "Synth Presets", ui.ICON_AUDIO_WAVEFORM})
	append(&out, Lib_Cat{.Effects, 0, "Effects", ui.ICON_WAND_SPARKLES})
	append(&out, Lib_Cat{.Plugins, 0, "Plug-ins", ui.ICON_PLUG})
	return out[:]
}

// The category shown.
lib_cat :: proc(a: ^App) -> Lib_Cat {
	cats := lib_categories(a)
	a.lib.cat = clamp(a.lib.cat, 0, len(cats) - 1)
	// (a favourite shown: the browser's tab, however it was chosen)
	if cats[a.lib.cat].kind == .Favorite && a.browser.tab < len(a.browser.favorites) do a.lib.cat = a.browser.tab
	return cats[a.lib.cat]
}

// Whether a category is a folder tree (the browser's).
lib_folders :: proc(c: Lib_Cat) -> bool { return c.kind == .Favorite || c.kind == .Files || c.kind == .Drives }

// Where attached drives are ("": none here).
drives_root :: proc() -> string {
	when ODIN_OS == .Darwin do return "/Volumes"
	else when ODIN_OS == .Linux do return "/media" if os.is_dir("/media") else ""
	else do return ""
}

// Shows category `k`: a folder one's folder in the browser.
lib_show :: proc(a: ^App, k: int) {
	cats := lib_categories(a)
	a.lib.cat = clamp(k, 0, len(cats) - 1)
	c := cats[a.lib.cat]
	#partial switch c.kind {
	case .Favorite: pa.browser_set_tab(&a.api, i64(c.fav))
	case .Files:
		home := os.get_env("HOME", context.temp_allocator)
		if home == "" do home = os.get_env("USERPROFILE", context.temp_allocator)
		if home != "" do pa.browser_go(&a.api, home)
	case .Drives: pa.browser_go(&a.api, drives_root())
	}
}

// The category's items (a folder one: the browser's rows, or its search's;
// a device one searched: the matching devices of every device category).
lib_items :: proc(a: ^App) -> []Lib_Item {
	c := lib_cat(a)
	find := strings.to_lower(string(cstring(&a.bview.device_query[0])), context.temp_allocator)
	if find != "" && !lib_folders(c) {
		kinds := []Lib_Kind{.Instruments, .Presets, .Effects, .Plugins} if c.kind >= .Instruments else []Lib_Kind{c.kind}
		out := make([dynamic]Lib_Item, context.temp_allocator)
		for k in kinds do for it in lib_items_of(a, {kind = k}) do if strings.contains(strings.to_lower(it.name, context.temp_allocator), find) do append(&out, it)
		return out[:]
	}
	return lib_items_of(a, c)
}

// Category `c`'s items.
@(private)
lib_items_of :: proc(a: ^App, c: Lib_Cat) -> []Lib_Item {
	out := make([dynamic]Lib_Item, context.temp_allocator)
	b := &a.browser
	file_kind :: proc(path: string, dir: bool) -> Item_Kind {
		if dir do return .Folder
		if pm.is_midi(path) do return .Midi
		if pm.is_audio(path) do return .Audio
		return .Other
	}
	switch c.kind {
	case .Manage:
		ps, _ := pa.project_state(&a.api)
		cmd :: proc(out: ^[dynamic]Lib_Item, name, code, info: string) { append(out, Lib_Item{name = name, kind = .Command, code = code, info = info}) }
		cmd(&out, "Save", "save", "Save it (a new one: into the projects folder as Project N)")
		cmd(&out, "Save As…", "save_as", "Save it under a name, in the projects folder")
		if !ps.untitled do cmd(&out, "Rename…", "rename", "Rename its folder")
		cmd(&out, "New Project", "new", "An empty project (the changes asked about first)")
		cmd(&out, "Save as Template…", "template", "New projects can start from it")
		cmd(&out, "Clean Up…", "cleanup", "The files it doesn't use, to the Trash")
		cmd(&out, "Export Audio", "export", "The sequence (or song) as a WAV in its folder's Exports")
	case .Favorite, .Files, .Drives:
		rows := pm.search_results(&b.search) if b.search.query != "" else pm.browser_rows(b)
		for r in rows do append(&out, Lib_Item{name = r.name, path = r.path, kind = file_kind(r.path, r.is_dir), depth = r.depth})
	case .Projects:
		where_ := a.settings.projects_folder if a.settings.projects_folder != "" else a.files.folders.projects
		if fs, err := os.read_all_directory_by_path(where_, context.temp_allocator); err == nil {
			slice.sort_by(fs, proc(x, y: os.File_Info) -> bool { return x.modification_time._nsec > y.modification_time._nsec })
			for f in fs do if f.type == .Directory && strings.has_suffix(f.name, ".pads") {
				append(&out, Lib_Item{name = strings.trim_suffix(f.name, ".pads"), path = f.fullpath, kind = .Project})
			}
		}
	case .Recent:
		ps, _ := pa.project_state(&a.api)
		for k in 0 ..< ps.recent {
			r, _ := pa.project_recent(&a.api, k)
			append(&out, Lib_Item{name = strings.trim_suffix(filepath.base(r), ".pads"), path = r, kind = .Project, info = r})
		}
	case .Templates:
		ps, _ := pa.project_state(&a.api)
		for k in 0 ..< ps.templates {
			n, _ := pa.project_template_name(&a.api, k)
			append(&out, Lib_Item{name = n, kind = .Template})
		}
	case .Instruments:
		append(&out, Lib_Item{name = "Sampler", kind = .Instrument, code = "inst sampler", info = "Plays the pad's sample"})
		append(&out, Lib_Item{name = "Slicer", kind = .Instrument, code = "inst slicer", info = "The pad's sample in slices, one a key"})
		append(&out, Lib_Item{name = "Audio Track", kind = .Instrument, code = "inst audio", info = "Records and plays audio"})
		append(&out, Lib_Item{name = "Synth", kind = .Instrument, code = "inst synth", info = "A wavetable synth (a plain patch)"})
		for e, k in plugin_instruments(a) do append(&out, Lib_Item{name = e.name, kind = .Instrument, code = fmt.tprintf("clapi %d", k), info = fmt.tprintf("%s %s (CLAP instrument)", e.vendor, e.version)})
	case .Presets:
		for p, k in pm.BUILTIN_PRESETS do append(&out, Lib_Item{name = p.name, kind = .Instrument, code = fmt.tprintf("preset %d", k), info = p.category})
		for n in pm.preset_list(preset_folder(a)) do append(&out, Lib_Item{name = n, kind = .Instrument, code = fmt.tprintf("mine %s", n), info = "Yours"})
	case .Effects:
		for k in pm.Effect_Kind {
			if k == .None || k == .Plugin || pm.effect_kind_legacy(k) do continue
			n := effect_preset_total(k)
			fold := 0 if n == 0 else (2 if k in a.lib.open else 1)
			info := "An insert effect" if n == 0 else fmt.tprintf("An insert effect, %d presets", n)
			append(&out, Lib_Item{name = string(pm.EFFECT_NAMES[k]), kind = .Effect, code = fmt.tprintf("fx %d", int(k)), info = info, fold = fold, fx = k})
			if fold != 2 do continue
			// Its presets, under it: the factory's, then (ProVerb) an installed ValhallaRoom's.
			for p, i in pm.EFFECT_PRESETS do if p.kind == k {
				append(&out, Lib_Item{name = p.name, kind = .Effect, code = fmt.tprintf("fxp %d", i), info = p.info, depth = 1, fx = k})
			}
			if k == .Proverb do for p, i in pm.imported_presets() {
				name := p.name if p.folder == "" else fmt.tprintf("%s / %s", p.folder, p.name)
				append(&out, Lib_Item{name = name, kind = .Effect, code = fmt.tprintf("fxi %d", i), info = "From your ValhallaRoom, as ProVerb's", depth = 1, fx = k})
			}
		}
	case .Plugins:
		for e, k in plugin_effects(a) do append(&out, Lib_Item{name = e.name, kind = .Effect, code = fmt.tprintf("clap %d", k), info = fmt.tprintf("%s %s (CLAP effect)", e.vendor, e.version)})
	}
	return out[:]
}

// The selected item's index in `items` (-1: none).
lib_selected :: proc(a: ^App, items: []Lib_Item) -> int {
	c := lib_cat(a)
	if lib_folders(c) {
		for it, k in items do if it.path == a.browser.selected do return k
		return -1
	}
	if len(items) == 0 do return -1
	a.lib.sel[c.kind] = clamp(a.lib.sel[c.kind], 0, len(items) - 1)
	return a.lib.sel[c.kind]
}

// Selects item `k` (a sample: heard, with auto-play).
lib_select :: proc(a: ^App, items: []Lib_Item, k: int) {
	if k < 0 || k >= len(items) do return
	c := lib_cat(a)
	if !lib_folders(c) {
		a.lib.sel[c.kind] = k
		return
	}
	it := items[k]
	pa.browser_select(&a.api, strings.clone(it.path, context.temp_allocator))
	preview_selected(a, {name = it.name, path = it.path, is_dir = it.kind == .Folder}, true)
}

// An item's buttons: four above the list, four below.
lib_actions :: proc(it: Lib_Item) -> (upper, lower: [4]Lib_Act) {
	switch it.kind {
	case .Folder:     upper = {.Open, .Kit, .Favorite, .None}
	case .Audio:      upper, lower = {.Sampler, .Slicer, .Slices, .Synth_Osc}, {.Next_Empty, .None, .None, .None}
	case .Midi:       upper, lower = {.Notes, .None, .None, .None}, {.Next_Empty, .None, .None, .None}
	case .Instrument: upper, lower = {.Load, .None, .None, .None}, {.Next_Empty, .None, .None, .None}
	case .Effect:     upper = {.Insert, .Presets if it.fold > 0 else .None, .None, .None}
	case .Project:    upper = {.Open_Project, .None, .None, .None}
	case .Template:   upper = {.From_Template, .None, .None, .None}
	case .Command:    upper = {.Run, .None, .None, .None}
	case .Other:
	}
	return
}

// How many presets effect `k` has: its factory ones (and, for ProVerb, an
// installed ValhallaRoom's).
effect_preset_total :: proc(k: pm.Effect_Kind) -> int {
	n := 0
	for p in pm.EFFECT_PRESETS do if p.kind == k do n += 1
	if k == .Proverb do n += len(pm.imported_presets())
	return n
}

// What an item's first button does (a double-click, Enter, Shift + a pad).
lib_primary :: proc(it: Lib_Item) -> Lib_Act {
	up, _ := lib_actions(it)
	return up[0]
}

// Whether action `act` can be done on item `it` now.
lib_can :: proc(a: ^App, act: Lib_Act, it: Lib_Item) -> bool {
	#partial switch act {
	case .None:       return false
	case .Favorite:   return !pm.is_favorite(&a.browser, it.path)
	case .Next_Empty: return next_empty_target(a) >= 0
	case .Kit:        return len(folder_samples(a, it.path)) > 0
	}
	return true
}

// Does action `act` on item `it`, onto pad `pad` (-1: the selected pad;
// Shift: the next empty one). Whether it did.
lib_run :: proc(a: ^App, act: Lib_Act, it: Lib_Item, pad := -1, shift := false) -> bool {
	m := &a.m
	to := pad if pad >= 0 else (next_empty_target(a) if shift else a.selected)
	if act == .Next_Empty {
		return lib_run(a, lib_primary(it), it, next_empty_target(a))
	}
	if act == .Presets {
		if it.fx in a.lib.open do a.lib.open -= {it.fx}
		else do a.lib.open += {it.fx}
		return true
	}
	if act == .Insert && a.lib.fx_replace && (strings.has_prefix(it.code, "fx ") || strings.has_prefix(it.code, "fxp ") || strings.has_prefix(it.code, "fxi ")) { // (browsed from an effect slot: it replaced)
		preset := strings.has_prefix(it.code, "fxp ") || strings.has_prefix(it.code, "fxi ")
		n, _ := strconv.parse_int(it.code[4:] if preset else it.code[3:])
		s := pa.Slot_Ref{place = .Insert, index = i64(a.lib.fx_slot[0]), slot = i64(a.lib.fx_slot[1])}
		if strings.has_prefix(it.code, "fxi ") {
			if pa.effect_load_imported_preset(&a.api, s, i64(n)) != .Ok do return false
		} else if preset {
			if pa.effect_load_preset(&a.api, s, i64(n)) != .Ok do return false
		} else if pa.effect_set(&a.api, s, i64(n)) != .Ok do return false
		ui.toast(&a.ws.toasts, .Success, fmt.tprintf("%s onto %s, slot %d", it.name, pm.pad_label(a.lib.fx_slot[0]), a.lib.fx_slot[1] + 1))
		a.lib.last = act
		return true
	}
	if act == .Run do return lib_command(a, it.code)
	if to < 0 && act != .Open && act != .Favorite && act != .Kit && act != .Open_Project && act != .From_Template {
		ui.toast(&a.ws.toasts, .Warning, "No empty pad")
		return false
	}
	base := filepath.base(it.path)
	#partial switch act {
	case .Open:
		pa.browser_go(&a.api, strings.clone(it.path, context.temp_allocator))
	case .Favorite:
		pa.browser_add_favorite(&a.api, it.path, "")
		ui.toast(&a.ws.toasts, .Success, fmt.tprintf("%s is a favourite", it.name))
	case .Kit:
		files := folder_samples(a, it.path)
		bank := a.bank * pm.PADS_PER_BANK
		n := 0
		pa.history_group_begin(&a.api, "Load Kit")
		for k in 0 ..< pm.PADS_PER_BANK {
			if n >= len(files) do break
			i := bank + k
			if pm.pad_used(&m.project, i) do continue
			if pa.pad_load_sample(&a.api, i64(i), files[n]) == .Ok do n += 1
		}
		pa.history_group_end(&a.api)
		ui.toast(&a.ws.toasts, .Success if n > 0 else .Warning, fmt.tprintf("%d samples onto bank %c", n, 'A' + rune(a.bank)) if n > 0 else "No empty pad in the bank")
	case .Sampler:
		if m.project.pads[to].kind != .Sampler && pm.pad_used(&m.project, to) do pa.pad_set_kind(&a.api, i64(to), .Sampler)
		if pa.pad_load_sample(&a.api, i64(to), it.path) != .Ok {
			ui.toast(&a.ws.toasts, .Error, fmt.tprintf("Could not load %s", base))
			return false
		}
		ui.toast(&a.ws.toasts, .Success, fmt.tprintf("%s onto %s (Sampler)", base, pm.pad_label(to)))
	case .Slicer:
		return load_into_slicer(a, to, it.path)
	case .Slices:
		if !load_into_slicer(a, to, it.path) do return false
		n := m.project.pads[to].slicer.count
		got := 0
		for k in 0 ..< n do if pm.slice_to_pad(m, to, k) >= 0 do got += 1
		ui.toast(&a.ws.toasts, .Success, fmt.tprintf("%d slices of %s onto pads", got, base))
	case .Synth_Osc:
		pa.history_group_begin(&a.api, "Sample Oscillator")
		if m.project.pads[to].kind != .Synth do pa.pad_set_kind(&a.api, i64(to), .Synth)
		id, err := pm.import_sample(m, it.path)
		if err == .None do pm.set_synth_sample(m, to, {sample = id})
		pa.history_group_end(&a.api)
		if err != .None {
			ui.toast(&a.ws.toasts, .Error, fmt.tprintf("Could not load %s", base))
			return false
		}
		ui.toast(&a.ws.toasts, .Success, fmt.tprintf("%s onto %s (Synth sample oscillator)", base, pm.pad_label(to)))
	case .Notes:
		if !drop_midi(a, it.path, to) do return false
	case .Load, .Insert:
		if !put_device(a, to, it.code) do return false
		ui.toast(&a.ws.toasts, .Success, fmt.tprintf("%s onto %s", it.name, pm.pad_label(to)))
	case .Open_Project:
		leave(a, .Open, it.path)
	case .From_Template:
		leave(a, .New_From, it.name)
	}
	if act != .Open && act != .Favorite do a.lib.last = act
	return true
}

// The audio files in folder `dir` (by name), for a kit.
folder_samples :: proc(a: ^App, dir: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	for e in pm.browser_list(&a.browser, dir) do if !e.is_dir && pm.is_audio(e.path) do append(&out, e.path)
	return out[:]
}

// Shift + a pad (a controller's): the selected item onto pad `pad` with
// the last load action (or its first).
lib_load_onto :: proc(a: ^App, pad: int) -> bool {
	items := lib_items(a)
	k := lib_selected(a, items)
	if k < 0 do return false
	it := items[k]
	act := a.lib.last
	up, low := lib_actions(it)
	fits := false
	for x in up do fits ||= x == act
	for x in low do fits ||= x == act
	if !fits || act == .None || act == .Open || act == .Favorite || act == .Kit do act = lib_primary(it)
	if act == .None || act == .Open || act == .Open_Project || act == .From_Template do return false
	return lib_run(a, act, it, pad)
}

// This project's command `code` ("save", "save_as", "rename", "new",
// "template", "cleanup", "export"). Whether it was done (or its dialog
// opened).
lib_command :: proc(a: ^App, code: string) -> bool {
	switch code {
	case "save":
		dir, r := pa.project_save_quick(&a.api)
		if r != .Ok {
			ui.toast(&a.ws.toasts, .Error, "Could not save the project")
			return false
		}
		ui.toast(&a.ws.toasts, .Success, fmt.tprintf("Saved %s", strings.trim_suffix(filepath.base(dir), ".pads")))
	case "save_as":
		a.lib.save_as_open = true
		a.lib.save_as_name = {}
		copy(a.lib.save_as_name[:len(a.lib.save_as_name) - 1], project_name(a))
	case "rename":   a.proj.rename_open = true
	case "new":      leave(a, .New)
	case "template":
		a.template = {open = true}
		copy(a.template.name[:63], project_name(a))
	case "cleanup":  cleanup_open(a)
	case "export":
		p := &a.m.project
		name := pm.arrangement_name(p, p.arrangement) if a.proj.settings.source == .Song else pm.sequence_name(p, p.slot)
		dir, _ := filepath.join({p.dir, "Exports"}, context.temp_allocator)
		os.make_directory_all(dir)
		path, _ := filepath.join({dir, fmt.tprintf("%s.wav", name)}, context.temp_allocator)
		st := a.proj.settings
		if pa.export_start(&a.api, {source = pa.Export_Source(st.source), stems = .Mixdown, format = pa.Export_Format(st.encoding), rate = st.rate, tail = st.tail}, path) != .Ok {
			ui.toast(&a.ws.toasts, .Error, "Nothing to export")
			return false
		}
	case: return false
	}
	return true
}

// The Save As by name dialog (a controller's name editor types into it):
// the project into the projects folder as "<name>.pads".
draw_lib_save_as :: proc(a: ^App) {
	if a.lib.save_as_open {
		im.OpenPopup("Save Project As")
		a.lib.save_as_open = false
	}
	if modal_begin(a, "Save Project As", nil, {.AlwaysAutoResize}) {
		modal_text(a, "Its name (it goes in the projects folder):")
		im.SetNextItemWidth(280)
		enter := modal_input(a, "##saveasname", a.lib.save_as_name[:], {.EnterReturnsTrue})
		name := strings.trim_space(string(cstring(&a.lib.save_as_name[0])))
		if (modal_button(a, "Save") || enter) && name != "" {
			where_ := a.settings.projects_folder if a.settings.projects_folder != "" else a.files.folders.projects
			os.make_directory_all(where_)
			path, _ := filepath.join({where_, name}, context.temp_allocator)
			if pa.project_save_as(&a.api, path) == .Ok do ui.toast(&a.ws.toasts, .Success, fmt.tprintf("Saved %s", name))
			else {
				why, _ := pa.last_error(&a.api)
				ui.toast(&a.ws.toasts, .Error, fmt.tprintf("Could not save: %s", why))
			}
			im.CloseCurrentPopup()
		}
		im.SameLine()
		if modal_button(a, "Cancel") || im.IsKeyPressed(.Escape) do im.CloseCurrentPopup()
		im.EndPopup()
	}
}

// Browse from the selected device: the category it loads from, and the
// load it takes (a sampler's samples as a sampler, a slicer's as a
// slicer, a synth's presets, an effect slot's effects replacing it, an
// empty pad's instruments).
lib_browse_for_device :: proc(a: ^App) {
	st := &a.detail
	a.lib.fx_replace = false
	show_kind :: proc(a: ^App, k: Lib_Kind) {
		for c, i in lib_categories(a) do if c.kind == k {
			lib_show(a, i)
			return
		}
	}
	samples :: proc(a: ^App) {
		if lib_cat(a).kind != .Favorite do lib_show(a, a.browser.tab)
	}
	if st.track.kind == .Pad {
		i := st.track.index
		pad := a.m.project.pads[i]
		#partial switch st.device.kind {
		case .Slot:
			show_kind(a, .Effects)
			a.lib.last = .Insert
			a.lib.fx_slot, a.lib.fx_replace = {i, st.device.slot}, true
			// The slot's own effect, its presets unfolded and its row selected.
			if k := pad.inserts[st.device.slot].kind; k != .None && effect_preset_total(k) > 0 {
				a.lib.open += {k}
				for it, n in lib_items(a) do if it.fold > 0 && it.fx == k {
					a.lib.sel[.Effects] = n
					break
				}
			}
		case:
			switch {
			case !pm.pad_used(&a.m.project, i): show_kind(a, .Instruments); a.lib.last = .Load
			case pad.kind == .Synth:  show_kind(a, .Presets); a.lib.last = .Load
			case pad.kind == .Slicer: samples(a); a.lib.last = .Slicer
			case:                     samples(a); a.lib.last = .Sampler
			}
		}
	}
	a.ws.left_shown = true
}
