package test_app_core

import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

import app "app:core"
import "fire:backend/fake"
import fc "fire:core"
import "fire:dsp"
import "fire:graph"
import kit "fire:testkit"

// --- events --------------------------------------------------------------------------------

Ping :: struct {
	n: int,
}

Log :: struct {
	got: [dynamic]int,
}

@(test)
events_publish_post_and_dispatch :: proc(t: ^testing.T) {
	b: app.Bus
	app.bus_init(&b)
	defer app.bus_destroy(&b)
	log: Log
	defer delete(log.got)
	app.subscribe(&b, Ping, proc(user: rawptr, e: ^Ping) {
		append(&(^Log)(user).got, e.n)
	}, &log)
	app.publish(&b, Ping{1})
	testing.expect_value(t, len(log.got), 1) // at once
	app.post(&b, Ping{2})
	app.post(&b, Ping{3})
	testing.expect_value(t, len(log.got), 1) // not yet
	app.dispatch(&b)
	testing.expect(t, len(log.got) == 3 && log.got[1] == 2 && log.got[2] == 3, "in posting order")
	app.publish(&b, "a string") // a type nobody subscribed to: nothing happens
}

// Many events over many dispatches (each dispatch reuses the memory of the
// one before last).
@(test)
events_over_many_dispatches :: proc(t: ^testing.T) {
	b: app.Bus
	app.bus_init(&b)
	defer app.bus_destroy(&b)
	total := 0
	app.subscribe(&b, Ping, proc(user: rawptr, e: ^Ping) { (^int)(user)^ += e.n }, &total)
	for _ in 0 ..< 20 {
		for _ in 0 ..< 3000 do app.post(&b, Ping{1})
		app.dispatch(&b)
	}
	testing.expect_value(t, total, 60_000)
}

@(test)
events_unsubscribe_and_reentrance :: proc(t: ^testing.T) {
	b: app.Bus
	app.bus_init(&b)
	defer app.bus_destroy(&b)
	State :: struct {
		b:     ^app.Bus,
		self:  app.Subscription,
		calls: int,
	}
	s := State{b = &b}
	// Unsubscribes itself, and posts during dispatch (delivered next time).
	s.self = app.subscribe(&b, Ping, proc(user: rawptr, e: ^Ping) {
		s := (^State)(user)
		s.calls += 1
		app.unsubscribe(s.b, s.self)
		app.post(s.b, Ping{e.n + 1})
	}, &s)
	others := 0
	app.subscribe(&b, Ping, proc(user: rawptr, e: ^Ping) { (^int)(user)^ += 1 }, &others)
	app.post(&b, Ping{1})
	app.dispatch(&b)
	testing.expect_value(t, s.calls, 1)
	testing.expect_value(t, others, 1) // later subscribers still get the event
	app.dispatch(&b)                    // the event posted by the handler
	testing.expect_value(t, s.calls, 1) // gone
	testing.expect_value(t, others, 2)
}

@(test)
events_from_other_threads_and_the_audio_thread :: proc(t: ^testing.T) {
	b: app.Bus
	app.bus_init(&b)
	defer app.bus_destroy(&b)
	total := 0
	app.subscribe(&b, Ping, proc(user: rawptr, e: ^Ping) { (^int)(user)^ += e.n }, &total)

	// Worker threads post with a lock.
	Worker :: struct {
		b: ^app.Bus,
	}
	w := Worker{&b}
	threads: [4]^thread.Thread
	for &th in threads {
		th = thread.create_and_start_with_data(&w, proc(data: rawptr) {
			w := (^Worker)(data)
			for _ in 0 ..< 100 do app.post_any_thread(w.b, Ping{1})
		})
	}
	for th in threads {
		thread.join(th)
		thread.destroy(th)
	}
	app.dispatch(&b)
	testing.expect_value(t, total, 400)

	// The audio thread sends through a channel without allocating.
	ch: app.Channel(Ping)
	testing.expect(t, app.channel_init(&b, &ch, 8) == nil)
	defer app.channel_destroy(&b, &ch)
	trap: kit.Trap_Allocator
	{
		context.allocator = kit.trap_allocator(&trap)
		context.temp_allocator = context.allocator
		for _ in 0 ..< 10 do app.send(&ch, Ping{10})
	}
	testing.expect_value(t, trap.violations, 0)
	testing.expect_value(t, sync.atomic_load(&ch.dropped), 2) // 8 fit
	total = 0
	app.dispatch(&b)
	testing.expect_value(t, total, 80)
}

