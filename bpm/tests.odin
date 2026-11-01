package bpm

import "core:os"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import "../disk"
import pg "../page"
import "../utils"
import sc "../scheduler"

/*
================================================================================
 BUFFER POOL MANAGER — TEST LADDER
================================================================================

 Interface under test (your bpm.odin must provide):

   Buffer_Pool :: struct {
       sched: ^sc.Disk_Scheduler,   // the concurrency tests reach in for this
       ...                          // the rest is yours
   }

   new_buffer_pool     :: proc(pool_size: u32, dm: ^disk.Disk_Manager) -> ^Buffer_Pool
   destroy_buffer_pool :: proc(bp: ^Buffer_Pool)
   fetch_page          :: proc(bp: ^Buffer_Pool, page_id: u32) -> ^pg.Page
   new_page            :: proc(bp: ^Buffer_Pool) -> ^pg.Page
   unpin_page          :: proc(bp: ^Buffer_Pool, page_id: u32, is_dirty: bool) -> bool
   flush_page          :: proc(bp: ^Buffer_Pool, page_id: u32) -> bool
   flush_all           :: proc(bp: ^Buffer_Pool)
   delete_page         :: proc(bp: ^Buffer_Pool, page_id: u32) -> bool
   pin_count           :: proc(bp: ^Buffer_Pool, page_id: u32) -> (count: u32, resident: bool)

 SPEC DECISIONS (the contract these tests pin down):

 1. PINS. fetch_page and new_page return a pointer into a frame, pinned once.
    The pointer stays valid until the matching unpin_page. A pinned frame is
    never evicted. Pin count 0 -> 1 makes a frame non-evictable; 1 -> 0 makes
    it evictable. Unpinning a page at pin count 0, or a page that isn't
    resident, returns false.

 2. DIRTY. is_dirty is sticky: unpin(true) then unpin(false) is still dirty.
    A dirty page reaches disk before its frame is reused. A clean page never
    gets written.

 3. FRAMES. Use the free list first; call replacer.evict only when it's empty.
    When no frame is available, fetch_page and new_page return nil and change
    nothing else. (A failed new_page may waste a page id. That's fine.)

 4. FAILED READ. fetch_page of a page the disk rejects returns nil. The frame
    goes back on the free list, and the id leaves the page table. With several
    waiters, every one of them gets nil and the LAST one out frees the frame.

 5. FLUSH. flush_page writes a dirty page and clears its dirty flag; on a clean
    page it writes nothing and returns true. Non-resident returns false. A
    flush pins the frame until its write finishes, because the queued write
    points at the frame and eviction would swap the bytes underneath it. The
    pin count is back where it started when flush returns, and pinned pages
    may be flushed. Clear the flag BEFORE scheduling the write. flush_all does
    this for every frame.

 6. DELETE. delete_page on a pinned page returns false. On an unpinned page it
    drops the page WITHOUT writing it, frees the frame (replacer.remove, free
    list) and returns true. Non-resident returns true. Disk space isn't
    reclaimed.

 7. DESTROY. destroy_buffer_pool flushes all dirty pages, then destroys the
    scheduler, then frees everything. It does not close the disk manager.

 8. LATCHING. One pool latch guards the page table, free list, frame metadata
    and the replacer, so the replacer needs no mutex of its own. Never wait on
    I/O while holding it. Calling schedule under the latch is fine and useful:
    it only pushes onto a queue.

 9. IN-FLIGHT READS. The page table entry goes in BEFORE the read is scheduled,
    so a hit can mean "assigned, still loading". The Completion for a read
    lives IN THE FRAME, not on anyone's stack: a second thread may be asleep on
    it, and A's stack is gone once A returns. So every fetch, hit or miss:
    pin under the latch, release the latch, wait on the frame's Completion.
    The pin taken before sleeping is what stops the frame being evicted, and
    its Completion reset, underneath the waiter.

 10. WRITE-BACK ORDER. Schedule the victim's write UNDER the latch, in the same
    critical section that removes it from the page table. A later fetch of that
    page then misses, schedules its read, and lands behind the write in the
    FIFO queue. It cannot read stale bytes. A write-back that fails can be
    treated as fatal for now.

 11. DISK MANAGER THREADING. This replaces scheduler spec 7. new_page runs
    allocate_page on caller threads while the worker reads and writes, so
    num_pages needs protecting. Rung 25 forces this: give Disk_Manager a mutex
    around allocate_page, read_page and write_page.

 12. OUT OF SCOPE. Two threads modifying one page's bytes at once. That's what
    the per-page latches in Page Guards are for.

 13. HANGS. To run one test alone:
      odin test bpm -define:ODIN_TEST_NAMES=bpm.<test_name> -define:ODIN_TEST_FANCY=false
    Name the thread that should wake the sleeper, and find out why it didn't.

 LADDER GATE: everything below the gate comment is inactive. Move the opening
 marker down as you go, one test at a time.
================================================================================
*/

