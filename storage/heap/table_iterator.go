package heap

import (
	"capradb/storage/buffer"
	"capradb/storage/page"
	"encoding/binary"
	"errors"
	"io"
)

type TableIterator struct {
	table            *TableHeap
	current          page.RID
	pageIDData       []byte
	currentIndex     int
	currentPageGuard *buffer.ReadPageGuard
}

func NewTableIterator(table *TableHeap) (*TableIterator, error) {
	headerPageGuard, err := table.bpm.ReadPage(table.headerPageID)
	if err != nil {
		return nil, err
	}

	headerPageData, err := headerPageGuard.GetRecord(0)
	if err != nil {
		return nil, err
	}
	numberPages := binary.LittleEndian.Uint32(headerPageData[0:4])
	pageIDData := make([]byte, len(headerPageData[8:8+numberPages*4]))
	copy(pageIDData, headerPageData[8:])
	headerPageGuard.Drop()

	firstPageID := binary.LittleEndian.Uint32(pageIDData[0:4])
	firstPageGuard, err := table.bpm.ReadPage(firstPageID)
	if err != nil {
		return nil, err
	}

	return &TableIterator{
		table:            table,
		current:          page.RID{PageID: firstPageID, SlotID: 0},
		pageIDData:       pageIDData,
		currentIndex:     0,
		currentPageGuard: firstPageGuard,
	}, nil
}

func (i *TableIterator) Next() ([]byte, page.RID, error) {
	if i.currentIndex >= len(i.pageIDData) {
		// no more pages to iterate over
		return nil, page.RID{}, io.EOF
	}

	currentSlotID := i.current.SlotID

	if currentSlotID >= i.currentPageGuard.GetSlotCount() {
		// no more slots on current page, move to next page
		i.currentPageGuard.Drop()
		i.currentPageGuard = nil
		i.currentIndex += 4
		if i.currentIndex >= len(i.pageIDData) {
			// went through all pages
			return nil, page.RID{}, io.EOF
		}

		nextPageID := binary.LittleEndian.Uint32(i.pageIDData[i.currentIndex : i.currentIndex+4])
		nextPageGuard, err := i.table.bpm.ReadPage(nextPageID)
		if err != nil {
			return nil, page.RID{}, err
		}

		i.currentPageGuard = nextPageGuard
		i.current = page.RID{PageID: nextPageID, SlotID: 0}
		return i.Next()
	}

	record, err := i.currentPageGuard.GetRecord(int(currentSlotID))
	if err != nil {
		if errors.Is(err, page.ErrSlotDeleted) {
			// slot is deleted, skip
			i.current.SlotID++
			return i.Next()
		}
		return nil, page.RID{}, err
	}

	i.current.SlotID++
	return record, page.RID{PageID: i.current.PageID, SlotID: i.current.SlotID - 1}, nil
}

func (i *TableIterator) Close() {
	if i.currentPageGuard != nil {
		i.currentPageGuard.Drop()
		i.currentPageGuard = nil
	}
}