// --- commands ------------------------------------------------------------------------------

Model :: struct {
	volume: f32,
	name:   string,
	notes:  [dynamic]int,
}

set_volume :: proc(ctx: rawptr, key: app.Key, v: f32) {
	(^Model)(ctx).volume = v
}

// A command with data of its own: appending a note (undo removes it).
Add_Note :: struct {
	note: int,
}

add_note_vtable := app.Command_VTable {
	apply = proc(data: rawptr, ctx: rawptr) { append(&(^Model)(ctx).notes, (^Add_Note)(data).note) },
	revert = proc(data: rawptr, ctx: rawptr) { pop(&(^Model)(ctx).notes) },
}

add_note :: proc(h: ^app.History, n: int) {
	app.execute(h, {vtable = &add_note_vtable, data = new_clone(Add_Note{n}), name = "Add Note"})
}

@(test)
undo_redo_merge_and_transactions :: proc(t: ^testing.T) {
	m: Model
	defer delete(m.notes)
	h: app.History
	app.history_init(&h, &m)
	defer app.history_destroy(&h)
	k := app.Key{id = 7, field = 1}

	// A drag: three sets merge into one step that undoes to the start.
	app.set_value(&h, "Set Volume", k, f32(0), f32(0.2), set_volume)
	app.set_value(&h, "Set Volume", k, f32(0.2), f32(0.5), set_volume)
	app.set_value(&h, "Set Volume", k, f32(0.5), f32(0.8), set_volume)
	testing.expect_value(t, m.volume, 0.8)
	testing.expect_value(t, len(h.undo), 1)
	testing.expect_value(t, app.undo_name(&h), "Set Volume")
	app.seal(&h) // the knob released: the next move is a new step
	app.set_value(&h, "Set Volume", k, f32(0.8), f32(0.9), set_volume)
	testing.expect_value(t, len(h.undo), 2)
	testing.expect(t, app.undo(&h))
	testing.expect_value(t, m.volume, 0.8)
	testing.expect(t, app.undo(&h))
	testing.expect_value(t, m.volume, 0)
	testing.expect(t, !app.undo(&h))
	testing.expect(t, app.redo(&h))
	testing.expect_value(t, m.volume, 0.8)

	// A new command clears the redo stack.
	add_note(&h, 60)
	testing.expect(t, !app.redo(&h))

	// A transaction is one step, undone in reverse.
	app.begin(&h, "Add Chord")
	add_note(&h, 64)
	add_note(&h, 67)
	app.set_value(&h, "Set Volume", k, f32(0.8), f32(0.3), set_volume)
	app.end(&h)
	testing.expect_value(t, len(m.notes), 3)
	testing.expect_value(t, app.undo_name(&h), "Add Chord")
	app.undo(&h)
	testing.expect_value(t, len(m.notes), 1)
	testing.expect_value(t, m.volume, 0.8)
	app.redo(&h)
	testing.expect_value(t, len(m.notes), 3)
	testing.expect_value(t, m.volume, 0.3)
}

@(test)
dirty_tracking_and_the_limit :: proc(t: ^testing.T) {
	m: Model
	defer delete(m.notes)
	h: app.History
	app.history_init(&h, &m, limit = 3)
	defer app.history_destroy(&h)
	testing.expect(t, !app.is_dirty(&h))
	add_note(&h, 1)
	testing.expect(t, app.is_dirty(&h))
	app.mark_saved(&h)
	testing.expect(t, !app.is_dirty(&h))
	// A set right after saving starts a new step (it must not merge into
	// the saved one), so undoing it returns to the saved state.
	k := app.Key{1, 1}
	app.set_value(&h, "Set Volume", k, f32(0), f32(1), set_volume)
	testing.expect(t, app.is_dirty(&h))
	app.undo(&h)
	testing.expect(t, !app.is_dirty(&h))
	for i in 0 ..< 5 do add_note(&h, i)
	testing.expect_value(t, len(h.undo), 3) // the limit
	testing.expect(t, app.is_dirty(&h))
	for app.undo(&h) {}
	testing.expect(t, app.is_dirty(&h)) // the saved state scrolled off
	testing.expect_value(t, len(m.notes), 3)
}

