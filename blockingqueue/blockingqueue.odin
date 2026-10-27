package blockingqueue

import "core:fmt"
import "core:sync"
import "core:mem"
import list "../linkedlist"

BlockingQueue :: struct($T: typeid) {
    list: ^list.LinkedList(T),
    mutex: sync.Mutex,
    cond: sync.Cond,
    allocator: mem.Allocator,
}

new_blocking_queue :: proc($T: typeid) -> ^BlockingQueue(T) {
    queue := new(BlockingQueue(T))
    queue.list = list.new_linked_list(T)
    queue.allocator = context.allocator
    return queue
}

destroy_blocking_queue :: proc(queue: ^BlockingQueue($T)) {
    list.free_linked_list(queue.list)
    free(queue)
}

push :: proc(q: ^BlockingQueue($T), item: T) {
    sync.mutex_lock(&q.mutex)
    defer sync.mutex_unlock(&q.mutex)

    node := new(list.Node(T), q.allocator)
    node.data = item
    list.push_back(q.list, node)

    sync.cond_signal(&q.cond)
}


pop :: proc(q: ^BlockingQueue($T)) -> T {
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