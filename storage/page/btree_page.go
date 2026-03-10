package page

import (
	"encoding/binary"
	"fmt"
)

/*
Header Layout (Total 20 Bytes):
0-3 (4 bytes): Page ID (uint32)
4-7 (4 bytes): LSN (uint32) - Log Sequence Number (last transaction that touched this page)
8-11 (4 Bytes): Node Type (uint32) - 0 for leaf, 1 for internal
12-13 (2 Bytes): Current Size (uint16) - Number of key-value pairs currently used in the page.
14-15 (2 Bytes): Max Size (uint16) - Maximum number of key-value pairs that can be used in the page.
16-19 (4 Bytes):
	Internal Node: Rightmost Child Pointer (uint32) - Points to the rightmost child page ID.
	Leaf Node: Sibling Pointer (uint32) - Points to the sibling page ID.
*/

/*
Internal Node:
0-7 (8 bytes): Key (uint64)
8-11 (4 bytes): Child Page ID (uint32)

Leaf Node:
0-7 (8 bytes): Key (uint64)
8-13 (6 bytes): RID (page ID + slot ID) (uint32 + uint16)
*/

const (
	BTreePageSize         = 4096
	BTreeHeaderSize       = 20
	BTreeInternalNodeSize = 12
	BTreeLeafNodeSize     = 14
	KeySize               = 8
)

type BTreeNodeType uint32

const (
	BTreeNodeTypeLeaf     BTreeNodeType = 0
	BTreeNodeTypeInternal BTreeNodeType = 1
)

type BTreePage struct {
	ID   uint32
	Data [BTreePageSize]byte
}

func NewBTreePage(id uint32, nodeType BTreeNodeType) *BTreePage {
	p := &BTreePage{
		ID:   id,
		Data: [BTreePageSize]byte{},
	}

	binary.LittleEndian.PutUint32(p.Data[:4], id)
	binary.LittleEndian.PutUint32(p.Data[4:8], 0)
	binary.LittleEndian.PutUint32(p.Data[8:12], uint32(nodeType))
	binary.LittleEndian.PutUint16(p.Data[12:14], 0)
	nodeSize := BTreeLeafNodeSize
	if nodeType == BTreeNodeTypeInternal {
		nodeSize = BTreeInternalNodeSize
	}
	maxSize := (BTreePageSize - BTreeHeaderSize) / nodeSize
	binary.LittleEndian.PutUint16(p.Data[14:16], uint16(maxSize))
	binary.LittleEndian.PutUint32(p.Data[16:20], 0xFFFFFFFF)
	return p
}

func (p *BTreePage) IsLeafNode() bool {
	return binary.LittleEndian.Uint32(p.Data[8:12]) == 0
}

func (p *BTreePage) GetCurrentSize() uint16 {
	return binary.LittleEndian.Uint16(p.Data[12:14])
}

func (p *BTreePage) GetMaxSize() uint16 {
	return binary.LittleEndian.Uint16(p.Data[14:16])
}

func (p *BTreePage) ReadEntryInternal(index int) (key uint64, childPageID uint32, err error) {
	if p.IsLeafNode() {
		return 0, 0, fmt.Errorf("node is a leaf node")
	}

	if index < 0 || index >= int(p.GetCurrentSize()) {
		return 0, 0, fmt.Errorf("index out of range")
	}

	offset := BTreeHeaderSize + index*BTreeInternalNodeSize

	key = binary.LittleEndian.Uint64(p.Data[offset : offset+KeySize])
	childPageID = binary.LittleEndian.Uint32(p.Data[offset+KeySize : offset+KeySize+4])
	return key, childPageID, nil
}

func (p *BTreePage) ReadEntryLeaf(index int) (key uint64, rid RID, err error) {
	if !p.IsLeafNode() {
		return 0, RID{}, fmt.Errorf("node is not a leaf node")
	}

	if index < 0 || index >= int(p.GetCurrentSize()) {
		return 0, RID{}, fmt.Errorf("index out of range")
	}

	offset := BTreeHeaderSize + index*BTreeLeafNodeSize

	key = binary.LittleEndian.Uint64(p.Data[offset : offset+KeySize])
	rid = RID{
		PageID: binary.LittleEndian.Uint32(p.Data[offset+KeySize : offset+KeySize+4]),
		SlotID: binary.LittleEndian.Uint16(p.Data[offset+KeySize+4 : offset+KeySize+6]),
	}
	return key, rid, nil
}

func (p *BTreePage) InsertEntryInternal(key uint64, childPageID uint32) error {
	if p.IsLeafNode() {
		return fmt.Errorf("node is a leaf node")
	}

	if int(p.GetCurrentSize()) >= int(p.GetMaxSize()) {
		return fmt.Errorf("node is full")
	}

	// Find where key should be inserted
	idx, _ := p.searchEntries(key, BTreeInternalNodeSize)

	data := make([]byte, BTreeInternalNodeSize)
	binary.LittleEndian.PutUint64(data[:KeySize], key)
	binary.LittleEndian.PutUint32(data[KeySize:KeySize+4], childPageID)

	// Actually insert
	if idx == int(p.GetCurrentSize()) {
		// Rightmost, just insert at the end
		copy(p.Data[BTreeHeaderSize+int(p.GetCurrentSize())*BTreeInternalNodeSize:], data)
		binary.LittleEndian.PutUint16(p.Data[12:14], uint16(p.GetCurrentSize()+1))
		return nil
	} else {
		// Not rightmost, insert in the middle, move the rest of the data to the right
		copy(p.Data[BTreeHeaderSize+(idx+1)*BTreeInternalNodeSize:], p.Data[BTreeHeaderSize+idx*BTreeInternalNodeSize:])
		copy(p.Data[BTreeHeaderSize+idx*BTreeInternalNodeSize:], data)
		binary.LittleEndian.PutUint16(p.Data[12:14], uint16(p.GetCurrentSize()+1))
		return nil
	}
}

