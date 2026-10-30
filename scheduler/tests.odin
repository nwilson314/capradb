package scheduler

import "core:os"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import "../disk"
import pg "../page"

/*
================================================================================
 DISK SCHEDULER — TEST LADDER
================================================================================

 Interface under test (your scheduler.odin must provide):

   Completion :: struct {
       mutex: sync.Mutex,
       cond:  sync.Cond,
       done:  bool,
       ok:    bool,
   }
   complete :: proc(c: ^Completion, ok: bool)
   wait     :: proc(c: ^Completion) -> bool

   Disk_Request :: struct {
       is_write: bool,
       page_id:  u32,
       buf:      ^pg.Page,     // read: filled by the worker. write: written out.
       done:     ^Completion,
   }

   Disk_Scheduler :: struct { ... }   // yours
   new_disk_scheduler     :: proc(dm: ^disk.DiskManager) -> ^Disk_Scheduler
   destroy_disk_scheduler :: proc(s: ^Disk_Scheduler)
   schedule               :: proc(s: ^Disk_Scheduler, req: Disk_Request)

 SPEC DECISIONS (the contract these tests pin down):

 1. COMPLETION. A zero-valued Completion is ready to use: no constructor.
    It is one-shot: complete is called exactly once per Completion.
    wait blocks until complete has run, then returns the ok it was given.
    If complete already ran, wait returns immediately (never sleeps).
    Any number of threads may wait on one Completion; complete wakes all.

 2. OWNERSHIP. The CALLER owns the Completion and the buf. Both usually live
    on the caller's stack. They must stay valid until the caller's wait
    returns. The scheduler never allocates or frees either one. The worker's
    LAST touch of a request is the complete call. After that, the caller may
    already have returned, taking both with it.

 3. REQUESTS. schedule enqueues and returns at once. It never waits on I/O.
    The request is copied into the queue by value; that is safe because the
    Completion and buf travel as POINTERS (copying a Completion itself would
    split it into two objects; see guide ch06, "The copied completion").
      - read:  on success, buf^ holds the page (id and data). On failure,
               buf's contents are unspecified.
      - write: buf.id == page_id (the caller's job). The bytes must not change
               until wait returns.

 4. ORDER. One worker thread, FIFO. Requests run in the order scheduled, so
    two requests for the same page never pass each other.

 5. FAILURE. If the disk manager says no, the worker calls complete(c, false)
    and moves on to the next request. It does not stop, and it does not skip
    the complete call.

 6. SHUTDOWN. destroy_disk_scheduler DRAINS: every request scheduled before
    destroy is performed and completed. Then the worker exits, destroy joins
    it, and frees everything the scheduler allocated. destroy does NOT close
    the disk manager; the caller does that afterwards. Calling schedule during
    or after destroy is a caller bug, and the behaviour is undefined.

 7. DISK MANAGER THREADING. While a scheduler exists, only its worker thread
    touches the disk manager. The tests allocate pages BEFORE creating the
    scheduler and inspect the file only AFTER destroying it.

 8. HANGS. A broken shutdown or broken wakeup usually HANGS a test instead of
    failing it. If a run hangs: Ctrl-C, then run the one test alone with
      -define:ODIN_TEST_NAMES=scheduler.<test_name> -define:ODIN_TEST_FANCY=false
    and work out which thread is asleep and on which line.

 LADDER GATE: everything below the gate comment is inactive. Move the
 opening marker down as you go, one test at a time.
================================================================================
*/

// ---------------------------------------------------------------------------
// Rung 1 — Completion on its own. No scheduler, no disk.
// ---------------------------------------------------------------------------

@(test)
test_01_complete_then_wait :: proc(t: ^testing.T) {
	// Case B: complete runs first. wait must see `done` and return without
	// ever sleeping. A wait that sleeps unconditionally hangs here.
	c: Completion
	complete(&c, true)
	testing.expect_value(t, wait(&c), true)
}

// ═══════════════════════════════ LADDER GATE ═══════════════════════════════
// Move this opening marker below the next test to activate it.

@(test)
test_02_complete_carries_failure :: proc(t: ^testing.T) {
	c: Completion
	complete(&c, false)
	testing.expect_value(t, wait(&c), false)
}

Waiter_State :: struct {
	c:        ^Completion,
	got:      bool,
	returned: bool, // read/written with sync.atomic_*
}

_wait_on :: proc(w: ^Waiter_State) {
	w.got = wait(w.c)
	sync.atomic_store(&w.returned, true)
}