// ---------------------------------------------------------------------------
// Shared helpers.
// ---------------------------------------------------------------------------

// Creates a fresh database with pages 1..=n_pages, each filled with a pattern
// unique to (id, seed 7).
_fresh_db :: proc(path: string, n_pages: int) -> ^disk.Disk_Manager {
	os.remove(path)
	dm := disk.new_disk_manager(path)
	for i in 0 ..< n_pages {
		_ = disk.allocate_page(dm)
		p: pg.Page
		_fill(&p, u32(i + 1), 7)
		disk.write_page(dm, &p)
	}
	return dm
}

_close_db :: proc(dm: ^disk.Disk_Manager, path: string) {
	disk.close_disk_manager(dm)
	os.remove(path)
}

_fill :: proc(p: ^pg.Page, id: u32, seed: u8) {
	p.id = id
	for i in 0 ..< pg.PAGE_SIZE {
		p.data[i] = seed + u8(i % 251) + u8(id)
	}
}

// What the file holds right now, read through a separate handle so the pool's
// disk manager is left alone.
_on_disk :: proc(path: string, id: u32) -> pg.Page {
	dm := disk.new_disk_manager(path)
	defer disk.close_disk_manager(dm)
	p, _ := disk.read_page(dm, id)
	return p
}

_expected :: proc(id: u32) -> pg.Page {
	p: pg.Page
	_fill(&p, id, 7)
	return p
}

// ---------------------------------------------------------------------------
// Rung 1 — one thread, the happy path.
// ---------------------------------------------------------------------------

@(test)
test_01_create_and_destroy :: proc(t: ^testing.T) {
	path := "/tmp/capradb_bpm_01.db"
	dm := _fresh_db(path, 0)
	defer _close_db(dm, path)

	bp := new_buffer_pool(3, dm)
	destroy_buffer_pool(bp)
}

// ═══════════════════════════════ LADDER GATE ═══════════════════════════════
// Move this opening marker below the next test to activate it.


@(test)
test_02_new_page :: proc(t: ^testing.T) {
	// The page has a real header, so slotted-page ops work on it right away.
	path := "/tmp/capradb_bpm_02.db"
	dm := _fresh_db(path, 0)
	defer _close_db(dm, path)
	bp := new_buffer_pool(3, dm)
	defer destroy_buffer_pool(bp)

	p := new_page(bp)
	testing.expect(t, p != nil, "new_page returned nil")
	testing.expect_value(t, p.id, u32(1))
	count, resident := pin_count(bp, 1)
	testing.expect(t, resident, "new page isn't resident")
	testing.expect_value(t, count, u32(1))

	rec := "hello"
	testing.expect(t, pg.insert_record(p, transmute([]u8)rec), "new page has no valid header")
}

@(test)
test_03_fetch_miss_reads_disk :: proc(t: ^testing.T) {
	path := "/tmp/capradb_bpm_03.db"
	dm := _fresh_db(path, 2)
	defer _close_db(dm, path)
	bp := new_buffer_pool(3, dm)
	defer destroy_buffer_pool(bp)

	p := fetch_page(bp, 2)
	testing.expect(t, p != nil, "fetch_page returned nil")
	want := _expected(2)
	testing.expect_value(t, p.id, u32(2))
	testing.expect(t, p.data == want.data, "wrong bytes")
}

@(test)
test_04_fetch_hit_same_frame :: proc(t: ^testing.T) {
	path := "/tmp/capradb_bpm_04.db"
	dm := _fresh_db(path, 1)
	defer _close_db(dm, path)
	bp := new_buffer_pool(3, dm)
	defer destroy_buffer_pool(bp)

	a := fetch_page(bp, 1)
	b := fetch_page(bp, 1)
	testing.expect(t, a == b, "two frames for one page")
	count, _ := pin_count(bp, 1)
	testing.expect_value(t, count, u32(2))
}

