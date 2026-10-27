package blockingqueue

import "core:mem"

/*
================================================================================
 BLOCKING QUEUE — TEST LADDER
================================================================================

 Interface under test (your blockingqueue.odin must provide):

   BlockingQueue :: struct($T: typeid) { ... }
   new_blocking_queue :: proc($T: typeid) -> ^BlockingQueue(T)
   destroy            :: proc(q: ^BlockingQueue($T))
   push               :: proc(q: ^BlockingQueue($T), item: T)
   pop                :: proc(q: ^BlockingQueue($T)) -> T

 SPEC DECISIONS (the contract these tests pin down):

 1. FIFO. Items come out in the order they went in. With multiple producers,
    each producer's own items stay in that producer's push order (a pop stream
    is an interleaving of per-producer sequences, never a reordering of one).

 2. pop BLOCKS on empty — indefinitely, zero CPU. No try_pop, no timeout, not
    until something upstream demands one.

 3. Thread-safe for any number of producers and consumers.

 4. MEMORY: the queue owns its nodes. push allocates a node, pop frees it,
    destroy frees whatever is still queued (plus the list and the queue).
    All node alloc/free MUST go through the allocator captured at
    new_blocking_queue time — NOT the calling thread's context.allocator.
    Why: push runs on producer threads, pop on consumer threads, and each
    thread has its own context. If nodes were allocated from whatever context
    the caller has, the test runner's tracking allocator would see allocs
    without frees (or worse, be handed pointers it never allocated).
    mem.Tracking_Allocator locks internally, so sharing the captured
    allocator across threads is safe.

 5. destroy contract: the caller guarantees no thread is inside push or pop
    when destroy runs. Waking blocked consumers at shutdown is the DISK
    SCHEDULER's problem (its shutdown protocol), not the queue's. Every test
    here joins its helper threads before destroy fires.

 6. TIMING: tests that assert "still blocked" give the OS a few ms of sleep
    and then check a flag. A pathologically loaded machine could false-fail
    one of these; a rerun that passes is fine. A *consistent* failure is
    never the machine.

 Helper threads are spawned with the test's own context (the third argument
 to thread.create_and_start_with_poly_data) so assertions and any incidental
 allocations on those threads stay inside the test harness's world.

 LADDER GATE: everything below the gate comment is inactive. Move the
 opening marker down as you go, one test at a time.
================================================================================
*/

import "core:testing"
import "core:thread"
import "core:time"
import "core:sync"

// ---------------------------------------------------------------------------
// Rung 1 — single-threaded correctness. No concurrency, just a queue.
// ---------------------------------------------------------------------------

@(test)
test_01_push_pop_single_thread :: proc(t: ^testing.T) {
	q := new_blocking_queue(int)
	defer destroy_blocking_queue(q)

	push(q, 42)
	testing.expect_value(t, pop(q), 42)
}

@(test)
test_02_fifo_order :: proc(t: ^testing.T) {
	q := new_blocking_queue(int)
	defer destroy_blocking_queue(q)

	for i in 1 ..= 5 {
		push(q, i)
	}
	for i in 1 ..= 5 {
		testing.expect_value(t, pop(q), i)
	}
}

// ═══════════════════════════════ LADDER GATE ═══════════════════════════════
// Move this opening marker below the next test to activate it.


// ---------------------------------------------------------------------------
// Shared helpers for the threaded rungs.
// ---------------------------------------------------------------------------

Consumer_State :: struct {
	q:    ^BlockingQueue(int),
	got:  int,
	done: bool, // read/written with sync.atomic_*
}

_consume_one :: proc(s: ^Consumer_State) {
	v := pop(s.q)
	s.got = v
	sync.atomic_store(&s.done, true)
}

Producer_State :: struct {
	q:     ^BlockingQueue(int),
	start: int,
	count: int,
}