@(test)
test_03_wait_then_complete :: proc(t: ^testing.T) {
	// Case A: the waiter gets there first and must sleep until complete.
	c: Completion
	w := Waiter_State{c = &c}
	th := thread.create_and_start_with_poly_data(&w, _wait_on, context)
	defer thread.destroy(th)

	time.sleep(20 * time.Millisecond)
	testing.expect(t, !sync.atomic_load(&w.returned), "wait returned before complete was called")

	complete(&c, true)
	thread.join(th)
	testing.expect_value(t, w.got, true)
}

// ---------------------------------------------------------------------------
// Shared helpers for the scheduler rungs.
// ---------------------------------------------------------------------------

// Creates a fresh database file with n_pages allocated (page ids 1..=n_pages).
_fresh_db :: proc(path: string, n_pages: int) -> ^disk.DiskManager {
	os.remove(path)
	dm := disk.new_disk_manager(path)
	for _ in 0 ..< n_pages {
		_ = disk.allocate_page(dm)
	}
	return dm
}

_close_db :: proc(dm: ^disk.DiskManager, path: string) {
	disk.close_disk_manager(dm)
	os.remove(path)
}

// Fills a page with a byte pattern unique to (id, seed).
_fill :: proc(p: ^pg.Page, id: u32, seed: u8) {
	p.id = id
	for i in 0 ..< pg.PAGE_SIZE {
		p.data[i] = seed + u8(i % 251) + u8(id)
	}
}

_same_bytes :: proc(a, b: ^pg.Page) -> bool {
	return a.data == b.data
}

// ---------------------------------------------------------------------------
// Rung 2 — lifecycle. The worker exists, sleeps, and can be stopped.
// ---------------------------------------------------------------------------

@(test)
test_04_create_and_destroy_idle :: proc(t: ^testing.T) {
	// The worker starts, finds an empty queue, and goes to sleep in pop.
	// destroy has to WAKE it so it can exit. If destroy only sets a flag,
	// this test hangs in join. Leak tracker checks that destroy frees
	// everything new allocated.
	path := "/tmp/capradb_sched_04.db"
	dm := _fresh_db(path, 0)
	defer _close_db(dm, path)

	s := new_disk_scheduler(dm)
	time.sleep(10 * time.Millisecond) // let the worker reach pop and sleep
	destroy_disk_scheduler(s)
}

// ---------------------------------------------------------------------------
// Rung 3 — one caller, real I/O.
// ---------------------------------------------------------------------------

@(test)
test_05_read :: proc(t: ^testing.T) {
	// Read path alone: the page is written straight through the disk manager
	// before the scheduler exists, then read back through the scheduler.
	path := "/tmp/capradb_sched_05.db"
	dm := _fresh_db(path, 1)
	defer _close_db(dm, path)

	want: pg.Page
	_fill(&want, 1, 7)
	disk.write_page(dm, &want)

	s := new_disk_scheduler(dm)
	defer destroy_disk_scheduler(s)

	got: pg.Page
	c: Completion
	schedule(s, Disk_Request{is_write = false, page_id = 1, buf = &got, done = &c})
	testing.expect_value(t, wait(&c), true)
	testing.expect_value(t, got.id, u32(1))
	testing.expect(t, _same_bytes(&got, &want), "read returned the wrong bytes")
}


@(test)
test_06_write :: proc(t: ^testing.T) {
	// Write path alone: written through the scheduler, checked straight
	// through the disk manager after the scheduler is gone.
	path := "/tmp/capradb_sched_06.db"
	dm := _fresh_db(path, 1)
	defer _close_db(dm, path)

	s := new_disk_scheduler(dm)

	buf: pg.Page
	_fill(&buf, 1, 42)
	c: Completion
	schedule(s, Disk_Request{is_write = true, page_id = 1, buf = &buf, done = &c})
	testing.expect_value(t, wait(&c), true)

	destroy_disk_scheduler(s)

	on_disk, ok := disk.read_page(dm, 1)
	testing.expect(t, ok)
	testing.expect(t, _same_bytes(&on_disk, &buf), "write did not reach the file")
}

@(test)
test_07_write_then_read_roundtrip :: proc(t: ^testing.T) {
	path := "/tmp/capradb_sched_07.db"
	dm := _fresh_db(path, 3)
	defer _close_db(dm, path)

	s := new_disk_scheduler(dm)
	defer destroy_disk_scheduler(s)

	for id in u32(1) ..= 3 {
		out: pg.Page
		_fill(&out, id, 99)
		cw: Completion
		schedule(s, Disk_Request{is_write = true, page_id = id, buf = &out, done = &cw})
		testing.expect_value(t, wait(&cw), true)

		back: pg.Page
		cr: Completion
		schedule(s, Disk_Request{is_write = false, page_id = id, buf = &back, done = &cr})
		testing.expect_value(t, wait(&cr), true)
		testing.expect(t, _same_bytes(&back, &out), "roundtrip changed the bytes")
	}
}

