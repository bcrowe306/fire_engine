package record

import "base:intrinsics"
import "core:mem"

import "fire:clip"
import "fire:core"
import "fire:rt"
import tb "fire:timebase"

// What happens when the user lets go of a control that was being written.
Write_Mode :: enum u8 {
	Touch, // writing stops on release
	Latch, // writing goes on with the last value until the take ends (a stop, a disarm, a punch-out, a loop wrap)
}

// Settings for `automation_recorder_create`.
Automation_Recorder_Settings :: struct {
	timeline:   core.Timeline_Id, // positions are taken from it, and it records while it plays
	mode:       Write_Mode,
	max_params: int, // parameters written at once; 0 = 64
	max_events: int, // changes held for the control thread; 0 = 8192 (more are dropped and counted)
	glide_ms:   f64, // a move is written as the old value held, then this glide to the new one (as the node's smoothing heard it); 0 = 10 ms, negative = jumps
}

// A range of one parameter's curve as the user drew it. Merge it into a
// lane with `clip.automation_merge`; free `points` with `delete`.
Automation_Take :: struct {
	param:  core.Param_Id,
	run:    int, // counts recordings: a new run starts at each start, punch-in or locate
	pass:   int, // loop passes within the run, from 0
	start:  tb.Beats, // timeline positions written over
	end:    tb.Beats,
	points: []clip.Automation_Point, // linear points at timeline positions, from `start` to `end`: each value held until the next move, then a glide to it
}

// Moves parameters for the user and records the moves. The app sends a
// control's values through it instead of `graph.set_param`; it passes them
// to the node it is event-connected to, at the start of its next block,
// and while armed and playing records them into takes. From
// `automation_recorder_create`; the node owns it and frees it when
// destroyed. Procs not marked [rt] are for the control thread, which must
// call `automation_recorder_poll` regularly. Fields are internal.
Automation_Recorder :: struct {
	settings:  Automation_Recorder_Settings,
	allocator: mem.Allocator,
	commands:  rt.Spsc_Queue(Auto_Command), // control → audio
	events:    rt.Spsc_Queue(Auto_Message), // audio → control
	dropped:   u64, // atomic
	// Audio side.
	gate:      Gate,
	glide:     f64, // frames
	params:    []Written, // first `n_params` used
	n_params:  int,
	moved:     bool, // commands arrived this call
	// Control side.
	run, pass: int,
	open:      [dynamic]Open_Range,
	done:      [dynamic]Automation_Take,
}

@(private)
Auto_Command :: struct {
	kind:  enum u8 {Arm, Disarm, Punch, No_Punch, Latency, Touch, Set, Release},
	param: core.Param_Id,
	value: f64,
	a, b:  tb.Beats,
}

@(private)
Auto_Message :: struct {
	kind:  enum u8 {Begin, Touch, Point, Release, End},
	param: core.Param_Id,
	run:   i32,
	pass:  i32,
	pos:   tb.Beats,
	value: f64,
	glide: tb.Beats, // for a Point
}

// A parameter the user is writing (audio side).
@(private)
Written :: struct {
	param:    core.Param_Id,
	value:    f64,
	held:     bool, // the user holds the control
	writing:  bool, // recorded while the gate is open
	changed:  bool, // this call: a new value
	touched:  bool, // this call: a touch
	released: bool, // this call: a release that stops writing
}

@(private)
Open_Range :: struct {
	param:  core.Param_Id,
	start:  tb.Beats,
	value:  f64,
	points: [dynamic]clip.Automation_Point,
}

@(private)
automation_recorder_vtable := core.Node_VTable {
	prepare = proc(self: rawptr, cfg: core.Prepare_Config, allocator: mem.Allocator) -> core.Error {
		r := (^Automation_Recorder)(self)
		ms := r.settings.glide_ms if r.settings.glide_ms != 0 else 10
		r.glide = max(ms, 0) * 0.001 * cfg.sample_rate
		return .None
	},
	process = automation_recorder_process,
	reset   = proc(self: rawptr) {},
	release = proc(self: rawptr, allocator: mem.Allocator) {},
	destroy = proc(self: rawptr, allocator: mem.Allocator) { automation_recorder_free((^Automation_Recorder)(self)) },
	type_id = AUTOMATION_RECORDER_TYPE_ID,
	state_version = 1,
	save    = save_automation_recorder,
}

