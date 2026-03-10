package page

import (
	"encoding/binary"
	"testing"
)

func TestNewBTreePageLeaf(t *testing.T) {
	p := NewBTreePage(1, BTreeNodeTypeLeaf)

	// Page ID
	if p.ID != 1 {
		t.Errorf("expected page ID 1, got %d", p.ID)
	}
	pageID := binary.LittleEndian.Uint32(p.Data[0:4])
	if pageID != 1 {
		t.Errorf("expected page ID in bytes to be 1, got %d", pageID)
	}

	// LSN should be 0
	lsn := binary.LittleEndian.Uint32(p.Data[4:8])
	if lsn != 0 {
		t.Errorf("expected LSN 0, got %d", lsn)
	}

	// Node type should be leaf (0)
	nodeType := binary.LittleEndian.Uint32(p.Data[8:12])
	if nodeType != 0 {
		t.Errorf("expected node type 0 (leaf), got %d", nodeType)
	}

	// Current size should be 0
	currentSize := binary.LittleEndian.Uint16(p.Data[12:14])
	if currentSize != 0 {
		t.Errorf("expected current size 0, got %d", currentSize)
	}

	// Max size for leaf: (4096 - 20) / 14 = 291
	maxSize := binary.LittleEndian.Uint16(p.Data[14:16])
	if maxSize != 291 {
		t.Errorf("expected max size 291, got %d", maxSize)
	}

	// Sibling pointer should be 0xFFFFFFFF (no sibling)
	sibling := binary.LittleEndian.Uint32(p.Data[16:20])
	if sibling != 0xFFFFFFFF {
		t.Errorf("expected sibling pointer 0xFFFFFFFF, got %d", sibling)
	}
}

func TestNewBTreePageInternal(t *testing.T) {
	p := NewBTreePage(5, BTreeNodeTypeInternal)

	// Page ID
	if p.ID != 5 {
		t.Errorf("expected page ID 5, got %d", p.ID)
	}

	// Node type should be internal (1)
	nodeType := binary.LittleEndian.Uint32(p.Data[8:12])
	if nodeType != 1 {
		t.Errorf("expected node type 1 (internal), got %d", nodeType)
	}

	// Current size should be 0
	currentSize := binary.LittleEndian.Uint16(p.Data[12:14])
	if currentSize != 0 {
		t.Errorf("expected current size 0, got %d", currentSize)
	}

	// Max size for internal: (4096 - 20) / 12 = 339
	maxSize := binary.LittleEndian.Uint16(p.Data[14:16])
	if maxSize != 339 {
		t.Errorf("expected max size 339, got %d", maxSize)
	}

	// Rightmost child pointer should be 0xFFFFFFFF (no child)
	rightmost := binary.LittleEndian.Uint32(p.Data[16:20])
	if rightmost != 0xFFFFFFFF {
		t.Errorf("expected rightmost child pointer 0xFFFFFFFF, got %d", rightmost)
	}
}

func TestBTreeIsLeafNode(t *testing.T) {
	leaf := NewBTreePage(1, BTreeNodeTypeLeaf)
	if !leaf.IsLeafNode() {
		t.Error("expected leaf node to return true for IsLeafNode")
	}

	internal := NewBTreePage(2, BTreeNodeTypeInternal)
	if internal.IsLeafNode() {
		t.Error("expected internal node to return false for IsLeafNode")
	}
}

func TestBTreeInsertEntryInternalAppend(t *testing.T) {
	p := NewBTreePage(1, BTreeNodeTypeInternal)

	// Insert keys in order: 10, 20, 30
	if err := p.InsertEntryInternal(10, 100); err != nil {
		t.Fatalf("insert key 10: %v", err)
	}
	if err := p.InsertEntryInternal(20, 200); err != nil {
		t.Fatalf("insert key 20: %v", err)
	}
	if err := p.InsertEntryInternal(30, 300); err != nil {
		t.Fatalf("insert key 30: %v", err)
	}

	if p.GetCurrentSize() != 3 {
		t.Fatalf("expected size 3, got %d", p.GetCurrentSize())
	}

	key, child, err := p.ReadEntryInternal(0)
	if err != nil {
		t.Fatal(err)
	}
	if key != 10 || child != 100 {
		t.Errorf("entry 0: expected key=10 child=100, got key=%d child=%d", key, child)
	}

	key, child, err = p.ReadEntryInternal(1)
	if err != nil {
		t.Fatal(err)
	}
	if key != 20 || child != 200 {
		t.Errorf("entry 1: expected key=20 child=200, got key=%d child=%d", key, child)
	}

	key, child, err = p.ReadEntryInternal(2)
	if err != nil {
		t.Fatal(err)
	}
	if key != 30 || child != 300 {
		t.Errorf("entry 2: expected key=30 child=300, got key=%d child=%d", key, child)
	}
}

