package bpm

import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import "../disk"
import pg "../page"
import "../utils"

/*
================================================================================
 PAGE GUARDS — TEST LADDER
================================================================================

 Same package as tests.odin, so the helpers there (_fresh_db, _close_db,
 _on_disk, _expected, Stall, _stall_worker, _release_worker) work here. The 29
 BPM tests stay active and must stay green.

 Interface under test:

   Frame :: struct {
       ...
       page_latch: sync.RW_Mutex,   // the tests probe it with try-locks
   }

   Read_Guard  :: struct { page: ^pg.Page, page_id: u32, ... }   // rest is yours
   Write_Guard :: struct { page: ^pg.Page, page_id: u32, ... }

   fetch_page_read  :: proc(bp: ^Buffer_Pool, page_id: u32) -> (Read_Guard, bool)
   fetch_page_write :: proc(bp: ^Buffer_Pool, page_id: u32) -> (Write_Guard, bool)
   new_page_write   :: proc(bp: ^Buffer_Pool) -> (Write_Guard, bool)
   release_read     :: proc(g: ^Read_Guard)
   release_write    :: proc(g: ^Write_Guard)

 SPEC DECISIONS:

 1. WHAT A GUARD IS. A pin, a page latch and the page pointer, undone by one
    release call. A read guard holds the latch shared: any number of readers,
    no writers. A write guard holds it exclusive: one writer, nobody else.
    The latch protects the page's BYTES. The pool latch still protects the
    pool's bookkeeping (page table, pins, dirty flags, free list, replacer).

 2. LOCK ORDER — the answer to the question we skipped. Acquire:
       pool latch: claim or find the frame, pin it, schedule any I/O
       release the pool latch
       wait for the I/O
       take the page latch
    NEVER wait for a page latch while holding the pool latch. Here's the
    deadlock if you do: thread A holds a write guard on page 7 and asks for
    page 8, which is normal (a B+tree holds the parent while it fetches the
    child). A needs the pool latch. Thread B holds the pool latch and is
    waiting for page 7's latch, which A has. Neither can move, and every other
    thread then piles up behind the pool latch. G06 checks this.

 3. RELEASE ORDER. Page latch first, then unpin (under the pool latch). The
    latch belongs to the FRAME. Once the pin reaches 0, the frame can be
    evicted and handed to a different page, and you'd still be holding its
    latch. No test can pause inside release to catch this, so get it right
    by reading it.

 4. DIRTY. release_write always marks the page dirty; release_read never does.
    A write guard that changed nothing costs one extra write, and that's
    accepted. Set the flag under the pool latch, where unpin_page sets it
    today: it's pool bookkeeping, and flush reads it under that latch.

 5. RELEASE IS IDEMPOTENT. Releasing a guard twice, or releasing the zero
    guard a failed fetch returns, does nothing. A second release must not take
    someone else's pin or someone else's share of the latch. DON'T COPY
    GUARDS: the "already released" state lives inside the struct, so a copy
    can release a second time. Pass ^Read_Guard / ^Write_Guard around.

 6. FAILED FETCH. Returns ({}, false) and takes no latch. Pool cleanup is
    unchanged (BPM spec 4).

 7. FLUSH. flush_page clears the dirty flag and pins under the pool latch (as
    now), releases the pool latch, takes the page latch SHARED, schedules the
    write, waits for it, then unlatches and unpins. Two reasons for the latch:
    a writer mid-change would otherwise reach disk half-written, and holding it
    until the write finishes stops a writer changing the bytes the queued
    write points at. Shared, not exclusive, because a flush only reads. A
    writer who finishes after the flag was cleared marks it dirty again on
    release, so nothing is lost.

 8. FLUSH_ALL holds AT MOST ONE page latch at a time: latch, write, wait,
    unlatch, then the next page. If it held page 2's latch while waiting for
    page 1, a writer holding page 1 and asking for page 2 would deadlock with
    it. Same rule as 2: never wait for a latch while holding another lock
    someone else needs.

 9. EVICTION TAKES NO PAGE LATCH. A victim has pin count 0, so no guard is on
    it, and a frame being flushed is pinned. Nothing to wait for.

 10. NEVER RESET A FRAME WHOLESALE (f^ = {}). That would wipe page_latch
    while someone may hold it or be queued on it. Reset fields one by one, as
    bpm.odin does now.

 11. THE RAW API GOES PRIVATE. fetch_page / new_page / unpin_page stay, for
    the old ladder and as building blocks for the guard procs. Once the guards
    work, mark them @(private): tests in package bpm can still call them, but
    any other package gets "not exported by 'bpm'", so guards are the only way
    in from outside. bench/main.odin then has to move to guards, which it needs
    anyway to measure them. Odin has no private struct fields, so this hides
    procedures, not data. BPM spec 12 ("two threads modifying one page") is
    now covered.

 12. RAII. Explicit `defer release_read(&g)`. @(deferred_out) would release at
    the end of the calling scope, and a guard sometimes has to outlive that:
    a B+tree descent releases the parent's guard partway through a loop.

 13. HANGS. G06–G09 run the dangerous part on a helper thread with a timeout,
    so a deadlock shows up as a failure message, not a hang. If anything else
    hangs, run it alone (BPM spec 13) and name the thread that should wake
    the sleeper.

 14. MAY PASS ON ARRIVAL. G06 and G08 check that you avoided a specific
    mistake. If your code from the rung before already avoids it, they pass
    with no changes. That's expected: read the test and confirm you know why.
    G10 is the stress test and should pass once G01–G09 do.

 15. A FAILED FLUSH LEAVES THE PAGE DIRTY. The flag is still cleared before
    the write (spec 7), but if the write fails, set it again under the pool
    latch. Otherwise the pool believes disk has the change, and the next
    eviction drops the only copy. G11.

 16. "FLUSH RETURNED TRUE" MEANS THE BYTES WERE WRITTEN. A flush that finds a
    write of the same frame already in flight waits for that write, then
    looks again (the page may be dirty again by then, or gone). It must not
    see the cleared flag and return true while the bytes are still queued.
    One way: a "write in flight" flag in the frame, plus a sync.Cond that
    waits on the pool latch, so the waiter sleeps without holding it. G12.

 17. NEVER FLUSH A PAGE YOU HOLD A GUARD ON. flush_page takes the frame latch
    shared. Holding a write guard, you'd wait for yourself. Holding a read
    guard, your second share queues behind any writer waiting in between, and
    that writer waits for your first share. Put this rule in the lock-order
    comment at the top of bpm.odin. Callers above the pool don't flush
    specific pages; eviction and (later) checkpoints do.

 G11 and G12 came from an outside probe (2026-11-11) and were folded in here.

 Assessment 5's asks apply here: mutex_guard (or defer) wherever a proc has
 several exits, the lock order written at the top of bpm.odin in your own
 words, and one adversarial test of your own (gc1, below) before I probe.

 FILE LAYOUT. Everything goes in bpm.odin, guards included: the public API
 lives in one file, and @(private) (spec 11), not the file split, marks
 what's internal.
================================================================================
*/

