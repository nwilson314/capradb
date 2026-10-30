package scheduler

import "core:sync"
import "core:thread"
import bq "../blockingqueue"
import "../disk"
import pg "../page"

Completion :: struct {
    mutex: sync.Mutex,
    cond:  sync.Cond,
    done:  bool,
    ok:    bool,
}

complete :: proc(c: ^Completion, ok: bool) {
    sync.mutex_lock(&c.mutex)
    c.done = true
    c.ok = ok
    sync.cond_broadcast(&c.cond)
    sync.mutex_unlock(&c.mutex)
}

wait :: proc(c: ^Completion) -> bool {
    sync.mutex_lock(&c.mutex)
    for !c.done {
        sync.cond_wait(&c.cond, &c.mutex)
    }
    ok := c.ok
    sync.mutex_unlock(&c.mutex)
    return ok
}

Disk_Scheduler :: struct {
    dm: ^disk.DiskManager,
    queue: ^bq.BlockingQueue(Maybe(Disk_Request)),
    worker: ^thread.Thread,
}

Disk_Request :: struct {
    is_write: bool,
    page_id: u32,
    buf: ^pg.Page,
    done: ^Completion,
}

new_disk_scheduler :: proc(dm: ^disk.DiskManager) -> ^Disk_Scheduler {
    sc := new(Disk_Scheduler)

    sc.dm = dm
    sc.queue = bq.new_blocking_queue(Maybe(Disk_Request))
    sc.worker = thread.create_and_start_with_poly_data(sc, _worker_loop, context)

    return sc
}

destroy_disk_scheduler :: proc(sc: ^Disk_Scheduler) {
    bq.push(sc.queue, nil)
    thread.join(sc.worker)
    thread.destroy(sc.worker)
    bq.destroy_blocking_queue(sc.queue)
    free(sc)
}

_worker_loop :: proc(sc: ^Disk_Scheduler) {
    for {
        req_maybe := bq.pop(sc.queue)
        req, ok := req_maybe.? ; if !ok do return

        if req.is_write {
            ok := disk.write_page(sc.dm, req.buf)
            if !ok {
                complete(req.done, false)
                continue
            }
            complete(req.done, true)
        } else {
            buf, ok := disk.read_page(sc.dm, req.page_id)
            if !ok {
                complete(req.done, false)
                continue
            }
            req.buf^ = buf
            complete(req.done, true)
        }
    }
}

schedule :: proc(sc: ^Disk_Scheduler, req: Disk_Request) {
    bq.push(sc.queue, req)
}