// --- stores --------------------------------------------------------------------------------

Pad :: struct {
	name:   string,
	volume: f32,
}

@(test)
stores_and_their_saving :: proc(t: ^testing.T) {
	ids: app.Ids
	s: app.Store(Pad)
	app.store_init(&s)
	defer app.store_destroy(&s)
	a, b, c := app.new_id(&ids), app.new_id(&ids), app.new_id(&ids)
	testing.expect(t, a == 1 && b == 2 && c == 3)
	app.store_add(&s, a, Pad{"kick", 0.9})
	app.store_add(&s, b, Pad{"snare", 0.7})
	app.store_add(&s, c, Pad{"hat", 0.5}, index = 0)
	testing.expect(t, !app.store_add(&s, a, Pad{}), "ids are unique")
	testing.expect_value(t, app.store_index(&s, c), 0)
	app.store_move(&s, c, 2)
	testing.expect_value(t, app.store_index(&s, c), 2)
	v, at, ok := app.store_remove(&s, b)
	testing.expect(t, ok && at == 1 && v.name == "snare")
	app.store_add(&s, b, v, at) // undo a removal: back where it was
	testing.expect_value(t, app.store_index(&s, b), 1)
	app.store_get(&s, a).volume = 0.25

	w: fc.State_Writer
	fc.state_writer_init(&w, context.temp_allocator)
	app.document_save(&w, &ids)
	app.store_save(&w, {'P', 'A', 'D', 'S'}, 1, &s, proc(w: ^fc.State_Writer, p: ^Pad) {
		fc.write_string(w, p.name)
		fc.write_f32(w, p.volume)
	})
	data, _ := fc.state_writer_bytes(&w)

	r := fc.state_reader(data)
	ids2: app.Ids
	dc, _ := fc.read_chunk(&r)
	testing.expect_value(t, app.document_load(dc, &ids2), fc.Error.None)
	testing.expect_value(t, ids2.next, ids.next)
	sc, _ := fc.read_chunk(&r)
	s2: app.Store(Pad)
	app.store_init(&s2)
	defer app.store_destroy(&s2)
	read :: proc(r: ^fc.State_Reader, version: u32, p: ^Pad) -> bool {
		p.name = fc.read_string(r) // a view of the data, fine for the test
		p.volume = fc.read_f32(r)
		return true
	}
	testing.expect_value(t, app.store_load(sc, &s2, read), fc.Error.None)
	testing.expect_value(t, app.store_len(&s2), 3)
	for it, i in s.items {
		testing.expect(t, s2.items[i].id == it.id && s2.items[i].value == it.value, "same entity in the same place")
	}
	// Truncated data is rejected.
	for cut in ([]int{len(sc.data) - 1, 10, 3}) {
		s3: app.Store(Pad)
		app.store_init(&s3)
		e := app.store_load({tag = sc.tag, version = 1, data = sc.data[:cut]}, &s3, read)
		testing.expectf(t, e == .Invalid_Data, "cut at %d: %v", cut, e)
		app.store_destroy(&s3)
	}
}

// --- jobs ----------------------------------------------------------------------------------

@(test)
jobs_run_report_and_cancel :: proc(t: ^testing.T) {
	b: app.Bus
	app.bus_init(&b)
	defer app.bus_destroy(&b)
	j: app.Jobs
	app.jobs_init(&j, &b, threads = 2)
	defer app.jobs_destroy(&j)
	Done :: struct {
		states: [dynamic]app.Job_State,
	}
	done: Done
	defer delete(done.states)
	app.subscribe(&b, app.Job_Done, proc(user: rawptr, e: ^app.Job_Done) {
		append(&(^Done)(user).states, e.job.state)
	}, &done)

	work := proc(job: ^app.Job, user: rawptr) {
		for i in 0 ..< 100 {
			if app.job_cancelled(job) do return
			app.job_progress(job, f32(i + 1) / 100)
			time.sleep(200 * time.Microsecond)
		}
	}
	a := app.job_start(&j, "finishes", work, nil)
	c := app.job_start(&j, "cancelled", work, nil)
	app.job_cancel(c)
	f := app.job_start(&j, "fails", proc(job: ^app.Job, user: rawptr) { job.error = "no such file" }, nil)
	_ = f
	deadline := time.tick_now()
	for len(done.states) < 3 && time.tick_since(deadline) < 10 * time.Second {
		app.dispatch(&b)
		time.sleep(time.Millisecond)
	}
	testing.expect_value(t, len(done.states), 3)
	counts: [app.Job_State]int
	for s in done.states do counts[s] += 1
	testing.expect_value(t, counts[.Done], 1)
	testing.expect_value(t, counts[.Cancelled], 1)
	testing.expect_value(t, counts[.Failed], 1)
	app.dispatch(&b) // reap
	testing.expect_value(t, app.jobs_running(&j), 0)
	_ = a
}