// ---------------------------------------------------------------------------
// Helpers.
// ---------------------------------------------------------------------------

_frame_of :: proc(bp: ^Buffer_Pool, page_id: u32) -> ^Frame {
	sync.mutex_lock(&bp.latch)
	defer sync.mutex_unlock(&bp.latch)
	fi, ok := bp.page_table[page_id]
	if !ok do return nil
	return &bp.frames[fi]
}

_is_dirty :: proc(bp: ^Buffer_Pool, page_id: u32) -> bool {
	sync.mutex_lock(&bp.latch)
	defer sync.mutex_unlock(&bp.latch)
	fi, ok := bp.page_table[page_id]
	return ok && bp.frames[fi].is_dirty
}

// Polls flag for up to ms milliseconds.
_done_within :: proc(flag: ^bool, ms: int) -> bool {
	for _ in 0 ..< ms {
		if sync.atomic_load(flag) do return true
		time.sleep(time.Millisecond)
	}
	return sync.atomic_load(flag)
}

// ---------------------------------------------------------------------------
// G01 — a read guard: pin, page pointer, release.
// ---------------------------------------------------------------------------

@(test)
test_g01_read_guard :: proc(t: ^testing.T) {
	path := "/tmp/capradb_guard_01.db"
	dm := _fresh_db(path, 2)
	defer _close_db(dm, path)
	bp := new_buffer_pool(3, dm)
	defer destroy_buffer_pool(bp)

	g, ok := fetch_page_read(bp, 2)
	testing.expect(t, ok, "fetch_page_read failed")
	testing.expect_value(t, g.page_id, u32(2))
	want := _expected(2)
	testing.expect(t, g.page != nil && g.page.data == want.data, "wrong bytes")
	count, _ := pin_count(bp, 2)
	testing.expect_value(t, count, u32(1))

	release_read(&g)
	count, _ = pin_count(bp, 2)
	testing.expect_value(t, count, u32(0))
	testing.expect(t, !_is_dirty(bp, 2), "a read guard dirtied its page")
}