@(test)
test_08_many_in_flight_from_one_caller :: proc(t: ^testing.T) {
	// The flush_all pattern: schedule everything, THEN wait for everything.
	// Each request needs its own Completion and its own buf, alive until
	// its wait returns.
	path := "/tmp/capradb_sched_08.db"
	N :: 20
	dm := _fresh_db(path, N)
	defer _close_db(dm, path)

	s := new_disk_scheduler(dm)

	bufs: [N]pg.Page
	cs: [N]Completion
	for i in 0 ..< N {
		id := u32(i + 1)
		_fill(&bufs[i], id, 3)
		schedule(s, Disk_Request{is_write = true, page_id = id, buf = &bufs[i], done = &cs[i]})
	}
	for i in 0 ..< N {
		testing.expect_value(t, wait(&cs[i]), true)
	}

	destroy_disk_scheduler(s)

	for i in 0 ..< N {
		on_disk, ok := disk.read_page(dm, u32(i + 1))
		testing.expect(t, ok)
		testing.expect(t, _same_bytes(&on_disk, &bufs[i]), "a batched write did not reach the file")
	}
}

@(test)
test_09_same_page_never_reorders :: proc(t: ^testing.T) {
	// SPEC 4. write(A), write(B), read: all scheduled back to back, no
	// waiting in between. The read must see B, the last write before it.
	path := "/tmp/capradb_sched_09.db"
	dm := _fresh_db(path, 1)
	defer _close_db(dm, path)

	s := new_disk_scheduler(dm)
	defer destroy_disk_scheduler(s)

	a, b, got: pg.Page
	_fill(&a, 1, 10)
	_fill(&b, 1, 20)
	ca, cb, cr: Completion
	schedule(s, Disk_Request{is_write = true, page_id = 1, buf = &a, done = &ca})
	schedule(s, Disk_Request{is_write = true, page_id = 1, buf = &b, done = &cb})
	schedule(s, Disk_Request{is_write = false, page_id = 1, buf = &got, done = &cr})

	testing.expect_value(t, wait(&cr), true)
	testing.expect_value(t, wait(&ca), true)
	testing.expect_value(t, wait(&cb), true)
	testing.expect(t, _same_bytes(&got, &b), "read overtook a write, or the writes swapped")
}

// ---------------------------------------------------------------------------
// Rung 4 — many callers at once.
// ---------------------------------------------------------------------------

Caller_State :: struct {
	s:          ^Disk_Scheduler,
	first_page: u32,
	n_pages:    u32,
	rounds:     int,
	failures:   int,
}

_write_read_loop :: proc(cs: ^Caller_State) {
	for round in 0 ..< cs.rounds {
		for id in cs.first_page ..< cs.first_page + cs.n_pages {
			out: pg.Page
			_fill(&out, id, u8(round))
			cw: Completion
			schedule(cs.s, Disk_Request{is_write = true, page_id = id, buf = &out, done = &cw})
			if !wait(&cw) {
				cs.failures += 1
			}

			back: pg.Page
			cr: Completion
			schedule(cs.s, Disk_Request{is_write = false, page_id = id, buf = &back, done = &cr})
			if !wait(&cr) || !_same_bytes(&back, &out) {
				cs.failures += 1
			}
		}
	}
}

@(test)
test_10_concurrent_callers :: proc(t: ^testing.T) {
	// Each caller owns a disjoint range of pages and checks its own
	// roundtrips. Completions and bufs live on each caller thread's stack.
	path := "/tmp/capradb_sched_10.db"
	N_CALLERS :: 4
	PER :: 10
	dm := _fresh_db(path, N_CALLERS * PER)
	defer _close_db(dm, path)

	s := new_disk_scheduler(dm)
	defer destroy_disk_scheduler(s)

	callers: [N_CALLERS]Caller_State
	threads: [N_CALLERS]^thread.Thread
	for k in 0 ..< N_CALLERS {
		callers[k] = Caller_State{s = s, first_page = u32(k * PER + 1), n_pages = PER, rounds = 5}
		threads[k] = thread.create_and_start_with_poly_data(&callers[k], _write_read_loop, context)
	}
	for th in threads {
		thread.join(th)
		thread.destroy(th)
	}
	for k in 0 ..< N_CALLERS {
		testing.expect_value(t, callers[k].failures, 0)
	}
}

// ---------------------------------------------------------------------------
// Corner cases — each aims at one specific implementation mistake.
// ---------------------------------------------------------------------------