func TestBTreeInsertEntryInternalSorted(t *testing.T) {
	p := NewBTreePage(1, BTreeNodeTypeInternal)

	// Insert out of order: 30, 10, 20
	if err := p.InsertEntryInternal(30, 300); err != nil {
		t.Fatalf("insert key 30: %v", err)
	}
	if err := p.InsertEntryInternal(10, 100); err != nil {
		t.Fatalf("insert key 10: %v", err)
	}
	if err := p.InsertEntryInternal(20, 200); err != nil {
		t.Fatalf("insert key 20: %v", err)
	}

	if p.GetCurrentSize() != 3 {
		t.Fatalf("expected size 3, got %d", p.GetCurrentSize())
	}

	// Should be sorted: 10, 20, 30
	key0, child0, _ := p.ReadEntryInternal(0)
	key1, child1, _ := p.ReadEntryInternal(1)
	key2, child2, _ := p.ReadEntryInternal(2)

	if key0 != 10 || child0 != 100 {
		t.Errorf("entry 0: expected key=10 child=100, got key=%d child=%d", key0, child0)
	}
	if key1 != 20 || child1 != 200 {
		t.Errorf("entry 1: expected key=20 child=200, got key=%d child=%d", key1, child1)
	}
	if key2 != 30 || child2 != 300 {
		t.Errorf("entry 2: expected key=30 child=300, got key=%d child=%d", key2, child2)
	}
}

func TestBTreeInsertEntryInternalOnLeafErrors(t *testing.T) {
	p := NewBTreePage(1, BTreeNodeTypeLeaf)
	err := p.InsertEntryInternal(10, 100)
	if err == nil {
		t.Error("expected error when inserting internal entry on leaf node")
	}
}

func TestBTreeInsertEntryInternalFullErrors(t *testing.T) {
	p := NewBTreePage(1, BTreeNodeTypeInternal)
	maxSize := p.GetMaxSize()

	for i := 0; i < int(maxSize); i++ {
		if err := p.InsertEntryInternal(uint64(i), uint32(i+100)); err != nil {
			t.Fatalf("insert %d: %v", i, err)
		}
	}

	err := p.InsertEntryInternal(9999, 9999)
	if err == nil {
		t.Error("expected error when inserting into full node")
	}
}

func TestBTreeGetSetRightmostChild(t *testing.T) {
	p := NewBTreePage(1, BTreeNodeTypeInternal)

	// Should be sentinel initially
	if p.GetRightmostChild() != 0xFFFFFFFF {
		t.Errorf("expected initial rightmost child 0xFFFFFFFF, got %d", p.GetRightmostChild())
	}

	p.SetRightmostChild(42)
	if p.GetRightmostChild() != 42 {
		t.Errorf("expected rightmost child 42, got %d", p.GetRightmostChild())
	}

	p.SetRightmostChild(0)
	if p.GetRightmostChild() != 0 {
		t.Errorf("expected rightmost child 0, got %d", p.GetRightmostChild())
	}
}

func TestBTreeUpdateEntryInternal(t *testing.T) {
	p := NewBTreePage(1, BTreeNodeTypeInternal)

	p.InsertEntryInternal(10, 100)
	p.InsertEntryInternal(20, 200)
	p.InsertEntryInternal(30, 300)

	// Update key 20 to 25
	err := p.UpdateEntryInternal(20, 25)
	if err != nil {
		t.Fatalf("update: %v", err)
	}

	// Size should not change
	if p.GetCurrentSize() != 3 {
		t.Fatalf("expected size 3, got %d", p.GetCurrentSize())
	}

	// Child pointer should be unchanged
	key, child, _ := p.ReadEntryInternal(1)
	if key != 25 || child != 200 {
		t.Errorf("entry 1: expected key=25 child=200, got key=%d child=%d", key, child)
	}

	// Neighbors should be untouched
	key0, child0, _ := p.ReadEntryInternal(0)
	key2, child2, _ := p.ReadEntryInternal(2)
	if key0 != 10 || child0 != 100 {
		t.Errorf("entry 0: expected key=10 child=100, got key=%d child=%d", key0, child0)
	}
	if key2 != 30 || child2 != 300 {
		t.Errorf("entry 2: expected key=30 child=300, got key=%d child=%d", key2, child2)
	}
}

func TestBTreeUpdateEntryInternalNotFound(t *testing.T) {
	p := NewBTreePage(1, BTreeNodeTypeInternal)

	p.InsertEntryInternal(10, 100)

	err := p.UpdateEntryInternal(99, 50)
	if err == nil {
		t.Error("expected error when updating non-existent key")
	}
}

