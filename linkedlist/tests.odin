package linkedlist

import "core:testing"

@(test)
test_new_linked_list :: proc(t: ^testing.T) {
    list := new_linked_list(int)
    defer free_linked_list(list)

    testing.expect_value(t, list.size, 0)
    testing.expect(t, list.head == nil)
    testing.expect(t, list.tail == nil)
}

@(test)
test_push_front :: proc(t: ^testing.T) {
    list := new_linked_list(int)
    defer free_linked_list(list)

    node := new(Node(int))
    node.data = 1
    push_front(list, node)
    testing.expect_value(t, list.size, 1)
    testing.expect(t, list.head == node)
    testing.expect(t, list.tail == node)
}

@(test)
test_push_back :: proc(t: ^testing.T) {
    list := new_linked_list(int)
    defer free_linked_list(list)

    node := new(Node(int))
    node.data = 1
    push_back(list, node)
    testing.expect_value(t, list.size, 1)
    testing.expect(t, list.head == node)
    testing.expect(t, list.tail == node)
}

@(test)
test_pop_front :: proc(t: ^testing.T) {
    list := new_linked_list(int)
    defer free_linked_list(list)

    node := new(Node(int))
    node.data = 1
    push_front(list, node)
    testing.expect_value(t, list.size, 1)
    testing.expect(t, list.head == node)
    testing.expect(t, list.tail == node)
    popped_node := pop_front(list)
    testing.expect_value(t, list.size, 0)
    testing.expect(t, list.head == nil)
    testing.expect(t, list.tail == nil)
    testing.expect(t, popped_node == node)
    free(popped_node)
}

@(test)
test_pop_back :: proc(t: ^testing.T) {
    list := new_linked_list(int)
    defer free_linked_list(list)
    node := new(Node(int))
    node.data = 1
    push_back(list, node)
    testing.expect_value(t, list.size, 1)
    testing.expect(t, list.head == node)
    testing.expect(t, list.tail == node)
    popped_node := pop_back(list)
    testing.expect_value(t, list.size, 0)
    testing.expect(t, list.head == nil)
    testing.expect(t, list.tail == nil)
    testing.expect(t, popped_node == node)
    free(popped_node)
}

// Fail case: moving a node between lists (the ARC promotion sequence) must
// not drag stale links along. A node's prev/next belong to ONE list at a
// time — pop/remove must sever them (or push must clear them). If they
// don't, the destination list's tail can end up pointing at a node that
// lives in the source list, and evictions read from the wrong list.
@(test)
test_move_node_between_lists :: proc(t: ^testing.T) {
    la := new_linked_list(int)
    lb := new_linked_list(int)
    defer free_linked_list(la)
    defer free(lb) // lb's only node is freed manually below, so skip the walk

    x := new(Node(int))
    x.data = 1
    defer free(x)
    y := new(Node(int))
    y.data = 2

    // la = [y <-> x], x is the tail
    push_front(la, x)
    push_front(la, y)

    // move x from la to lb
    moved := pop_back(la)
    testing.expect(t, moved == x)
    testing.expect(t, moved.prev == nil, "popped node still linked to its old list")
    testing.expect(t, moved.next == nil, "popped node still linked to its old list")
    push_front(lb, moved)

    // la must be intact on its own
    testing.expect_value(t, la.size, 1)
    testing.expect(t, la.head == y && la.tail == y)

    // pop x back out of lb: with a stale prev, lb.tail becomes y — a node
    // that was never in lb
    popped := pop_back(lb)
    testing.expect(t, popped == x)
    testing.expect_value(t, lb.size, 0)
    testing.expect(t, lb.head == nil, "lb.head must be nil after popping its only node")
    testing.expect(t, lb.tail == nil, "lb.tail points into the OTHER list — stale prev was followed")
}

@(test)
test_remove :: proc(t: ^testing.T) {
    list := new_linked_list(int)
    defer free_linked_list(list)
    node := new(Node(int))
    defer free(node)
    node.data = 1
    push_front(list, node)
    testing.expect_value(t, list.size, 1)
    testing.expect(t, list.head == node)
    testing.expect(t, list.tail == node)
    remove(list, node)
    testing.expect_value(t, list.size, 0)
    testing.expect(t, list.head == nil)
    testing.expect(t, list.tail == nil)
}