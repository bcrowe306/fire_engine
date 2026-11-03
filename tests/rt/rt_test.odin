package test_rt

import "base:intrinsics"
import "core:testing"
import "core:thread"

import "fire:rt"

@(test)
flush_to_zero_flushes_denormals :: proc(t: ^testing.T) {
	when ODIN_ARCH != .arm64 && ODIN_ARCH != .amd64 {
		return
	}
	// Volatile loads keep the optimizer from constant-folding the multiply at compile time.
	volatile_mul :: proc(a, b: f32) -> f32 {
		a, b := a, b
		return intrinsics.volatile_load(&a) * intrinsics.volatile_load(&b)
	}
	tiny: f32 = 1e-38

	prev := rt.enable_flush_to_zero()
	testing.expect(t, rt.flush_to_zero_enabled())
	testing.expect_value(t, volatile_mul(tiny, 0.001), 0)
	rt.restore_fp_state(prev)

	testing.expect(t, !rt.flush_to_zero_enabled())
	testing.expect(t, volatile_mul(tiny, 0.001) != 0, "denormal should survive with FTZ off")
}

@(test)
spsc_basic :: proc(t: ^testing.T) {
	q: rt.Spsc_Queue(int)
	rt.spsc_init(&q, 3)
	defer rt.spsc_destroy(&q)

	testing.expect_value(t, rt.spsc_capacity(&q), 4)
	for i in 0 ..< 4 do testing.expect(t, rt.spsc_push(&q, i))
	testing.expect(t, !rt.spsc_push(&q, 99), "push into full queue must fail")
	for i in 0 ..< 4 {
		v, ok := rt.spsc_pop(&q)
		testing.expect(t, ok)
		testing.expect_value(t, v, i)
	}
	_, ok := rt.spsc_pop(&q)
	testing.expect(t, !ok)
}

Stress :: struct {
	q:     rt.Spsc_Queue(u64),
	count: u64,
	bad:   u64,
}

// One producer and one consumer thread hammer a small queue. Every value must
// arrive exactly once, in order.
@(test)
spsc_two_thread_stress :: proc(t: ^testing.T) {
	s: Stress
	s.count = 2_000_000
	rt.spsc_init(&s.q, 64)
	defer rt.spsc_destroy(&s.q)

	producer := thread.create_and_start_with_data(&s, proc(p: rawptr) {
		s := (^Stress)(p)
		for i: u64 = 0; i < s.count; {
			if rt.spsc_push(&s.q, i) do i += 1
		}
	})
	consumer := thread.create_and_start_with_data(&s, proc(p: rawptr) {
		s := (^Stress)(p)
		expected: u64 = 0
		for expected < s.count {
			v, ok := rt.spsc_pop(&s.q)
			if !ok do continue
			if v != expected do s.bad += 1
			expected += 1
		}
	})
	thread.join_multiple(producer, consumer)
	thread.destroy(producer)
	thread.destroy(consumer)

	testing.expect_value(t, s.bad, 0)
	testing.expect_value(t, rt.spsc_len(&s.q), 0)
}

@(test)
mpmc_basic :: proc(t: ^testing.T) {
	q: rt.Mpmc_Queue(int)
	rt.mpmc_init(&q, 3)
	defer rt.mpmc_destroy(&q)
	testing.expect_value(t, rt.mpmc_capacity(&q), 4)
	for i in 0 ..< 4 do testing.expect(t, rt.mpmc_push(&q, i))
	testing.expect(t, !rt.mpmc_push(&q, 99), "push into full queue must fail")
	for i in 0 ..< 4 {
		v, ok := rt.mpmc_pop(&q)
		testing.expect(t, ok)
		testing.expect_value(t, v, i)
	}
	_, ok := rt.mpmc_pop(&q)
	testing.expect(t, !ok)
	// Wrap around several laps.
	for lap in 0 ..< 10 {
		for i in 0 ..< 3 do rt.mpmc_push(&q, lap * 10 + i)
		for i in 0 ..< 3 {
			v, _ := rt.mpmc_pop(&q)
			testing.expect_value(t, v, lap * 10 + i)
		}
	}
}

Mpmc_Stress :: struct {
	q:        rt.Mpmc_Queue(u64),
	per:      u64,
	seen:     []u32, // atomic counts per value
	consumed: u64,   // atomic
}

// 4 producers and 4 consumers through a small queue: every value exactly once.
@(test)
mpmc_stress :: proc(t: ^testing.T) {
	PRODUCERS :: 4
	s: Mpmc_Stress
	s.per = 100_000
	rt.mpmc_init(&s.q, 64)
	defer rt.mpmc_destroy(&s.q)
	s.seen = make([]u32, PRODUCERS * int(s.per))
	defer delete(s.seen)

	Arg :: struct {
		s:  ^Mpmc_Stress,
		id: u64,
	}
	args: [PRODUCERS]Arg
	threads: [2 * PRODUCERS]^thread.Thread
	for p in 0 ..< PRODUCERS {
		args[p] = {&s, u64(p)}
		threads[p] = thread.create_and_start_with_data(&args[p], proc(data: rawptr) {
			a := (^Arg)(data)
			for i: u64 = 0; i < a.s.per; {
				if rt.mpmc_push(&a.s.q, a.id * a.s.per + i) do i += 1
			}
		})
	}
	for c in 0 ..< PRODUCERS {
		threads[PRODUCERS + c] = thread.create_and_start_with_data(&s, proc(data: rawptr) {
			s := (^Mpmc_Stress)(data)
			total := u64(len(s.seen))
			for intrinsics.atomic_load(&s.consumed) < total {
				if v, ok := rt.mpmc_pop(&s.q); ok {
					intrinsics.atomic_add(&s.seen[v], 1)
					intrinsics.atomic_add(&s.consumed, 1)
				}
			}
		})
	}
	for th in threads {
		thread.join(th)
		thread.destroy(th)
	}
	bad := 0
	for n in s.seen do if n != 1 do bad += 1
	testing.expect_value(t, bad, 0)
}

// Each worker raises its own priority; on macOS this must succeed for any
// user (a time-constraint policy needs no privileges).
@(test)
realtime_priority_from_thread :: proc(t: ^testing.T) {
	ok: bool
	th := thread.create_and_start_with_data(&ok, proc(data: rawptr) {
		(^bool)(data)^ = rt.set_realtime_priority(80, 5_333_333)
	})
	thread.join(th)
	thread.destroy(th)
	when ODIN_OS == .Darwin || ODIN_OS == .Windows {
		testing.expect(t, ok, "set_realtime_priority failed")
	}
}