func TestBTreeDeleteEntryInternal(t *testing.T) {
	p := NewBTreePage(1, BTreeNodeTypeInternal)

	p.InsertEntryInternal(10, 100)
	p.InsertEntryInternal(20, 200)
	p.InsertEntryInternal(30, 300)

	// Delete middle entry
	err := p.DeleteEntryInternal(20)
	if err != nil {
		t.Fatalf("delete: %v", err)
	}

	if p.GetCurrentSize() != 2 {
		t.Fatalf("expected size 2, got %d", p.GetCurrentSize())
	}

	// Remaining entries should be 10, 30 — shifted left
	key0, child0, _ := p.ReadEntryInternal(0)
	key1, child1, _ := p.ReadEntryInternal(1)

	if key0 != 10 || child0 != 100 {
		t.Errorf("entry 0: expected key=10 child=100, got key=%d child=%d", key0, child0)
	}
	if key1 != 30 || child1 != 300 {
		t.Errorf("entry 1: expected key=30 child=300, got key=%d child=%d", key1, child1)
	}
}

func TestBTreeDeleteEntryInternalFirst(t *testing.T) {
	p := NewBTreePage(1, BTreeNodeTypeInternal)

	p.InsertEntryInternal(10, 100)
	p.InsertEntryInternal(20, 200)

	err := p.DeleteEntryInternal(10)
	if err != nil {
		t.Fatalf("delete: %v", err)
	}

	if p.GetCurrentSize() != 1 {
		t.Fatalf("expected size 1, got %d", p.GetCurrentSize())
	}

	key, child, _ := p.ReadEntryInternal(0)
	if key != 20 || child != 200 {
		t.Errorf("entry 0: expected key=20 child=200, got key=%d child=%d", key, child)
	}
}

func TestBTreeDeleteEntryInternalNotFound(t *testing.T) {
	p := NewBTreePage(1, BTreeNodeTypeInternal)

	p.InsertEntryInternal(10, 100)

	err := p.DeleteEntryInternal(99)
	if err == nil {
		t.Error("expected error when deleting non-existent key")
	}
}

func TestBTreeInsertAndReadEntryLeaf(t *testing.T) {
	p := NewBTreePage(1, BTreeNodeTypeLeaf)

	rid1 := RID{PageID: 10, SlotID: 1}
	rid2 := RID{PageID: 20, SlotID: 2}
	rid3 := RID{PageID: 30, SlotID: 3}

	// Insert in order
	if err := p.InsertEntryLeaf(100, rid1); err != nil {
		t.Fatalf("insert key 100: %v", err)
	}
	if err := p.InsertEntryLeaf(200, rid2); err != nil {
		t.Fatalf("insert key 200: %v", err)
	}
	if err := p.InsertEntryLeaf(300, rid3); err != nil {
		t.Fatalf("insert key 300: %v", err)
	}

	if p.GetCurrentSize() != 3 {
		t.Fatalf("expected size 3, got %d", p.GetCurrentSize())
	}

	key, rid, err := p.ReadEntryLeaf(0)
	if err != nil {
		t.Fatal(err)
	}
	if key != 100 || rid != rid1 {
		t.Errorf("entry 0: expected key=100 rid=%v, got key=%d rid=%v", rid1, key, rid)
	}

	key, rid, err = p.ReadEntryLeaf(1)
	if err != nil {
		t.Fatal(err)
	}
	if key != 200 || rid != rid2 {
		t.Errorf("entry 1: expected key=200 rid=%v, got key=%d rid=%v", rid2, key, rid)
	}

	key, rid, err = p.ReadEntryLeaf(2)
	if err != nil {
		t.Fatal(err)
	}
	if key != 300 || rid != rid3 {
		t.Errorf("entry 2: expected key=300 rid=%v, got key=%d rid=%v", rid3, key, rid)
	}
}

func TestBTreeInsertEntryLeafSorted(t *testing.T) {
	p := NewBTreePage(1, BTreeNodeTypeLeaf)

	rid1 := RID{PageID: 10, SlotID: 1}
	rid2 := RID{PageID: 20, SlotID: 2}
	rid3 := RID{PageID: 30, SlotID: 3}

	// Insert out of order: 300, 100, 200
	if err := p.InsertEntryLeaf(300, rid3); err != nil {
		t.Fatalf("insert key 300: %v", err)
	}
	if err := p.InsertEntryLeaf(100, rid1); err != nil {
		t.Fatalf("insert key 100: %v", err)
	}
	if err := p.InsertEntryLeaf(200, rid2); err != nil {
		t.Fatalf("insert key 200: %v", err)
	}

	// Should be sorted: 100, 200, 300
	key0, rid0, _ := p.ReadEntryLeaf(0)
	key1, rid1Read, _ := p.ReadEntryLeaf(1)
	key2, rid2Read, _ := p.ReadEntryLeaf(2)

	if key0 != 100 || rid0 != rid1 {
		t.Errorf("entry 0: expected key=100 rid=%v, got key=%d rid=%v", rid1, key0, rid0)
	}
	if key1 != 200 || rid1Read != rid2 {
		t.Errorf("entry 1: expected key=200 rid=%v, got key=%d rid=%v", rid2, key1, rid1Read)
	}
	if key2 != 300 || rid2Read != rid3 {
		t.Errorf("entry 2: expected key=300 rid=%v, got key=%d rid=%v", rid3, key2, rid2Read)
	}
}

