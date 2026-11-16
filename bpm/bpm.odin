package bpm

import "core:sync"

import disk "../disk"
import pg "../page"
import "../replacer"
import sc "../scheduler"


// =============================================================================
// LATCHING
// =============================================================================
//
// What protects what
// ------------------
//   Pool latch    bp.latch           Mutex     Bookkeeping: page_table,
//                                              free_list, the replacer, and
//                                              every Frame field except page
//                                              (page_id, pin_count, is_dirty,
//                                              writing, io).
//
//   Frame latch   Frame.page_latch   RW_Mutex  The page bytes. Shared to
//                                              read, exclusive to write.
//
//   Pin           pin_count > 0      counter   Keeps a frame bound to its
//                                              page. Eviction and delete_page
//                                              skip pinned frames. Nobody
//                                              ever waits on a pin.
//
// The rule
// --------
//   Never wait for a frame latch or for I/O while holding the pool latch.
//   Every path here goes further: it drops one latch before taking the other.
//
// Guards
// ------
//   Acquire:  1. pool latch { find or claim the frame, pin }
//             2. wait for the read to finish
//             3. take the frame latch (shared or exclusive)
//
//   Release:  1. drop the frame latch
//             2. unpin (takes the pool latch, sets dirty)
//
//   Unlatch before unpin: once the pin hits 0 the frame can be evicted and
//   reused, and we must not still hold its latch.
//
// Eviction
// --------
//   Takes no frame latch. pin_count == 0 means no guard holds one and no
//   flush is in flight.
//
// flush_page
// ----------
//   1. pool latch { clear dirty, pin, writing = true }
//   2. shared frame latch { schedule the write, wait }
//   3. pool latch { writing = false, broadcast, re-dirty on failure }
//   4. unpin
//
//   - After step 1, flush only ever sets dirty, never clears it: a writer
//     may have dirtied the page mid-flush.
//   - A flush that finds writing == true waits on bp.cond for that write to
//     land.
//
// Never flush a page you hold a guard on (spec 17)
// ------------------------------------------------
//   - Holding a write guard: the flush's shared latch waits on you.
//   - Holding a read guard: a writer queued behind you blocks the flush's
//     shared latch, and that writer is waiting for you.

Frame :: struct {
    page_latch: sync.RW_Mutex,
    page: pg.Page,
    page_id: u32, 
    pin_count: u32,
    is_dirty: bool,
    io: sc.Completion,
    writing: bool,
}

Buffer_Pool :: struct {
    latch: sync.Mutex,
    cond: sync.Cond,
    frames: []Frame,
    page_table: map[u32]u32, // page_id -> frame_index
    free_list: [dynamic]u32,
    arc: ^replacer.Arc,
    sched: ^sc.Disk_Scheduler,
    dm: ^disk.Disk_Manager,
}

new_buffer_pool :: proc(num_pages: u32, dm: ^disk.Disk_Manager) -> ^Buffer_Pool {
    bp := new(Buffer_Pool)
    bp.frames = make([]Frame, num_pages)
    bp.free_list = make([dynamic]u32, 0, num_pages)
    for i in 0..<num_pages {
        append(&bp.free_list, i)
    }
    bp.arc = replacer.new_arc(num_pages)
    bp.page_table = make(map[u32]u32)
    bp.dm = dm
    bp.sched = sc.new_disk_scheduler(dm)

    return bp
}

destroy_buffer_pool :: proc(bp: ^Buffer_Pool) {
    flush_all(bp)
    sc.destroy_disk_scheduler(bp.sched)
    delete(bp.frames)
    delete(bp.free_list)
    replacer.destroy_arc(bp.arc)
    delete(bp.page_table)
    free(bp)
}

