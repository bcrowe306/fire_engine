package pads

import "core:fmt"
import "core:strings"

import app "app:core"
import "app:ui"
import im "deps:imgui"

// Every action's shortcut can be changed (Settings > Keyboard): what
// differs from its own is kept in settings.ini's [keys], as text
// ("Cmd+Shift+S"; Cmd is Ctrl off macOS).

// Notes each action's own shortcut, then puts the user's in place.
keys_apply :: proc(a: ^App) {
	s := &a.settings
	if len(s.defaults) == 0 do for x in a.actions.list do append(&s.defaults, Key_Override{strings.clone(x.id), x.chord})
	for k in s.keys do delete(k.id)
	clear(&s.keys)
	for sec in s.ini.sections do if sec.name == "keys" {
		for e in sec.entries {
			chord, ok := parse_chord_name(e.value)
			if ok do append(&s.keys, Key_Override{strings.clone(e.key), chord})
		}
	}
	for &x in a.actions.list do x.chord = key_of(a, x.id)
}

// The shortcut action `id` has now: the user's, else its own.
key_of :: proc(a: ^App, id: string) -> im.KeyChord {
	for k in a.settings.keys do if k.id == id do return k.chord
	return default_key(a, id)
}

@(private)
default_key :: proc(a: ^App, id: string) -> im.KeyChord {
	for k in a.settings.defaults do if k.id == id do return k.chord
	return 0
}

// Gives action `id` shortcut `chord` (0: none), as the user's if it differs
// from its own.
set_key :: proc(a: ^App, id: string, chord: im.KeyChord) {
	s := &a.settings
	for k, i in s.keys do if k.id == id {
		delete(k.id)
		ordered_remove(&s.keys, i)
		break
	}
	if chord != default_key(a, id) do append(&s.keys, Key_Override{strings.clone(id), chord})
	for &x in a.actions.list do if x.id == id do x.chord = chord
}

// A shortcut as settings.ini keeps it: "Cmd+Shift+S", "Space", "F2".
chord_name :: proc(chord: im.KeyChord) -> string {
	b := strings.builder_make(context.temp_allocator)
	if chord & ui.MOD_CMD != 0 do strings.write_string(&b, "Cmd+")
	if chord & ui.MOD_ALT != 0 do strings.write_string(&b, "Alt+")
	if chord & ui.MOD_SHIFT != 0 do strings.write_string(&b, "Shift+")
	strings.write_string(&b, string(im.GetKeyName(im.Key(chord & ~i32(im.KEY_MOD_MASK)))))
	return strings.to_string(b)
}

// A shortcut from its text (as `chord_name` writes it); "none" is no
// shortcut. False if it can't be read.
parse_chord_name :: proc(text: string) -> (chord: im.KeyChord, ok: bool) {
	t := strings.trim_space(text)
	if strings.to_lower(t, context.temp_allocator) == "none" do return 0, true
	parts := strings.split(t, "+", context.temp_allocator)
	for p, i in parts {
		if i < len(parts) - 1 {
			switch strings.to_lower(strings.trim_space(p), context.temp_allocator) {
			case "cmd", "ctrl": chord |= ui.MOD_CMD
			case "alt", "option": chord |= ui.MOD_ALT
			case "shift": chord |= ui.MOD_SHIFT
			case: return 0, false
			}
			continue
		}
		key := strings.trim_space(p)
		for k := i32(im.Key.NamedKey_BEGIN); k < i32(im.Key.NamedKey_END); k += 1 {
			if strings.equal_fold(string(im.GetKeyName(im.Key(k))), key) {
				return chord | k, true
			}
		}
		return 0, false
	}
	return 0, false
}

// Keys an editor reads itself (not actions): listed, not changed.
@(private)
FIXED_KEYS := [?][2]cstring{
	{"V  B  E  M", "Sequence editor tools: Select, Draw, Erase, Move"},
	{"Backspace / Delete", "Delete the selected notes, or song clips"},
	{"0", "Mute or unmute the selected notes"},
	{"Arrows (Shift: a bar)", "Nudge the selected notes"},
	{"Cmd+A", "Select every note, or song clip"},
	{"Cmd+X", "Cut the selected song clips"},
	{"Z X C V  A S D F  Q W E R  1 2 3 4", "Play the pads of the bank"},
	{"Esc", "Back to the Select tool; close a dialog"},
}