func TestBTreeInsertEntryLeafOnInternalErrors(t *testing.T) {
	p := NewBTreePage(1, BTreeNodeTypeInternal)
	err := p.InsertEntryLeaf(10, RID{PageID: 1, SlotID: 1})
	if err == nil {
		t.Error("expected error when inserting leaf entry on internal node")
	}
}

func TestBTreeInsertEntryLeafFullErrors(t *testing.T) {
	p := NewBTreePage(1, BTreeNodeTypeLeaf)
	maxSize := p.GetMaxSize()

	for i := 0; i < int(maxSize); i++ {
		if err := p.InsertEntryLeaf(uint64(i), RID{PageID: uint32(i), SlotID: uint16(i)}); err != nil {
			t.Fatalf("insert %d: %v", i, err)
		}
	}

	err := p.InsertEntryLeaf(9999, RID{PageID: 9999, SlotID: 9999})
	if err == nil {
		t.Error("expected error when inserting into full node")
	}
}

func TestBTreeDeleteEntryLeaf(t *testing.T) {
	p := NewBTreePage(1, BTreeNodeTypeLeaf)

	p.InsertEntryLeaf(100, RID{PageID: 10, SlotID: 1})
	p.InsertEntryLeaf(200, RID{PageID: 20, SlotID: 2})
	p.InsertEntryLeaf(300, RID{PageID: 30, SlotID: 3})

	// Delete middle entry
	err := p.DeleteEntryLeaf(200)
	if err != nil {
		t.Fatalf("delete: %v", err)
	}

	if p.GetCurrentSize() != 2 {
		t.Fatalf("expected size 2, got %d", p.GetCurrentSize())
	}

	key0, rid0, _ := p.ReadEntryLeaf(0)
	key1, rid1, _ := p.ReadEntryLeaf(1)

	if key0 != 100 || rid0.PageID != 10 || rid0.SlotID != 1 {
		t.Errorf("entry 0: expected key=100 rid={10,1}, got key=%d rid=%v", key0, rid0)
	}
	if key1 != 300 || rid1.PageID != 30 || rid1.SlotID != 3 {
		t.Errorf("entry 1: expected key=300 rid={30,3}, got key=%d rid=%v", key1, rid1)
	}
}

func TestBTreeDeleteEntryLeafFirst(t *testing.T) {
	p := NewBTreePage(1, BTreeNodeTypeLeaf)

	p.InsertEntryLeaf(100, RID{PageID: 10, SlotID: 1})
	p.InsertEntryLeaf(200, RID{PageID: 20, SlotID: 2})

	err := p.DeleteEntryLeaf(100)
	if err != nil {
		t.Fatalf("delete: %v", err)
	}

	if p.GetCurrentSize() != 1 {
		t.Fatalf("expected size 1, got %d", p.GetCurrentSize())
	}

	key, rid, _ := p.ReadEntryLeaf(0)
	if key != 200 || rid.PageID != 20 || rid.SlotID != 2 {
		t.Errorf("entry 0: expected key=200 rid={20,2}, got key=%d rid=%v", key, rid)
	}
}

func TestBTreeDeleteEntryLeafNotFound(t *testing.T) {
	p := NewBTreePage(1, BTreeNodeTypeLeaf)

	p.InsertEntryLeaf(100, RID{PageID: 10, SlotID: 1})

	err := p.DeleteEntryLeaf(999)
	if err == nil {
		t.Error("expected error when deleting non-existent key")
	}
}

func TestBTreeGetSetSiblingPointer(t *testing.T) {
	p := NewBTreePage(1, BTreeNodeTypeLeaf)

	// Should be sentinel initially
	if p.GetSiblingPointer() != 0xFFFFFFFF {
		t.Errorf("expected initial sibling pointer 0xFFFFFFFF, got %d", p.GetSiblingPointer())
	}

	p.SetSiblingPointer(42)
	if p.GetSiblingPointer() != 42 {
		t.Errorf("expected sibling pointer 42, got %d", p.GetSiblingPointer())
	}

	p.SetSiblingPointer(0)
	if p.GetSiblingPointer() != 0 {
		t.Errorf("expected sibling pointer 0, got %d", p.GetSiblingPointer())
	}
}