_produce_range :: proc(p: ^Producer_State) {
	for i in 0 ..< p.count {
		push(p.q, p.start + i)
		if i % 10 == 0 {
			// brief stall so the consumer drains us dry and has to re-block —
			// forces the empty->blocked->woken path, not just the fast path
			time.sleep(time.Millisecond)
		}
	}
}

Drain_State :: struct {
	q:    ^BlockingQueue(int),
	take: int,
	got:  [64]int,
	n:    int,
}

_drain_n :: proc(s: ^Drain_State) {
	for s.n < s.take {
		s.got[s.n] = pop(s.q)
		s.n += 1
	}
}

Discard_State :: struct {
	q:    ^BlockingQueue(int),
	take: int,
}

_drain_discard :: proc(s: ^Discard_State) {
	for _ in 0 ..< s.take {
		_ = pop(s.q)
	}
}

// ---------------------------------------------------------------------------
// Rung 2 — one producer, one consumer. The sleep/wake machinery.
// ---------------------------------------------------------------------------

@(test)
test_03_push_wakes_blocked_pop :: proc(t: ^testing.T) {
	q := new_blocking_queue(int)
	defer destroy_blocking_queue(q)

	s := Consumer_State{q = q}
	th := thread.create_and_start_with_poly_data(&s, _consume_one, context)
	defer thread.destroy(th)

	time.sleep(20 * time.Millisecond) // let the consumer reach pop and go to sleep
	push(q, 7)
	thread.join(th)

	testing.expect_value(t, s.got, 7)
}

@(test)
test_04_pop_blocks_on_empty :: proc(t: ^testing.T) {
	q := new_blocking_queue(int)
	defer destroy_blocking_queue(q)

	s := Consumer_State{q = q}
	th := thread.create_and_start_with_poly_data(&s, _consume_one, context)
	defer thread.destroy(th)

	time.sleep(30 * time.Millisecond)
	// nothing has been pushed: the consumer must still be asleep inside pop.
	// If this fires, pop returned garbage from an empty queue.
	testing.expect(t, !sync.atomic_load(&s.done), "pop returned on an empty queue")

	push(q, 1) // release it so the test can finish
	thread.join(th)
	testing.expect_value(t, s.got, 1)
}

@(test)
test_05_streaming_producer :: proc(t: ^testing.T) {
	q := new_blocking_queue(int)
	defer destroy_blocking_queue(q)

	p := Producer_State{q = q, start = 0, count = 100}
	th := thread.create_and_start_with_poly_data(&p, _produce_range, context)
	defer thread.destroy(th)

	// the producer stalls periodically, so this loop crosses the
	// empty/non-empty boundary many times. Order must survive every crossing.
	for i in 0 ..< 100 {
		testing.expect_value(t, pop(q), i)
	}
	thread.join(th)
}

// ---------------------------------------------------------------------------
// Rung 3 — many threads on one queue.
// ---------------------------------------------------------------------------

@(test)
test_06_multi_producer :: proc(t: ^testing.T) {
	q := new_blocking_queue(int)
	defer destroy_blocking_queue(q)

	N_PRODUCERS :: 4
	PER :: 50

	producers: [N_PRODUCERS]Producer_State
	threads: [N_PRODUCERS]^thread.Thread
	for k in 0 ..< N_PRODUCERS {
		// producer k pushes k-tagged values: (k+1)*1000 + 0 .. (k+1)*1000 + 49
		producers[k] = Producer_State{q = q, start = (k + 1) * 1000, count = PER}
		threads[k] = thread.create_and_start_with_poly_data(&producers[k], _produce_range, context)
	}
	defer for th in threads {
		thread.destroy(th)
	}

	// global interleaving is scheduler-dependent, but each producer's own
	// values must arrive in increasing order (FIFO per producer).
	last_seen: [N_PRODUCERS]int
	for k in 0 ..< N_PRODUCERS {
		last_seen[k] = -1
	}
	for _ in 0 ..< N_PRODUCERS * PER {
		v := pop(q)
		k := v / 1000 - 1
		seq := v % 1000
		testing.expect(t, k >= 0 && k < N_PRODUCERS, "value from unknown producer")
		testing.expect(t, seq > last_seen[k], "per-producer FIFO order violated")
		last_seen[k] = seq
	}
	for th in threads {
		thread.join(th)
	}
	for k in 0 ..< N_PRODUCERS {
		testing.expect_value(t, last_seen[k], PER - 1) // nothing lost, nothing duplicated
	}
}

