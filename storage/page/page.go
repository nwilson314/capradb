package page

import (
	"encoding/binary"
	"fmt"
)

/*
Header Layout (Total 12 Bytes):
0-3 (4 bytes): Page ID (uint32)
4-7 (4 bytes): LSN (uint32) - Log Sequence Number (last transaction that touched this page)
8-9 (2 bytes): FreeSpacePointer (uint16) - Points to the start of the data area (initially 4096).
10-11 (2 bytes): SlotCount (uint16) - Number of slots currently used.
Slot Layout (Total 4 Bytes):
0-1 (2 bytes): Offset (uint16)
2-3 (2 bytes): Length (uint16)
*/

const (
	PageSize   = 4096
	HeaderSize = 12
	SlotSize   = 4
)

type Page struct {
	ID   uint32
	Data [PageSize]byte
}

func New(id uint32) *Page {
	p := &Page{
		ID:   id,
		Data: [PageSize]byte{},
	}

	binary.LittleEndian.PutUint32(p.Data[:4], id)
	binary.LittleEndian.PutUint16(p.Data[8:10], PageSize)

	return p
}

func (p *Page) GetSlotCount() uint16 {
	return binary.LittleEndian.Uint16(p.Data[10:12])
}

func (p *Page) GetFreeSpacePointer() uint16 {
	return binary.LittleEndian.Uint16(p.Data[8:10])
}

func (p *Page) GetFreeSpace() int {
	freePtr := p.GetFreeSpacePointer()
	slotCount := p.GetSlotCount()

	usedHeader := HeaderSize + (int(slotCount) * SlotSize)

	return int(freePtr) - usedHeader
}

func (p *Page) InsertRecord(data []byte) (int, error) {
	dataLength := len(data)

	if int(dataLength)+SlotSize > p.GetFreeSpace() {
		return 0, fmt.Errorf("not enough free space")
	}

	slotSpot := p.GetSlotCount()*SlotSize + HeaderSize
	dataOffset := p.GetFreeSpacePointer() - uint16(dataLength)

	binary.LittleEndian.PutUint16(p.Data[slotSpot:slotSpot+2], uint16(dataOffset))
	binary.LittleEndian.PutUint16(p.Data[slotSpot+2:slotSpot+4], uint16(dataLength))

	slotCount := p.GetSlotCount() + 1
	binary.LittleEndian.PutUint16(p.Data[10:12], slotCount)
	copy(p.Data[dataOffset:], data)

	// Move free space pointer to the start of the data
	binary.LittleEndian.PutUint16(p.Data[8:10], dataOffset)

	return int(slotCount - 1), nil
}

func (p *Page) GetRecord(slotID int) ([]byte, error) {
	if slotID < 0 || slotID >= int(p.GetSlotCount()) {
		return nil, fmt.Errorf("invalid slotID")
	}
	slotSpot := HeaderSize + slotID*SlotSize
	slotPtr := binary.LittleEndian.Uint16(p.Data[slotSpot : slotSpot+2])
	dataLength := binary.LittleEndian.Uint16(p.Data[slotSpot+2 : slotSpot+4])

	return p.Data[slotPtr : slotPtr+dataLength], nil
}

func (p *Page) UpdateRecord(slotID int, data []byte) error {
	if slotID < 0 || slotID >= int(p.GetSlotCount()) {
		return fmt.Errorf("invalid slotID")
	}

	dataLength := len(data)
	slotSpot := p.GetSlotCount()*SlotSize + HeaderSize
	if dataLength <= int(binary.LittleEndian.Uint16(p.Data[slotSpot+2:slotSpot+4])) {
		// Just insert into existing space

		return nil
	}

	// data too large for existing spot, find new spot
	// currently, we will fragment the data.
	// TODO: implement compacting

	return nil
}
