package heap

import (
	"capradb/storage/buffer"
)

// Header page layout (just raw bytes in page 0):
//   Bytes 0-3:   FirstPageID
//   Bytes 4-7:   LastPageID
//   Bytes 8-11:  RecordCount (optional, nice for stats)

type TableHeap struct {
	bpm          *buffer.BufferPoolManager
	headerPageID uint32
}

func NewTableHeap(bpm *buffer.BufferPoolManager) (*TableHeap, error) {
	headerPage, err := bpm.NewPage()
	if err != nil {
		return nil, err
	}

	headerPageData := make([]byte, 12)

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
