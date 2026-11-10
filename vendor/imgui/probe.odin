package imgui

// Fire Engine: bindings for the item probe (vendor/imgui/probe.cpp, built
// into the same library): ImGui's test-engine hooks, recording every item
// of a frame so a test harness can find widgets by label. Not part of
// odin-imgui.

// An item the probe saw: its id, status flags, the part of it that shows
// (screen points), its window and its label as given (with any "##").
Probe_Item :: struct {
	id:     ID,
	status: u32,
	x0, y0, x1, y1: f32,
	window: [64]u8,
	label:  [128]u8,
}

@(default_calling_convention = "c")
foreign imguilib {
	// Turns recording on or off (off: the hooks cost nothing).
	@(link_name = "fire_probe_enable")
	probe_enable :: proc(on: bool) ---
	// Once a frame, before NewFrame: the frame recorded becomes the one read.
	@(link_name = "fire_probe_frame")
	probe_frame :: proc() ---
	// How many items the last frame had.
	@(link_name = "fire_probe_count")
	probe_count :: proc() -> i32 ---
	// Item `i` of the last frame.
	@(link_name = "fire_probe_get")
	probe_get :: proc(i: i32, out: ^Probe_Item) -> bool ---
	// Labels item `id` before it is drawn (a combo gives ImGui no label).
	@(link_name = "fire_probe_label_id")
	probe_label_id :: proc(id: ID, label: cstring) ---
	// Gives the last item submitted `label` (for items drawn with "##" ids).
	@(link_name = "fire_probe_name_last")
	probe_name_last :: proc(label: cstring) ---
}
