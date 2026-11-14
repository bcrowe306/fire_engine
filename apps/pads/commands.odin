package pads

import "core:fmt"
import "core:strings"

import app "app:core"
import "app:ui"
import pa "api"
import pm "model"
import im "deps:imgui"

// Commands: everything you can do to something, in one list. Each says
// what it applies to (a pad, a note, a sequence, a song step, an effect
// slot...), and runs on a `Target`. Right-click menus are made from it,
// the palette lists what applies to the selection, drive scripts and
// (later) control surfaces run commands by id.

// What a command acts on.
Target_Kind :: enum u8 {
	Global,
	Pad,
	Note,      // `slot`'s note `index`
	Sequence,  // `slot`
	Song_Clip, // `index`
	Slot,      // `fx`: an insert, a bus slot or a performance effect
	Bus,       // `index` (BUSES: main)
	File,      // `path`
	Point,     // `slot`'s automation point `index`
	Part,      // the piano roll's marked part (of the current sequence)
	Take,      // pad `index`'s take in the current sequence
}

// Something to act on.
Target :: struct {
	kind:  Target_Kind,
	index: int,
	slot:  int,
	fx:    pm.Fx_Target,
	path:  string,
}

// One command.
Command :: struct {
	id:      string, // "pad.duplicate": stable, for scripts and surfaces
	label:   string,
	icon:    string,
	kinds:   bit_set[Target_Kind],
	group:   int,    // menus put a line between groups
	keys:    cstring, // its shortcut, as menus show it ("Cmd+D"), or nil
	run:     proc(a: ^App, t: Target),
	enabled: proc(a: ^App, t: Target) -> bool, // nil: always
	checked: proc(a: ^App, t: Target) -> bool, // nil: not a toggle
}

// Shorthands for targets.
pad_target :: proc(i: int) -> Target { return {kind = .Pad, index = i} }
seq_target :: proc(slot: int) -> Target { return {kind = .Sequence, slot = slot} }
note_target :: proc(slot, i: int) -> Target { return {kind = .Note, slot = slot, index = i} }

// The command `id`, or nil.
find_command :: proc(a: ^App, id: string) -> ^Command {
	for &c in a.commands do if c.id == id do return &c
	return nil
}

// Runs command `id` on `t`: false if there is none, it doesn't apply to
// `t`, or it isn't enabled.
run_command :: proc(a: ^App, id: string, t: Target) -> bool {
	c := find_command(a, id)
	if c == nil || t.kind not_in c.kinds || !target_valid(a, t) do return false
	if c.enabled != nil && !c.enabled(a, t) do return false
	c.run(a, t)
	return true
}

// The menu items of every command for `t` (inside an open popup), groups
// apart. `extra` draws more first (a pad's colours, say).
command_items :: proc(a: ^App, t: Target) {
	// What it was opened on is gone (a note deleted while its menu was
	// open): nothing to show.
	if !target_valid(a, t) {
		im.CloseCurrentPopup()
		return
	}
	last := -1
	for &c in a.commands {
		if t.kind not_in c.kinds do continue
		if last >= 0 && c.group != last do im.Separator()
		last = c.group
		on := c.checked != nil && c.checked(a, t)
		ok := c.enabled == nil || c.enabled(a, t)
		label := fmt.ctprintf("%s  %s###%s", c.icon if c.icon != "" else "  ", c.label, c.id)
		ran := im.MenuItem(label, c.keys, on, ok)
		ui.name(c.label) // for the probe and scripts: its words, not its icon
		if ran {
			c.run(a, t)
			return // (it may have removed what `t` names: the menu closes)
		}
	}
	if t.kind == .Sequence {
		im.Separator()
		if im.BeginMenu(ui.ICON_PALETTE + "  Colour") {
			seq_color_menu(a, t.slot)
			im.EndMenu()
		}
		ui.name("Colour")
	}
}

// A right-click menu on the last item, for `t`: its commands (`id` names
// the popup). True while it is open.
item_menu :: proc(a: ^App, t: Target, id: cstring = "##menu") -> bool {
	if !im.BeginPopupContextItem(id) do return false
	command_items(a, t)
	im.EndPopup()
	return true
}

// --- the commands ------------------------------------------------------------------------------