// Control thread. Makes a recorder node with no audio channels. Event-connect
// it to the node whose parameters it writes.
automation_recorder_create :: proc(settings: Automation_Recorder_Settings, allocator := context.allocator) -> (node: core.Node, r: ^Automation_Recorder, err: core.Error) {
	if settings.max_params < 0 || settings.max_events < 0 do return {}, nil, .Invalid_Argument
	r = new(Automation_Recorder, allocator)
	if r == nil do return {}, nil, .Out_Of_Memory
	r.settings, r.allocator = settings, allocator
	r.gate = {timeline = settings.timeline}
	r.open = make([dynamic]Open_Range, allocator)
	r.done = make([dynamic]Automation_Take, allocator)
	ae: mem.Allocator_Error
	r.params, ae = make([]Written, settings.max_params if settings.max_params > 0 else 64, allocator)
	if ae == nil do ae = rt.spsc_init(&r.commands, 1024, allocator)
	if ae == nil do ae = rt.spsc_init(&r.events, settings.max_events if settings.max_events > 0 else 8192, allocator)
	if ae != nil {
		automation_recorder_free(r)
		return {}, nil, .Out_Of_Memory
	}
	return core.node_make(&automation_recorder_vtable, r, allocator), r, .None
}

// Control thread. Arms or disarms writing, from the next block. Values are
// passed on to the node either way.
automation_recorder_arm :: proc(r: ^Automation_Recorder, armed: bool) -> core.Error {
	return auto_command(r, {kind = .Arm if armed else .Disarm})
}

// Control thread. Writes only from timeline position `punch_in` to `punch_out`.
automation_recorder_set_punch :: proc(r: ^Automation_Recorder, punch_in, punch_out: tb.Beats) -> core.Error {
	if !(punch_out > punch_in) do return .Invalid_Argument
	return auto_command(r, {kind = .Punch, a = punch_in, b = punch_out})
}

// Control thread. Removes the punch range.
automation_recorder_clear_punch :: proc(r: ^Automation_Recorder) -> core.Error {
	return auto_command(r, {kind = .No_Punch})
}

// Control thread. The user takes hold of `param`'s control, at `value`:
// writing starts. Suspend the parameter's automation player lane first
// (`clip.automation_player_suspend`), so the two don't fight.
automation_recorder_touch :: proc(r: ^Automation_Recorder, param: core.Param_Id, value: f64) -> core.Error {
	return auto_command(r, {kind = .Touch, param = param, value = value})
}

// Control thread. The control moved: the node gets `value`, and it is
// recorded if the parameter is being written.
automation_recorder_set :: proc(r: ^Automation_Recorder, param: core.Param_Id, value: f64) -> core.Error {
	return auto_command(r, {kind = .Set, param = param, value = value})
}

// Control thread. The user lets go of `param`'s control. In `.Touch` mode
// writing stops; in `.Latch` it goes on until the take ends.
automation_recorder_release :: proc(r: ^Automation_Recorder, param: core.Param_Id) -> core.Error {
	return auto_command(r, {kind = .Release, param = param})
}

// Control thread. The next finished range, if any (iterate with `for take
// in`). The caller owns `take.points`.
automation_recorder_poll :: proc(r: ^Automation_Recorder) -> (take: Automation_Take, ok: bool) {
	auto_drain(r)
	if len(r.done) == 0 do return {}, false
	take = r.done[0]
	ordered_remove(&r.done, 0)
	return take, true
}

// [rt] Changes lost for lack of room (poll more often, or raise `max_events`).
automation_recorder_dropped :: proc "contextless" (r: ^Automation_Recorder) -> u64 {
	return intrinsics.atomic_load(&r.dropped)
}

@(private)
auto_command :: proc(r: ^Automation_Recorder, c: Auto_Command) -> core.Error {
	return .None if rt.spsc_push(&r.commands, c) else .Out_Of_Memory
}

@(private)
automation_recorder_free :: proc(r: ^Automation_Recorder) {
	for o in r.open do delete(o.points)
	delete(r.open)
	for t in r.done do delete(t.points, r.allocator)
	delete(r.done)
	delete(r.params, r.allocator)
	rt.spsc_destroy(&r.commands, r.allocator)
	rt.spsc_destroy(&r.events, r.allocator)
	free(r, r.allocator)
}

// --- the audio side ----------------------------------------------------------------------