// ═══════════════════════════════ LADDER GATE ═══════════════════════════════
// Move the opening marker below the next test to activate it.


// ---------------------------------------------------------------------------
// G02 — the page latch. Readers share it, and a writer can't get in.
// ---------------------------------------------------------------------------

// try-locks from the test thread, undone straight away
_can_read :: proc(bp: ^Buffer_Pool, page_id: u32) -> bool {
	f := _frame_of(bp, page_id)
	if f == nil do return false
	if sync.rw_mutex_try_shared_lock(&f.page_latch) {
		sync.rw_mutex_shared_unlock(&f.page_latch)
		return true
	}
	return false
}

_can_write :: proc(bp: ^Buffer_Pool, page_id: u32) -> bool {
	f := _frame_of(bp, page_id)
	if f == nil do return false
	if sync.rw_mutex_try_lock(&f.page_latch) {
		sync.rw_mutex_unlock(&f.page_latch)
		return true
	}
	return false
}

@(test)
test_g02_read_guard_latches_shared :: proc(t: ^testing.T) {
	path := "/tmp/capradb_guard_02.db"
	dm := _fresh_db(path, 1)
	defer _close_db(dm, path)
	bp := new_buffer_pool(3, dm)
	defer destroy_buffer_pool(bp)

	a, _ := fetch_page_read(bp, 1)
	testing.expect(t, !_can_write(bp, 1), "a read guard must keep writers out")
	if !testing.expect(t, _can_read(bp, 1), "a read guard must let other readers in") {
		release_read(&a)
		return // a second reader on this thread would wait forever
	}

	b, ok := fetch_page_read(bp, 1)
	testing.expect(t, ok, "second reader on the same page failed")
	testing.expect(t, a.page == b.page, "two readers, two frames")
	count, _ := pin_count(bp, 1)
	testing.expect_value(t, count, u32(2))

	release_read(&a)
	testing.expect(t, !_can_write(bp, 1), "one reader is left, so writers are still out")
	release_read(&b)
	testing.expect(t, _can_write(bp, 1), "both readers released, but the latch is still held")
}

// ---------------------------------------------------------------------------
// G03 — release twice, and release a failed fetch's guard. Spec 5 and 6.
// ---------------------------------------------------------------------------

@(test)
test_g03_release_is_idempotent :: proc(t: ^testing.T) {
	path := "/tmp/capradb_guard_03.db"
	dm := _fresh_db(path, 1)
	defer _close_db(dm, path)
	bp := new_buffer_pool(3, dm)
	defer destroy_buffer_pool(bp)

	a, _ := fetch_page_read(bp, 1)
	b, _ := fetch_page_read(bp, 1)
	release_read(&a)
	release_read(&a) // must do nothing

	count, _ := pin_count(bp, 1)
	testing.expect_value(t, count, u32(1)) // 0 means the second release took b's pin
	testing.expect(t, !_can_write(bp, 1), "the second release gave up b's share of the latch")

	release_read(&b)
	count, _ = pin_count(bp, 1)
	testing.expect_value(t, count, u32(0))
	testing.expect(t, _can_write(bp, 1), "latch still held after every guard was released")

	// A failed fetch hands back a zero guard, and releasing it is harmless.
	bad, ok := fetch_page_read(bp, 999)
	testing.expect(t, !ok, "fetch of an unallocated page succeeded")
	release_read(&bad)
	_, resident := pin_count(bp, 999)
	testing.expect(t, !resident, "failed fetch left a page table entry")
}

// ---------------------------------------------------------------------------
// G04 — a write guard: exclusive, and it marks the page dirty. Spec 4.
// ---------------------------------------------------------------------------

@(test)
test_g04_write_guard :: proc(t: ^testing.T) {
	path := "/tmp/capradb_guard_04.db"
	dm := _fresh_db(path, 1)
	defer _close_db(dm, path)
	bp := new_buffer_pool(3, dm)
	defer destroy_buffer_pool(bp)

	g, ok := fetch_page_write(bp, 1)
	testing.expect(t, ok, "fetch_page_write failed")
	testing.expect_value(t, g.page_id, u32(1))
	testing.expect(t, !_can_read(bp, 1), "a write guard must keep readers out")
	testing.expect(t, !_can_write(bp, 1), "a write guard must keep other writers out")

	g.page.data[100] = 0xAB
	release_write(&g)
	testing.expect(t, _can_write(bp, 1), "release_write left the latch held")
	testing.expect(t, _is_dirty(bp, 1), "release_write must mark the page dirty")
	count, _ := pin_count(bp, 1)
	testing.expect_value(t, count, u32(0))

	release_write(&g) // must do nothing
	count, _ = pin_count(bp, 1)
	testing.expect_value(t, count, u32(0))
	testing.expect(t, _can_write(bp, 1), "second release_write broke the latch")

	testing.expect(t, flush_page(bp, 1), "flush_page")
	got := _on_disk(path, 1)
	testing.expect_value(t, got.data[100], u8(0xAB))
}

