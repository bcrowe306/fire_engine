// Profiling zones, written as a Spall trace (`core:prof/spall`; open the
// file at https://gravitymoth.com/spall/, or summarize it with
// `scripts/prof.py`). Off unless built with `-define:FIRE_PROF=true`: then
// `zone` is a few nanoseconds; off, it compiles to nothing.
//
//	prof.start("pads.spall")
//	defer prof.stop()
//	...
//	draw_mixer :: proc(...) {
//		prof.zone("mixer")
//		...
//	}
//
// Each thread writes into a buffer of its own (made on its first zone);
// a full buffer is written out on that thread (it shows in the trace as
// "Spall Trace Buffer Flush"). On the audio thread that is a syscall, so
// buffers are large (`BUFFER_BYTES`): a profile build is not for playing
// live, only for measuring.
package prof

import "base:intrinsics"
import "base:runtime"
import "core:prof/spall"
import "core:sync"

// (Used only when profiling is built in.)
_ :: runtime
_ :: spall
_ :: sync

// Whether zones are recorded: `-define:FIRE_PROF=true`.
ENABLED :: #config(FIRE_PROF, false)

// The threads that can record (others record nothing).
MAX_THREADS :: 64

// Each thread's buffer, written out when full and at `stop`.
BUFFER_BYTES :: 32 << 20

when ENABLED {
	@(private)
	Thread_Buffer :: struct {
		buf:   spall.Buffer,
		data:  []u8,
		named: bool,
	}

	@(private)
	state: struct {
		ctx:     spall.Context,
		on:      bool,
		lock:    sync.Mutex,
		buffers: [MAX_THREADS]^Thread_Buffer,
		count:   int,
	}

	@(private, thread_local)
	mine: ^Thread_Buffer
}

// Starts recording to `path` (a .spall file). False if it can't be made,
// or profiling is not built in.
start :: proc(path: string) -> bool {
	when ENABLED {
		// (The OS clock in nanoseconds, not the cycle counter: read inline,
		// the compiler may merge a zone's two reads of it into one, and
		// every zone lasts no time; on ARM Linux it did.)
		ok: bool
		state.ctx, ok = spall.context_create_with_scale(path, false, 1)
		if !ok do return false
		intrinsics.atomic_store(&state.on, true)
		return true
	} else {
		return false
	}
}

// Stops recording and writes out every thread's buffer. Call it once the
// threads that record have stopped (the audio device closed).
stop :: proc() {
	when ENABLED {
		if !intrinsics.atomic_load(&state.on) do return
		intrinsics.atomic_store(&state.on, false)
		sync.guard(&state.lock)
		for b in state.buffers[:state.count] {
			spall.buffer_flush(&state.ctx, &b.buf)
		}
		spall.context_destroy(&state.ctx)
	}
}

// Whether a trace is being recorded now.
recording :: #force_inline proc "contextless" () -> bool {
	when ENABLED {
		return intrinsics.atomic_load(&state.on)
	} else {
		return false
	}
}

// [rt] Names the calling thread in the trace (once; later calls do
// nothing).
thread_name :: proc "contextless" (name: string) {
	when ENABLED {
		b := buffer()
		if b == nil || b.named do return
		b.named = true
		spall._buffer_name_thread(&state.ctx, &b.buf, name)
	}
}

// [rt] Begins a zone named `name`, ended at the end of the calling scope.
@(deferred_none = end)
zone :: #force_inline proc "contextless" (name: string) {
	when ENABLED do begin(name)
}

// [rt] Begins a zone named `name`; `end` ends it (they nest).
begin :: #force_inline proc "contextless" (name: string) {
	when ENABLED {
		if !intrinsics.atomic_load(&state.on) do return
		b := buffer()
		if b != nil do spall._buffer_begin(&state.ctx, &b.buf, name)
	}
}

// [rt] Ends the zone `begin` (or `zone`) began last on this thread.
end :: #force_inline proc "contextless" () {
	when ENABLED {
		b := mine
		if b != nil && intrinsics.atomic_load(&state.on) do spall._buffer_end(&state.ctx, &b.buf)
	}
}

when ENABLED {
	// This thread's buffer, made on its first use (nil past MAX_THREADS).
	@(private)
	buffer :: #force_inline proc "contextless" () -> ^Thread_Buffer {
		if mine != nil do return mine
		return make_buffer()
	}

	@(private)
	make_buffer :: proc "contextless" () -> ^Thread_Buffer {
		context = runtime.default_context()
		sync.guard(&state.lock)
		if state.count >= MAX_THREADS do return nil
		b := new(Thread_Buffer, runtime.heap_allocator())
		b.data = make([]u8, BUFFER_BYTES, runtime.heap_allocator())
		b.buf, _ = spall.buffer_create(b.data, u32(sync.current_thread_id()))
		state.buffers[state.count] = b
		state.count += 1
		mine = b
		return b
	}
}
