package pads

import "core:fmt"
import "core:strings"

import app "app:core"
import "app:ui"
import pm "model"
import im "deps:imgui"

// File > Clean Up Project: the files the project doesn't use, chosen to
// go to the Trash (from where they can be put back). Files no sample of
// the project is are ticked; samples only undoing would bring back, and
// the cache, aren't (ticking the first forgets the undo history).
Cleanup_Ui :: struct {
	open:   bool,
	files:  [dynamic]pm.Unused_File, // (paths owned)
	ticked: [dynamic]bool,
}

// Opens the dialog with what the project doesn't use now.
cleanup_open :: proc(a: ^App) {
	st := &a.cleanup
	cleanup_forget(st)
	extra: []app.Id
	if cb := &a.seq.aud; cb.has_clip do extra = cb.clip.takes[:cb.clip.count] // (what Paste would put back)
	for f in pm.unused_files(&a.m, extra) {
		g := f
		g.path = strings.clone(f.path)
		append(&st.files, g)
		append(&st.ticked, f.kind == .Unused)
	}
	st.open = true
}

@(private)
cleanup_forget :: proc(st: ^Cleanup_Ui) {
	for f in st.files do delete(f.path)
	delete(st.files)
	delete(st.ticked)
	st^ = {}
}

// "1.2 MB".
@(private)
size_text :: proc(n: i64) -> string {
	switch {
	case n >= 1 << 30: return fmt.tprintf("%.1f GB", f64(n) / f64(1 << 30))
	case n >= 1 << 20: return fmt.tprintf("%.1f MB", f64(n) / f64(1 << 20))
	case n >= 1 << 10: return fmt.tprintf("%.0f KB", f64(n) / f64(1 << 10))
	}
	return fmt.tprintf("%d bytes", n)
}

// The dialog, while open.
draw_cleanup :: proc(a: ^App) {
	st := &a.cleanup
	if !st.open do return
	im.OpenPopup("Clean Up Project")
	if im.BeginPopupModal("Clean Up Project", &st.open, {.AlwaysAutoResize}) {
		dir := a.m.project.dir
		if len(st.files) == 0 {
			im.TextUnformatted("Every file in the project is in use.")
		} else {
			im.TextDisabled("Moved to the Trash, from where they can be put back. The project is saved after.")
			im.Spacing()
			total: i64
			forgets := false
			if im.BeginTable("##cleanup", 4, {.SizingFixedFit, .RowBg, .ScrollY}, {560, min(f32(len(st.files)) * (im.GetFrameHeightWithSpacing() + 4) + 8, 360)}) {
				for &f, k in st.files {
					im.TableNextRow()
					im.TableNextColumn()
					im.Checkbox(fmt.ctprintf("##c%d", k), &st.ticked[k])
					ui.name(fmt.tprintf("clean up %d", k + 1))
					im.TableNextColumn()
					rel := strings.trim_prefix(strings.trim_prefix(f.path, dir), "/")
					im.TextUnformatted(fmt.ctprintf("%s", rel))
					im.TableNextColumn()
					switch f.kind {
					case .Unused:    im.TextDisabled("not used")
					case .Undo_Only: im.TextDisabled("only undo uses it")
					case .Cache:     im.TextDisabled("made again when needed")
					}
					im.TableNextColumn()
					im.TextUnformatted(fmt.ctprintf("%s", size_text(f.size)))
					if st.ticked[k] {
						total += f.size
						if f.kind == .Undo_Only do forgets = true
					}
				}
				im.EndTable()
			}
			if forgets do im.TextColored(transmute(im.Vec4)ui.theme().warn, "%s", cstring("Undo is forgotten: what was ticked couldn't come back."))
			im.Spacing()
			im.BeginDisabled(total == 0)
			if im.Button(fmt.ctprintf("Move %s to the Trash", size_text(total))) {
				chosen := make([dynamic]pm.Unused_File, context.temp_allocator)
				for f, k in st.files do if st.ticked[k] do append(&chosen, f)
				n, bytes := pm.clean_up(&a.m, chosen[:], app.move_to_trash)
				if n < len(chosen) do ui.toast(&a.ws.toasts, .Warning, fmt.tprintf("%d of %d moved to the Trash (%s): the others couldn't be", n, len(chosen), size_text(bytes)))
				else do ui.toast(&a.ws.toasts, .Success, fmt.tprintf("Moved %d to the Trash (%s)", n, size_text(bytes)))
				st.open = false
			}
			ui.name("move to trash")
			im.EndDisabled()
			im.SameLine()
		}
		if im.Button("Close") do st.open = false
		ui.name("close clean up")
		if !st.open do im.CloseCurrentPopup()
		im.EndPopup()
	}
	if !st.open do cleanup_forget(st)
}
