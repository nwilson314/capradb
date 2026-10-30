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

// new_buffer_pool :: proc()