// ---------------------------------------------------------------------------
// A hit on a page that is still loading. Concurrency, made deterministic.
//
// _stall_worker parks the scheduler's worker: the test holds the mutex of a
// Completion, so the worker blocks inside complete() on a dummy request. Every
// read the pool schedules then sits in the queue until _release_worker, which
// gives the tests a read that's reliably in flight. No sleep-and-hope.
// ---------------------------------------------------------------------------

Stall :: struct {
	gate:    sc.Completion,
	scratch: pg.Page,
}

_stall_worker :: proc(s: ^Stall, bp: ^Buffer_Pool) {
	sync.mutex_lock(&s.gate.mutex)
	sc.schedule(bp.sched, sc.Disk_Request{page_id = 1, buf = &s.scratch, done = &s.gate})
	time.sleep(10 * time.Millisecond)
}

_release_worker :: proc(s: ^Stall) {
	sync.mutex_unlock(&s.gate.mutex)
	sc.wait(&s.gate)
}

Fetch_Job :: struct {
	bp:       ^Buffer_Pool,
	page_id:  u32,
	result:   ^pg.Page,
	returned: bool, // read/written with sync.atomic_*
}

_fetch_job :: proc(j: ^Fetch_Job) {
	j.result = fetch_page(j.bp, j.page_id)
	sync.atomic_store(&j.returned, true)
}

_start_fetch :: proc(j: ^Fetch_Job) -> ^thread.Thread {
	th := thread.create_and_start_with_poly_data(j, _fetch_job, context)
	time.sleep(20 * time.Millisecond) // let it reach its wait
	return th
}

@(test)
test_04b_second_fetch_waits_for_the_read :: proc(t: ^testing.T) {
	// The scenario from the design discussion. B hits while A's read is in
	// flight. B must not return early, and must be pinned while it sleeps.
	// If this hangs in pin_count, some thread is holding the latch across I/O.
	path := "/tmp/capradb_bpm_04b.db"
	dm := _fresh_db(path, 1)
	defer _close_db(dm, path)
	bp := new_buffer_pool(3, dm)
	defer destroy_buffer_pool(bp)

	s: Stall
	_stall_worker(&s, bp)

	a := Fetch_Job{bp = bp, page_id = 1}
	b := Fetch_Job{bp = bp, page_id = 1}
	ta := _start_fetch(&a)
	defer thread.destroy(ta)
	tb := _start_fetch(&b)
	defer thread.destroy(tb)

	testing.expect(t, !sync.atomic_load(&a.returned), "A returned before its read ran")
	testing.expect(t, !sync.atomic_load(&b.returned), "B returned before the read ran")
	count, _ := pin_count(bp, 1)
	testing.expect_value(t, count, u32(2))

	_release_worker(&s)
	thread.join(ta)
	thread.join(tb)

	testing.expect(t, a.result != nil && a.result == b.result, "A and B must share one frame")
	want := _expected(1)
	testing.expect(t, a.result.data == want.data, "wrong bytes")
}

@(test)
test_05_fetch_hit_on_new_page :: proc(t: ^testing.T) {
	// new_page does no read, so nothing would ever complete the frame's
	// Completion unless new_page does it. If this hangs, name the thread
	// that was supposed to wake it.
	path := "/tmp/capradb_bpm_05.db"
	dm := _fresh_db(path, 0)
	defer _close_db(dm, path)
	bp := new_buffer_pool(3, dm)
	defer destroy_buffer_pool(bp)

	a := new_page(bp)
	b := fetch_page(bp, a.id)
	testing.expect(t, a == b, "two frames for one page")
	count, _ := pin_count(bp, a.id)
	testing.expect_value(t, count, u32(2))
}

@(test)
test_06_unpin :: proc(t: ^testing.T) {
	path := "/tmp/capradb_bpm_06.db"
	dm := _fresh_db(path, 2)
	defer _close_db(dm, path)
	bp := new_buffer_pool(3, dm)
	defer destroy_buffer_pool(bp)

	fetch_page(bp, 1)
	fetch_page(bp, 1)
	testing.expect(t, unpin_page(bp, 1, false), "unpin 2 -> 1")
	testing.expect(t, unpin_page(bp, 1, false), "unpin 1 -> 0")
	testing.expect(t, !unpin_page(bp, 1, false), "unpin below zero must fail")
	testing.expect(t, !unpin_page(bp, 2, false), "unpin of a non-resident page must fail")

	count, resident := pin_count(bp, 1)
	testing.expect(t, resident, "unpinned page stays resident until evicted")
	testing.expect_value(t, count, u32(0))
}