// [rt]
@(private)
automation_recorder_process :: proc(self: rawptr, ctx: ^core.Process_Context) {
	r := (^Automation_Recorder)(self)
	for &w in r.params[:r.n_params] do w.changed, w.touched, w.released = false, false, false
	for c in rt.spsc_pop(&r.commands) do apply_auto(r, c)
	if ctx.events_out != nil do for w in r.params[:r.n_params] do if w.changed {
		core.event_writer_push(ctx.events_out, {offset = 0, payload = core.Param_Value{param = w.param, value = w.value}})
	}
	gate_process(&r.gate, ctx, {
		user = r,
		begin = proc "contextless" (user: rawptr, g: ^Gate, frame: i64, pos: tb.Beats) -> bool {
			r := (^Automation_Recorder)(user)
			if !auto_push(r, {kind = .Begin, run = g.run, pass = g.pass, pos = pos}) do return false
			for &w in r.params[:r.n_params] do if w.writing {
				auto_push(r, {kind = .Touch, param = w.param, pos = pos, value = w.value})
				w.touched, w.changed = false, false // said already
			}
			return true
		},
		data = proc "contextless" (user: rawptr, g: ^Gate, e: ^History, a, b: i64, at: int) {
			r := (^Automation_Recorder)(user)
			if at != 0 do return // changes happen at the call's first frame
			pos := position(g, e, a)
			for w in r.params[:r.n_params] {
				if w.touched {
					auto_push(r, {kind = .Touch, param = w.param, pos = pos, value = w.value})
				} else if w.changed && w.writing {
					auto_push(r, {kind = .Point, param = w.param, pos = pos, value = w.value, glide = tb.Beats(r.glide * e.bpf)})
				}
				if w.released do auto_push(r, {kind = .Release, param = w.param, pos = pos})
			}
		},
		end = proc "contextless" (user: rawptr, g: ^Gate) {
			r := (^Automation_Recorder)(user)
			auto_push(r, {kind = .End, pos = g.last_pos})
			if r.settings.mode == .Latch do for &w in r.params[:r.n_params] do if !w.held do w.writing = false
		},
	})
}

// [rt]
@(private)
apply_auto :: proc "contextless" (r: ^Automation_Recorder, c: Auto_Command) {
	switch c.kind {
	case .Arm:      gate_command(&r.gate, {kind = .Arm})
	case .Disarm:   gate_command(&r.gate, {kind = .Disarm})
	case .Punch:    gate_command(&r.gate, {kind = .Punch, a = c.a, b = c.b})
	case .No_Punch: gate_command(&r.gate, {kind = .No_Punch})
	case .Latency:
	case .Touch, .Set, .Release:
		w := written(r, c.param)
		if w == nil {
			intrinsics.atomic_add(&r.dropped, 1)
			return
		}
		switch c.kind {
		case .Touch:
			w.value, w.changed, w.held = c.value, true, true
			if !w.writing do w.touched = true
			w.writing, w.released = true, false
		case .Set:
			w.value, w.changed = c.value, true
		case .Release:
			w.held = false
			if r.settings.mode == .Touch && w.writing {
				w.writing, w.released = false, true
				w.touched = false
			}
		case .Arm, .Disarm, .Punch, .No_Punch, .Latency:
		}
	}
}

// [rt] The parameter's slot, made on first use; nil when all are taken.
@(private)
written :: proc "contextless" (r: ^Automation_Recorder, param: core.Param_Id) -> ^Written {
	for &w in r.params[:r.n_params] do if w.param == param do return &w
	if r.n_params == len(r.params) do return nil
	r.params[r.n_params] = {param = param}
	r.n_params += 1
	return &r.params[r.n_params - 1]
}

// [rt]
@(private)
auto_push :: proc "contextless" (r: ^Automation_Recorder, m: Auto_Message) -> bool {
	if rt.spsc_push(&r.events, m) do return true
	intrinsics.atomic_add(&r.dropped, 1)
	return false
}

// --- the control side --------------------------------------------------------------------

@(private)
auto_drain :: proc(r: ^Automation_Recorder) {
	for m in rt.spsc_pop(&r.events) {
		switch m.kind {
		case .Begin:
			r.run, r.pass = int(m.run), int(m.pass)
		case .Touch:
			close_range(r, m.param, m.pos)
			o := Open_Range{param = m.param, start = m.pos, value = m.value, points = make([dynamic]clip.Automation_Point, r.allocator)}
			append(&o.points, clip.Automation_Point{at = m.pos, value = m.value})
			append(&r.open, o)
		case .Point:
			for &o in r.open do if o.param == m.param {
				last := o.points[len(o.points) - 1]
				if m.value == o.value do break
				if m.pos > last.at do append(&o.points, clip.Automation_Point{at = m.pos, value = o.value}) // held until now
				append(&o.points, clip.Automation_Point{at = max(m.pos + m.glide, last.at), value = m.value})
				o.value = m.value
			}
		case .Release:
			close_range(r, m.param, m.pos)
		case .End:
			for len(r.open) > 0 do close_range(r, r.open[0].param, m.pos)
		}
	}
}

// Ends `param`'s open range at `pos`, holding its last value there.
@(private)
close_range :: proc(r: ^Automation_Recorder, param: core.Param_Id, pos: tb.Beats) {
	for o, i in r.open do if o.param == param {
		points := o.points
		if pos > points[len(points) - 1].at do append(&points, clip.Automation_Point{at = pos, value = o.value})
		shrunk := make([]clip.Automation_Point, len(points), r.allocator)
		copy(shrunk, points[:])
		delete(points)
		append(&r.done, Automation_Take{param = param, run = r.run, pass = r.pass, start = o.start, end = pos, points = shrunk})
		ordered_remove(&r.open, i)
		return
	}
}
