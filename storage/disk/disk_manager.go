package disk

import (
	"fmt"
	"os"

	"capradb/storage/page"
)

type DiskManager struct {
	file     *os.File
	numPages uint32
}

func NewDiskManager(path string) (*DiskManager, error) {
	file, err := os.OpenFile(path, os.O_RDWR|os.O_CREATE, 0666)
	if err != nil {
		return nil, err
	}

	fileInfo, err := file.Stat()
	if err != nil {
		return nil, err
	}
	fileSize := fileInfo.Size()
	numPages := uint32(fileSize / page.PageSize)
	dm := &DiskManager{
		file:     file,
		numPages: numPages,
	}
	return dm, nil
}

func (dm *DiskManager) Close() error {
	return dm.file.Close()
}

func (dm *DiskManager) GetNumPages() uint32 {
	return dm.numPages
}

func (dm *DiskManager) AllocatePage() uint32 {
	pageID := dm.numPages
	dm.numPages++
	return pageID
}

func (dm *DiskManager) WritePage(p *page.Page) error {
	pageID := p.ID
	offset := pageID * page.PageSize

	_, err := dm.file.WriteAt(p.Data[:], int64(offset))
	if err != nil {
		return err
	}
	return nil
}

func (dm *DiskManager) ReadPage(pageID uint32) (*page.Page, error) {
	if pageID >= dm.numPages {
		return nil, fmt.Errorf("pageID out of range")
	}
	p := &page.Page{ID: pageID}
	offset := pageID * page.PageSize

	_, err := dm.file.ReadAt(p.Data[:], int64(offset))
	if err != nil {
		return nil, err
	}
	return p, nil
}
