package bpm

import "core:sync"

import disk "../disk"
import pg "../page"
import "../replacer"
import sc "../scheduler"


Frame :: struct {
    page: pg.Page,
    page_id: u32, 
    pin_count: u32,
    is_dirty: bool,
    io: sc.Completion,
}

Buffer_Pool :: struct {
    latch: sync.Mutex,
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

new_page :: proc(bp: ^Buffer_Pool) -> ^pg.Page {
    page := disk.allocate_page(bp.dm)
    sync.mutex_lock(&bp.latch)
    wb: sc.Completion
    f, _, wrote, f_ok := _get_or_claim_frame(bp, page.id, &wb)
    if !f_ok {
        sync.mutex_unlock(&bp.latch)
        return nil
    }

    sync.mutex_unlock(&bp.latch)

    if wrote {
        ok := sc.wait(&wb)
        assert(ok)
    }
    f.page = page

    sc.complete(&f.io, true)

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

fetch_page :: proc(bp: ^Buffer_Pool, page_id: u32) -> ^pg.Page {
    sync.mutex_lock(&bp.latch)

    wb: sc.Completion
    f, f_found, wrote, f_ok := _get_or_claim_frame(bp, page_id, &wb)
    if !f_ok {
        sync.mutex_unlock(&bp.latch)
        return nil
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
        return nil
    }

    return &f.page
}

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
        sync.mutex_unlock(&bp.latch)
        return true
    }

    f.is_dirty = false

    f.pin_count += 1
    replacer.set_evictable(bp.arc, frame_id, false)
    
    c: sc.Completion
    req := sc.Disk_Request{
        is_write=true,
        page_id=page_id,
        buf=&f.page,
        done=&c,
    }
    sc.schedule(bp.sched, req)

    sync.mutex_unlock(&bp.latch)
    ok_wait := sc.wait(&c)
    unpin_page(bp, page_id, false)
    return ok_wait
}

flush_all :: proc(bp: ^Buffer_Pool) {
    cs := make([]sc.Completion, len(bp.frames))
    used := make([]bool, len(bp.frames))
    defer delete(cs)
    defer delete(used)

    sync.mutex_lock(&bp.latch)

    for page_id, frame_index in bp.page_table {
        f := &bp.frames[frame_index]
        if !f.is_dirty {
            continue
        }

        f.is_dirty = false

        f.pin_count += 1
        replacer.set_evictable(bp.arc, frame_index, false)

        req := sc.Disk_Request{
            is_write=true,
            page_id=page_id,
            buf=&f.page,
            done=&cs[frame_index],
        }
        sc.schedule(bp.sched, req)
        used[frame_index] = true
    }

    sync.mutex_unlock(&bp.latch)

    for u, i in used {
        if !u do continue
        ok := sc.wait(&cs[i])
        unpin_page(bp, bp.frames[i].page_id, false)
        assert(ok)
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