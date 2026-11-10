/*
The application layer's model side, with no GUI: events, commands with
undo and redo, entity stores and their saving, background jobs, and the
engine host (device, clock, graph). A headless app (a box with no screen)
uses this package alone; `app:ui` adds the window.

Import it as `app` (the engine's `fire:core` is `core`):

	import app "app:core"   // app.Bus, app.History, app.Host ...

See /guides/app-core/ for a walk-through.
*/
package app

import "base:runtime"
import "core:mem"
import "core:sync"

import "fire:rt"

// A typed event bus. Subscribers register for one event type (any Odin
// type); `publish` delivers to them at once, `post` queues the event until
// the next `dispatch` (call it once per frame, on the UI thread).
// `Channel`s carry events from the audio thread. Not thread-safe except
// `post_any_thread` and channels: use it from one thread.
Bus :: struct {
	subs:      map[typeid][dynamic]Subscriber,
	next_id:   u64,
	queue:     [dynamic]Queued,   // posted events, in order
	arenas:    [2]mem.Dynamic_Arena, // their payloads: one being posted into, one being delivered
	current:   int,
	channels:  [dynamic]Channel_Source,
	locked:    [dynamic]Queued,   // posted from other threads
	lock_arena: mem.Dynamic_Arena,
	lock:      sync.Mutex,
	allocator: mem.Allocator,
	depth:     int, // nested deliveries (unsubscribing while delivering is deferred)
	removed:   [dynamic]Subscription,
}

// What `subscribe` returns, to `unsubscribe` with.
Subscription :: struct {
	type: typeid,
	id:   u64,
}

@(private)
Subscriber :: struct {
	id:      u64,
	handler: proc(user: rawptr, event: rawptr),
	user:    rawptr,
	dead:    bool,
}

@(private)
Queued :: struct {
	type: typeid,
	data: rawptr,
}

@(private)
Channel_Source :: struct {
	drain: proc(ch: rawptr, bus: ^Bus),
	ch:    rawptr,
}

// Prepares an empty bus.
bus_init :: proc(b: ^Bus, allocator := context.allocator) {
	b.allocator = allocator
	b.subs = make(map[typeid][dynamic]Subscriber, allocator)
	b.queue = make([dynamic]Queued, allocator)
	b.channels = make([dynamic]Channel_Source, allocator)
	b.locked = make([dynamic]Queued, allocator)
	b.removed = make([dynamic]Subscription, allocator)
	for &a in b.arenas do mem.dynamic_arena_init(&a, allocator, allocator)
	mem.dynamic_arena_init(&b.lock_arena, allocator, allocator)
}

// Frees the bus and everything queued on it.
bus_destroy :: proc(b: ^Bus) {
	for _, list in b.subs do delete(list)
	delete(b.subs)
	delete(b.queue)
	delete(b.channels)
	delete(b.locked)
	delete(b.removed)
	for &a in b.arenas do mem.dynamic_arena_destroy(&a)
	mem.dynamic_arena_destroy(&b.lock_arena)
	b^ = {}
}

// Calls `handler` with every event of type T published or dispatched from
// now on, until `unsubscribe`. Handlers run in subscription order.
subscribe :: proc(b: ^Bus, $T: typeid, handler: proc(user: rawptr, event: ^T), user: rawptr = nil) -> Subscription {
	b.next_id += 1
	list, ok := &b.subs[T]
	if !ok {
		b.subs[T] = make([dynamic]Subscriber, b.allocator)
		list = &b.subs[T]
	}
	append(list, Subscriber{id = b.next_id, handler = auto_cast handler, user = user})
	return {T, b.next_id}
}

// Stops a subscription. Safe from inside a handler.
unsubscribe :: proc(b: ^Bus, s: Subscription) {
	list, ok := &b.subs[s.type]
	if !ok do return
	for &sub, i in list do if sub.id == s.id {
		if b.depth > 0 {
			sub.dead = true
			append(&b.removed, s)
		} else {
			ordered_remove(list, i)
		}
		return
	}
}