@(test)
test_c1_failed_io_still_completes_and_worker_survives :: proc(t: ^testing.T) {
	// TARGET: SPEC 5. An error path that skips complete hangs the caller.
	// A worker that returns on error hangs every later caller. Page 99
	// doesn't exist, page 0 is the metadata page: both reads fail.
	path := "/tmp/capradb_sched_c1.db"
	dm := _fresh_db(path, 1)
	defer _close_db(dm, path)

	s := new_disk_scheduler(dm)
	defer destroy_disk_scheduler(s)

	junk: pg.Page
	c_missing, c_meta: Completion
	schedule(s, Disk_Request{is_write = false, page_id = 99, buf = &junk, done = &c_missing})
	schedule(s, Disk_Request{is_write = false, page_id = 0, buf = &junk, done = &c_meta})
	testing.expect_value(t, wait(&c_missing), false)
	testing.expect_value(t, wait(&c_meta), false)

	// the worker must still be alive and serving
	good: pg.Page
	c_good: Completion
	schedule(s, Disk_Request{is_write = false, page_id = 1, buf = &good, done = &c_good})
	testing.expect_value(t, wait(&c_good), true)
}

@(test)
test_c2_destroy_drains_the_queue :: proc(t: ^testing.T) {
	// TARGET: SPEC 6. 500 writes are queued and NOBODY waits before destroy.
	// A shutdown that jumps the line (a stop flag the worker checks before
	// popping, or a stop message that skips ahead) drops the tail. Every
	// request must be completed with ok=true, and its bytes must be on disk.
	// Reads c.done directly. That's safe because destroy joined the worker.
	path := "/tmp/capradb_sched_c2.db"
	N :: 500 // big enough that the queue is still backed up when destroy runs
	dm := _fresh_db(path, N)
	defer _close_db(dm, path)

	s := new_disk_scheduler(dm)

	bufs := make([]pg.Page, N) // 2 MB: too big for a test thread's stack
	defer delete(bufs)
	cs := make([]Completion, N)
	defer delete(cs)

	for i in 0 ..< N {
		_fill(&bufs[i], u32(i + 1), 55)
	}
	// schedule in a tight loop (pushes are far faster than writes), then
	// destroy immediately: most of these are still queued at that moment
	for i in 0 ..< N {
		schedule(s, Disk_Request{is_write = true, page_id = u32(i + 1), buf = &bufs[i], done = &cs[i]})
	}
	destroy_disk_scheduler(s)

	never_completed, failed, not_on_disk := 0, 0, 0
	for i in 0 ..< N {
		if !cs[i].done {
			never_completed += 1
		} else if !cs[i].ok {
			failed += 1
		}
		on_disk, ok := disk.read_page(dm, u32(i + 1))
		if !ok || !_same_bytes(&on_disk, &bufs[i]) {
			not_on_disk += 1
		}
	}
	testing.expect_value(t, never_completed, 0)
	testing.expect_value(t, failed, 0)
	testing.expect_value(t, not_on_disk, 0)
}

@(test)
test_c3_complete_wakes_every_waiter :: proc(t: ^testing.T) {
	// TARGET: SPEC 1, "complete wakes all". Two threads wait on ONE
	// Completion. cond_signal wakes one of them; the other sleeps forever.
	// (Ch05: signal when any one waiter can make progress, broadcast when the
	// change matters to all of them. "It's done" matters to all of them.)
	c: Completion
	a := Waiter_State{c = &c}
	b := Waiter_State{c = &c}
	ta := thread.create_and_start_with_poly_data(&a, _wait_on, context)
	tb := thread.create_and_start_with_poly_data(&b, _wait_on, context)
	defer {
		thread.destroy(ta)
		thread.destroy(tb)
	}

	time.sleep(20 * time.Millisecond) // both asleep in wait
	complete(&c, true)
	time.sleep(30 * time.Millisecond)

	both := sync.atomic_load(&a.returned) && sync.atomic_load(&b.returned)
	testing.expect(t, both, "complete woke only one of two waiters")
	if !both {
		complete(&c, true) // rescue the sleeper so the test can end instead of hanging
	}
	thread.join(ta)
	thread.join(tb)
	testing.expect_value(t, a.got, true)
	testing.expect_value(t, b.got, true)
}
/*
// ---------------------------------------------------------------------------
// c4 — YOURS. Write one test that breaks an implementation this suite would
// still pass. Ideas, if you want a starting point: a request's buf or
// Completion touched after complete (try -sanitize:address); destroy called
// while callers are mid-wait; a write whose bytes change before wait returns.
// ---------------------------------------------------------------------------
*/
@(test)
test_c4_failed_write_still_completes :: proc(t: ^testing.T) {
	path := "/tmp/capradb_sched_c4.db"
	dm := _fresh_db(path, 1)
	defer _close_db(dm, path)

	s := new_disk_scheduler(dm)

	buf: pg.Page
	buf.id = 3
	c: Completion
	schedule(s, Disk_Request{is_write = true, page_id = 3, buf = &buf, done = &c})
	testing.expect_value(t, wait(&c), false)

	destroy_disk_scheduler(s)
}