package pads

import "core:fmt"
import "core:strconv"
import "core:strings"

import app "app:core"
import "app:ui"
import pm "model"
import im "deps:imgui"

// The Devices panel (a tab beside the Browser): the instruments, effects
// and plug-ins there are, in a tree. Drag one onto a pad: an instrument
// becomes the pad's (a synth preset loads on a synth), an effect goes in
// its first empty insert. Double-click one for the selected pad.

// The drag-and-drop payload a device carries: what it is, as text
// ("inst synth", "preset 3", "fx 9", "clap 2" an effect plug-in, "clapi 0"
// an instrument plug-in).
PADS_DEVICE_PAYLOAD :: "PADS_DEVICE"

// The panel's state: the filter typed.
Devices_Ui :: struct {
	filter: [64]u8,
}

// What a device payload names.
@(private = "file")
Device_Item :: struct {
	label: string,
	icon:  string,
	code:  string, // the payload
	tip:   string,
}

draw_devices :: proc(user: rawptr) {
	a := (^App)(user)
	st := &a.devices
	im.SetNextItemWidth(-1)
	im.InputTextWithHint("##devfilter", fmt.ctprintf("%s  Find a device", ui.ICON_SEARCH), cstring(&st.filter[0]), len(st.filter))
	ui.name("device filter")
	find := strings.to_lower(strings.truncate_to_byte(string(st.filter[:]), 0), context.temp_allocator)
	im.Spacing()
	group :: proc(a: ^App, title: string, items: []Device_Item, find: string) {
		shown := 0
		for it in items do if find == "" || strings.contains(strings.to_lower(it.label, context.temp_allocator), find) do shown += 1
		if shown == 0 do return
		flags: im.TreeNodeFlags = {.SpanAvailWidth, .DefaultOpen}
		if find != "" do im.SetNextItemOpen(true)
		if !im.TreeNodeEx(fmt.ctprintf("%s###dg%s", title, title), flags) do return
		ui.name(fmt.tprintf("devices %s", title))
		for it in items {
			if find != "" && !strings.contains(strings.to_lower(it.label, context.temp_allocator), find) do continue
			im.TreeNodeEx(fmt.ctprintf("%s  %s###dv%s", it.icon, it.label, it.code), {.Leaf, .NoTreePushOnOpen, .SpanAvailWidth})
			ui.name(fmt.tprintf("device %s", it.label))
			if im.IsItemHovered() do im.SetTooltip("%s", fmt.ctprintf("%s — drag onto a pad, or double-click for the selected pad", it.tip))
			if im.BeginDragDropSource() {
				im.SetDragDropPayload(PADS_DEVICE_PAYLOAD, raw_data(it.code), uint(len(it.code)))
				im.Text("%s", fmt.ctprintf("%s  %s", it.icon, it.label))
				im.EndDragDropSource()
			}
			if im.IsItemHovered() && im.IsMouseDoubleClicked(.Left) do put_device(a, a.selected, it.code)
		}
		im.TreePop()
	}
	if im.TreeNodeEx("Instruments###dginst", {.DefaultOpen, .SpanAvailWidth}) {
		ui.name("devices Instruments")
		group(a, "Basic", {
			{"Synth", ui.ICON_AUDIO_WAVEFORM, "inst synth", "A wavetable synth"},
			{"Sampler", ui.ICON_LAYOUT_GRID, "inst sampler", "Plays the pad's sample"},
			{"Slicer", ui.ICON_SCISSORS, "inst slicer", "The pad's sample in slices, one a key"},
			{"Audio track", ui.ICON_MIC, "inst audio", "Records and plays audio"},
		}, find)
		// The synth's presets, by kind.
		last := ""
		items := make([dynamic]Device_Item, context.temp_allocator)
		flush :: proc(a: ^App, kind: string, items: ^[dynamic]Device_Item, find: string) {
			if len(items) > 0 do group(a, fmt.tprintf("Synth: %s", kind), items[:], find)
			clear(items)
		}
		for p, k in pm.BUILTIN_PRESETS {
			if p.category != last {
				flush(a, last, &items, find)
				last = p.category
			}
			append(&items, Device_Item{p.name, ui.ICON_LIBRARY, fmt.tprintf("preset %d", k), "A synth preset"})
		}
		flush(a, last, &items, find)
		mine := make([dynamic]Device_Item, context.temp_allocator)
		for n in pm.preset_list(preset_folder(a)) do append(&mine, Device_Item{n, ui.ICON_LIBRARY, fmt.tprintf("mine %s", n), "One of your synth presets"})
		if len(mine) > 0 do group(a, "Synth: yours", mine[:], find)
		// Instrument plug-ins.
		insts := make([dynamic]Device_Item, context.temp_allocator)
		for e, k in plugin_instruments(a) do append(&insts, Device_Item{e.name, ui.ICON_PLUG, fmt.tprintf("clapi %d", k), fmt.tprintf("%s %s (CLAP instrument)", e.vendor, e.version)})
		if len(insts) > 0 do group(a, "Plug-ins", insts[:], find)
		im.TreePop()
	}
	if im.TreeNodeEx("Effects###dgfx", {.DefaultOpen, .SpanAvailWidth}) {
		ui.name("devices Effects")
		synth_fx := make([dynamic]Device_Item, context.temp_allocator)
		other := make([dynamic]Device_Item, context.temp_allocator)
		for k in pm.Effect_Kind {
			if k == .None || k == .Plugin || pm.effect_kind_legacy(k) do continue
			it := Device_Item{string(pm.EFFECT_NAMES[k]), ui.ICON_WAND_SPARKLES, fmt.tprintf("fx %d", int(k)), "An insert effect"}
			if _, twin := pm.synth_twin(k); twin do append(&synth_fx, it)
			else do append(&other, it)
		}
		group(a, "Sound", synth_fx[:], find)
		group(a, "Rhythm and pitch", other[:], find)
		im.TreePop()
	}
	if im.TreeNodeEx("Plug-ins###dgclap", {.DefaultOpen, .SpanAvailWidth}) {
		ui.name("devices Plug-ins")
		entries := plugin_effects(a)
		if len(entries) == 0 && len(plugin_instruments(a)) == 0 {
			im.TextDisabled("None found yet")
			if im.SmallButton("Find plug-ins… (Settings)") do a.settings.open, a.settings.page = true, .Plugins
		}
		// By vendor.
		vendors := make([dynamic]string, context.temp_allocator)
		for e in entries {
			seen := false
			for v in vendors do seen ||= v == e.vendor
			if !seen do append(&vendors, e.vendor)
		}
		for v in vendors {
			items := make([dynamic]Device_Item, context.temp_allocator)
			for e, k in entries do if e.vendor == v do append(&items, Device_Item{e.name, ui.ICON_PLUG, fmt.tprintf("clap %d", k), fmt.tprintf("%s %s (CLAP)", e.vendor, e.version)})
			group(a, v if v != "" else "Other", items[:], find)
		}
		im.TreePop()
	}
}

