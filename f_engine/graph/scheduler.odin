package graph

import "base:intrinsics"
import "base:runtime"
import "core:mem"
import "core:os"
import "core:sync"
import "core:thread"
import "core:time"

import "fire:core"
import "fire:rt"

// Multithreaded scheduling (see /design/graph/#scheduling-multithreaded).
//
// Per block the audio thread resets each node's dependency counter, queues the
// nodes with none, publishes the plan in `Pool.work` and then works like any
// worker until `remaining` reaches zero. Finishing a node decrements its
// consumers' counters; the thread that takes one to zero runs that consumer
// next itself, and queues any others.

@(private)
SPIN :: 4000 // cpu_relax rounds before an idle worker sleeps (tens of µs)

// Per plan: the ready queue and this block's parameters.
@(private)
Schedule :: struct {
	queue:     rt.Mpmc_Queue(i32),
	remaining: i32, // atomic: nodes not yet finished this block
	frames:    int,
	t0:        i64,
	transport: ^core.Transport,
}

@(private)
Hazard :: struct {
	plan: ^Plan, // atomic: the plan this worker is reading, or nil
	_:    [rt.CACHE_LINE - size_of(rawptr)]u8,
}

@(private)
Worker :: struct {
	g:     ^Graph,
	index: int,
}

@(private)
Pool :: struct {
	threads:  []^thread.Thread,
	workers:  []Worker,
	hazards:  []Hazard,
	work:     ^Plan, // atomic: the plan being processed this block, nil between blocks
	sema:     sync.Sema,
	sleepers: i32, // atomic: workers asleep (or about to be) on `sema`
	queued:   i32, // atomic: nodes in the current queue (a hint for sleeping)
	stop:     bool, // atomic
}

@(private)
pool_start :: proc(g: ^Graph) -> core.Error {
	n := g.settings.workers
	if n < 0 do n = max(os.get_processor_core_count() - 1, 0)
	if n == 0 do return .None
	p := &g.pool
	p.threads = make([]^thread.Thread, n, g.allocator)
	p.workers = make([]Worker, n, g.allocator)
	p.hazards = make([]Hazard, n, g.allocator)
	if p.threads == nil || p.workers == nil || p.hazards == nil do return .Out_Of_Memory
	for i in 0 ..< n {
		p.workers[i] = {g, i}
		p.threads[i] = thread.create_and_start_with_data(&p.workers[i], worker_main, priority = .High)
		if p.threads[i] == nil do return .Device_Error
	}
	return .None
}

@(private)
pool_stop :: proc(g: ^Graph) {
	p := &g.pool
	intrinsics.atomic_store(&p.stop, true)
	sync.sema_post(&p.sema, len(p.threads))
	for th in p.threads do if th != nil {
		thread.join(th)
		thread.destroy(th)
	}
	delete(p.threads, g.allocator)
	delete(p.workers, g.allocator)
	delete(p.hazards, g.allocator)
	p.threads, p.workers, p.hazards = nil, nil, nil
}

@(private)
sched_init :: proc(g: ^Graph, p: ^Plan, a: mem.Allocator) -> core.Error {
	if len(g.pool.threads) == 0 do return .None
	return .None if rt.mpmc_init(&p.sched.queue, len(p.nodes), a) == nil else .Out_Of_Memory
}

@(private)
sched_destroy :: proc(p: ^Plan) {} // the queue lives in the plan's arena

// Control thread: waits until no worker is reading `p` (hazard pointers), so
// it can be freed. Workers only ever hold a plan they saw in `Pool.work`, and
// re-check it after publishing their hazard.
@(private)
sched_quiesce :: proc(g: ^Graph, p: ^Plan) {
	for &h in g.pool.hazards {
		for intrinsics.atomic_load(&h.plan) == p do thread.yield()
	}
}

// [rt] Processes one block of `p`: serially on the calling (audio) thread when
// that's cheaper (no parallel paths, or too little work to be worth waking
// workers), else on the calling thread and the pool.
@(private)
sched_run :: proc(g: ^Graph, p: ^Plan, frames: int, t0: i64, transport: ^core.Transport) {
	parallel := len(g.pool.threads) > 0 && p.width > 1 && p.work_ns >= g.settings.parallel_min_us * 1000
	start := time.tick_now()
	if parallel {
		run_parallel(g, p, frames, t0, transport)
		// Wall time × threads that could have been busy overestimates the
		// work; the serial measurement below corrects it when it switches.
		measured := f64(time.tick_since(start)) * f64(min(p.width, len(g.pool.threads) + 1))
		p.work_ns += (measured - p.work_ns) * 0.05
		return
	}
	for i in 0 ..< i32(len(p.nodes)) do run_node(g, p, i, frames, t0, transport)
	p.work_ns += (f64(time.tick_since(start)) - p.work_ns) * 0.05
}

