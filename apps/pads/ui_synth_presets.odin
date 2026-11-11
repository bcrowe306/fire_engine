package pads

import "core:fmt"
import "core:path/filepath"
import "core:strings"

import "app:ui"
import pm "model"
import im "deps:imgui"

// The synth's presets, on the line of the device tabs: the one playing
// (a menu of the built-in bank by kind and of yours), the ones before
// and after it, and Save (yours go in the settings folder's
// Presets/Synth).

// The save dialog's state.
Preset_Ui :: struct {
	saving: bool,
	name:   [64]u8,
}

// A preset to choose: built in (`builtin` ≥ 0) or yours (by name).
@(private = "file")
Preset_Entry :: struct {
	builtin: int,
	name:    string,
}

// Where your synth presets are kept.
preset_folder :: proc(a: ^App) -> string {
	p, _ := filepath.join({settings_folder(a), "Presets", "Synth"}, context.temp_allocator)
	return p
}

@(private = "file")
preset_entries :: proc(a: ^App) -> []Preset_Entry {
	out := make([dynamic]Preset_Entry, context.temp_allocator)
	for p, k in pm.BUILTIN_PRESETS do append(&out, Preset_Entry{k, p.name})
	for n in pm.preset_list(preset_folder(a)) do append(&out, Preset_Entry{-1, n})
	return out[:]
}

@(private = "file")
load_entry :: proc(a: ^App, e: Preset_Entry) {
	m := &a.m
	if e.builtin >= 0 {
		pm.preset_apply_builtin(m, a.selected, e.builtin)
		return
	}
	path, _ := filepath.join({preset_folder(a), strings.concatenate({e.name, pm.PRESET_EXT}, context.temp_allocator)}, context.temp_allocator)
	pr, err := pm.preset_read(path)
	if err != .None {
		ui.toast(&a.ws.toasts, .Error, fmt.tprintf("Couldn't read the preset %s", e.name))
		return
	}
	pm.preset_apply(m, a.selected, &pr)
}

// The preset bar, right-aligned at `right` on the line at `y`.
draw_preset_bar :: proc(a: ^App, right, y: f32) {
	m := &a.m
	i := a.selected
	entries := preset_entries(a)
	name := pm.synth_preset_name(m, i)
	at := -1
	for e, k in entries do if e.name == name do at = k
	h := im.GetFrameHeight()
	w := h * 3 + 200 + 12
	back := im.GetCursorScreenPos()
	im.SetCursorScreenPos({right - w, y})
	if ui.icon_button(ui.ICON_CHEVRON_LEFT, "The preset before") && len(entries) > 0 do load_entry(a, entries[(at - 1 + len(entries)) % len(entries) if at >= 0 else len(entries) - 1])
	ui.name("preset before")
	im.SameLine(0, 2)
	im.SetNextItemWidth(200)
	shown := name if name != "" else "No preset"
	if ui.combo("##preset", fmt.ctprintf("%s  %s", ui.ICON_LIBRARY, shown), {.HeightLargest}) {
		// Yours first, then the bank by kind.
		im.TextDisabled("Yours")
		mine := 0
		for e in entries do if e.builtin < 0 {
			if im.Selectable(fmt.ctprintf("%s###pru%s", e.name, e.name), e.name == name) do load_entry(a, e)
			mine += 1
		}
		if mine == 0 do im.TextDisabled("  none yet (Save keeps one)")
		last := ""
		for e in entries do if e.builtin >= 0 {
			kind := pm.BUILTIN_PRESETS[e.builtin].category
			if kind != last {
				im.Separator()
				im.TextDisabled("%s", fmt.ctprintf("%s", kind))
				last = kind
			}
			if im.Selectable(fmt.ctprintf("%s###prb%d", e.name, e.builtin), e.name == name) do load_entry(a, e)
		}
		im.EndCombo()
	}
	ui.name("preset")
	im.SameLine(0, 2)
	if ui.icon_button(ui.ICON_CHEVRON_RIGHT, "The preset after") && len(entries) > 0 do load_entry(a, entries[(at + 1) % len(entries)])
	ui.name("preset after")
	im.SameLine(0, 6)
	if ui.icon_button(ui.ICON_SAVE, "Save this sound as a preset of yours") {
		a.presets.saving = true
		a.presets.name = {}
		copy(a.presets.name[:63], name if name != "" else pm.pad_name(&m.project.pads[i]))
	}
	ui.name("save preset")
	im.SetCursorScreenPos(back)
}

// The Save Preset dialog (when open).
draw_preset_save :: proc(a: ^App) {
	st := &a.presets
	if !st.saving do return
	im.OpenPopup("Save Preset")
	if im.BeginPopupModal("Save Preset", &st.saving, {.AlwaysAutoResize}) {
		im.TextDisabled("Its name")
		im.SetNextItemWidth(260)
		if im.IsWindowAppearing() do im.SetKeyboardFocusHere()
		enter := im.InputText("##presetname", cstring(&st.name[0]), len(st.name), {.EnterReturnsTrue})
		ui.name("preset name")
		name := strings.trim_space(strings.truncate_to_byte(string(st.name[:]), 0))
		if (im.Button("Save") || enter) && name != "" {
			if _, err := pm.preset_save(&a.m, a.selected, preset_folder(a), name); err == .None {
				ui.toast(&a.ws.toasts, .Success, fmt.tprintf("Saved the preset %s", name))
			} else {
				ui.toast(&a.ws.toasts, .Error, fmt.tprintf("Couldn't save the preset %s", name))
			}
			st.saving = false
			im.CloseCurrentPopup()
		}
		ui.name("save")
		im.SameLine()
		if im.Button("Cancel") {
			st.saving = false
			im.CloseCurrentPopup()
		}
		im.EndPopup()
	}
}