// ---------------------------------------------------------------------------
// G05 — new_page_write: a fresh page, already write-latched.
// ---------------------------------------------------------------------------

@(test)
test_g05_new_page_write :: proc(t: ^testing.T) {
	path := "/tmp/capradb_guard_05.db"
	dm := _fresh_db(path, 0)
	defer _close_db(dm, path)
	bp := new_buffer_pool(3, dm)
	defer destroy_buffer_pool(bp)

	g, ok := new_page_write(bp)
	testing.expect(t, ok, "new_page_write failed")
	testing.expect_value(t, g.page_id, u32(1))
	testing.expect(t, g.page != nil && g.page.id == 1, "guard doesn't point at page 1")
	testing.expect(t, !_can_read(bp, 1), "a new page must come back write-latched")

	rec := "hello"
	testing.expect(t, pg.insert_record(g.page, transmute([]u8)rec), "new page has no valid header")
	release_write(&g)
	testing.expect(t, _is_dirty(bp, 1), "release_write must mark the new page dirty")

	testing.expect(t, flush_page(bp, 1), "flush_page")
	got := _on_disk(path, 1)
	data, found := pg.get_record(&got, 0)
	testing.expect(t, found && string(data) == "hello", "record didn't reach disk")
}

// ---------------------------------------------------------------------------
// G06 — a reader waits for a writer, without holding the pool latch. Spec 2.
// May pass on arrival (spec 14).
//
// The probe is a second thread that fetches a different page. If the waiting
// reader holds the pool latch, the probe can't get in, and it reports instead
// of hanging the test.
// ---------------------------------------------------------------------------

Read_Job :: struct {
	bp:       ^Buffer_Pool,
	page_id:  u32,
	acquired: bool, // atomic
	seen:     u8,
}

_read_job :: proc(j: ^Read_Job) {
	g, ok := fetch_page_read(j.bp, j.page_id)
	sync.atomic_store(&j.acquired, true)
	if ok {
		j.seen = g.page.data[100]
		release_read(&g)
	}
}

Probe :: struct {
	bp:      ^Buffer_Pool,
	page_id: u32,
	done:    bool, // atomic
}

_probe_job :: proc(p: ^Probe) {
	g, ok := fetch_page_read(p.bp, p.page_id)
	if ok do release_read(&g)
	sync.atomic_store(&p.done, true)
}

// Starts a thread that takes and drops a read guard on page_id. Poll p.done
// with _done_within: if it never finishes, the pool is stuck.
_pool_responds :: proc(bp: ^Buffer_Pool, page_id: u32, p: ^Probe) -> ^thread.Thread {
	p^ = Probe{bp = bp, page_id = page_id}
	return thread.create_and_start_with_poly_data(p, _probe_job, context)
}

@(test)
test_g06_reader_waits_without_pool_latch :: proc(t: ^testing.T) {
	path := "/tmp/capradb_guard_06.db"
	dm := _fresh_db(path, 2)
	defer _close_db(dm, path)
	bp := new_buffer_pool(3, dm)
	defer destroy_buffer_pool(bp)

	w, _ := fetch_page_write(bp, 1)
	r2, _ := fetch_page_read(bp, 2) // make page 2 resident for the probe
	release_read(&r2)

	j := Read_Job{bp = bp, page_id = 1}
	th := thread.create_and_start_with_poly_data(&j, _read_job, context)
	defer thread.destroy(th)
	time.sleep(20 * time.Millisecond) // let it reach page 1's latch

	testing.expect(t, !sync.atomic_load(&j.acquired), "a reader got past a write guard")

	p: Probe
	pt := _pool_responds(bp, 2, &p)
	defer thread.destroy(pt)
	responsive := _done_within(&p.done, 1000)
	testing.expect(t, responsive,
		"the pool is stuck while a reader waits for page 1: something waits for a page latch while holding the pool latch (spec 2)")
	if responsive {
		// The waiting reader is pinned, so page 1 can't be evicted under it.
		count, _ := pin_count(bp, 1)
		testing.expect_value(t, count, u32(2))
	}

	w.page.data[100] = 0xCD
	release_write(&w)
	thread.join(th)
	thread.join(pt)
	testing.expect_value(t, j.seen, u8(0xCD))
}