// ---------------------------------------------------------------------------
// Rung 2 — eviction and write-back.
// ---------------------------------------------------------------------------

@(test)
test_07_pool_full :: proc(t: ^testing.T) {
	path := "/tmp/capradb_bpm_07.db"
	dm := _fresh_db(path, 3)
	defer _close_db(dm, path)
	bp := new_buffer_pool(2, dm)
	defer destroy_buffer_pool(bp)

	fetch_page(bp, 1)
	fetch_page(bp, 2)
	testing.expect(t, fetch_page(bp, 3) == nil, "fetch with every frame pinned")
	testing.expect(t, new_page(bp) == nil, "new_page with every frame pinned")
	_, resident := pin_count(bp, 3)
	testing.expect(t, !resident, "failed fetch left an entry behind")

	unpin_page(bp, 2, false)
	testing.expect(t, fetch_page(bp, 3) != nil, "a frame was free after the unpin")
}

@(test)
test_08_eviction :: proc(t: ^testing.T) {
	path := "/tmp/capradb_bpm_08.db"
	dm := _fresh_db(path, 2)
	defer _close_db(dm, path)
	bp := new_buffer_pool(1, dm)
	defer destroy_buffer_pool(bp)

	fetch_page(bp, 1)
	unpin_page(bp, 1, false)
	p := fetch_page(bp, 2)
	testing.expect(t, p != nil, "eviction should have made room")
	_, resident := pin_count(bp, 1)
	testing.expect(t, !resident, "evicted page still in the page table")
	want := _expected(2)
	testing.expect_value(t, p.id, u32(2))
	testing.expect(t, p.data == want.data, "wrong bytes after eviction")
}

@(test)
test_09_repin_revokes_evictable :: proc(t: ^testing.T) {
	// Pin 0 -> 1 on a HIT has to tell the replacer too.
	path := "/tmp/capradb_bpm_09.db"
	dm := _fresh_db(path, 2)
	defer _close_db(dm, path)
	bp := new_buffer_pool(1, dm)
	defer destroy_buffer_pool(bp)

	fetch_page(bp, 1)
	unpin_page(bp, 1, false)
	fetch_page(bp, 1)
	testing.expect(t, fetch_page(bp, 2) == nil, "evicted a pinned page")
}

@(test)
test_10_clean_eviction_writes_nothing :: proc(t: ^testing.T) {
	path := "/tmp/capradb_bpm_10.db"
	dm := _fresh_db(path, 2)
	defer _close_db(dm, path)
	bp := new_buffer_pool(1, dm)
	defer destroy_buffer_pool(bp)

	p := fetch_page(bp, 1)
	p.data[100] ~= 0xFF // scribble, then claim it's clean
	unpin_page(bp, 1, false)
	fetch_page(bp, 2)

	got := _on_disk(path, 1)
	want := _expected(1)
	testing.expect(t, got.data == want.data, "clean page was written")
}

@(test)
test_11_dirty_eviction_writes_back :: proc(t: ^testing.T) {
	path := "/tmp/capradb_bpm_11.db"
	dm := _fresh_db(path, 2)
	defer _close_db(dm, path)
	bp := new_buffer_pool(1, dm)
	defer destroy_buffer_pool(bp)

	p := fetch_page(bp, 1)
	p.data[100] = 0xAB
	unpin_page(bp, 1, true)
	fetch_page(bp, 2)

	got := _on_disk(path, 1)
	testing.expect_value(t, got.data[100], u8(0xAB))
}

@(test)
test_12_dirty_is_sticky :: proc(t: ^testing.T) {
	path := "/tmp/capradb_bpm_12.db"
	dm := _fresh_db(path, 2)
	defer _close_db(dm, path)
	bp := new_buffer_pool(1, dm)
	defer destroy_buffer_pool(bp)

	p := fetch_page(bp, 1)
	fetch_page(bp, 1)
	p.data[100] = 0xAB
	unpin_page(bp, 1, true)
	unpin_page(bp, 1, false) // the reader must not wipe the writer's flag
	fetch_page(bp, 2)

	got := _on_disk(path, 1)
	testing.expect_value(t, got.data[100], u8(0xAB))
}