// Claims a frame for a given page_id. If the page is already in the buffer pool, it will return that frame.
// Otherwise, it will attempt to claim a new frame. If there are no free frames, it will evict a frame, 
// request the page from disk, and return the newly claimed frame. If the request fails, it will return nil.
// Assumes that the caller has already acquired the latch.
_get_or_claim_frame :: proc(bp: ^Buffer_Pool, page_id: u32, wb: ^sc.Completion) -> (f: ^Frame, f_found: bool, wrote: bool, f_ok: bool) {
    frame_index, ok := bp.page_table[page_id]
    if !ok {
        wrote = false
        // page is not yet in the buffer pool
        if len(bp.free_list) == 0 {
            // no free frames, need to evict
            f_i, evict_ok := replacer.evict(bp.arc)
            if !evict_ok do return nil, false, false, false
            frame_index = f_i
        } else {
            frame_index = pop(&bp.free_list)
        }

        // new frame so zero out the frame
        f = &bp.frames[frame_index]
        if f.page_id != 0 {
            delete_key(&bp.page_table, f.page_id)
            if f.is_dirty {
                req := sc.Disk_Request{
                    is_write=true,
                    page_id=f.page_id,
                    buf=&f.page,
                    done=wb, // write back completion
                }
                wrote = true
                sc.schedule(bp.sched, req)
            }
        }
        f.page_id = page_id
        f.pin_count = 1
        f.is_dirty = false
        f.io = {}
        
        bp.page_table[page_id] = frame_index

        replacer.record_access(bp.arc, frame_index, page_id)
        replacer.set_evictable(bp.arc, frame_index, false)

        return f, false, wrote, true
    }

    // page is already in the buffer pool
    f = &bp.frames[frame_index]
    f.pin_count += 1
    replacer.record_access(bp.arc, frame_index, page_id)
    replacer.set_evictable(bp.arc, frame_index, false)
    return f, true, false, true
}

// unwinds a failed page load op
_fail_load :: proc(bp: ^Buffer_Pool, frame_index: u32) {
    sync.mutex_lock(&bp.latch)
    defer sync.mutex_unlock(&bp.latch)

    f := &bp.frames[frame_index]

    f.pin_count -= 1
    if f.pin_count == 0 {
        delete_key(&bp.page_table, f.page_id)
        replacer.remove(bp.arc, frame_index)
        f.page_id = 0
        f.pin_count = 0
        f.is_dirty = false
        f.io = {}
        append(&bp.free_list, frame_index)
    }
}

_new_frame :: proc(bp: ^Buffer_Pool) -> (^Frame, bool) {
    page := disk.allocate_page(bp.dm)
    sync.mutex_lock(&bp.latch)
    wb: sc.Completion
    f, _, wrote, f_ok := _get_or_claim_frame(bp, page.id, &wb)
    if !f_ok {
        sync.mutex_unlock(&bp.latch)
        return nil, false
    }

    sync.mutex_unlock(&bp.latch)

    if wrote {
        ok := sc.wait(&wb)
        assert(ok)
    }
    f.page = page

    sc.complete(&f.io, true)
    
    return f, true
}

@(private)
new_page :: proc(bp: ^Buffer_Pool) -> ^pg.Page {
    f, ok := _new_frame(bp)

    if !ok do return nil

    return &f.page
}

pin_count :: proc(bp: ^Buffer_Pool, page_id: u32) -> (u32, bool) {
    sync.mutex_lock(&bp.latch)
    defer sync.mutex_unlock(&bp.latch)
    frame_index, ok := bp.page_table[page_id]
    if !ok {
        return 0, false
    }
    f := &bp.frames[frame_index]
    return f.pin_count, true
}

_fetch_frame :: proc(bp: ^Buffer_Pool, page_id: u32) -> (frame: ^Frame, ok: bool) {
    sync.mutex_lock(&bp.latch)

    wb: sc.Completion
    f, f_found, wrote, f_ok := _get_or_claim_frame(bp, page_id, &wb)
    if !f_ok {
        sync.mutex_unlock(&bp.latch)
        return nil, false
    }

    if !f_found {
        req := sc.Disk_Request{
            is_write=false,
            page_id=page_id,
            buf=&f.page,
            done=&f.io,
        }
        sc.schedule(bp.sched, req)
    }
    frame_index := bp.page_table[page_id]
    sync.mutex_unlock(&bp.latch)
    if wrote {
        ok_wait := sc.wait(&wb)
        assert(ok_wait)
    }
    ok_wait := sc.wait(&f.io)
    if !ok_wait {
        _fail_load(bp, frame_index)
        return nil, false
    }

    return f, true
}

@(private)
fetch_page :: proc(bp: ^Buffer_Pool, page_id: u32) -> ^pg.Page {
    f, ok := _fetch_frame(bp, page_id)
    if !ok {
        return nil
    }

    return &f.page
}

@(private)
unpin_page :: proc(bp: ^Buffer_Pool, page_id: u32, is_dirty: bool) -> bool {
    sync.mutex_lock(&bp.latch)
    defer sync.mutex_unlock(&bp.latch)

    frame_index, ok := bp.page_table[page_id]
    if !ok do return false

    f := &bp.frames[frame_index]
    if f.pin_count == 0 do return false

    f.pin_count -= 1
    if f.pin_count == 0 {
        replacer.set_evictable(bp.arc, frame_index, true)
    }

    if is_dirty {
        f.is_dirty = true
    }

    return true
}