// ---------------------------------------------------------------------------
// G07 — flush waits for a writer. Spec 7.
// ---------------------------------------------------------------------------

Flush_Wait_Job :: struct {
	bp:      ^Buffer_Pool,
	page_id: u32,
	ok:      bool,
	done:    bool, // atomic
}

_flush_wait_job :: proc(j: ^Flush_Wait_Job) {
	j.ok = flush_page(j.bp, j.page_id)
	sync.atomic_store(&j.done, true)
}

@(test)
test_g07_flush_waits_for_writer :: proc(t: ^testing.T) {
	path := "/tmp/capradb_guard_07.db"
	dm := _fresh_db(path, 2)
	defer _close_db(dm, path)
	bp := new_buffer_pool(3, dm)
	defer destroy_buffer_pool(bp)

	w, _ := fetch_page_write(bp, 1)
	w.page.data[100] = 0xAB
	release_write(&w) // page 1 is dirty
	r2, _ := fetch_page_read(bp, 2)
	release_read(&r2)

	w, _ = fetch_page_write(bp, 1) // a writer, mid-change

	j := Flush_Wait_Job{bp = bp, page_id = 1}
	th := thread.create_and_start_with_poly_data(&j, _flush_wait_job, context)
	defer thread.destroy(th)
	time.sleep(20 * time.Millisecond)

	testing.expect(t, !sync.atomic_load(&j.done),
		"flush wrote page 1 while a writer held it, so disk can get a half-finished change")

	p: Probe
	pt := _pool_responds(bp, 2, &p)
	defer thread.destroy(pt)
	responsive := _done_within(&p.done, 1000)
	testing.expect(t, responsive, "flush is waiting for page 1's latch while holding the pool latch")
	if responsive {
		count, _ := pin_count(bp, 1)
		testing.expect_value(t, count, u32(2)) // the writer + the flush
	}

	w.page.data[100] = 0xCD
	release_write(&w)
	thread.join(th)
	thread.join(pt)

	testing.expect(t, j.ok, "flush failed")
	got := _on_disk(path, 1)
	testing.expect_value(t, got.data[100], u8(0xCD))
}

// ---------------------------------------------------------------------------
// G08 — flush keeps the latch until its write lands. Spec 7.
// May pass on arrival (spec 14).
// ---------------------------------------------------------------------------

@(test)
test_g08_flush_holds_latch_through_write :: proc(t: ^testing.T) {
	path := "/tmp/capradb_guard_08.db"
	dm := _fresh_db(path, 1)
	defer _close_db(dm, path)
	bp := new_buffer_pool(3, dm)
	defer destroy_buffer_pool(bp)

	w, _ := fetch_page_write(bp, 1)
	w.page.data[100] = 0xAB
	release_write(&w)

	s: Stall
	_stall_worker(&s, bp)

	j := Flush_Wait_Job{bp = bp, page_id = 1}
	th := thread.create_and_start_with_poly_data(&j, _flush_wait_job, context)
	defer thread.destroy(th)
	time.sleep(20 * time.Millisecond) // flush has queued its write behind the stall

	testing.expect(t, !sync.atomic_load(&j.done), "flush returned before its write ran")
	testing.expect(t, _can_read(bp, 1), "a flush only reads the page, so readers may share it")
	testing.expect(t, !_can_write(bp, 1),
		"flush let go of the latch before its write finished, so a writer could change the bytes the queued write points at")

	_release_worker(&s)
	thread.join(th)
	testing.expect(t, j.ok, "flush failed")
	testing.expect(t, _can_write(bp, 1), "flush never released the latch")
	got := _on_disk(path, 1)
	testing.expect_value(t, got.data[100], u8(0xAB))
}

// ---------------------------------------------------------------------------
// G09 — flush_all: waits for writers, one latch at a time. Spec 8.
// ---------------------------------------------------------------------------

_flush_all_job :: proc(j: ^Flush_Wait_Job) {
	flush_all(j.bp)
	sync.atomic_store(&j.done, true)
}

Writer_Sweep :: struct {
	bp:   ^Buffer_Pool,
	skip: u32,
	done: bool, // atomic
}

// Takes and drops a write guard on pages 1..=4, except skip.
_writer_sweep :: proc(w: ^Writer_Sweep) {
	for id in u32(1) ..= 4 {
		if id == w.skip do continue
		g, ok := fetch_page_write(w.bp, id)
		if ok do release_write(&g)
	}
	sync.atomic_store(&w.done, true)
}