@(test)
test_13_round_trip_through_eviction :: proc(t: ^testing.T) {
	// The reused frame must not leak flags: page 1 comes back clean, pin 1.
	path := "/tmp/capradb_bpm_13.db"
	dm := _fresh_db(path, 2)
	defer _close_db(dm, path)
	bp := new_buffer_pool(1, dm)
	defer destroy_buffer_pool(bp)

	p := fetch_page(bp, 1)
	p.data[100] = 0xAB
	unpin_page(bp, 1, true)
	fetch_page(bp, 2)
	unpin_page(bp, 2, false)

	p = fetch_page(bp, 1)
	testing.expect_value(t, p.data[100], u8(0xAB))
	count, _ := pin_count(bp, 1)
	testing.expect_value(t, count, u32(1))

	// Scribble and unpin clean. If the dirty flag survived from the first
	// life of this frame, the scribble reaches disk.
	p.data[101] = 0xCD
	unpin_page(bp, 1, false)
	fetch_page(bp, 2)
	got := _on_disk(path, 1)
	testing.expect(t, got.data[101] != 0xCD, "dirty flag survived frame reuse")
}

@(test)
test_14_new_page_evicts_dirty_victim :: proc(t: ^testing.T) {
	// The same frame holds the victim's bytes (being written) and is about to
	// hold the new page. Installing the new page too early destroys the write.
	path := "/tmp/capradb_bpm_14.db"
	dm := _fresh_db(path, 1)
	defer _close_db(dm, path)
	bp := new_buffer_pool(1, dm)
	defer destroy_buffer_pool(bp)

	p := fetch_page(bp, 1)
	p.data[100] = 0xAB
	unpin_page(bp, 1, true)

	q := new_page(bp)
	testing.expect(t, q != nil, "new_page should evict")
	testing.expect_value(t, q.id, u32(2))
	got := _on_disk(path, 1)
	testing.expect_value(t, got.data[100], u8(0xAB))
}

@(test)
test_15_arc_keeps_the_hot_page :: proc(t: ^testing.T) {
	// Proves hits reach the replacer: page 1 is touched twice, so it's in T2,
	// and a one-shot scan has to churn T1 instead.
	path := "/tmp/capradb_bpm_15.db"
	dm := _fresh_db(path, 7)
	defer _close_db(dm, path)
	bp := new_buffer_pool(3, dm)
	defer destroy_buffer_pool(bp)

	fetch_page(bp, 1)
	unpin_page(bp, 1, false)
	fetch_page(bp, 1)
	unpin_page(bp, 1, false)
	for id in u32(2) ..= 7 {
		testing.expect(t, fetch_page(bp, id) != nil, "scan fetch failed")
		unpin_page(bp, id, false)
	}
	_, resident := pin_count(bp, 1)
	testing.expect(t, resident, "scan evicted the hot page")
}

// ---------------------------------------------------------------------------
// Rung 3 — flush, delete, failure, destroy.
// ---------------------------------------------------------------------------

@(test)
test_16_flush_page :: proc(t: ^testing.T) {
	path := "/tmp/capradb_bpm_16.db"
	dm := _fresh_db(path, 2)
	defer _close_db(dm, path)
	bp := new_buffer_pool(1, dm)
	defer destroy_buffer_pool(bp)

	testing.expect(t, !flush_page(bp, 1), "flush of a non-resident page")

	p := fetch_page(bp, 1)
	p.data[100] = 0xAB
	unpin_page(bp, 1, true)
	testing.expect(t, flush_page(bp, 1), "flush_page")
	got := _on_disk(path, 1)
	testing.expect_value(t, got.data[100], u8(0xAB))

	// flush cleared the flag, so this scribble must not reach disk.
	p = fetch_page(bp, 1)
	p.data[100] = 0xCD
	unpin_page(bp, 1, false)
	fetch_page(bp, 2)
	got = _on_disk(path, 1)
	testing.expect_value(t, got.data[100], u8(0xAB))
}

@(test)
test_17_flush_all :: proc(t: ^testing.T) {
	path := "/tmp/capradb_bpm_17.db"
	dm := _fresh_db(path, 3)
	defer _close_db(dm, path)
	bp := new_buffer_pool(3, dm)
	defer destroy_buffer_pool(bp)

	for id in u32(1) ..= 3 {
		p := fetch_page(bp, id)
		p.data[100] = 0xA0 + u8(id)
		unpin_page(bp, id, true)
	}
	flush_all(bp)
	for id in u32(1) ..= 3 {
		got := _on_disk(path, id)
		testing.expect_value(t, got.data[100], 0xA0 + u8(id))
	}
}

