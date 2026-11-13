package pads_model

import "core:fmt"
import "core:strings"

import app "app:core"

// The launcher's lanes: each sequence has one, and a row in it. A lane
// plays one sequence at a time, the lanes together; row k across the
// lanes is a scene. A lane's sequences are its rows 0..n-1, no holes
// (moving one out closes the gap). The 64 sequences are shared among the
// lanes; a lane added starts empty and takes unused ones.

// The most lanes a project has.
MAX_LANES :: 16
// Lanes a new project has (a setting can say otherwise).
DEFAULT_LANES :: 8

// A launcher lane: its name ("" = "Lane N") and colour (0: its sequences').
Launch_Lane :: struct {
	name:  [16]u8,
	color: u32,
}

// Where a sequence is in the launcher.
Seq_Place :: struct {
	lane, row: u8,
}

// The launcher's lanes and where each sequence is (one value: an edit of
// them is one undo step).
Lanes :: struct {
	lanes: [MAX_LANES]Launch_Lane,
	count: int, // 1..MAX_LANES
	place: [SLOTS]Seq_Place,
}

// `count` lanes, the sequences dealt round them in order (sequence k in
// lane k % count, row k / count): a new project's, and (4) an old one's,
// which is how its 4 × 4 banks played.
default_lanes :: proc(count: int) -> (l: Lanes) {
	l.count = clamp(count, 1, MAX_LANES)
	for k in 0 ..< SLOTS do l.place[k] = {u8(k % l.count), u8(k / l.count)}
	return
}

// The lane sequence `slot` plays in.
seq_lane :: proc "contextless" (p: ^Project, slot: int) -> int {
	if slot < 0 || slot >= SLOTS do return 0
	return int(p.lanes.place[slot].lane)
}

// The sequence at row `row` of lane `lane`, or -1.
lane_slot :: proc(p: ^Project, lane, row: int) -> int {
	for x, k in p.lanes.place do if int(x.lane) == lane && int(x.row) == row do return k
	return -1
}

// How many sequences lane `lane` has.
lane_rows :: proc(p: ^Project, lane: int) -> int {
	n := 0
	for x in p.lanes.place do if int(x.lane) == lane do n += 1
	return n
}

// The most rows a lane has.
max_rows :: proc(p: ^Project) -> int {
	n := 0
	for k in 0 ..< p.lanes.count do n = max(n, lane_rows(p, k))
	return n
}

// Launcher lane `lane`'s name.
launch_lane_name :: proc(p: ^Project, lane: int) -> string {
	if lane < 0 || lane >= MAX_LANES do return ""
	n := strings.truncate_to_byte(string(p.lanes.lanes[lane].name[:]), 0)
	return n if n != "" else fmt.tprintf("Lane %d", lane + 1)
}

// Sets the lanes to `l`, undoably as `name`.
set_lanes :: proc(m: ^Model, name: string, l: Lanes) {
	l := l
	compact_rows(&l)
	old := m.project.lanes
	if old == l do return
	app.set_value(&m.history, name, {LANES_KEY, 0}, old, l, proc(ctx: rawptr, k: app.Key, v: Lanes) {
		mm := (^Model)(ctx)
		mm.project.lanes = v
		mm.engine.seq_dirty = true
	})
	app.seal(&m.history)
}

@(private)
LANES_KEY :: app.Id(1 << 41)

// Each lane's rows renumbered 0..n-1 in their order (ties: by slot), and
// a sequence on a lane that is gone on the last one.
@(private)
compact_rows :: proc(l: ^Lanes) {
	l.count = clamp(l.count, 1, MAX_LANES)
	for &x in l.place do if int(x.lane) >= l.count do x = {u8(l.count - 1), 255}
	for lane in 0 ..< l.count {
		order := make([dynamic]int, 0, SLOTS, context.temp_allocator)
		for x, k in l.place do if int(x.lane) == lane do append(&order, k)
		for i in 1 ..< len(order) {
			// (Insertion sort: a few dozen at most.)
			for j := i; j > 0; j -= 1 {
				a, b := l.place[order[j - 1]], l.place[order[j]]
				if a.row < b.row || (a.row == b.row && order[j - 1] < order[j]) do break
				order[j - 1], order[j] = order[j], order[j - 1]
			}
		}
		for k, r in order do l.place[k].row = u8(r)
	}
}