@(test)
test_g09_flush_all_one_latch_at_a_time :: proc(t: ^testing.T) {
	path := "/tmp/capradb_guard_09.db"
	dm := _fresh_db(path, 5)
	defer _close_db(dm, path)
	bp := new_buffer_pool(5, dm)
	defer destroy_buffer_pool(bp)

	// Part A: flush_all waits for a writer, without blocking the pool.
	{
		for id in u32(1) ..= 4 {
			g, _ := fetch_page_write(bp, id)
			release_write(&g)
		}
		r5, _ := fetch_page_read(bp, 5)
		release_read(&r5)

		hold, _ := fetch_page_write(bp, 1)
		j := Flush_Wait_Job{bp = bp}
		th := thread.create_and_start_with_poly_data(&j, _flush_all_job, context)
		defer thread.destroy(th)
		time.sleep(20 * time.Millisecond)

		testing.expect(t, !sync.atomic_load(&j.done), "flush_all wrote page 1 while a writer held it")

		p: Probe
		pt := _pool_responds(bp, 5, &p)
		defer thread.destroy(pt)
		testing.expect(t, _done_within(&p.done, 1000),
			"flush_all is waiting for page 1's latch while holding the pool latch")

		hold.page.data[100] = 0xEE
		release_write(&hold)
		thread.join(th)
		thread.join(pt)
		got := _on_disk(path, 1)
		testing.expect_value(t, got.data[100], u8(0xEE))
	}

	// Part B: a writer holds page `a` and then wants the other pages, while
	// flush_all waits on `a`. Map order decides which page flush_all reaches
	// first, so every page takes a turn as `a`.
	for a in u32(1) ..= 4 {
		for id in u32(1) ..= 4 {
			g, _ := fetch_page_write(bp, id) // dirty all four
			release_write(&g)
		}

		hold, _ := fetch_page_write(bp, a)
		j := Flush_Wait_Job{bp = bp}
		th := thread.create_and_start_with_poly_data(&j, _flush_all_job, context)
		time.sleep(20 * time.Millisecond) // flush_all reaches page a and waits

		sweep := Writer_Sweep{bp = bp, skip = a}
		st := thread.create_and_start_with_poly_data(&sweep, _writer_sweep, context)
		ok := _done_within(&sweep.done, 1000)
		testing.expectf(t, ok,
			"page %d held: a writer can't get the other pages, so flush_all holds one latch while waiting for another (deadlock)", a)

		release_write(&hold)
		thread.join(th)
		thread.join(st)
		thread.destroy(th)
		thread.destroy(st)
		if !ok do return
	}
}

// ---------------------------------------------------------------------------
// G10 — stress. Four threads share eight pages in four frames. Writers bump a
// shared counter at offset 0 and stamp the rest of the page with its low byte.
// Readers check the stamp is uniform: a mixed page means a reader saw a
// writer mid-change. Some ops flush. At the end, each page's counter on disk
// must equal the number of writes to it. Without page latches this loses
// updates and sees torn pages, which the benchmark avoided by giving each
// thread its own bytes.
// ---------------------------------------------------------------------------

GS_THREADS :: 4
GS_PAGES :: 8
GS_OPS :: 2000

Guard_Stress_Job :: struct {
	bp:     ^Buffer_Pool,
	seed:   u32,
	writes: [GS_PAGES + 1]u32,
	torn:   int,
	failed: int,
}

_stamp_ok :: proc(p: ^pg.Page) -> bool {
	c, _ := utils.read_u32_le(p.data[:], 0)
	for i in 4 ..< pg.PAGE_SIZE {
		if p.data[i] != u8(c) do return false
	}
	return true
}

_guard_stress :: proc(j: ^Guard_Stress_Job) {
	rng := j.seed
	for _ in 0 ..< GS_OPS {
		rng = rng * 1664525 + 1013904223
		id := (rng >> 16) % GS_PAGES + 1
		op := (rng >> 8) % 10

		switch {
		case op < 5:
			g, ok := fetch_page_write(j.bp, id)
			if !ok {
				j.failed += 1
				continue
			}
			c, _ := utils.read_u32_le(g.page.data[:], 0)
			c += 1
			utils.write_u32_le(g.page.data[:], 0, c)
			for i in 4 ..< pg.PAGE_SIZE do g.page.data[i] = u8(c)
			release_write(&g)
			j.writes[id] += 1
		case op < 9:
			g, ok := fetch_page_read(j.bp, id)
			if !ok {
				j.failed += 1
				continue
			}
			if !_stamp_ok(g.page) do j.torn += 1
			release_read(&g)
		case:
			flush_page(j.bp, id)
		}
	}
}

