package pads_api

import app "app:core"

// The undo history now: steps that can be undone and redone, and whether
// the project has changed since it was saved.
History_State :: struct {
	undo_steps: i64, // steps that can be undone
	redo_steps: i64, // steps undone that can be redone
	dirty:      bool, // changed since it was saved
	grouping:   bool, // a group is open (history_group_begin)
}

// The history now.
history_state :: proc(api: ^Api) -> (History_State, Result) {
	h := &api.core.m.history
	return {undo_steps = i64(len(h.undo)), redo_steps = i64(len(h.redo)), dirty = app.is_dirty(h), grouping = h.group != nil}, .Ok
}

// Undoes the last step. Not_Found with nothing to undo; Busy while a
// group is open.
history_undo :: proc(api: ^Api) -> Result {
	h := &api.core.m.history
	if h.group != nil do return fail(api, .Busy, "a group of edits is open")
	if !app.undo(h) do return fail(api, .Not_Found, "nothing to undo")
	return .Ok
}

// Redoes the last step undone. Not_Found with nothing to redo; Busy while
// a group is open.
history_redo :: proc(api: ^Api) -> Result {
	h := &api.core.m.history
	if h.group != nil do return fail(api, .Busy, "a group of edits is open")
	if !app.redo(h) do return fail(api, .Not_Found, "nothing to redo")
	return .Ok
}

// What undo would undo ("Set Tempo"), or "" (temporary).
history_undo_name :: proc(api: ^Api) -> (string, Result) {
	return app.undo_name(&api.core.m.history), .Ok
}

// What redo would redo, or "" (temporary).
history_redo_name :: proc(api: ^Api) -> (string, Result) {
	return app.redo_name(&api.core.m.history), .Ok
}

// Step `step`'s name, counting along the history: 0 .. undo_steps-1 are
// the steps done (the oldest first), then the steps undone (the next to
// redo first). Not_Found past the end. Temporary.
history_step_name :: proc(api: ^Api, step: i64) -> (string, Result) {
	h := &api.core.m.history
	n := i64(len(h.undo))
	switch {
	case step >= 0 && step < n:                  return h.undo[step].name, .Ok
	case step >= n && step < n + i64(len(h.redo)): return h.redo[len(h.redo) - 1 - int(step - n)].name, .Ok
	}
	return "", fail(api, .Not_Found, "no such step")
}

// Undoes or redoes until `done` steps are done (0: all undone; undo_steps
// + redo_steps: all redone). Invalid_Argument out of that range; Busy
// while a group is open.
history_go_to :: proc(api: ^Api, done: i64) -> Result {
	h := &api.core.m.history
	if h.group != nil do return fail(api, .Busy, "a group of edits is open")
	if done < 0 || done > i64(len(h.undo) + len(h.redo)) do return fail(api, .Invalid_Argument, "no such step")
	for i64(len(h.undo)) > done do app.undo(h)
	for i64(len(h.undo)) < done do app.redo(h)
	return .Ok
}

// Starts a group: the edits until `history_group_end` become one undo
// step named `name`. Groups nest (the outermost names the step).
history_group_begin :: proc(api: ^Api, name: string) -> Result {
	if name == "" do return fail(api, .Invalid_Argument, "a group needs a name")
	app.begin(&api.core.m.history, name)
	return .Ok
}

// Ends the group `history_group_begin` started (an empty group leaves no
// step). Not_Found when none is open.
history_group_end :: proc(api: ^Api) -> Result {
	h := &api.core.m.history
	if h.depth == 0 do return fail(api, .Not_Found, "no group is open")
	app.end(h)
	return .Ok
}

// Starts a gesture (a knob or a fader held): the edits of one value until
// `history_gesture_end` merge into one undo step, as a drag's do. Without
// one, each edit is a step of its own.
history_gesture_begin :: proc(api: ^Api) -> Result {
	api.gesture = true
	return .Ok
}

// Ends the gesture: the next edit is a new step.
history_gesture_end :: proc(api: ^Api) -> Result {
	api.gesture = false
	app.seal(&api.core.m.history)
	return .Ok
}

// After an edit: the next one starts a new step, unless a gesture is open.
@(private)
edited :: proc(api: ^Api) {
	if !api.gesture do app.seal(&api.core.m.history)
}
