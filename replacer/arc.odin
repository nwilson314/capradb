package replacer

import list "../linkedlist"


Entry :: struct {
    frame_id: u32,
    page_id: u32,
}

Arc :: struct {
    // maximum number of frames in the buffer pool
    c: u32,
    // target size of the MRU list
    p: u32,
    // most recently used list
    t1: ^list.LinkedList(Entry),
    // most frequently used list
    t2: ^list.LinkedList(Entry),
    // ghost MRU list
    b1: ^list.LinkedList(Entry),
    // ghost MFU list
    b2: ^list.LinkedList(Entry),

    // index, keyed on frame_id for t1 and t2
    t1_index: map[u32]^list.Node(Entry),
    t2_index: map[u32]^list.Node(Entry),
    // index, keyed on page_id for b1 and b2
    b1_index: map[u32]^list.Node(Entry),
    b2_index: map[u32]^list.Node(Entry),   
    // map of frame_id to evictable
    evictable: map[u32]bool,
    // map of frame_id to page_id
    frame_to_page: map[u32]u32,
}

new_arc :: proc(c: u32) -> ^Arc {
    arc := new(Arc)
    arc.c = c
    arc.t1 = list.new_linked_list(Entry)
    arc.t2 = list.new_linked_list(Entry)
    arc.b1 = list.new_linked_list(Entry)
    arc.b2 = list.new_linked_list(Entry)
    return arc
}

destroy_arc :: proc(arc: ^Arc) {
    list.free_linked_list(arc.t1)
    list.free_linked_list(arc.t2)
    list.free_linked_list(arc.b1)
    list.free_linked_list(arc.b2)
    delete(arc.t1_index)
    delete(arc.t2_index)
    delete(arc.b1_index)
    delete(arc.b2_index)
    delete(arc.evictable)
    delete(arc.frame_to_page)
    free(arc)
}

// Arc size is the number of evictable frames
arc_size :: proc(arc: ^Arc) -> u32 {
    size: u32 = 0
    for _, evictable in arc.evictable {
        if evictable {
            size += 1
        }
    }
    return size
}

// Finds the oldest evictable frame in the list. Returns nil if no evictable frames are found.
find_victim :: proc(arc: ^Arc, l: ^list.LinkedList(Entry)) -> ^list.Node(Entry) {
    node := l.tail
    if node == nil {
        return nil
    }
    for {
        _, ok := arc.evictable[node.data.frame_id]
        if !ok {
            if node == l.head {
                // reached the head of the list, no evictable frames found
                return nil
            }
            node = node.prev
            continue
        }
        // evictable frame found
        return node
    }
}

evict_from :: proc(
    arc: ^Arc, 
    src: ^list.LinkedList(Entry), 
    src_index: ^map[u32]^list.Node(Entry),
    ghost: ^list.LinkedList(Entry), 
    ghost_index: ^map[u32]^list.Node(Entry),
) -> (frame_id: u32, ok: bool) {
    node := find_victim(arc, src)

    if node == nil {
        return 0, false
    }

    list.remove(src, node)
    delete_key(src_index, node.data.frame_id)
    list.push_front(ghost, node)
    ghost_index[node.data.page_id] = node
    delete_key(&arc.evictable, node.data.frame_id)

    frame_id = node.data.frame_id
    ok = true

    return frame_id, ok
}

// Evicts a frame from the ARC. Returns the frame_id and a boolean indicating if an eviction was successful.
evict :: proc(arc: ^Arc) -> (frame_id: u32, ok: bool) {
    if arc_size(arc) == 0 {
        return 0, false
    }

    if arc.t1.size >= arc.p {
        frame_id, ok = evict_from(arc, arc.t1, &arc.t1_index, arc.b1, &arc.b1_index)
        if !ok {
            frame_id, ok = evict_from(arc, arc.t2, &arc.t2_index, arc.b2, &arc.b2_index)
        }
    } else {
        frame_id, ok = evict_from(arc, arc.t2, &arc.t2_index, arc.b2, &arc.b2_index)
        if !ok {
            frame_id, ok = evict_from(arc, arc.t1, &arc.t1_index, arc.b1, &arc.b1_index)
        }
    }

    if ok {
        // trim ghosts
        if arc.b1.size + arc.t1.size > arc.c {
            // evict oldest from B1
            node := list.pop_back(arc.b1)
            defer free(node)
            delete_key(&arc.b1_index, node.data.page_id)
        }
        if arc.b2.size + arc.t2.size + arc.t1.size + arc.b1.size > 2 * arc.c {
            // evict oldest from B2
            node := list.pop_back(arc.b2)
            defer free(node)
            delete_key(&arc.b2_index, node.data.page_id)
        }
    }

    return frame_id, ok
}