func (p *BTreePage) InsertEntryLeaf(key uint64, rid RID) error {
	if !p.IsLeafNode() {
		return fmt.Errorf("node is not a leaf node")
	}

	if int(p.GetCurrentSize()) >= int(p.GetMaxSize()) {
		return fmt.Errorf("node is full")
	}

	// Find where key should be inserted
	idx, _ := p.searchEntries(key, BTreeLeafNodeSize)

	data := make([]byte, BTreeLeafNodeSize)
	binary.LittleEndian.PutUint64(data[:KeySize], key)
	binary.LittleEndian.PutUint32(data[KeySize:KeySize+4], rid.PageID)
	binary.LittleEndian.PutUint16(data[KeySize+4:KeySize+6], rid.SlotID)

	// Actually insert
	if idx == int(p.GetCurrentSize()) {
		// Rightmost, just insert at the end
		copy(p.Data[BTreeHeaderSize+int(p.GetCurrentSize())*BTreeLeafNodeSize:], data)
		binary.LittleEndian.PutUint16(p.Data[12:14], uint16(p.GetCurrentSize()+1))
		return nil
	} else {
		// Not rightmost, insert in the middle, move the rest of the data to the right
		copy(p.Data[BTreeHeaderSize+(idx+1)*BTreeLeafNodeSize:], p.Data[BTreeHeaderSize+idx*BTreeLeafNodeSize:])
		copy(p.Data[BTreeHeaderSize+idx*BTreeLeafNodeSize:], data)
		binary.LittleEndian.PutUint16(p.Data[12:14], uint16(p.GetCurrentSize()+1))
		return nil
	}
}

func (p *BTreePage) UpdateEntryInternal(replaceKey uint64, key uint64) error {
	// We assume that the key that will replace the old key still maintains sorted order in the page
	if p.IsLeafNode() {
		return fmt.Errorf("node is a leaf node")
	}

	if int(p.GetCurrentSize()) == 0 {
		return fmt.Errorf("node is empty")
	}

	idx, found := p.searchEntries(replaceKey, BTreeInternalNodeSize)
	if !found {
		return fmt.Errorf("key to replace not found")
	}

	binary.LittleEndian.PutUint64(p.Data[BTreeHeaderSize+idx*BTreeInternalNodeSize:BTreeHeaderSize+idx*BTreeInternalNodeSize+KeySize], key)
	return nil
}

func (p *BTreePage) DeleteEntryInternal(key uint64) error {
	if p.IsLeafNode() {
		return fmt.Errorf("node is a leaf node")
	}

	if int(p.GetCurrentSize()) == 0 {
		return fmt.Errorf("node is empty")
	}

	idx, found := p.searchEntries(key, BTreeInternalNodeSize)
	if !found {
		return fmt.Errorf("key not found")
	}

	// Delete the entry and shift the rest of the data to the left
	copy(p.Data[BTreeHeaderSize+idx*BTreeInternalNodeSize:], p.Data[BTreeHeaderSize+(idx+1)*BTreeInternalNodeSize:])
	binary.LittleEndian.PutUint16(p.Data[12:14], uint16(p.GetCurrentSize()-1))
	return nil
}

func (p *BTreePage) DeleteEntryLeaf(key uint64) error {
	if !p.IsLeafNode() {
		return fmt.Errorf("node is not a leaf node")
	}

	if int(p.GetCurrentSize()) == 0 {
		return fmt.Errorf("node is empty")
	}

	idx, found := p.searchEntries(key, BTreeLeafNodeSize)
	if !found {
		return fmt.Errorf("key not found")
	}

	// Delete the entry and shift the rest of the data to the left
	copy(p.Data[BTreeHeaderSize+idx*BTreeLeafNodeSize:], p.Data[BTreeHeaderSize+(idx+1)*BTreeLeafNodeSize:])
	binary.LittleEndian.PutUint16(p.Data[12:14], uint16(p.GetCurrentSize()-1))
	return nil
}

func (p *BTreePage) GetRightmostChild() uint32 {
	if p.IsLeafNode() {
		// Leaf nodes don't have a rightmost child
		return 0xFFFFFFFF
	}
	return binary.LittleEndian.Uint32(p.Data[16:20])
}

func (p *BTreePage) SetRightmostChild(childPageID uint32) {
	if p.IsLeafNode() {
		// Leaf nodes don't have a rightmost child
		return
	}
	binary.LittleEndian.PutUint32(p.Data[16:20], childPageID)
}

func (p *BTreePage) GetSiblingPointer() uint32 {
	if p.IsLeafNode() {
		return binary.LittleEndian.Uint32(p.Data[16:20])
	}
	// Internal nodes don't have a sibling pointer
	return 0xFFFFFFFF
}

func (p *BTreePage) SetSiblingPointer(siblingPageID uint32) {
	if p.IsLeafNode() {
		binary.LittleEndian.PutUint32(p.Data[16:20], siblingPageID)
	}
	// Internal nodes don't have a sibling pointer
	return
}

func (p *BTreePage) searchEntries(key uint64, nodeSize int) (int, bool) {
	left := 0
	right := int(p.GetCurrentSize()) - 1

	for left <= right {
		mid := (left + right) / 2
		midKey := binary.LittleEndian.Uint64(p.Data[BTreeHeaderSize+mid*nodeSize : BTreeHeaderSize+mid*nodeSize+KeySize])
		if midKey < key {
			left = mid + 1
		} else if midKey > key {
			right = mid - 1
		} else {
			return mid, true
		}
	}
	return left, false
}