// Moves sequence `slot` to row `row` of lane `lane` (the lane's others at
// and after it move down a row; its old lane's close up). One undo step.
move_sequence :: proc(m: ^Model, slot, lane, row: int) {
	p := &m.project
	if slot < 0 || slot >= SLOTS || lane < 0 || lane >= p.lanes.count do return
	l := p.lanes
	from := l.place[slot]
	if int(from.lane) == lane && int(from.row) == row do return
	// Out of its lane (the rest close up), then into the new one at `row`.
	for &x, k in l.place do if k != slot && x.lane == from.lane && x.row > from.row do x.row -= 1
	to := clamp(row, 0, lane_count_in(&l, lane, slot))
	for &x, k in l.place do if k != slot && int(x.lane) == lane && int(x.row) >= to do x.row += 1
	l.place[slot] = {u8(lane), u8(to)}
	set_lanes(m, "Move Sequence", l)
	// (Playing in its old lane: it goes on there until it is launched again.)
}

// Lane `lane`'s sequences in `l`, `slot` not counted.
@(private)
lane_count_in :: proc(l: ^Lanes, lane, slot: int) -> int {
	n := 0
	for x, k in l.place do if k != slot && int(x.lane) == lane do n += 1
	return n
}

// Adds a lane (named, empty) at the end. False at MAX_LANES.
add_lane :: proc(m: ^Model) -> bool {
	l := m.project.lanes
	if l.count >= MAX_LANES do return false
	l.lanes[l.count] = {}
	l.count += 1
	set_lanes(m, "Add Lane", l)
	return true
}

// Deletes lane `lane`: its sequences go to the end of the lane before it
// (the next one, for the first); the lanes after it move down one. False
// for the last lane left.
delete_lane :: proc(m: ^Model, lane: int) -> bool {
	l := m.project.lanes
	if l.count <= 1 || lane < 0 || lane >= l.count do return false
	into := lane - 1 if lane > 0 else 1
	base := lane_count_in(&l, into, -1)
	n := 0
	for k in 0 ..< SLOTS do if int(l.place[k].lane) == lane {
		l.place[k] = {u8(into), u8(base + int(l.place[k].row))}
		n += 1
	}
	for k in 0 ..< SLOTS do if int(l.place[k].lane) > lane do l.place[k].lane -= 1
	for k in lane ..< MAX_LANES - 1 do l.lanes[k] = l.lanes[k + 1]
	l.lanes[MAX_LANES - 1] = {}
	l.count -= 1
	set_lanes(m, "Delete Lane", l)
	stop_lanes_from(&m.engine, l.count)
	return true
}

// Renames lane `lane` ("" = its default name).
rename_lane :: proc(m: ^Model, lane: int, name: string) {
	l := m.project.lanes
	if lane < 0 || lane >= l.count do return
	l.lanes[lane].name = {}
	copy(l.lanes[lane].name[:len(l.lanes[lane].name) - 1], name)
	set_lanes(m, "Rename Lane", l)
}

// Colours lane `lane` (0: its sequences' own).
color_lane :: proc(m: ^Model, lane: int, color: u32) {
	l := m.project.lanes
	if lane < 0 || lane >= l.count do return
	l.lanes[lane].color = color
	set_lanes(m, "Lane Colour", l)
}

// A sequence for the end of lane `lane`: the first one that has nothing
// (no notes, takes, name or tempo; not the current one, not in the song)
// moved there. Its slot, or -1 when every sequence is used. One undo step.
new_sequence_in :: proc(m: ^Model, lane: int) -> int {
	p := &m.project
	if lane < 0 || lane >= p.lanes.count do return -1
	for k in 0 ..< SLOTS {
		if slot_used(m, k) || k == p.slot do continue
		in_song := false
		for c in p.song.clips[:p.song.count] do if int(c.slot) == k do in_song = true
		if in_song do continue
		move_sequence(m, k, lane, lane_rows(p, lane))
		return k
	}
	return -1
}

// Lanes at and after `from` stop (they are gone).
@(private)
stop_lanes_from :: proc(e: ^Engine, from: int) {
	for k in max(from, 0) ..< MAX_LANES do e.launch.cols[k] = {slot = -1}
	e.seq_dirty = true
}

// The pads each sequence's notes play (as sets).
all_seq_pads :: proc(p: ^Project) -> (out: [SLOTS]bit_set[0 ..< PADS; u128]) {
	for s, k in p.sequences do for n in s.notes do out[k] += {int(n.pad)}
	return
}

// The first other lane with a sequence playing one of the pads sequence
// `slot` plays (both play it at once), or -1. `pads`: `all_seq_pads`.
shared_lane :: proc(p: ^Project, pads: ^[SLOTS]bit_set[0 ..< PADS; u128], slot: int) -> int {
	mine := pads[slot]
	if mine == {} do return -1
	lane := seq_lane(p, slot)
	for k in 0 ..< SLOTS {
		other := seq_lane(p, k)
		if other != lane && other < p.lanes.count && mine & pads[k] != {} do return other
	}
	return -1
}
