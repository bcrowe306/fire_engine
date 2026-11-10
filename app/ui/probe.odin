package ui

import "core:strconv"
import "core:strings"

import im "deps:imgui"

// An item of the last frame, as a test sees it: its label as shown (up to
// "##"), its window, and its rectangle (the part that shows), in points.
Probe_Item :: struct {
	label:  string, // as shown
	raw:    string, // as given, "##" and all
	window: string,
	min:    [2]f32,
	max:    [2]f32,
	status: u32,
}

// Whether the probe records items (`probe_on`; off costs nothing).
@(private) probe_enabled: bool

// Starts or stops recording the items each frame draws.
probe_on :: proc(on: bool) {
	probe_enabled = on
	im.probe_enable(on)
}

// Gives the item just drawn the name `label`, for a test to find it by
// (custom widgets drawn as an InvisibleButton with a "##" id). Nothing
// when the probe is off.
name :: proc(label: string) {
	if !probe_enabled do return
	im.probe_name_last(strings.clone_to_cstring(label, context.temp_allocator))
}

// A combo box (ImGui's BeginCombo) a test can find by its label ("##arp_mode").
combo :: proc(label: cstring, preview: cstring, flags: im.ComboFlags = {}) -> bool {
	if probe_enabled do im.probe_label_id(im.GetID(label), label)
	return im.BeginCombo(label, preview, flags)
}

// A combo of strings (ImGui's ComboChar) a test can find by its label.
combo_char :: proc(label: cstring, current: ^i32, items: [^]cstring, count: i32) -> bool {
	if probe_enabled do im.probe_label_id(im.GetID(label), label)
	return im.ComboChar(label, current, items, count)
}

// The items of the last frame (temporary allocator), top-most last.
probe_items :: proc() -> []Probe_Item {
	n := int(im.probe_count())
	out := make([dynamic]Probe_Item, 0, n, context.temp_allocator)
	for i in 0 ..< n {
		it: im.Probe_Item
		if !im.probe_get(i32(i), &it) do continue
		raw := strings.clone(string(cstring(&it.label[0])), context.temp_allocator)
		if raw == "" do continue
		append(&out, Probe_Item{
			label  = shown(raw),
			raw    = raw,
			window = strings.clone(string(cstring(&it.window[0])), context.temp_allocator),
			min    = {it.x0, it.y0},
			max    = {it.x1, it.y1},
			status = it.status,
		})
	}
	return out[:]
}

// A label up to "##" (or "###"), trimmed.
@(private)
shown :: proc(raw: string) -> string {
	s := raw
	if i := strings.index(s, "##"); i >= 0 do s = s[:i]
	return strings.trim_space(s)
}

// The item a test means by `query`, in `window` (a panel's id, or ""
// for any): "Label", or "Label#N" for the Nth match (from 1). Matches the
// label as shown, then as given; then a shown label that ends with the
// query (icons go first: "  Save" matches "Save"). False if none.
probe_find :: proc(query: string, window := "") -> (Probe_Item, bool) {
	q := query
	nth := 1
	if i := strings.last_index_byte(q, '#'); i > 0 && i < len(q) - 1 && q[i - 1] != '#' {
		if n, ok := strconv.parse_int(q[i + 1:]); ok do nth, q = n, q[:i]
	}
	items := probe_items()
	for pass in 0 ..< 3 {
		seen := 0
		for it in items {
			// A window matches its own name and its children's ("browser/##list_…").
			if window != "" && !strings.has_prefix(strings.to_lower(it.window, context.temp_allocator), strings.to_lower(window, context.temp_allocator)) do continue
			match := false
			switch pass {
			case 0: match = it.label == q
			case 1: match = it.raw == q
			case 2: match = strings.has_suffix(it.label, q) && len(q) >= 2
			}
			if !match do continue
			seen += 1
			if seen == nth do return it, true
		}
	}
	return {}, false
}