@(test)
test_18_delete_page :: proc(t: ^testing.T) {
	path := "/tmp/capradb_bpm_18.db"
	dm := _fresh_db(path, 2)
	defer _close_db(dm, path)
	bp := new_buffer_pool(1, dm)
	defer destroy_buffer_pool(bp)

	testing.expect(t, delete_page(bp, 2), "delete of a non-resident page")

	p := fetch_page(bp, 1)
	p.data[100] = 0xAB
	testing.expect(t, !delete_page(bp, 1), "delete of a pinned page")
	unpin_page(bp, 1, true)
	testing.expect(t, delete_page(bp, 1), "delete of an unpinned page")
	_, resident := pin_count(bp, 1)
	testing.expect(t, !resident, "deleted page still in the page table")

	// The frame is free, and the dirty bytes were dropped, not written.
	testing.expect(t, fetch_page(bp, 2) != nil, "frame wasn't freed")
	got := _on_disk(path, 1)
	testing.expect(t, got.data[100] != 0xAB, "deleted page was written")
}

@(test)
test_19_failed_read :: proc(t: ^testing.T) {
	path := "/tmp/capradb_bpm_19.db"
	dm := _fresh_db(path, 1)
	defer _close_db(dm, path)
	bp := new_buffer_pool(1, dm)
	defer destroy_buffer_pool(bp)

	testing.expect(t, fetch_page(bp, 999) == nil, "fetch of an unallocated page")
	_, resident := pin_count(bp, 999)
	testing.expect(t, !resident, "failed fetch left a page table entry")
	testing.expect(t, fetch_page(bp, 1) != nil, "failed fetch leaked the only frame")
}

@(test)
test_20_destroy_flushes :: proc(t: ^testing.T) {
	path := "/tmp/capradb_bpm_20.db"
	dm := _fresh_db(path, 1)
	defer _close_db(dm, path)

	bp := new_buffer_pool(1, dm)
	p := fetch_page(bp, 1)
	p.data[100] = 0xAB
	unpin_page(bp, 1, true)
	destroy_buffer_pool(bp)

	got := _on_disk(path, 1)
	testing.expect_value(t, got.data[100], u8(0xAB))
}

// ---------------------------------------------------------------------------
// Rung 4 — concurrency. These use the worker-parking helpers from test_04b.
// ---------------------------------------------------------------------------

@(test)
test_22_latch_not_held_across_io :: proc(t: ^testing.T) {
	// While a read is in flight, a hit on a different page has to get through.
	path := "/tmp/capradb_bpm_22.db"
	dm := _fresh_db(path, 2)
	defer _close_db(dm, path)
	bp := new_buffer_pool(3, dm)
	defer destroy_buffer_pool(bp)

	fetch_page(bp, 1)

	s: Stall
	_stall_worker(&s, bp)

	miss := Fetch_Job{bp = bp, page_id = 2}
	hit := Fetch_Job{bp = bp, page_id = 1}
	tm := _start_fetch(&miss)
	defer thread.destroy(tm)
	th := _start_fetch(&hit)
	defer thread.destroy(th)
	time.sleep(30 * time.Millisecond)

	testing.expect(t, sync.atomic_load(&hit.returned), "a hit was blocked by someone else's I/O")
	testing.expect(t, !sync.atomic_load(&miss.returned), "the miss returned before its read ran")

	_release_worker(&s)
	thread.join(tm)
	thread.join(th)
	testing.expect(t, miss.result != nil, "miss failed")
}

@(test)
test_23_read_lands_behind_write_back :: proc(t: ^testing.T) {
	// A evicts dirty page 1 while the worker is parked. C then fetches page 1
	// and misses. C's read must run after A's write-back (spec 10), or C sees
	// the stale bytes from disk.
	path := "/tmp/capradb_bpm_23.db"
	dm := _fresh_db(path, 3)
	defer _close_db(dm, path)
	bp := new_buffer_pool(2, dm)
	defer destroy_buffer_pool(bp)

	p := fetch_page(bp, 1)
	p.data[100] = 0xAB
	unpin_page(bp, 1, true)
	fetch_page(bp, 3)
	unpin_page(bp, 3, false)

	s: Stall
	_stall_worker(&s, bp)

	a := Fetch_Job{bp = bp, page_id = 2} // evicts page 1
	ta := _start_fetch(&a)
	defer thread.destroy(ta)
	_, resident := pin_count(bp, 1)
	testing.expect(t, !resident, "page 1 should have been evicted first")

	c := Fetch_Job{bp = bp, page_id = 1} // evicts page 3
	tc := _start_fetch(&c)
	defer thread.destroy(tc)
	testing.expect(t, !sync.atomic_load(&c.returned), "C returned before its read ran")

	_release_worker(&s)
	thread.join(ta)
	thread.join(tc)

	testing.expect(t, c.result != nil, "C failed")
	testing.expect_value(t, c.result.data[100], u8(0xAB))
}

