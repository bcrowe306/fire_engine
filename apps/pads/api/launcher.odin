package pads_api

import "core:strings"

import pm "../model"

// Launcher lanes there may be.
MAX_LANES :: pm.MAX_LANES

// When a sequence launched while playing takes over.
Launch_Quantize :: enum i32 {
	End,  // at the end of the one playing
	Bar,  // at the next bar
	Beat, // at the next beat
	Now,  // at once
}

// The launcher now.
Launcher_State :: struct {
	lanes:     i64, // lanes 0..lanes-1
	quantize:  Launch_Quantize,
	hold:      bool, // sequence pads play while held (else a press launches)
	continue_: bool, // a launch carries on where the playhead is in its lane
	recording: bool, // launches are recorded into the song
}

// Lane `lane` now.
Lane_State :: struct {
	rows:    i64,  // its sequences (rows 0..rows-1)
	color:   i64,  // 0xRRGGBB (0: its default)
	playing: i64,  // the sequence it plays (-1: none)
	queued:  i64,  // the sequence about to take over (-1: none)
	beats_to_switch: f64, // until the queued one takes over
}

// Where a sequence is in the launcher.
Place :: struct {
	lane: i64,
	row:  i64,
}

// The launcher now.
launcher_state :: proc(api: ^Api) -> (Launcher_State, Result) {
	m := &api.core.m
	p := &m.project
	return {lanes = i64(p.lanes.count), quantize = Launch_Quantize(p.switch_at), hold = p.launch_hold, continue_ = p.launch_continue, recording = pm.launch_recording(m)}, .Ok
}

// Lane `lane` now.
launcher_lane :: proc(api: ^Api, lane: i64) -> (Lane_State, Result) {
	if r := lane_ok(api, lane); r != .Ok do return {}, r
	p := &api.core.m.project
	cs, _, next, in_beats, queued := pm.column_state(&api.core.m.engine, int(lane))
	return {rows = i64(pm.lane_rows(p, int(lane))), color = i64(p.lanes.lanes[lane].color), playing = i64(cs), queued = i64(next) if queued else -1, beats_to_switch = in_beats if queued else 0}, .Ok
}

// Lane `lane`'s name (its own, else its letter's). Temporary.
launcher_lane_name :: proc(api: ^Api, lane: i64) -> (string, Result) {
	if r := lane_ok(api, lane); r != .Ok do return "", r
	return strings.clone(pm.launch_lane_name(&api.core.m.project, int(lane)), context.temp_allocator), .Ok
}

// Where sequence `slot` is.
launcher_place :: proc(api: ^Api, slot: i64) -> (Place, Result) {
	if r := slot_ok(api, slot); r != .Ok do return {}, r
	x := api.core.m.project.lanes.place[slot]
	return {lane = i64(x.lane), row = i64(x.row)}, .Ok
}

// The sequence at `lane`, `row` (-1: none).
launcher_slot_at :: proc(api: ^Api, lane: i64, row: i64) -> (i64, Result) {
	if r := lane_ok(api, lane); r != .Ok do return -1, r
	return i64(pm.lane_slot(&api.core.m.project, int(lane), int(row))), .Ok
}

// Launches sequence `slot` in its lane (`alone`: the other lanes stop),
// when the launch quantize says; stopped, it starts playing.
launcher_launch :: proc(api: ^Api, slot: i64, alone := false) -> Result {
	if r := slot_ok(api, slot); r != .Ok do return r
	pm.launch_slot(&api.core.m, int(slot), alone)
	return .Ok
}

// Launches row `row` of every lane (a scene).
launcher_launch_row :: proc(api: ^Api, row: i64) -> Result {
	if row < 0 || row >= i64(pm.max_rows(&api.core.m.project)) do return fail(api, .Not_Found, "no such row")
	pm.launch_scene(&api.core.m, int(row))
	return .Ok
}

// Stops lane `lane` (when the launch quantize says).
launcher_stop_lane :: proc(api: ^Api, lane: i64) -> Result {
	if r := lane_ok(api, lane); r != .Ok do return r
	pm.stop_column(&api.core.m.engine, int(lane))
	return .Ok
}

