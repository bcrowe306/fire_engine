package app

import "core:sync"
import "core:thread"

// Background work for the control thread: decoding a file, chopping a
// sample, rendering an export. Jobs run on a small pool of threads, report
// progress, can be cancelled, and announce that they finished on the bus
// (as a `Job_Done`, delivered at a `dispatch` on the UI thread).
Jobs :: struct {
	pool:  thread.Pool,
	bus:   ^Bus,
	next:  u64,
	lock:  sync.Mutex,
	live:  [dynamic]^Job,
	reap:  Subscription,
}

// One piece of background work. Read `progress` and `state` anywhere;
// `run` reads `cancelled`.
Job :: struct {
	id:        u64,
	name:      string,
	run:       proc(job: ^Job, user: rawptr), // on a pool thread
	user:      rawptr,
	progress:  f32,  // atomic, 0..1; set with `job_progress`
	cancelled: bool, // atomic; set with `job_cancel`
	state:     Job_State, // atomic
	error:     string, // set by `run` on failure (a constant, or allocated with the jobs' allocator)
}

// Where a job is.
Job_State :: enum u8 {
	Queued,
	Running,
	Done,
	Cancelled,
	Failed,
}

// Delivered on the bus when a job ends (done, cancelled or failed). The job
// is freed after the dispatch that delivers this.
Job_Done :: struct {
	job: ^Job,
}

// Starts a pool of `threads` workers announcing to `bus`.
jobs_init :: proc(j: ^Jobs, bus: ^Bus, threads := 2, allocator := context.allocator) {
	j.bus = bus
	j.live = make([dynamic]^Job, allocator)
	thread.pool_init(&j.pool, allocator, max(threads, 1))
	thread.pool_start(&j.pool)
	j.reap = jobs_reaper(j)
}

// Cancels every job, waits for the workers, and frees the pool.
jobs_destroy :: proc(j: ^Jobs) {
	{
		sync.guard(&j.lock)
		for job in j.live do sync.atomic_store(&job.cancelled, true)
	}
	thread.pool_finish(&j.pool)
	thread.pool_destroy(&j.pool)
	unsubscribe(j.bus, j.reap)
	for job in j.live do free(job)
	delete(j.live)
}

// Queues `run(job, user)` on a worker. Returns the job, to watch or cancel.
job_start :: proc(j: ^Jobs, name: string, run: proc(job: ^Job, user: rawptr), user: rawptr) -> ^Job {
	job := new(Job)
	job^ = {name = name, run = run, user = user}
	{
		sync.guard(&j.lock)
		j.next += 1
		job.id = j.next
		append(&j.live, job)
	}
	Task :: struct {
		jobs: ^Jobs,
		job:  ^Job,
	}
	thread.pool_add_task(&j.pool, context.allocator, proc(t: thread.Task) {
		jobs := (^Jobs)(t.data)
		job := (^Job)(rawptr(uintptr(t.user_index)))
		if sync.atomic_load(&job.cancelled) {
			sync.atomic_store(&job.state, Job_State.Cancelled)
		} else {
			sync.atomic_store(&job.state, Job_State.Running)
			job.run(job, job.user)
			state := Job_State.Done
			if job.error != "" do state = .Failed
			if sync.atomic_load(&job.cancelled) do state = .Cancelled
			sync.atomic_store(&job.state, state)
		}
		post_any_thread(jobs.bus, Job_Done{job})
		post_any_thread(jobs.bus, Job_Reap{jobs, job})
	}, j, int(uintptr(rawptr(job))))
	return job
}

// Asks a job to stop; `run` sees it in `job_cancelled` and returns early.
job_cancel :: proc(job: ^Job) {
	sync.atomic_store(&job.cancelled, true)
}

// From `run`: whether the job should stop.
job_cancelled :: proc(job: ^Job) -> bool {
	return sync.atomic_load(&job.cancelled)
}

// From `run`: reports how far along the job is (0..1).
job_progress :: proc(job: ^Job, progress: f32) {
	sync.atomic_store(&job.progress, clamp(progress, 0, 1))
}

// Jobs not yet finished and announced.
jobs_running :: proc(j: ^Jobs) -> int {
	sync.guard(&j.lock)
	return len(j.live)
}

// Delivered after `Job_Done` so the job is freed once every handler has
// seen it.
@(private)
Job_Reap :: struct {
	jobs: ^Jobs,
	job:  ^Job,
}

// Subscribes the handler that frees finished jobs (once, from `jobs_init`).
@(private)
jobs_reaper :: proc(j: ^Jobs) -> Subscription {
	return subscribe(j.bus, Job_Reap, proc(_: rawptr, e: ^Job_Reap) {
		j := e.jobs
		sync.guard(&j.lock)
		for x, i in j.live do if x == e.job {
			unordered_remove(&j.live, i)
			break
		}
		free(e.job)
	})
}
