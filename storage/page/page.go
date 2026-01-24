package page

import (
	"encoding/binary"
	"errors"
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

/*
A deleted slot is marked as deleted by setting the length to 0.
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

var ErrSlotDeleted = errors.New("slot is deleted")

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

	dataPtr, dataLen, _ := p.getSlotData(slotID)

	if dataLen == 0 {
		return nil, ErrSlotDeleted
	}

	return p.Data[dataPtr : dataPtr+dataLen], nil
}

func (p *Page) UpdateRecord(slotID int, data []byte) error {
	if slotID < 0 || slotID >= int(p.GetSlotCount()) {
		return fmt.Errorf("invalid slotID")
	}

	updateLen := len(data)
	dataPtr, dataLen, slotPtr := p.getSlotData(slotID)
	if dataLen == 0 {
		return fmt.Errorf("slot is deleted")
	}
	if updateLen <= int(dataLen) {
		// Just insert into existing space as it can fit
		copy(p.Data[dataPtr:], data)
		// Update slot length
		binary.LittleEndian.PutUint16(p.Data[slotPtr+2:slotPtr+4], uint16(updateLen))

		return nil
	}

	// data too large for existing spot, find new spot
	// currently, we will fragment the data.
	// TODO: implement compacting

	if int(updateLen) > p.GetFreeSpace() {
		return fmt.Errorf("not enough free space for update")
	}

	newPtr := p.GetFreeSpacePointer() - uint16(updateLen)
	copy(p.Data[newPtr:], data)
	binary.LittleEndian.PutUint16(p.Data[slotPtr:slotPtr+2], uint16(newPtr))
	binary.LittleEndian.PutUint16(p.Data[slotPtr+2:slotPtr+4], uint16(updateLen))
	// Move free space pointer to the start of the data
	binary.LittleEndian.PutUint16(p.Data[8:10], newPtr)

	return nil
}

func (p *Page) DeleteRecord(slotID int) error {
	if slotID < 0 || slotID >= int(p.GetSlotCount()) {
		return fmt.Errorf("invalid slotID")
	}

	_, dataLen, slotPtr := p.getSlotData(slotID)

	if dataLen == 0 {
		// already deleted
		return nil
	}

	binary.LittleEndian.PutUint16(p.Data[slotPtr+2:slotPtr+4], 0)

	return nil
}

func (p *Page) getSlotData(slotID int) (uint16, uint16, int) {
	// Returns
	// dataPtr - pointer to slots data
	// dataLen - length of the data
	// slotPtr - pointer to the slot itself
	// It's assumed that the slotID has been validated already
	slotPtr := slotID*SlotSize + HeaderSize
	dataPtr := binary.LittleEndian.Uint16(p.Data[slotPtr : slotPtr+2])
	dataLen := binary.LittleEndian.Uint16(p.Data[slotPtr+2 : slotPtr+4])

	return dataPtr, dataLen, slotPtr
}
