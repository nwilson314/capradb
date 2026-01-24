package heap

import (
	"capradb/storage/buffer"
	"encoding/binary"
)

// Header page layout (just raw bytes in page 0):
//   Bytes 0-3:   Page Count
//   Bytes 4-7:   NextHeaderPage (0xFFFFFFFF if no more header pages)
//   Bytes 8+:  PageID array (each 4 bytes)

type TableHeap struct {
	bpm          *buffer.BufferPoolManager
	headerPageID uint32
}

func NewTableHeap(bpm *buffer.BufferPoolManager) (*TableHeap, error) {
	headerPage, err := bpm.NewPage()
	if err != nil {
		return nil, err
	}

	firstPage, err := bpm.NewPage()
	if err != nil {
		return nil, err
	}

	firstPageID := firstPage.PageID()
	firstPage.Drop()

	// Preallocate a large enough header page data to avoid reallocations
	headerPageData := make([]byte, 2048)

	binary.LittleEndian.PutUint32(headerPageData[:4], 1)
	binary.LittleEndian.PutUint32(headerPageData[4:8], 0xFFFFFFFF)
	binary.LittleEndian.PutUint32(headerPageData[8:12], firstPageID)

	_, insert_err := headerPage.InsertRecord(headerPageData)
	if insert_err != nil {
		return nil, insert_err
	}

	headerPageID := headerPage.PageID()

	headerPage.Drop()

	return &TableHeap{
		bpm:          bpm,
		headerPageID: uint32(headerPageID),
	}, nil
}

func (h *TableHeap) InsertRecord(record []byte) (RID, error) {
	headerPageGuard, err := h.bpm.WritePage(h.headerPageID)
	if err != nil {
		return RID{}, err
	}

	// header page data is always the first record in header page
	headerPageData, err := headerPageGuard.GetRecord(0)
	if err != nil {
		return RID{}, err
	}

	numberPages := binary.LittleEndian.Uint32(headerPageData[0:4])
	lastPageSlot := (numberPages-1)*4 + 8

	lastPageID := binary.LittleEndian.Uint32(headerPageData[lastPageSlot : lastPageSlot+4])

	lastPageGuard, err := h.bpm.WritePage(lastPageID)
	if err != nil {
		return RID{}, err
	}

	freeSpace := lastPageGuard.GetFreeSpace()
	recordSize := len(record) + 4 // 4 bytes for the slot size

	if recordSize > freeSpace {
		// last page is too full, create a new page
		lastPageGuard.Drop()
		newPage, err := h.bpm.NewPage()
		if err != nil {
			return RID{}, err
		}

		newPageID := newPage.PageID()

		// // grow header page data by 4 bytes
		// newHeaderPageData := make([]byte, len(headerPageData)+4)
		// copy(newHeaderPageData, headerPageData)

		binary.LittleEndian.PutUint32(headerPageData[lastPageSlot+4:lastPageSlot+8], newPageID)
		binary.LittleEndian.PutUint32(headerPageData[0:4], numberPages+1)

		update_err := headerPageGuard.UpdateRecord(0, headerPageData[:])
		if update_err != nil {
			return RID{}, update_err
		}

		slotID, insert_err := newPage.InsertRecord(record)
		if insert_err != nil {
			return RID{}, insert_err
		}

		headerPageGuard.Drop()
		newPage.Drop()

		return RID{
			PageID: newPageID,
			SlotID: uint16(slotID),
		}, nil

	}

	slotID, insert_err := lastPageGuard.InsertRecord(record)
	if insert_err != nil {
		return RID{}, insert_err
	}

	headerPageGuard.Drop()
	lastPageGuard.Drop()

	return RID{
		PageID: lastPageID,
		SlotID: uint16(slotID),
	}, nil
}

func (h *TableHeap) GetRecord(rid RID) ([]byte, error) {
	pageGuard, err := h.bpm.ReadPage(rid.PageID)
	if err != nil {
		return nil, err
	}

	record, err := pageGuard.GetRecord(int(rid.SlotID))
	if err != nil {
		return nil, err
	}

	pageGuard.Drop()

	return record, nil
}

func (h *TableHeap) DeleteRecord(rid RID) error {
	pageGuard, err := h.bpm.WritePage(rid.PageID)
	if err != nil {
		return err
	}

	err = pageGuard.DeleteRecord(int(rid.SlotID))
	if err != nil {
		return err
	}

	pageGuard.Drop()

	return nil
}