@(private)
page_keyboard :: proc(a: ^App) -> (changed: bool) {
	s := &a.settings
	io := im.GetIO()
	// Recording a shortcut: the next key pressed with what is held (Esc
	// stops, Backspace takes it away).
	if s.recording != "" {
		if im.IsKeyPressed(.Escape, false) {
			delete(s.recording)
			s.recording = ""
		} else if im.IsKeyPressed(.Backspace, false) && !io.KeyCtrl && !io.KeyShift && !io.KeyAlt {
			set_key(a, s.recording, 0)
			delete(s.recording)
			s.recording = ""
			changed = true
		} else {
			for k := i32(im.Key.NamedKey_BEGIN); k < i32(im.Key.NamedKey_END); k += 1 {
				key := im.Key(k)
				if key >= .ReservedForModCtrl || is_modifier(key) || key == .MouseLeft || key == .MouseRight || key == .MouseMiddle do continue
				if !im.IsKeyPressed(key, false) do continue
				chord := im.KeyChord(k)
				if io.KeyCtrl do chord |= ui.MOD_CMD
				if io.KeyAlt do chord |= ui.MOD_ALT
				if io.KeyShift do chord |= ui.MOD_SHIFT
				set_key(a, s.recording, chord)
				delete(s.recording)
				s.recording = ""
				changed = true
				break
			}
		}
	}
	im.SetNextItemWidth(260)
	im.InputTextWithHint("##kfilter", "Search commands", cstring(&s.key_filter[0]), len(s.key_filter))
	im.SameLine()
	if im.Button("Reset all") {
		for x in a.actions.list do set_key(a, x.id, default_key(a, x.id))
		changed = true
	}
	q := strings.to_lower(strings.truncate_to_byte(string(s.key_filter[:]), 0), context.temp_allocator)
	if im.BeginTable("##keys", 3, {.RowBg, .BordersInnerH, .SizingStretchProp}) {
		im.TableSetupColumn("Command", {.WidthStretch}, 3)
		im.TableSetupColumn("Shortcut", {.WidthStretch}, 2)
		im.TableSetupColumn("", {.WidthStretch}, 2)
		im.TableHeadersRow()
		for x in a.actions.list {
			if q != "" && !strings.contains(strings.to_lower(x.label, context.temp_allocator), q) do continue
			im.TableNextRow()
			im.TableNextColumn()
			im.AlignTextToFramePadding()
			im.TextUnformatted(fmt.ctprintf("%s", x.label))
			im.TableNextColumn()
			rec := s.recording == x.id
			text := "Press a key…" if rec else (ui.chord_text(x.chord) if x.chord != 0 else "—")
			if rec do im.PushStyleColorVec4(.Button, transmute(im.Vec4)ui.theme().accent)
			if im.Button(fmt.ctprintf("%s###k%s", text, x.id), {150, 0}) {
				delete(s.recording)
				s.recording = strings.clone(x.id)
			}
			ui.name(fmt.tprintf("key %s", x.id))
			if rec do im.PopStyleColor()
			if im.IsItemHovered() && !rec do im.SetTooltip("Click, then press the new shortcut (Esc: keep it; Backspace: none)")
			im.TableNextColumn()
			// The same shortcut on another command: say so, and offer to take it.
			if x.chord != 0 do for y in a.actions.list do if y.id != x.id && y.chord == x.chord {
				im.AlignTextToFramePadding()
				im.TextColored(transmute(im.Vec4)ui.theme().danger, "%s", fmt.ctprintf("Also %s", y.label))
				im.SameLine()
				if im.SmallButton(fmt.ctprintf("Take it###take%s", x.id)) {
					set_key(a, y.id, 0)
					changed = true
				}
				break
			}
			if x.chord != default_key(a, x.id) {
				im.SameLine()
				if im.SmallButton(fmt.ctprintf("Reset###reset%s", x.id)) {
					set_key(a, x.id, default_key(a, x.id))
					changed = true
				}
			}
		}
		im.EndTable()
	}
	im.SeparatorText("In the editors (fixed)")
	for k in FIXED_KEYS {
		label(k[0], 280)
		im.TextDisabled("%s", k[1])
	}
	return
}

@(private)
is_modifier :: proc(k: im.Key) -> bool {
	#partial switch k {
	case .LeftCtrl, .RightCtrl, .LeftShift, .RightShift, .LeftAlt, .RightAlt, .LeftSuper, .RightSuper: return true
	}
	return false
}

_ :: app.Ini