flush_page :: proc(bp: ^Buffer_Pool, page_id: u32) -> bool {
    sync.mutex_lock(&bp.latch)

    frame_id, ok := bp.page_table[page_id]
    if !ok {
        sync.mutex_unlock(&bp.latch)
        return false
    }

    f := &bp.frames[frame_id]

    if !f.is_dirty {
        for f.writing {
            sync.cond_wait(&bp.cond, &bp.latch)
        }
        sync.mutex_unlock(&bp.latch)
        return true
    }

    f.is_dirty = false

    f.pin_count += 1
    f.writing = true
    replacer.set_evictable(bp.arc, frame_id, false)
    
    sync.mutex_unlock(&bp.latch)

    c: sc.Completion
    req := sc.Disk_Request{
        is_write=true,
        page_id=page_id,
        buf=&f.page,
        done=&c,
    }

    sync.rw_mutex_shared_lock(&f.page_latch)

    sc.schedule(bp.sched, req)
    ok_wait := sc.wait(&c)

    sync.rw_mutex_shared_unlock(&f.page_latch)
    
    sync.mutex_lock(&bp.latch)
    f.writing = false
    sync.cond_broadcast(&bp.cond)
    if !ok_wait do f.is_dirty = true
    sync.mutex_unlock(&bp.latch)

    unpin_page(bp, page_id, false)
    return ok_wait
}

flush_all :: proc(bp: ^Buffer_Pool) {
    sync.mutex_lock(&bp.latch)
    page_ids: [dynamic]u32
    defer delete(page_ids)

    for page_id, _ in bp.page_table {
        append(&page_ids, page_id)
    }
    sync.mutex_unlock(&bp.latch)

    for page_id in page_ids {
        flush_page(bp, page_id)
    }
}

delete_page :: proc(bp: ^Buffer_Pool, page_id: u32) -> bool {
    sync.mutex_lock(&bp.latch)
    defer sync.mutex_unlock(&bp.latch)

    frame_index, ok := bp.page_table[page_id]
    if !ok do return true

    f := &bp.frames[frame_index]
    if f.pin_count > 0 do return false

    delete_key(&bp.page_table, page_id)
    replacer.remove(bp.arc, frame_index)
    f.page_id = 0
    f.pin_count = 0
    f.is_dirty = false
    f.io = {}
    append(&bp.free_list, frame_index)

    return true
}


/////////////////// Page Guards

Guard :: struct {
    page_id: u32,
    bp: ^Buffer_Pool,
    frame: ^Frame,
    released: bool,
    page: ^pg.Page,
}

Read_Guard :: struct {
    using guard: Guard,
}

Write_Guard :: struct {
    using guard: Guard,
}

_fetch_guard :: proc(bp: ^Buffer_Pool, page_id: u32, is_write: bool) -> (Guard, bool) {
    guard: Guard
    frame, ok := _fetch_frame(bp, page_id)
    if !ok {
        return Guard{}, false
    }

    if is_write {
        sync.rw_mutex_lock(&frame.page_latch)
    } else {
        sync.rw_mutex_shared_lock(&frame.page_latch)
    }

    guard.bp = bp
    guard.frame = frame
    guard.page_id = page_id
    guard.page = &frame.page

    return guard, true
}


fetch_page_read :: proc(bp: ^Buffer_Pool, page_id: u32) -> (Read_Guard, bool) {
    guard, ok := _fetch_guard(bp, page_id, false)
    if !ok {
        return Read_Guard{}, false
    }

    return Read_Guard{guard}, true
}

release_read :: proc(g: ^Read_Guard) {
    if g.released || g.frame == nil do return
    sync.rw_mutex_shared_unlock(&g.frame.page_latch)
    unpin_page(g.bp, g.page_id, false)
    g.released = true
}

new_page_write :: proc(bp: ^Buffer_Pool) -> (Write_Guard, bool) {
    f, ok := _new_frame(bp)

    if !ok do return Write_Guard{}, false

    sync.rw_mutex_lock(&f.page_latch)

    return Write_Guard{
        page_id=f.page_id,
        bp=bp,
        frame=f,
        released=false,
        page=&f.page,
    }, true
}

fetch_page_write :: proc(bp: ^Buffer_Pool, page_id: u32) -> (Write_Guard, bool) {
    guard, ok := _fetch_guard(bp, page_id, true)
    if !ok {
        return Write_Guard{}, false
    }

    return Write_Guard{guard}, true
}

release_write :: proc(g: ^Write_Guard) {
    if g.released || g.frame == nil do return
    sync.rw_mutex_unlock(&g.frame.page_latch)
    unpin_page(g.bp, g.page_id, true)
    g.released = true
}