// Fills `a.commands`.
register_commands :: proc(a: ^App) {
	c := &a.commands
	add :: proc(c: ^[dynamic]Command, x: Command) { append(c, x) }
	pad_has :: proc(a: ^App, t: Target) -> bool { return pm.pad_used(&a.m.project, t.index) }

	// Pads.
	add(c, {id = "pad.play", label = "Play", icon = ui.ICON_PLAY, kinds = {.Pad}, group = 0,
		run = proc(a: ^App, t: Target) { pa.pad_play(&a.api, i64(t.index), true); a.release_at[t.index] = 12 }, enabled = pad_has})
	add(c, {id = "pad.select", label = "Select", icon = ui.ICON_MOUSE_POINTER, kinds = {.Pad}, group = 0,
		run = proc(a: ^App, t: Target) { a.selected = t.index }})
	add(c, {id = "pad.rename", label = "Rename…", icon = ui.ICON_PENCIL, kinds = {.Pad}, group = 0,
		run = proc(a: ^App, t: Target) { begin_rename_pad(a, t.index) }})
	add(c, {id = "pad.piano", label = "Edit in the Piano Roll", icon = ui.ICON_PIANO, kinds = {.Pad}, group = 0,
		run = proc(a: ^App, t: Target) { a.selected = t.index; a.seq.piano, a.seq.piano_pad, a.seq.view.key0 = true, t.index, -1; ui.panel_focus(&a.ws, "sequence") }})
	add(c, {id = "pad.edit", label = "Edit Sound", icon = ui.ICON_SLIDERS_HORIZONTAL, kinds = {.Pad}, group = 0,
		run = proc(a: ^App, t: Target) { a.selected = t.index; show_detail(a, .Sample) }})
	add(c, {id = "pad.mute", label = "Mute", icon = ui.ICON_VOLUME_X, kinds = {.Pad}, group = 1,
		run = proc(a: ^App, t: Target) { pa.pad_set_mute(&a.api, i64(t.index), !a.m.project.pads[t.index].mute) },
		checked = proc(a: ^App, t: Target) -> bool { return a.m.project.pads[t.index].mute }})
	add(c, {id = "pad.solo", label = "Solo", icon = ui.ICON_HEADPHONES, kinds = {.Pad}, group = 1,
		run = proc(a: ^App, t: Target) { pa.pad_set_solo(&a.api, i64(t.index), !a.m.project.pads[t.index].solo) },
		checked = proc(a: ^App, t: Target) -> bool { return a.m.project.pads[t.index].solo }})
	add(c, {id = "pad.arm", label = "Arm to Record", icon = ui.ICON_CIRCLE_DOT, kinds = {.Pad}, group = 1,
		run = proc(a: ^App, t: Target) { pa.pad_set_armed(&a.api, i64(t.index), !pm.track_armed(&a.m, t.index)) },
		enabled = proc(a: ^App, t: Target) -> bool { return a.m.project.pads[t.index].kind == .Audio },
		checked = proc(a: ^App, t: Target) -> bool { return pm.track_armed(&a.m, t.index) }})
	add(c, {id = "pad.audio", label = "Audio Track", icon = ui.ICON_MIC, kinds = {.Pad}, group = 1,
		run = proc(a: ^App, t: Target) { k := a.m.project.pads[t.index].kind; pa.pad_set_kind(&a.api, i64(t.index), .Sampler if k == .Audio else .Audio) },
		checked = proc(a: ^App, t: Target) -> bool { return a.m.project.pads[t.index].kind == .Audio }})
	add(c, {id = "pad.slicer", label = "Slicer", icon = ui.ICON_SCISSORS, kinds = {.Pad}, group = 1,
		run = proc(a: ^App, t: Target) {
			pa.pad_set_kind(&a.api, i64(t.index), .Sampler if a.m.project.pads[t.index].kind == .Slicer else .Slicer)
			a.selected = t.index
		},
		enabled = proc(a: ^App, t: Target) -> bool { return a.m.project.pads[t.index].kind != .Audio },
		checked = proc(a: ^App, t: Target) -> bool { return a.m.project.pads[t.index].kind == .Slicer }})
	add(c, {id = "pad.synth", label = "Synth", icon = ui.ICON_AUDIO_WAVEFORM, kinds = {.Pad}, group = 1,
		run = proc(a: ^App, t: Target) {
			pa.pad_set_kind(&a.api, i64(t.index), .Sampler if a.m.project.pads[t.index].kind == .Synth else .Synth)
			a.selected = t.index
		},
		enabled = proc(a: ^App, t: Target) -> bool { return a.m.project.pads[t.index].kind != .Audio },
		checked = proc(a: ^App, t: Target) -> bool { return a.m.project.pads[t.index].kind == .Synth }})
	add(c, {id = "pad.freeze", label = "Freeze", icon = ui.ICON_SNOWFLAKE, kinds = {.Pad}, group = 2,
		run = proc(a: ^App, t: Target) { start_freeze(a, t.index) },
		enabled = proc(a: ^App, t: Target) -> bool { return pm.can_freeze(&a.m.project, t.index) }})
	add(c, {id = "pad.unfreeze", label = "Unfreeze", icon = ui.ICON_SNOWFLAKE, kinds = {.Pad}, group = 2,
		run = proc(a: ^App, t: Target) { pa.export_unfreeze(&a.api, i64(t.index)) },
		enabled = proc(a: ^App, t: Target) -> bool { return a.m.project.pads[t.index].frozen }})
	add(c, {id = "pad.flatten", label = "Flatten to Audio", icon = ui.ICON_SNOWFLAKE, kinds = {.Pad}, group = 2,
		run = proc(a: ^App, t: Target) { pa.export_flatten(&a.api, i64(t.index)) },
		enabled = proc(a: ^App, t: Target) -> bool { return a.m.project.pads[t.index].frozen }})
	add(c, {id = "pad.bounce", label = "Bounce to Pad", icon = ui.ICON_COMBINE, kinds = {.Pad}, group = 2,
		run = proc(a: ^App, t: Target) { start_bounce_pads(a, selected_pads(a) if t.index in selected_pads(a) else {t.index}) }, enabled = pad_has})
	add(c, {id = "pad.bounce_in_place", label = "Bounce in Place", icon = ui.ICON_AUDIO_LINES, kinds = {.Pad}, group = 2,
		run = proc(a: ^App, t: Target) { start_bounce_in_place(a, t.index) },
		enabled = proc(a: ^App, t: Target) -> bool { return pm.can_bounce_in_place(&a.m.project, t.index) }})
	add(c, {id = "pad.group", label = "Group Selected Pads", icon = ui.ICON_GROUP, kinds = {.Pad}, group = 2, keys = "Cmd+G",
		run = proc(a: ^App, t: Target) { group_selected(a, t.index) }, enabled = pad_has})
	add(c, {id = "bus.ungroup", label = "Ungroup", icon = ui.ICON_GROUP, kinds = {.Bus}, group = 1,
		run = proc(a: ^App, t: Target) { pa.mixer_ungroup(&a.api, i64(t.index)) },
		enabled = proc(a: ^App, t: Target) -> bool { return t.index < pm.BUSES && a.m.project.buses[t.index].group }})
	add(c, {id = "pad.copy", label = "Copy Pad", icon = ui.ICON_COPY, kinds = {.Pad}, group = 2,
		run = proc(a: ^App, t: Target) { a.pad_clip, a.has_pad_clip = a.m.project.pads[t.index], true }, enabled = pad_has})
	add(c, {id = "pad.paste", label = "Paste Pad", icon = ui.ICON_CLIPBOARD_PASTE, kinds = {.Pad}, group = 2,
		run = proc(a: ^App, t: Target) { pm.set_pad(&a.m, t.index, .Whole, "Paste Pad", a.pad_clip); app.seal(&a.m.history) }, // api-lint: the pad as it was copied (the clipboard is the UI's)
		enabled = proc(a: ^App, t: Target) -> bool { return a.has_pad_clip }})
	add(c, {id = "pad.duplicate", label = "Duplicate to Next Empty Pad", icon = ui.ICON_COPY_PLUS, kinds = {.Pad}, group = 2,
		run = proc(a: ^App, t: Target) { if to, r := pa.pad_duplicate(&a.api, i64(t.index)); r == .Ok do a.selected = int(to) }, enabled = pad_has})
	add(c, {id = "pad.clear", label = "Clear Pad", icon = ui.ICON_ERASER, kinds = {.Pad}, group = 2, keys = "Delete",
		run = proc(a: ^App, t: Target) { pa.pad_clear(&a.api, i64(t.index)) }, enabled = pad_has})

	// Notes.
	add(c, {id = "note.delete", label = "Delete Note", icon = ui.ICON_TRASH_2, kinds = {.Note}, group = 0,
		run = proc(a: ^App, t: Target) { pa.sequence_remove_notes(&a.api, i64(t.slot), {i64(t.index)}); a.seq.selected = -1 }})
	add(c, {id = "note.duplicate", label = "Duplicate Note", icon = ui.ICON_COPY_PLUS, kinds = {.Note}, group = 0,
		run = proc(a: ^App, t: Target) {
			n, _ := pa.sequence_note(&a.api, i64(t.slot), i64(t.index))
			n.start += n.length
			pa.sequence_add_note(&a.api, i64(t.slot), n)
		}})
	add(c, {id = "note.loud", label = "Velocity 100%", icon = ui.ICON_SIGNAL_HIGH, kinds = {.Note}, group = 1, run = proc(a: ^App, t: Target) { note_velocity(a, t, 1) }})
	add(c, {id = "note.medium", label = "Velocity 70%", icon = ui.ICON_SIGNAL_MEDIUM, kinds = {.Note}, group = 1, run = proc(a: ^App, t: Target) { note_velocity(a, t, 0.7) }})
	add(c, {id = "note.soft", label = "Velocity 40%", icon = ui.ICON_SIGNAL_LOW, kinds = {.Note}, group = 1, run = proc(a: ^App, t: Target) { note_velocity(a, t, 0.4) }})
	add(c, {id = "note.chance", label = "Chance 50%", icon = ui.ICON_DICES, kinds = {.Note}, group = 1,
		run = proc(a: ^App, t: Target) {
			n, _ := pa.sequence_note(&a.api, i64(t.slot), i64(t.index))
			n.probability = 1 if n.probability < 1 else 0.5
			pa.sequence_set_note(&a.api, i64(t.slot), i64(t.index), n)
		},
		checked = proc(a: ^App, t: Target) -> bool { return a.m.project.sequences[t.slot].notes[t.index].probability < 1 }})

	// The marked part.
	add(c, {id = "part.copy", label = "Copy", icon = ui.ICON_COPY, kinds = {.Part}, group = 0, keys = "Cmd+C", run = proc(a: ^App, t: Target) { copy_marked(a) },
		enabled = proc(a: ^App, t: Target) -> bool { return len(a.seq.sel) > 0 }})
	add(c, {id = "part.paste", label = "Paste Here", icon = ui.ICON_CLIPBOARD_PASTE, kinds = {.Part}, group = 0, keys = "Cmd+V",
		run = proc(a: ^App, t: Target) { paste_marked(a) }, enabled = proc(a: ^App, t: Target) -> bool { return a.seq_ops.has_part }})
	add(c, {id = "part.duplicate", label = "Duplicate After", icon = ui.ICON_COPY_PLUS, kinds = {.Part}, group = 0, keys = "Cmd+D",
		run = proc(a: ^App, t: Target) { duplicate_selection(a) }, enabled = proc(a: ^App, t: Target) -> bool { return len(a.seq.sel) > 0 }})
	add(c, {id = "part.mute", label = "Mute / Unmute", icon = ui.ICON_VOLUME_X, kinds = {.Part}, group = 1, keys = "0",
		run = proc(a: ^App, t: Target) { mute_selection(a) }, enabled = proc(a: ^App, t: Target) -> bool { return len(a.seq.sel) > 0 }})
	add(c, {id = "part.delete", label = "Delete Notes", icon = ui.ICON_TRASH_2, kinds = {.Part}, group = 1, keys = "Delete / Backspace",
		run = proc(a: ^App, t: Target) { delete_selection(a) }, enabled = proc(a: ^App, t: Target) -> bool { return len(a.seq.sel) > 0 }})

	// Sequences.
	add(c, {id = "seq.select", label = "Edit", icon = ui.ICON_LIST_MUSIC, kinds = {.Sequence}, group = 0, run = proc(a: ^App, t: Target) { pa.sequence_select(&a.api, i64(t.slot)) }})
	add(c, {id = "seq.rename", label = "Rename…", icon = ui.ICON_PENCIL, kinds = {.Sequence}, group = 0, keys = "F2", run = proc(a: ^App, t: Target) { begin_rename_sequence(a, t.slot) }})
	add(c, {id = "seq.lane_left", label = "Move to the Lane Before", icon = ui.ICON_CHEVRON_LEFT, kinds = {.Sequence}, group = 2,
		run = proc(a: ^App, t: Target) { p := &a.m.project; l := pm.seq_lane(p, t.slot) - 1; pa.launcher_move_sequence(&a.api, i64(t.slot), i64(l), i64(pm.lane_rows(p, l))) },
		enabled = proc(a: ^App, t: Target) -> bool { return pm.seq_lane(&a.m.project, t.slot) > 0 }})
	add(c, {id = "seq.lane_right", label = "Move to the Lane After", icon = ui.ICON_CHEVRON_RIGHT, kinds = {.Sequence}, group = 2,
		run = proc(a: ^App, t: Target) { p := &a.m.project; l := pm.seq_lane(p, t.slot) + 1; pa.launcher_move_sequence(&a.api, i64(t.slot), i64(l), i64(pm.lane_rows(p, l))) },
		enabled = proc(a: ^App, t: Target) -> bool { return pm.seq_lane(&a.m.project, t.slot) < a.m.project.lanes.count - 1 }})
	add(c, {id = "seq.row_up", label = "Move Up a Row", icon = ui.ICON_CHEVRON_UP, kinds = {.Sequence}, group = 2,
		run = proc(a: ^App, t: Target) { p := &a.m.project; pa.launcher_move_sequence(&a.api, i64(t.slot), i64(pm.seq_lane(p, t.slot)), i64(p.lanes.place[t.slot].row) + 1) },
		enabled = proc(a: ^App, t: Target) -> bool { p := &a.m.project; return int(p.lanes.place[t.slot].row) < pm.lane_rows(p, pm.seq_lane(p, t.slot)) - 1 }})
	add(c, {id = "seq.row_down", label = "Move Down a Row", icon = ui.ICON_CHEVRON_DOWN, kinds = {.Sequence}, group = 2,
		run = proc(a: ^App, t: Target) { p := &a.m.project; pa.launcher_move_sequence(&a.api, i64(t.slot), i64(pm.seq_lane(p, t.slot)), i64(p.lanes.place[t.slot].row) - 1) },
		enabled = proc(a: ^App, t: Target) -> bool { return a.m.project.lanes.place[t.slot].row > 0 }})
	add(c, {id = "seq.duplicate", label = "Duplicate", icon = ui.ICON_COPY_PLUS, kinds = {.Sequence}, group = 1, keys = "Cmd+D", run = proc(a: ^App, t: Target) { pa.sequence_duplicate(&a.api, i64(t.slot)) }})
	add(c, {id = "seq.copy_bars", label = "Copy Bars to…", icon = ui.ICON_COPY, kinds = {.Sequence}, group = 1, run = proc(a: ^App, t: Target) { begin_copy_bars(a, t.slot) }})
	add(c, {id = "seq.double", label = "Double", icon = ui.ICON_MERGE, kinds = {.Sequence}, group = 1, run = proc(a: ^App, t: Target) { pa.sequence_double(&a.api, i64(t.slot)) }})
	add(c, {id = "seq.to_song", label = "Add to Song", icon = ui.ICON_LIST_ORDERED, kinds = {.Sequence}, group = 1, run = proc(a: ^App, t: Target) { pa.song_add(&a.api, i64(t.slot)) }})
	add(c, {id = "seq.tempo", label = "Own Tempo", icon = ui.ICON_GAUGE, kinds = {.Sequence}, group = 2,
		run = proc(a: ^App, t: Target) {
			own := a.m.project.sequences[t.slot].bpm > 0
			pa.sequence_set_tempo(&a.api, i64(t.slot), 0 if own else a.m.project.bpm)
		},
		checked = proc(a: ^App, t: Target) -> bool { return a.m.project.sequences[t.slot].bpm > 0 }})
	add(c, {id = "seq.clear", label = "Clear", icon = ui.ICON_TRASH_2, kinds = {.Sequence}, group = 3, run = proc(a: ^App, t: Target) { pa.sequence_clear(&a.api, i64(t.slot)) }})

	// Song clips (each acts on the selection when the clip is in it).
	add(c, {id = "clip.edit", label = "Edit Its Sequence", icon = ui.ICON_LIST_MUSIC, kinds = {.Song_Clip}, group = 0,
		run = proc(a: ^App, t: Target) {
			pa.sequence_select(&a.api, i64(int(a.m.project.song.clips[t.index].slot)))
			ui.panel_focus(&a.ws, "sequence")
		}})
	add(c, {id = "clip.mute", label = "Mute", icon = ui.ICON_VOLUME_X, kinds = {.Song_Clip}, group = 1,
		run = proc(a: ^App, t: Target) {
			on := !a.m.project.song.clips[t.index].mute
			pa.history_group_begin(&a.api, "Mute Clips" if on else "Unmute Clips")
			for k in clip_targets(a, t.index) {
				c, _ := pa.song_clip(&a.api, i64(k))
				c.mute = on
				pa.song_set_clip(&a.api, i64(k), c)
			}
			pa.history_group_end(&a.api)
		},
		checked = proc(a: ^App, t: Target) -> bool { return a.m.project.song.clips[t.index].mute }})
	add(c, {id = "clip.duplicate", label = "Duplicate", icon = ui.ICON_COPY_PLUS, kinds = {.Song_Clip}, group = 2,
		run = proc(a: ^App, t: Target) {
			if added := song_duplicate_set(a, clip_targets(a, t.index)); added != {} do a.song_ui.sel = added
		}})
	add(c, {id = "clip.remove", label = "Remove from Song", icon = ui.ICON_X, kinds = {.Song_Clip}, group = 2,
		run = proc(a: ^App, t: Target) {
			pa.song_remove_clips(&a.api, clip_ids(clip_targets(a, t.index)))
			a.song_ui.sel, a.song_ui.cur = {}, -1
		}})

	// Effect slots (inserts, bus slots, performance effects).
	add(c, {id = "slot.edit", label = "Edit Effect", icon = ui.ICON_SLIDERS_HORIZONTAL, kinds = {.Slot}, group = 0, run = proc(a: ^App, t: Target) { show_device(a, t.fx) }})
	add(c, {id = "slot.bypass", label = "On", icon = ui.ICON_POWER, kinds = {.Slot}, group = 0,
		run = proc(a: ^App, t: Target) { s, _ := pm.target_slot(&a.m, t.fx); pa.effect_set_on(&a.api, slot_ref(t.fx), !s.on) },
		enabled = slot_full, checked = proc(a: ^App, t: Target) -> bool { s, _ := pm.target_slot(&a.m, t.fx); return s.on }})
	add(c, {id = "slot.copy", label = "Copy Effect", icon = ui.ICON_COPY, kinds = {.Slot}, group = 1,
		run = proc(a: ^App, t: Target) { a.slot_clip, _ = pm.target_slot(&a.m, t.fx); a.has_slot_clip = true }, enabled = slot_full})
	add(c, {id = "slot.paste", label = "Paste Effect", icon = ui.ICON_CLIPBOARD_PASTE, kinds = {.Slot}, group = 1,
		run = proc(a: ^App, t: Target) { pm.set_target_slot(&a.m, t.fx, a.slot_clip, "Paste Effect") }, // api-lint: the effect as it was copied (the clipboard is the UI's)
		enabled = proc(a: ^App, t: Target) -> bool { return a.has_slot_clip && (t.fx.kind != .Perf || a.slot_clip.kind != .None) }})
	add(c, {id = "slot.clear", label = "Remove Effect", icon = ui.ICON_X, kinds = {.Slot}, group = 1,
		run = proc(a: ^App, t: Target) { pa.effect_clear(&a.api, slot_ref(t.fx)) },
		enabled = proc(a: ^App, t: Target) -> bool { return slot_full(a, t) && t.fx.kind != .Perf }})

	// Buses.
	add(c, {id = "bus.mute", label = "Mute", icon = ui.ICON_VOLUME_X, kinds = {.Bus}, group = 0,
		run = proc(a: ^App, t: Target) { pa.mixer_set_bus_mute(&a.api, i64(t.index), !pm.bus_of(&a.m, t.index).mute) },
		checked = proc(a: ^App, t: Target) -> bool { return pm.bus_of(&a.m, t.index).mute }})
	add(c, {id = "bus.solo", label = "Solo", icon = ui.ICON_HEADPHONES, kinds = {.Bus}, group = 0,
		run = proc(a: ^App, t: Target) { pa.mixer_set_bus_solo(&a.api, i64(t.index), !pm.bus_of(&a.m, t.index).solo) },
		enabled = proc(a: ^App, t: Target) -> bool { return t.index != pm.BUSES },
		checked = proc(a: ^App, t: Target) -> bool { return pm.bus_of(&a.m, t.index).solo }})
	add(c, {id = "bus.reset", label = "Reset Level and Pan", icon = ui.ICON_ROTATE_CCW, kinds = {.Bus}, group = 1,
		run = proc(a: ^App, t: Target) {
			pa.history_group_begin(&a.api, "Reset Bus")
			pa.mixer_set_bus_volume(&a.api, i64(t.index), 0)
			pa.mixer_set_bus_pan(&a.api, i64(t.index), 0)
			pa.history_group_end(&a.api)
		}})
	add(c, {id = "bus.bounce", label = "Bounce to Pad", icon = ui.ICON_COMBINE, kinds = {.Bus}, group = 1,
		run = proc(a: ^App, t: Target) { if t.index == pm.BUSES do start_resample(a); else do start_bounce_bus(a, t.index) }})
	add(c, {id = "bus.rename", label = "Rename…", icon = ui.ICON_PENCIL, kinds = {.Bus}, group = 2,
		run = proc(a: ^App, t: Target) { begin_rename_bus(a, t.index + 1) },
		enabled = proc(a: ^App, t: Target) -> bool { return t.index != pm.BUSES }})
	add(c, {id = "bus.delete", label = "Delete Bus", icon = ui.ICON_TRASH_2, kinds = {.Bus}, group = 2,
		run = proc(a: ^App, t: Target) { pa.mixer_delete_bus(&a.api, i64(t.index)) },
		enabled = proc(a: ^App, t: Target) -> bool { return t.index != pm.BUSES && a.m.project.bus_count > 1 }})
	add(c, {id = "bus.add", label = "Add Bus", icon = ui.ICON_PLUS, kinds = {.Bus}, group = 2,
		run = proc(a: ^App, t: Target) { pa.mixer_add_bus(&a.api) },
		enabled = proc(a: ^App, t: Target) -> bool { return a.m.project.bus_count < pm.BUSES }})

	// Files in the browser.
	add(c, {id = "file.load", label = "Load onto Selected Pad", icon = ui.ICON_DOWNLOAD, kinds = {.File}, group = 0,
		run = proc(a: ^App, t: Target) { pa.pad_load_sample(&a.api, i64(a.selected), t.path) }})
	add(c, {id = "file.load_empty", label = "Load onto Next Empty Pad", icon = ui.ICON_SQUARE_PLUS, kinds = {.File}, group = 0,
		run = proc(a: ^App, t: Target) {
			for i in 0 ..< pm.PADS do if !pm.pad_used(&a.m.project, i) {
				if pa.pad_load_sample(&a.api, i64(i), t.path) == .Ok do a.selected = i
				return
			}
		}})
	add(c, {id = "file.slice_empty", label = "Slice onto Next Empty Pad", icon = ui.ICON_SCISSORS, kinds = {.File}, group = 1, keys = "Shift+Enter",
		run = proc(a: ^App, t: Target) { slice_onto_next(a, t.path) }})
	add(c, {id = "file.slice", label = "Slice onto Selected Pad", icon = ui.ICON_SCISSORS, kinds = {.File}, group = 1, keys = "Cmd+Shift+Enter",
		run = proc(a: ^App, t: Target) { load_into_slicer(a, a.selected, t.path) }})
	add(c, {id = "file.preview", label = "Preview", icon = ui.ICON_PLAY, kinds = {.File}, group = 0,
		run = proc(a: ^App, t: Target) { pa.browser_preview(&a.api, t.path) }})

	// Automation points.
	add(c, {id = "point.delete", label = "Delete Point", icon = ui.ICON_TRASH_2, kinds = {.Point}, group = 0,
		run = proc(a: ^App, t: Target) { pa.sequence_remove_point(&a.api, i64(t.slot), i64(t.index)) }})

	// An audio pad's take.
	add(c, {id = "take.clear", label = "Clear Take", icon = ui.ICON_ERASER, kinds = {.Take}, group = 0,
		run = proc(a: ^App, t: Target) { pa.audio_clear(&a.api, i64(t.index)) }})
}