@(test)
test_07_two_consumers_share_the_stream :: proc(t: ^testing.T) {
	q := new_blocking_queue(int)
	defer destroy_blocking_queue(q)

	TOTAL :: 60
	a := Drain_State{q = q, take = TOTAL / 2}
	b := Drain_State{q = q, take = TOTAL / 2}
	ta := thread.create_and_start_with_poly_data(&a, _drain_n, context)
	tb := thread.create_and_start_with_poly_data(&b, _drain_n, context)
	defer {
		thread.destroy(ta)
		thread.destroy(tb)
	}

	for i in 0 ..< TOTAL {
		push(q, i)
	}
	thread.join(ta)
	thread.join(tb)

	// every value delivered exactly once, across the two consumers combined
	seen: [TOTAL]bool
	for i in 0 ..< a.n {
		v := a.got[i]
		testing.expect(t, !seen[v], "value delivered twice")
		seen[v] = true
	}
	for i in 0 ..< b.n {
		v := b.got[i]
		testing.expect(t, !seen[v], "value delivered twice")
		seen[v] = true
	}
	for i in 0 ..< TOTAL {
		testing.expect(t, seen[i], "value lost")
	}

	// pops are serialized by the mutex and the queue is FIFO, so each
	// consumer's personal stream must also be increasing
	for i in 1 ..< a.n {
		testing.expect(t, a.got[i] > a.got[i - 1], "consumer A saw out-of-order values")
	}
	for i in 1 ..< b.n {
		testing.expect(t, b.got[i] > b.got[i - 1], "consumer B saw out-of-order values")
	}
}

// ---------------------------------------------------------------------------
// Corner cases — each aims at one specific implementation mistake.
// ---------------------------------------------------------------------------

@(test)
test_c1_stress_cross_thread_memory :: proc(t: ^testing.T) {
	// TARGET: spec decision 4. 1600 nodes allocated on 8 producer threads,
	// freed on 2 consumer threads. The assertion here is really the leak
	// tracker's: if node memory doesn't go through the queue's captured
	// allocator, this test leaks (or crashes) even though every value moves
	// through correctly.
	q := new_blocking_queue(int)
	defer destroy_blocking_queue(q)

	N_PRODUCERS :: 8
	PER :: 200

	producers: [N_PRODUCERS]Producer_State
	pthreads: [N_PRODUCERS]^thread.Thread
	for k in 0 ..< N_PRODUCERS {
		producers[k] = Producer_State{q = q, start = (k + 1) * 1000, count = PER}
		pthreads[k] = thread.create_and_start_with_poly_data(&producers[k], _produce_range, context)
	}

	a := Discard_State{q = q, take = N_PRODUCERS * PER / 2}
	b := Discard_State{q = q, take = N_PRODUCERS * PER / 2}
	ca := thread.create_and_start_with_poly_data(&a, _drain_discard, context)
	cb := thread.create_and_start_with_poly_data(&b, _drain_discard, context)

	for th in pthreads {
		thread.join(th)
	}
	thread.join(ca)
	thread.join(cb)

	for th in pthreads {
		thread.destroy(th)
	}
	thread.destroy(ca)
	thread.destroy(cb)
}