// --- the engine host -----------------------------------------------------------------------

Host_Log :: struct {
	kinds: [dynamic]app.Host_Event_Kind,
}

@(test)
host_opens_loses_and_restores_a_device :: proc(t: ^testing.T) {
	b: app.Bus
	app.bus_init(&b)
	defer app.bus_destroy(&b)
	log: Host_Log
	defer delete(log.kinds)
	app.subscribe(&b, app.Host_Event, proc(user: rawptr, e: ^app.Host_Event) {
		append(&(^Host_Log)(user).kinds, e.kind)
	}, &log)

	h: app.Host
	testing.expect_value(t, app.host_init(&h, {fake = true, max_block = 256}, &b), fc.Error.None)
	defer app.host_destroy(&h)
	testing.expect_value(t, app.host_open(&h), fc.Error.None)
	testing.expect(t, h.graph != nil && h.clock != nil, "an engine at the device's rate")
	testing.expect_value(t, h.graph.settings.sample_rate, h.format.sample_rate)

	// Something to play: a gain node so the graph does work.
	id, _ := graph.add_node(h.graph, dsp.gain_create(), 2, 2)
	for c in 0 ..< 2 do graph.connect(h.graph, id, c, graph.OUTPUT, c)
	graph.commit(h.graph)
	testing.expect(t, app.host_fake_run(&h, 10) > 0, "callbacks run")

	// Unplugged, and kept away for a while: lost, retried, then restored.
	f := app.host_fake(&h)
	fake.set_absent(f, true)
	fake.unplug(f)
	app.host_update(&h)
	testing.expect(t, h.lost, "lost")
	for _ in 0 ..< 3 do app.host_update(&h) // fails to reopen while absent
	testing.expect(t, h.lost, "still lost")
	fake.set_absent(f, false)
	h.retry_at = time.tick_now() // no waiting in the test
	app.host_update(&h)
	testing.expect(t, !h.lost && h.running, "restored")
	testing.expect_value(t, len(graph.nodes(h.graph, context.temp_allocator)), 1) // the same graph
	want := []app.Host_Event_Kind{.Opened, .Lost, .Restored}
	found := 0
	for k in log.kinds do if found < len(want) && k == want[found] do found += 1
	testing.expect_value(t, found, len(want))
}

Engine_Log :: struct {
	changes: int,
}

@(test)
host_moves_the_engine_to_a_new_rate_and_renders_offline :: proc(t: ^testing.T) {
	b: app.Bus
	app.bus_init(&b)
	defer app.bus_destroy(&b)
	changes := 0
	app.subscribe(&b, app.Host_Engine_Changed, proc(user: rawptr, e: ^app.Host_Engine_Changed) { (^int)(user)^ += 1 }, &changes)
	h: app.Host
	app.host_init(&h, {fake = true, sample_rate = 48_000, max_block = 256}, &b)
	defer app.host_destroy(&h)
	testing.expect_value(t, app.host_open(&h), fc.Error.None)
	id, _ := graph.add_node(h.graph, dsp.gain_create(), 2, 2)
	graph.set_param_ramp(h.graph, id, dsp.GAIN_PARAM_DB, -6, 0)
	graph.commit(h.graph)

	h.settings.sample_rate = 44_100
	testing.expect_value(t, app.host_open(&h), fc.Error.None)
	testing.expect_value(t, h.graph.settings.sample_rate, 44_100)
	testing.expect_value(t, changes, 2)
	testing.expect_value(t, len(graph.nodes(h.graph, context.temp_allocator)), 1) // carried over

	// Offline: the device closed, render straight through the engine.
	app.host_close(&h)
	out := [2][]f32{make([]f32, 1000, context.temp_allocator), make([]f32, 1000, context.temp_allocator)}
	app.host_render(&h, out[:], 1000)
	for x in out[0] do testing.expect(t, x == x, "finite")
}
