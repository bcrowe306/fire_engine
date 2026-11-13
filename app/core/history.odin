package app

import "core:mem"
import "core:strings"

// What a command type does. `apply` and `revert` change the model through
// `ctx` (the app's model, whatever the history was made with); they must be
// exact inverses. `merge` may absorb a following command of the same type
// into this one (consecutive moves of one knob become one undo step):
// return true if it did. `destroy` frees the command's data.
Command_VTable :: struct {
	apply:   proc(data: rawptr, ctx: rawptr),
	revert:  proc(data: rawptr, ctx: rawptr),
	merge:   proc(data: rawptr, next: rawptr) -> bool, // may be nil: never merges
	destroy: proc(data: rawptr, allocator: mem.Allocator), // may be nil: `free(data)`
}

// One undoable step: a command type, its data, and what to call it in the
// Edit menu ("Set Volume").
Command :: struct {
	vtable: ^Command_VTable,
	data:   rawptr,
	name:   string,
}

// A history of commands, for undo and redo. Every change to the model goes
// through `execute`, so every change can be undone. Not thread-safe: use it
// from the UI thread.
History :: struct {
	ctx:       rawptr, // passed to every command
	undo:      [dynamic]Step,
	redo:      [dynamic]Step,
	limit:     int, // undo steps kept; older ones are freed
	saved:     int, // `undo` length at the last `mark_saved`; -1 = unreachable
	group:     ^Step, // open transaction, if any
	depth:     int,   // nested `begin` calls
	sealed:    bool,  // the next command starts a new step even if it could merge
	bus:       ^Bus,  // if set, gets a `History_Changed` after each change
	allocator: mem.Allocator,
}

// A step on the undo stack: one command, or a transaction of several.
Step :: struct {
	name:     string, // allocated
	commands: [dynamic]Command,
}

// Published (if the history has a bus) after anything changes the stacks.
History_Changed :: struct {
	history: ^History,
}

// Prepares a history whose commands act on `ctx`, keeping up to `limit`
// undo steps.
history_init :: proc(h: ^History, ctx: rawptr, limit := 500, bus: ^Bus = nil, allocator := context.allocator) {
	h^ = {ctx = ctx, limit = max(limit, 1), bus = bus, allocator = allocator}
	h.undo = make([dynamic]Step, allocator)
	h.redo = make([dynamic]Step, allocator)
}

// Frees every step.
history_destroy :: proc(h: ^History) {
	for &s in h.undo do step_free(h, &s)
	for &s in h.redo do step_free(h, &s)
	delete(h.undo)
	delete(h.redo)
	if h.group != nil {
		step_free(h, h.group)
		free(h.group, h.allocator)
	}
	h^ = {}
}

// Applies `cmd` and records it, clearing the redo stack. Inside a
// transaction (`begin` … `end`) it joins the transaction; otherwise it may
// merge into the previous step (see `Command_VTable.merge` and `seal`). The
// history owns the command from here on.
execute :: proc(h: ^History, cmd: Command) {
	cmd.vtable.apply(cmd.data, h.ctx)
	for &s in h.redo do step_free(h, &s)
	clear(&h.redo)
	if h.group != nil {
		if !merge_into(h, h.group, cmd, any = true) do append(&h.group.commands, cmd)
		return
	}
	if !h.sealed && len(h.undo) > 0 && len(h.undo[len(h.undo) - 1].commands) == 1 && h.saved != len(h.undo) {
		if merge_into(h, &h.undo[len(h.undo) - 1], cmd) {
			changed(h)
			return
		}
	}
	h.sealed = false
	s := Step{name = strings.clone(cmd.name, h.allocator), commands = make([dynamic]Command, h.allocator)}
	append(&s.commands, cmd)
	push_undo(h, s)
	changed(h)
}

// Starts a transaction: commands executed until the matching `end` become
// one undo step named `name`. Transactions nest (the outermost names the
// step).
begin :: proc(h: ^History, name: string) {
	h.depth += 1
	if h.depth > 1 do return
	h.group = new(Step, h.allocator)
	h.group^ = {name = strings.clone(name, h.allocator), commands = make([dynamic]Command, h.allocator)}
}

// Ends a transaction. An empty transaction leaves no step.
end :: proc(h: ^History) {
	if h.depth == 0 do return
	h.depth -= 1
	if h.depth > 0 do return
	g := h.group
	h.group = nil
	if len(g.commands) == 0 {
		step_free(h, g)
	} else {
		push_undo(h, g^)
		h.sealed = true
		changed(h)
	}
	free(g, h.allocator)
}

// Makes the next command start a new step even if it could merge into the
// previous one: call it when a gesture ends (a knob released).
seal :: proc(h: ^History) {
	h.sealed = true
}

// Undoes the last step. False if there is nothing to undo (or a
// transaction is open).
undo :: proc(h: ^History) -> bool {
	if len(h.undo) == 0 || h.group != nil do return false
	s := pop(&h.undo)
	#reverse for c in s.commands do c.vtable.revert(c.data, h.ctx)
	append(&h.redo, s)
	h.sealed = true
	changed(h)
	return true
}

// Redoes the last undone step. False if there is nothing to redo.
redo :: proc(h: ^History) -> bool {
	if len(h.redo) == 0 || h.group != nil do return false
	s := pop(&h.redo)
	for c in s.commands do c.vtable.apply(c.data, h.ctx)
	append(&h.undo, s)
	h.sealed = true
	changed(h)
	return true
}