@(test)
test_c2_one_item_wakes_exactly_one_consumer :: proc(t: ^testing.T) {
	// TARGET: the `if`-instead-of-`for` wait loop (and broadcast-happy
	// signaling). Two consumers asleep, ONE item arrives. Exactly one
	// consumer may return; the other must re-check, find the list empty,
	// and go back to sleep. An `if` implementation lets the second wake
	// straight through cond_wait into popping an empty list.
	q := new_blocking_queue(int)
	defer destroy_blocking_queue(q)

	a := Consumer_State{q = q}
	b := Consumer_State{q = q}
	ta := thread.create_and_start_with_poly_data(&a, _consume_one, context)
	tb := thread.create_and_start_with_poly_data(&b, _consume_one, context)
	defer {
		thread.destroy(ta)
		thread.destroy(tb)
	}

	time.sleep(20 * time.Millisecond) // both blocked in pop
	push(q, 1)
	time.sleep(30 * time.Millisecond) // let whoever woke finish

	a_done := sync.atomic_load(&a.done)
	b_done := sync.atomic_load(&b.done)
	testing.expect(t, a_done != b_done, "exactly one consumer should have returned (0 = lost wakeup, 2 = popped empty)")

	push(q, 2) // release the survivor
	thread.join(ta)
	thread.join(tb)
	testing.expect_value(t, a.got + b.got, 3) // one took 1, the other took 2
}

@(test)
test_c3_destroy_frees_queued_items :: proc(t: ^testing.T) {
	// TARGET: destroy that frees the list header but strands queued nodes.
	// Three items are still enqueued when destroy runs. No expects here —
	// the leak tracker fails this test if those nodes (or the list, or the
	// queue) survive.
	q := new_blocking_queue(int)
	for i in 0 ..< 5 {
		push(q, i)
	}
	_ = pop(q)
	_ = pop(q)
	destroy_blocking_queue(q)
}

@(test)
test_c4_signal_with_no_waiter_still_delivers :: proc(t: ^testing.T) {
	// TARGET: designs that trust the signal instead of the data. Push #2's
	// wakeup fires while the consumer is awake processing push #1 — nobody
	// is sleeping, so the condvar discards it. The ITEM must not be lost:
	// the consumer's next pop has to check the list before ever sleeping.
	// (This is the condvar-vs-semaphore lesson, embodied.)
	q := new_blocking_queue(int)
	defer destroy_blocking_queue(q)

	s := Drain_State{q = q, take = 2}
	th := thread.create_and_start_with_poly_data(&s, _drain_n, context)
	defer thread.destroy(th)

	time.sleep(20 * time.Millisecond) // consumer blocked
	push(q, 10)
	push(q, 20) // no gap: lands while the consumer is between wakeup and next pop
	thread.join(th)

	testing.expect_value(t, s.n, 2)
	testing.expect_value(t, s.got[0], 10)
	testing.expect_value(t, s.got[1], 20)
}

@(test)
test_c5_workers_cannot_use_context_allocator :: proc(t: ^testing.T) {
	// TARGET: spec decision 4, sharper than c1. Queue is created under the
	// test harness allocator. Workers run with panic_allocator as
	// context.allocator — so any node new/free that ignores q.allocator dies.
	// Pass criteria: no panic + leak tracker clean after destroy.
	q := new_blocking_queue(int)
	defer destroy_blocking_queue(q)

	worker_ctx := context
	worker_ctx.allocator = mem.panic_allocator()

	N_PRODUCERS :: 4
	PER :: 100

	producers: [N_PRODUCERS]Producer_State
	pthreads: [N_PRODUCERS]^thread.Thread
	for k in 0 ..< N_PRODUCERS {
		producers[k] = Producer_State{
			q = q,
			start = (k + 1) * 1000,
			count = PER,
		}
		pthreads[k] = thread.create_and_start_with_poly_data(
			&producers[k],
			_produce_range,
			worker_ctx,
		)
	}

	TOTAL :: N_PRODUCERS * PER
	a := Discard_State{q = q, take = TOTAL / 2}
	b := Discard_State{q = q, take = TOTAL / 2}
	ca := thread.create_and_start_with_poly_data(&a, _drain_discard, worker_ctx)
	cb := thread.create_and_start_with_poly_data(&b, _drain_discard, worker_ctx)

	for th in pthreads {
		thread.join(th)
	}
	thread.join(ca)
	thread.join(cb)

	for th in pthreads {
		thread.destroy(th)
	}
	thread.destroy(ca)
	thread.destroy(cb)
}