record_access :: proc(arc: ^Arc, frame_id: u32, page_id: u32) {
    // Check if the frame is already in the ARC
    if _, ok := arc.t1_index[frame_id]; ok {
        // Frame is in the MRU list, move to MFU list
        list.remove(arc.t1, arc.t1_index[frame_id])
        list.push_front(arc.t2, arc.t1_index[frame_id])
        delete_key(&arc.t1_index, frame_id)
        arc.t2_index[frame_id] = arc.t2.head
        return 
    }

    if _, ok := arc.t2_index[frame_id]; ok {
        // Frame is in the MFU list, move to front
        elem := arc.t2_index[frame_id]
        list.remove(arc.t2, elem)
        list.push_front(arc.t2, elem)
        return
    }

    // Check if the frame is in the ghost MRU list
    if _, ok := arc.b1_index[page_id]; ok {
        // Page is in the ghost MRU list, move to T2 front
        // grow p
        // recency was starved in b1 hit
        arc.p = min(arc.c, arc.p + max(1, arc.b2.size / arc.b1.size))
        elem := arc.b1_index[page_id]
        list.remove(arc.b1, elem)
        elem.data.frame_id = frame_id
        list.push_front(arc.t2, elem)
        delete_key(&arc.b1_index, page_id)
        arc.t2_index[frame_id] = elem
        return
    }

    // Check if the frame is in the ghost MFU list
    if _, ok := arc.b2_index[page_id]; ok {
        // Page is in the ghost MFU list, move to T2 front
        // shrink p
        // freqency was starved in b2 hit
        sub := max(1, arc.b1.size / arc.b2.size)
        if sub > arc.p {
            arc.p = 0
        } else {
            arc.p = arc.p - sub
        }
        elem := arc.b2_index[page_id]
        list.remove(arc.b2, elem)
        elem.data.frame_id = frame_id
        list.push_front(arc.t2, elem)
        delete_key(&arc.b2_index, page_id)
        arc.t2_index[frame_id] = elem

        return
    }

    // Frame is not in the ARC, add to MRU
    node := new(list.Node(Entry))
    node.data.frame_id = frame_id
    node.data.page_id = page_id
    list.push_front(arc.t1, node)
    arc.t1_index[frame_id] = node
}

set_evictable :: proc(arc: ^Arc, frame_id: u32, evictable: bool) {
    if evictable {
        // first check if frame even exists in the ARC
        _, ok1 := arc.t1_index[frame_id]
        _, ok2 := arc.t2_index[frame_id]

        if ok1 || ok2 {
            arc.evictable[frame_id] = true
        }
    } else {
        delete_key(&arc.evictable, frame_id)
    }
}

// Removes a frame entirely from the ARC
remove :: proc(arc: ^Arc, frame_id: u32) {
    if _, ok := arc.t1_index[frame_id]; ok {
        node := arc.t1_index[frame_id]
        list.remove(arc.t1, node)
        delete_key(&arc.t1_index, frame_id)
        free(node)

        if _, ok := arc.evictable[frame_id]; ok {
            delete_key(&arc.evictable, frame_id)
        }
        return
    }

    if _, ok := arc.t2_index[frame_id]; ok {
        node := arc.t2_index[frame_id]
        list.remove(arc.t2, node)
        delete_key(&arc.t2_index, frame_id)
        free(node)

        if _, ok := arc.evictable[frame_id]; ok {
            delete_key(&arc.evictable, frame_id)
        }
        return
    }
}