// Stops every lane.
launcher_stop_all :: proc(api: ^Api) -> Result {
	pm.stop_all_columns(&api.core.m.engine)
	return .Ok
}

// When a sequence launched while playing takes over (saved with the project).
launcher_set_quantize :: proc(api: ^Api, q: Launch_Quantize) -> Result {
	if q < min(Launch_Quantize) || q > max(Launch_Quantize) do return fail(api, .Invalid_Argument, "no such launch quantize")
	api.core.m.project.switch_at = pm.Switch_At(q)
	return .Ok
}

// Sequence pads play while held (`on`), or launch on a press. Undoably.
launcher_set_hold :: proc(api: ^Api, on: bool) -> Result {
	pm.set_launch_hold(&api.core.m, on)
	edited(api)
	return .Ok
}

// A launch carries on where the playhead is in its lane (`on`), or starts
// its sequence from the top. Undoably.
launcher_set_continue :: proc(api: ^Api, on: bool) -> Result {
	pm.set_launch_continue(&api.core.m, on)
	edited(api)
	return .Ok
}

// Records what is launched into the song (Record to Song), or stops:
// stopped while playing, the take so far goes into the song.
launcher_set_recording :: proc(api: ^Api, on: bool) -> Result {
	pm.set_launch_record(&api.core.m, on)
	return .Ok
}

// Adds a lane (after the others): its number. Busy at 16.
launcher_add_lane :: proc(api: ^Api) -> (i64, Result) {
	if !pm.add_lane(&api.core.m) do return -1, fail(api, .Busy, "there are 16 lanes already")
	edited(api)
	return i64(api.core.m.project.lanes.count - 1), .Ok
}

// Deletes lane `lane` (its sequences go to the others). Busy for the last.
launcher_delete_lane :: proc(api: ^Api, lane: i64) -> Result {
	if r := lane_ok(api, lane); r != .Ok do return r
	if !pm.delete_lane(&api.core.m, int(lane)) do return fail(api, .Busy, "a launcher keeps one lane at least")
	edited(api)
	return .Ok
}

// Names lane `lane` (up to 15 bytes; "": its letter again), undoably.
launcher_rename_lane :: proc(api: ^Api, lane: i64, name: string) -> Result {
	if r := lane_ok(api, lane); r != .Ok do return r
	if len(strings.trim_space(name)) > 15 do return fail(api, .Invalid_Argument, "a lane's name is up to 15 bytes")
	pm.rename_lane(&api.core.m, int(lane), name)
	edited(api)
	return .Ok
}

// Colours lane `lane` (0xRRGGBB; 0: its default), undoably.
launcher_color_lane :: proc(api: ^Api, lane: i64, color: i64) -> Result {
	if r := lane_ok(api, lane); r != .Ok do return r
	if color < 0 || color > 0xffffff do return fail(api, .Invalid_Argument, "a colour is 0xRRGGBB")
	pm.color_lane(&api.core.m, int(lane), u32(color))
	edited(api)
	return .Ok
}

// Moves sequence `slot` to `lane`, `row` (the rows close up behind it),
// undoably.
launcher_move_sequence :: proc(api: ^Api, slot: i64, lane: i64, row: i64) -> Result {
	if r := slot_ok(api, slot); r != .Ok do return r
	if r := lane_ok(api, lane); r != .Ok do return r
	if row < 0 do return fail(api, .Invalid_Argument, "a row is 0 or more")
	pm.move_sequence(&api.core.m, int(slot), int(lane), int(row))
	edited(api)
	return .Ok
}

// A new, empty sequence at the end of lane `lane`: its slot. Busy when
// every slot is used.
launcher_new_sequence :: proc(api: ^Api, lane: i64) -> (i64, Result) {
	if r := lane_ok(api, lane); r != .Ok do return -1, r
	n := pm.new_sequence_in(&api.core.m, int(lane))
	if n < 0 do return -1, fail(api, .Busy, "every slot is used")
	edited(api)
	return i64(n), .Ok
}

@(private)
lane_ok :: proc(api: ^Api, lane: i64) -> Result {
	if lane < 0 || lane >= i64(api.core.m.project.lanes.count) do return fail(api, .Not_Found, "no such lane")
	return .Ok
}