@(test)
test_g10_stress :: proc(t: ^testing.T) {
	path := "/tmp/capradb_guard_10.db"
	dm := _fresh_db(path, GS_PAGES)
	defer _close_db(dm, path)
	bp := new_buffer_pool(GS_THREADS, dm)
	defer destroy_buffer_pool(bp)

	// Start every page at counter 0 with a matching stamp.
	for id in u32(1) ..= GS_PAGES {
		g, _ := fetch_page_write(bp, id)
		for i in 0 ..< pg.PAGE_SIZE do g.page.data[i] = 0
		release_write(&g)
	}

	jobs: [GS_THREADS]Guard_Stress_Job
	threads: [GS_THREADS]^thread.Thread
	for i in 0 ..< GS_THREADS {
		jobs[i] = Guard_Stress_Job{bp = bp, seed = u32(i * 7919 + 1)}
		threads[i] = thread.create_and_start_with_poly_data(&jobs[i], _guard_stress, context)
	}
	for th in threads {
		thread.join(th)
		thread.destroy(th)
	}

	total: [GS_PAGES + 1]u32
	for j in jobs {
		// Each thread holds at most one pin, so a frame is always available.
		testing.expectf(t, j.failed == 0, "%d fetches failed", j.failed)
		testing.expectf(t, j.torn == 0, "%d reads saw a page mid-write", j.torn)
		for id in 1 ..= GS_PAGES do total[id] += j.writes[id]
	}

	flush_all(bp)
	for id in u32(1) ..= GS_PAGES {
		got := _on_disk(path, id)
		c, _ := utils.read_u32_le(got.data[:], 0)
		testing.expectf(t, c == total[id], "page %d: counter %d on disk, %d writes made", id, c, total[id])
		testing.expectf(t, _stamp_ok(&got), "page %d reached disk torn", id)
	}
}

// ---------------------------------------------------------------------------
// G11 — a flush whose write fails leaves the page dirty. Spec 15.
//
// One frame, two pages. Page 1 is changed in memory, then flushed while the
// disk refuses writes. flush_page must report the failure AND leave the page
// dirty, or the next eviction drops the only copy of the change.
// ---------------------------------------------------------------------------

// Makes every write fail, the only way the disk manager can today:
// write_page refuses a page id above num_pages. Reads fail too while this is
// in force, so don't fetch a non-resident page between the two calls.
_break_writes :: proc(dm: ^disk.Disk_Manager) -> u32 {
	sync.mutex_lock(&dm.latch)
	defer sync.mutex_unlock(&dm.latch)
	saved := dm.num_pages
	dm.num_pages = 0
	return saved
}

_mend_writes :: proc(dm: ^disk.Disk_Manager, saved: u32) {
	sync.mutex_lock(&dm.latch)
	defer sync.mutex_unlock(&dm.latch)
	dm.num_pages = saved
}

@(test)
test_g11_failed_flush_keeps_page_dirty :: proc(t: ^testing.T) {
	path := "/tmp/capradb_guard_11.db"
	dm := _fresh_db(path, 2)
	defer _close_db(dm, path)
	bp := new_buffer_pool(1, dm) // one frame: fetching page 2 must evict page 1
	defer destroy_buffer_pool(bp)

	w, _ := fetch_page_write(bp, 1)
	w.page.data[100] = 0xAB
	release_write(&w) // page 1 is dirty; 0xAB exists only in memory

	saved := _break_writes(dm)
	flushed := flush_page(bp, 1)
	_mend_writes(dm, saved)

	testing.expect(t, !flushed, "the disk refused the write, so flush_page must report failure")
	count, _ := pin_count(bp, 1)
	testing.expect_value(t, count, u32(0)) // a failed flush still gives its pin back
	testing.expect(t, _is_dirty(bp, 1),
		"the write failed but page 1 is marked clean, so the pool thinks disk already has its change")

	// What that costs: push page 1 out and bring it back.
	r2, ok2 := fetch_page_read(bp, 2)
	testing.expect(t, ok2, "fetch of page 2")
	release_read(&r2)
	r1, ok1 := fetch_page_read(bp, 1)
	testing.expect(t, ok1, "fetch of page 1")
	if ok1 {
		testing.expect(t, r1.page.data[100] == 0xAB,
			"page 1's change is gone: it was evicted as clean after a flush that never reached disk")
		release_read(&r1)
	}
}