@(test)
test_c6_consumers_reblock_after_drain :: proc(t: ^testing.T) {
	// TARGET: after a wake/drain round, the next pop on empty must wait again.
	// A broken loop (or "stayed runnable") shows up as done==true with no push,
	// or as more than one consumer finishing on a single push.
	q := new_blocking_queue(int)
	defer destroy_blocking_queue(q)

	N :: 3

	// --- round 1: fill exactly N waiters ---
	c1: [N]Consumer_State
	t1: [N]^thread.Thread
	for i in 0 ..< N {
		c1[i] = Consumer_State{q = q}
		t1[i] = thread.create_and_start_with_poly_data(&c1[i], _consume_one, context)
	}
	defer for th in t1 { thread.destroy(th) }

	time.sleep(20 * time.Millisecond)
	for i in 0 ..< N {
		push(q, i + 1)
	}
	for th in t1 { thread.join(th) }

	seen: [N + 1]bool // 1..=N
	for i in 0 ..< N {
		v := c1[i].got
		testing.expect(t, v >= 1 && v <= N)
		testing.expect(t, !seen[v], "duplicate in round 1")
		seen[v] = true
	}

	// --- round 2: queue is empty; new waiters must block ---
	c2: [N]Consumer_State
	t2: [N]^thread.Thread
	for i in 0 ..< N {
		c2[i] = Consumer_State{q = q}
		t2[i] = thread.create_and_start_with_poly_data(&c2[i], _consume_one, context)
	}
	defer for th in t2 { thread.destroy(th) }

	time.sleep(30 * time.Millisecond)
	for i in 0 ..< N {
		testing.expect(t, !sync.atomic_load(&c2[i].done),
			"consumer returned on empty queue after prior drain")
	}

	push(q, 100)
	time.sleep(30 * time.Millisecond)

	finished := 0
	for i in 0 ..< N {
		if sync.atomic_load(&c2[i].done) {
			finished += 1
			testing.expect_value(t, c2[i].got, 100)
		}
	}
	testing.expect_value(t, finished, 1)

	// release the rest
	for i in 0 ..< N - 1 {
		push(q, 200 + i)
	}
	for th in t2 { thread.join(th) }
}

_produce_range_nosleep :: proc(p: ^Producer_State) {
	for i in 0 ..< p.count {
		push(p.q, p.start + i)
	}
}

@(test)
test_c7_pure_race_no_producer_sleep :: proc(t: ^testing.T) {
	q := new_blocking_queue(int)
	defer destroy_blocking_queue(q)

	N_PRODUCERS :: 8
	PER :: 500

	producers: [N_PRODUCERS]Producer_State
	threads: [N_PRODUCERS]^thread.Thread
	for k in 0 ..< N_PRODUCERS {
		producers[k] = Producer_State{
			q = q,
			start = (k + 1) * 1000,
			count = PER,
		}
		threads[k] = thread.create_and_start_with_poly_data(
			&producers[k],
			_produce_range_nosleep,
			context,
		)
	}
	defer for th in threads { thread.destroy(th) }

	last_seen: [N_PRODUCERS]int
	for k in 0 ..< N_PRODUCERS {
		last_seen[k] = -1
	}

	for _ in 0 ..< N_PRODUCERS * PER {
		v := pop(q)
		k := v / 1000 - 1
		seq := v % 1000
		testing.expect(t, k >= 0 && k < N_PRODUCERS)
		testing.expect(t, seq > last_seen[k], "per-producer FIFO violated under race")
		last_seen[k] = seq
	}

	for th in threads { thread.join(th) }
	for k in 0 ..< N_PRODUCERS {
		testing.expect_value(t, last_seen[k], PER - 1)
	}
}
/*
*/