@(test)
test_24_failed_read_with_two_waiters :: proc(t: ^testing.T) {
	// Both get nil, and only the last one out frees the frame. If each of
	// them frees it, the free list holds it twice.
	path := "/tmp/capradb_bpm_24.db"
	dm := _fresh_db(path, 3)
	defer _close_db(dm, path)
	bp := new_buffer_pool(1, dm)
	defer destroy_buffer_pool(bp)

	s: Stall
	_stall_worker(&s, bp)

	a := Fetch_Job{bp = bp, page_id = 999}
	b := Fetch_Job{bp = bp, page_id = 999}
	ta := _start_fetch(&a)
	defer thread.destroy(ta)
	tb := _start_fetch(&b)
	defer thread.destroy(tb)

	_release_worker(&s)
	thread.join(ta)
	thread.join(tb)

	testing.expect(t, a.result == nil && b.result == nil, "both must get nil")
	_, resident := pin_count(bp, 999)
	testing.expect(t, !resident, "failed fetch left a page table entry")

	// With a one-frame pool, a frame on the free list twice shows up as two
	// pages "both pinned at once".
	testing.expect(t, fetch_page(bp, 1) != nil, "frame was leaked")
	testing.expect(t, fetch_page(bp, 2) == nil, "frame was freed twice")
}

New_Job :: struct {
	bp:  ^Buffer_Pool,
	ids: [50]u32,
}

_new_job :: proc(j: ^New_Job) {
	for i in 0 ..< len(j.ids) {
		p := new_page(j.bp)
		if p != nil {
			j.ids[i] = p.id
			unpin_page(j.bp, p.id, true)
		}
	}
}

@(test)
test_25_concurrent_new_page :: proc(t: ^testing.T) {
	// This is the rung that needs the Disk_Manager mutex (spec 11).
	path := "/tmp/capradb_bpm_25.db"
	dm := _fresh_db(path, 0)
	defer _close_db(dm, path)
	bp := new_buffer_pool(16, dm)
	defer destroy_buffer_pool(bp)

	jobs: [8]New_Job
	threads: [8]^thread.Thread
	for i in 0 ..< 8 {
		jobs[i].bp = bp
		threads[i] = thread.create_and_start_with_poly_data(&jobs[i], _new_job, context)
	}
	for th in threads {
		thread.join(th)
		thread.destroy(th)
	}

	seen: map[u32]bool
	defer delete(seen)
	for j in jobs {
		for id in j.ids {
			testing.expect(t, id != 0, "new_page returned nil with frames available")
			testing.expect(t, !seen[id], "two new_page calls got the same page id")
			seen[id] = true
		}
	}
}

STRESS_THREADS :: 8
STRESS_PAGES :: 64
STRESS_OPS :: 500
COUNTER_OFFSET :: 200

Stress_Job :: struct {
	bp:     ^Buffer_Pool,
	tid:    u32,
	writes: [STRESS_PAGES + 1]u32, // writes this thread made, by page id
	errors: int,
}

_stress_job :: proc(j: ^Stress_Job) {
	rng := j.tid * 2654435761 + 1
	for _ in 0 ..< STRESS_OPS {
		rng = rng * 1664525 + 1013904223
		id := (rng >> 16) % STRESS_PAGES + 1

		p := fetch_page(j.bp, id)
		if p == nil || p.id != id {
			j.errors += 1
			if p != nil do unpin_page(j.bp, id, false)
			continue
		}

		// Threads only write the pages they own, so no two threads modify
		// the same bytes (spec 12). Everyone reads everything.
		owned := id % STRESS_THREADS == j.tid
		if owned {
			c, _ := utils.read_u32_le(p.data[:], COUNTER_OFFSET)
			utils.write_u32_le(p.data[:], COUNTER_OFFSET, c + 1)
			j.writes[id] += 1
		}
		unpin_page(j.bp, id, owned)
	}
}