// ---------------------------------------------------------------------------
// G12 — a second flush waits for the write already in flight. Spec 16.
//
// Two flushes of one dirty page, with the worker stalled so the first one's
// write is queued but hasn't run. The second must not return true while the
// bytes are still only in the queue.
// ---------------------------------------------------------------------------

@(test)
test_g12_second_flush_waits_for_the_write :: proc(t: ^testing.T) {
	path := "/tmp/capradb_guard_12.db"
	dm := _fresh_db(path, 1)
	defer _close_db(dm, path)
	bp := new_buffer_pool(3, dm)
	defer destroy_buffer_pool(bp)

	w, _ := fetch_page_write(bp, 1)
	w.page.data[100] = 0xAB
	release_write(&w) // page 1 is dirty

	s: Stall
	_stall_worker(&s, bp)

	first := Flush_Wait_Job{bp = bp, page_id = 1}
	t1 := thread.create_and_start_with_poly_data(&first, _flush_wait_job, context)
	defer thread.destroy(t1)
	time.sleep(20 * time.Millisecond) // the first flush has queued its write behind the stall

	second := Flush_Wait_Job{bp = bp, page_id = 1}
	t2 := thread.create_and_start_with_poly_data(&second, _flush_wait_job, context)
	defer thread.destroy(t2)
	time.sleep(20 * time.Millisecond)

	testing.expect(t, !sync.atomic_load(&second.done),
		"the second flush returned while page 1's write was still queued: its caller believes bytes are on disk that aren't")

	_release_worker(&s)
	thread.join(t1)
	thread.join(t2)
	testing.expect(t, first.ok && second.ok, "a flush failed")
	got := _on_disk(path, 1)
	testing.expect_value(t, got.data[100], u8(0xAB))
}

// ---------------------------------------------------------------------------
// gc1 — yours. One adversarial test for something this ladder misses. Write
// it before I probe, and watch it fail against the bug before you trust it
// passing.
// ---------------------------------------------------------------------------
/*
*/ // ——— end of ladder gate ———


@(test)
test_gc1_delete_refuses_write_guard :: proc(t: ^testing.T) {
	path := "/tmp/capradb_guard_gc1.db"
	dm := _fresh_db(path, 2)
	defer _close_db(dm, path)
	bp := new_buffer_pool(3, dm)
	defer destroy_buffer_pool(bp)

	w, ok := fetch_page_write(bp, 1)
	testing.expect(t, ok, "fetch_page_write failed")
	w.page.data[100] = 0xAB

	testing.expect(t, !delete_page(bp, 1), "delete_page succeeded while a write guard still held the page")

	_, resident := pin_count(bp, 1)
	testing.expect(t, resident, "page 1 vanished from the pool while a write guard still held it")

	count, _ := pin_count(bp, 1)
	testing.expect_value(t, count, u32(1))

	release_write(&w)

	testing.expect(t, delete_page(bp, 1), "delete_page failed after the write guard released the page")
	_, resident = pin_count(bp, 1)
	testing.expect(t, !resident, "page 1 is still resident after delete_page")
}

@(test)
test_gc2_delete_refuses_flush_pin :: proc(t: ^testing.T) {
	path := "/tmp/capradb_guard_gc2.db"
	dm := _fresh_db(path, 2)
	defer _close_db(dm, path)
	bp := new_buffer_pool(3, dm)
	defer destroy_buffer_pool(bp)

	w, ok := fetch_page_write(bp, 1)
	testing.expect(t, ok, "fetch_page_write failed")
	w.page.data[100] = 0xAB
	release_write(&w)

	s: Stall
	_stall_worker(&s, bp)

	j := Flush_Wait_Job{bp = bp, page_id = 1}
	th := thread.create_and_start_with_poly_data(&j, _flush_wait_job, context)
	defer thread.destroy(th)
	time.sleep(20 * time.Millisecond)

	testing.expect(t, !delete_page(bp, 1), "delete page freed page 1 while a flush still held its pin")

	count, resident := pin_count(bp, 1)
	testing.expect(t, count >= 1, "flush should still own a pin")
	testing.expect(t, resident, "page 1 left the pool under an in-flight flush")

	_release_worker(&s)
	thread.join(th)
	testing.expect(t, j.ok, "flush failed")

	got := _on_disk(path, 1)
	testing.expect_value(t, got.data[100], u8(0xAB))

	testing.expect(t, delete_page(bp, 1), "delete_page failed after flush finished")
	_, resident = pin_count(bp, 1)
	testing.expect(t, !resident, "page 1 is still resident after delete_page")
}