@(private)
slot_full :: proc(a: ^App, t: Target) -> bool {
	s, ok := pm.target_slot(&a.m, t.fx)
	return ok && s.kind != .None
}

@(private)
note_velocity :: proc(a: ^App, t: Target, v: f32) {
	n, _ := pa.sequence_note(&a.api, i64(t.slot), i64(t.index))
	n.velocity = v
	pa.sequence_set_note(&a.api, i64(t.slot), i64(t.index), n)
}

// The palette's entries for the selection: the selected pad's commands
// ("Pad: Duplicate…"), the current sequence's, the marked part's.
// Registered once as actions that act on whatever is selected when run.
register_selection_actions :: proc(a: ^App, acts: ^ui.Actions) {
	for &c in a.commands {
		prefix := ""
		switch {
		case .Pad in c.kinds:      prefix = "Pad"
		case .Sequence in c.kinds: prefix = "Sequence"
		case .Part in c.kinds:     prefix = "Marked Notes"
		case: continue
		}
		cmd := new_clone(Selection_Action{a, &c})
		ui.action_add(acts, {id = c.id, label = strings.concatenate({prefix, ": ", c.label}), icon = c.icon, user = cmd,
			run = proc(u: rawptr) { s := (^Selection_Action)(u); run_command(s.app, s.cmd.id, selection_target(s.app, s.cmd.kinds)) },
			enabled = proc(u: rawptr) -> bool {
				s := (^Selection_Action)(u)
				t := selection_target(s.app, s.cmd.kinds)
				if t.kind == .Part && len(s.app.seq.sel) == 0 && s.cmd.id != "part.paste" do return false
				return s.cmd.enabled == nil || s.cmd.enabled(s.app, t)
			}})
	}
}