// Puts device `code` (a payload) on pad `index`: one undo step. Returns
// whether it did.
put_device :: proc(a: ^App, index: int, code: string) -> bool {
	m := &a.m
	if index < 0 || index >= pm.PADS do return false
	words := strings.fields(code, context.temp_allocator)
	if len(words) < 2 do return false
	arg := strings.join(words[1:], " ", context.temp_allocator)
	n, _ := strconv.parse_int(arg)
	switch words[0] {
	case "inst":
		switch arg {
		case "synth":   pm.make_synth(m, index)
		case "sampler": pm.make_sampler(m, index)
		case "slicer":  pm.make_slicer(m, index)
		case "audio":   pm.set_pad_kind(m, index, .Audio); app.seal(&m.history)
		case:           return false
		}
	case "preset", "mine":
		app.begin(&m.history, "Load Preset")
		defer app.end(&m.history)
		if m.project.pads[index].kind != .Synth do pm.make_synth(m, index)
		if words[0] == "preset" {
			pm.preset_apply_builtin(m, index, n)
		} else {
			path := strings.concatenate({preset_folder(a), "/", arg, pm.PRESET_EXT}, context.temp_allocator)
			pr, err := pm.preset_read(path)
			if err != .None do return false
			pm.preset_apply(m, index, &pr)
		}
	case "clapi":
		entries := plugin_instruments(a)
		if n < 0 || n >= len(entries) do return false
		e := entries[n]
		pm.make_plugin_pad(m, index, e.path, e.id, e.name)
	case "fx", "clap":
		slot := -1
		for s, k in m.project.pads[index].inserts do if s.kind == .None {
			slot = k
			break
		}
		if slot < 0 {
			ui.toast(&a.ws.toasts, .Error, fmt.tprintf("%s has no empty insert", pm.pad_label(index)))
			return false
		}
		s: pm.Effect_Slot
		if words[0] == "fx" {
			if n <= 0 || n > int(max(pm.Effect_Kind)) do return false
			s = pm.new_effect(pm.Effect_Kind(n))
		} else {
			entries := plugin_effects(a)
			if n < 0 || n >= len(entries) do return false
			e := entries[n]
			s = pm.new_plugin_effect(&m.project, e.path, e.id, e.name)
		}
		pm.set_insert(m, index, slot, s, "Add Effect")
		app.seal(&m.history)
		a.selected = index
		show_device(a, {.Pad, index, slot})
		return true
	case:
		return false
	}
	a.selected = index
	return true
}