// Delivers `event` to T's subscribers now.
publish :: proc(b: ^Bus, event: $T) {
	e := event
	deliver(b, T, &e)
}

// Queues `event` for the next `dispatch`.
post :: proc(b: ^Bus, event: $T) {
	p := new(T, mem.dynamic_arena_allocator(&b.arenas[b.current]))
	p^ = event
	append(&b.queue, Queued{T, p})
}

// Queues `event` for the next `dispatch`, from any thread (a background
// job, say). Takes a lock; not for the audio thread (use a `Channel`).
post_any_thread :: proc(b: ^Bus, event: $T) {
	sync.guard(&b.lock)
	p := new(T, mem.dynamic_arena_allocator(&b.lock_arena))
	p^ = event
	append(&b.locked, Queued{T, p})
}

// Delivers queued events in the order they were posted, then drains every
// channel. Events posted by handlers during the dispatch wait for the next.
dispatch :: proc(b: ^Bus) {
	{
		sync.guard(&b.lock)
		for q in b.locked {
			info := type_info_of(q.type)
			p, _ := mem.alloc(info.size, info.align, mem.dynamic_arena_allocator(&b.arenas[b.current]))
			mem.copy(p, q.data, info.size)
			append(&b.queue, Queued{q.type, p})
		}
		clear(&b.locked)
		mem.dynamic_arena_reset(&b.lock_arena)
	}
	// Handlers may post: they post into the other arena and a new queue.
	queued := b.queue
	b.queue = make([dynamic]Queued, b.allocator)
	delivering := b.current
	b.current = 1 - b.current
	for q in queued do deliver(b, q.type, q.data)
	delete(queued)
	mem.dynamic_arena_reset(&b.arenas[delivering])
	for c in b.channels do c.drain(c.ch, b)
}

@(private)
deliver :: proc(b: ^Bus, type: typeid, data: rawptr) {
	list, ok := b.subs[type]
	if !ok do return
	b.depth += 1
	n := len(list) // subscribers added by handlers start with the next event
	for i in 0 ..< n {
		sub := b.subs[type][i]
		if !sub.dead do sub.handler(sub.user, data)
	}
	b.depth -= 1
	if b.depth == 0 && len(b.removed) > 0 {
		for s in b.removed do unsubscribe(b, s)
		clear(&b.removed)
	}
}

// Events of type T from the audio thread: a fixed-size lock-free queue
// that `dispatch` drains into the bus. `send` never allocates or blocks; a
// full channel drops the event and counts it.
Channel :: struct($T: typeid) {
	queue:   rt.Spsc_Queue(T),
	dropped: u64, // atomic
}

// Makes a channel holding up to `capacity` events and connects it to `b`.
// It must outlive the bus's use of it (destroy it after the last dispatch).
channel_init :: proc(b: ^Bus, ch: ^Channel($T), capacity: int, allocator := context.allocator) -> runtime.Allocator_Error {
	rt.spsc_init(&ch.queue, capacity, allocator) or_return
	append(&b.channels, Channel_Source{drain = proc(c: rawptr, b: ^Bus) {
		ch := (^Channel(T))(c)
		for e in rt.spsc_pop(&ch.queue) {
			e := e
			deliver(b, T, &e)
		}
	}, ch = ch})
	return nil
}

// Disconnects the channel from `b` and frees it.
channel_destroy :: proc(b: ^Bus, ch: ^Channel($T), allocator := context.allocator) {
	for c, i in b.channels do if c.ch == ch {
		ordered_remove(&b.channels, i)
		break
	}
	rt.spsc_destroy(&ch.queue, allocator)
}

// [rt] Sends `event` to be delivered at the bus's next dispatch. False
// (and counted in `dropped`) if the channel is full.
send :: proc "contextless" (ch: ^Channel($T), event: T) -> bool {
	if rt.spsc_push(&ch.queue, event) do return true
	sync.atomic_add(&ch.dropped, 1)
	return false
}

_ :: rt.spsc_len // used by Channel's generic procs