@(private)
Selection_Action :: struct {
	app: ^App,
	cmd: ^Command,
}

// What a command of `kinds` acts on now: the selected pad, the current
// sequence, the marked part.
selection_target :: proc(a: ^App, kinds: bit_set[Target_Kind]) -> Target {
	if .Pad in kinds do return pad_target(a.selected)
	if .Sequence in kinds do return seq_target(a.m.project.slot)
	if .Part in kinds do return {kind = .Part}
	return {}
}

// Whether `t` still names something: a note, a point, a song step, a bus
// that may have gone since its menu opened.
target_valid :: proc(a: ^App, t: Target) -> bool {
	p := &a.m.project
	#partial switch t.kind {
	case .Note:      return t.slot >= 0 && t.slot < pm.SLOTS && t.index >= 0 && t.index < len(p.sequences[t.slot].notes)
	case .Point:     return t.slot >= 0 && t.slot < pm.SLOTS && t.index >= 0 && t.index < len(p.sequences[t.slot].points)
	case .Song_Clip: return t.index >= 0 && t.index < p.song.count
	case .Pad, .Take: return t.index >= 0 && t.index < pm.PADS
	case .Bus:       return t.index == pm.BUSES || (t.index >= 0 && t.index < p.bus_count)
	case .Sequence:  return t.slot >= 0 && t.slot < pm.SLOTS
	}
	return true
}

// The clips a clip's command acts on: the selection when clip `i` is in it,
// else that clip alone.
@(private)
clip_targets :: proc(a: ^App, i: int) -> pm.Clip_Set {
	return a.song_ui.sel if i in a.song_ui.sel else {i}
}