@(test)
test_26_stress :: proc(t: ^testing.T) {
	// More pages than frames, so constant eviction, and a lost update on any
	// path shows up as a wrong counter on disk. If this flakes, run it alone
	// in a loop: one failure in fifty is a real bug.
	path := "/tmp/capradb_bpm_26.db"
	dm := _fresh_db(path, 0)
	defer _close_db(dm, path)
	for _ in 0 ..< STRESS_PAGES {
		_ = disk.allocate_page(dm)
	}

	bp := new_buffer_pool(STRESS_THREADS, dm)
	jobs: [STRESS_THREADS]Stress_Job
	threads: [STRESS_THREADS]^thread.Thread
	for i in 0 ..< STRESS_THREADS {
		jobs[i].bp = bp
		jobs[i].tid = u32(i)
		threads[i] = thread.create_and_start_with_poly_data(&jobs[i], _stress_job, context)
	}
	for th in threads {
		thread.join(th)
		thread.destroy(th)
	}
	destroy_buffer_pool(bp)

	for j in jobs {
		testing.expect_value(t, j.errors, 0)
	}
	for id in u32(1) ..= STRESS_PAGES {
		total: u32
		for j in jobs {
			total += j.writes[id]
		}
		got := _on_disk(path, id)
		c, _ := utils.read_u32_le(got.data[:], COUNTER_OFFSET)
		testing.expect_value(t, c, total)
	}
}
/*
// ---------------------------------------------------------------------------
// c1 — yours. Write one adversarial test for something the ladder misses.
// Watch it fail against the bug before you trust it passing.
// ---------------------------------------------------------------------------

*/

Flush_Job :: struct {
	bp:      ^Buffer_Pool,
	page_id: u32,
	ok:      bool,
}

_flush_job :: proc(j: ^Flush_Job) {
	j.ok = flush_page(j.bp, j.page_id)
}

@(test)
test_c1_flush_in_flight :: proc(t: ^testing.T) {
	path := "/tmp/capradb_bpm_c1.db"
	dm := _fresh_db(path, 2)
	defer _close_db(dm, path)

	bp := new_buffer_pool(1, dm)
	defer destroy_buffer_pool(bp)

	p := fetch_page(bp, 1)
	p.data[100] = 0xAB
	unpin_page(bp, 1, true)

	s: Stall
	_stall_worker(&s, bp)

	j := Flush_Job{bp = bp, page_id = 1}
	th := thread.create_and_start_with_poly_data(&j, _flush_job, context)
	defer thread.destroy(th)
	time.sleep(20 * time.Millisecond) // let it queue its write and wait

	q := new_page(bp)
	testing.expect(t, q == nil, "new_page must not evict a frame with a flush in flight")

	_release_worker(&s)
	thread.join(th)
	testing.expect(t, j.ok, "flush failed")

	got := _on_disk(path, 1)
	testing.expect_value(t, got.data[100], u8(0xAB))
}

@(test)
test_c2_flush_all_in_flight :: proc(t: ^testing.T) {
	path := "/tmp/capradb_bpm_c2.db"
	dm := _fresh_db(path, 2)
	defer _close_db(dm, path)

	bp := new_buffer_pool(1, dm)
	defer destroy_buffer_pool(bp)

	p := fetch_page(bp, 1)
	p.data[100] = 0xAB
	unpin_page(bp, 1, true)

	s: Stall
	_stall_worker(&s, bp)

	th := thread.create_and_start_with_poly_data(bp, flush_all, context)
	defer thread.destroy(th)
	time.sleep(20 * time.Millisecond) // let it queue its write and wait

	q := new_page(bp)
	testing.expect(t, q == nil, "new_page must not evict a frame with a flush in flight")

	_release_worker(&s)
	thread.join(th)

	got := _on_disk(path, 1)
	testing.expect_value(t, got.data[100], u8(0xAB))
}

@(test)
test_c3_random_churn :: proc(t: ^testing.T) {
	path := "/tmp/capradb_bpm_c3.db"
	dm := _fresh_db(path, 10)
	defer _close_db(dm, path)

	bp := new_buffer_pool(3, dm)
	defer destroy_buffer_pool(bp)

	rng := u32(12345)
	writes: [11]u8 // writes[id] = how many times we bumped page id

	for _ in 0 ..< 5000 {
		rng = rng * 1664525 + 1013904223
		id := (rng >> 16) % 10 + 1

		p := fetch_page(bp, id)
		if p == nil || p.id != id {
			testing.expect(t, false, "fetch returned the wrong page")
			return
		}

		p.data[300] += 1
		writes[id] += 1
		unpin_page(bp, id, true)
	}

	flush_all(bp)

	for id in u32(1) ..= 10 {
		got := _on_disk(path, id)
		want := _expected(id)
		testing.expect_value(t, got.data[300], want.data[300] + writes[id])
	}
}