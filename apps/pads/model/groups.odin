package pads_model

import "core:fmt"

import app "app:core"

// Track groups are buses: grouping pads makes a bus (named for the group,
// marked a group) and sends them to it; the mixer shows a group's pads
// beside its fold tab, hidden while it is folded. Ungrouping sends them
// where the group went, and the bus goes.

// Groups pads `pads` under a new group bus named `name` ("" : "Group N"):
// one undo step. Returns the bus (1..BUSES), or 0 when there is no room.
group_pads :: proc(m: ^Model, pads: []int, name := "") -> int {
	p := &m.project
	if len(pads) == 0 || p.bus_count >= BUSES do return 0
	app.begin(&m.history, "Group Pads")
	defer app.end(&m.history)
	n := 1
	for b in p.buses[:p.bus_count] do if b.group do n += 1
	b := add_bus(m)
	if b == 0 do return 0
	nb := p.buses[b - 1]
	nb.group = true
	nb.name = {}
	copy(nb.name[:len(nb.name) - 1], name if name != "" else fmt.tprintf("Group %d", n))
	// It goes where the first pad went (a group inside a bus stays there).
	first := int(p.pads[pads[0]].bus)
	if first >= 1 && bus_dest_ok(p, b, first) do nb.dest = u8(first)
	set_bus(m, b - 1, 6, "Group Pads", nb)
	for i in pads do if i >= 0 && i < PADS do set_pad_bus(m, i, b)
	return b
}

// Ungroups group bus `b` (1..BUSES): its pads go where it went, and the
// bus goes. One undo step.
ungroup :: proc(m: ^Model, b: int) {
	p := &m.project
	if b < 1 || b > p.bus_count || !p.buses[b - 1].group do return
	app.begin(&m.history, "Ungroup")
	defer app.end(&m.history)
	dest := int(p.buses[b - 1].dest)
	for i in 0 ..< PADS do if int(p.pads[i].bus) == b do set_pad_bus(m, i, dest)
	delete_bus(m, b)
}

// Folds (or unfolds) group bus `b` (1..BUSES) in the mixer. Not undone (a
// view), but saved.
set_group_folded :: proc(m: ^Model, b: int, folded: bool) {
	p := &m.project
	if b < 1 || b > p.bus_count do return
	p.buses[b - 1].folded = folded
}

// The pads in group bus `b` (1..BUSES), in order. Temporary allocator.
group_members :: proc(p: ^Project, b: int) -> []int {
	out := make([dynamic]int, context.temp_allocator)
	for i in 0 ..< PADS do if int(p.pads[i].bus) == b && pad_used(p, i) do append(&out, i)
	return out[:]
}
