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
