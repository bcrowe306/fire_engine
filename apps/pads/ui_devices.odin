package pads

import "core:fmt"
import "core:strconv"
import "core:strings"

import "app:ui"
import pa "api"
import pm "model"
import im "deps:imgui"

// The Library's devices: the instruments, effects and plug-ins there
// are, in sections. Drag one onto a pad: an instrument
// becomes the pad's (a synth preset loads on a synth), an effect goes in
// its first empty insert. Double-click one for the selected pad.

// The drag-and-drop payload a device carries: what it is, as text
// ("inst synth", "preset 3", "fx 9", "clap 2" an effect plug-in, "clapi 0"
// an instrument plug-in).
PADS_DEVICE_PAYLOAD :: "PADS_DEVICE"


// What a device payload names.
@(private = "file")
Device_Item :: struct {
	label: string,
	icon:  string,
	code:  string, // the payload
	tip:   string,
}

// The Library's device sections: Instruments, Effects and Plug-ins, each
// device shown only if its name has `find` in it (lower case; "" all).
// A device in the panel: drag it onto a pad, or double-click it for the
// selected pad.
@(private)
device_leaf :: proc(a: ^App, it: Device_Item) {
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

draw_device_sections :: proc(a: ^App, find: string) {
	group :: proc(a: ^App, title: string, items: []Device_Item, find: string, open := true, under := "") {
		shown := 0
		for it in items do if find == "" || strings.contains(strings.to_lower(it.label, context.temp_allocator), find) do shown += 1
		if shown == 0 do return
		flags: im.TreeNodeFlags = {.SpanAvailWidth, .DefaultOpen} if open else {.SpanAvailWidth}
		if find != "" do im.SetNextItemOpen(true)
		is_open := im.TreeNodeEx(fmt.ctprintf("%s###dg%s%s", title, under, title), flags) // (`under`: a branch's own, as the synth's Basic is not the instruments')
		ui.name(fmt.tprintf("devices %s %s", under, title) if under != "" else fmt.tprintf("devices %s", title)) // (named folded too)
		if !is_open do return
		for it in items {
			if find != "" && !strings.contains(strings.to_lower(it.label, context.temp_allocator), find) do continue
			device_leaf(a, it)
		}
		im.TreePop()
	}
	if library_section("Instruments") {
		group(a, "Basic", {
			{"Sampler", ui.ICON_LAYOUT_GRID, "inst sampler", "Plays the pad's sample"},
			{"Slicer", ui.ICON_SCISSORS, "inst slicer", "The pad's sample in slices, one a key"},
			{"Audio track", ui.ICON_MIC, "inst audio", "Records and plays audio"},
		}, find)
		// The synth: one branch, a plain synth first, then its presets by
		// kind (each folded; a search opens what it finds), yours last.
		plain := []Device_Item{{"Synth", ui.ICON_AUDIO_WAVEFORM, "inst synth", "A wavetable synth (a plain patch)"}}
		kinds := make([dynamic]string, context.temp_allocator)
		by_kind := make([dynamic][dynamic]Device_Item, context.temp_allocator)
		for p, k in pm.BUILTIN_PRESETS {
			if len(kinds) == 0 || kinds[len(kinds) - 1] != p.category {
				append(&kinds, p.category)
				append(&by_kind, make([dynamic]Device_Item, context.temp_allocator))
			}
			append(&by_kind[len(by_kind) - 1], Device_Item{p.name, ui.ICON_LIBRARY, fmt.tprintf("preset %d", k), fmt.tprintf("A synth preset (%s)", p.category)})
		}
		mine := make([dynamic]Device_Item, context.temp_allocator)
		for n in pm.preset_list(preset_folder(a)) do append(&mine, Device_Item{n, ui.ICON_LIBRARY, fmt.tprintf("mine %s", n), "One of your synth presets"})
		matches :: proc(items: []Device_Item, find: string) -> bool {
			for it in items do if find == "" || strings.contains(strings.to_lower(it.label, context.temp_allocator), find) do return true
			return false
		}
		any := matches(plain, find) || matches(mine[:], find)
		for k in by_kind do any = any || matches(k[:], find)
		if any {
			if find != "" do im.SetNextItemOpen(true)
			if im.TreeNodeEx("Synth###dgSynth", {.SpanAvailWidth, .DefaultOpen}) {
				ui.name("devices Synth")
				for it in plain do if matches({it}, find) do device_leaf(a, it)
				for kind, k in kinds do group(a, kind, by_kind[k][:], find, open = false, under = "Synth")
				if len(mine) > 0 do group(a, "Yours", mine[:], find, open = false, under = "Synth")
				im.TreePop()
			}
		}
		// Instrument plug-ins.
		insts := make([dynamic]Device_Item, context.temp_allocator)
		for e, k in plugin_instruments(a) do append(&insts, Device_Item{e.name, ui.ICON_PLUG, fmt.tprintf("clapi %d", k), fmt.tprintf("%s %s (CLAP instrument)", e.vendor, e.version)})
		if len(insts) > 0 do group(a, "Plug-ins", insts[:], find)
	}
	if library_section("Effects") {
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
	}
	if library_section("Plug-ins") {
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
		case "synth":   pa.pad_set_kind(&a.api, i64(index), .Synth)
		case "sampler": pa.pad_set_kind(&a.api, i64(index), .Sampler)
		case "slicer":  pa.pad_set_kind(&a.api, i64(index), .Slicer)
		case "audio":   pa.pad_set_kind(&a.api, i64(index), .Audio)
		case:           return false
		}
	case "preset", "mine":
		pa.history_group_begin(&a.api, "Load Preset")
		defer pa.history_group_end(&a.api)
		if m.project.pads[index].kind != .Synth do pa.pad_set_kind(&a.api, i64(index), .Synth)
		if words[0] == "preset" {
			if pa.device_load_preset(&a.api, i64(index), i64(n)) != .Ok do return false
		} else {
			path := strings.concatenate({preset_folder(a), "/", arg, pm.PRESET_EXT}, context.temp_allocator)
			if pa.device_load_preset_file(&a.api, i64(index), path) != .Ok do return false
		}
	case "clapi":
		entries := plugin_instruments(a)
		if n < 0 || n >= len(entries) do return false
		e := entries[n]
		pa.device_load_plugin(&a.api, i64(index), e.path, e.id, e.name)
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
		ref := pa.Slot_Ref{place = .Insert, index = i64(index), slot = i64(slot)}
		if words[0] == "fx" {
			if n <= 0 || n > int(max(pm.Effect_Kind)) do return false
			if pa.effect_set(&a.api, ref, i64(n)) != .Ok do return false
		} else {
			entries := plugin_effects(a)
			if n < 0 || n >= len(entries) do return false
			e := entries[n]
			if pa.effect_set_plugin(&a.api, ref, e.path, e.id, e.name) != .Ok do return false
		}
		a.selected = index
		show_device(a, {.Pad, index, slot})
		return true
	case:
		return false
	}
	a.selected = index
	return true
}
