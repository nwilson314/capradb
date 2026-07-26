package linkedlist

LinkedList :: struct($T: typeid) {
    size: u32,
    head: ^Node(T),
    tail: ^Node(T),
}

Node :: struct($T: typeid) {
    next: ^Node(T),
    prev: ^Node(T),
    data: T,
}

new_linked_list :: proc($T: typeid) -> ^LinkedList(T) {
    list := new(LinkedList(T))
    list.head = nil
    list.tail = nil
    return list
}

free_linked_list :: proc(list: ^LinkedList($T)) {
    node := list.head
    for node != nil {
        next := node.next
        free(node)
        node = next
    }
    free(list)
}

is_empty :: proc(list: ^LinkedList($T)) -> bool {
    return list.size == 0
}

push_front :: proc(list: ^LinkedList($T), node: ^Node(T)) {
    if list.head == nil {
        list.head = node
        list.tail = node
        list.size = 1
    } else {
        node.next = list.head
        list.head.prev = node
        list.head = node
        list.size += 1
    }
}

push_back :: proc(list: ^LinkedList($T), node: ^Node(T)) {
    if list.tail == nil {
        list.head = node
        list.tail = node
        list.size = 1
    } else {
        node.prev = list.tail
        list.tail.next = node
        list.tail = node
        list.size += 1
    }
}

pop_front :: proc(list: ^LinkedList($T)) -> ^Node(T) {
    if list.head == nil {
        return nil
    }
    node := list.head
    list.head = node.next
    if list.head == nil {
        list.tail = nil
    } else {
        list.head.prev = nil
    }
    list.size -= 1
    // clear the node's prev and next pointers
    node.prev = nil
    node.next = nil
    return node
}

pop_back :: proc(list: ^LinkedList($T)) -> ^Node(T) {
    if list.tail == nil {
        return nil
    }
    node := list.tail
    list.tail = node.prev
    if list.tail == nil {
        list.head = nil
    } else {
        list.tail.next = nil
    }
    list.size -= 1
    // clear the node's prev and next pointers
    node.prev = nil
    node.next = nil
    return node
}

remove :: proc(list: ^LinkedList($T), node: ^Node(T)) {
    if node == list.head {
        list.head = node.next
        if list.head == nil {
            list.tail = nil
        } else {
            list.head.prev = nil
        }
    } else if node == list.tail {
        list.tail = node.prev
        if list.tail == nil {
            list.head = nil
        } else {
            list.tail.next = nil
        }
    } else {
        node.prev.next = node.next
        node.next.prev = node.prev
    }
    list.size -= 1
    // clear the node's prev and next pointers
    node.prev = nil
    node.next = nil
}