@(private)
run_parallel :: proc(g: ^Graph, p: ^Plan, frames: int, t0: i64, transport: ^core.Transport) {
	s := &p.sched
	s.frames, s.t0, s.transport = frames, t0, transport
	for &pn in p.nodes do intrinsics.atomic_store_explicit(&pn.deps, pn.num_deps, .Relaxed)
	intrinsics.atomic_store_explicit(&s.remaining, i32(len(p.nodes)), .Relaxed)
	// Publish before queueing: a worker woken by `ready_push` must find the plan.
	intrinsics.atomic_store_explicit(&g.pool.work, p, .Release)
	first: i32 = -1
	for &pn, i in p.nodes do if pn.num_deps == 0 {
		if first < 0 do first = i32(i)
		else do ready_push(g, p, i32(i))
	}
	if first >= 0 do run_chain(g, p, first)
	for intrinsics.atomic_load_explicit(&s.remaining, .Acquire) > 0 {
		if i, ok := ready_pop(g, p); ok {
			run_chain(g, p, i)
		} else {
			intrinsics.cpu_relax() // the audio thread never sleeps
		}
	}
	intrinsics.atomic_store_explicit(&g.pool.work, nil, .Release)
}

// Runs `i`, then whichever consumer it made ready first, and so on: chains
// stay on one thread.
@(private)
run_chain :: proc(g: ^Graph, p: ^Plan, i: i32) {
	s := &p.sched
	i := i
	for {
		run_node(g, p, i, s.frames, s.t0, s.transport)
		next: i32 = -1
		for c in p.nodes[i].consumers {
			if intrinsics.atomic_sub_explicit(&p.nodes[c].deps, 1, .Acq_Rel) == 1 {
				if next < 0 do next = c
				else do ready_push(g, p, c)
			}
		}
		// Only now is this node finished: decrementing `remaining` before the
		// consumer counters above would let the block end (and the next one
		// reset the counters) while this thread still touches them.
		intrinsics.atomic_sub_explicit(&s.remaining, 1, .Acq_Rel)
		if next < 0 do return
		i = next
	}
}

// [rt] Queues a ready node. Wakes a worker only if every worker is asleep:
// an awake worker will take it, and wakes the next if more is waiting (see
// `ready_pop`). So the audio thread posts the semaphore at most once a block.
@(private)
ready_push :: proc "contextless" (g: ^Graph, p: ^Plan, i: i32) {
	ok := rt.mpmc_push(&p.sched.queue, i)
	assert_contextless(ok, "graph ready queue full") // capacity >= node count
	intrinsics.atomic_add(&g.pool.queued, 1)
	if int(intrinsics.atomic_load(&g.pool.sleepers)) == len(g.pool.threads) && claim_sleeper(&g.pool) {
		sync.sema_post(&g.pool.sema)
	}
}

// Takes a ready node; if more are waiting, wakes one more worker (the
// cascade that spreads wake-ups over the workers instead of the audio thread).
@(private)
ready_pop :: proc "contextless" (g: ^Graph, p: ^Plan, waker := false) -> (i32, bool) {
	i, ok := rt.mpmc_pop(&p.sched.queue)
	if !ok do return i, ok
	left := intrinsics.atomic_sub(&g.pool.queued, 1) - 1
	if waker && left > 0 && claim_sleeper(&g.pool) do sync.sema_post(&g.pool.sema)
	return i, ok
}

// Takes one sleeper off the count; the caller then owes it a post.
@(private)
claim_sleeper :: proc "contextless" (pool: ^Pool) -> bool {
	n := intrinsics.atomic_load(&pool.sleepers)
	for n > 0 {
		if _, ok := intrinsics.atomic_compare_exchange_weak(&pool.sleepers, n, n - 1); ok do return true
		n = intrinsics.atomic_load(&pool.sleepers)
	}
	return false
}

@(private)
worker_main :: proc(data: rawptr) {
	w := (^Worker)(data)
	g := w.g
	pool := &g.pool
	// Nodes must not allocate on any processing thread: give them the
	// configured allocator (nil by default, so a mistake fails loudly).
	context.allocator = g.settings.worker_allocator if g.settings.worker_allocator.procedure != nil else runtime.nil_allocator()
	context.temp_allocator = context.allocator
	rt.set_realtime_priority(80, u64(f64(g.settings.max_block) * 1e9 / g.settings.sample_rate))
	fp := rt.enable_flush_to_zero()
	defer rt.restore_fp_state(fp)

	hazard := &pool.hazards[w.index]
	idle := 0
	for !intrinsics.atomic_load(&pool.stop) {
		p := intrinsics.atomic_load_explicit(&pool.work, .Acquire)
		worked := false
		if p != nil {
			intrinsics.atomic_store(&hazard.plan, p) // seq_cst: see sched_quiesce
			if intrinsics.atomic_load(&pool.work) == p {
				for i in ready_pop(g, p, waker = true) {
					run_chain(g, p, i)
					worked = true
				}
			}
			intrinsics.atomic_store(&hazard.plan, nil)
		}
		if worked {
			idle = 0
		} else if idle < SPIN {
			idle += 1
			intrinsics.cpu_relax()
		} else {
			sleep(pool)
			idle = 0
		}
	}
}

// Sleeps until a node is queued (or the pool stops). Announces itself first,
// then re-checks, so a push can't slip between the check and the wait.
@(private)
sleep :: proc(pool: ^Pool) {
	intrinsics.atomic_add(&pool.sleepers, 1)
	if intrinsics.atomic_load(&pool.queued) > 0 || intrinsics.atomic_load(&pool.stop) {
		if claim_sleeper(pool) do return // took ourselves back off
		// A producer claimed us already: consume its post.
	}
	sync.sema_wait(&pool.sema)
}

@(private)
assert_contextless :: proc "contextless" (cond: bool, msg: string) {
	if !cond do intrinsics.trap()
}