// The name of the step `undo` would undo ("" if none).
undo_name :: proc(h: ^History) -> string {
	return h.undo[len(h.undo) - 1].name if len(h.undo) > 0 else ""
}

// The name of the step `redo` would redo ("" if none).
redo_name :: proc(h: ^History) -> string {
	return h.redo[len(h.redo) - 1].name if len(h.redo) > 0 else ""
}

// Tells the history's listeners it changed (after its fields were set
// from outside: a document loaded with unsaved changes, say).
changed_history :: proc(h: ^History) {
	changed(h)
}

// Records that the model as it is now has been saved.
mark_saved :: proc(h: ^History) {
	h.saved = len(h.undo)
	h.sealed = true
	changed(h)
}

// Whether the model differs from the last `mark_saved` (true before any).
is_dirty :: proc(h: ^History) -> bool {
	return h.saved != len(h.undo) || h.group != nil
}

// Forgets every step (after loading a new document, say), leaving the
// model clean.
history_clear :: proc(h: ^History) {
	for &s in h.undo do step_free(h, &s)
	for &s in h.redo do step_free(h, &s)
	clear(&h.undo)
	clear(&h.redo)
	h.saved = 0
	h.sealed = true
	changed(h)
}

// Forgets the steps undone (nothing can be redone), keeping those that
// can be undone.
history_clear_redo :: proc(h: ^History) {
	for &s in h.redo do step_free(h, &s)
	clear(&h.redo)
	changed(h)
}

@(private)
merge_into :: proc(h: ^History, s: ^Step, cmd: Command, any := false) -> bool {
	if len(s.commands) == 0 do return false
	// The last command; or, within a transaction (`any`), the latest of the
	// same kind that takes it (a drag of several things at once: each
	// thing's commands merge, however they interleave).
	lo := max(len(s.commands) - MERGE_LOOKBACK, 0) if any else len(s.commands) - 1
	for k := len(s.commands) - 1; k >= lo; k -= 1 {
		c := s.commands[k]
		if c.vtable != cmd.vtable || c.vtable.merge == nil do continue
		if !c.vtable.merge(c.data, cmd.data) do continue
		command_free(h, cmd)
		return true
	}
	return false
}

// How far back in a transaction a command looks for one to merge into.
@(private)
MERGE_LOOKBACK :: 256

@(private)
push_undo :: proc(h: ^History, s: Step) {
	append(&h.undo, s)
	for len(h.undo) > h.limit {
		old := h.undo[0]
		step_free(h, &old)
		ordered_remove(&h.undo, 0)
		h.saved -= 1 // the saved state may scroll off: then it is unreachable
		if h.saved < 0 do h.saved = -1
	}
}

@(private)
step_free :: proc(h: ^History, s: ^Step) {
	for c in s.commands do command_free(h, c)
	delete(s.commands)
	delete(s.name, h.allocator)
}

@(private)
command_free :: proc(h: ^History, c: Command) {
	if c.vtable.destroy != nil {
		c.vtable.destroy(c.data, h.allocator)
	} else {
		free(c.data, h.allocator)
	}
}

@(private)
changed :: proc(h: ^History) {
	if h.bus != nil do publish(h.bus, History_Changed{h})
}

// --- a command for the common case ---------------------------------------------------------

// Sets one value of type T on the model, by key, undoably. `set` is called
// with the new value by `apply` and the old by `revert`; consecutive sets of
// the same key with the same `set` merge into one step (a dragged knob).
// Key a value with something stable (an entity `Id` and a field number),
// not a pointer: undo may outlive the memory a pointer names.
Set :: struct($T: typeid) {
	key:  Key,
	old:  T,
	new:  T,
	set:  proc(ctx: rawptr, key: Key, value: T),
}

// What a `Set` command addresses: an entity and which of its values.
Key :: struct {
	id:    Id,
	field: int,
}

// Executes a `Set` of `key` from `old` to `new` via `set`, named `name`.
set_value :: proc(h: ^History, name: string, key: Key, old, new: $T, set: proc(ctx: rawptr, key: Key, value: T)) {
	data := new_clone(Set(T){key = key, old = old, new = new, set = set}, h.allocator)
	execute(h, {vtable = set_vtable(T), data = data, name = name})
}

// As `set_value`, for a large `T` (hundreds of kilobytes): `old` and `new_`
// are copied straight into the command on the heap, with no copy of them
// on the stack (a thread's stack is 1 MB on Windows).
set_value_big :: proc(h: ^History, name: string, key: Key, old, new_: ^$T, set: proc(ctx: rawptr, key: Key, value: T)) {
	data := new(Set(T), h.allocator)
	data.key, data.set = key, set
	data.old = old^
	data.new = new_^
	execute(h, {vtable = set_vtable(T), data = data, name = name})
}

// The vtable of `Set(T)` commands (one per T).
set_vtable :: proc($T: typeid) -> ^Command_VTable {
	@(static) vt := Command_VTable {
		apply = proc(data: rawptr, ctx: rawptr) {
			c := (^Set(T))(data)
			c.set(ctx, c.key, c.new)
		},
		revert = proc(data: rawptr, ctx: rawptr) {
			c := (^Set(T))(data)
			c.set(ctx, c.key, c.old)
		},
		merge = proc(data: rawptr, next: rawptr) -> bool {
			a, b := (^Set(T))(data), (^Set(T))(next)
			if a.key != b.key || a.set != b.set do return false
			a.new = b.new // keep the first old value
			return true
		},
	}
	return &vt
}
