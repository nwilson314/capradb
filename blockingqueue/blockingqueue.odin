package blockingqueue

import "core:sync"
import "core:mem"
import list "../linkedlist"

Blocking_Queue :: struct($T: typeid) {
    list: ^list.Linked_List(T),
    mutex: sync.Mutex,
    cond: sync.Cond,
    allocator: mem.Allocator,
}

new_blocking_queue :: proc($T: typeid) -> ^Blocking_Queue(T) {
    queue := new(Blocking_Queue(T))
    queue.list = list.new_linked_list(T)
    queue.allocator = context.allocator
    return queue
}

destroy_blocking_queue :: proc(queue: ^Blocking_Queue($T)) {
    list.free_linked_list(queue.list)
    free(queue)
}

push :: proc(q: ^Blocking_Queue($T), item: T) {
    sync.mutex_lock(&q.mutex)
    defer sync.mutex_unlock(&q.mutex)

    node := new(list.Node(T), q.allocator)
    node.data = item
    list.push_back(q.list, node)

    sync.cond_signal(&q.cond)
}


pop :: proc(q: ^Blocking_Queue($T)) -> T {
    sync.mutex_lock(&q.mutex)
    defer sync.mutex_unlock(&q.mutex)

    for q.list.size == 0 {
        sync.cond_wait(&q.cond, &q.mutex)
    }
    
    node := list.pop_front(q.list)
    data := node.data
    mem.free(node, q.allocator)
    return data
}