package pads

import "core:fmt"
import "core:strings"

import app "app:core"
import "app:ui"
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
	Song_Step, // `index`
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
	if c == nil || t.kind not_in c.kinds do return false
	if c.enabled != nil && !c.enabled(a, t) do return false
	c.run(a, t)
	return true
}

// The menu items of every command for `t` (inside an open popup), groups
// apart. `extra` draws more first (a pad's colours, say).
command_items :: proc(a: ^App, t: Target) {
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
		if ran do c.run(a, t)
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
		run = proc(a: ^App, t: Target) { pm.hit(&a.m.engine, t.index, true); a.release_at[t.index] = 12 }, enabled = pad_has})
	add(c, {id = "pad.select", label = "Select", icon = ui.ICON_MOUSE_POINTER, kinds = {.Pad}, group = 0,
		run = proc(a: ^App, t: Target) { a.selected = t.index }})
	add(c, {id = "pad.edit", label = "Edit Sound", icon = ui.ICON_SLIDERS_HORIZONTAL, kinds = {.Pad}, group = 0,
		run = proc(a: ^App, t: Target) { a.selected = t.index; show_detail(a, .Sample) }})
	add(c, {id = "pad.mute", label = "Mute", icon = ui.ICON_VOLUME_X, kinds = {.Pad}, group = 1,
		run = proc(a: ^App, t: Target) { p := a.m.project.pads[t.index]; p.mute = !p.mute; pm.set_pad(&a.m, t.index, .Mute, "Mute", p); app.seal(&a.m.history) },
		checked = proc(a: ^App, t: Target) -> bool { return a.m.project.pads[t.index].mute }})
	add(c, {id = "pad.solo", label = "Solo", icon = ui.ICON_HEADPHONES, kinds = {.Pad}, group = 1,
		run = proc(a: ^App, t: Target) { p := a.m.project.pads[t.index]; p.solo = !p.solo; pm.set_pad(&a.m, t.index, .Solo, "Solo", p); app.seal(&a.m.history) },
		checked = proc(a: ^App, t: Target) -> bool { return a.m.project.pads[t.index].solo }})
	add(c, {id = "pad.arm", label = "Arm to Record", icon = ui.ICON_CIRCLE_DOT, kinds = {.Pad}, group = 1,
		run = proc(a: ^App, t: Target) { pm.arm_audio(&a.m, t.index, !pm.audio_armed(&a.m, t.index)) },
		enabled = proc(a: ^App, t: Target) -> bool { return a.m.project.pads[t.index].kind == .Audio },
		checked = proc(a: ^App, t: Target) -> bool { return pm.audio_armed(&a.m, t.index) }})
	add(c, {id = "pad.audio", label = "Audio Track", icon = ui.ICON_MIC, kinds = {.Pad}, group = 1,
		run = proc(a: ^App, t: Target) { k := a.m.project.pads[t.index].kind; pm.set_pad_kind(&a.m, t.index, .Sampler if k == .Audio else .Audio) },
		checked = proc(a: ^App, t: Target) -> bool { return a.m.project.pads[t.index].kind == .Audio }})
	add(c, {id = "pad.copy", label = "Copy Pad", icon = ui.ICON_COPY, kinds = {.Pad}, group = 2,
		run = proc(a: ^App, t: Target) { a.pad_clip, a.has_pad_clip = a.m.project.pads[t.index], true }, enabled = pad_has})
	add(c, {id = "pad.paste", label = "Paste Pad", icon = ui.ICON_CLIPBOARD_PASTE, kinds = {.Pad}, group = 2,
		run = proc(a: ^App, t: Target) { pm.set_pad(&a.m, t.index, .Whole, "Paste Pad", a.pad_clip); app.seal(&a.m.history) },
		enabled = proc(a: ^App, t: Target) -> bool { return a.has_pad_clip }})
	add(c, {id = "pad.duplicate", label = "Duplicate to Next Empty Pad", icon = ui.ICON_COPY_PLUS, kinds = {.Pad}, group = 2,
		run = proc(a: ^App, t: Target) { if to := pm.duplicate_pad(&a.m, t.index); to >= 0 do a.selected = to }, enabled = pad_has})
	add(c, {id = "pad.clear", label = "Clear Pad", icon = ui.ICON_ERASER, kinds = {.Pad}, group = 2, keys = "Delete",
		run = proc(a: ^App, t: Target) { pm.clear_pad(&a.m, t.index) }, enabled = pad_has})

	// Notes.
	add(c, {id = "note.delete", label = "Delete Note", icon = ui.ICON_TRASH_2, kinds = {.Note}, group = 0,
		run = proc(a: ^App, t: Target) { pm.remove_notes(&a.m, t.slot, {t.index}); a.seq.selected = -1 }})
	add(c, {id = "note.duplicate", label = "Duplicate Note", icon = ui.ICON_COPY_PLUS, kinds = {.Note}, group = 0,
		run = proc(a: ^App, t: Target) { n := a.m.project.sequences[t.slot].notes[t.index]; n.start += n.length; pm.add_note(&a.m, t.slot, n) }})
	add(c, {id = "note.loud", label = "Velocity 100%", icon = ui.ICON_SIGNAL_HIGH, kinds = {.Note}, group = 1, run = proc(a: ^App, t: Target) { note_velocity(a, t, 1) }})
	add(c, {id = "note.medium", label = "Velocity 70%", icon = ui.ICON_SIGNAL_MEDIUM, kinds = {.Note}, group = 1, run = proc(a: ^App, t: Target) { note_velocity(a, t, 0.7) }})
	add(c, {id = "note.soft", label = "Velocity 40%", icon = ui.ICON_SIGNAL_LOW, kinds = {.Note}, group = 1, run = proc(a: ^App, t: Target) { note_velocity(a, t, 0.4) }})
	add(c, {id = "note.chance", label = "Chance 50%", icon = ui.ICON_DICES, kinds = {.Note}, group = 1,
		run = proc(a: ^App, t: Target) {
			n := a.m.project.sequences[t.slot].notes[t.index]
			n.probability = 1 if n.probability < 1 else 0.5
			pm.set_note(&a.m, t.slot, t.index, n, .Probability, "Set Chance")
			app.seal(&a.m.history)
		},
		checked = proc(a: ^App, t: Target) -> bool { return a.m.project.sequences[t.slot].notes[t.index].probability < 1 }})

	// The marked part.
	add(c, {id = "part.copy", label = "Copy", icon = ui.ICON_COPY, kinds = {.Part}, group = 0, keys = "Cmd+C", run = proc(a: ^App, t: Target) { copy_marked(a) }})
	add(c, {id = "part.paste", label = "Paste Here", icon = ui.ICON_CLIPBOARD_PASTE, kinds = {.Part}, group = 0, keys = "Cmd+V",
		run = proc(a: ^App, t: Target) { paste_marked(a) }, enabled = proc(a: ^App, t: Target) -> bool { return a.seq_ops.has_part }})
	add(c, {id = "part.duplicate", label = "Duplicate After", icon = ui.ICON_COPY_PLUS, kinds = {.Part}, group = 0,
		run = proc(a: ^App, t: Target) {
			r := &a.seq.range
			if copy_marked(a) {
				span := r.beat1 - r.beat0
				r.beat0, r.beat1 = r.beat1, r.beat1 + span
				paste_marked(a)
			}
		}})
	add(c, {id = "part.delete", label = "Delete Notes", icon = ui.ICON_TRASH_2, kinds = {.Part}, group = 1,
		run = proc(a: ^App, t: Target) {
			r := a.seq.range
			pads: [pm.PADS]bool
			for k in r.key0 ..= r.key1 do if k >= 0 && k < pm.PADS_PER_BANK do pads[a.bank * pm.PADS_PER_BANK + k] = true
			pm.clear_part(&a.m, a.m.project.slot, r.beat0, r.beat1, &pads)
		}})

	// Sequences.
	add(c, {id = "seq.select", label = "Edit", icon = ui.ICON_LIST_MUSIC, kinds = {.Sequence}, group = 0, run = proc(a: ^App, t: Target) { pm.select_slot(&a.m, t.slot) }})
	add(c, {id = "seq.rename", label = "Rename…", icon = ui.ICON_PENCIL, kinds = {.Sequence}, group = 0, keys = "F2", run = proc(a: ^App, t: Target) { begin_rename_sequence(a, t.slot) }})
	add(c, {id = "seq.duplicate", label = "Duplicate", icon = ui.ICON_COPY_PLUS, kinds = {.Sequence}, group = 1, keys = "Cmd+D", run = proc(a: ^App, t: Target) { pm.duplicate_sequence(&a.m, t.slot) }})
	add(c, {id = "seq.copy_bars", label = "Copy Bars to…", icon = ui.ICON_COPY, kinds = {.Sequence}, group = 1, run = proc(a: ^App, t: Target) { begin_copy_bars(a, t.slot) }})
	add(c, {id = "seq.double", label = "Double", icon = ui.ICON_MERGE, kinds = {.Sequence}, group = 1, run = proc(a: ^App, t: Target) { pm.double_sequence(&a.m, t.slot) }})
	add(c, {id = "seq.to_song", label = "Add to Song", icon = ui.ICON_LIST_ORDERED, kinds = {.Sequence}, group = 1, run = proc(a: ^App, t: Target) { pm.song_add(&a.m, t.slot) }})
	add(c, {id = "seq.tempo", label = "Own Tempo", icon = ui.ICON_GAUGE, kinds = {.Sequence}, group = 2,
		run = proc(a: ^App, t: Target) {
			own := a.m.project.sequences[t.slot].bpm > 0
			pm.set_sequence_tempo(&a.m, t.slot, 0 if own else a.m.project.bpm)
			app.seal(&a.m.history)
		},
		checked = proc(a: ^App, t: Target) -> bool { return a.m.project.sequences[t.slot].bpm > 0 }})
	add(c, {id = "seq.clear", label = "Clear", icon = ui.ICON_TRASH_2, kinds = {.Sequence}, group = 3, run = proc(a: ^App, t: Target) { pm.clear_sequence(&a.m, t.slot) }})

	// Song steps.
	add(c, {id = "step.edit", label = "Edit Its Sequence", icon = ui.ICON_LIST_MUSIC, kinds = {.Song_Step}, group = 0,
		run = proc(a: ^App, t: Target) { pm.select_slot(&a.m, int(a.m.project.song.steps[t.index].slot)) }})
	add(c, {id = "step.more", label = "Repeat Once More", icon = ui.ICON_PLUS, kinds = {.Song_Step}, group = 1,
		run = proc(a: ^App, t: Target) { pm.song_repeats(&a.m, t.index, int(a.m.project.song.steps[t.index].repeats) + 1) }})
	add(c, {id = "step.less", label = "Repeat Once Less", icon = ui.ICON_MINUS, kinds = {.Song_Step}, group = 1,
		run = proc(a: ^App, t: Target) { pm.song_repeats(&a.m, t.index, int(a.m.project.song.steps[t.index].repeats) - 1) },
		enabled = proc(a: ^App, t: Target) -> bool { return a.m.project.song.steps[t.index].repeats > 1 }})
	add(c, {id = "step.duplicate", label = "Duplicate Step", icon = ui.ICON_COPY_PLUS, kinds = {.Song_Step}, group = 2,
		run = proc(a: ^App, t: Target) { st := a.m.project.song.steps[t.index]; pm.song_add(&a.m, int(st.slot), t.index, int(st.repeats)) }})
	add(c, {id = "step.remove", label = "Remove from Song", icon = ui.ICON_X, kinds = {.Song_Step}, group = 2, run = proc(a: ^App, t: Target) { pm.song_remove(&a.m, t.index) }})

	// Effect slots (inserts, bus slots, performance effects).
	add(c, {id = "slot.edit", label = "Edit Effect", icon = ui.ICON_SLIDERS_HORIZONTAL, kinds = {.Slot}, group = 0, run = proc(a: ^App, t: Target) { show_device(a, t.fx) }})
	add(c, {id = "slot.bypass", label = "On", icon = ui.ICON_POWER, kinds = {.Slot}, group = 0,
		run = proc(a: ^App, t: Target) { s, _ := pm.target_slot(&a.m, t.fx); s.on = !s.on; pm.set_target_slot(&a.m, t.fx, s, "Effect On" if s.on else "Effect Off") },
		enabled = slot_full, checked = proc(a: ^App, t: Target) -> bool { s, _ := pm.target_slot(&a.m, t.fx); return s.on }})
	add(c, {id = "slot.copy", label = "Copy Effect", icon = ui.ICON_COPY, kinds = {.Slot}, group = 1,
		run = proc(a: ^App, t: Target) { a.slot_clip, _ = pm.target_slot(&a.m, t.fx); a.has_slot_clip = true }, enabled = slot_full})
	add(c, {id = "slot.paste", label = "Paste Effect", icon = ui.ICON_CLIPBOARD_PASTE, kinds = {.Slot}, group = 1,
		run = proc(a: ^App, t: Target) { pm.set_target_slot(&a.m, t.fx, a.slot_clip, "Paste Effect") },
		enabled = proc(a: ^App, t: Target) -> bool { return a.has_slot_clip && (t.fx.kind != .Perf || a.slot_clip.kind != .None) }})
	add(c, {id = "slot.clear", label = "Remove Effect", icon = ui.ICON_X, kinds = {.Slot}, group = 1,
		run = proc(a: ^App, t: Target) { pm.set_target_slot(&a.m, t.fx, {}, "Remove Effect") },
		enabled = proc(a: ^App, t: Target) -> bool { return slot_full(a, t) && t.fx.kind != .Perf }})

	// Buses.
	add(c, {id = "bus.mute", label = "Mute", icon = ui.ICON_VOLUME_X, kinds = {.Bus}, group = 0,
		run = proc(a: ^App, t: Target) { b := pm.bus_of(&a.m, t.index)^; b.mute = !b.mute; pm.set_bus(&a.m, t.index, 1, "Mute", b); app.seal(&a.m.history) },
		checked = proc(a: ^App, t: Target) -> bool { return pm.bus_of(&a.m, t.index).mute }})
	add(c, {id = "bus.solo", label = "Solo", icon = ui.ICON_HEADPHONES, kinds = {.Bus}, group = 0,
		run = proc(a: ^App, t: Target) { b := pm.bus_of(&a.m, t.index)^; b.solo = !b.solo; pm.set_bus(&a.m, t.index, 1, "Solo", b); app.seal(&a.m.history) },
		enabled = proc(a: ^App, t: Target) -> bool { return t.index != pm.BUSES },
		checked = proc(a: ^App, t: Target) -> bool { return pm.bus_of(&a.m, t.index).solo }})
	add(c, {id = "bus.reset", label = "Reset Level and Pan", icon = ui.ICON_ROTATE_CCW, kinds = {.Bus}, group = 1,
		run = proc(a: ^App, t: Target) { b := pm.bus_of(&a.m, t.index)^; b.volume, b.pan = 0, 0; pm.set_bus(&a.m, t.index, 0, "Reset Bus", b); app.seal(&a.m.history) }})

	// Files in the browser.
	add(c, {id = "file.load", label = "Load onto Selected Pad", icon = ui.ICON_DOWNLOAD, kinds = {.File}, group = 0,
		run = proc(a: ^App, t: Target) { pm.load_onto_pad(&a.m, a.selected, t.path) }})
	add(c, {id = "file.load_empty", label = "Load onto Next Empty Pad", icon = ui.ICON_SQUARE_PLUS, kinds = {.File}, group = 0,
		run = proc(a: ^App, t: Target) {
			for i in 0 ..< pm.PADS do if !pm.pad_used(&a.m.project, i) {
				if pm.load_onto_pad(&a.m, i, t.path) == .None do a.selected = i
				return
			}
		}})
	add(c, {id = "file.preview", label = "Preview", icon = ui.ICON_PLAY, kinds = {.File}, group = 0,
		run = proc(a: ^App, t: Target) { pm.preview_play(&a.m.engine, t.path) }})

	// Automation points.
	add(c, {id = "point.delete", label = "Delete Point", icon = ui.ICON_TRASH_2, kinds = {.Point}, group = 0,
		run = proc(a: ^App, t: Target) { pm.remove_point(&a.m, t.slot, t.index) }})

	// An audio pad's take.
	add(c, {id = "take.clear", label = "Clear Take", icon = ui.ICON_ERASER, kinds = {.Take}, group = 0,
		run = proc(a: ^App, t: Target) { pm.clear_clip(&a.m, t.index) }})
}

@(private)
slot_full :: proc(a: ^App, t: Target) -> bool {
	s, ok := pm.target_slot(&a.m, t.fx)
	return ok && s.kind != .None
}

@(private)
note_velocity :: proc(a: ^App, t: Target, v: f32) {
	n := a.m.project.sequences[t.slot].notes[t.index]
	n.velocity = v
	pm.set_note(&a.m, t.slot, t.index, n, .Velocity, "Set Velocity")
	app.seal(&a.m.history)
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
				if t.kind == .Part && !s.app.seq.range.on do return false
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
